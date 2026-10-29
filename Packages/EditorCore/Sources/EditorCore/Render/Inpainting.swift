import CoreGraphics
import CoreImage
import CoreML
import CryptoKit
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

public enum InpaintError: Error, LocalizedError {
    case modelUnavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable: "AI removal isn't available in this build (the LaMa model wasn't bundled)."
        case .failed(let reason): "AI removal failed: \(reason)"
        }
    }
}

/// Runs LaMa (big-lama, Apache-2.0) through Core ML.
///
/// The model package has two functions sharing one set of weights: "full" at
/// 1024×1024 and "fast" at 512×512. An older single-function package works too,
/// at whatever size it was built for.
public final class Inpainter: Sendable {
    public static let shared = Inpainter()
    /// The fast size, and the size of older packages.
    public static let fastSize = 512

    private struct State: @unchecked Sendable {
        var url: URL?
        var compiledURL: URL?
        /// Loaded models by size, and whether they run on the CPU only.
        var models: [ModelKey: MLModel] = [:]
        /// Set when the package has no 1024 "full" function (an older build).
        var fullMissing = false
    }

    private struct ModelKey: Hashable {
        var size: Int
        var cpuOnly: Bool
    }

    /// Held for the whole load and prediction: one fill at a time, so two jobs
    /// never load the model twice or run it side by side (memory on iPhone).
    private let state = Mutex(State())

    /// The compiled model (`.mlmodelc`) or a package (`.mlpackage`, compiled on first use).
    public func configure(modelURL: URL?) {
        state.withLock { $0 = State(url: modelURL) }
    }

    public var isAvailable: Bool { state.withLock { $0.url != nil } }

    /// The size "full" removals run at. Doesn't load anything, so the UI can ask.
    public static let largeSize = 1024
    public var fullSize: Int { state.withLock { $0.fullMissing } ? Self.fastSize : Self.largeSize }

    private static func compiled(_ state: inout State) throws -> URL {
        if let url = state.compiledURL { return url }
        guard var url = state.url else { throw InpaintError.modelUnavailable }
        if url.pathExtension == "mlpackage" { url = try MLModel.compileModel(at: url) }
        state.compiledURL = url
        return url
    }

