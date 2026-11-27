import CoreImage
import Foundation
import Testing
@testable import EditorCore

/// Four-corner perspective: four points on the photo become a rectangle.
@Suite struct PerspectiveCornersTests {
    @Test func storesFourPointsCompactly() throws {
        let quad = PerspectiveQuad(topLeft: NormalizedPoint(x: 0.1, y: 0.2), topRight: NormalizedPoint(x: 0.9, y: 0.1),
                                   bottomRight: NormalizedPoint(x: 0.95, y: 0.9), bottomLeft: NormalizedPoint(x: 0.05, y: 0.85))
        var recipe = Recipe()
        recipe.set(.perspectiveCorners, .quad(quad), at: testClock.now())
        let data = try RecipeCodec.encode(recipe)
        #expect(try RecipeCodec.decode(data) == recipe)
        #expect(String(decoding: data, as: UTF8.self).contains(#""crop.perspective.corners":{"quad":[[0.1,0.2],[0.9,0.1],[0.95,0.9],[0.05,0.85]]}"#))
        #expect(ParamCatalog.spec(for: .perspectiveCorners)?.group == .crop)
    }

    @Test func rejectsTwistedOrTinyShapes() {
        #expect(PerspectiveQuad.inset(0.1).isValid)
        // Corners out of order: a bow tie.
        let twisted = PerspectiveQuad(topLeft: NormalizedPoint(x: 0.1, y: 0.1), topRight: NormalizedPoint(x: 0.9, y: 0.9),
                                      bottomRight: NormalizedPoint(x: 0.9, y: 0.1), bottomLeft: NormalizedPoint(x: 0.1, y: 0.9))
        #expect(!twisted.isValid)
        #expect(!PerspectiveQuad.inset(0.48).isValid)
        // An invalid quad leaves the photo alone.
        let image = solid(0.5, 0.5, 0.5, size: 100)
        #expect(GradeGraph.corners(image, twisted).extent == image.extent)
    }

    /// A white trapezoid on black (a "facade" shot from below) straightens into a
    /// rectangle that fills the output.
    @Test func turnsTheQuadIntoARectangle() {
        let size = 400.0
        // Narrower at the top: x 120...280 at the top, 40...360 at the bottom (CI y is up).
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 40, y: 40)); path.addLine(to: CGPoint(x: 360, y: 40))
        path.addLine(to: CGPoint(x: 280, y: 360)); path.addLine(to: CGPoint(x: 120, y: 360)); path.closeSubpath()
        let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                                space: RenderContext.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); context.addPath(path); context.fillPath()
        let image = CIImage(cgImage: context.makeImage()!)
        // The same corners, normalized from the top left.
        let quad = PerspectiveQuad(topLeft: NormalizedPoint(x: 120 / size, y: 40 / size), topRight: NormalizedPoint(x: 280 / size, y: 40 / size),
                                   bottomRight: NormalizedPoint(x: 360 / size, y: 360 / size), bottomLeft: NormalizedPoint(x: 40 / size, y: 360 / size))
        let corrected = GradeGraph.corners(image, quad)
        let e = corrected.extent
        #expect(e.origin == .zero)
        #expect(e.width > 100 && e.height > 100, "\(e)")
        // White everywhere inside, including the corners that were black triangles before.
        for (x, y) in [(0.08, 0.08), (0.92, 0.08), (0.08, 0.92), (0.92, 0.92), (0.5, 0.5)] {
            #expect(pixel(corrected, x: e.width * x, y: e.height * y).x > 0.9, "(\(x), \(y))")
        }
    }

    @Test func runsBeforeCropAndKeystone() throws {
        var recipe = Recipe()
        recipe.set(.perspectiveCorners, .quad(.inset(0.25)), at: testClock.now())
        let out = GradeGraph.geometry(solid(0.5, 0.5, 0.5, size: 400), recipe)
        // The middle half of the frame, stretched to its own size: about 200 × 200.
        #expect(abs(out.extent.width - 200) < 4 && abs(out.extent.height - 200) < 4, "\(out.extent)")
    }
}
