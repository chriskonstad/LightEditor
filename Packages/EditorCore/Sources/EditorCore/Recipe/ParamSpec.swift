import Foundation

/// Where a parameter is applied. RAW-stage parameters change the cached decode;
/// grade-stage parameters run live on top of it.
public enum PipelineStage: Sendable, Hashable {
    case rawDecode
    case grade
    /// Border, canvas and watermark, on the cropped, graded photo (see `Finishing`).
    case finishing
    /// Changes only how the saved image is encoded, not how it looks.
    case output
}

/// The groups offered in the paste sheet.
public enum PasteGroup: String, CaseIterable, Sendable, Codable, Identifiable {
    case whiteBalance, light, color, grade, filmLUT, effects, detail, crop, masks, retouch, finishing, photosCopy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .whiteBalance: "White balance"
        case .light: "Light"
        case .color: "Color"
        case .grade: "Color grading"
        case .filmLUT: "Film LUT (.cube)"
        case .effects: "Effects"
        case .detail: "Detail and noise"
        case .crop: "Crop"
        case .masks: "Masks"
        case .retouch: "Retouch"
        case .finishing: "Border and watermark"
        case .photosCopy: "Saved image size"
        }
    }

    public var subtitle: String? {
        switch self {
        case .detail: "Re-decodes, slower"
        case .crop: "Per photo"
        case .masks: "AI masks re-detect on each photo"
        case .retouch: "Per photo"
        case .finishing: "Frame, canvas and text"
        case .photosCopy: "Resolution and quality of the image saved to Photos"
        default: nil
        }
    }

    /// Whether the group is ticked by default in the paste sheet. Everything but
    /// Crop and Retouch, which are specific to one photo, and the border, watermark
    /// and saved image's size, which aren't part of the look.
    public var isOnByDefault: Bool { ![.crop, .retouch, .finishing, .photosCopy].contains(self) }

    public static var defaultSelection: Set<PasteGroup> {
        Set(allCases.filter(\.isOnByDefault))
    }

    public var keys: [ParamKey] { ParamCatalog.all.filter { $0.group == self }.map(\.key) }
}

/// Static description of one parameter: its range, default and where it lives.
public struct ParamSpec: Sendable, Identifiable {
    public enum Kind: Sendable {
        case scalar(range: ClosedRange<Double>, defaultValue: Double?)
        case point
        case curve
        case lut
        case crop
        case mask
        case retouch
        case color
        case aspect
        case watermark
    }

    public let key: ParamKey
    public let label: String
    public let kind: Kind
    public let group: PasteGroup
    public let stage: PipelineStage

    public var id: ParamKey { key }

    public var range: ClosedRange<Double>? {
        if case .scalar(let range, _) = kind { return range }
        return nil
    }

    /// The fixed default for scalars. `nil` means the default depends on the photo,
    /// like as-shot white balance; see `PhotoDefaults`.
    public var fixedDefault: Double? {
        if case .scalar(_, let value) = kind { return value }
        return nil
    }