    private static func configuration(function: String?, units: MLComputeUnits) -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = units
        #endif
        configuration.functionName = function
        return configuration
    }

    /// Where each size runs. The Neural Engine returns noise for the 1024 model
    /// (seen on the iPhone 16 Pro and an M4 Pro: a gray test fill came back with
    /// mean 28 and std 18 instead of 110 and 2), so it runs on CPU+GPU: 1.4 s
    /// per fill on the iPhone 16 Pro, 0.37 s on an M4 Pro. The 512 model is fine
    /// on the Neural Engine. On the Mac, `.all` doesn't even load the 1024
    /// function, which hid this until it ran on a phone.
    static func units(for size: Int) -> MLComputeUnits {
        size > fastSize ? .cpuAndGPU : .all
    }

    /// Loads the model for `size` lazily: function "full" (1024) or "fast" (512),
    /// or an older single-function package.
    private static func model(_ state: inout State, size: Int, cpuOnly: Bool) throws -> MLModel {
        let key = ModelKey(size: size, cpuOnly: cpuOnly)
        if let model = state.models[key] { return model }
        let url = try compiled(&state)
        let units = cpuOnly ? MLComputeUnits.cpuOnly : units(for: size)
        let function = size > fastSize ? "full" : "fast"
        let model: MLModel
        if let named = try? MLModel(contentsOf: url, configuration: configuration(function: function, units: units)) {
            model = named
        } else {
            // A single-function package: one size only.
            model = try MLModel(contentsOf: url, configuration: configuration(function: nil, units: units))
            if size > fastSize { state.fullMissing = true }
        }
        state.models[key] = model
        return model
    }

    private static func inputSize(_ model: MLModel) -> Int {
        model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint?.pixelsWide ?? fastSize
    }

    /// The model size used for `engine`.
    public func size(for engine: RemoveEngine) -> Int {
        engine == .fast ? Self.fastSize : fullSize
    }

    /// Fills the white areas of `mask` in `image`. Both are `size`×`size`; the
    /// image is sRGB. A fill that comes back as noise is retried on the CPU.
    public func inpaint(image: CGImage, mask: CGImage, size: Int) throws -> CGImage {
        try state.withLock { state in
            var model = try Self.model(&state, size: size, cpuOnly: false)
            let chosen = Self.inputSize(model)
            let maskPixels = try Self.grayPixels(mask, size: chosen)
            for attempt in 0..<2 {
                let input = try MLDictionaryFeatureProvider(dictionary: [
                    "image": try MLFeatureValue(cgImage: image, pixelsWide: chosen, pixelsHigh: chosen, pixelFormatType: kCVPixelFormatType_32BGRA, options: nil),
                    "mask": try MLFeatureValue(cgImage: mask, pixelsWide: chosen, pixelsHigh: chosen, pixelFormatType: kCVPixelFormatType_OneComponent8, options: nil),
                ])
                let output = try model.prediction(from: input)
                guard let buffer = output.featureValue(for: "output")?.imageBufferValue else { throw InpaintError.failed("no output") }
                let (pixels, result) = try Self.copyOpaque(buffer)
                if !Self.looksLikeNoise(pixels, mask: maskPixels, size: chosen) { return result }
                if attempt == 0 { model = try Self.model(&state, size: size, cpuOnly: true) }
            }
            throw InpaintError.failed("the fill came out as noise")
        }
    }

    /// An 8-bit gray copy of `image` at `size`×`size`.
    static func grayPixels(_ image: CGImage, size: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size)
        guard let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                      space: CGColorSpace(name: CGColorSpace.linearGray)!, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw InpaintError.failed("couldn't read the mask") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pixels
    }

    /// True when the filled area is far noisier than the rest of the crop, the
    /// signature of a broken compute path (colored speckles on black).
    static func looksLikeNoise(_ bgra: [UInt8], mask: [UInt8], size: Int) -> Bool {
        var inside = 0.0, insideCount = 0.0, outside = 0.0, outsideCount = 0.0
        for y in Swift.stride(from: 0, to: size, by: 2) {
            for x in Swift.stride(from: 0, to: size - 1, by: 2) {
                let i = (y * size + x) * 4, j = i + 4
                // Green carries most of the detail; neighboring-pixel difference measures noise.
                let difference = abs(Double(bgra[i + 1]) - Double(bgra[j + 1]))
                if mask[y * size + x] > 128 { inside += difference; insideCount += 1 } else { outside += difference; outsideCount += 1 }
            }
        }
        guard insideCount > 100 else { return false }
        let insideNoise = inside / insideCount, outsideNoise = outsideCount > 0 ? outside / outsideCount : 0
        return insideNoise > max(outsideNoise * 3, 12)
    }

    /// Copies Core ML's BGRA output into a new opaque image.
    ///
    /// Core ML can hand back the same pixel buffer for the next prediction, and
    /// Core Image caches what it read from a buffer, so reading it through Core
    /// Image could return an earlier fill. Copying the bytes avoids both. Core
    /// ML also leaves alpha at 0; the fill must be opaque.
    static func copyOpaque(_ buffer: CVPixelBuffer) throws -> ([UInt8], CGImage) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer) else { throw InpaintError.failed("unexpected output format") }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let sourceRow = CVPixelBufferGetBytesPerRow(buffer)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let row = base.advanced(by: y * sourceRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = row[x * 4]
                pixels[i + 1] = row[x * 4 + 1]
                pixels[i + 2] = row[x * 4 + 2]
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: RenderContext.sRGB,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw InpaintError.failed("couldn't copy the result") }
        return (pixels, image)
    }
}

