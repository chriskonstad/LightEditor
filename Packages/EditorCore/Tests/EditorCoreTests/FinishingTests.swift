import CoreImage
import Foundation
import Testing
@testable import EditorCore

@Suite struct FinishingTests {
    static func bordered(_ edit: (inout Recipe) -> Void = { _ in }) -> Recipe {
        var recipe = Recipe()
        recipe.setScalar(.borderWidth, 5, at: testClock.now())
        edit(&recipe)
        return recipe
    }

    static let mark = Watermark(text: "© Test", position: .bottomLeft, color: SRGBColor(red: 1, green: 0.5, blue: 0))

    // MARK: Codec

    @Test func roundTripsEveryFinishingValue() throws {
        let recipe = Self.bordered { recipe in
            recipe.setScalar(.borderBottom, 12, at: testClock.now())
            recipe.set(.borderColor, .color(.black), at: testClock.now())
            recipe.set(.borderCanvas, .aspect(AspectRatio(4, 5)), at: testClock.now())
            recipe.set(.watermark, .watermark(Self.mark), at: testClock.now())
            recipe.setScalar(.watermarkSize, 6, at: testClock.now())
            recipe.setScalar(.watermarkOpacity, 50, at: testClock.now())
            recipe.setScalar(.watermarkMargin, 2, at: testClock.now())
        }
        let data = try RecipeCodec.encode(recipe)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""finish.border.canvas":{"canvas":"4:5"}"#))
        #expect(json.contains(#""finish.border.color":{"rgb":[0,0,0]}"#))
        #expect(json.contains(#""schemaVersion":2"#))
        let decoded = try RecipeCodec.decode(data)
        #expect(decoded.params == recipe.params)
        #expect(decoded.stamps == recipe.stamps)
        #expect(decoded[.watermark] == .watermark(Self.mark))
    }

    @Test func recipesWithoutFinishingStayVersion1() throws {
        var recipe = Recipe()
        recipe.setScalar(.exposure, 0.5, at: testClock.now())
        let json = String(decoding: try RecipeCodec.encode(recipe), as: UTF8.self)
        #expect(json.contains(#""schemaVersion":1"#), "older app versions keep reading edits that don't use a border")
        #expect(recipe.minimumSchemaVersion == 1)
        #expect(Self.bordered().minimumSchemaVersion == 2)
    }

    @Test func migratesVersion1Recipes() throws {
        let recipe = try RecipeCodec.decode(try fixture("recipe_v1.json"))
        #expect(recipe.schemaVersion == Recipe.currentSchemaVersion)
        #expect(recipe.scalar(.exposure) == 0.3)
        #expect(!recipe.hasEdits(in: .finishing))
        #expect(FinishingRenderer.apply(recipe, to: solid(0.5, 0.5, 0.5, size: 40)).extent == CGRect(x: 0, y: 0, width: 40, height: 40))
    }

