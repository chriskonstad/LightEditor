import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A folder of image files acting as the library.
///
/// Used by tests, UI automation and demos, so none of them touch a real Photos
/// library. Edits are stored next to the files in a `.raweditor` folder: the recipe
/// as JSON and the rendered result, mirroring what Photos keeps.
public final class FolderLibrary: PhotoLibrary, @unchecked Sendable {
    public let directory: URL
    public var displayName: String { directory.lastPathComponent }
    private let sidecars: URL
    private let continuations = NSLock()
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(directory: URL) {
        self.directory = directory
        sidecars = directory.appending(path: ".raweditor", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: sidecars, withIntermediateDirectories: true)
    }

    public func authorizationStatus() -> LibraryAuthorization { .authorized }
    public func requestAuthorization() async -> LibraryAuthorization { .authorized }

    public func albums() async -> [LibraryAlbum] { [.raw, .recents, .recentlyEdited] }

    private func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func assets(in album: LibraryAlbum) async -> AssetList {
        let assets = files().compactMap { url -> PhotoAsset? in
            let isRAW = UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) ?? false
            let edited = FileManager.default.fileExists(atPath: recipeURL(url.lastPathComponent).path)
            switch album {
            case .raw where !isRAW: return nil
            case .recentlyEdited where !edited: return nil
            case .favorites, .user: return nil
            default: break
            }
            return PhotoAsset(id: url.lastPathComponent, hasAdjustments: edited)
        }
        return AssetList(assets)
    }

    private func url(for asset: PhotoAsset) -> URL { directory.appending(path: asset.id) }
    private func recipeURL(_ name: String) -> URL { sidecars.appending(path: "\(name).recipe.json") }
    private func renderedURL(_ name: String) -> URL { sidecars.appending(path: "\(name).rendered") }

    public func thumbnail(for asset: PhotoAsset, pixelSize: CGSize) async -> CGImage? {
        let rendered = renderedURL(asset.id)
        let source = FileManager.default.fileExists(atPath: rendered.path) ? rendered : url(for: asset)
        return EmbeddedPreview.load(source, maxPixelSize: Int(max(pixelSize.width, pixelSize.height)))
    }

    public func quickPreview(for asset: PhotoAsset, maxPixelSize: Int) async -> CGImage? {
        await thumbnail(for: asset, pixelSize: CGSize(width: maxPixelSize, height: maxPixelSize))
    }

    public func beginEditing(_ asset: PhotoAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> EditingSession {
        let file = url(for: asset)
        guard FileManager.default.fileExists(atPath: file.path) else { throw LibraryError.noOriginal }
        progress(1)
        return EditingSession(asset: asset, filename: asset.id, original: PhotoSource(url: file), stored: await storedEdit(for: asset))
    }

    public func storedEdit(for asset: PhotoAsset) async -> StoredEdit {
        guard let data = try? Data(contentsOf: recipeURL(asset.id)) else { return .none }
        return (try? .ours(RecipeCodec.decode(data))) ?? .foreign("unreadable recipe")
    }

    public func save(_ session: EditingSession, recipe: Recipe, rendered: Data, format: ExportFormat) async throws {
        try RecipeCodec.encode(recipe).write(to: recipeURL(session.asset.id), options: .atomic)
        try rendered.write(to: renderedURL(session.asset.id), options: .atomic)
        notify()
    }

    public func saveBatch(_ edits: [PendingEdit]) async throws {
        for edit in edits {
            try RecipeCodec.encode(edit.recipe).write(to: recipeURL(edit.session.asset.id), options: .atomic)
            try edit.rendered.write(to: renderedURL(edit.session.asset.id), options: .atomic)
        }
        notify()
    }

    public func revert(_ asset: PhotoAsset) async throws {
        try? FileManager.default.removeItem(at: recipeURL(asset.id))
        try? FileManager.default.removeItem(at: renderedURL(asset.id))
        notify()
    }

    public func addPhoto(fileAt url: URL, rawAlternate: URL?) async throws {
        for file in [url, rawAlternate].compactMap({ $0 }) {
            let destination = directory.appending(path: file.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file, to: destination)
        }
        notify()
    }

    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            continuations.withLock { observers[id] = continuation }
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.continuations.withLock { _ = self?.observers.removeValue(forKey: id) }
            }
        }
    }

    private func notify() {
        continuations.withLock { observers.values.forEach { $0.yield() } }
    }
}
