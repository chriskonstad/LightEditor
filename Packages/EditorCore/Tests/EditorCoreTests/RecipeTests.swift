import Foundation
import Testing
@testable import EditorCore

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try Data(contentsOf: url)
}

let testClock = HybridLogicalClock(node: "test")

@Suite struct RecipeTests {
    @Test func roundTripsThroughJSON() throws {
        var recipe = Recipe(photoID: PhotoID(rawValue: "abc"))
        recipe.setScalar(.exposure, 0.7, at: testClock.now())
        recipe.setScalar(.hsl(.blue, .saturation), -30, at: testClock.now())
        recipe.set(.gradeWheel(.shadows), .point(x: 0.1, y: -0.2), at: testClock.now())
        recipe.set(.toneCurve, .curve([CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 0.9)]), at: testClock.now())
        recipe.set(.lut, .lut(LUTRef(hash: "h", name: "Film"), amount: 0.5), at: testClock.now())
        recipe.set(.crop, .crop(CropGeometry(rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), angle: 2, aspect: AspectRatio(1, 1))), at: testClock.now())

        let data = try RecipeCodec.encode(recipe)
        let decoded = try RecipeCodec.decode(data)
        #expect(decoded == recipe)
    }

    @Test func scalarsEncodeAsBareNumbers() throws {
        var recipe = Recipe()
        recipe.setScalar(.exposure, 1.5, at: testClock.now())
        let json = String(decoding: try RecipeCodec.encode(recipe), as: UTF8.self)
        #expect(json.contains(#""light.exposure":1.5"#))
    }

    @Test func defaultsAreAbsentButStamped() {
        var recipe = Recipe()
        recipe.setScalar(.exposure, 1, at: testClock.now())
        #expect(recipe.scalar(.exposure) == 1)
        recipe.setScalar(.exposure, 0, at: testClock.now())
        #expect(recipe[.exposure] == nil)
        #expect(recipe.stamps[.exposure] != nil, "a reset keeps its stamp for later merges")
        #expect(recipe.isIdentity)
    }

    @Test func photoDependentDefaults() {
        let defaults = PhotoDefaults(values: [.temperature: 5600, .tint: 4])
        let recipe = Recipe()
        #expect(recipe.scalar(.temperature, defaults: defaults) == 5600)
        #expect(recipe.scalar(.exposure, defaults: defaults) == 0)
        #expect(recipe.scalar(.gradeBlending, defaults: defaults) == 50)
    }

    @Test func clampsToRange() {
        var recipe = Recipe()
        recipe.setScalar(.contrast, 400, at: testClock.now())
        #expect(recipe.scalar(.contrast) == 100)
    }

    @Test func decodesVersion1Fixture() throws {
        let recipe = try RecipeCodec.decode(try fixture("recipe_v1.json"))
        #expect(recipe.schemaVersion == 1)
        #expect(recipe.decoder == .raw9)
        #expect(recipe.scalar(.exposure) == 0.3)
        #expect(recipe.scalar(.temperature) == 5200)
        #expect(recipe.scalar(.hsl(.blue, .saturation)) == -20)
        #expect(recipe[.gradeWheel(.shadows)] == .point(x: -0.2, y: 0.1))
        #expect(recipe[.lut] == .lut(LUTRef(hash: "abc123", name: "Portra"), amount: 0.8))
        guard case .crop(let geometry)? = recipe[.crop] else { Issue.record("missing crop"); return }
        #expect(geometry.aspect == AspectRatio(3, 2))
        #expect(geometry.angle == 1.5)
        #expect(recipe.stamps[.temperature] == HLCStamp(millis: 1_760_000_000_800, counter: 0, node: "mac"))
    }

    @Test func rejectsNewerSchema() throws {
        let data = Data(#"{"schemaVersion": 99, "photoID": "", "decoder": {"version": "9"}, "params": {}, "stamps": {}}"#.utf8)
        #expect(throws: RecipeCodecError.newerSchema(99)) { try RecipeCodec.decode(data) }
    }

    @Test func adjustmentDataIsCompressedAndSmall() throws {
        var recipe = try RecipeCodec.decode(try fixture("recipe_v1.json"))
        for band in HueBand.allCases {
            for component in HSLComponent.allCases {
                recipe.setScalar(.hsl(band, component), 12, at: testClock.now())
            }
        }
        let data = try AdjustmentFormat.encode(recipe)
        #expect(data.count < 4096)
        #expect(try AdjustmentFormat.decode(data) == recipe)
    }

    @Test func rawStageKeyChangesOnlyForDetail() {
        var recipe = Recipe()
        let base = recipe.rawStage
        recipe.setScalar(.exposure, 2, at: testClock.now())
        #expect(recipe.rawStage == base)
        recipe.setScalar(.noiseReduction, 40, at: testClock.now())
        #expect(recipe.rawStage != base)
    }

    @Test func clockIsMonotonic() {
        let clock = HybridLogicalClock(node: "a", wallClock: { Date(timeIntervalSince1970: 100) })
        let first = clock.now()
        let second = clock.now()
        #expect(second > first)
        clock.observe(HLCStamp(millis: 500_000, counter: 3, node: "b"))
        #expect(clock.now() > HLCStamp(millis: 500_000, counter: 3, node: "b"))
    }
}

