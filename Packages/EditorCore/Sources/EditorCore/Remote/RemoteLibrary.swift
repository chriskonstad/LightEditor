import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Synchronization

/// The iPad's side of remote editing: another device's photo library, reached
/// over a `PeerLink` that can come and go.
///
/// It stands in for Apple Photos, so the library grid and editor work unchanged,
/// and it decodes photos for `RawDecoder` by asking the phone for its decode.
/// Saves, exports, AI masks, Remove fills and bulk edits run on the phone.
///
/// The phone drops the link whenever it locks or switches apps. Editing carries
/// on here: requests wait for the next link and retry with the same key (the
/// phone runs each key once), saves go through a disk-backed outbox that
/// survives this app being closed, and photos opened before keep working from
/// cached decodes and session info.
public final class RemoteLibrary: PhotoLibrary, RemoteDecoding, @unchecked Sendable {
    /// The other device's identity key, which a reconnection must match.
    public let hostIdentity: Data
    public let displayName: String

    private struct State {
        var link: PeerLink?
        var waiters: [UUID: CheckedContinuation<PeerLink, any Error>] = [:]
        var closed = false
        var changes: [UUID: AsyncStream<Void>.Continuation] = [:]
    }
    private let state = Mutex(State())
    private let infos = Mutex<[String: RemoteSessionInfo]>([:])
    private let thumbnails = Mutex<[String: Data]>([:])
    public let outbox: RemoteOutbox

    public init(hostIdentity: Data, name: String, outboxDirectory: URL? = RemoteOutbox.defaultDirectory) {
        self.hostIdentity = hostIdentity
        self.displayName = name
        self.outbox = RemoteOutbox(host: hostIdentity, directory: outboxDirectory)
    }

    public convenience init(link: PeerLink, outboxDirectory: URL? = RemoteOutbox.defaultDirectory) {
        self.init(hostIdentity: link.peerIdentity, name: link.peerName, outboxDirectory: outboxDirectory)
        attach(link)
    }

    // MARK: Connection

    public var isConnected: Bool { state.withLock { $0.link.map { !$0.isClosed } ?? false } }

    /// Uses a new link to the same device, e.g. after the phone unlocks.
    /// Waiting requests continue on it.
    public func attach(_ link: PeerLink) {
        precondition(link.peerIdentity == hostIdentity, "a different device")
        let (waiters, listeners) = state.withLock { state in
            state.link = link
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return (waiters, Array(state.changes.values))
        }
        waiters.forEach { $0.resume(returning: link) }
        // Refresh the grid: the library may have changed while away.
        listeners.forEach { $0.yield() }
        let events = link.events
        Task { [weak self] in
            for await event in events {
                if case .libraryChanged = event {
                    self?.state.withLock { Array($0.changes.values) }.forEach { $0.yield() }
                }
            }
        }
        link.onClose { [weak self] _ in
            self?.state.withLock { state in if state.link === link { state.link = nil } }
        }
    }

    /// Stops for good: waiting requests fail.
    public func shutDown() {
        let (link, waiters) = state.withLock { state in
            state.closed = true
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return (state.link, waiters)
        }
        waiters.forEach { $0.resume(throwing: PeerError.closed) }
        link?.close()
    }

