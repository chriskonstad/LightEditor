import CoreImage
import CoreML
import Foundation
import Synchronization

/// Relative depth for depth range masks, from Depth Anything V2 Small (Apache-2.0,
/// Apple's Core ML conversion) on the photo itself.
///
/// No Apple API estimates depth from an ordinary photo, and Sony and Fujifilm RAWs
/// carry none, so every photo gets the same treatment from the same model rather
/// than using depth some iPhones store. See docs/spikes/depth-masks.md.
///
/// The result is a *distance* map, 0 for the nearest part of the photo and 1 for
/// the farthest, normalized per photo. It's computed once per photo by
/// `AIMaskStore` and cached like the other AI masks.
public final class DepthEstimator: Sendable {
    public static let shared = DepthEstimator()

    private struct State: @unchecked Sendable {
        var url: URL?
        var model: MLModel?
    }

    /// Held for the load and the prediction: one estimate at a time.
    private let state = Mutex(State())

    /// The compiled model (`.mlmodelc`) or a package (`.mlpackage`, compiled on first use).
    public func configure(modelURL: URL?) {
        state.withLock { $0 = State(url: modelURL) }
    }

    public var isAvailable: Bool { state.withLock { $0.url != nil } }

    /// The distance map for an sRGB image, at the image's size, with edges that
    /// follow the photo's.
    public func distanceMap(for image: CGImage) throws -> CIImage {
        let source = CIImage(cgImage: image)
        // The model's input is landscape (518 × 392). A portrait photo is turned on
        // its side rather than squashed, then the result is turned back.
        let portrait = image.height > image.width
        let upright = portrait ? Self.atOrigin(source.oriented(.right)) : source
        let raw = try predict(upright)
        let small = portrait ? Self.atOrigin(raw.oriented(.left)) : raw

        // The model's 518 px map upsampled to the photo, guided by its edges.
        let extent = source.extent
        if let guided = CIFilter(name: "CIEdgePreserveUpsampleFilter", parameters: [
            kCIInputImageKey: source,
            "inputSmallImage": small,
            "inputSpatialSigma": 3,
            "inputLumaSigma": 0.15,
        ])?.outputImage, !guided.extent.isInfinite {
            // The filter keeps the guide's colors' alpha; take one channel as gray.
            return guided.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]).cropped(to: extent)
        }
        return small.transformed(by: CGAffineTransform(scaleX: extent.width / small.extent.width, y: extent.height / small.extent.height))
            .cropped(to: extent)
    }

    /// Runs the model on `image` (stretched to its input size) and returns distance,
    /// 0 near to 1 far, at the model's output size.
    private func predict(_ image: CIImage) throws -> CIImage {
        try state.withLock { state in
            let model = try Self.model(&state)
            let input = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint
            let width = input?.pixelsWide ?? 518, height = input?.pixelsHigh ?? 392
            let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width, y: CGFloat(height) / image.extent.height))
            guard let cgImage = RenderContext.shared.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: width, height: height),
                                                                    format: .RGBA8, colorSpace: RenderContext.sRGB)
            else { throw DecodeError.renderFailed }
            let features = try MLDictionaryFeatureProvider(dictionary: [
                "image": try MLFeatureValue(cgImage: cgImage, pixelsWide: width, pixelsHigh: height, pixelFormatType: kCVPixelFormatType_32BGRA, options: nil),
            ])
            guard let buffer = try model.prediction(from: features).featureValue(for: "depth")?.imageBufferValue else {
                throw AIMaskError.unsupported
            }
            return try Self.distance(fromDisparity: buffer)
        }
    }

    /// The model outputs relative inverse depth (larger is nearer). Normalize it
    /// between its 1st and 99th percentiles, so a few outliers don't flatten the
    /// rest, and flip it into distance.
    static func distance(fromDisparity buffer: CVPixelBuffer) throws -> CIImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw DecodeError.renderFailed }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
            for x in 0..<width {
                switch format {
                case kCVPixelFormatType_OneComponent16Half:
                    values[y * width + x] = Float(row.assumingMemoryBound(to: Float16.self)[x])
                case kCVPixelFormatType_OneComponent32Float:
                    values[y * width + x] = row.assumingMemoryBound(to: Float.self)[x]
                default:
                    values[y * width + x] = Float(row.assumingMemoryBound(to: UInt8.self)[x]) / 255
                }
            }
        }
        let sorted = values.filter(\.isFinite).sorted()
        guard let first = sorted.first, let last = sorted.last else { throw DecodeError.renderFailed }
        let low = sorted[Int(Double(sorted.count - 1) * 0.01)], high = sorted[Int(Double(sorted.count - 1) * 0.99)]
        let span = high - low > 1e-6 ? high - low : max(last - first, 1e-6)
        // 16-bit gray, rows top first, as a CGImage (which has no doubt about which row is the top).
        let distance = values.map { UInt16((1 - min(max(($0 - low) / span, 0), 1)) * 65535) }
        let data = distance.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        guard let provider = CGDataProvider(data: data),
              let gray = CGColorSpace(name: CGColorSpace.linearGray),
              let cgImage = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: width * 2, space: gray,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw DecodeError.renderFailed }
        return CIImage(cgImage: cgImage)
    }

    private static func model(_ state: inout State) throws -> MLModel {
        if let model = state.model { return model }
        guard var url = state.url else { throw AIMaskError.unsupported }
        if url.pathExtension == "mlpackage" { url = try MLModel.compileModel(at: url) }
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = .all
        #endif
        let model = try MLModel(contentsOf: url, configuration: configuration)
        state.model = model
        state.url = url
        return model
    }

    private static func atOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}
