import CoreImage
import Foundation
import ImageIO

/// The camera's embedded JPEG preview, shown instantly while the RAW decodes.
public enum EmbeddedPreview {
    public static func load(_ url: URL, maxPixelSize: Int = 2560) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A luminance + RGB histogram of the current render, for the editor overlay.
public struct Histogram: Sendable, Equatable {
    public static let binCount = 64

    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]
    public var luma: [Float]

    public static let empty = Histogram(red: [], green: [], blue: [], luma: [])

    /// Computes a normalized histogram on the GPU from a downscaled copy of `image`.
    public static func compute(_ image: CIImage, context: CIContext = RenderContext.shared) -> Histogram {
        let signpostID = Signposts.render.makeSignpostID()
        let state = Signposts.render.beginInterval("Histogram", id: signpostID)
        defer { Signposts.render.endInterval("Histogram", state) }

        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite else { return .empty }
        let scale = min(1, 256 / max(extent.width, extent.height))
        // Bin gamma-encoded values, like every photo editor, not linear light.
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CILinearToSRGBToneCurve")
        let luma = small.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        ])
        guard let rgbBins = bins(of: small, context: context), let lumaBins = bins(of: luma, context: context) else { return .empty }
        func channel(_ bins: [Float], _ c: Int) -> [Float] { (0..<binCount).map { bins[$0 * 4 + c] } }
        var histogram = Histogram(red: channel(rgbBins, 0), green: channel(rgbBins, 1), blue: channel(rgbBins, 2), luma: channel(lumaBins, 0))
        let peak = max((histogram.red + histogram.green + histogram.blue + histogram.luma).max() ?? 1, 1e-6)
        histogram.red = histogram.red.map { $0 / peak }
        histogram.green = histogram.green.map { $0 / peak }
        histogram.blue = histogram.blue.map { $0 / peak }
        histogram.luma = histogram.luma.map { $0 / peak }
        return histogram
    }

    /// Raw CIAreaHistogram counts, read back without color management.
    private static func bins(of image: CIImage, context: CIContext) -> [Float]? {
        guard let filter = CIFilter(name: "CIAreaHistogram") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: image.extent), forKey: kCIInputExtentKey)
        filter.setValue(binCount, forKey: "inputCount")
        filter.setValue(1, forKey: kCIInputScaleKey)
        guard let output = filter.outputImage else { return nil }
        var bins = [Float](repeating: 0, count: binCount * 4)
        bins.withUnsafeMutableBytes { pointer in
            context.render(
                output, toBitmap: pointer.baseAddress!, rowBytes: binCount * 16,
                bounds: CGRect(x: 0, y: 0, width: binCount, height: 1),
                format: .RGBAf, colorSpace: nil
            )
        }
        return bins
    }
}

/// Small renders for preset tiles and bulk-edit thumbnails.
public enum ThumbnailRenderer {
    public static func render(_ recipe: Recipe, base: CIImage, inputs: GradeInputs, longEdge: CGFloat) -> CGImage? {
        let scale = min(1, longEdge / max(base.extent.width, base.extent.height))
        let small = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let graded = GradeGraph.apply(recipe, to: small, inputs: inputs)
        return RenderContext.shared.createCGImage(graded, from: graded.extent, format: .RGBA8, colorSpace: RenderContext.displayP3)
    }
}
