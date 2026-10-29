import Foundation
import ImageIO

/// Fujifilm film simulations: built-in presets with the same names, and detection
/// of the simulation a RAF (or Fuji JPEG) was shot with.
///
/// The presets are approximations built from this app's own controls, tuned by eye
/// to echo each simulation's character. They are not Fujifilm's rendering, and the
/// names are Fujifilm's trademarks, used only to say which look they aim for.
public enum FilmSimulations {
    public static let collection = "Fujifilm"

    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", n))! }

    private static func wheel(_ hue: Double, _ strength: Double) -> ParamValue {
        let radians = hue * .pi / 180
        return .point(x: cos(radians) * strength, y: sin(radians) * strength)
    }

    private static func preset(_ n: Int, _ name: String, _ params: [ParamKey: ParamValue]) -> Preset {
        var preset = Preset(id: id(n), name: name, groups: [.light, .color, .grade, .effects], params: params, isBuiltIn: true)
        preset.collection = collection
        return preset
    }

    private static let gentleS: ParamValue = .curve([CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.22), CurvePoint(x: 0.75, y: 0.79), CurvePoint(x: 1, y: 1)])
    private static let fadedS: ParamValue = .curve([CurvePoint(x: 0, y: 0.05), CurvePoint(x: 0.25, y: 0.24), CurvePoint(x: 0.75, y: 0.78), CurvePoint(x: 1, y: 0.97)])

    public static let presets: [Preset] = [
        preset(1, "Provia", [.contrast: .scalar(8), .vibrance: .scalar(5)]),
        preset(2, "Velvia", [
            .contrast: .scalar(22), .saturation: .scalar(28), .vibrance: .scalar(12), .blacks: .scalar(-12),
            .hsl(.green, .saturation): .scalar(10), .hsl(.blue, .saturation): .scalar(12),
        ]),
        preset(3, "Astia", [
            .contrast: .scalar(-6), .highlights: .scalar(-12), .saturation: .scalar(6),
            .hsl(.orange, .luminance): .scalar(6), .hsl(.blue, .saturation): .scalar(8),
        ]),
        preset(4, "Classic Chrome", [
            .contrast: .scalar(14), .shadows: .scalar(-12), .highlights: .scalar(-15), .saturation: .scalar(-22),
            .hsl(.blue, .hue): .scalar(-10), .hsl(.blue, .saturation): .scalar(-18), .hsl(.red, .saturation): .scalar(-10),
            .hsl(.green, .hue): .scalar(14), .hsl(.green, .saturation): .scalar(-28), .hsl(.yellow, .saturation): .scalar(-12),
            .gradeWheel(.shadows): wheel(195, 0.18), .gradeWheel(.highlights): wheel(45, 0.12), .toneCurve: gentleS,
        ]),
        preset(5, "Classic Neg.", [
            .contrast: .scalar(22), .saturation: .scalar(-12), .highlights: .scalar(-10),
            .hsl(.red, .hue): .scalar(6), .hsl(.green, .hue): .scalar(18), .hsl(.green, .saturation): .scalar(-15),
            .hsl(.blue, .hue): .scalar(-12), .hsl(.yellow, .hue): .scalar(-8),
            .gradeWheel(.shadows): wheel(185, 0.28), .gradeWheel(.highlights): wheel(25, 0.18), .toneCurve: gentleS,
        ]),
        preset(6, "Nostalgic Neg.", [
            .contrast: .scalar(-4), .saturation: .scalar(-6), .blacks: .scalar(8), .highlights: .scalar(-10),
            .gradeWheel(.highlights): wheel(42, 0.32), .gradeWheel(.midtones): wheel(35, 0.12), .gradeWheel(.shadows): wheel(20, 0.08),
            .hsl(.orange, .saturation): .scalar(8), .hsl(.blue, .saturation): .scalar(-10),
        ]),
        preset(7, "Pro Neg. Hi", [
            .contrast: .scalar(10), .saturation: .scalar(-10), .hsl(.orange, .hue): .scalar(-4), .hsl(.orange, .luminance): .scalar(6),
        ]),
        preset(8, "Pro Neg. Std", [
            .contrast: .scalar(-12), .saturation: .scalar(-15), .shadows: .scalar(8), .hsl(.orange, .luminance): .scalar(6),
        ]),
        preset(9, "Eterna", [
            .contrast: .scalar(-30), .saturation: .scalar(-30), .highlights: .scalar(-30), .shadows: .scalar(20),
            .gradeWheel(.shadows): wheel(190, 0.14), .toneCurve: fadedS,
        ]),
        preset(10, "Eterna Bleach Bypass", [
            .contrast: .scalar(40), .saturation: .scalar(-60), .clarity: .scalar(20), .blacks: .scalar(-15), .highlights: .scalar(-15),
        ]),
        preset(11, "Reala Ace", [.contrast: .scalar(10), .saturation: .scalar(4), .hsl(.green, .saturation): .scalar(-5)]),
        preset(12, "Acros", [
            .saturation: .scalar(-100), .contrast: .scalar(22), .clarity: .scalar(10), .blacks: .scalar(-8),
            .hsl(.red, .luminance): .scalar(-8), .grainAmount: .scalar(22), .grainSize: .scalar(20),
        ]),
        preset(13, "Monochrome", [.saturation: .scalar(-100), .contrast: .scalar(8)]),
        preset(14, "Sepia", [.saturation: .scalar(-100), .gradeWheel(.global): wheel(38, 0.45), .contrast: .scalar(-5)]),
    ]

    /// The preset name for the `FilmSimulation` code Fujifilm writes in EXIF
    /// (exiftool's FilmMode), or nil for codes we don't know.
    public static func name(forCode code: Int) -> String? {
        switch code {
        case 0x000: "Provia"
        case 0x100, 0x110, 0x120, 0x130, 0x300: "Astia"
        case 0x200, 0x400: "Velvia"
        case 0x500: "Pro Neg. Std"
        case 0x501: "Pro Neg. Hi"
        case 0x600: "Classic Chrome"
        case 0x700: "Eterna"
        case 0x800: "Classic Neg."
        case 0x900: "Eterna Bleach Bypass"
        case 0xA00: "Nostalgic Neg."
        case 0xB00: "Reala Ace"
        default: nil
        }
    }

    /// Reads the film simulation from image metadata, if the camera recorded one.
    public static func detect(in properties: [CFString: Any]) -> String? {
        // Look up by string: CFString-keyed Swift dictionaries don't reliably match
        // keys that came from ImageIO.
        let byName = Dictionary(properties.map { ($0.key as String, $0.value) }, uniquingKeysWith: { first, _ in first })
        guard let style = byName["{PictureStyle}"] as? [String: Any] else { return nil }
        // Each entry is (label, value, default); the label is a string.
        func code(_ key: String) -> Int? {
            guard let entry = style[key] as? [Any] else { return nil }
            if entry.count > 1, let value = entry[1] as? Int { return value }
            return (entry.first as? String).flatMap { Int($0) } ?? entry.first as? Int
        }
        if let monochrome = code("Monochrome"), monochrome != 0 { return "Monochrome" }
        guard let code = code("FilmSimulation") else { return nil }
        return name(forCode: code)
    }

    public static func preset(named name: String) -> Preset? {
        presets.first { $0.name == name }
    }
}
