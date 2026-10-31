import Foundation

/// Sony Creative Looks: built-in presets with the same names, and the look an ARW was
/// shot with, read from Sony's maker notes, so an edit can start from the camera's look.
///
/// The presets are approximations built from this app's own controls, tuned by eye to
/// echo each look's character. They are not Sony's rendering.
public enum SonyLooks {
    public static let collection = "Sony"

    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0002-%012d", n))! }

    private static func preset(_ n: Int, _ code: String, _ params: [ParamKey: ParamValue]) -> Preset {
        var preset = Preset(id: id(n), name: code, groups: [.light, .color, .grade, .effects], params: params, isBuiltIn: true)
        preset.collection = collection
        return preset
    }

    private static let wheel = FilmSimulations.wheel

    /// In the order the camera lists them, named by the camera's codes.
    public static let presets: [Preset] = [
        preset(1, "ST", [.contrast: .scalar(6)]),
        preset(2, "PT", [
            .contrast: .scalar(-8), .saturation: .scalar(-6),
            .hsl(.orange, .luminance): .scalar(6), .hsl(.orange, .saturation): .scalar(-5), .hsl(.red, .saturation): .scalar(-4),
        ]),
        preset(3, "NT", [.contrast: .scalar(-12), .saturation: .scalar(-20), .highlights: .scalar(-6)]),
        preset(4, "VV", [.contrast: .scalar(18), .saturation: .scalar(24), .vibrance: .scalar(10), .blacks: .scalar(-6)]),
        preset(5, "VV2", [
            .contrast: .scalar(12), .saturation: .scalar(10), .vibrance: .scalar(16),
            .hsl(.blue, .saturation): .scalar(8), .hsl(.green, .saturation): .scalar(6),
        ]),
        // Moody, contrasty and calm: muted color, teal shadows, a slightly lifted floor,
        // and skies and greens that still carry.
        preset(6, "FL", [
            .contrast: .scalar(16), .saturation: .scalar(-18), .highlights: .scalar(-12), .blacks: .scalar(6),
            .hsl(.green, .hue): .scalar(10), .hsl(.green, .saturation): .scalar(-6), .hsl(.blue, .saturation): .scalar(8),
            .hsl(.orange, .saturation): .scalar(-8),
            .gradeWheel(.shadows): wheel(200, 0.14), .gradeWheel(.highlights): wheel(40, 0.08),
            .toneCurve: FilmSimulations.gentleS,
        ]),
        // Matte: low contrast and saturation, lifted blacks, a little warmth.
        preset(7, "IN", [
            .contrast: .scalar(-24), .saturation: .scalar(-24), .highlights: .scalar(-10), .blacks: .scalar(12),
            .gradeWheel(.midtones): wheel(40, 0.08), .toneCurve: FilmSimulations.fadedS,
        ]),
        // Bright, soft and clear.
        preset(8, "SH", [
            .contrast: .scalar(-14), .shadows: .scalar(20), .whites: .scalar(6), .blacks: .scalar(6),
            .saturation: .scalar(6), .vibrance: .scalar(12),
        ]),
        preset(9, "BW", [.saturation: .scalar(-100), .contrast: .scalar(12)]),
        preset(10, "SE", [.saturation: .scalar(-100), .gradeWheel(.global): wheel(38, 0.42), .contrast: .scalar(-5)]),
    ]

    public static func preset(code: String) -> Preset? {
        presets.first { $0.name == code }
    }

    /// The look and adjustments a Sony camera recorded.
    public struct CameraSettings: Sendable, Hashable, Codable {
        /// The Creative Look's code ("FL", "ST"…), or nil for looks without a preset.
        public var look: String?
        /// Creative Look adjustments as the camera shows them: -9...+9, fade 0...9.
        public var contrast = 0
        public var highlights = 0
        public var shadows = 0
        public var fade = 0
        public var saturation = 0
        public var clarity = 0
        /// White balance shift in the camera's steps: positive is amber, and magenta.
        public var amberBlue = 0.0
        public var greenMagenta = 0.0

        public init(look: String?) { self.look = look }

        var adjustments: [(String, Int)] {
            [("Contrast", contrast), ("Highlights", highlights), ("Shadows", shadows),
             ("Fade", fade), ("Saturation", saturation), ("Clarity", clarity)].filter { $0.1 != 0 }
        }

