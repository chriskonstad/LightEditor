import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// An original file on disk, plus a stable key for caching its decodes.
public struct PhotoSource: Sendable, Hashable {
    public var url: URL
    /// Identity for caches, e.g. a Photos local identifier. Must change if the file does.
    public var key: String

    public init(url: URL, key: String? = nil) {
        self.url = url
        self.key = key ?? url.path
    }

    public var isRAW: Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .rawImage)
    }

    /// Photos that live on another device have `lightedit-remote://<device>/<asset>`
    /// URLs; `RawDecoder` fetches their decodes from that device.
    public static let remoteScheme = "lightedit-remote"
    public var isRemote: Bool { url.scheme == Self.remoteScheme }
}

/// Decodes photos that live on another device (the phone, when the iPad edits remotely).
public protocol RemoteDecoding: Sendable {
    func info(for source: PhotoSource) async throws -> SourceInfo
    func decode(_ source: PhotoSource, rawStage: RawStageParams, longEdge: Int) async throws -> DecodedImage
}

/// What the decoder learned about a source: camera, size, decoder and defaults.
public struct SourceInfo: Sendable, Hashable, Codable {
    public var isRAW: Bool
    public var cameraModel: String?
    /// Oriented native pixel size.
    public var nativeSize: CGSize
    /// The decoder version in use, e.g. "9", or "none" for non-RAW files.
    public var decoderVersion: String
    public var supportedDecoderVersions: [String]
    public var defaults: PhotoDefaults
    /// The Fujifilm film simulation the photo was shot with, matching a preset name.
    public var filmSimulation: String?
    /// The camera's electronic level (degrees) for upright landscape RAWs that record it.
    public var cameraRoll: Double?
    /// Whether the decoder has a lens profile for this camera and lens (nil: unknown).
    public var lensCorrectionSupported: Bool?

    /// "A7R V · RAW 9", as shown in the editor's badge.
    public var badge: String {
        let camera = cameraModel.map(CameraNames.displayName) ?? (isRAW ? "RAW" : "Photo")
        guard isRAW else { return camera }
        return "\(camera) · RAW \(decoderVersion)"
    }

    public var supportsRAW9: Bool { supportedDecoderVersions.contains(CIRAWDecoderVersion.version9.rawValue) }
}

public enum DecodeError: Error, LocalizedError {
    case unreadable(URL)
    case renderFailed
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): "Couldn't read \(url.lastPathComponent)."
        case .renderFailed: "The image couldn't be decoded."
        case .notConnected: "The device with this photo isn't connected."
        }
    }
}

