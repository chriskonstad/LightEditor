import Foundation

/// One control point of a tone curve, both axes in 0...1.
public struct CurvePoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }
}

/// A reference to a .cube LUT by the SHA-256 of its file contents.
public struct LUTRef: Codable, Sendable, Hashable {
    public var hash: String
    public var name: String

    public init(hash: String, name: String) {
        self.hash = hash
        self.name = name
    }
}

/// A rectangle in normalized coordinates (0...1), origin at the top left of the
/// straightened image.
public struct NormalizedRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isFull: Bool {
        abs(x) < 1e-6 && abs(y) < 1e-6 && abs(width - 1) < 1e-6 && abs(height - 1) < 1e-6
    }
}

/// A crop aspect constraint, e.g. 3:2. Width and height are swapped for portrait crops.
public struct AspectRatio: Codable, Sendable, Hashable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }

    public var value: Double { Double(width) / Double(height) }
    public var description: String { "\(width):\(height)" }

    /// 65:24 is the Hasselblad XPan's panoramic frame.
    public static let presets: [AspectRatio] = [
        AspectRatio(1, 1), AspectRatio(4, 5), AspectRatio(3, 2), AspectRatio(4, 3), AspectRatio(16, 9), AspectRatio(65, 24),
    ]

    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        let parts = string.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad aspect \(string)"))
        }
        width = parts[0]
        height = parts[1]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// The crop and straighten state of a photo.
public struct CropGeometry: Codable, Sendable, Hashable {
    public var rect: NormalizedRect
    /// Straighten angle in degrees, positive is counter-clockwise.
    public var angle: Double
    public var aspect: AspectRatio?
    /// Set when the angle came from auto straighten, so pasting it finds each
    /// photo's own level instead of copying the angle.
    public var auto: AutoStraighten?

    public init(rect: NormalizedRect = .full, angle: Double = 0, aspect: AspectRatio? = nil, auto: AutoStraighten? = nil) {
        self.rect = rect
        self.angle = angle
        self.aspect = aspect
        self.auto = auto
    }

    public var isIdentity: Bool { rect.isFull && abs(angle) < 1e-6 }

    /// For pasting onto another photo: auto straighten is found again there,
    /// keeping the fine-tune; the angle stays as the fallback.
    public var forPasting: CropGeometry {
        var copy = self
        if let auto { copy.auto = AutoStraighten(method: nil, detected: nil, tweak: auto.tweak) }
        return copy
    }

    /// Sets the angle by hand. With auto straighten on, the difference from the
    /// found angle is kept as the fine-tune.
    public mutating func setAngle(_ newAngle: Double) {
        angle = newAngle
        if var auto, let detected = auto.detected {
            auto.tweak = newAngle - detected
            self.auto = auto
        }
    }
}

/// How a straighten angle was found automatically.
public struct AutoStraighten: Codable, Sendable, Hashable {
    public enum Method: String, Codable, Sendable {
        /// The camera's electronic level, from the file.
        case camera
        /// Apple's horizon detection.
        case horizon

        public var displayName: String { self == .camera ? "Camera level" : "Horizon" }
    }

    /// What found `detected`; nil until found for this photo (e.g. just pasted).
    public var method: Method?
    /// The angle found for this photo, in degrees; nil until found.
    public var detected: Double?
    /// The fine-tune on top of the found angle, in degrees.
    public var tweak: Double

    public init(method: Method?, detected: Double?, tweak: Double = 0) {
        self.method = method
        self.detected = detected
        self.tweak = tweak
    }

    public var isResolved: Bool { detected != nil }
}

/// The value of one recipe parameter.
///
/// Scalars encode as bare JSON numbers to keep adjustment data small; the other cases
/// encode as small objects tagged by a single distinguishing key.
public enum ParamValue: Sendable, Hashable {
    case scalar(Double)
    case point(x: Double, y: Double)
    case curve([CurvePoint])
    case lut(LUTRef, amount: Double)
    case crop(CropGeometry)
    case mask(MaskLayer)
    case retouch(RetouchSpot)

    public var scalarValue: Double? {
        if case .scalar(let value) = self { return value }
        return nil
    }

    public var pointValue: (x: Double, y: Double)? {
        if case .point(let x, let y) = self { return (x, y) }
        return nil
    }
}

extension ParamValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case x, y, curve, lut, name, amount, crop, angle, aspect, level, mask, retouch
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let number = try? single.decode(Double.self) {
            self = .scalar(number)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.curve) {
            self = .curve(try container.decode([CurvePoint].self, forKey: .curve))
        } else if container.contains(.lut) {
            let ref = LUTRef(
                hash: try container.decode(String.self, forKey: .lut),
                name: try container.decodeIfPresent(String.self, forKey: .name) ?? "LUT"
            )
            self = .lut(ref, amount: try container.decodeIfPresent(Double.self, forKey: .amount) ?? 1)
        } else if container.contains(.crop) {
            self = .crop(CropGeometry(
                rect: try container.decode(NormalizedRect.self, forKey: .crop),
                angle: try container.decodeIfPresent(Double.self, forKey: .angle) ?? 0,
                aspect: try container.decodeIfPresent(AspectRatio.self, forKey: .aspect),
                auto: try container.decodeIfPresent(AutoStraighten.self, forKey: .level)
            ))
        } else if container.contains(.retouch) {
            self = .retouch(try container.decode(RetouchSpot.self, forKey: .retouch))
        } else if container.contains(.mask) {
            self = .mask(try container.decode(MaskLayer.self, forKey: .mask))
        } else if container.contains(.x) {
            self = .point(x: try container.decode(Double.self, forKey: .x), y: try container.decode(Double.self, forKey: .y))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown parameter value"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .scalar(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .point(let x, let y):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
        case .curve(let points):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(points, forKey: .curve)
        case .lut(let ref, let amount):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(ref.hash, forKey: .lut)
            try container.encode(ref.name, forKey: .name)
            try container.encode(amount, forKey: .amount)
        case .crop(let geometry):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(geometry.rect, forKey: .crop)
            try container.encode(geometry.angle, forKey: .angle)
            try container.encodeIfPresent(geometry.aspect, forKey: .aspect)
            try container.encodeIfPresent(geometry.auto, forKey: .level)
        case .mask(let layer):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(layer, forKey: .mask)
        case .retouch(let spot):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(spot, forKey: .retouch)
        }
    }
}
