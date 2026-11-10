#if DEBUG
import CoreImage
import EditorCore
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Debug-only spike: `-PhotosCopySpike YES` saves an edit whose rendered image is
/// smaller than the original (12 MP, quality 0.8) to the first RAW in the library,
/// then reads it back the ways Photos and other apps do, reverts, and saves again.
/// Logs `SPIKE` lines. Run it in a simulator, never against a real library.
enum PhotosCopySpike {
    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "PhotosCopySpike") else { return }
        Task.detached(priority: .userInitiated) { await run() }
    }

    static func log(_ line: String) { print("SPIKE \(line)") }

    static func run() async {
        do {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            let all = PHAsset.fetchAssets(with: .image, options: nil)
            var target: PHAsset?
            all.enumerateObjects { asset, _, stop in
                let raw = PHAssetResource.assetResources(for: asset).contains {
                    UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true
                }
                if raw { target = asset; stop.pointee = true }
            }
            guard let asset = target else { log("no RAW in the library"); return }
            log("asset \(asset.localIdentifier) \(asset.pixelWidth)x\(asset.pixelHeight) edited=\(asset.hasAdjustments)")
            let library = PhotoKitLibrary()
            try await saveSmall(asset, library: library)
            await inspect(asset.localIdentifier, label: "after small save")
            try await library.revert(PhotoAsset(id: asset.localIdentifier))
            await inspect(asset.localIdentifier, label: "after revert")
            try await saveSmall(asset, library: library)
            await inspect(asset.localIdentifier, label: "after second small save")
            log("done")
        } catch {
            log("FAILED \(error)")
        }
    }

    static func saveSmall(_ asset: PHAsset, library: PhotoKitLibrary) async throws {
        let session = try await library.beginEditing(PhotoAsset(id: asset.localIdentifier)) { _ in }
        let info = try await RawDecoder.shared.info(for: session.original)
        var recipe = Recipe(decoder: DecoderPin(version: info.decoderVersion))
        recipe.set(.exposure, .scalar(0.7), at: HybridLogicalClock(node: "spike").now())
        let options = ExportOptions(format: .heic, longEdge: ExportSizing.longEdge(megapixels: 12, for: info.nativeSize), quality: 0.8)
        let data = try await Exporter.render(source: session.original, recipe: recipe, luts: nil, options: options, priority: .now)
        log("rendered \(dimensions(data)) \(data.count / 1000) KB from native \(Int(info.nativeSize.width))x\(Int(info.nativeSize.height))")
        try await library.save(session, recipe: recipe, rendered: data, format: .heic)
        log("saved")
    }

    static func inspect(_ id: String, label: String) async {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return log("\(label): asset gone") }
        log("\(label): PHAsset \(asset.pixelWidth)x\(asset.pixelHeight) edited=\(asset.hasAdjustments)")
        for resource in PHAssetResource.assetResources(for: asset) {
            let size = (resource.value(forKey: "fileSize") as? Int).map { "\($0 / 1000) KB" } ?? "?"
            log("\(label):   resource type=\(resource.type.rawValue) \(resource.uniformTypeIdentifier) \(resource.originalFilename) \(size)")
        }
        let input: String = await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.canHandleAdjustmentData = { _ in true }
            asset.requestContentEditingInput(with: options) { input, _ in
                guard let input else { return continuation.resume(returning: "none") }
                let url = input.fullSizeImageURL.map { "\($0.lastPathComponent) \(dimensions(url: $0))" } ?? "none"
                continuation.resume(returning: "fullSizeImage=\(url) adjustment=\(input.adjustmentData?.formatIdentifier ?? "none") \(input.adjustmentData?.data.count ?? 0) B")
            }
        }
        log("\(label): editing input \(input)")
        let data: Data? = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .current
            options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
        log("\(label): image data (what sharing gets) \(data.map { "\(dimensions($0)) \($0.count / 1000) KB" } ?? "none")")
        let image: CGSize? = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current
            PHImageManager.default().requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .default, options: options) { image, _ in
                #if os(macOS)
                continuation.resume(returning: image?.size)
                #else
                continuation.resume(returning: image.map { CGSize(width: $0.size.width * $0.scale, height: $0.size.height * $0.scale) })
                #endif
            }
        }
        log("\(label): requestImage max size \(image.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none")")
    }

    static func dimensions(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return "?" }
        return dimensions(source)
    }

    static func dimensions(url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "?" }
        return dimensions(source)
    }

    static func dimensions(_ source: CGImageSource) -> String {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return "\(props?[kCGImagePropertyPixelWidth] ?? "?")x\(props?[kCGImagePropertyPixelHeight] ?? "?")"
    }
}
#endif
