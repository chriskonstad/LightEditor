import CoreImage
import Foundation
import Testing
@testable import EditorCore

@Suite struct SkySeedTests {
    func cgImage(_ image: CIImage) -> CGImage {
        let made = RenderContext.shared.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: RenderContext.sRGB)
        if made == nil { print("createCGImage failed for extent \(image.extent)") }
        return made!
    }

    @Test func findsSmoothBrightSky() {
        // Pale blue top half, dark noisy ground below.
        let sky = solid(0.35, 0.5, 0.8, size: 400).cropped(to: CGRect(x: 0, y: 150, width: 400, height: 150))
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 400, height: 150))
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.2, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.2, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0.2, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 150))
        let seeds = AIMaskStore.skySeeds(in: cgImage(sky.composited(over: noise)))
        #expect(!seeds.isEmpty)
        #expect(seeds.allSatisfy { $0.y < 0.2 }, "seeds sit near the top")
    }

    @Test func ignoresBusyOrDarkTops() {
        // Coarse texture, so it survives the 64 px analysis downsample.
        let busy = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .transformed(by: CGAffineTransform(scaleX: 6, y: 6)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(AIMaskStore.skySeeds(in: cgImage(busy)).isEmpty)
        #expect(AIMaskStore.skySeeds(in: cgImage(solid(0.01, 0.01, 0.01, size: 300))).isEmpty)
        #expect(AIMaskStore.skySeeds(in: cgImage(solid(0.1, 0.5, 0.1, size: 300))).isEmpty, "foliage green isn't sky")
    }

    @Test func backgroundIsTheInverseOfTheSubject() {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 100)
        let background = MaskLayer(name: "BG", order: 1, components: [MaskComponent(shape: .ai(kind: .background))])
        let base = solid(0.2, 0.2, 0.2, size: 200).cropped(to: extent)
        let mask = MaskRenderer.maskImage(background, extent: extent, current: base, ai: FixedAIMasks())!
        #expect(pixel(mask, x: 50, y: 50).x < 0.05)
        #expect(pixel(mask, x: 150, y: 50).x > 0.95)
    }
}

/// Runs Vision on real photos. Set EDITORCORE_RAW_FIXTURES to run.
@Suite(.serialized) struct VisionMaskTests {
    static func fixture(_ prefix: String) -> URL? {
        DecodeTests.fixtureFiles.first { $0.lastPathComponent.hasPrefix(prefix) }
    }

    func store(for url: URL) async throws -> (AIMaskStore, CIImage) {
        let decoder = RawDecoder(cache: DecodeCache(directory: nil))
        let base = try await decoder.decode(PhotoSource(url: url), rawStage: RawStageParams(), longEdge: 1024)
        let store = AIMaskStore(photoKey: UUID().uuidString, directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        return (store, base.image)
    }

    /// Fraction of mask pixels above 0.5 in a normalized region (top-left origin).
    func coverage(_ mask: CIImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> Double {
        let extent = mask.extent
        let rect = CGRect(x: extent.minX + x.lowerBound * extent.width, y: extent.minY + (1 - y.upperBound) * extent.height,
                          width: (x.upperBound - x.lowerBound) * extent.width, height: (y.upperBound - y.lowerBound) * extent.height).integral
        let values = pixels(mask, rect: rect).map(\.x)
        return Double(values.filter { $0 > 0.5 }.count) / Double(max(values.count, 1))
    }

    @Test(.enabled(if: fixture("DSCF2030") != nil)) func findsTheSunsetSky() async throws {
        let (store, base) = try await store(for: Self.fixture("DSCF2030")!)
        try await store.compute(.ai(kind: .sky), base: base)
        let mask = try #require(store.mask(for: .ai(kind: .sky)))
        let top = coverage(mask, x: 0.1...0.9, y: 0.02...0.2), bottom = coverage(mask, x: 0.1...0.9, y: 0.8...0.98)
        print("sky coverage top \(top) bottom \(bottom)")
        #expect(top > 0.8)
        #expect(bottom < 0.1)
    }

    @Test(.enabled(if: fixture("DSC04319") != nil)) func noSkyOverAStreet() async throws {
        let (store, base) = try await store(for: Self.fixture("DSC04319")!)
        await #expect(throws: AIMaskError.self) { try await store.compute(.ai(kind: .sky), base: base) }
    }

    @Test(.enabled(if: fixture("DSC04319") != nil)) func findsPeopleAndSubjects() async throws {
        let (store, base) = try await store(for: Self.fixture("DSC04319")!)
        try await store.compute(.ai(kind: .people), base: base)
        try await store.compute(.ai(kind: .subject), base: base)
        let people = try #require(store.mask(for: .ai(kind: .people)))
        let overall = coverage(people, x: 0...1, y: 0...1)
        print("people coverage \(overall)")
        #expect(overall > 0.05 && overall < 0.6)
        #expect(store.hasMask(for: .ai(kind: .background)), "background shares the subject result")
    }

    @Test(.enabled(if: fixture("DSCF2763") != nil)) func tapSelectsTheObjectUnderTheFinger() async throws {
        let (store, base) = try await store(for: Self.fixture("DSCF2763")!)
        // The woman in the portrait fills the middle of the frame.
        let tap = MaskShape.object(seeds: [NormalizedPoint(x: 0.5, y: 0.5)])
        try await store.compute(tap, base: base)
        let mask = try #require(store.mask(for: tap))
        #expect(coverage(mask, x: 0.45...0.55, y: 0.45...0.55) > 0.8)
        #expect(coverage(mask, x: 0...0.05, y: 0...0.05) < 0.2)
    }

    @Test(.enabled(if: fixture("DSCF2763") != nil)) func masksSurviveOnDisk() async throws {
        let url = Self.fixture("DSCF2763")!
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let decoder = RawDecoder(cache: DecodeCache(directory: nil))
        let base = try await decoder.decode(PhotoSource(url: url), rawStage: RawStageParams(), longEdge: 1024)
        let first = AIMaskStore(photoKey: "same-photo", directory: directory)
        try await first.compute(.ai(kind: .subject), base: base.image)
        let second = AIMaskStore(photoKey: "same-photo", directory: directory)
        #expect(second.hasMask(for: .ai(kind: .subject)))
        #expect(!AIMaskStore(photoKey: "other-photo", directory: directory).hasMask(for: .ai(kind: .subject)))
    }

    @Test(.enabled(if: fixture("DSCF2763") != nil)) func exportAppliesAIMasks() async throws {
        let url = Self.fixture("DSCF2763")!
        var recipe = Recipe(decoder: .none)
        recipe.setMask(MaskLayer(name: "Subject", order: 1, components: [MaskComponent(shape: .ai(kind: .subject))], adjustments: [.exposure: 2]), at: testClock.now())
        let plain = try await Exporter.render(source: PhotoSource(url: url, key: "export-test"), recipe: Recipe(decoder: .none), luts: nil, options: ExportOptions(format: .jpeg, longEdge: 512))
        let masked = try await Exporter.render(source: PhotoSource(url: url, key: "export-test"), recipe: recipe, luts: nil, options: ExportOptions(format: .jpeg, longEdge: 512))
        func centerLuma(_ data: Data) -> Float {
            let image = CIImage(data: data)!
            let p = pixel(image, x: image.extent.midX, y: image.extent.midY)
            return p.x + p.y + p.z
        }
        #expect(centerLuma(masked) > centerLuma(plain) * 1.5, "the subject in the middle is brighter")
    }
}
