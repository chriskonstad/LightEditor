import CoreGraphics
import EditorCore
import Foundation
import Observation

/// App-wide state: the library, jobs, clipboard and presets.
///
/// Views stay thin and talk to this model and to `EditorModel`; all real logic
/// lives in EditorCore.
@MainActor
@Observable
final class AppModel {
    /// The library on screen: this device's, or another device's while editing it remotely.
    private(set) var library: any PhotoLibrary
    /// This device's own library (Apple Photos, or a folder in tests).
    let localLibrary: any PhotoLibrary
    let remote = RemoteModel()
    let jobs = JobCenter()
    let clock: HybridLogicalClock
    let lutStore = LUTStore(directory: LUTStore.defaultDirectory())
    private let presetStore = PresetStore(directory: PresetStore.defaultDirectory())

    var authorization: LibraryAuthorization
    private(set) var albums: [LibraryAlbum] = []
    var album: LibraryAlbum = .raw {
        didSet { if oldValue != album { Task { await reloadAssets() } } }
    }
    private(set) var assets: AssetList = .empty
    /// Bumped whenever the library changes, so thumbnails reload.
    private(set) var libraryVersion = 0

    /// The photo open in the editor, if any.
    var editing: PhotoAsset?
    /// The live editor, so leaving the app can save it.
    @ObservationIgnored weak var activeEditor: EditorModel?

    var clipboard: RecipeClip? { didSet { persistClipboard() } }
    /// The last photo's edit, for "Match previous".
    var previousEdit: RecipeClip?
    /// Thumbnails rendered by a bulk edit before Photos has the full render.
    var pendingThumbnails: [String: CGImage] = [:]

    private(set) var userPresets: [Preset] = []
    private(set) var luts: [LUTRef] = []
    var toast: String?

    var presets: [Preset] { BuiltInPresets.all + FilmSimulations.presets + AdaptivePresets.all + userPresets }

    /// While editing another device's library, the remote library.
    var remoteLibrary: RemoteLibrary? { library as? RemoteLibrary }

    init(library: any PhotoLibrary) {
        self.library = library
        self.localLibrary = library
        authorization = library.authorizationStatus()
        let defaults = UserDefaults.standard
        let node = defaults.string(forKey: "clockNode") ?? String(UUID().uuidString.prefix(8)).lowercased()
        defaults.set(node, forKey: "clockNode")
        clock = HybridLogicalClock(node: node)
        if let data = defaults.data(forKey: "clipboard") {
            clipboard = try? JSONDecoder().decode(RecipeClip.self, from: data)
        }
        userPresets = presetStore.load()
        luts = lutStore.all()
        Task.detached(priority: .utility) { Kernels.warmUp() }
        remote.attach(self)
    }

    /// Picks Apple Photos, or a folder when launched with `-FixtureLibrary <path>`
    /// (used for UI automation and on the Mac during development).
    static func makeLibrary() -> any PhotoLibrary {
        if let path = UserDefaults.standard.string(forKey: "FixtureLibrary"), !path.isEmpty {
            return FolderLibrary(directory: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        return PhotoKitLibrary()
    }

    // MARK: Library

    func start() async {
        if authorization == .notDetermined { return }
        await loadLibrary()
    }

    func requestAccess() async {
        authorization = await library.requestAuthorization()
        await loadLibrary()
    }

    @ObservationIgnored private var observing: Task<Void, Never>?

    private func loadLibrary() async {
        guard authorization == .authorized || authorization == .limited else { return }
        #if DEBUG
        if remoteLibrary == nil { await importAutomationFolderIfRequested() }
        #endif
        albums = await library.albums()
        // Start on RAW if there are any, else everything.
        if album == .raw, await library.assets(in: .raw).count == 0 { album = .recents }
        await reloadAssets()
        guard observing == nil else { return }
        let stream = library.changes()
        observing = Task { [weak self] in
            for await _ in stream {
                await self?.reloadAssets()
            }
        }
    }

    /// Switches to another device's library (remote editing) or back.
    func use(_ newLibrary: any PhotoLibrary) {
        activeEditor?.saveIfNeeded()
        editing = nil
        observing?.cancel()
        observing = nil
        library = newLibrary
        albums = []
        assets = .empty
        pendingThumbnails = [:]
        authorization = newLibrary.authorizationStatus()
        libraryVersion += 1
        Task { await loadLibrary() }
    }

    func useLocalLibrary() { use(localLibrary) }

    /// Sends edits saved while the other device was away.
    func flushRemoteOutbox() {
        guard let remote = remoteLibrary else { return }
        let entries = remote.outbox.pending
        guard !entries.isEmpty else { return }
        let label = entries.count == 1 ? "Saving edit to \(remote.displayName)" : "Saving \(entries.count) edits to \(remote.displayName)"
        jobs.run(label, photos: entries.count) { [weak self] reporter in
            for (index, entry) in entries.enumerated() {
                try await remote.send(entry) { fraction, detail in
                    reporter.progress((Double(index) + (fraction ?? 0)) / Double(entries.count), detail: detail, remaining: entries.count - index)
                }
            }
            await MainActor.run { self?.libraryVersion += 1 }
        }
    }

    /// Imports camera files (RAW, RAW+JPEG pairs, JPEG/HEIC) into the library.
    func importFiles(_ urls: [URL]) {
        if let remote = remoteLibrary {
            showToast("Import on \(remote.displayName) itself")
            return
        }
        let library = self.library
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        jobs.run("Importing \(urls.count) files", photos: urls.count, started: Self.keepRunningInBackground) { reporter in
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            let count = try await PhotoImporter.importFiles(urls, into: library) { reporter.progress($0) }
            await MainActor.run { [weak self] in self?.showToast("Imported \(count) photos") }
        }
    }

    #if DEBUG
    /// UI automation hook: `-ImportFolder <path>` imports a folder's files on launch,
    /// because `simctl addmedia` can't add RAW files to a simulator's library.
    func importAutomationFolderIfRequested() async {
        guard let path = UserDefaults.standard.string(forKey: "ImportFolder"), !path.isEmpty else { return }
        let folder = URL(fileURLWithPath: path)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard !files.isEmpty else { return }
        importFiles(files)
    }
    #endif

    func reloadAssets() async {
        assets = await library.assets(in: album)
        libraryVersion += 1
    }

    /// Moves the editor to the previous or next photo in the album.
    func step(_ offset: Int) {
        guard let editing, let index = assets.index(of: editing.id) else { return }
        let next = index + offset
        guard next >= 0, next < assets.count else { return }
        self.editing = assets[next]
    }

    // MARK: Clipboard

    func copy(_ recipe: Recipe, from filename: String, defaults: PhotoDefaults) {
        clipboard = RecipeClip(recipe: recipe, sourceName: filename, sourceDefaults: defaults)
        showToast("Edits copied · Paste on any photo")
    }

    private func persistClipboard() {
        UserDefaults.standard.set(clipboard.flatMap { try? JSONEncoder().encode($0) }, forKey: "clipboard")
    }

    func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toast == message { toast = nil }
        }
    }

