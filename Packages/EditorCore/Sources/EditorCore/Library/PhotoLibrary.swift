import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// A photo in the library, independent of PhotoKit so views and tests don't need it.
public struct PhotoAsset: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var creationDate: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var hasAdjustments: Bool
    public var isFavorite: Bool

    public init(id: String, creationDate: Date? = nil, pixelWidth: Int = 0, pixelHeight: Int = 0, hasAdjustments: Bool = false, isFavorite: Bool = false) {
        self.id = id
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.hasAdjustments = hasAdjustments
        self.isFavorite = isFavorite
    }
}

public enum LibraryAlbum: Hashable, Sendable, Identifiable, Codable {
    case raw
    case recents
    case favorites
    case recentlyEdited
    case user(id: String, title: String)

    public var id: String {
        switch self {
        case .raw: "raw"
        case .recents: "recents"
        case .favorites: "favorites"
        case .recentlyEdited: "edited"
        case .user(let id, _): id
        }
    }

    public var title: String {
        switch self {
        case .raw: "RAW"
        case .recents: "All Photos"
        case .favorites: "Favorites"
        case .recentlyEdited: "Recently Edited"
        case .user(_, let title): title
        }
    }

    public var systemImage: String {
        switch self {
        case .raw: "camera.aperture"
        case .recents: "photo.on.rectangle"
        case .favorites: "heart"
        case .recentlyEdited: "slider.horizontal.3"
        case .user: "rectangle.stack"
        }
    }
}

public enum LibraryAuthorization: Sendable {
    case notDetermined, denied, limited, authorized
}

/// A lazily materialized list of assets, so a 50 000-photo album opens instantly.
public final class AssetList: @unchecked Sendable {
    public let count: Int
    private let fetch: (Int) -> PhotoAsset
    private let lock = NSLock()
    private var cache: [Int: PhotoAsset] = [:]

    public init(count: Int, fetch: @escaping (Int) -> PhotoAsset) {
        self.count = count
        self.fetch = fetch
    }

    public convenience init(_ assets: [PhotoAsset]) {
        self.init(count: assets.count) { assets[$0] }
    }

    public static let empty = AssetList([])

    public subscript(index: Int) -> PhotoAsset {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[index] { return hit }
        let asset = fetch(index)
        cache[index] = asset
        return asset
    }

    public func index(of id: String) -> Int? {
        (0..<count).first { self[$0].id == id }
    }
}

/// What the library holds for an asset's edit.
public enum StoredEdit: Sendable, Codable {
    case none
    case ours(Recipe)
    /// Edited in Photos or another app; we can only start from the original.
    case foreign(String)
}

/// An open editing session for one asset: the original on disk and its stored edit.
public struct EditingSession: @unchecked Sendable {
    public var asset: PhotoAsset
    public var filename: String
    public var original: PhotoSource
    public var stored: StoredEdit
    /// Opaque library state needed to save, e.g. a `PHContentEditingInput`.
    public var token: AnyObject?

    public init(asset: PhotoAsset, filename: String, original: PhotoSource, stored: StoredEdit, token: AnyObject? = nil) {
        self.asset = asset
        self.filename = filename
        self.original = original
        self.stored = stored
        self.token = token
    }
}

public enum LibraryError: Error, LocalizedError {
    case notAuthorized
    case noOriginal
    case saveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: "LightEditor doesn't have access to your photos."
        case .noOriginal: "The original file couldn't be loaded."
        case .saveFailed(let reason): "Saving failed: \(reason)"
        }
    }
}

