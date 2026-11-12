import CoreImage
import Foundation
import Testing
@testable import EditorCore

@Suite struct LensCorrectionTests {
    let frame = CGRect(x: 0, y: 0, width: 300, height: 200)

    /// Vertical stripes 10 px wide, so any horizontal shift shows.
    func stripes() -> CIImage {
        CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor(red: 0.05, green: 0.05, blue: 0.05), "inputColor1": CIColor(red: 0.5, green: 0.5, blue: 0.5), "inputWidth": 10,
        ])!.outputImage!.cropped(to: frame)
    }

    func maxDifference(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
        zip(a, b).map { abs($0.x - $1.x) }.max() ?? 0
    }

    @Test func nothingSetChangesNothing() {
        let base = stripes()
        let output = graded(base) { $0.setScalar(.lensVignetteMidpoint, 80, at: testClock.now()) }
        #expect(pixels(output, rect: CGRect(x: 0, y: 100, width: 300, height: 1)) == pixels(base, rect: CGRect(x: 0, y: 100, width: 300, height: 1)))
    }

    @Test(arguments: [100.0, -100.0, 30.0])
    func distortionKeepsFrameCovered(amount: Double) {
        let base = solid(0.5, 0.5, 0.5, size: 300).cropped(to: frame)
        let output = graded(base) { $0.setScalar(.lensDistortion, amount, at: testClock.now()) }
        #expect(output.extent == frame)
        for (x, y) in [(0.0, 0.0), (299.0, 0.0), (0.0, 199.0), (299.0, 199.0)] {
            #expect(pixel(output, x: x, y: y).w > 0.99, "corner \(x),\(y) is empty")
            #expect(abs(pixel(output, x: x, y: y).x - 0.5) < 1e-3)
        }
    }

    @Test func barrelCorrectionPushesEdgesOutward() {
        // Positive Distortion samples nearer the center the farther out a pixel is.
        let mapping = LensCorrection.Mapping(distortion: 50, red: 0, blue: 0)
        #expect(mapping.source(1) < 1)
        #expect(mapping.source(0.5) < 0.5)
        #expect(abs(mapping.source(0.01) - 0.01) < 1e-4, "the center stays put")
        // Pincushion correction maps the corner exactly onto the corner.
        #expect(abs(LensCorrection.Mapping(distortion: -50, red: 0, blue: 0).source(1) - 1) < 1e-9)
    }

    @Test func distortionMovesPixelsAwayFromCenterOnly() {
        let base = stripes()
        let output = graded(base) { $0.setScalar(.lensDistortion, 80, at: testClock.now()) }
        let center = CGRect(x: 145, y: 100, width: 10, height: 1)
        #expect(maxDifference(pixels(output, rect: center), pixels(base, rect: center)) < 0.01)
        let edge = CGRect(x: 0, y: 100, width: 40, height: 1)
        #expect(maxDifference(pixels(output, rect: edge), pixels(base, rect: edge)) > 0.1)
    }

    @Test func fringeShiftsOnlyItsChannel() {
        let base = stripes()
        let output = graded(base) { $0.setScalar(.lensFringeRed, 100, at: testClock.now()) }
        let edge = pixels(output, rect: CGRect(x: 0, y: 100, width: 60, height: 1))
        let original = pixels(base, rect: CGRect(x: 0, y: 100, width: 60, height: 1))
        #expect(zip(edge, original).map { abs($0.y - $1.y) }.max()! < 1e-3, "green doesn't move")
        #expect(zip(edge, original).map { abs($0.x - $1.x) }.max()! > 0.05, "red does, near the edge")
    }

    /// Core Image once smeared edge pixels outside the frame when the preview
    /// scaled and offset a warp (see `LensCorrection.warp`).
    @Test(arguments: [100.0, -100.0])
    func staysInsideFrameWhenScaledAndOffset(amount: Double) {
        let base = solid(0.5, 0.5, 0.5, size: 400).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 267))
        let warped = graded(base) {
            $0.setScalar(.lensDistortion, amount, at: testClock.now())
            $0.setScalar(.lensFringeRed, 50, at: testClock.now())
        }
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        let shown = warped.transformed(by: CGAffineTransform(scaleX: 0.7756, y: 0.7756))
            .transformed(by: CGAffineTransform(translationX: 39.2, y: 0)).composited(over: black)
        let row = pixels(shown, rect: CGRect(x: 0, y: 0, width: 256, height: 64))
        #expect(row[10 + 32 * 256].x < 1e-3, "left of the frame stays empty")
        #expect(abs(row[60 + 32 * 256].y - 0.5) < 1e-3)
    }

    @Test func vignetteBrightensCornersNotCenter() {
        let base = solid(0.2, 0.2, 0.2, size: 300).cropped(to: frame)
        let output = graded(base) { $0.setScalar(.lensVignette, 50, at: testClock.now()) }
        #expect(abs(pixel(output, x: 150, y: 100).x - pixel(graded(base) { _ in }, x: 150, y: 100).x) < 2e-3)
        #expect(pixel(output, x: 0, y: 0).x > pixel(graded(base) { _ in }, x: 0, y: 0).x * 1.5)
    }
}
