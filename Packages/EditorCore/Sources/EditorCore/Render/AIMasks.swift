import CoreImage
import CryptoKit
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import Vision

public enum AIMaskError: Error, LocalizedError {
    case nothingFound(String)
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .nothingFound(let what): "No \(what.lowercased()) found in this photo."
        case .unsupported: "AI masks aren't available on this device."
        }
    }
}

/// Computes and caches AI masks for one photo with Vision.
///
/// Masks are computed from the photo's *ungraded* preview decode, so they depend
/// only on the photo and the mask's recipe (kind or seed points), never on edits.
/// That makes them cacheable in memory and on disk, and identical on every device
/// that runs the same model.
///
/// - Subject: `GenerateForegroundInstanceMaskRequest`, all instances.
/// - People: `GeneratePersonInstanceMaskRequest`, all instances.
/// - Background: the subject, inverted.
/// - Object: `GenerateIterativeSegmentationRequest` from each tap, unioned.
/// - Sky: iterative segmentation seeded at the brightest, smoothest points along the
///   top of the frame. If none looks like sky, there is no sky.
public final class AIMaskStore: AIMaskProvider, @unchecked Sendable {
    /// Bump when the mask pipeline changes, so stale disk entries are ignored.
    static let version = 1
    /// Long edge of the image Vision sees.
    static let analysisEdge: CGFloat = 1536

    public let photoKey: String
    private let cache = Mutex<[MaskShape: UncheckedBox<CIImage>]>([:])
    private let directory: URL?

    private static let stores = Mutex<[String: AIMaskStore]>([:])

    /// The shared store for a photo, so the editor and exports reuse results.
    public static func store(for photoKey: String) -> AIMaskStore {
        stores.withLock { stores in
            if let existing = stores[photoKey] { return existing }
            if stores.count > 12 { stores.removeAll() }
            let store = AIMaskStore(photoKey: photoKey)
            stores[photoKey] = store
            return store
        }
    }

