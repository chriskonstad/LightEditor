import Foundation
import Synchronization

/// A named partial recipe, applied with an amount.
///
/// `groups` lists the paste groups the preset owns. Applying it resets those groups
/// first, so a preset always looks the same no matter what was there before.
public struct Preset: Codable, Sendable, Hashable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var groups: Set<PasteGroup>
    public var params: [ParamKey: ParamValue]
    public var isBuiltIn: Bool
    /// A section title for grouping presets, e.g. "Fujifilm". Nil for the user's own.
    public var collection: String?

    public init(id: UUID = UUID(), name: String, groups: Set<PasteGroup>, params: [ParamKey: ParamValue], isBuiltIn: Bool = false) {
        schemaVersion = Preset.currentSchemaVersion
        self.id = id
        self.name = name
        self.groups = groups
        self.params = params
        self.isBuiltIn = isBuiltIn
    }

    /// Captures the given groups of a recipe as a preset. Crop is never included.
    public init(name: String, from recipe: Recipe, groups: Set<PasteGroup>) {
        let owned = groups.subtracting([.crop, .retouch])
        self.init(name: name, groups: owned, params: recipe.params(in: owned))
    }
}

extension Recipe {
    /// Applies a preset at `amount` (0...1, where 1 is the preset as saved). Scalars and
    /// wheels are interpolated from the photo's defaults; curves blend toward a line.
    public func applying(_ preset: Preset, amount: Double, defaults: PhotoDefaults, stamp: HLCStamp) -> Recipe {
        var result = self
        let amount = min(max(amount, 0), 2)
        for spec in ParamCatalog.all where preset.groups.contains(spec.group) {
            let key = spec.key
            guard let value = preset.params[key] else {
                result.set(key, nil, at: stamp)
                continue
            }
            switch value {
            case .scalar(let target):
                let base = defaults.value(for: key)
                result.setScalar(key, base + (target - base) * amount, at: stamp)
            case .point(let x, let y):
                result.set(key, .point(x: x * amount, y: y * amount), at: stamp)
            case .curve(let points):
                result.set(key, .curve(points.map { CurvePoint(x: $0.x, y: $0.x + ($0.y - $0.x) * amount) }), at: stamp)
            case .lut(let ref, let lutAmount):
                result.set(key, .lut(ref, amount: min(lutAmount * amount, 1)), at: stamp)
            case .crop, .mask, .retouch:
                continue
            }
        }
        if preset.groups.contains(.masks) {
            // Adaptive presets: their (usually AI) masks replace the photo's, scaled by amount.
            for layer in result.masks { result.removeMask(layer.id, at: stamp) }
            for (key, value) in preset.params where key.isMask {
                guard case .mask(var layer) = value else { continue }
                layer.amount = min(layer.amount * amount, 1)
                result.setMask(layer, at: stamp)
            }
        }
        return result
    }
}

/// The presets that ship with the app, so the Presets tab is useful from day one.
public enum BuiltInPresets {
    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    public static let all: [Preset] = [
        Preset(id: id(1), name: "Vivid", groups: [.light, .color], params: [
            .contrast: .scalar(20), .vibrance: .scalar(30), .saturation: .scalar(5), .shadows: .scalar(15), .highlights: .scalar(-15),
        ], isBuiltIn: true),
        Preset(id: id(2), name: "Warm travel", groups: [.light, .color, .grade], params: [
            .contrast: .scalar(10), .vibrance: .scalar(15),
            .gradeWheel(.highlights): .point(x: 0.42, y: 0.32), .gradeWheel(.shadows): .point(x: -0.15, y: -0.2),
            .hsl(.blue, .saturation): .scalar(-10), .hsl(.orange, .luminance): .scalar(8),
        ], isBuiltIn: true),
        Preset(id: id(3), name: "Teal & orange", groups: [.color, .grade], params: [
            .gradeWheel(.shadows): .point(x: -0.35, y: -0.15), .gradeWheel(.highlights): .point(x: 0.3, y: 0.2),
            .hsl(.aqua, .hue): .scalar(-15), .hsl(.blue, .hue): .scalar(-20), .hsl(.orange, .saturation): .scalar(10),
            .gradeBalance: .scalar(10),
        ], isBuiltIn: true),
        Preset(id: id(4), name: "Soft matte", groups: [.light, .color], params: [
            .contrast: .scalar(-20), .highlights: .scalar(-30), .blacks: .scalar(25), .saturation: .scalar(-10),
            .toneCurve: .curve([CurvePoint(x: 0, y: 0.08), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 0.95)]),
        ], isBuiltIn: true),
        Preset(id: id(5), name: "B&W", groups: [.light, .color], params: [
            .saturation: .scalar(-100), .contrast: .scalar(25), .blacks: .scalar(-10),
        ], isBuiltIn: true),
    ]
}