/// Decodes originals into cached scene-linear intermediates.
///
/// RAWs go through `CIRAWFilter` with the RAW 9 decoder when the camera supports
/// it. The result is rendered once into an RGBA16F buffer and cached; grading then
/// runs on that buffer and never touches the RAW again. Only RAW-stage parameters
/// (noise reduction, sharpness, detail) cause a new decode.
public actor RawDecoder {
    public static let shared = RawDecoder(cache: DecodeCache())

    public let cache: DecodeCache

    /// Where `lightedit-remote` sources come from, while editing another device's library.
    public static let remote = Mutex<(any RemoteDecoding)?>(nil)

    public init(cache: DecodeCache) {
        self.cache = cache
    }

    private static func remoteDecoder() throws -> any RemoteDecoding {
        guard let remote = remote.withLock({ $0 }) else { throw DecodeError.notConnected }
        return remote
    }

    /// Inspects a source without decoding pixels.
    public func info(for source: PhotoSource) async throws -> SourceInfo {
        if source.isRemote { return try await Self.remoteDecoder().info(for: source) }
        if source.isRAW, let raw = CIRAWFilter(imageURL: source.url) {
            return makeInfo(raw: raw, source: source)
        }
        return try bitmapInfo(source)
    }

    /// Returns the cached decode at `longEdge` pixels, decoding it if needed.
    public func decode(_ source: PhotoSource, rawStage: RawStageParams, longEdge: Int) async throws -> DecodedImage {
        let key = DecodeCache.Key(photoKey: source.key, rawStage: rawStage, longEdge: longEdge)
        if let cached = await cache.image(for: key) { return cached }
        try Task.checkCancellation()

        let signpostID = Signposts.decode.makeSignpostID()
        let state = Signposts.decode.beginInterval("Decode", id: signpostID, "\(source.url.lastPathComponent, privacy: .public) \(longEdge)")
        defer { Signposts.decode.endInterval("Decode", state) }

        if source.isRemote {
            let decoded = try await Self.remoteDecoder().decode(source, rawStage: rawStage, longEdge: longEdge)
            await cache.insert(decoded, for: key)
            return decoded
        }
        let (image, info) = try await lazyImage(source, rawStage: rawStage, longEdge: longEdge)
        try Task.checkCancellation()
        let decoded = try render(image, info: info)
        await cache.insert(decoded, for: key)
        return decoded
    }

    /// An unrendered Core Image graph for the source, used for exports and 100% views
    /// where caching a full-resolution buffer would cost too much memory.
    /// `longEdge` of nil means full resolution.
    public func lazyImage(_ source: PhotoSource, rawStage: RawStageParams, longEdge: Int?) async throws -> (CIImage, SourceInfo) {
        if source.isRemote {
            // Only the phone has the original; the preview decode stands in.
            let decoded = try await decode(source, rawStage: rawStage, longEdge: longEdge.map { min($0, 2560) } ?? 2560)
            return (decoded.image, decoded.info)
        }
        if source.isRAW, let raw = CIRAWFilter(imageURL: source.url) {
            let info = makeInfo(raw: raw, source: source)
            let wanted = CIRAWDecoderVersion(rawValue: rawStage.decoderVersion)
            if raw.supportedDecoderVersions.contains(wanted) {
                raw.decoderVersion = wanted
            } else if let newest = raw.supportedDecoderVersions.last {
                raw.decoderVersion = newest
            }
            if raw.decoderVersion == .version9 || raw.decoderVersion == .version9DNG {
                try await downloadResources(raw)
            }
            if let value = rawStage.noiseReduction, raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = Float(value / 100) }
            if let value = rawStage.colorNoise, raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = Float(value / 100) }
            if let value = rawStage.sharpness, raw.isSharpnessSupported { raw.sharpnessAmount = Float(value / 100) }
            if let value = rawStage.detail, raw.isDetailSupported { raw.detailAmount = Float(value / 100) }
            if let value = rawStage.lensCorrection, raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = value >= 0.5 }
            if let value = rawStage.moire, raw.isMoireReductionSupported { raw.moireReductionAmount = Float(value / 100) }
            let native = max(raw.nativeSize.width, raw.nativeSize.height)
            let scale = longEdge.map { min(1, Double($0) / native) } ?? 1
            #if targetEnvironment(simulator)
            // The iOS 27 simulator ignores scaleFactor: the output reports the scaled
            // extent but holds the top-left corner of the full-size image. Decode at full
            // size and downscale instead. Devices and the Mac honor scaleFactor.
            guard var output = raw.outputImage else { throw DecodeError.renderFailed }
            if scale < 1 {
                output = output.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            }
            #else
            raw.scaleFactor = Float(scale)
            guard let output = raw.outputImage else { throw DecodeError.renderFailed }
            #endif
            var resolved = info
            resolved.decoderVersion = raw.decoderVersion.rawValue
            return (output, resolved)
        }

        let info = try bitmapInfo(source)
        guard var image = CIImage(contentsOf: source.url, options: [.applyOrientationProperty: true]) else {
            throw DecodeError.unreadable(source.url)
        }
        if let longEdge {
            let scale = min(1, Double(longEdge) / max(image.extent.width, image.extent.height))
            if scale < 1 {
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            }
        }
        // Non-RAW files get Core Image's denoise and sharpen in the decode stage, so
        // the Detail tab behaves the same for every file type.
        let noise = (rawStage.noiseReduction ?? 0) / 100
        let sharpness = (rawStage.sharpness ?? 0) / 100
        if noise > 0 || sharpness > 0 {
            image = image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": noise * 0.06, "inputSharpness": sharpness * 2])
        }
        return (image, info)
    }

    private func render(_ image: CIImage, info: SourceInfo) throws -> DecodedImage {
        let extent = image.extent.integral
        let origin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        guard let buffer = PixelBuffers.make(width: Int(extent.width), height: Int(extent.height)) else {
            throw DecodeError.renderFailed
        }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = RenderContext.linearP3
        let task = try RenderContext.shared.startTask(toRender: origin, from: CGRect(origin: .zero, size: extent.size), to: destination, at: .zero)
        _ = try task.waitUntilCompleted()
        return DecodedImage(pixelBuffer: buffer, info: info)
    }

    private func downloadResources(_ raw: CIRAWFilter) async throws {
        let box = UncheckedBox(raw)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            _ = box.value.downloadResources(timeout: 120) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func makeInfo(raw: CIRAWFilter, source: PhotoSource) -> SourceInfo {
        var defaults = PhotoDefaults()
        defaults.values[.temperature] = Double(raw.neutralTemperature)
        defaults.values[.tint] = Double(raw.neutralTint)
        defaults.values[.noiseReduction] = Double(raw.luminanceNoiseReductionAmount) * 100
        defaults.values[.colorNoise] = Double(raw.colorNoiseReductionAmount) * 100
        defaults.values[.sharpness] = Double(raw.sharpnessAmount) * 100
        defaults.values[.detail] = Double(raw.detailAmount) * 100
        let versions = raw.supportedDecoderVersions.map(\.rawValue)
        let preferred = versions.contains(CIRAWDecoderVersion.version9.rawValue) ? CIRAWDecoderVersion.version9.rawValue : (versions.last ?? "none")
        var size = raw.nativeSize
        if [5, 6, 7, 8].contains(raw.orientation.rawValue) { size = CGSize(width: size.height, height: size.width) }
        return SourceInfo(
            isRAW: true,
            cameraModel: Self.cameraModel(source.url),
            nativeSize: size,
            decoderVersion: preferred,
            supportedDecoderVersions: versions,
            defaults: defaults,
            filmSimulation: Self.properties(source.url).flatMap(FilmSimulations.detect),
            cameraRoll: raw.orientation == .up ? CameraLevel.roll(fileAt: source.url) : nil,
            lensCorrectionSupported: raw.isLensCorrectionSupported
        )
    }

    private func bitmapInfo(_ source: PhotoSource) throws -> SourceInfo {
        guard let imageSource = CGImageSourceCreateWithURL(source.url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        else { throw DecodeError.unreadable(source.url) }
        var width = properties[kCGImagePropertyPixelWidth] as? Double ?? 0
        var height = properties[kCGImagePropertyPixelHeight] as? Double ?? 0
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) { swap(&width, &height) }
        return SourceInfo(
            isRAW: false,
            cameraModel: Self.cameraModel(source.url),
            nativeSize: CGSize(width: width, height: height),
            decoderVersion: DecoderPin.none.version,
            supportedDecoderVersions: [],
            defaults: .generic,
            filmSimulation: FilmSimulations.detect(in: properties)
        )
    }

    static func properties(_ url: URL) -> [CFString: Any]? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
    }

    static func cameraModel(_ url: URL) -> String? {
        guard let properties = properties(url),
              let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        else { return nil }
        return (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Friendly camera names for the editor badge.
public enum CameraNames {
    public static func displayName(_ model: String) -> String {
        // Sony bodies report e.g. "ILCE-7RM5"; show "A7R V".
        if model.hasPrefix("ILCE-") {
            var body = String(model.dropFirst(5))
            var generation = ""
            if let range = body.range(of: "M", options: .backwards), let number = Int(body[range.upperBound...]) {
                generation = " " + romanNumeral(number)
                body = String(body[..<range.lowerBound])
            }
            return "A" + body + generation
        }
        return model
    }

    private static func romanNumeral(_ number: Int) -> String {
        ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"][min(max(number, 0), 10)]
    }
}

/// Moves a non-Sendable reference across an isolation boundary we know is safe.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
