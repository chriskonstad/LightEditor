import Foundation
import Testing
@testable import EditorCore

/// Guards the stored recipe format, which is saved in every edited photo's adjustment
/// data and must keep decoding forever (CLAUDE.md: never break old recipes).
///
/// `recipe_v<N>_all_kinds.json` is a golden file holding one of every value kind at
/// schema version N. The test for the current version checks both directions: the
/// file decodes to `kitchenSink`, and `kitchenSink` encodes to the file byte for byte.
/// A change to the encoding fails it on purpose. If the change is intended, bump
/// `Recipe.currentSchemaVersion`, add a migration, keep the old file, and record a new
/// one with `EDITORCORE_RECORD=1 scripts/test-fast.sh --filter RecipeCompatibility`.
@Suite struct RecipeCompatibilityTests {
    static let goldenName = "recipe_v\(Recipe.currentSchemaVersion)_all_kinds.json"

    /// One of every `ParamValue` case, every `MaskShape` and every retouch kind, with
    /// fixed IDs and stamps so the encoding is reproducible.
    static var kitchenSink: Recipe {
        var recipe = Recipe(photoID: PhotoID(rawValue: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"), decoder: .raw9)
        var tick: Int64 = 0
        func stamp() -> HLCStamp {
            tick += 1
            return HLCStamp(millis: 1_760_000_000_000 + tick, counter: 0, node: "golden")
        }
        // A fixed list rather than the whole catalog, so adding a parameter (which
        // doesn't change the format) doesn't change the golden file.
        let scalars: [(ParamKey, Double)] = [
            (.temperature, 5200), (.tint, -12.5), (.exposure, 0.375), (.contrast, 20), (.shadows, 30),
            (.hsl(.blue, .saturation), -20), (.gradeLuminance(.highlights), 10), (.gradeBlending, 75),
            (.vignetteAmount, -25), (.grainAmount, 15), (.noiseReduction, 40), (.lensCorrection, 0),
            (.lensDistortion, 5), (.perspectiveVertical, -10), (.photosMaxMegapixels, 24), (.photosQuality, 0.8),
        ]
        for (key, value) in scalars { recipe.setScalar(key, value, at: stamp()) }
        recipe.set(.gradeWheel(.shadows), .point(x: -0.25, y: 0.125), at: stamp())
        recipe.set(.toneCurve, .curve([CurvePoint(x: 0, y: 0.05), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 0.95)]), at: stamp())
        recipe.set(.lut, .lut(LUTRef(hash: "abc123", name: "Portra"), amount: 0.75), at: stamp())
        recipe.set(.crop, .crop(CropGeometry(
            rect: NormalizedRect(x: 0.05, y: 0.1, width: 0.9, height: 0.8), angle: 1.5, aspect: AspectRatio(3, 2),
            auto: AutoStraighten(method: .horizon, detected: 1.25, tweak: 0.25)
        )), at: stamp())

        let point = NormalizedPoint(x: 0.25, y: 0.75)
        let stroke = BrushStroke(points: [point, NormalizedPoint(x: 0.5, y: 0.5)], radius: 0.05, feather: 0.25, flow: 0.5, erase: true)
        let shapes: [MaskShape] = [
            .linear(start: point, end: NormalizedPoint(x: 0.75, y: 0.25)),
            .radial(center: point, radiusX: 0.25, radiusY: 0.125, angle: 30, feather: 0.5),
            .brush(strokes: [stroke]),
            .luminance(low: 0.25, high: 0.75, feather: 0.125),
            .color(l: 0.5, a: 0.125, b: -0.0625, range: 0.25),
        ] + AIMaskKind.allCases.map { .ai(kind: $0) } + [.object(seeds: [point])]
        let components = shapes.enumerated().map { index, shape in
            MaskComponent(
                id: uuid(0x100 + index), operation: index.isMultiple(of: 2) ? .add : .subtract,
                inverted: index == 1, shape: shape
            )
        }
        recipe.setMask(MaskLayer(
            id: uuid(1), name: "Everything", order: 1, components: components,
            adjustments: Dictionary(uniqueKeysWithValues: MaskLayer.adjustmentKeys.enumerated().map { ($1, Double($0 + 1)) }),
            amount: 0.75, isEnabled: false
        ), at: stamp())

        for (index, kind) in RetouchSpot.Kind.allCases.enumerated() {
            recipe.setRetouch(RetouchSpot(
                id: uuid(0x200 + index), order: Double(index + 1), kind: kind, strokes: [stroke],
                sourceOffset: kind.needsSource ? NormalizedPoint(x: 0.125, y: -0.125) : nil,
                opacity: 0.75, engine: RemoveEngine.allCases[index % RemoveEngine.allCases.count], variation: index
            ), at: stamp())
        }
        // A reset: no value, but a stamp, so a later merge can tell it from "never set".
        recipe.setScalar(.vibrance, 10, at: stamp())
        recipe.set(.vibrance, nil, at: stamp())
        return recipe
    }

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
    }

