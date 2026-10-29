import CoreImage
import Foundation
import Testing
@testable import EditorCore

/// Renders a mask layer's gray mask at (x, y) in a 200×100 frame, y measured from the top.
func maskValue(_ layer: MaskLayer, x: CGFloat, yFromTop: CGFloat, current: CIImage? = nil, ai: (any AIMaskProvider)? = nil) -> Float {
    let extent = CGRect(x: 0, y: 0, width: 200, height: 100)
    let base = current ?? solid(0.2, 0.2, 0.2, size: 200).cropped(to: extent)
    guard let mask = MaskRenderer.maskImage(layer, extent: extent, current: base, ai: ai) else { return -1 }
    return pixel(mask, x: x, y: 99 - yFromTop).x
}

func layer(_ components: [MaskComponent], adjustments: [ParamKey: Double] = [.exposure: 1], amount: Double = 1) -> MaskLayer {
    MaskLayer(name: "Test", order: 1, components: components, adjustments: adjustments, amount: amount)
}

struct FixedAIMasks: AIMaskProvider {
    /// Left half selected.
    func mask(for shape: MaskShape) -> CIImage? {
        let left = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 50))
        return left.composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 50)))
    }
}

@Suite struct MaskRenderTests {
    @Test func linearGradientFadesFromStartToEnd() {
        let gradient = layer([MaskComponent(shape: .linear(start: NormalizedPoint(x: 0.5, y: 0), end: NormalizedPoint(x: 0.5, y: 0.5)))])
        #expect(maskValue(gradient, x: 100, yFromTop: 1) > 0.95)
        #expect(maskValue(gradient, x: 100, yFromTop: 25) > 0.2)
        #expect(maskValue(gradient, x: 100, yFromTop: 80) < 0.02)
    }

    @Test func radialSelectsInsideTheEllipse() {
        let radial = layer([MaskComponent(shape: .radial(center: NormalizedPoint(x: 0.25, y: 0.5), radiusX: 0.2, radiusY: 0.4, angle: 0, feather: 0.3))])
        #expect(maskValue(radial, x: 50, yFromTop: 50) > 0.95)
        #expect(maskValue(radial, x: 150, yFromTop: 50) < 0.02)
        let inverted = layer([MaskComponent(inverted: true, shape: .radial(center: NormalizedPoint(x: 0.25, y: 0.5), radiusX: 0.2, radiusY: 0.4, angle: 0, feather: 0.3))])
        #expect(maskValue(inverted, x: 150, yFromTop: 50) > 0.95)
    }

    @Test func brushPaintsAlongStrokesAndErases() {
        let stroke = BrushStroke(points: [NormalizedPoint(x: 0.1, y: 0.5), NormalizedPoint(x: 0.9, y: 0.5)], radius: 0.05, feather: 0.2)
        let brush = layer([MaskComponent(shape: .brush(strokes: [stroke]))])
        #expect(maskValue(brush, x: 100, yFromTop: 50) > 0.9)
        #expect(maskValue(brush, x: 100, yFromTop: 10) < 0.05)
        let erase = BrushStroke(points: [NormalizedPoint(x: 0.5, y: 0.2), NormalizedPoint(x: 0.5, y: 0.8)], radius: 0.05, feather: 0, erase: true)
        let erased = layer([MaskComponent(shape: .brush(strokes: [stroke, erase]))])
        #expect(maskValue(erased, x: 100, yFromTop: 50) < 0.1)
        #expect(maskValue(erased, x: 40, yFromTop: 50) > 0.9)
    }

    @Test func luminanceRangeSelectsBrightAreas() {
        let current = edgeImage(width: 200, height: 100, dark: 0.02, bright: 0.7)
        let bright = layer([MaskComponent(shape: .luminance(low: 0.6, high: 1, feather: 0.05))])
        #expect(maskValue(bright, x: 150, yFromTop: 50, current: current) > 0.95)
        #expect(maskValue(bright, x: 50, yFromTop: 50, current: current) < 0.02)
    }

    @Test func colorRangeSelectsTheSampledColor() {
        let blue = solid(0.05, 0.2, 0.8, size: 200).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
        let red = solid(0.8, 0.1, 0.05, size: 200).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let current = blue.composited(over: red)
        let lab = ColorMath.linearToOklab(0.05, 0.2, 0.8)
        let picker = layer([MaskComponent(shape: .color(l: lab.L, a: lab.a, b: lab.b, range: 0.4))])
        #expect(maskValue(picker, x: 150, yFromTop: 50, current: current) > 0.95)
        #expect(maskValue(picker, x: 50, yFromTop: 50, current: current) < 0.02)
    }