    @Test func decodesVersion2Json() throws {
        let data = Data(#"""
        {"schemaVersion": 2, "photoID": "", "decoder": {"version": "9"},
         "params": {"finish.border.width": 3, "finish.watermark": {"watermark": {"text": "© Me", "position": "top", "color": [1, 1, 1]}}},
         "stamps": {}}
        """#.utf8)
        let recipe = try RecipeCodec.decode(data)
        #expect(recipe.scalar(.borderWidth) == 3)
        #expect(Finishing.watermark(recipe) == Watermark(text: "© Me", position: .top))
    }

    // MARK: Paste groups and presets

    @Test func finishingIsOffByDefaultInPaste() {
        #expect(!PasteGroup.finishing.isOnByDefault)
        #expect(Set(PasteGroup.finishing.keys) == Set(Finishing.keys))
        let source = Self.bordered { recipe in
            recipe.setScalar(.exposure, 1, at: testClock.now())
            recipe.set(.watermark, .watermark(Self.mark), at: testClock.now())
        }
        let clip = RecipeClip(recipe: source, sourceName: "A", sourceDefaults: .generic)
        let look = Recipe().pasting(clip, groups: PasteGroup.defaultSelection, mode: .set, targetDefaults: .generic, stamp: testClock.now())
        #expect(look.scalar(.exposure) == 1)
        #expect(!look.hasEdits(in: .finishing))

        let framed = Recipe().pasting(clip, groups: [.finishing], mode: .set, targetDefaults: .generic, stamp: testClock.now())
        #expect(framed.scalar(.borderWidth) == 5)
        #expect(framed[.watermark] == .watermark(Self.mark))
        #expect(framed.scalar(.exposure) == nil)
        #expect(Set(source.params(in: [.finishing]).keys) == [.borderWidth, .watermark])
    }

    @Test func adjustModePastesFinishingAsIs() {
        let source = Self.bordered()
        let clip = RecipeClip(recipe: source, sourceName: "A", sourceDefaults: .generic)
        var target = Recipe()
        target.setScalar(.borderWidth, 2, at: testClock.now())
        let result = target.pasting(clip, groups: [.finishing], mode: .adjust, targetDefaults: .generic, stamp: testClock.now())
        #expect(result.scalar(.borderWidth) == 5, "a border width is set, not added")
    }

    @Test func presetsCarryBorderAndWatermark() {
        let source = Self.bordered { $0.set(.watermark, .watermark(Self.mark), at: testClock.now()) }
        let preset = Preset(name: "Frame", from: source, groups: [.finishing])
        let applied = Recipe().applying(preset, amount: 0.5, defaults: .generic, stamp: testClock.now())
        #expect(applied[.watermark] == .watermark(Self.mark))
        #expect(applied.scalar(.borderWidth) == 2.5)
    }

    // MARK: Layout

    @Test func borderIsRelativeToShortEdge() {
        let layout = Finishing.layout(photo: CGSize(width: 3000, height: 2000), recipe: Self.bordered())
        #expect(layout.canvas == CGSize(width: 3200, height: 2200))
        #expect(layout.photo == CGRect(x: 100, y: 100, width: 3000, height: 2000))
        let small = Finishing.layout(photo: CGSize(width: 300, height: 200), recipe: Self.bordered())
        #expect(small.canvas == CGSize(width: 320, height: 220), "the same proportions at any resolution")
    }

    @Test func extraBottomForGalleryLook() {
        let recipe = Self.bordered { $0.setScalar(.borderBottom, 15, at: testClock.now()) }
        let layout = Finishing.layout(photo: CGSize(width: 2000, height: 2000), recipe: recipe)
        #expect(layout.canvas == CGSize(width: 2200, height: 2500))
        #expect(layout.photo.minY == 400, "Core Image's origin is at the bottom")
    }

    @Test func padsToCanvasAspect() {
        var recipe = Recipe()
        recipe.set(.borderCanvas, .aspect(AspectRatio(4, 5)), at: testClock.now())
        let layout = Finishing.layout(photo: CGSize(width: 3000, height: 2000), recipe: recipe)
        #expect(layout.canvas == CGSize(width: 3000, height: 3750))
        #expect(layout.photo == CGRect(x: 0, y: 875, width: 3000, height: 2000))

        recipe.set(.borderCanvas, .aspect(AspectRatio(1, 1)), at: testClock.now())
        recipe.setScalar(.borderWidth, 5, at: testClock.now())
        let square = Finishing.layout(photo: CGSize(width: 2000, height: 3000), recipe: recipe)
        #expect(square.canvas == CGSize(width: 3200, height: 3200))
        #expect(square.photo.minX == 600)
    }

    // MARK: Rendering

    @Test func rendersBorderAroundCroppedPhoto() {
        var recipe = Self.bordered()
        recipe.set(.borderColor, .color(.black), at: testClock.now())
        recipe.set(.crop, .crop(CropGeometry(rect: NormalizedRect(x: 0, y: 0, width: 1, height: 0.5))), at: testClock.now())
        let base = solid(0.5, 0.5, 0.5, size: 400)
        let image = GradeGraph.apply(recipe, to: base, inputs: GradeInputs(defaults: .generic))
        // 400 × 200 cropped, 10 px border.
        #expect(image.extent == CGRect(x: 0, y: 0, width: 420, height: 220))
        #expect(pixel(image, x: 2, y: 2).x < 0.01)
        #expect(abs(pixel(image, x: 210, y: 110).x - 0.5) < 0.01)

        var inputs = GradeInputs(defaults: .generic)
        inputs.applyFinishing = false
        #expect(GradeGraph.apply(recipe, to: base, inputs: inputs).extent.size == CGSize(width: 400, height: 200))
        let uncropped = GradeGraph.apply(recipe, to: base, inputs: GradeInputs(defaults: .generic, applyGeometry: false))
        #expect(uncropped.extent.size == CGSize(width: 400, height: 400), "the crop tool and masks show the bare original")
    }

    @Test func borderColorIsSRGB() {
        var recipe = Self.bordered()
        recipe.set(.borderColor, .color(SRGBColor(red: 1, green: 1, blue: 1)), at: testClock.now())
        let image = FinishingRenderer.apply(recipe, to: solid(0, 0, 0, size: 100))
        let corner = pixel(image, x: 1, y: 1)
        #expect(abs(corner.x - 1) < 0.01 && abs(corner.y - 1) < 0.01 && abs(corner.z - 1) < 0.01)
    }

    @Test func watermarkDrawsInItsCorner() {
        var recipe = Recipe()
        recipe.set(.watermark, .watermark(Watermark(text: "© Test", position: .bottomLeft)), at: testClock.now())
        recipe.setScalar(.watermarkSize, 10, at: testClock.now())
        recipe.setScalar(.watermarkOpacity, 100, at: testClock.now())
        let base = solid(0, 0, 0, size: 400)
        let image = FinishingRenderer.apply(recipe, to: base)
        #expect(image.extent == base.extent)
        func brightest(_ rect: CGRect) -> Float { pixels(image, rect: rect).map(\.x).max() ?? 0 }
        // Bottom left (Core Image's origin): the text, 40 px tall, 16 px in.
        #expect(brightest(CGRect(x: 0, y: 0, width: 200, height: 80)) > 0.9)
        #expect(brightest(CGRect(x: 0, y: 300, width: 400, height: 100)) == 0)
        #expect(brightest(CGRect(x: 300, y: 0, width: 100, height: 100)) == 0)
    }

    @Test func watermarkOpacityAndEmptyText() {
        var recipe = Recipe()
        recipe.set(.watermark, .watermark(Watermark(text: "WWWW", position: .center)), at: testClock.now())
        recipe.setScalar(.watermarkSize, 20, at: testClock.now())
        recipe.setScalar(.watermarkOpacity, 50, at: testClock.now())
        let image = FinishingRenderer.apply(recipe, to: solid(0, 0, 0, size: 400))
        let peak = pixels(image, rect: CGRect(x: 0, y: 150, width: 400, height: 100)).map(\.x).max() ?? 0
        // Half of white over black, blended in linear light.
        #expect(peak > 0.4 && peak < 0.6)

        recipe.set(.watermark, .watermark(Watermark(text: "  ")), at: testClock.now())
        #expect(Finishing.watermark(recipe) == nil)
    }

    @Test func longWatermarksShrinkToFit() {
        var recipe = Recipe()
        recipe.set(.watermark, .watermark(Watermark(text: String(repeating: "Long watermark ", count: 10), position: .center)), at: testClock.now())
        recipe.setScalar(.watermarkSize, 20, at: testClock.now())
        recipe.setScalar(.watermarkOpacity, 100, at: testClock.now())
        let image = FinishingRenderer.apply(recipe, to: solid(0, 0, 0, size: 400))
        let edges = pixels(image, rect: CGRect(x: 0, y: 0, width: 400, height: 400))
        // Nothing within the 16 px margin on the left.
        var leftmost = 400
        for (index, p) in edges.enumerated() where p.x > 0.05 { leftmost = min(leftmost, index % 400) }
        #expect(leftmost >= 15, "leftmost \(leftmost)")
    }

    @Test func previewMatchesExportProportions() {
        let recipe = Self.bordered {
            $0.setScalar(.borderBottom, 10, at: testClock.now())
            $0.set(.watermark, .watermark(Watermark(text: "© Test")), at: testClock.now())
        }
        let preview = FinishingRenderer.apply(recipe, to: solid(0.2, 0.2, 0.2, size: 500)).extent.size
        let full = FinishingRenderer.apply(recipe, to: solid(0.2, 0.2, 0.2, size: 2000)).extent.size
        #expect(abs(full.width / preview.width - 4) < 0.01)
        #expect(abs(full.height / preview.height - 4) < 0.01)
    }
}
