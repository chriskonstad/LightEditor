import Foundation

/// A point in normalized image coordinates: origin top-left of the original
/// (uncropped, uncorrected) image, both axes 0...1.
public struct NormalizedPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    // Encoded as a compact [x, y] pair rounded to 1/10 000, so brush strokes stay small.
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode((x * 10_000).rounded() / 10_000)
        try container.encode((y * 10_000).rounded() / 10_000)
    }
}

/// One painted stroke. Sizes are fractions of the image's long edge.
public struct BrushStroke: Codable, Sendable, Hashable {
    public var points: [NormalizedPoint]
    public var radius: Double
    /// 0 is a hard edge; 1 fades over the whole radius.
    public var feather: Double
    /// Opacity of the stroke, 0...1.
    public var flow: Double
    public var erase: Bool

    public init(points: [NormalizedPoint], radius: Double, feather: Double = 0.5, flow: Double = 1, erase: Bool = false) {
        self.points = points
        self.radius = radius
        self.feather = feather
        self.flow = flow
        self.erase = erase
    }

    /// Drops points closer together than a fraction of the radius, to keep recipes small.
    public func simplified(spacing: Double = 0.2) -> BrushStroke {
        guard points.count > 2 else { return self }
        var kept = [points[0]]
        let minimum = radius * spacing
        for point in points.dropFirst().dropLast() where hypot(point.x - kept.last!.x, point.y - kept.last!.y) >= minimum {
            kept.append(point)
        }
        kept.append(points.last!)
        var copy = self
        copy.points = kept
        return copy
    }
}

/// What an AI mask selects. Regenerated on each device from the original image.
public enum AIMaskKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case subject, people, sky, background

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .subject: "Subject"
        case .people: "People"
        case .sky: "Sky"
        case .background: "Background"
        }
    }

    public var systemImage: String {
        switch self {
        case .subject: "person.and.background.dotted"
        case .people: "person.2"
        case .sky: "cloud.sun"
        case .background: "photo"
        }
    }
}

/// The geometry or selector of one mask component.
public enum MaskShape: Codable, Sendable, Hashable {
    /// Full effect at `start`, fading to none at `end`.
    case linear(start: NormalizedPoint, end: NormalizedPoint)
    /// An ellipse: full effect inside, fading out over `feather` (0...1) of the radius.
    /// Radii are fractions of the image's width and height; `angle` is in degrees.
    case radial(center: NormalizedPoint, radiusX: Double, radiusY: Double, angle: Double, feather: Double)
    case brush(strokes: [BrushStroke])
    /// Gamma-encoded luminance between `low` and `high`, softened by `feather`.
    case luminance(low: Double, high: Double, feather: Double)
    /// Colors near a sampled Oklab color; `range` is the tolerance (0...1).
    case color(l: Double, a: Double, b: Double, range: Double)
    /// An AI selection, computed by Vision.
    case ai(kind: AIMaskKind)
    /// Tap-to-select: the object under the seed points, by Vision iterative segmentation.
    case object(seeds: [NormalizedPoint])

    public var displayName: String {
        switch self {
        case .linear: "Linear gradient"
        case .radial: "Radial gradient"
        case .brush: "Brush"
        case .luminance: "Luminance range"
        case .color: "Color range"
        case .ai(let kind): kind.displayName
        case .object: "Object"
        }
    }

    public var systemImage: String {
        switch self {
        case .linear: "square.bottomhalf.filled"
        case .radial: "circle.circle"
        case .brush: "paintbrush.pointed"
        case .luminance: "circle.lefthalf.filled"
        case .color: "eyedropper"
        case .ai(let kind): kind.systemImage
        case .object: "hand.tap"
        }
    }

    /// Whether the shape is computed by a model (and so needs a cache and a job).
    public var isAI: Bool {
        switch self {
        case .ai, .object: true
        default: false
        }
    }
}

/// One part of a mask, combined with the parts before it.
public struct MaskComponent: Codable, Sendable, Hashable, Identifiable {
    public enum Operation: String, Codable, Sendable, CaseIterable {
        case add, subtract, intersect

        public var displayName: String { rawValue.capitalized }
    }

    public var id: UUID
    public var operation: Operation
    public var inverted: Bool
    public var shape: MaskShape

    public init(id: UUID = UUID(), operation: Operation = .add, inverted: Bool = false, shape: MaskShape) {
        self.id = id
        self.operation = operation
        self.inverted = inverted
        self.shape = shape
    }
}

/// A local adjustment: a mask plus the settings applied through it.
public struct MaskLayer: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Sort order in the mask list; masks apply in this order.
    public var order: Double
    public var components: [MaskComponent]
    /// Local settings, keyed by `MaskLayer.adjustmentKeys`. Absent means zero.
    public var adjustments: [ParamKey: Double]
    /// Overall strength of the layer, 0...1.
    public var amount: Double
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, order: Double, components: [MaskComponent], adjustments: [ParamKey: Double] = [:], amount: Double = 1, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.order = order
        self.components = components
        self.adjustments = adjustments
        self.amount = amount
        self.isEnabled = isEnabled
    }

    /// The local settings a mask offers, all -100...100 except exposure (EV).
    public static let adjustmentKeys: [ParamKey] = [
        .localTemperature, .localTint, .exposure, .contrast, .highlights, .shadows, .whites, .blacks,
        .clarity, .texture, .dehaze, .saturation, .vibrance,
    ]

    public static func range(for key: ParamKey) -> ClosedRange<Double> {
        key == .exposure ? -4...4 : -100...100
    }

    /// The recipe key this layer is stored under.
    public var key: ParamKey { ParamKey.mask(id) }

    /// Whether any component needs a model.
    public var usesAI: Bool { components.contains { $0.shape.isAI } }
}

extension ParamKey {
    /// Relative white balance inside a mask (-100...100), unlike the global absolute Kelvin.
    public static let localTemperature = ParamKey("local.temperature")
    public static let localTint = ParamKey("local.tint")

    public static let maskPrefix = "mask."

    public static func mask(_ id: UUID) -> ParamKey { ParamKey(maskPrefix + id.uuidString) }

    public var isMask: Bool { rawValue.hasPrefix(ParamKey.maskPrefix) }
}

extension Recipe {
    /// Mask layers in application order.
    public var masks: [MaskLayer] {
        params.compactMap { key, value -> MaskLayer? in
            guard key.isMask, case .mask(let layer) = value else { return nil }
            return layer
        }
        .sorted { ($0.order, $0.id.uuidString) < ($1.order, $1.id.uuidString) }
    }

    public mutating func setMask(_ layer: MaskLayer, at stamp: HLCStamp) {
        set(layer.key, .mask(layer), at: stamp)
    }

    public mutating func removeMask(_ id: UUID, at stamp: HLCStamp) {
        set(.mask(id), nil, at: stamp)
    }

    /// The next order value, so new masks go to the end of the list.
    public var nextMaskOrder: Double { (masks.map(\.order).max() ?? 0) + 1 }
}
