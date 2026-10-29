import CoreImage
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import Photos
import UniformTypeIdentifiers

/// Apple Photos as the library.
///
/// Edits are saved the Photos way: the original is untouched, the rendered result
/// goes in `PHContentEditingOutput`, and our recipe rides along as
/// `PHAdjustmentData`. iCloud Photos syncs all three, and Revert in Photos works.
public final class PhotoKitLibrary: PhotoLibrary, @unchecked Sendable {
    public let displayName = "Photos"
    private let imageManager = PHCachingImageManager()
    private let originals: URL

    public init() {
        originals = URL.cachesDirectory.appending(path: "Originals", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        trimOriginals(limit: 3 << 30)
    }

    /// Originals downloaded for editing are a cache; Photos keeps the real copy.
    /// Keeps the most recently used ones under `limit` bytes.
    private func trimOriginals(limit: Int) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentAccessDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: originals, includingPropertiesForKeys: Array(keys)) else { return }
        var entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentAccessDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > limit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    public func authorizationStatus() -> LibraryAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAuthorization() async -> LibraryAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    private static func map(_ status: PHAuthorizationStatus) -> LibraryAuthorization {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    // MARK: Browsing

    public func albums() async -> [LibraryAlbum] {
        var albums: [LibraryAlbum] = [.raw, .recents, .favorites, .recentlyEdited]
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let user = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        user.enumerateObjects { collection, _, _ in
            albums.append(.user(id: collection.localIdentifier, title: collection.localizedTitle ?? "Album"))
        }
        return albums
    }

    public func assets(in album: LibraryAlbum) async -> AssetList {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result: PHFetchResult<PHAsset>
        switch album {
        case .raw:
            result = fetch(smartAlbum: .smartAlbumRAW, options: options)
        case .recents:
            result = PHAsset.fetchAssets(with: options)
        case .favorites:
            result = fetch(smartAlbum: .smartAlbumFavorites, options: options)
        case .recentlyEdited:
            options.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false)]
            options.fetchLimit = 500
            let recent = PHAsset.fetchAssets(with: options)
            var edited: [PhotoAsset] = []
            recent.enumerateObjects { asset, _, _ in
                if asset.adjustmentFormatIdentifier == AdjustmentFormat.identifier { edited.append(Self.makeAsset(asset)) }
            }
            return AssetList(edited)
        case .user(let id, _):
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
                return .empty
            }
            result = PHAsset.fetchAssets(in: collection, options: options)
        }
        return AssetList(count: result.count) { Self.makeAsset(result.object(at: $0)) }
    }

    private func fetch(smartAlbum subtype: PHAssetCollectionSubtype, options: PHFetchOptions) -> PHFetchResult<PHAsset> {
        guard let collection = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject else {
            return PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil)
        }
        return PHAsset.fetchAssets(in: collection, options: options)
    }

    static func makeAsset(_ asset: PHAsset) -> PhotoAsset {
        PhotoAsset(
            id: asset.localIdentifier,
            creationDate: asset.creationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            hasAdjustments: asset.hasAdjustments,
            isFavorite: asset.isFavorite
        )
    }

    private func phAsset(_ asset: PhotoAsset) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [asset.id], options: nil).firstObject
    }

    public func thumbnail(for asset: PhotoAsset, pixelSize: CGSize) async -> CGImage? {
        guard let phAsset = phAsset(asset) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await requestImage(phAsset, size: pixelSize, contentMode: .aspectFill, options: options)
    }

    public func quickPreview(for asset: PhotoAsset, maxPixelSize: Int) async -> CGImage? {
        guard let phAsset = phAsset(asset) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = false
        let size = CGSize(width: maxPixelSize, height: maxPixelSize)
        return await requestImage(phAsset, size: size, contentMode: .aspectFit, options: options)
    }

    private func requestImage(_ asset: PHAsset, size: CGSize, contentMode: PHImageContentMode, options: PHImageRequestOptions) async -> CGImage? {
        let manager = imageManager
        let stream = AsyncStream<CGImage?> { continuation in
            let id = manager.requestImage(for: asset, targetSize: size, contentMode: contentMode, options: options) { image, info in
                #if os(macOS)
                let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                #else
                let cgImage = image?.cgImage
                #endif
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                continuation.yield(cgImage)
                if !degraded || info?[PHImageErrorKey] != nil || (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in manager.cancelImageRequest(id) }
        }
        var best: CGImage?
        for await image in stream where image != nil { best = image }
        return best
    }

    // MARK: Editing

    public func beginEditing(_ asset: PhotoAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> EditingSession {
        guard let phAsset = phAsset(asset) else { throw LibraryError.noOriginal }
        let signpostID = Signposts.library.makeSignpostID()
        let state = Signposts.library.beginInterval("BeginEditing", id: signpostID)
        defer { Signposts.library.endInterval("BeginEditing", state) }

        async let input = contentEditingInput(phAsset)
        let (resource, filename) = try originalResource(phAsset)
        let url = try await download(resource, asset: phAsset, progress: progress)
        let editingInput = try await input

        var stored = StoredEdit.none
        if let data = editingInput?.adjustmentData, AdjustmentFormat.canHandle(identifier: data.formatIdentifier, version: data.formatVersion) {
            stored = (try? .ours(AdjustmentFormat.decode(data.data))) ?? .none
        } else if phAsset.hasAdjustments {
            stored = .foreign(phAsset.adjustmentFormatIdentifier ?? "another app")
        }
        let key = "\(phAsset.localIdentifier)|\(filename)"
        return EditingSession(
            asset: Self.makeAsset(phAsset),
            filename: filename,
            original: PhotoSource(url: url, key: key),
            stored: stored,
            token: editingInput
        )
    }

    public func storedEdit(for asset: PhotoAsset) async -> StoredEdit {
        guard let phAsset = phAsset(asset) else { return .none }
        guard phAsset.hasAdjustments else { return .none }
        guard phAsset.adjustmentFormatIdentifier == AdjustmentFormat.identifier else {
            return .foreign(phAsset.adjustmentFormatIdentifier ?? "another app")
        }
        guard let input = try? await contentEditingInput(phAsset), let data = input.adjustmentData,
              let recipe = try? AdjustmentFormat.decode(data.data) else { return .none }
        return .ours(recipe)
    }

    /// Picks the RAW resource when there is one (RAW-only or RAW+JPEG), else the photo.
    private func originalResource(_ asset: PHAsset) throws -> (PHAssetResource, String) {
        let resources = PHAssetResource.assetResources(for: asset)
        func isRAW(_ resource: PHAssetResource) -> Bool {
            UTType(resource.uniformTypeIdentifier)?.conforms(to: .rawImage) ?? false
        }
        let originals = resources.filter { [.photo, .alternatePhoto].contains($0.type) }
        guard let chosen = originals.first(where: isRAW) ?? originals.first(where: { $0.type == .photo }) ?? originals.first else {
            throw LibraryError.noOriginal
        }
        return (chosen, chosen.filename ?? "Photo")
    }

    private func download(_ resource: PHAssetResource, asset: PHAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let safeID = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        let url = originals.appending(path: "\(safeID)-\(resource.filename ?? "original")")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let partial = url.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value in progress(value) }
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: partial, options: options)
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }

    private func contentEditingInput(_ asset: PHAsset) async throws -> PHContentEditingInput? {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { data in
            AdjustmentFormat.canHandle(identifier: data.formatIdentifier, version: data.formatVersion)
        }
        let box = UncheckedBox(asset)
        return await withCheckedContinuation { continuation in
            box.value.requestContentEditingInput(with: options) { input, _ in
                continuation.resume(returning: UncheckedBox(input))
            }
        }.value
    }

    public func save(_ session: EditingSession, recipe: Recipe, rendered: Data, format: ExportFormat) async throws {
        try await saveBatch([PendingEdit(session: session, recipe: recipe, rendered: rendered, format: format)])
    }

    public func saveBatch(_ edits: [PendingEdit]) async throws {
        var changes: [(PHAsset, PHContentEditingOutput)] = []
        for edit in edits {
            guard let phAsset = phAsset(edit.session.asset) else { throw LibraryError.noOriginal }
            guard let input = edit.session.token as? PHContentEditingInput else { throw LibraryError.saveFailed("no editing input") }
            let output = PHContentEditingOutput(contentEditingInput: input)
            output.adjustmentData = PHAdjustmentData(
                formatIdentifier: AdjustmentFormat.identifier,
                formatVersion: AdjustmentFormat.version,
                data: try AdjustmentFormat.encode(edit.recipe)
            )
            let type: UTType = output.supportedRenderedContentTypes.contains(edit.format.utType)
                ? edit.format.utType : (output.defaultRenderedContentType ?? .jpeg)
            try edit.rendered.write(to: try output.renderedContentURL(for: type), options: .atomic)
            changes.append((phAsset, output))
        }
        let box = UncheckedBox(changes)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for (asset, output) in box.value {
                    PHAssetChangeRequest(for: asset).contentEditingOutput = output
                }
            }
        } catch {
            throw LibraryError.saveFailed(error.localizedDescription)
        }
    }

    public func revert(_ asset: PhotoAsset) async throws {
        guard let phAsset = phAsset(asset) else { throw LibraryError.noOriginal }
        let box = UncheckedBox(phAsset)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: box.value).revertAssetContentToOriginal()
        }
    }

    public func addPhoto(fileAt url: URL, rawAlternate: URL?) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = url.lastPathComponent
            request.addResource(with: .photo, fileURL: url, options: options)
            if let rawAlternate {
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.originalFilename = rawAlternate.lastPathComponent
                request.addResource(with: .alternatePhoto, fileURL: rawAlternate, options: rawOptions)
            }
        }
    }

    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observer = ChangeObserver { continuation.yield() }
            PHPhotoLibrary.shared().register(observer)
            continuation.onTermination = { @Sendable _ in PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
        }
    }

    private final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
        let handler: @Sendable () -> Void
        init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
        func photoLibraryDidChange(_ changeInstance: PHChange) { handler() }
    }
}
