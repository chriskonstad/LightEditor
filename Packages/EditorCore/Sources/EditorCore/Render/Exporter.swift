import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Sendable, Codable, Identifiable {
    case heic, jpeg

    public var id: String { rawValue }
    public var displayName: String { rawValue.uppercased() }
    public var fileExtension: String { self == .heic ? "heic" : "jpg" }
    public var utType: UTType { self == .heic ? .heic : .jpeg }
}

public struct ExportOptions: Sendable, Hashable, Codable {
    public var format: ExportFormat
    /// Long edge in pixels; nil exports at full resolution.
    public var longEdge: Int?
    public var quality: Double

    public init(format: ExportFormat = .heic, longEdge: Int? = nil, quality: Double = 0.9) {
        self.format = format
        self.longEdge = longEdge
        self.quality = quality
    }

}

/// Export sizes by megapixels, and file-size estimates.
public enum ExportSizing {
    /// Offered below full size, when smaller than the photo.
    public static let megapixelPresets: [Double] = [24, 12, 6, 2]

    /// The long edge that gives about `megapixels` for an output of `size`.
    public static func longEdge(megapixels: Double, for size: CGSize) -> Int {
        let long = max(size.width, size.height), short = max(min(size.width, size.height), 1)
        return Int((megapixels * 1_000_000 * long / short).squareRoot().rounded())
    }

    /// The output size for a long edge (never larger than the full size).
    public static func size(longEdge: Int?, full: CGSize) -> CGSize {
        let long = max(full.width, full.height)
        guard let longEdge, long > 0, Double(longEdge) < long else { return full }
        let scale = Double(longEdge) / long
        return CGSize(width: (full.width * scale).rounded(), height: (full.height * scale).rounded())
    }

    /// Estimates the encoded size of a `target`-pixel export from a small sample
    /// encoded with the same format and quality.
    ///
    /// Measured on A7R V files, bytes per pixel barely change from 2 MP to full
    /// size, and run about 0.8× the 1024-pixel sample's (which packs more detail
    /// into each pixel). Within about 15%.
    public static func estimatedBytes(sampleBytes: Int, samplePixels: Double, targetPixels: Double) -> Int {
        guard samplePixels > 0, targetPixels > 0 else { return 0 }
        return Int(Double(sampleBytes) / samplePixels * 0.8 * targetPixels)
    }

    /// Encodes `image` (already small) as an export would, and returns its size in bytes.
    public static func sampleBytes(_ image: CIImage, format: ExportFormat, quality: Double) -> Int? {
        let image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let context = RenderContext.background
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        switch format {
        case .heic: return context.heifRepresentation(of: image, format: .RGBA8, colorSpace: RenderContext.displayP3, options: options)?.count
        case .jpeg: return context.jpegRepresentation(of: image, colorSpace: RenderContext.displayP3, options: options)?.count
        }
    }
}