    // MARK: Bulk edits

    func bulkApply(_ change: BulkChange, to assets: [PhotoAsset], label: String) {
        if let remote = remoteLibrary {
            // The other device renders and saves; this one just shows progress.
            let luts = lutFiles(for: change)
            jobs.run(label, detail: "On \(remote.displayName)", photos: assets.count, started: Self.keepRunningInBackground) { [weak self] reporter in
                _ = try await remote.bulk(change, assets: assets, luts: luts) { fraction, detail in
                    reporter.progress(fraction, detail: detail)
                }
                await MainActor.run { self?.libraryVersion += 1 }
            }
            return
        }
        let library = self.library
        let luts = lutStore
        let clock = self.clock
        let total = assets.count
        jobs.run(label, detail: "Preparing · \(total) photos", photos: total, started: Self.keepRunningInBackground) { [weak self] reporter in
            try await BulkEditor.apply(change, to: assets, library: library, luts: luts, clock: clock) { progress in
                reporter.progress(progress.fraction, detail: progress.summary, remaining: progress.remaining)
            } thumbnail: { id, image in
                let box = SendableImage(image)
                Task { @MainActor in self?.pendingThumbnails[id] = box.image }
            }
            await MainActor.run {
                for asset in assets { self?.pendingThumbnails[asset.id] = nil }
                self?.libraryVersion += 1
            }
        }
    }

    /// Lets a job the user started keep going after they leave the app or lock the
    /// screen, with its progress in a Live Activity (iOS and iPadOS).
    private static func keepRunningInBackground(_ job: Job) {
        #if os(iOS)
        ContinuedProcessing.cover(job)
        #endif
    }

    /// The .cube files a bulk change needs, for renders on another device.
    private func lutFiles(for change: BulkChange) -> [LUTFile] {
        switch change {
        case .paste(let clip, _, _): clip.recipe.lutFiles(from: lutStore)
        case .preset(let preset, _): Recipe().applying(preset, amount: 1, defaults: .generic, stamp: clock.now()).lutFiles(from: lutStore)
        case .values, .reset: []
        }
    }

    // MARK: Presets and LUTs

    func savePreset(named name: String, from recipe: Recipe, groups: Set<PasteGroup>) {
        let preset = Preset(name: name, from: recipe, groups: groups)
        try? presetStore.save(preset)
        userPresets = presetStore.load()
        showToast("Saved preset “\(name)”")
    }

    func delete(_ preset: Preset) {
        try? presetStore.delete(preset)
        userPresets = presetStore.load()
    }

    /// Imports a .cube (as a LUT and a one-tap preset) or a Lightroom .xmp preset.
    /// Returns a message for the user.
    @discardableResult
    func importPresetFile(_ url: URL) -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            switch url.pathExtension.lowercased() {
            case "cube":
                let lut = try lutStore.importCube(from: url)
                luts = lutStore.all()
                let preset = Preset(name: lut.title, groups: [.filmLUT], params: [.lut: .lut(lut.ref, amount: 1)])
                try presetStore.save(preset)
                userPresets = presetStore.load()
                return "Imported LUT “\(lut.title)” (\(lut.dimension)³)."
            case "xmp":
                let result = try XMPImporter.importPreset(from: Data(contentsOf: url), fallbackName: url.deletingPathExtension().lastPathComponent)
                try presetStore.save(result.preset)
                userPresets = presetStore.load()
                if result.unmapped.isEmpty { return "Imported “\(result.preset.name)”." }
                return "Imported “\(result.preset.name)”. Not supported, so skipped: \(result.unmapped.joined(separator: ", "))."
            default:
                return "Choose a .cube LUT or a Lightroom .xmp preset."
            }
        } catch {
            return "Import failed: \(error.localizedDescription)"
        }
    }

    func importLUT(_ url: URL) -> LUTRef? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let lut = try? lutStore.importCube(from: url) else { return nil }
        luts = lutStore.all()
        return lut.ref
    }
}

/// CGImage is immutable and thread-safe; this marks it so for Swift 6.
struct SendableImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
