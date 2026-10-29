import Foundation

/// Best-effort import of Lightroom / Camera Raw presets and sidecars (`crs:` XMP).
///
/// Adobe's tone and color math is proprietary, so mapped values approximate the
/// look rather than reproduce it. The mapping table lives in docs/DESIGN.md. Every
/// `crs:` setting with a non-default value that we can't map is reported back so
/// the UI can tell the user what was skipped.
public enum XMPImporter {
    public struct Result: Sendable {
        public var preset: Preset
        /// `crs:` names that had a value but no equivalent here, e.g. "Clarity2012".
        public var unmapped: [String]
    }

    public enum ImportError: Error, LocalizedError {
        case notXMP
        case noSettings

        public var errorDescription: String? {
            switch self {
            case .notXMP: "This file isn't a readable XMP preset."
            case .noSettings: "The XMP file has no Lightroom settings in it."
            }
        }
    }

    /// Settings that carry no look and are never reported as unmapped.
    static let ignored: Set<String> = [
        "Version", "ProcessVersion", "HasSettings", "HasCrop", "AlreadyApplied", "PresetType", "UUID", "SupportsAmount",
        "SupportsColor", "SupportsMonochrome", "SupportsHighDynamicRange", "SupportsNormalDynamicRange", "SupportsSceneReferred",
        "SupportsOutputReferred", "Name", "ShortName", "SortName", "Group", "Description", "Copyright", "ContactInfo",
        "CameraModelRestriction", "Cluster", "RequiresRGBTables", "WhiteBalance", "ToneCurveName2012", "ToneCurveName",
        "OverrideLookVignette", "CompatibleVersion", "RawFileName", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue",
        "ConvertToGrayscale", "Look",
    ]

    static let directScalars: [String: (ParamKey, Double)] = [
        "Exposure2012": (.exposure, 1), "Contrast2012": (.contrast, 1), "Highlights2012": (.highlights, 1),
        "Shadows2012": (.shadows, 1), "Whites2012": (.whites, 1), "Blacks2012": (.blacks, 1),
        "Temperature": (.temperature, 1), "Tint": (.tint, 1),
        "Vibrance": (.vibrance, 1), "Saturation": (.saturation, 1),
        "PostCropVignetteAmount": (.vignetteAmount, 1), "PostCropVignetteMidpoint": (.vignetteMidpoint, 1),
        "LuminanceSmoothing": (.noiseReduction, 1), "ColorNoiseReduction": (.colorNoise, 1),
        "LensProfileEnable": (.lensCorrection, 1),
        "Sharpness": (.sharpness, 100.0 / 150.0), "SharpenDetail": (.detail, 1),
        "ColorGradeBlending": (.gradeBlending, 1), "ColorGradeBalance": (.gradeBalance, 1),
        "SplitToningBalance": (.gradeBalance, 1),
        "ColorGradeShadowLum": (.gradeLuminance(.shadows), 1), "ColorGradeMidtoneLum": (.gradeLuminance(.midtones), 1),
        "ColorGradeHighlightLum": (.gradeLuminance(.highlights), 1),
        "ColorGradeGlobalLum": (.gradeLuminance(.global), 1),
        "Clarity2012": (.clarity, 1), "Texture": (.texture, 1), "Dehaze": (.dehaze, 1),
        "GrainAmount": (.grainAmount, 1), "GrainSize": (.grainSize, 1),
        "PerspectiveVertical": (.perspectiveVertical, 1), "PerspectiveHorizontal": (.perspectiveHorizontal, 1),
    ]

    static let wheels: [(hue: String, sat: String, range: ToneRange)] = [
        ("ColorGradeShadowHue", "ColorGradeShadowSat", .shadows),
        ("ColorGradeMidtoneHue", "ColorGradeMidtoneSat", .midtones),
        ("ColorGradeHighlightHue", "ColorGradeHighlightSat", .highlights),
        ("ColorGradeGlobalHue", "ColorGradeGlobalSat", .global),
        ("SplitToningShadowHue", "SplitToningShadowSaturation", .shadows),
        ("SplitToningHighlightHue", "SplitToningHighlightSaturation", .highlights),
    ]

