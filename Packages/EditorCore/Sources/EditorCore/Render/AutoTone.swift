import CoreImage
import Foundation

/// One-tap "Auto" for the Light group, from the photo's luminance histogram.
///
/// Deliberately gentle: it centers the exposure, recovers clipped highlights,
/// opens blocked shadows and sets the white and black points. Users fine-tune
/// from there.
public enum AutoTone {
    public static func values(for image: CIImage, context: CIContext = RenderContext.shared) -> [ParamKey: Double] {
        let bins = lumaHistogram(image, count: 256, context: context)
        let total = bins.reduce(0, +)
        guard total > 0 else { return [:] }

        func percentile(_ p: Double) -> Double {
            var sum = 0.0
            for (index, value) in bins.enumerated() {
                sum += value
                if sum >= p * total { return (Double(index) + 0.5) / Double(bins.count) }
            }
            return 1
        }
        func fraction(above v: Double) -> Double {
            bins.enumerated().filter { (Double($0.offset) + 0.5) / Double(bins.count) > v }.map(\.element).reduce(0, +) / total
        }
        func fraction(below v: Double) -> Double {
            bins.enumerated().filter { (Double($0.offset) + 0.5) / Double(bins.count) < v }.map(\.element).reduce(0, +) / total
        }

        // Percentiles are in the gamma-2.2 domain; exposure works in linear light.
        let median = percentile(0.5)
        let medianLinear = max(pow(median, 2.2), 1e-4)
        // Only part of the way, and capped: dark scenes like sunsets are often dark
        // on purpose.
        var exposure = log2(0.18 / medianLinear) * 0.55
        exposure = min(max(exposure, -1.5), 1.5)
        let gain = pow(pow(2, exposure), 1 / 2.2)  // How exposure moves gamma-domain values.

        var values: [ParamKey: Double] = [:]
        if abs(exposure) >= 0.05 { values[.exposure] = (exposure * 100).rounded() / 100 }

        // Highlights already at the top of the histogram stay clipped whatever the
        // exposure does, so count them too.
        let clipped = fraction(above: min(0.97 / gain, 0.985))
        if clipped > 0.002 { values[.highlights] = -min(70, (clipped * 900).rounded()) }

        let blocked = fraction(below: 0.1 / gain)
        if blocked > 0.08 { values[.shadows] = min(50, (blocked * 120).rounded()) }

        let white = min(percentile(0.995) * gain, 1)
        let whites = ((0.96 - white) * 150).rounded()
        if abs(whites) >= 3 { values[.whites] = min(max(whites, -30), 40) }

        let black = percentile(0.005) * gain
        let blacks = (-(black - 0.03) * 220).rounded()
        if abs(blacks) >= 3 { values[.blacks] = min(max(blacks, -40), 30) }

        let spread = (percentile(0.95) - percentile(0.05)) * gain
        if spread < 0.55 { values[.contrast] = min(25, ((0.55 - spread) * 80).rounded()) }
        return values
    }

    /// Luma counts in the gamma-encoded domain.
    static func lumaHistogram(_ image: CIImage, count: Int, context: CIContext) -> [Double] {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite else { return [] }
        let scale = min(1, 512 / max(extent.width, extent.height))
        let luma = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        guard let filter = CIFilter(name: "CIAreaHistogram") else { return [] }
        filter.setValue(luma, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: luma.extent), forKey: kCIInputExtentKey)
        filter.setValue(count, forKey: "inputCount")
        filter.setValue(1, forKey: kCIInputScaleKey)
        guard let output = filter.outputImage else { return [] }
        var bins = [Float](repeating: 0, count: count * 4)
        bins.withUnsafeMutableBytes { pointer in
            context.render(output, toBitmap: pointer.baseAddress!, rowBytes: count * 16,
                           bounds: CGRect(x: 0, y: 0, width: count, height: 1), format: .RGBAf, colorSpace: nil)
        }
        return (0..<count).map { Double(bins[$0 * 4]) }
    }
}
