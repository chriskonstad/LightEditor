import CoreGraphics
import CoreImage
import CoreML
import Foundation
import Synchronization

/// Remove with diffusion: LaMa decides what goes in the area without
/// inventing anything, then Stable Diffusion 1.5 inpainting re-imagines it at
/// strength 0.6 so it looks like a photo rather than a smear. On its own,
/// diffusion tends to paint a new person or object into the hole; started from
/// LaMa's fill it removes instead (docs/spikes/diffusion-inpaint.md).
///
/// Models come from `scripts/fetch-models.sh`: the 9-channel UNet (6-bit
/// palettized), the VAE encoder and decoder, and the prompt embeddings
/// computed ahead of time, so there's no tokenizer or text encoder.
public final class DiffusionInpainter: Sendable {
    public static let shared = DiffusionInpainter()
    public static let size = 512
    static let latentSize = 64

    /// How it samples. Tuned on real photos.
    public struct Settings: Sendable {
        public var steps = 30
        public var strength = 0.6
        public var guidance: Float = 7.5
    }

    public struct Models: Sendable {
        public var unet: URL
        public var encoder: URL
        public var decoder: URL
        public var embeddings: URL

        public init(unet: URL, encoder: URL, decoder: URL, embeddings: URL) {
            self.unet = unet
            self.encoder = encoder
            self.decoder = decoder
            self.embeddings = embeddings
        }

        /// The app bundle's copies, if this build has them.
        public static func inBundle(_ bundle: Bundle = .main) -> Models? {
            guard let unet = bundle.url(forResource: "SDInpaintUNet", withExtension: "mlmodelc"),
                  let encoder = bundle.url(forResource: "SDInpaintVAEEncoder", withExtension: "mlmodelc"),
                  let decoder = bundle.url(forResource: "SDInpaintVAEDecoder", withExtension: "mlmodelc"),
                  let embeddings = bundle.url(forResource: "SDInpaintEmbeddings", withExtension: "bin")
            else { return nil }
            return Models(unet: unet, encoder: encoder, decoder: decoder, embeddings: embeddings)
        }
    }

    private struct Loaded: @unchecked Sendable {
        var unet: MLModel
        var encoder: MLModel
        var decoder: MLModel
        /// Negative then positive prompt, 77×768 each.
        var embeddings: MLMultiArray
    }

    private struct State: @unchecked Sendable {
        var models: Models?
        var loaded: Loaded?
        var settings = Settings()
    }

    /// Held for a whole fill: one at a time, since the UNet alone needs ~1 GB.
    private let state = Mutex(State())

    public func configure(_ models: Models?) {
        state.withLock { $0 = State(models: models) }
    }

    public var isAvailable: Bool { state.withLock { $0.models != nil } }

    public var settings: Settings {
        get { state.withLock { $0.settings } }
        set { state.withLock { $0.settings = newValue } }
    }

    /// Frees the models (~1 GB) when nothing is being removed.
    public func release() {
        state.withLock { $0.loaded = nil }
    }