/// Computes and caches Remove fills for one photo.
///
/// A fill depends on the spot and every spot before it, so results are keyed by
/// `RetouchRenderer.chainKey`. They're computed from the ungraded preview decode,
/// stored with their normalized region, and placed at any resolution.
public final class InpaintStore: InpaintProvider, @unchecked Sendable {
    static let version = 1

    public let photoKey: String
    private let directory: URL?
    private let cache = Mutex<[String: Patch]>([:])
    private static let stores = Mutex<[String: InpaintStore]>([:])

    struct Patch: @unchecked Sendable, Codable {
        var region: NormalizedRect
        var imageData: Data

        var image: CIImage? { CIImage(data: imageData, options: [.colorSpace: RenderContext.sRGB]) }
    }

    public static func store(for photoKey: String) -> InpaintStore {
        stores.withLock { stores in
            if let existing = stores[photoKey] { return existing }
            if stores.count > 12 { stores.removeAll() }
            let store = InpaintStore(photoKey: photoKey)
            stores[photoKey] = store
            return store
        }
    }

    public init(photoKey: String, directory: URL? = InpaintStore.defaultDirectory) {
        self.photoKey = photoKey
        self.directory = directory
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "Inpaints", directoryHint: .isDirectory)
    }

    private func fileURL(_ key: String) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data("v\(Self.version)|\(photoKey)|\(key)".utf8))
        return directory.appending(path: digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".json")
    }

    private func stored(_ key: String) -> Patch? {
        if let hit = cache.withLock({ $0[key] }) { return hit }
        guard let url = fileURL(key), let data = try? Data(contentsOf: url), let patch = try? JSONDecoder().decode(Patch.self, from: data) else { return nil }
        cache.withLock { $0[key] = patch }
        return patch
    }

    public func hasPatch(for key: String) -> Bool { stored(key) != nil }

    /// Every Remove fill `recipe` has, to send to a device editing remotely.
    public func fills(for recipe: Recipe) -> [RemoteFill] {
        let spots = recipe.retouches
        let keys = RetouchRenderer.chainKeys(spots)
        return spots.indices.compactMap { index in
            guard spots[index].kind == .remove, let patch = stored(keys[index]) else { return nil }
            return RemoteFill(key: keys[index], region: patch.region, png: patch.imageData)
        }
    }

    /// Stores a fill computed on another device.
    public func insert(_ fill: RemoteFill) {
        let patch = Patch(region: fill.region, imageData: fill.png)
        cache.withLock { $0[fill.key] = patch }
        if let url = fileURL(fill.key), let encoded = try? JSONEncoder().encode(patch) {
            try? encoded.write(to: url, options: .atomic)
        }
    }

    public func patch(for key: String, in extent: CGRect) -> CIImage? {
        guard let patch = stored(key), let image = patch.image else { return nil }
        let region = patch.region
        let target = CGRect(
            x: extent.minX + region.x * extent.width, y: extent.minY + (1 - region.y - region.height) * extent.height,
            width: region.width * extent.width, height: region.height * extent.height
        )
        return MaskRenderer.fit(image, to: target)
    }

    /// Computes every missing Remove fill in `recipe`, in order. `preview` is the
    /// ungraded preview decode; `fullResolution` supplies the original at full
    /// size (lazily, only if a spot needs it).
    public func prepare(
        _ recipe: Recipe,
        preview: CIImage,
        fullResolution: (@Sendable () async throws -> CIImage)? = nil,
        progress: @Sendable (Int, Int) -> Void = { _, _ in },
        stepProgress: @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let spots = recipe.retouches
        let keys = RetouchRenderer.chainKeys(spots)
        let pending = spots.indices.filter { spots[$0].kind == .remove && !hasPatch(for: keys[$0]) }
        var full: CIImage?
        for (done, index) in pending.enumerated() {
            try Task.checkCancellation()
            progress(done, pending.count)
            let spot = spots[index]
            var base = preview
            if spot.engine != .fast, let fullResolution {
                if full == nil { full = try await fullResolution() }
                base = full ?? preview
            }
            switch spot.engine {
            case .diffusion:
                try await DiffusionInpainter.shared.fill(spots: spots, index: index, base: base, store: self, progress: stepProgress)
            case .standard, .fast:
                try compute(spots: spots, index: index, base: base)
            }
        }
    }

    /// Back-compatible entry: everything from one image.
    public func prepare(_ recipe: Recipe, base: CIImage, progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws {
        try await prepare(recipe, preview: base, fullResolution: nil, progress: progress)
    }

    /// The crop of `base` a spot's fill works on, in `base`'s pixels.
    func region(for spot: RetouchSpot, modelSize: Int, extent: CGRect) -> (NormalizedRect, CGRect) {
        let region = RetouchRenderer.inpaintRegion(for: spot, imageSize: extent.size, minimumSide: CGFloat(modelSize))
        let rect = CGRect(
            x: extent.minX + region.x * extent.width, y: extent.minY + (1 - region.y - region.height) * extent.height,
            width: region.width * extent.width, height: region.height * extent.height
        )
        return (region, rect)
    }

    /// The model's input and mask for spot `index`: the image the spots before it
    /// produced, cropped around the spot and scaled to `size` (never up).
    func modelInputs(spots: [RetouchSpot], index: Int, base: CIImage, size modelSize: Int) throws -> (image: CGImage, mask: CGImage, region: NormalizedRect) {
        let spot = spots[index]
        let extent = base.extent
        let input = RetouchRenderer.apply(Array(spots[..<index]), to: base, inpaints: self)
        let (region, rect) = region(for: spot, modelSize: modelSize, extent: extent)
        let size = CGFloat(modelSize)
        func toModel(_ image: CIImage) -> CIImage {
            image.cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                .transformed(by: CGAffineTransform(scaleX: size / rect.width, y: size / rect.height))
        }
        let square = CGRect(x: 0, y: 0, width: size, height: size)
        guard let imageCG = RenderContext.background.createCGImage(toModel(input), from: square, format: .RGBA8, colorSpace: RenderContext.sRGB) else {
            throw InpaintError.failed("couldn't prepare the image")
        }
        // Hard-edged and slightly grown, so the fill covers the whole feathered spot.
        let mask = toModel(RetouchRenderer.spotMask(RetouchSpot(order: 0, kind: .remove, strokes: spot.strokes), extent: extent))
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.02])
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 6 * size / 512])
            .cropped(to: square)
        guard let maskCG = RenderContext.background.createCGImage(mask, from: square, format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray)) else {
            throw InpaintError.failed("couldn't prepare the mask")
        }
        return (imageCG, maskCG, region)
    }

    /// Fills spot `index` with LaMa, working on the image the spots before it produced.
    public func compute(spots: [RetouchSpot], index: Int, base: CIImage) throws {
        let spot = spots[index]
        let signpostID = Signposts.render.makeSignpostID()
        let state = Signposts.render.beginInterval("Inpaint", id: signpostID)
        defer { Signposts.render.endInterval("Inpaint", state) }
        let size = Inpainter.shared.size(for: spot.engine)
        let (imageCG, maskCG, region) = try modelInputs(spots: spots, index: index, base: base, size: size)
        let filled = try Inpainter.shared.inpaint(image: imageCG, mask: maskCG, size: size)
        try store(filled, region: region, for: RetouchRenderer.chainKey(spots[...index]))
    }

    /// Saves a fill for the spot chain `key`.
    func store(_ filled: CGImage, region: NormalizedRect, for key: String) throws {

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw InpaintError.failed("couldn't encode the result")
        }
        CGImageDestinationAddImage(destination, filled, nil)
        guard CGImageDestinationFinalize(destination) else { throw InpaintError.failed("couldn't encode the result") }
        let patch = Patch(region: region, imageData: data as Data)
        cache.withLock { $0[key] = patch }
        if let url = fileURL(key), let encoded = try? JSONEncoder().encode(patch) {
            try? encoded.write(to: url, options: .atomic)
        }
    }
}