/// Adaptive presets: AI masks with local adjustments, re-detected on each photo.
public enum AdaptivePresets {
    public static let collection = "Adaptive"

    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0002-%012d", n))! }

    private static func preset(_ n: Int, _ name: String, _ kind: AIMaskKind, _ adjustments: [ParamKey: Double]) -> Preset {
        let layer = MaskLayer(
            id: id(100 + n), name: kind.displayName, order: Double(n),
            components: [MaskComponent(id: id(200 + n), shape: .ai(kind: kind))],
            adjustments: adjustments
        )
        var preset = Preset(id: id(n), name: name, groups: [.masks], params: [layer.key: .mask(layer)], isBuiltIn: true)
        preset.collection = collection
        return preset
    }

    public static let all: [Preset] = [
        preset(1, "Sky: deep blue", .sky, [.exposure: -0.3, .highlights: -25, .saturation: 20, .dehaze: 15, .localTemperature: -8]),
        preset(2, "Sky: sunset glow", .sky, [.localTemperature: 25, .localTint: 8, .saturation: 25, .highlights: -20]),
        preset(3, "Subject: pop", .subject, [.exposure: 0.25, .clarity: 15, .texture: 10, .vibrance: 10]),
        preset(4, "Background: soften", .background, [.exposure: -0.35, .clarity: -30, .saturation: -15]),
        preset(5, "People: warm skin", .people, [.localTemperature: 8, .exposure: 0.15, .texture: -15, .clarity: -10]),
    ]
}

/// Saved presets as JSON files in Application Support.
public final class PresetStore: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func defaultDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "Presets", directoryHint: .isDirectory)
    }

    public func load() -> [Preset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Preset.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(_ preset: Preset) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preset).write(to: directory.appending(path: "\(preset.id.uuidString).json"), options: .atomic)
    }

    public func delete(_ preset: Preset) throws {
        try FileManager.default.removeItem(at: directory.appending(path: "\(preset.id.uuidString).json"))
    }
}

/// Imported .cube files, stored by content hash so recipes can reference them.
public final class LUTStore: LUTProvider {
    private let directory: URL
    private let cache = Mutex<[String: CubeLUT]>([:])

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func defaultDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "LUTs", directoryHint: .isDirectory)
    }

    /// Copies a .cube file into the store and returns the parsed LUT.
    @discardableResult
    public func importCube(from url: URL) throws -> CubeLUT {
        let data = try Data(contentsOf: url)
        let lut = try CubeParser.parse(data, fallbackTitle: url.deletingPathExtension().lastPathComponent)
        try data.write(to: directory.appending(path: "\(lut.hash).cube"), options: .atomic)
        try Data(lut.title.utf8).write(to: directory.appending(path: "\(lut.hash).name"), options: .atomic)
        cache.withLock { $0[lut.hash] = lut }
        return lut
    }

    public func all() -> [LUTRef] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "cube" }.map { url in
            let hash = url.deletingPathExtension().lastPathComponent
            let name = (try? String(contentsOf: directory.appending(path: "\(hash).name"), encoding: .utf8)) ?? "LUT"
            return LUTRef(hash: hash, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The .cube file itself, e.g. to send with a render on another device.
    public func data(for ref: LUTRef) -> Data? {
        try? Data(contentsOf: directory.appending(path: "\(ref.hash).cube"))
    }

    public func lut(for ref: LUTRef) -> CubeLUT? {
        if let hit = cache.withLock({ $0[ref.hash] }) { return hit }
        guard let data = try? Data(contentsOf: directory.appending(path: "\(ref.hash).cube")),
              let lut = try? CubeParser.parse(data, fallbackTitle: ref.name)
        else { return nil }
        cache.withLock { $0[ref.hash] = lut }
        return lut
    }
}