    /// The current link, waiting for a reconnection if there isn't one.
    private func currentLink(progress: (@Sendable (Double?, String?) -> Void)?) async throws -> PeerLink {
        if let link = state.withLock({ $0.link.flatMap { $0.isClosed ? nil : $0 } }) { return link }
        progress?(nil, "Waiting for \(displayName)…")
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready = state.withLock { state -> Result<PeerLink, any Error>? in
                    if state.closed { return .failure(PeerError.closed) }
                    if let link = state.link, !link.isClosed { return .success(link) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    /// Sends a request, waiting through disconnections and retrying with the
    /// same key until it's answered.
    func request(_ request: RemoteRequest, key: String = UUID().uuidString, progress: (@Sendable (Double?, String?) -> Void)? = nil) async throws -> RemoteResponse {
        while true {
            let link = try await currentLink(progress: progress)
            do {
                return try await link.request(request, key: key, progress: progress)
            } catch PeerError.closed {
                try Task.checkCancellation()
                continue  // Lost mid-request: the phone finishes it; ask again on the next link.
            }
        }
    }

    /// Only if connected now; for things not worth waiting for, like thumbnails.
    private func requestIfConnected(_ request: RemoteRequest) async -> RemoteResponse? {
        guard let link = state.withLock({ $0.link.flatMap { $0.isClosed ? nil : $0 } }) else { return nil }
        return try? await link.request(request)
    }

    // MARK: Identifying photos

    /// The `PhotoSource` for a photo on the other device.
    func source(for assetID: String) -> PhotoSource {
        let encoded = assetID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? assetID
        let device = hostIdentity.prefix(8).map { String(format: "%02x", $0) }.joined()
        return PhotoSource(url: URL(string: "\(PhotoSource.remoteScheme)://\(device)/\(encoded)")!, key: "remote|\(device)|\(assetID)")
    }

    func assetID(for source: PhotoSource) throws -> String {
        guard source.isRemote, let id = source.url.lastPathComponent.removingPercentEncoding else { throw DecodeError.unreadable(source.url) }
        return id
    }

    // MARK: PhotoLibrary

    public func authorizationStatus() -> LibraryAuthorization { .authorized }
    public func requestAuthorization() async -> LibraryAuthorization { .authorized }

    public func albums() async -> [LibraryAlbum] {
        guard case .albums(let albums)? = try? await request(.albums) else { return [] }
        return albums
    }

    public func assets(in album: LibraryAlbum) async -> AssetList {
        guard case .assets(let assets)? = try? await request(.assets(album)) else { return .empty }
        return AssetList(assets)
    }

    public func thumbnail(for asset: PhotoAsset, pixelSize: CGSize) async -> CGImage? {
        let pixels = Int(max(pixelSize.width, pixelSize.height))
        let cacheKey = "\(asset.id)|\(pixels)|\(asset.hasAdjustments)"
        if case .image(let data?)? = await requestIfConnected(.thumbnail(assetID: asset.id, pixels: pixels)) {
            thumbnails.withLock { cache in
                if cache.count > 2000 { cache.removeAll() }
                cache[cacheKey] = data
            }
            return Self.image(data)
        }
        // Disconnected: what we saw last.
        return thumbnails.withLock { $0[cacheKey] }.flatMap(Self.image)
    }

    public func quickPreview(for asset: PhotoAsset, maxPixelSize: Int) async -> CGImage? {
        guard case .image(let data?)? = await requestIfConnected(.quickPreview(assetID: asset.id, maxPixelSize: maxPixelSize)) else { return nil }
        return Self.image(data)
    }

    public func beginEditing(_ asset: PhotoAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> EditingSession {
        let info: RemoteSessionInfo
        if !isConnected, let known = infos.withLock({ $0[asset.id] }) {
            // Opened before: keep editing offline. A newer local draft is restored on top.
            info = known
        } else {
            guard case .session(let fresh) = try await request(.beginEditing(assetID: asset.id), progress: { fraction, _ in
                if let fraction { progress(fraction) }
            }) else { throw PeerError.badFrame }
            info = fresh
            infos.withLock { $0[asset.id] = fresh }
        }
        var stored = info.stored
        // Keep the photo's identity from the phone, which has the file to hash.
        if case .ours(var recipe) = stored, recipe.photoID == .pending, let id = info.photoID {
            recipe.photoID = PhotoID(rawValue: id)
            stored = .ours(recipe)
        }
        // A save still waiting in the outbox is newer than what the phone has.
        if let pending = outbox.entry(for: asset.id) { stored = .ours(pending.recipe) }
        return EditingSession(asset: info.asset, filename: info.filename, original: source(for: asset.id), stored: stored)
    }

    public func storedEdit(for asset: PhotoAsset) async -> StoredEdit {
        if let pending = outbox.entry(for: asset.id) { return .ours(pending.recipe) }
        guard case .stored(let stored)? = try? await request(.storedEdit(assetID: asset.id)) else { return .none }
        return stored
    }

    /// The phone renders its own saves; the rendering passed in isn't needed.
    public func save(_ session: EditingSession, recipe: Recipe, rendered: Data, format: ExportFormat) async throws {
        try await saveEdit(session, recipe: recipe, luts: [], progress: { _, _ in })
    }

    public func saveBatch(_ edits: [PendingEdit]) async throws {
        for edit in edits { try await saveEdit(edit.session, recipe: edit.recipe, luts: [], progress: { _, _ in }) }
    }

    public func revert(_ asset: PhotoAsset) async throws {
        outbox.remove(asset.id)
        _ = try await request(.revert(assetID: asset.id))
    }

    public func addPhoto(fileAt url: URL, rawAlternate: URL?) async throws {
        throw LibraryError.saveFailed("Import photos on \(displayName) itself.")
    }

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            state.withLock { $0.changes[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.changes.removeValue(forKey: id) }
            }
        }
    }

    // MARK: RemoteDecoding

    public func info(for source: PhotoSource) async throws -> SourceInfo {
        let id = try assetID(for: source)
        if let known = infos.withLock({ $0[id] }) { return known.info }
        guard case .session(let info) = try await request(.beginEditing(assetID: id)) else { throw PeerError.badFrame }
        infos.withLock { $0[id] = info }
        return info.info
    }

    public func decode(_ source: PhotoSource, rawStage: RawStageParams, longEdge: Int) async throws -> DecodedImage {
        guard case .decoded(let compressed) = try await request(.decode(assetID: try assetID(for: source), rawStage: rawStage, longEdge: longEdge)),
              let bytes = try? (compressed as NSData).decompressed(using: .lzfse) as Data,
              let decoded = DecodedImage(serialized: bytes)
        else { throw DecodeError.renderFailed }
        return decoded
    }

    // MARK: Work done on the other device

    /// Saves through the outbox: kept on disk until the phone confirms, so an
    /// edit survives disconnections and this app being closed.
    public func saveEdit(_ session: EditingSession, recipe: Recipe, luts: [LUTFile], progress: @escaping @Sendable (Double?, String?) -> Void) async throws {
        let entry = outbox.add(assetID: try assetID(for: session.original), recipe: recipe, luts: luts)
        try await send(entry, progress: progress)
    }

    /// Sends one outbox entry; removes it once the phone has saved it.
    public func send(_ entry: RemoteOutbox.Entry, progress: @escaping @Sendable (Double?, String?) -> Void) async throws {
        _ = try await request(.save(assetID: entry.assetID, recipe: entry.recipe, luts: entry.luts), key: entry.key, progress: progress)
        outbox.remove(entry.assetID, ifKey: entry.key)
    }

    /// Renders an export on the other device and returns it as a local file.
    public func export(_ session: EditingSession, recipe: Recipe, options: ExportOptions, luts: [LUTFile],
                       progress: @escaping @Sendable (Double?, String?) -> Void) async throws -> URL {
        guard case .file(let name, let data) = try await request(
            .export(assetID: try assetID(for: session.original), recipe: recipe, options: options, luts: luts), progress: progress)
        else { throw PeerError.badFrame }
        let directory = FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try data.write(to: url, options: .atomic)
        return url
    }

    public func exportToLibrary(_ session: EditingSession, recipe: Recipe, options: ExportOptions, luts: [LUTFile],
                                progress: @escaping @Sendable (Double?, String?) -> Void) async throws {
        _ = try await request(.exportToLibrary(assetID: try assetID(for: session.original), recipe: recipe, options: options, luts: luts), progress: progress)
    }

    /// Computes `recipe`'s AI masks on the other device and caches them in `store`.
    public func computeAIMasks(_ session: EditingSession, recipe: Recipe, into store: AIMaskStore) async throws {
        guard case .masks(let masks) = try await request(.aiMasks(assetID: try assetID(for: session.original), recipe: recipe)) else { throw PeerError.badFrame }
        for mask in masks { store.insert(png: mask.png, for: mask.shape) }
    }

    /// Computes `recipe`'s Remove fills on the other device and caches them in `store`.
    public func computeFills(_ session: EditingSession, recipe: Recipe, into store: InpaintStore,
                             progress: @escaping @Sendable (Double?, String?) -> Void) async throws {
        guard case .fills(let fills) = try await request(.fills(assetID: try assetID(for: session.original), recipe: recipe), progress: progress)
        else { throw PeerError.badFrame }
        for fill in fills { store.insert(fill) }
    }

    public func bulk(_ change: BulkChange, assets: [PhotoAsset], luts: [LUTFile], progress: @escaping @Sendable (Double?, String?) -> Void) async throws -> Int {
        guard case .done(let count) = try await request(.bulk(change: change, assetIDs: assets.map(\.id), luts: luts), progress: progress)
        else { throw PeerError.badFrame }
        return count
    }

    static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Edits made on this device for another device's photos, kept on disk until
/// that device confirms it saved them. One entry per photo: a newer edit
/// replaces an older one that hasn't gone out yet.
public final class RemoteOutbox: @unchecked Sendable {
    public struct Entry: Codable, Sendable, Hashable {
        public var assetID: String
        public var recipe: Recipe
        public var luts: [LUTFile]
        /// The save's idempotency key; changes with every new edit.
        public var key: String
    }

    private let file: URL?
    private let entries: Mutex<[String: Entry]>

    public static var defaultDirectory: URL? {
        URL.applicationSupportDirectory.appending(path: "Remote/Outbox", directoryHint: .isDirectory)
    }

    init(host: Data, directory: URL?) {
        let name = SHA256.hash(data: host).prefix(8).map { String(format: "%02x", $0) }.joined()
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        file = directory?.appending(path: "\(name).json")
        let saved = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = Mutex(saved)
    }

    public var pending: [Entry] { entries.withLock { Array($0.values) } }
    public var isEmpty: Bool { entries.withLock { $0.isEmpty } }

    public func entry(for assetID: String) -> Entry? { entries.withLock { $0[assetID] } }

    func add(assetID: String, recipe: Recipe, luts: [LUTFile]) -> Entry {
        let entry = Entry(assetID: assetID, recipe: recipe, luts: luts, key: UUID().uuidString)
        entries.withLock { $0[assetID] = entry }
        persist()
        return entry
    }

    /// Removes the entry, unless a newer edit replaced it (`key` no longer matches).
    func remove(_ assetID: String, ifKey key: String? = nil) {
        entries.withLock { entries in
            if let key, entries[assetID]?.key != key { return }
            entries[assetID] = nil
        }
        persist()
    }

    private func persist() {
        guard let file, let data = try? JSONEncoder().encode(entries.withLock({ $0 })) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

extension Recipe {
    /// The LUTs this recipe uses, to send with renders done on another device.
    public func lutFiles(from store: LUTStore) -> [LUTFile] {
        guard case .lut(let ref, _)? = self[.lut], let data = store.data(for: ref) else { return [] }
        return [LUTFile(hash: ref.hash, name: ref.name, data: data)]
    }
}