/// Runs full-size renders one at a time, in order. A 61 MP RAW can need over a
/// gigabyte while it renders, and two at once can exceed an iPhone's memory limit.
public actor RenderGate {
    public static let fullSize = RenderGate()

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Runs `work` once the renders queued before it finish. `queued` is called
    /// first if it has to wait.
    public func run<T: Sendable>(queued: @Sendable () -> Void = {}, _ work: @Sendable () async throws -> T) async throws -> T {
        if busy {
            queued()
            await withCheckedContinuation { waiting.append($0) }
        }
        busy = true
        defer {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await work()
    }
}

/// Full-resolution renders for export and for saving to Photos, through the same
/// grade graph as the preview so colors match.
public enum Exporter {
    /// Renders the recipe and returns encoded image data. Reports coarse progress.
    public static func render(
        source: PhotoSource,
        recipe: Recipe,
        luts: (any LUTProvider)?,
        options: ExportOptions,
        decoder: RawDecoder = .shared,
        queued: @Sendable () -> Void = {},
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> Data {
        try await RenderGate.fullSize.run(queued: queued) {
            try await renderNow(source: source, recipe: recipe, luts: luts, options: options, decoder: decoder, progress: progress)
        }
    }

    private static func renderNow(
        source: PhotoSource,
        recipe: Recipe,
        luts: (any LUTProvider)?,
        options: ExportOptions,
        decoder: RawDecoder,
        progress: @Sendable (Double) -> Void
    ) async throws -> Data {
        let signpostID = Signposts.export.makeSignpostID()
        let state = Signposts.export.beginInterval("Export", id: signpostID, "\(source.url.lastPathComponent, privacy: .public)")
        defer { Signposts.export.endInterval("Export", state) }

        progress(0.05)
        // Decode enough pixels that the crop still fills the requested size.
        var cropFraction = 1.0
        if case .crop(let geometry)? = recipe[.crop] { cropFraction = max(geometry.rect.width, geometry.rect.height, 0.05) }
        let decodeEdge = options.longEdge.map { Int((Double($0) / cropFraction).rounded(.up)) }
        let (base, info) = try await decoder.lazyImage(source, rawStage: recipe.rawStage, longEdge: decodeEdge)
        try Task.checkCancellation()
        progress(0.3)

        var recipe = recipe
        if case .crop(let geometry)? = recipe[.crop], geometry.auto?.isResolved == false,
           let decoded = try? await decoder.decode(source, rawStage: recipe.analysisStage, longEdge: 1024),
           let resolved = await AutoStraightener.resolve(recipe, source: source, image: decoded.image, stamp: HLCStamp(millis: 0, node: "export")) {
            recipe = resolved
        }
        let aiMasks = try await prepareAIMasks(recipe, source: source, decoder: decoder)
        var inputs = GradeInputs(defaults: info.defaults, luts: luts, aiMasks: aiMasks)
        inputs.inpaints = try await prepareInpaints(recipe, source: source, decoder: decoder)
        var image = GradeGraph.apply(recipe, to: base, inputs: inputs)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let longEdge = options.longEdge {
            let scale = Double(longEdge) / max(image.extent.width, image.extent.height)
            if scale < 1 {
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            }
        }
        try Task.checkCancellation()
        progress(0.4)

        let context = RenderContext.background
        let quality = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: options.quality]
        let data: Data?
        switch options.format {
        case .heic:
            data = context.heifRepresentation(of: image, format: .RGBA8, colorSpace: RenderContext.displayP3, options: quality)
        case .jpeg:
            data = context.jpegRepresentation(of: image, colorSpace: RenderContext.displayP3, options: quality)
        }
        guard let data else { throw DecodeError.renderFailed }
        progress(1)
        return data
    }

    /// Makes sure every AI mask in the recipe is computed (they're cached per photo),
    /// so exports and bulk edits never silently drop a mask.
    public static func prepareAIMasks(_ recipe: Recipe, source: PhotoSource, decoder: RawDecoder = .shared) async throws -> AIMaskStore? {
        guard recipe.masks.contains(where: \.usesAI) else { return nil }
        let store = AIMaskStore.store(for: recipe.analysisKey(for: source.key))
        let base = try await decoder.decode(source, rawStage: recipe.analysisStage, longEdge: 2560)
        try await store.prepare(recipe, base: base.image)
        return store
    }

    /// Computes any missing AI fills for Remove spots (cached per photo).
    public static func prepareInpaints(_ recipe: Recipe, source: PhotoSource, decoder: RawDecoder = .shared) async throws -> InpaintStore? {
        guard recipe.retouches.contains(where: { $0.kind == .remove }) else { return nil }
        let store = InpaintStore.store(for: recipe.analysisKey(for: source.key))
        let base = try await decoder.decode(source, rawStage: recipe.analysisStage, longEdge: 2560)
        let stage = recipe.analysisStage
        try await store.prepare(recipe, preview: base.image, fullResolution: {
            try await decoder.lazyImage(source, rawStage: stage, longEdge: nil).0
        })
        return store
    }

    /// Renders to a temporary file named after the original.
    public static func renderToFile(
        source: PhotoSource,
        recipe: Recipe,
        luts: (any LUTProvider)?,
        options: ExportOptions,
        baseName: String,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let data = try await render(source: source, recipe: recipe, luts: luts, options: options, progress: progress)
        let directory = FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(baseName).\(options.format.fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }
}