        /// "A+1.5 G0.5": how the camera writes a white balance shift; empty with none.
        public var whiteBalanceShift: String {
            func step(_ value: Double, _ positive: String, _ negative: String) -> String? {
                guard abs(value) >= 0.05 else { return nil }
                let amount = String(format: "%g", (abs(value) * 10).rounded() / 10)
                return value > 0 ? "\(positive)+\(amount)" : "\(negative)\(amount)"
            }
            return [step(amberBlue, "A", "B"), step(greenMagenta, "M", "G")].compactMap { $0 }.joined(separator: " ")
        }

        /// "FL · Contrast +2 · WB A+1.5", for the editor's "Shot as" line.
        public var summary: String {
            var parts = [look ?? "Camera look"]
            // Fade only goes up from 0, so it has no sign.
            parts += adjustments.map { "\($0.0) \($0.1 > 0 && $0.0 != "Fade" ? "+" : "")\($0.1)" }
            if !whiteBalanceShift.isEmpty { parts.append("WB \(whiteBalanceShift)") }
            return parts.joined(separator: " · ")
        }
    }

    /// Reads the look from an ARW's maker notes; nil for other files and unknown looks.
    public static func read(fileAt url: URL) -> CameraSettings? {
        guard ["arw", "srf", "sr2"].contains(url.pathExtension.lowercased()),
              let notes = SonyMakerNote(fileAt: url) else { return nil }
        return settings(from: notes)
    }

    static func settings(from notes: SonyMakerNote) -> CameraSettings? {
        guard let style = notes.strings[0xb020], let look = code(forCreativeStyle: style) else { return nil }
        var settings = CameraSettings(look: look)
        settings.contrast = notes.integer(0x2004) ?? 0
        settings.saturation = notes.integer(0x2005) ?? 0
        settings.shadows = notes.integer(0x2032) ?? 0
        settings.highlights = notes.integer(0x2033) ?? 0
        settings.fade = notes.integer(0x2034) ?? 0
        settings.clarity = notes.integer(0x2036) ?? 0
        if let shift = notes.integers[0x2026], shift.count == 2 {
            settings.amberBlue = Double(shift[0]) / 1000
            settings.greenMagenta = Double(shift[1]) / 1000
        }
        return settings
    }

    /// The Creative Look code for Sony's CreativeStyle string (exiftool's names), or nil
    /// for older Creative Styles we have no preset for.
    static func code(forCreativeStyle style: String) -> String? {
        switch style {
        case "Standard": "ST"
        case "Portrait": "PT"
        case "Neutral": "NT"
        case "Vivid": "VV"
        case "BW": "BW"
        case "Sepia": "SE"
        case "VV2", "FL", "IN", "SH": style
        default: nil
        }
    }

    /// The look's preset with the camera's adjustments added on top.
    ///
    /// The white balance shift is left out: Sony bakes it into the RAW's as-shot white
    /// balance, which the editor already starts from.
    public static func cameraPreset(for settings: CameraSettings) -> Preset? {
        guard let look = settings.look, let index = presets.firstIndex(where: { $0.name == look }) else { return nil }
        var preset = presets[index]
        func add(_ key: ParamKey, _ amount: Double) {
            guard amount != 0 else { return }
            let current = preset.params[key].flatMap { if case .scalar(let value) = $0 { value } else { nil } } ?? 0
            preset.params[key] = .scalar(min(max(current + amount, -100), 100))
        }
        // Each camera step is worth a few points on this app's -100...100 sliders.
        add(.contrast, Double(settings.contrast) * 5 - Double(settings.fade) * 2)
        add(.highlights, Double(settings.highlights) * 6)
        add(.shadows, Double(settings.shadows) * 6)
        add(.blacks, Double(settings.fade) * 3)
        add(.saturation, Double(settings.saturation) * 6)
        add(.clarity, Double(settings.clarity) * 5)
        // Stable per look, so the editor can tell it's the one already applied.
        preset.id = UUID(uuidString: String(format: "00000000-0000-0000-0003-%012d", index + 1))!
        preset.name = settings.summary
        preset.collection = nil
        return preset
    }
}
