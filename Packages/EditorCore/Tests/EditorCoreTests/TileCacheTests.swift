import CoreImage
import Foundation
import Testing
@testable import EditorCore

@Suite struct TileCacheTests {
    /// A horizontal and vertical ramp, so any misplaced tile shows.
    private func ramp(width: CGFloat, height: CGFloat) -> CIImage {
        let red = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: width, y: 0),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 0, blue: 0),
        ])!.outputImage!
        let green = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: height),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 0, green: 1, blue: 0),
        ])!.outputImage!
        return red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    @Test func keysCoverTheRequestedArea() {
        let cache = TileCache(source: ramp(width: 3000, height: 2000), level: 1) {}
        let keys = cache.keys(covering: CGRect(x: 1000, y: 500, width: 100, height: 100))
        #expect(keys == [.init(column: 0, row: 0), .init(column: 1, row: 0)])
        #expect(cache.keys(covering: CGRect(x: 5000, y: 0, width: 10, height: 10)).isEmpty)
        // Edge tiles are clipped to the image.
        #expect(cache.rect(for: .init(column: 2, row: 1)) == CGRect(x: 2048, y: 1024, width: 952, height: 976))
    }

    @Test func decodedTilesMatchTheSourceAndFallbackFillsTheRest() async throws {
        let source = ramp(width: 3000, height: 2000)
        let arrived = AsyncStream<Void>.makeStream()
        let cache = TileCache(source: source, level: 1) { arrived.continuation.yield() }
        // Pixels well outside any tile come from the fallback, enlarged.
        let fallback = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        cache.request(CGRect(x: 1100, y: 1100, width: 200, height: 200))  // One tile: column 1, row 1.
        var count = 0
        for await _ in arrived.stream {
            count += 1
            if cache.pendingCount == 0 { break }
        }
        #expect(count == 1)
        let composed = cache.image(over: fallback)
        #expect(composed.extent == source.extent)
        let inside = pixel(composed, x: 1500, y: 1500), expected = pixel(source, x: 1500, y: 1500)
        #expect(abs(inside.x - expected.x) < 0.01 && abs(inside.y - expected.y) < 0.01 && inside.z < 0.01)
        let outside = pixel(composed, x: 100, y: 100)
        #expect(outside.z > 0.99 && outside.x < 0.01)
    }

    @Test func requestsAreCappedToTheLimitNearestTheMiddle() async {
        let cache = TileCache(source: ramp(width: 8192, height: 8192), level: 1, limit: 4) {}
        cache.request(CGRect(x: 0, y: 0, width: 8192, height: 8192))
        #expect(cache.pendingCount <= 4)
        cache.cancelAll()
    }

    @Test func proxyKeepsAspectAndContent() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        try RenderContext.shared.writePNGRepresentation(of: ramp(width: 2560, height: 1707), to: url, format: .RGBA8,
                                                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = RawDecoder(cache: DecodeCache(directory: nil))
        let decoded = try await decoder.decode(PhotoSource(url: url), rawStage: RawStageParams(), longEdge: 2560)
        let small = try decoded.downscaled(toLongEdge: 640)
        #expect(small.size == CGSize(width: 640, height: 427))
        // Same content as the decode at the same relative spot.
        let middle = pixel(small.image, x: 320, y: 213), reference = pixel(decoded.image, x: 1280, y: 853)
        #expect(abs(middle.x - reference.x) < 0.02 && abs(middle.y - reference.y) < 0.02)
    }
}