@Suite struct PasteTests {
    func source() -> RecipeClip {
        var recipe = Recipe()
        recipe.setScalar(.temperature, 6000, at: testClock.now())
        recipe.setScalar(.exposure, 0.5, at: testClock.now())
        recipe.setScalar(.vibrance, 20, at: testClock.now())
        recipe.setScalar(.noiseReduction, 60, at: testClock.now())
        recipe.set(.crop, .crop(CropGeometry(rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5))), at: testClock.now())
        return RecipeClip(recipe: recipe, sourceName: "IMG_4821", sourceDefaults: PhotoDefaults(values: [.temperature: 5000, .tint: 0, .noiseReduction: 30]))
    }

    @Test func defaultSelectionIsEverythingButPerPhotoGroups() {
        #expect(PasteGroup.defaultSelection == Set(PasteGroup.allCases).subtracting([.crop, .retouch]))
    }

    @Test func setModeCopiesOnlySelectedGroups() {
        var target = Recipe()
        target.setScalar(.contrast, 30, at: testClock.now())
        target.setScalar(.saturation, -10, at: testClock.now())
        let result = target.pasting(source(), groups: PasteGroup.defaultSelection, mode: .set, targetDefaults: .generic, stamp: testClock.now())
        #expect(result.scalar(.exposure) == 0.5)
        #expect(result.scalar(.temperature) == 6000)
        #expect(result.scalar(.vibrance) == 20)
        #expect(result.scalar(.contrast) == nil, "set mode makes the Light group match the source")
        #expect(result.scalar(.saturation) == nil)
        #expect(result.scalar(.noiseReduction) == 60, "Detail is on by default")
        #expect(result[.crop] == nil, "Crop is off by default")
    }

    @Test func setModeWithDetailAndCrop() {
        let result = Recipe().pasting(source(), groups: Set(PasteGroup.allCases), mode: .set, targetDefaults: .generic, stamp: testClock.now())
        #expect(result.scalar(.noiseReduction) == 60)
        #expect(result[.crop] != nil)
    }

    @Test func adjustModeAddsDeltas() {
        var target = Recipe()
        target.setScalar(.exposure, -1, at: testClock.now())
        target.setScalar(.contrast, 30, at: testClock.now())
        let defaults = PhotoDefaults(values: [.temperature: 4000, .tint: 0])
        let result = target.pasting(source(), groups: PasteGroup.defaultSelection, mode: .adjust, targetDefaults: defaults, stamp: testClock.now())
        #expect(result.scalar(.exposure) == -0.5)
        #expect(result.scalar(.contrast) == 30, "adjust mode leaves untouched parameters alone")
        #expect(result.scalar(.temperature) == 5000, "+1000 K relative to the source's as-shot value")
        #expect(result.scalar(.vibrance) == 20)
    }

    @Test func bulkSliderDeltas() {
        var target = Recipe()
        target.setScalar(.exposure, 0.2, at: testClock.now())
        let result = target.applying([.exposure: 0.3, .shadows: 10], mode: .adjust, defaults: .generic, stamp: testClock.now())
        #expect(abs(result.scalar(.exposure)! - 0.5) < 1e-9)
        #expect(result.scalar(.shadows) == 10)
        let set = target.applying([.exposure: 0.3], mode: .set, defaults: .generic, stamp: testClock.now())
        #expect(set.scalar(.exposure) == 0.3)
    }

    @Test func groupFiltering() {
        let clip = source()
        let light = clip.recipe.params(in: [.light])
        #expect(Set(light.keys) == [.exposure])
        let wb = clip.recipe.params(in: [.whiteBalance, .detail])
        #expect(Set(wb.keys) == [.temperature, .noiseReduction])
    }
}