    public func clamp(_ value: Double) -> Double {
        guard let range else { return value }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Every parameter the editor knows about.
public enum ParamCatalog {
    private static func scalar(
        _ key: ParamKey, _ label: String, _ group: PasteGroup,
        range: ClosedRange<Double> = -100...100, defaultValue: Double? = 0, stage: PipelineStage = .grade
    ) -> ParamSpec {
        ParamSpec(key: key, label: label, kind: .scalar(range: range, defaultValue: defaultValue), group: group, stage: stage)
    }

    public static let all: [ParamSpec] = {
        var specs: [ParamSpec] = [
            scalar(.temperature, "Temperature", .whiteBalance, range: 2000...50000, defaultValue: nil),
            scalar(.tint, "Tint", .whiteBalance, range: -150...150, defaultValue: nil),

            scalar(.exposure, "Exposure", .light, range: -5...5),
            scalar(.contrast, "Contrast", .light),
            scalar(.highlights, "Highlights", .light),
            scalar(.shadows, "Shadows", .light),
            scalar(.whites, "Whites", .light),
            scalar(.blacks, "Blacks", .light),
            ParamSpec(key: .toneCurve, label: "Tone curve", kind: .curve, group: .light, stage: .grade),
            scalar(.clarity, "Clarity", .light),
            scalar(.texture, "Texture", .light),
            scalar(.dehaze, "Dehaze", .light),

            scalar(.vibrance, "Vibrance", .color),
            scalar(.saturation, "Saturation", .color),
        ]
        for band in HueBand.allCases {
            for component in HSLComponent.allCases {
                specs.append(scalar(.hsl(band, component), "\(band.displayName) \(component.rawValue)", .color))
            }
        }
        for range in ToneRange.allCases {
            specs.append(ParamSpec(key: .gradeWheel(range), label: range.displayName, kind: .point, group: .grade, stage: .grade))
            specs.append(scalar(.gradeLuminance(range), "\(range.displayName) luminance", .grade))
        }
        specs += [
            scalar(.gradeBlending, "Blending", .grade, range: 0...100, defaultValue: 50),
            scalar(.gradeBalance, "Balance", .grade),

            ParamSpec(key: .lut, label: "Film LUT", kind: .lut, group: .filmLUT, stage: .grade),

            scalar(.vignetteAmount, "Vignette", .effects),
            scalar(.vignetteMidpoint, "Midpoint", .effects, range: 0...100, defaultValue: 50),
            scalar(.grainAmount, "Grain", .effects, range: 0...100),
            scalar(.grainSize, "Grain size", .effects, range: 0...100, defaultValue: 25),

            // Detail defaults come from the RAW decoder for each camera.
            scalar(.noiseReduction, "Noise reduction", .detail, range: 0...100, defaultValue: nil, stage: .rawDecode),
            scalar(.colorNoise, "Color noise", .detail, range: 0...100, defaultValue: nil, stage: .rawDecode),
            scalar(.sharpness, "Sharpness", .detail, range: 0...100, defaultValue: nil, stage: .rawDecode),
            scalar(.detail, "Detail", .detail, range: 0...100, defaultValue: nil, stage: .rawDecode),
            scalar(.lensCorrection, "Lens corrections", .detail, range: 0...1, defaultValue: 1, stage: .rawDecode),
            scalar(.moire, "Moiré reduction", .detail, range: 0...100, defaultValue: 0, stage: .rawDecode),
            scalar(.lensDistortion, "Distortion", .detail),
            scalar(.lensFringeRed, "Red/cyan fringe", .detail),
            scalar(.lensFringeBlue, "Blue/yellow fringe", .detail),
            scalar(.lensVignette, "Lens vignetting", .detail),
            scalar(.lensVignetteMidpoint, "Lens vignetting midpoint", .detail, range: 0...100, defaultValue: 50),

            ParamSpec(key: .crop, label: "Crop", kind: .crop, group: .crop, stage: .grade),
            scalar(.perspectiveVertical, "Vertical", .crop),
            scalar(.perspectiveHorizontal, "Horizontal", .crop),
            scalar(.borderWidth, "Border", .finishing, range: 0...25, stage: .finishing),
            scalar(.borderBottom, "Extra bottom", .finishing, range: 0...50, stage: .finishing),
            ParamSpec(key: .borderColor, label: "Border color", kind: .color, group: .finishing, stage: .finishing),
            ParamSpec(key: .borderCanvas, label: "Canvas", kind: .aspect, group: .finishing, stage: .finishing),
            ParamSpec(key: .watermark, label: "Watermark", kind: .watermark, group: .finishing, stage: .finishing),
            scalar(.watermarkSize, "Watermark size", .finishing, range: 1...20, defaultValue: 4, stage: .finishing),
            scalar(.watermarkOpacity, "Watermark opacity", .finishing, range: 5...100, defaultValue: 80, stage: .finishing),
            scalar(.watermarkMargin, "Watermark margin", .finishing, range: 0...20, defaultValue: 4, stage: .finishing),

            // Absent means this device's default from Settings (`PhotosCopy.deviceDefault`).
            scalar(.photosMaxMegapixels, "Maximum size", .photosCopy, range: 0...1000, defaultValue: nil, stage: .output),
            scalar(.photosQuality, "Quality", .photosCopy, range: PhotosCopy.qualityRange, defaultValue: nil, stage: .output),
        ]
        return specs
    }()

    private static let byKey: [ParamKey: ParamSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    /// The spec for a key. Mask layers (`mask.<id>`) share one dynamic spec.
    public static func spec(for key: ParamKey) -> ParamSpec? {
        if let spec = byKey[key] { return spec }
        if key.isMask { return ParamSpec(key: key, label: "Mask", kind: .mask, group: .masks, stage: .grade) }
        if key.isRetouch { return ParamSpec(key: key, label: "Retouch", kind: .retouch, group: .retouch, stage: .grade) }
        return nil
    }

    public static let rawStageKeys: [ParamKey] = all.filter { $0.stage == .rawDecode }.map(\.key)
}

/// Defaults that depend on the photo: as-shot white balance and the decoder's
/// per-camera detail settings. Values are in recipe units.
public struct PhotoDefaults: Codable, Sendable, Hashable {
    public var values: [ParamKey: Double]

    public init(values: [ParamKey: Double] = [:]) { self.values = values }

    /// Defaults for a photo we know nothing about, e.g. a JPEG.
    public static let generic = PhotoDefaults(values: [
        .temperature: 6500, .tint: 0,
        .noiseReduction: 0, .colorNoise: 0, .sharpness: 0, .detail: 0,
    ])

    /// The default for a scalar key, fixed or photo-dependent.
    public func value(for key: ParamKey) -> Double {
        if let fixed = ParamCatalog.spec(for: key)?.fixedDefault { return fixed }
        return values[key] ?? PhotoDefaults.genericValue(key)
    }

    private static func genericValue(_ key: ParamKey) -> Double {
        generic.values[key] ?? 0
    }
}
