import Foundation

/// An sRGB color, components 0...1. Encoded as a compact `[r, g, b]` triple.
public struct RGBColor: Codable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    public static let white = RGBColor(red: 1, green: 1, blue: 1)
    public static let black = RGBColor(red: 0, green: 0, blue: 0)

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.init(red: try container.decode(Double.self), green: try container.decode(Double.self), blue: try container.decode(Double.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for value in [red, green, blue] { try container.encode((value * 1000).rounded() / 1000) }
    }
}

/// Where a text watermark sits on the photo, on a 3 × 3 grid.
public enum WatermarkPosition: String, Codable, Sendable, CaseIterable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    public var id: String { rawValue }

    /// Column and row, 0...2, from the top left.
    public var cell: (column: Int, row: Int) {
        let index = Self.allCases.firstIndex(of: self)!
        return (index % 3, index / 3)
    }

    public var displayName: String {
        switch self {
        case .topLeft: "Top left"
        case .top: "Top"
        case .topRight: "Top right"
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        case .bottomLeft: "Bottom left"
        case .bottom: "Bottom"
        case .bottomRight: "Bottom right"
        }
    }
}

/// A text watermark such as "© Name". Its size, opacity and margin are scalar
/// parameters of their own, so they get the usual sliders.
public struct Watermark: Codable, Sendable, Hashable {
    public var text: String
    public var position: WatermarkPosition
    public var color: RGBColor

    public init(text: String, position: WatermarkPosition = .bottomRight, color: RGBColor = .white) {
        self.text = text
        self.position = position
        self.color = color
    }

    /// The `UserDefaults` key of the text new watermarks start with (Settings › Watermark).
    public static let defaultTextKey = "watermark.defaultText"
    public static let fallbackText = "©"
}

/// The finishing stage: a border or canvas around the cropped photo, and a text
/// watermark on it. Rendered last, after crop, vignette and grain, so a preview and
/// any save or export of the recipe match.
///
/// Sizes are percentages of the cropped photo's short edge, so they look the same
/// at every resolution.
public enum Finishing {
    /// The keys that change the output frame (not the watermark). The split
    /// before/after view and the tile mapping draw these too, so both sides match in size.
    public static let frameKeys: [ParamKey] = [.borderWidth, .borderBottom, .borderColor, .borderCanvas]
    public static let watermarkKeys: [ParamKey] = [.watermark, .watermarkSize, .watermarkOpacity, .watermarkMargin]
    public static let keys: [ParamKey] = frameKeys + watermarkKeys

    /// The canvas aspect ratios offered for padding, e.g. 4:5 for Instagram. These are
    /// literal (4:5 is portrait for every photo), since the point is the post's shape.
    public static let canvasPresets: [AspectRatio] = [
        AspectRatio(1, 1), AspectRatio(4, 5), AspectRatio(9, 16), AspectRatio(3, 2), AspectRatio(2, 3),
    ]

    /// Where the photo sits on the finished canvas, in pixels with a bottom-left
    /// origin like Core Image. `photo` is pixel-aligned.
    public struct Layout: Sendable, Equatable {
        public var canvas: CGSize
        public var photo: CGRect

        public var isIdentity: Bool { photo.origin == .zero && photo.size == canvas }
    }

    /// Whether the recipe adds a border or pads the canvas.
    public static func hasFrame(_ recipe: Recipe) -> Bool {
        (recipe.scalar(.borderWidth) ?? 0) > 0 || (recipe.scalar(.borderBottom) ?? 0) > 0 || canvas(recipe) != nil
    }

    public static func watermark(_ recipe: Recipe) -> Watermark? {
        guard case .watermark(let mark)? = recipe[.watermark], !mark.text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return mark
    }

    public static func borderColor(_ recipe: Recipe) -> RGBColor {
        if case .color(let color)? = recipe[.borderColor] { return color }
        return .white
    }

    public static func canvas(_ recipe: Recipe) -> AspectRatio? {
        if case .aspect(let aspect)? = recipe[.borderCanvas] { return aspect }
        return nil
    }

    /// The finished canvas for a cropped photo of `size` pixels.
    public static func layout(photo size: CGSize, recipe: Recipe) -> Layout {
        let w = size.width, h = size.height
        guard w > 0, h > 0, hasFrame(recipe) else { return Layout(canvas: size, photo: CGRect(origin: .zero, size: size)) }
        let short = min(w, h)
        let side = ((recipe.scalar(.borderWidth) ?? 0) / 100 * short).rounded()
        let bottom = side + ((recipe.scalar(.borderBottom) ?? 0) / 100 * short).rounded()
        var canvasWidth = w + 2 * side
        var canvasHeight = h + side + bottom
        if let aspect = canvas(recipe) {
            // Only ever pad, never crop the photo.
            let ratio = aspect.value
            if canvasWidth / canvasHeight < ratio {
                canvasWidth = (canvasHeight * ratio).rounded()
            } else {
                canvasHeight = (canvasWidth / ratio).rounded()
            }
        }
        // Extra room from the canvas ratio is shared evenly, keeping the bottom's extra.
        let x = ((canvasWidth - w) / 2).rounded(.down)
        let y = (bottom + (canvasHeight - h - side - bottom) / 2).rounded(.down)
        return Layout(canvas: CGSize(width: canvasWidth, height: canvasHeight), photo: CGRect(x: x, y: y, width: w, height: h))
    }

    /// The size of the finished image for a cropped photo of `size` pixels.
    public static func outputSize(photo size: CGSize, recipe: Recipe) -> CGSize {
        layout(photo: size, recipe: recipe).canvas
    }

    /// The watermark's text height, margin and opacity for a photo of `size` pixels.
    public static func watermarkMetrics(photo size: CGSize, recipe: Recipe) -> (height: Double, margin: Double, opacity: Double) {
        let short = Double(min(size.width, size.height))
        let height = recipe.scalar(.watermarkSize, defaults: .generic) / 100 * short
        let margin = recipe.scalar(.watermarkMargin, defaults: .generic) / 100 * short
        let opacity = recipe.scalar(.watermarkOpacity, defaults: .generic) / 100
        return (height, margin, opacity)
    }
}

extension ParamKey {
    // Finishing: border, canvas and watermark (see `Finishing`)
    /// Border on every side, in percent of the cropped photo's short edge.
    public static let borderWidth = ParamKey("finish.border.width")
    /// Extra border below the photo, for a gallery or instant-film look.
    public static let borderBottom = ParamKey("finish.border.bottom")
    /// `.color`; absent is white.
    public static let borderColor = ParamKey("finish.border.color")
    /// `.aspect`: pads the canvas to this ratio, e.g. 4:5. Absent fits the border.
    public static let borderCanvas = ParamKey("finish.border.canvas")
    /// `.watermark`; absent is none.
    public static let watermark = ParamKey("finish.watermark")
    /// Text height in percent of the cropped photo's short edge.
    public static let watermarkSize = ParamKey("finish.watermark.size")
    public static let watermarkOpacity = ParamKey("finish.watermark.opacity")
    /// Distance from the photo's edges, in percent of its short edge.
    public static let watermarkMargin = ParamKey("finish.watermark.margin")
}
