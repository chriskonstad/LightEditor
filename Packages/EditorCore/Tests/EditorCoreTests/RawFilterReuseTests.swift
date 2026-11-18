import CoreImage
import Foundation
import Testing
@testable import EditorCore

/// `RawDecoder` reuses one `CIRAWFilter` per photo. Every decode must come out
/// exactly as from a fresh filter set up for it alone. Set EDITORCORE_RAW_FIXTURES to run.
@Suite(.serialized) struct RawFilterReuseTests {
    /// One file of each RAW kind.
    static var raws: [URL] {
        let all = DecodeTests.fixtureFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return ["arw", "raf", "dng"].compactMap { kind in all.first { $0.pathExtension.lowercased() == kind } }
    }

    /// Set EDITORCORE_PRORAW_FIXTURE to an Apple ProRAW DNG that supports RAW 9.
    static var proRAWFixture: URL? {
        ProcessInfo.processInfo.environment["EDITORCORE_PRORAW_FIXTURE"].map { URL(fileURLWithPath: $0) }
    }

    static func pixels(_ image: CIImage) throws -> [UInt16] {
        let e = image.extent.integral
        let buffer = try #require(PixelBuffers.make(width: Int(e.width), height: Int(e.height)))
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = RenderContext.linearP3
        _ = try RenderContext.shared.startTask(toRender: image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)),
                                               from: CGRect(origin: .zero, size: e.size), to: destination, at: .zero).waitUntilCompleted()
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let count = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer) / 2
        return Array(UnsafeBufferPointer(start: CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt16.self), count: count))
    }

    @Test(.enabled(if: !raws.isEmpty)) func reusedFilterMatchesFreshOnes() async throws {
        let stages: [RawStageParams] = [
            RawStageParams(),
            RawStageParams(noiseReduction: 40, sharpness: 70),
            RawStageParams(colorNoise: 20, detail: 60, lensCorrection: 0),
            RawStageParams(),  // back to every default
            RawStageParams(decoderVersion: "8"),
            RawStageParams(),
        ]
        for url in Self.raws {
            let decoder = RawDecoder(cache: DecodeCache(directory: nil))
            let source = PhotoSource(url: url, key: UUID().uuidString)
            for (index, stage) in stages.enumerated() {
                let longEdge = index % 2 == 0 ? 640 : 1024
                let (image, _) = try await decoder.lazyImage(source, rawStage: stage, longEdge: longEdge)
                let reused = try Self.pixels(image)
                let fresh = RawDecoder(cache: DecodeCache(directory: nil))
                let (expected, _) = try await fresh.lazyImage(source, rawStage: stage, longEdge: longEdge)
                #expect(reused == (try Self.pixels(expected)), "\(url.lastPathComponent) stage \(index)")
            }
        }
    }

    @Test(.enabled(if: proRAWFixture != nil)) func proRAWPreviewMatchesFullFrame() async throws {
        let source = PhotoSource(url: try #require(Self.proRAWFixture))
        let decoder = RawDecoder(cache: DecodeCache(directory: nil))
        let stage = RawStageParams(decoderVersion: CIRAWDecoderVersion.version9DNG.rawValue)
        let (full, _) = try await decoder.lazyImage(source, rawStage: stage, longEdge: nil)
        let nativeLongEdge = max(full.extent.width, full.extent.height)
        let longEdge = min(2560, Int(nativeLongEdge / 2))
        let (preview, info) = try await decoder.lazyImage(source, rawStage: stage, longEdge: longEdge)
        let expected = full.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: Double(longEdge) / nativeLongEdge,
            kCIInputAspectRatioKey: 1,
        ])
        #expect(info.decoderVersion == stage.decoderVersion)
        #expect(preview.extent.integral.size == expected.extent.integral.size)
        let pixelsMatch = try Self.pixels(preview) == Self.pixels(expected)
        #expect(pixelsMatch, "The reduced decode should show the entire ProRAW frame")
    }

    /// Tiles rendering on other threads from an earlier output while the decoder
    /// sets the shared filter up for other sizes, as the editor and a save do.
    @Test(.enabled(if: !raws.isEmpty)) func tilesRenderWhileTheFilterIsReused() async throws {
        let url = try #require(Self.raws.first)
        let decoder = RawDecoder(cache: DecodeCache(directory: nil))
        let source = PhotoSource(url: url, key: UUID().uuidString)
        let (full, _) = try await decoder.lazyImage(source, rawStage: RawStageParams(), longEdge: nil)
        let rects = (0..<8).map { CGRect(x: 600 * $0, y: 800, width: 512, height: 512) }
        let expected = try rects.map { try Self.pixels(full.cropped(to: $0)) }
        let box = UncheckedImage(image: full)
        async let tiles = withThrowingTaskGroup(of: (Int, [UInt16]).self) { group in
            for (index, rect) in rects.enumerated() { group.addTask { (index, try Self.pixels(box.image.cropped(to: rect))) } }
            var out = [[UInt16]](repeating: [], count: rects.count)
            for try await (index, pixels) in group { out[index] = pixels }
            return out
        }
        for edge in [640, 2560, 1024, 512, 2560] { _ = try await decoder.lazyImage(source, rawStage: RawStageParams(), longEdge: edge) }
        #expect(try await tiles == expected)
    }

    struct UncheckedImage: @unchecked Sendable { let image: CIImage }
}
