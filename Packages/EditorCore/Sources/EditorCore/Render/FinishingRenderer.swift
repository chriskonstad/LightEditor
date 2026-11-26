import CoreGraphics
import CoreImage
import CoreText
import Foundation
import Synchronization

/// Draws the finishing stage (`Finishing`): the watermark onto the cropped photo,
/// then the border and canvas around it. The result's extent starts at the origin.
public enum FinishingRenderer {
    public static func apply(_ recipe: Recipe, to image: CIImage) -> CIImage {
        let hasFrame = Finishing.hasFrame(recipe)
        let mark = Finishing.watermark(recipe)
        guard hasFrame || mark != nil else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return image }
        var photo = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if let mark { photo = watermark(mark, recipe, on: photo) }
        guard hasFrame else { return photo }

        let layout = Finishing.layout(photo: extent.size, recipe: recipe)
        let color = Finishing.borderColor(recipe)
        let background = CIImage(color: CIColor(red: color.red, green: color.green, blue: color.blue, colorSpace: RenderContext.sRGB) ?? .white)
            .cropped(to: CGRect(origin: .zero, size: layout.canvas))
        return photo
            .transformed(by: CGAffineTransform(translationX: layout.photo.minX, y: layout.photo.minY))
            .composited(over: background)
    }

    /// The watermark over a photo whose extent starts at the origin.
    static func watermark(_ mark: Watermark, _ recipe: Recipe, on photo: CIImage) -> CIImage {
        let size = photo.extent.size
        let metrics = Finishing.watermarkMetrics(photo: size, recipe: recipe)
        let maxWidth = Double(size.width) - 2 * metrics.margin
        guard metrics.height >= 1, maxWidth > 1, let text = TextImages.shared.image(mark.text, height: metrics.height, maxWidth: maxWidth, color: mark.color) else {
            return photo
        }
        let w = Double(text.width), h = Double(text.height)
        let (column, row) = mark.position.cell
        let x: Double = switch column {
        case 0: metrics.margin
        case 1: (Double(size.width) - w) / 2
        default: Double(size.width) - metrics.margin - w
        }
        // Rows count from the top; Core Image's origin is at the bottom.
        let y: Double = switch row {
        case 0: Double(size.height) - metrics.margin - h
        case 1: (Double(size.height) - h) / 2
        default: metrics.margin
        }
        var overlay = CIImage(cgImage: text)
        if metrics.opacity < 1 {
            overlay = overlay.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: metrics.opacity),
            ])
        }
        return overlay
            .transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
            .composited(over: photo)
            .cropped(to: photo.extent)
    }
}

/// Rendered watermark text, cached: slider drags elsewhere rebuild the graph every
/// frame, and the text only changes when its own settings do.
final class TextImages: Sendable {
    static let shared = TextImages()

    private struct Key: Hashable {
        var text: String
        var height: Int
        var maxWidth: Int
        var color: RGBColor
    }

    private let cache = Mutex<[(key: Key, image: CGImage)]>([])
    private let limit = 6

    /// `text` in the system font, about `height` pixels tall (ascent plus descent),
    /// shrunk to fit `maxWidth`. White, black or any color, on transparency.
    func image(_ text: String, height: Double, maxWidth: Double, color: RGBColor) -> CGImage? {
        let key = Key(text: text, height: Int(height.rounded()), maxWidth: Int(maxWidth.rounded()), color: color)
        if let hit = cache.withLock({ entries in entries.first { $0.key == key }?.image }) { return hit }
        guard let image = Self.render(key) else { return nil }
        cache.withLock { entries in
            entries.removeAll { $0.key == key }
            entries.insert((key, image), at: 0)
            if entries.count > limit { entries.removeLast() }
        }
        return image
    }

    private static func render(_ key: Key) -> CGImage? {
        func line(fontSize: Double) -> (CTLine, CTFont) {
            let system = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
                ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            // A fixed optical size: the system font otherwise widens its glyphs at
            // small sizes, so a preview's text would run longer than an export's.
            let fixed = CTFontDescriptorCreateWithAttributes([kCTFontOpticalSizeAttribute: 28] as CFDictionary)
            let font = CTFontCreateCopyWithAttributes(system, fontSize, nil, fixed)
            let color = CGColor(colorSpace: RenderContext.sRGB, components: [key.color.red, key.color.green, key.color.blue, 1])!
            let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
            let string = CFAttributedStringCreate(nil, key.text as CFString, attributes as CFDictionary)!
            return (CTLineCreateWithAttributedString(string), font)
        }
        // Size the font so ascent + descent is the requested height.
        var (probe, probeFont) = line(fontSize: 100)
        let lineHeight = CTFontGetAscent(probeFont) + CTFontGetDescent(probeFont)
        guard lineHeight > 0 else { return nil }
        var fontSize = Double(key.height) * 100 / lineHeight
        let probeWidth = CTLineGetTypographicBounds(probe, nil, nil, nil) * fontSize / 100
        if probeWidth > Double(key.maxWidth), probeWidth > 0 { fontSize *= Double(key.maxWidth) / probeWidth }
        (probe, probeFont) = line(fontSize: fontSize)
        let fitted = CTLineGetTypographicBounds(probe, nil, nil, nil)
        if fitted > Double(key.maxWidth) {
            fontSize *= Double(key.maxWidth) / fitted
            (probe, probeFont) = line(fontSize: fontSize)
        }
        let ascent = CTFontGetAscent(probeFont), descent = CTFontGetDescent(probeFont)
        let width = Int(CTLineGetTypographicBounds(probe, nil, nil, nil).rounded(.up))
        let height = Int((ascent + descent).rounded(.up))
        guard width > 0, height > 0, width < 16_384, height < 16_384,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: RenderContext.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShouldAntialias(true)
        context.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(probe, context)
        return context.makeImage()
    }
}