    static var fixturesFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
    }

    @Test func goldenRecipeMatchesCurrentEncoding() throws {
        let encoded = try RecipeCodec.encode(Self.kitchenSink)
        let source = Self.fixturesFolder.appending(path: Self.goldenName)
        if ProcessInfo.processInfo.environment["EDITORCORE_RECORD"] == "1" {
            try encoded.write(to: source)
            Issue.record("Recorded \(source.path). Unset EDITORCORE_RECORD and run again.")
            return
        }
        let golden = try fixture(Self.goldenName)
        #expect(try RecipeCodec.decode(golden) == Self.kitchenSink, "the golden recipe no longer decodes to the same edit")
        #expect(
            encoded == golden,
            """
            The recipe encoding changed. Old photos store the old format, so: bump Recipe.currentSchemaVersion, \
            add a migration in RecipeCodec, keep \(Self.goldenName), and record the new version's golden \
            (EDITORCORE_RECORD=1). Encoded now: \(String(decoding: encoded, as: UTF8.self))
            """
        )
    }

    /// Every stored version still decodes into the current model.
    @Test func everyRecipeFixtureDecodes() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.fixturesFolder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("recipe_v") && $0.pathExtension == "json" }
        #expect(files.count >= 2)
        for file in files {
            let recipe = try RecipeCodec.decode(Data(contentsOf: file))
            #expect(recipe.schemaVersion == Recipe.currentSchemaVersion, "\(file.lastPathComponent) wasn't migrated")
            #expect(!recipe.isIdentity, "\(file.lastPathComponent) decoded empty")
        }
    }

    /// Each older version has a migration step and a golden file to run it on.
    @Test func everyOldVersionHasAMigrationAndAFixture() {
        for version in 1..<Recipe.currentSchemaVersion {
            #expect(RecipeCodec.migrations[version] != nil, "no migration from v\(version)")
            #expect(Bundle.module.url(forResource: "Fixtures/recipe_v\(version)_all_kinds.json", withExtension: nil) != nil,
                    "keep the v\(version) golden recipe so its migration stays tested")
        }
        #expect(Bundle.module.url(forResource: "Fixtures/\(Self.goldenName)", withExtension: nil) != nil)
    }

    @Test func catalogKeysAreUniqueAndDefaultsInRange() {
        let keys = ParamCatalog.all.map(\.key)
        #expect(Set(keys).count == keys.count, "duplicate ParamCatalog keys")
        for spec in ParamCatalog.all {
            if let range = spec.range, let fixed = spec.fixedDefault {
                #expect(range.contains(fixed), "\(spec.key) default \(fixed) is outside \(range)")
            }
            #expect(!spec.label.isEmpty, "\(spec.key) has no label")
            #expect(!spec.key.isMask && !spec.key.isRetouch, "\(spec.key) collides with a dynamic key prefix")
        }
        for group in PasteGroup.allCases where group != .masks && group != .retouch {
            #expect(!group.keys.isEmpty, "paste group \(group) has no parameters")
        }
    }

    /// Every scalar survives a round trip at both ends of its range.
    @Test func everyScalarRoundTripsAtItsLimits() throws {
        for spec in ParamCatalog.all {
            guard let range = spec.range else { continue }
            for value in [range.lowerBound, range.upperBound] {
                var recipe = Recipe()
                recipe.setScalar(spec.key, value, at: testClock.now())
                let decoded = try RecipeCodec.decode(RecipeCodec.encode(recipe))
                #expect(decoded == recipe, "\(spec.key) at \(value)")
            }
        }
    }

    /// The adjustment data saved into Photos round-trips the kitchen sink too.
    @Test func adjustmentDataRoundTripsEverything() throws {
        let recipe = Self.kitchenSink
        let data = try RecipeCodec.encode(recipe)
        #expect(data.count < 16_000, "a recipe with everything in it is \(data.count) bytes")
        #expect(try RecipeCodec.decode(data) == recipe)
    }
}