/// The photo library: Apple Photos in the app, or a folder in tests and demos.
public protocol PhotoLibrary: AnyObject, Sendable {
    var displayName: String { get }
    func authorizationStatus() -> LibraryAuthorization
    func requestAuthorization() async -> LibraryAuthorization
    func albums() async -> [LibraryAlbum]
    func assets(in album: LibraryAlbum) async -> AssetList
    /// A small square-ish thumbnail for grids and filmstrips.
    func thumbnail(for asset: PhotoAsset, pixelSize: CGSize) async -> CGImage?
    /// The asset's current rendition, shown instantly while the original loads.
    func quickPreview(for asset: PhotoAsset, maxPixelSize: Int) async -> CGImage?
    /// Fetches the original (downloading it from iCloud if needed) and the stored edit.
    func beginEditing(_ asset: PhotoAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> EditingSession
    /// Reads only the stored edit, for bulk edits that build on it.
    func storedEdit(for asset: PhotoAsset) async -> StoredEdit
    /// Saves a non-destructive edit: the rendered image plus the recipe as adjustment data.
    func save(_ session: EditingSession, recipe: Recipe, rendered: Data, format: ExportFormat) async throws
    /// Saves many edits in one library change, so Photos asks for permission once.
    func saveBatch(_ edits: [PendingEdit]) async throws
    func revert(_ asset: PhotoAsset) async throws
    /// Adds a file to the library as a new photo. A RAW+JPEG pair becomes one asset,
    /// with the RAW as the alternate resource, as the camera app does.
    func addPhoto(fileAt url: URL, rawAlternate: URL?) async throws
    /// Yields whenever the library changes.
    func changes() -> AsyncStream<Void>
}

extension PhotoLibrary {
    public func addPhoto(fileAt url: URL) async throws {
        try await addPhoto(fileAt: url, rawAlternate: nil)
    }
}

/// Imports camera files, pairing RAW+JPEG shots that share a base name.
public enum PhotoImporter {
    public struct Group: Sendable, Hashable {
        public var primary: URL
        public var rawAlternate: URL?
    }

    public static func groups(for urls: [URL]) -> [Group] {
        func isRAW(_ url: URL) -> Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) ?? false }
        func isImage(_ url: URL) -> Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false }
        let images = urls.filter(isImage)
        let byName = Dictionary(grouping: images) { $0.deletingPathExtension().lastPathComponent.lowercased() }
        return byName.keys.sorted().compactMap { name in
            let files = byName[name]!
            let raw = files.first(where: isRAW)
            let processed = files.first { !isRAW($0) }
            if let processed { return Group(primary: processed, rawAlternate: raw) }
            if let raw { return Group(primary: raw, rawAlternate: nil) }
            return nil
        }
    }

    /// Imports every group, reporting progress; returns the number of assets created.
    public static func importFiles(_ urls: [URL], into library: any PhotoLibrary, progress: @Sendable (Double) -> Void) async throws -> Int {
        let groups = groups(for: urls)
        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()
            try await library.addPhoto(fileAt: group.primary, rawAlternate: group.rawAlternate)
            progress(Double(index + 1) / Double(max(groups.count, 1)))
        }
        return groups.count
    }
}

/// One edit waiting to be committed by `saveBatch`.
public struct PendingEdit: @unchecked Sendable {
    public var session: EditingSession
    public var recipe: Recipe
    public var rendered: Data
    public var format: ExportFormat

    public init(session: EditingSession, recipe: Recipe, rendered: Data, format: ExportFormat) {
        self.session = session
        self.recipe = recipe
        self.rendered = rendered
        self.format = format
    }
}

/// The format of our recipe inside `PHAdjustmentData`.
public enum AdjustmentFormat {
    public static let identifier = "app.raweditor.recipe"
    public static let version = "1"

    /// Recipes are zlib-compressed JSON to stay well under Photos' size limit.
    public static func encode(_ recipe: Recipe) throws -> Data {
        try (RecipeCodec.encode(recipe) as NSData).compressed(using: .zlib) as Data
    }

    public static func decode(_ data: Data) throws -> Recipe {
        let json = (try? (data as NSData).decompressed(using: .zlib) as Data) ?? data
        return try RecipeCodec.decode(json)
    }

    public static func canHandle(identifier: String, version: String) -> Bool {
        identifier == self.identifier && (Int(version) ?? Int.max) <= (Int(self.version) ?? 0)
    }
}