    @Test func componentsCombine() {
        let left = MaskComponent(shape: .linear(start: NormalizedPoint(x: 0, y: 0.5), end: NormalizedPoint(x: 0.1, y: 0.5)))  // the left tenth
        let everything = MaskComponent(shape: .luminance(low: 0, high: 1, feather: 0.01))
        let circle = MaskComponent(shape: .radial(center: NormalizedPoint(x: 0.5, y: 0.5), radiusX: 0.1, radiusY: 0.2, angle: 0, feather: 0.1))

        let subtract = layer([everything, MaskComponent(operation: .subtract, shape: circle.shape)])
        #expect(maskValue(subtract, x: 100, yFromTop: 50) < 0.02)
        #expect(maskValue(subtract, x: 20, yFromTop: 50) > 0.95)

        let intersect = layer([everything, MaskComponent(operation: .intersect, shape: circle.shape)])
        #expect(maskValue(intersect, x: 100, yFromTop: 50) > 0.95)
        #expect(maskValue(intersect, x: 20, yFromTop: 50) < 0.02)

        let union = layer([left, circle])
        #expect(maskValue(union, x: 100, yFromTop: 50) > 0.95)
        #expect(maskValue(union, x: 0, yFromTop: 50) > 0.9)
    }

    @Test func aiMasksStretchToTheFrame() {
        let subject = layer([MaskComponent(shape: .ai(kind: .subject))])
        #expect(maskValue(subject, x: 50, yFromTop: 50, ai: FixedAIMasks()) > 0.95)
        #expect(maskValue(subject, x: 150, yFromTop: 50, ai: FixedAIMasks()) < 0.05)
        #expect(maskValue(subject, x: 50, yFromTop: 50, ai: nil) == 0, "not computed yet means no effect")
    }

    @Test func localAdjustmentsApplyOnlyInsideTheMask() {
        let base = solid(0.1, 0.1, 0.1, size: 200).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        var recipe = Recipe()
        recipe.setMask(layer([MaskComponent(shape: .radial(center: NormalizedPoint(x: 0.25, y: 0.5), radiusX: 0.15, radiusY: 0.3, angle: 0, feather: 0.1))], adjustments: [.exposure: 1]), at: testClock.now())
        let output = GradeGraph.apply(recipe, to: base, inputs: GradeInputs(defaults: .generic))
        #expect(abs(pixel(output, x: 50, y: 50).x - 0.2) < 3e-3, "+1 EV inside")
        #expect(abs(pixel(output, x: 170, y: 50).x - 0.1) < 1e-3, "untouched outside")
    }

    @Test func amountScalesTheEffect() {
        let base = solid(0.1, 0.1, 0.1, size: 200).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        var recipe = Recipe()
        recipe.setMask(layer([MaskComponent(shape: .luminance(low: 0, high: 1, feather: 0.01))], adjustments: [.exposure: 1], amount: 0.5), at: testClock.now())
        let value = pixel(GradeGraph.apply(recipe, to: base, inputs: GradeInputs(defaults: .generic)), x: 100, y: 50).x
        #expect(abs(value - 0.15) < 3e-3)
    }

    @Test func localWarmthWarms() {
        let base = solid(0.3, 0.3, 0.3, size: 200).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        var recipe = Recipe()
        recipe.setMask(layer([MaskComponent(shape: .luminance(low: 0, high: 1, feather: 0.01))], adjustments: [.localTemperature: 60]), at: testClock.now())
        let p = pixel(GradeGraph.apply(recipe, to: base, inputs: GradeInputs(defaults: .generic)), x: 100, y: 50)
        #expect(p.x > p.z)
    }

    @Test func overlayTintsTheSelection() {
        let base = solid(0.3, 0.3, 0.3, size: 200).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        var recipe = Recipe()
        let shown = layer([MaskComponent(shape: .radial(center: NormalizedPoint(x: 0.25, y: 0.5), radiusX: 0.15, radiusY: 0.3, angle: 0, feather: 0.1))], adjustments: [:])
        recipe.setMask(shown, at: testClock.now())
        let output = GradeGraph.apply(recipe, to: base, inputs: GradeInputs(defaults: .generic, maskOverlay: shown.id))
        let inside = pixel(output, x: 50, y: 50), outside = pixel(output, x: 170, y: 50)
        #expect(inside.x > inside.y + 0.1)
        #expect(abs(outside.x - outside.y) < 1e-3)
    }

    @Test func previewAndExportScaleMatch() {
        // The same recipe at two resolutions selects the same relative area.
        let small = CGRect(x: 0, y: 0, width: 200, height: 100), large = CGRect(x: 0, y: 0, width: 800, height: 400)
        let gradient = layer([MaskComponent(shape: .radial(center: NormalizedPoint(x: 0.3, y: 0.4), radiusX: 0.2, radiusY: 0.2, angle: 30, feather: 0.6))])
        func sample(_ extent: CGRect, _ fx: CGFloat, _ fy: CGFloat) -> Float {
            let base = solid(0.2, 0.2, 0.2, size: 800).cropped(to: extent)
            let mask = MaskRenderer.maskImage(gradient, extent: extent, current: base, ai: nil)!
            return pixel(mask, x: fx * extent.width, y: (1 - fy) * extent.height - 1).x
        }
        for (fx, fy) in [(0.3, 0.4), (0.4, 0.45), (0.2, 0.3)] {
            #expect(abs(sample(small, fx, fy) - sample(large, fx, fy)) < 0.05)
        }
    }
}
