import CoreImage
import Foundation
import Testing
@testable import EditorCore

/// Effects stay inside the photo: the graded image keeps the photo's (cropped)
/// extent, and the preview frame paints nothing but the background around it.
@Suite struct CanvasBoundsTests {
    static let crop = CropGeometry(rect: NormalizedRect(x: 0.1, y: 0.15, width: 0.7, height: 0.6))

    /// Edits that make clear pixels colored, so would show around the photo if
    /// Core Image ran them there.
    enum Edit: String, CaseIterable {
        case vignetteDarken, vignetteLighten, vignetteWithCrop, vignetteStraightened, dehazeNegative, grain, clipping, maskOverlay

        func apply(to recipe: inout Recipe, inputs: inout GradeInputs) {
            let stamp = testClock.now()
            switch self {
            case .vignetteDarken: recipe.setScalar(.vignetteAmount, -100, at: stamp)
            case .vignetteLighten: recipe.setScalar(.vignetteAmount, 100, at: stamp)
            case .vignetteWithCrop:
                recipe.setScalar(.vignetteAmount, 100, at: stamp)
                recipe.set(.crop, .crop(CanvasBoundsTests.crop), at: stamp)
            case .vignetteStraightened:
                recipe.setScalar(.vignetteAmount, 100, at: stamp)
                recipe.set(.crop, .crop(CropGeometry(angle: 8)), at: stamp)
            case .dehazeNegative: recipe.setScalar(.dehaze, -100, at: stamp)
            case .grain: recipe.setScalar(.grainAmount, 100, at: stamp)
            case .clipping: inputs.showClipping = true
            case .maskOverlay:
                let mask = MaskLayer(name: "Radial", order: 1, components: [
                    MaskComponent(inverted: true, shape: .radial(center: NormalizedPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2, angle: 0, feather: 0.2)),
                ], adjustments: [.exposure: 1])
                recipe.setMask(mask, at: stamp)
                recipe.setScalar(.vignetteAmount, 100, at: stamp)
                inputs.maskOverlay = mask.id
            }
        }
    }

    func graded(_ edit: Edit, base: CIImage) -> CIImage {
        var recipe = Recipe()
        var inputs = GradeInputs(defaults: .generic)
        edit.apply(to: &recipe, inputs: &inputs)
        return GradeGraph.apply(recipe, to: base, inputs: inputs)
    }

    @Test func strongVignetteKeepsTheCroppedExtent() {
        let base = solid(0.5, 0.5, 0.5, size: 400)
        for amount in [-100.0, 100] {
            var recipe = Recipe()
            recipe.setScalar(.vignetteAmount, amount, at: testClock.now())
            #expect(GradeGraph.apply(recipe, to: base, inputs: GradeInputs(defaults: .generic)).extent == base.extent)
            recipe.set(.crop, .crop(Self.crop), at: testClock.now())
            let cropped = GradeGraph.apply(recipe, to: base, inputs: GradeInputs(defaults: .generic))
            #expect(cropped.extent == CGRect(x: 0, y: 0, width: 280, height: 240))
        }
    }

    /// Where the photo sits in a 600×500 drawable: Fit with an odd offset, and
    /// zoomed in and panned so it runs off two edges.
    static let placements: [CGRect] = [
        CGRect(x: 190.4, y: 120.6, width: 245.2, height: 245.2),
        CGRect(x: -310.3, y: 140.7, width: 820.5, height: 820.5),
    ]

    @Test(arguments: Edit.allCases, [0, 1])
    func previewFrameShowsOnlyBackgroundAroundThePhoto(_ edit: Edit, placement: Int) {
        let image = graded(edit, base: solid(0.5, 0.5, 0.5, size: 400))
        let drawable = CGSize(width: 600, height: 500)
        var rect = Self.placements[placement]
        rect.size.height = rect.width * image.extent.height / image.extent.width
        let background = CIColor(red: 1, green: 0, blue: 1)
        let frame = PreviewRenderer.frame(image: image, before: nil, split: nil, in: rect, drawableSize: drawable, background: background)
        #expect(frame.extent == CGRect(origin: .zero, size: drawable))

        let px = pixels(frame, rect: CGRect(origin: .zero, size: drawable))
        // A pixel of slack for the photo's filtered edge.
        let photo = rect.insetBy(dx: -1, dy: -1)
        var leaks = 0, inside = 0
        for row in 0..<Int(drawable.height) {
            for column in 0..<Int(drawable.width) {
                let p = px[row * Int(drawable.width) + column]
                // Bitmap rows run top-down, like `rect`.
                let center = CGPoint(x: CGFloat(column) + 0.5, y: CGFloat(row) + 0.5)
                let isBackground = abs(p.x - 1) < 0.01 && abs(p.y) < 0.01 && abs(p.z - 1) < 0.01
                if !photo.contains(center) {
                    if !isBackground { leaks += 1 }
                } else if rect.insetBy(dx: 2, dy: 2).contains(center), !isBackground {
                    inside += 1
                }
            }
        }
        #expect(leaks == 0, "\(edit) painted \(leaks) pixels outside the photo")
        #expect(inside > 0, "\(edit) lost the photo")
    }

    @Test func splitBeforeStaysInsideThePhoto() {
        let image = graded(.vignetteLighten, base: solid(0.5, 0.5, 0.5, size: 400))
        let drawable = CGSize(width: 600, height: 500)
        let rect = Self.placements[0]
        let frame = PreviewRenderer.frame(image: image, before: solid(0.5, 0.5, 0.5, size: 400), split: 0.5, in: rect,
                                          drawableSize: drawable, background: CIColor(red: 1, green: 0, blue: 1))
        // Above the photo, on both sides of the divider (Core Image rows run bottom-up).
        for x in [100.0, 500] {
            let p = pixel(frame, x: x, y: 450)
            #expect(abs(p.x - 1) < 0.01 && abs(p.y) < 0.01)
        }
    }
}

@Suite struct CanvasBackgroundTests {
    @Test func midGrayIsEighteenPercentLinear() {
        let frame = PreviewRenderer.frame(image: nil, before: nil, split: nil, in: .zero,
                                          drawableSize: CGSize(width: 4, height: 4), background: CanvasBackground.midGray.ciColor)
        let p = pixel(frame)
        #expect(abs(p.x - 0.18) < 0.003 && abs(p.y - 0.18) < 0.003 && abs(p.z - 0.18) < 0.003)
    }

    @Test func everyBackgroundIsNeutralAndOrdered() {
        let lightness = CanvasBackground.allCases.map { option -> Double in
            let c = option.srgbComponents
            #expect(c.red == c.green || option == .dark)
            return c.green
        }
        #expect(lightness == lightness.sorted())
        #expect(CanvasBackground.default == .dark)
        #expect(CanvasBackground(rawValue: CanvasBackground.midGray.rawValue) == .midGray)
    }
}
