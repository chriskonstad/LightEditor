import Foundation
import Testing
@testable import EditorCore

func sampleMask(_ shape: MaskShape, order: Double = 1, exposure: Double = 0.5) -> MaskLayer {
    MaskLayer(name: shape.displayName, order: order, components: [MaskComponent(shape: shape)], adjustments: [.exposure: exposure])
}

@Suite struct MaskModelTests {
    static let shapes: [MaskShape] = [
        .linear(start: NormalizedPoint(x: 0.5, y: 0), end: NormalizedPoint(x: 0.5, y: 0.6)),
        .radial(center: NormalizedPoint(x: 0.4, y: 0.5), radiusX: 0.2, radiusY: 0.3, angle: 15, feather: 0.5),
        .brush(strokes: [BrushStroke(points: [NormalizedPoint(x: 0.1, y: 0.1), NormalizedPoint(x: 0.3, y: 0.2)], radius: 0.05, erase: false)]),
        .luminance(low: 0.6, high: 1, feather: 0.1),
        .color(l: 0.6, a: -0.05, b: -0.12, range: 0.3),
        .ai(kind: .sky),
        .object(seeds: [NormalizedPoint(x: 0.5, y: 0.5)]),
    ]

    @Test(arguments: shapes)
    func roundTripsEveryShape(shape: MaskShape) throws {
        var recipe = Recipe()
        var layer = sampleMask(shape)
        layer.components.append(MaskComponent(operation: .subtract, inverted: true, shape: .ai(kind: .people)))
        layer.adjustments[.localTemperature] = 20
        recipe.setMask(layer, at: testClock.now())
        let decoded = try RecipeCodec.decode(try RecipeCodec.encode(recipe))
        #expect(decoded == recipe)
        #expect(decoded.masks == [layer])
    }

    @Test func masksSortByOrder() {
        var recipe = Recipe()
        let second = sampleMask(.ai(kind: .sky), order: 2)
        let first = sampleMask(.ai(kind: .subject), order: 1)
        recipe.setMask(second, at: testClock.now())
        recipe.setMask(first, at: testClock.now())
        #expect(recipe.masks.map(\.id) == [first.id, second.id])
        #expect(recipe.nextMaskOrder == 3)
        recipe.removeMask(first.id, at: testClock.now())
        #expect(recipe.masks.map(\.id) == [second.id])
    }

    @Test func masksAreTheirOwnPasteGroup() {
        #expect(PasteGroup.defaultSelection.contains(.masks))
        var recipe = Recipe()
        recipe.setScalar(.exposure, 1, at: testClock.now())
        recipe.setMask(sampleMask(.ai(kind: .sky)), at: testClock.now())
        #expect(recipe.params(in: [.masks]).count == 1)
        #expect(recipe.params(in: [.light]).count == 1)
        #expect(recipe.hasEdits(in: .masks))
    }

    @Test func pasteSetReplacesAndAdjustAdds() {
        var source = Recipe()
        let sky = sampleMask(.ai(kind: .sky))
        source.setMask(sky, at: testClock.now())
        let clip = RecipeClip(recipe: source, sourceName: "A", sourceDefaults: .generic)

        var target = Recipe()
        let own = sampleMask(.radial(center: NormalizedPoint(x: 0.5, y: 0.5), radiusX: 0.1, radiusY: 0.1, angle: 0, feather: 0.3))
        target.setMask(own, at: testClock.now())

        let skipped = target.pasting(clip, groups: [.light, .color], mode: .set, targetDefaults: .generic, stamp: testClock.now())
        #expect(skipped.masks.map(\.id) == [own.id], "masks only paste with their group")

        let replaced = target.pasting(clip, groups: [.masks], mode: .set, targetDefaults: .generic, stamp: testClock.now())
        #expect(replaced.masks.map(\.id) == [sky.id])

        let added = target.pasting(clip, groups: [.masks], mode: .adjust, targetDefaults: .generic, stamp: testClock.now())
        #expect(Set(added.masks.map(\.id)) == [sky.id, own.id])
    }

    @Test func adaptivePresetCarriesMasks() {
        var recipe = Recipe()
        recipe.setMask(sampleMask(.ai(kind: .sky)), at: testClock.now())
        recipe.setScalar(.vibrance, 20, at: testClock.now())
        let preset = Preset(name: "Blue skies", from: recipe, groups: [.masks, .color])
        var target = Recipe()
        target.setMask(sampleMask(.ai(kind: .subject)), at: testClock.now())
        let applied = target.applying(preset, amount: 0.5, defaults: .generic, stamp: testClock.now())
        #expect(applied.masks.count == 1)
        #expect(applied.masks.first?.components.first?.shape == .ai(kind: .sky))
        #expect(applied.masks.first?.amount == 0.5)
        #expect(applied.scalar(.vibrance) == 10)
    }

    @Test func brushStrokesStayCompact() throws {
        var points: [NormalizedPoint] = []
        for i in 0..<2000 {
            let t = Double(i) / 2000
            points.append(NormalizedPoint(x: 0.1 + 0.8 * t, y: 0.5 + 0.2 * sin(t * 12)))
        }
        let stroke = BrushStroke(points: points, radius: 0.03).simplified()
        #expect(stroke.points.count < 400)
        var recipe = Recipe()
        recipe.setMask(sampleMask(.brush(strokes: [stroke])), at: testClock.now())
        let data = try AdjustmentFormat.encode(recipe)
        #expect(data.count < 8_000, "\(data.count) bytes")
    }

    @Test func oldRecipesStillDecode() throws {
        let recipe = try RecipeCodec.decode(try fixture("recipe_v1.json"))
        #expect(recipe.masks.isEmpty)
    }

    @Test func builtInAdaptivePresetsAddAIMasks() {
        for preset in AdaptivePresets.all {
            let applied = Recipe().applying(preset, amount: 1, defaults: .generic, stamp: testClock.now())
            #expect(applied.masks.count == 1, "\(preset.name)")
            #expect(applied.masks.first?.usesAI == true)
            #expect(preset.collection == "Adaptive")
        }
    }
}