@Suite struct PresetTests {
    @Test func appliesWithAmount() {
        let preset = Preset(name: "Test", groups: [.light], params: [.exposure: .scalar(1), .contrast: .scalar(40)])
        var recipe = Recipe()
        recipe.setScalar(.highlights, -50, at: testClock.now())
        recipe.setScalar(.vibrance, 10, at: testClock.now())
        let half = recipe.applying(preset, amount: 0.5, defaults: .generic, stamp: testClock.now())
        #expect(half.scalar(.exposure) == 0.5)
        #expect(half.scalar(.contrast) == 20)
        #expect(half.scalar(.highlights) == nil, "the preset owns the Light group")
        #expect(half.scalar(.vibrance) == 10, "other groups are untouched")
    }

    @Test func capturesGroupsWithoutCrop() {
        var recipe = Recipe()
        recipe.setScalar(.exposure, 1, at: testClock.now())
        recipe.set(.crop, .crop(CropGeometry(rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1))), at: testClock.now())
        let preset = Preset(name: "Mine", from: recipe, groups: Set(PasteGroup.allCases))
        #expect(preset.params[.exposure] == .scalar(1))
        #expect(preset.params[.crop] == nil)
        #expect(!preset.groups.contains(.crop))
    }

    @Test func storeRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = PresetStore(directory: directory)
        let preset = BuiltInPresets.all[1]
        try store.save(preset)
        #expect(store.load() == [preset])
        try store.delete(preset)
        #expect(store.load().isEmpty)
    }
}

@Suite struct CropMathTests {
    let frame = 3.0 / 2.0

    @Test func centeredSquareOnLandscapeFrame() {
        let rect = CropMath.centered(aspect: 1, frameAspect: frame)
        #expect(abs(rect.width * frame - rect.height) < 1e-9, "square in pixels")
        #expect(rect.height == 1)
        #expect(abs(rect.x - (1 - rect.width) / 2) < 1e-9)
    }

    @Test func resizeKeepsOppositeCornerAndAspect() {
        let start = CropMath.centered(aspect: 1, frameAspect: frame)
        let resized = CropMath.resize(start, dragging: .topLeft, dx: 0.1, dy: 0.05, aspect: 1, frameAspect: frame)
        #expect(abs((resized.x + resized.width) - (start.x + start.width)) < 1e-9, "right edge fixed")
        #expect(abs((resized.y + resized.height) - (start.y + start.height)) < 1e-9, "bottom edge fixed")
        #expect(abs(resized.width * frame - resized.height) < 1e-9)
    }

    @Test func resizeStaysInFrameWithMinimumSize() {
        let resized = CropMath.resize(.full, dragging: .bottomRight, dx: -2, dy: 0.5, aspect: nil, frameAspect: frame)
        #expect(resized.width == CropMath.minimumSize)
        #expect(resized.height == 1)
        #expect(resized.x == 0 && resized.y == 0)
    }

    @Test func moveClampsToFrame() {
        let start = NormalizedRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        let moved = CropMath.move(start, dx: 1, dy: -1)
        #expect(moved.x == 0.5 && moved.y == 0)
    }
}

@Suite struct RecipeDraftTests {
    @Test func savesLoadsAndClears() {
        let drafts = RecipeDrafts(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        var recipe = Recipe()
        recipe.setScalar(.exposure, 0.7, at: testClock.now())
        drafts.save(recipe, for: "asset-1")
        #expect(drafts.load(for: "asset-1")?.params == recipe.params)
        #expect(drafts.load(for: "asset-2") == nil)

        var newer = recipe
        newer.setScalar(.contrast, 20, at: testClock.now())
        drafts.save(newer, for: "asset-1")
        drafts.clear(for: "asset-1", ifMatching: recipe)
        #expect(drafts.load(for: "asset-1") != nil, "a newer draft survives an older save")
        drafts.clear(for: "asset-1", ifMatching: newer)
        #expect(drafts.load(for: "asset-1") == nil)
    }
}