    private static func load(_ models: Models) throws -> Loaded {
        func compiled(_ url: URL) throws -> URL {
            url.pathExtension == "mlpackage" ? try MLModel.compileModel(at: url) : url
        }
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = .cpuAndGPU
        #endif
        let unet = try MLModel(contentsOf: compiled(models.unet), configuration: configuration)
        let encoder = try MLModel(contentsOf: compiled(models.encoder), configuration: configuration)
        let decoder = try MLModel(contentsOf: compiled(models.decoder), configuration: configuration)
        let data = try Data(contentsOf: models.embeddings)
        let count = 2 * 77 * 768
        guard data.count == count * 4 else { throw InpaintError.failed("the prompt embeddings are the wrong size") }
        let embeddings = try MLMultiArray(shape: [2, 77, 768], dataType: .float32)
        data.withUnsafeBytes { raw in
            embeddings.withUnsafeMutableBytes { pointer, _ in
                pointer.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw.prefix(count * 4)))
            }
        }
        return Loaded(unet: unet, encoder: encoder, decoder: decoder, embeddings: embeddings)
    }

    // MARK: Filling a spot

    /// Fills spot `index`: LaMa first, then diffusion over its result.
    func fill(spots: [RetouchSpot], index: Int, base: CIImage, store: InpaintStore,
              progress: @Sendable (Double) -> Void = { _ in }) async throws {
        let spot = spots[index]
        let (image, mask, region) = try store.modelInputs(spots: spots, index: index, base: base, size: Self.size)
        // LaMa's fill as the starting point, at the same 512 px.
        let start = Inpainter.shared.isAvailable ? try Inpainter.shared.inpaint(image: image, mask: mask, size: Self.size) : image
        progress(0.05)
        let filled = try await inpaint(image: image, start: start, mask: mask, seed: UInt64(spot.variation), progress: { progress(0.05 + $0 * 0.95) })
        try store.store(filled, region: region, for: RetouchRenderer.chainKey(spots[...index]))
    }

    /// Re-imagines the white area of `mask`, starting from `start` (LaMa's fill)
    /// and conditioned on `image` outside the mask. All 512×512 sRGB.
    public func inpaint(image: CGImage, start: CGImage, mask: CGImage, seed: UInt64,
                        progress: @Sendable (Double) -> Void = { _ in }) async throws -> CGImage {
        let (loaded, settings) = try state.withLock { state -> (Loaded, Settings) in
            if state.loaded == nil {
                guard let models = state.models else { throw InpaintError.failed("diffusion isn't in this build") }
                state.loaded = try Self.load(models)
            }
            return (state.loaded!, state.settings)
        }
        let n = Self.latentSize * Self.latentSize
        let maskValues = try Self.maskLatent(mask)
        // The photo with the area blanked (mid-gray), and LaMa's fill, as latents.
        let maskedLatent = try encode(Self.blanked(image, mask: mask), with: loaded.encoder)
        let startLatent = try encode(start, with: loaded.encoder)

        let sampler = DiffusionSampler(steps: settings.steps, strength: settings.strength)
        var noise = SeededNoise(seed: seed)
        let initial = sampler.noised(startLatent, noise: noise.gaussian(count: 4 * n))
        let sample = try MLMultiArray(shape: [2, 9, 64, 64], dataType: .float32)
        let timestep = try MLMultiArray(shape: [2], dataType: .float32)
        let total = Double(sampler.timesteps.count)
        let latent = try await sampler.sample(from: initial) { x, t, step in
            // Both halves of the batch get the same input; only the prompt differs.
            sample.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
                for half in 0..<2 {
                    let offset = half * 9 * n
                    for i in 0..<(4 * n) { buffer[offset + i] = x[i] }
                    for i in 0..<n { buffer[offset + 4 * n + i] = maskValues[i] }
                    for i in 0..<(4 * n) { buffer[offset + 5 * n + i] = maskedLatent[i] }
                }
            }
            timestep[0] = NSNumber(value: Float(t))
            timestep[1] = NSNumber(value: Float(t))
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "sample": MLFeatureValue(multiArray: sample),
                "timestep": MLFeatureValue(multiArray: timestep),
                "encoder_hidden_states": MLFeatureValue(multiArray: loaded.embeddings),
            ])
            let output = try await loaded.unet.prediction(from: input)
            guard let noisePrediction = output.featureValue(for: "noise")?.multiArrayValue else { throw InpaintError.failed("no output") }
            // Classifier-free guidance: negative + g · (positive − negative).
            let guided = Self.floats(noisePrediction).withUnsafeBufferPointer { values in
                (0..<(4 * n)).map { i in values[i] + settings.guidance * (values[4 * n + i] - values[i]) }
            }
            progress(Double(step + 1) / total)
            return guided
        }
        guard latent.allSatisfy(\.isFinite) else { throw InpaintError.failed("the fill didn't converge") }
        return try decode(latent, with: loaded.decoder)
    }

    // MARK: Helpers

    private func encode(_ image: CGImage, with encoder: MLModel) throws -> [Float] {
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": try MLFeatureValue(cgImage: image, pixelsWide: Self.size, pixelsHigh: Self.size, pixelFormatType: kCVPixelFormatType_32BGRA, options: nil),
        ])
        guard let latent = try encoder.prediction(from: input).featureValue(for: "latent")?.multiArrayValue else {
            throw InpaintError.failed("couldn't encode the image")
        }
        return Self.floats(latent)
    }

    private func decode(_ latent: [Float], with decoder: MLModel) throws -> CGImage {
        let array = try MLMultiArray(shape: [1, 4, 64, 64], dataType: .float32)
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for i in 0..<latent.count { buffer[i] = latent[i] }
        }
        let output = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["latent": MLFeatureValue(multiArray: array)]))
        guard let buffer = output.featureValue(for: "image")?.imageBufferValue else { throw InpaintError.failed("couldn't decode the fill") }
        return try Inpainter.copyOpaque(buffer).1
    }

    /// A multi-array's values as Float, whatever its storage type.
    static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        switch array.dataType {
        case .float16:
            return array.withUnsafeBufferPointer(ofType: Float16.self) { Array($0.prefix(count)).map(Float.init) }
        case .float32:
            return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(count)) }
        default:
            return (0..<count).map { array[$0].floatValue }
        }
    }

    /// The mask at latent size (1 = re-imagine), as diffusers prepares it.
    static func maskLatent(_ mask: CGImage) throws -> [Float] {
        let pixels = try Inpainter.grayPixels(mask, size: latentSize)
        return pixels.map { $0 >= 128 ? 1 : 0 }
    }

    /// The photo with the masked area set to mid-gray (0 in the model's −1…1 range).
    static func blanked(_ image: CGImage, mask: CGImage) throws -> CGImage {
        let size = DiffusionInpainter.size
        let maskPixels = try Inpainter.grayPixels(mask, size: size)
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: RenderContext.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw InpaintError.failed("couldn't prepare the image") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        for i in 0..<(size * size) where maskPixels[i] >= 128 {
            pixels[i * 4] = 128; pixels[i * 4 + 1] = 128; pixels[i * 4 + 2] = 128
        }
        guard let blanked = context.makeImage() else { throw InpaintError.failed("couldn't prepare the image") }
        return blanked
    }
}
