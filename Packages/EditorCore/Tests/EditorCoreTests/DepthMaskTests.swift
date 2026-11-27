import CoreImage
import Foundation
import ImageIO
import Testing
@testable import EditorCore

/// A depth map that gets farther from left (0) to right (1), like a 200 × 100 photo.
struct RampDepth: AIMaskProvider {
    func mask(for shape: MaskShape) -> CIImage? {
        guard shape == .depthMap else { return nil }
        return CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 200, y: 0),
            "inputColor0": CIColor.black, "inputColor1": CIColor.white,
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
    }
}

@Suite struct DepthMaskTests {
    @Test func storesOnlyTheRange() throws {
        let shape = MaskShape.depth(near: 0.2, far: 0.5, feather: 0.1)
        var recipe = Recipe()
        recipe.setMask(sampleMask(shape), at: testClock.now())
        let data = try RecipeCodec.encode(recipe)
        #expect(try RecipeCodec.decode(data) == recipe)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""depth":{"far":0.5,"feather":0.1,"near":0.2}"#), "\(json)")
    }

    @Test func everyRangeSharesOneDepthMap() {
        #expect(AIMaskStore.canonical(.depth(near: 0.1, far: 0.3, feather: 0.05)) == .depthMap)
        #expect(AIMaskStore.canonical(.depth(near: 0.6, far: 0.9, feather: 0.2)) == .depthMap)
        #expect(MaskShape.depth(near: 0, far: 0.4, feather: 0.1).isAI)
    }

    @Test func selectsTheChosenDistances() {
        let near = layer([MaskComponent(shape: .depth(near: 0, far: 0.3, feather: 0.05))])
        #expect(maskValue(near, x: 20, yFromTop: 50, ai: RampDepth()) > 0.95)
        #expect(maskValue(near, x: 120, yFromTop: 50, ai: RampDepth()) < 0.02)

        let middle = layer([MaskComponent(shape: .depth(near: 0.4, far: 0.6, feather: 0.05))])
        #expect(maskValue(middle, x: 100, yFromTop: 50, ai: RampDepth()) > 0.95)
        #expect(maskValue(middle, x: 20, yFromTop: 50, ai: RampDepth()) < 0.02)
        #expect(maskValue(middle, x: 180, yFromTop: 50, ai: RampDepth()) < 0.02)
    }

    @Test func nothingIsSelectedBeforeTheMapIsReady() {
        let shape = layer([MaskComponent(shape: .depth(near: 0, far: 1, feather: 0.1))])
        #expect(maskValue(shape, x: 100, yFromTop: 50, ai: nil) < 0.01)
    }

    @Test func samplesTheDistanceUnderATap() {
        let map = RampDepth().mask(for: .depthMap)!
        #expect(abs(AIMaskStore.sample(map, at: NormalizedPoint(x: 0.25, y: 0.5)) - 0.25) < 0.03)
        #expect(abs(AIMaskStore.sample(map, at: NormalizedPoint(x: 0.75, y: 0.5)) - 0.75) < 0.03)
    }
}

/// Runs the real model (Models/DepthAnything.mlpackage, from scripts/fetch-models.sh).
/// Skipped by `scripts/test-fast.sh` unless `--models`.
@Suite(.serialized) struct DepthModelTests {
    static let modelURL: URL? = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Models/DepthAnything.mlpackage")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    /// A ground plane of tiles shrinking toward a horizon, under a plain sky: the
    /// bottom of the frame is nearest.
    static func scene(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: RenderContext.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.55, green: 0.7, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let horizon = Double(height) * 0.55
        var y = 0.0, row = 0
        while y < horizon - 1 {
            let rowHeight = max((horizon - y) * 0.18, 1)
            let tiles = 6 + row * 2
            for column in 0..<tiles {
                let shade = (column + row).isMultiple(of: 2) ? 0.35 : 0.55
                context.setFillColor(CGColor(srgbRed: shade, green: shade * 0.9, blue: shade * 0.7, alpha: 1))
                let tileWidth = Double(width) / Double(tiles)
                context.fill(CGRect(x: Double(column) * tileWidth, y: y, width: tileWidth, height: rowHeight))
            }
            y += rowHeight
            row += 1
        }
        return context.makeImage()!
    }

    static func meanDistance(_ map: CIImage, rows: ClosedRange<Double>) -> Double {
        let points = stride(from: 0.1, through: 0.9, by: 0.2).flatMap { x in
            stride(from: rows.lowerBound, through: rows.upperBound, by: (rows.upperBound - rows.lowerBound) / 3).map { NormalizedPoint(x: x, y: $0) }
        }
        return points.map { AIMaskStore.sample(map, at: $0) }.reduce(0, +) / Double(points.count)
    }

    @Test(.enabled(if: modelURL != nil)) func theGroundIsNearerThanTheSky() throws {
        DepthEstimator.shared.configure(modelURL: Self.modelURL)
        let map = try DepthEstimator.shared.distanceMap(for: Self.scene(width: 900, height: 600))
        #expect(map.extent == CGRect(x: 0, y: 0, width: 900, height: 600))
        // Points are top-left normalized: the ground is at the bottom.
        let ground = Self.meanDistance(map, rows: 0.75...0.95)
        let sky = Self.meanDistance(map, rows: 0.05...0.3)
        #expect(ground + 0.2 < sky, "ground \(ground), sky \(sky)")
    }

    @Test(.enabled(if: modelURL != nil)) func portraitPhotosAreNotSquashed() throws {
        DepthEstimator.shared.configure(modelURL: Self.modelURL)
        let map = try DepthEstimator.shared.distanceMap(for: Self.scene(width: 600, height: 900))
        #expect(map.extent == CGRect(x: 0, y: 0, width: 600, height: 900))
        let ground = Self.meanDistance(map, rows: 0.75...0.95)
        let sky = Self.meanDistance(map, rows: 0.05...0.3)
        #expect(ground + 0.2 < sky, "ground \(ground), sky \(sky)")
    }

    /// `DEPTH_CHECK=<folder>` writes the distance map of each RAW fixture's embedded
    /// preview there, to look at.
    @Test(.enabled(if: modelURL != nil && ProcessInfo.processInfo.environment["DEPTH_CHECK"] != nil))
    func writesFixtureDepthMaps() throws {
        DepthEstimator.shared.configure(modelURL: Self.modelURL)
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DEPTH_CHECK"]!)
        let fixtures = Self.modelURL!.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures")
        for name in ["DSC04921.ARW", "DSCF2030.raf"] {
            guard let source = CGImageSourceCreateWithURL(fixtures.appending(path: name) as CFURL, nil),
                  let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1536,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { continue }
            let map = try DepthEstimator.shared.distanceMap(for: preview)
            let cg = RenderContext.shared.createCGImage(map, from: map.extent, format: .RGBA8, colorSpace: RenderContext.sRGB)!
            let destination = CGImageDestinationCreateWithURL(out.appending(path: "\(name)-depth.png") as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, cg, nil)
            CGImageDestinationFinalize(destination)
        }
    }
}