    public init(photoKey: String, directory: URL? = AIMaskStore.defaultDirectory) {
        self.photoKey = photoKey
        self.directory = directory
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "AIMasks", directoryHint: .isDirectory)
    }

    // MARK: Lookup

    public func mask(for shape: MaskShape) -> CIImage? {
        let key = Self.canonical(shape)
        if let hit = cache.withLock({ $0[key] }) { return hit.value }
        guard let url = fileURL(key), let image = CIImage(contentsOf: url) else { return nil }
        cache.withLock { $0[key] = UncheckedBox(image) }
        return image
    }

    public func hasMask(for shape: MaskShape) -> Bool { mask(for: shape) != nil }

    /// Background is the inverted subject, so they share one computation.
    static func canonical(_ shape: MaskShape) -> MaskShape {
        if case .ai(kind: .background) = shape { return .ai(kind: .subject) }
        return shape
    }

    private func fileURL(_ shape: MaskShape) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys  // Stable bytes, so file names match across runs.
        guard let directory, let data = try? encoder.encode(shape) else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data("v\(Self.version)|\(photoKey)|".utf8))
        hasher.update(data: data)
        return directory.appending(path: hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined() + ".png")
    }

    // MARK: Computing

    /// Computes every AI shape in `recipe` that isn't cached yet.
    public func prepare(_ recipe: Recipe, base: CIImage, progress: @Sendable (String) -> Void = { _ in }) async throws {
        let shapes = Set(recipe.masks.flatMap(\.components).map(\.shape).filter(\.isAI).map(Self.canonical))
        for shape in shapes where !hasMask(for: shape) {
            try Task.checkCancellation()
            progress(shape.displayName)
            try await compute(shape, base: base)
        }
    }

    /// Runs Vision for one shape and caches the result.
    public func compute(_ shape: MaskShape, base: CIImage) async throws {
        let key = Self.canonical(shape)
        let image = try Self.analysisImage(base)
        let signpostID = Signposts.render.makeSignpostID()
        let state = Signposts.render.beginInterval("AIMask", id: signpostID, "\(key.displayName, privacy: .public)")
        defer { Signposts.render.endInterval("AIMask", state) }

        var mask: CIImage
        switch key {
        case .ai(kind: .subject), .ai(kind: .background):
            var request = GenerateForegroundInstanceMaskRequest()
            Self.preferCPUInSimulator(&request)
            mask = try await Self.instances(request, image: image, what: "Subject")
        case .ai(kind: .people):
            var request = GeneratePersonInstanceMaskRequest()
            Self.preferCPUInSimulator(&request)
            mask = try await Self.instances(request, image: image, what: "People")
        case .ai(kind: .sky):
            mask = try await Self.sky(image)
        case .object(let seeds):
            mask = try await Self.objects(seeds, image: image)
        default:
            return
        }
        // Store as 8-bit gray: small on disk and cheap to sample.
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        mask = MaskRenderer.fit(mask, to: extent)
        guard let rendered = RenderContext.shared.createCGImage(mask, from: extent, format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray)) else {
            throw DecodeError.renderFailed
        }
        let stored = CIImage(cgImage: rendered)
        cache.withLock { $0[key] = UncheckedBox(stored) }
        if let url = fileURL(key), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, rendered, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    // MARK: Sharing with another device

    /// A computed mask as an 8-bit gray PNG, to send to a device editing remotely.
    public func pngData(for shape: MaskShape) -> Data? {
        let key = Self.canonical(shape)
        if let url = fileURL(key), let data = try? Data(contentsOf: url) { return data }
        guard let mask = mask(for: key),
              let cgImage = RenderContext.shared.createCGImage(mask, from: mask.extent, format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray))
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Stores a mask computed on another device.
    public func insert(png: Data, for shape: MaskShape) {
        let key = Self.canonical(shape)
        guard let image = CIImage(data: png) else { return }
        cache.withLock { $0[key] = UncheckedBox(image) }
        if let url = fileURL(key) { try? png.write(to: url, options: .atomic) }
    }

    /// The ungraded base as an sRGB CGImage at Vision's working size.
    static func analysisImage(_ base: CIImage) throws -> CGImage {
        let scale = min(1, analysisEdge / max(base.extent.width, base.extent.height))
        let small = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = small.extent.integral
        guard let image = RenderContext.shared.createCGImage(small, from: extent, format: .RGBA8, colorSpace: RenderContext.sRGB) else {
            throw DecodeError.renderFailed
        }
        return image
    }

    // MARK: Requests

    static func instances<Request: ImageProcessingRequest>(_ request: Request, image: CGImage, what: String) async throws -> CIImage where Request.Result == InstanceMaskObservation? {
        let handler = ImageRequestHandler(image)
        guard let observation = try await handler.perform(request), !observation.allInstances.isEmpty else {
            throw AIMaskError.nothingFound(what)
        }
        // Scaled to the image for clean edges, rather than the model's 512 px output.
        let buffer = try observation.generateScaledMask(for: observation.allInstances, scaledToImageFrom: handler)
        return CIImage(cvPixelBuffer: buffer)
    }

    /// The simulator has no Neural Engine, so Vision's default device fails there
    /// ("Could not create inference context"). Devices and Macs keep the default.
    static func preferCPUInSimulator<Request: ImageProcessingRequest>(_ request: inout Request) {
        #if targetEnvironment(simulator)
        for (stage, devices) in request.supportedComputeStageDevices {
            if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        #endif
    }

    static func iterative(_ request: GenerateIterativeSegmentationRequest, image: CGImage) async throws -> CIImage? {
        var request = request
        preferCPUInSimulator(&request)
        if await request.assetStatus != .ready {
            try await request.downloadAssets()
        }
        guard let observation = try await request.perform(on: image) else { return nil }
        return CIImage(cgImage: try observation.cgImage)
    }

    /// One iterative segmentation per tap, combined.
    static func objects(_ seeds: [NormalizedPoint], image: CGImage) async throws -> CIImage {
        var union: CIImage?
        for seed in seeds {
            // Vision's normalized origin is bottom-left; ours is top-left.
            let request = GenerateIterativeSegmentationRequest(seedPoint: Vision.NormalizedPoint(x: seed.x, y: 1 - seed.y))
            guard let mask = try await iterative(request, image: image) else { continue }
            union = union.map { mask.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? mask
        }
        guard let union else { throw AIMaskError.nothingFound("Object") }
        return union
    }

    /// Sky: seed iterative segmentation at the most sky-like points along the top.
    static func sky(_ image: CGImage) async throws -> CIImage {
        let seeds = skySeeds(in: image)
        guard !seeds.isEmpty else { throw AIMaskError.nothingFound("Sky") }
        var union: CIImage?
        for seed in seeds {
            let request = GenerateIterativeSegmentationRequest(seedPoint: Vision.NormalizedPoint(x: seed.x, y: 1 - seed.y))
            guard let mask = try await iterative(request, image: image) else { continue }
            union = union.map { mask.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? mask
        }
        guard let union, spansTopEdge(union) else { throw AIMaskError.nothingFound("Sky") }
        return union
    }

    /// Candidate points along the top of the frame that look like sky: bright,
    /// smooth, and not foliage green. Points are top-left normalized.
    static func skySeeds(in image: CGImage) -> [NormalizedPoint] {
        let width = 64, height = max(Int(Double(64) * Double(image.height) / Double(image.width)), 8)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: RenderContext.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = (y * width + x) * 4  // Row 0 is the top in this bitmap's memory.
            return (Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255)
        }
        func luma(_ c: (Double, Double, Double)) -> Double { 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2 }

        var seeds: [(NormalizedPoint, Double)] = []
        let row = max(height / 20, 1)
        for column in stride(from: 4, to: width - 4, by: 6) {
            // A 5×5 patch just below the top edge.
            var values: [Double] = []
            var greenish = 0.0
            for dy in 0..<5 {
                for dx in -2...2 {
                    let c = rgb(column + dx, min(row + dy, height - 1))
                    values.append(luma(c))
                    if c.1 > c.0 * 1.1 && c.1 > c.2 * 1.1 { greenish += 1 }
                }
            }
            let mean = values.reduce(0, +) / Double(values.count)
            let deviation = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
            let c = rgb(column, row + 2)
            if ProcessInfo.processInfo.environment["SKY_DEBUG"] != nil {
                print(String(format: "sky candidate x=%d mean=%.3f dev=%.3f green=%.0f rgb=(%.2f %.2f %.2f)", column, mean, deviation, greenish, c.0, c.1, c.2))
            }
            guard mean > 0.2, deviation < 0.09, greenish < 8, looksLikeSky(c, mean: mean) else { continue }
            seeds.append((NormalizedPoint(x: (Double(column) + 0.5) / Double(width), y: (Double(row) + 2.5) / Double(height)), mean - deviation * 4))
        }
        // The best few, spread out.
        return seeds.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
    }

    /// Skies are blue-leaning, bright and neutral (overcast, haze), or a saturated
    /// warm sunset. Walls and roofs are usually dull, warm and darker.
    static func looksLikeSky(_ c: (Double, Double, Double), mean: Double) -> Bool {
        let high = max(c.0, c.1, c.2), low = min(c.0, c.1, c.2)
        let saturation = high > 0 ? (high - low) / high : 0
        let blueLeaning = c.2 >= c.0 * 0.95
        let brightNeutral = mean > 0.45 && saturation < 0.25
        let sunset = saturation > 0.5 && c.0 >= c.1 && c.1 >= c.2
        return blueLeaning || brightNeutral || sunset
    }

    /// A real sky reaches across a good part of the top edge of the frame.
    static func spansTopEdge(_ mask: CIImage) -> Bool {
        let extent = mask.extent
        let band = CGRect(x: extent.minX, y: extent.maxY - max(extent.height * 0.04, 1), width: extent.width, height: max(extent.height * 0.04, 1))
        let samples = 64
        let row = mask.cropped(to: band)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(samples) / band.width, y: 1 / band.height))
        var values = [Float](repeating: 0, count: samples * 4)
        values.withUnsafeMutableBytes { pointer in
            RenderContext.shared.render(row, toBitmap: pointer.baseAddress!, rowBytes: samples * 16,
                                        bounds: CGRect(x: row.extent.minX, y: row.extent.minY, width: CGFloat(samples), height: 1),
                                        format: .RGBAf, colorSpace: nil)
        }
        let covered = (0..<samples).filter { values[$0 * 4] > 0.5 }.count
        return Double(covered) / Double(samples) > 0.3
    }
}