    public static func importPreset(from data: Data, fallbackName: String) throws -> Result {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = collector
        guard parser.parse() else { throw ImportError.notXMP }
        var settings = collector.settings
        if settings["WhiteBalance"] == "As Shot" {
            settings["Temperature"] = nil
            settings["Tint"] = nil
        }
        guard !settings.isEmpty || !collector.toneCurve.isEmpty else { throw ImportError.noSettings }

        var params: [ParamKey: ParamValue] = [:]
        var consumed = Set<String>()

        for (name, (key, scale)) in directScalars {
            guard let raw = settings[name], let value = Double(raw.replacingOccurrences(of: "+", with: "")) else { continue }
            consumed.insert(name)
            if let fixed = ParamCatalog.spec(for: key)?.fixedDefault, abs(value * scale - fixed) < 1e-9 { continue }
            params[key] = .scalar(ParamCatalog.spec(for: key)?.clamp(value * scale) ?? value * scale)
        }

        let lightroomBands: [(String, HueBand)] = HueBand.allCases.map { ($0.displayName, $0) }
        for (name, band) in lightroomBands {
            for (prefix, component) in [("HueAdjustment", HSLComponent.hue), ("SaturationAdjustment", .saturation), ("LuminanceAdjustment", .luminance)] {
                let setting = prefix + name
                guard let raw = settings[setting], let value = Double(raw.replacingOccurrences(of: "+", with: "")) else { continue }
                consumed.insert(setting)
                if value != 0 { params[.hsl(band, component)] = .scalar(value) }
            }
        }

        for wheel in wheels {
            guard let hueRaw = settings[wheel.hue], let satRaw = settings[wheel.sat],
                  let hue = Double(hueRaw), let sat = Double(satRaw) else { continue }
            consumed.formUnion([wheel.hue, wheel.sat])
            guard sat != 0 else { continue }
            let radians = hue * .pi / 180
            let strength = min(sat / 100, 1)
            params[.gradeWheel(wheel.range)] = .point(x: cos(radians) * strength, y: sin(radians) * strength)
        }

        if !collector.toneCurve.isEmpty {
            consumed.insert("ToneCurvePV2012")
            let points = collector.toneCurve.map { CurvePoint(x: $0.0 / 255, y: $0.1 / 255) }
            if !points.isIdentityCurve { params[.toneCurve] = .curve(points) }
        }

        var unmapped: [String] = []
        for (name, value) in settings where !consumed.contains(name) && !ignored.contains(name) {
            if let number = Double(value.replacingOccurrences(of: "+", with: "")), number == 0 { continue }
            if value.isEmpty || value == "False" { continue }
            unmapped.append(name)
        }

        let groups = Set(params.keys.compactMap { ParamCatalog.spec(for: $0)?.group }).subtracting([.crop])
        let name = collector.name ?? fallbackName
        return Result(preset: Preset(name: name, groups: groups, params: params), unmapped: unmapped.sorted())
    }

    /// Collects `crs:` attributes and simple elements, the preset name, and the
    /// parametric tone curve.
    private final class Collector: NSObject, XMLParserDelegate {
        var settings: [String: String] = [:]
        var toneCurve: [(Double, Double)] = []
        var name: String?

        private var stack: [String] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            stack.append(elementName)
            text = ""
            for (attribute, value) in attributes where attribute.hasPrefix("crs:") {
                settings[String(attribute.dropFirst(4))] = value
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if elementName == "rdf:li" {
                if stack.contains("crs:ToneCurvePV2012") {
                    let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    if parts.count == 2 { toneCurve.append((parts[0], parts[1])) }
                } else if stack.contains("crs:Name"), name == nil, !value.isEmpty {
                    name = value
                }
            } else if elementName.hasPrefix("crs:"), !value.isEmpty {
                settings[String(elementName.dropFirst(4))] = value
            }
            stack.removeLast()
            text = ""
        }
    }
}
