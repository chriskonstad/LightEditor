import CoreGraphics
import CoreImage
import CoreText
import Foundation
import Synchronization

/// Draws the finishing stage (`Finishing`): the watermark onto the cropped photo,
/// then the border and canvas around it. The result's extent starts at the origin.
public enum FinishingRenderer {
    /// `files` supplies a logo watermark's image; without it (or without the logo's
    /// file) a logo watermark is skipped.
    public static func apply(_ recipe: Recipe, to image: CIImage, files: (any LUTProvider)? = nil) -> CIImage {
        let hasFrame = Finishing.hasFrame(recipe)
        let mark = Finishing.watermark(recipe)
        guard hasFrame || mark != nil else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return image }
        var photo = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if let mark { photo = watermark(mark, recipe, on: photo, files: files) }
        guard hasFrame else { return photo }

        let layout = Finishing.layout(photo: extent.size, recipe: recipe)
        let color = Finishing.borderColor(recipe)
        let background = CIImage(color: CIColor(red: color.red, green: color.green, blue: color.blue, colorSpace: RenderContext.sRGB) ?? .white)
            .cropped(to: CGRect(origin: .zero, size: layout.canvas))
        return photo
            .transformed(by: CGAffineTransform(translationX: layout.photo.minX, y: layout.photo.minY))
            .composited(over: background)
    }

    /// Where the watermark goes on a photo of `size` pixels: its center (from the
    /// top left), its size before rotation, and its rotation. Nil when there's no
    /// watermark or it can't be drawn (a logo whose file is missing). The on-photo
    /// handles use the same placement as the render.
    public static func watermarkPlacement(_ recipe: Recipe, photo size: CGSize, files: (any LUTProvider)?) -> WatermarkPlacement? {
        guard let mark = Finishing.watermark(recipe) else { return nil }
        return placement(mark, recipe, photo: size, files: files)?.placement
    }

    public struct WatermarkPlacement: Sendable, Equatable {
        /// The center, in pixels from the photo's top left.
        public var center: CGPoint
        /// The watermark's size before rotation, in pixels.
        public var size: CGSize
        /// Degrees, clockwise.
        public var rotation: Double
    }

    /// The placement, plus how to draw the art at a given scale (1 is the photo's pixels).
    private static func placement(_ mark: Watermark, _ recipe: Recipe, photo size: CGSize, files: (any LUTProvider)?)
        -> (placement: WatermarkPlacement, art: (Double) -> CGImage?)? {
        let metrics = Finishing.watermarkMetrics(photo: size, recipe: recipe)
        let maxWidth = Double(size.width) - 2 * metrics.margin
        guard metrics.height >= 1, maxWidth > 1 else { return nil }
        let artSize: CGSize
        let art: (Double) -> CGImage?
        if let logo = mark.logo {
            // Fit: the logo's height is the watermark size, its width follows its
            // aspect ratio, and a logo too wide for the margins shrinks to fit.
            guard let aspect = files?.aspectRatio(of: logo), aspect > 0 else { return nil }
            var logoSize = CGSize(width: metrics.height * aspect, height: metrics.height)
            if logoSize.width > maxWidth { logoSize = CGSize(width: maxWidth, height: maxWidth / aspect) }
            logoSize = CGSize(width: logoSize.width.rounded(), height: logoSize.height.rounded())
            guard logoSize.width >= 1, logoSize.height >= 1 else { return nil }
            artSize = logoSize
            // A PDF logo is drawn as vectors at whatever size is asked for.
            art = { scale in files?.image(for: logo, size: CGSize(width: (logoSize.width * scale).rounded(), height: (logoSize.height * scale).rounded())) }
        } else {
            // Text is set in the font at its final pixel size, never scaled as a bitmap.
            guard let text = TextImages.shared.image(mark.text, height: metrics.height, maxWidth: maxWidth, color: mark.color) else { return nil }
            artSize = CGSize(width: text.width, height: text.height)
            art = { scale in
                scale == 1 ? text : TextImages.shared.image(mark.text, height: metrics.height * scale, maxWidth: maxWidth * scale, color: mark.color)
            }
        }
        let w = Double(artSize.width), h = Double(artSize.height)
        let center: CGPoint
        if let free = mark.center {
            center = CGPoint(x: free.x * Double(size.width), y: free.y * Double(size.height))
        } else {
            let (column, row) = mark.position.cell
            let x: Double = switch column {
            case 0: metrics.margin
            case 1: (Double(size.width) - w) / 2
            default: Double(size.width) - metrics.margin - w
            }
            let top: Double = switch row {
            case 0: metrics.margin
            case 1: (Double(size.height) - h) / 2
            default: Double(size.height) - metrics.margin - h
            }
            center = CGPoint(x: x + w / 2, y: top + h / 2)
        }
        return (WatermarkPlacement(center: center, size: artSize, rotation: mark.rotation), art)
    }

    /// The watermark over a photo whose extent starts at the origin.
    static func watermark(_ mark: Watermark, _ recipe: Recipe, on photo: CIImage, files: (any LUTProvider)?) -> CIImage {
        let size = photo.extent.size
        guard let (placement, art) = placement(mark, recipe, photo: size, files: files) else { return photo }
        let opacity = Finishing.watermarkMetrics(photo: size, recipe: recipe).opacity
        // Core Image's origin is at the bottom left.
        let center = CGPoint(x: placement.center.x, y: Double(size.height) - placement.center.y)
        var overlay: CIImage
        if placement.rotation == 0 {
            guard let image = art(1) else { return photo }
            // Whole pixels, so text stays as crisp as it was set.
            let x = (center.x - placement.size.width / 2).rounded(), y = (center.y - placement.size.height / 2).rounded()
            overlay = CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: x, y: y))
        } else {
            // Turned: set at twice the size, rotate, then scale down with Lanczos, so
            // edges stay clean instead of picking up a bilinear blur.
            guard let image = art(2) else { return photo }
            let big = CIImage(cgImage: image)
            overlay = big
                .transformed(by: CGAffineTransform(translationX: -big.extent.width / 2, y: -big.extent.height / 2))
                .transformed(by: CGAffineTransform(rotationAngle: -placement.rotation * .pi / 180))
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.5, kCIInputAspectRatioKey: 1])
                .transformed(by: CGAffineTransform(translationX: center.x, y: center.y))
        }
        if opacity < 1 {
            overlay = overlay.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
            ])
        }
        return overlay.composited(over: photo).cropped(to: photo.extent)
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
        var color: SRGBColor
    }

    private let cache = Mutex<[(key: Key, image: CGImage)]>([])
    private let limit = 6

    /// `text` in the system font, about `height` pixels tall (ascent plus descent),
    /// shrunk to fit `maxWidth`. White, black or any color, on transparency.
    func image(_ text: String, height: Double, maxWidth: Double, color: SRGBColor) -> CGImage? {
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
