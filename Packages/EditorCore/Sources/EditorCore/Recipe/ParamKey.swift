import Foundation

/// The name of one recipe parameter.
///
/// Keys are dotted strings (`light.exposure`, `color.hsl.red.hue`) so the encoded
/// recipe stays readable and stable across app versions. Never rename a key; add a
/// migration instead.
public struct ParamKey: RawRepresentable, Hashable, Comparable, Sendable, Codable, CodingKeyRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
    public static func < (lhs: ParamKey, rhs: ParamKey) -> Bool { lhs.rawValue < rhs.rawValue }

    public var codingKey: any CodingKey { AnyKey(stringValue: rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.rawValue = codingKey.stringValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// The eight hue bands of the HSL mixer.
public enum HueBand: String, CaseIterable, Sendable, Codable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }

    /// Band center as an sRGB hue angle in degrees, used for UI swatches.
    public var swatchHue: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 55
        case .green: 115
        case .aqua: 180
        case .blue: 220
        case .purple: 275
        case .magenta: 315
        }
    }
}

public enum HSLComponent: String, CaseIterable, Sendable, Codable {
    case hue, saturation, luminance

    public var displayName: String { rawValue.capitalized }
}

/// The three tonal ranges of the color grading wheels.
public enum ToneRange: String, CaseIterable, Sendable, Codable, Identifiable {
    case shadows, midtones, highlights, global

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

extension ParamKey {
    // White balance. Absolute Kelvin and tint; absent means "as shot".
    public static let temperature = ParamKey("wb.temperature")
    public static let tint = ParamKey("wb.tint")

    // Light
    public static let exposure = ParamKey("light.exposure")
    public static let contrast = ParamKey("light.contrast")
    public static let highlights = ParamKey("light.highlights")
    public static let shadows = ParamKey("light.shadows")
    public static let whites = ParamKey("light.whites")
    public static let blacks = ParamKey("light.blacks")
    public static let toneCurve = ParamKey("light.toneCurve")

    // Presence (local contrast)
    public static let clarity = ParamKey("light.clarity")
    public static let texture = ParamKey("light.texture")
    public static let dehaze = ParamKey("light.dehaze")

    // Color
    public static let vibrance = ParamKey("color.vibrance")
    public static let saturation = ParamKey("color.saturation")

    public static func hsl(_ band: HueBand, _ component: HSLComponent) -> ParamKey {
        ParamKey("color.hsl.\(band.rawValue).\(component.rawValue)")
    }

    // Grade. The wheel is a point in the unit disc (angle = hue, radius = strength).
    public static func gradeWheel(_ range: ToneRange) -> ParamKey { ParamKey("grade.\(range.rawValue)") }
    public static func gradeLuminance(_ range: ToneRange) -> ParamKey { ParamKey("grade.\(range.rawValue).lum") }
    public static let gradeBlending = ParamKey("grade.blending")
    public static let gradeBalance = ParamKey("grade.balance")

    // Film LUT
    public static let lut = ParamKey("lut.film")

    // Effects
    public static let vignetteAmount = ParamKey("effects.vignette.amount")
    public static let vignetteMidpoint = ParamKey("effects.vignette.midpoint")
    public static let grainAmount = ParamKey("effects.grain.amount")
    public static let grainSize = ParamKey("effects.grain.size")

    // Detail (RAW decode stage)
    public static let noiseReduction = ParamKey("detail.noiseReduction")
    public static let colorNoise = ParamKey("detail.colorNoise")
    public static let sharpness = ParamKey("detail.sharpness")
    public static let detail = ParamKey("detail.detail")
    /// 1 applies the camera's lens profile (distortion, vignetting, color fringing), 0 turns it off.
    public static let lensCorrection = ParamKey("detail.lensCorrection")
    public static let moire = ParamKey("detail.moire")

    // Crop and perspective
    public static let crop = ParamKey("crop.geometry")
    public static let perspectiveVertical = ParamKey("crop.perspective.vertical")
    public static let perspectiveHorizontal = ParamKey("crop.perspective.horizontal")
}
