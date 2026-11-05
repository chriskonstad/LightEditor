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

    /// How decodes were made before filters were reused.
    static func freshDecode(_ url: URL, _ stage: RawStageParams, longEdge: Int) throws -> [UInt16] {
        let raw = try #require(CIRAWFilter(imageURL: url))
        let wanted = CIRAWDecoderVersion(rawValue: stage.decoderVersion)
        raw.decoderVersion = raw.supportedDecoderVersions.contains(wanted) ? wanted : raw.supportedDecoderVersions.last!
        if let v = stage.noiseReduction { raw.luminanceNoiseReductionAmount = Float(v / 100) }
        if let v = stage.colorNoise { raw.colorNoiseReductionAmount = Float(v / 100) }
        if let v = stage.sharpness { raw.sharpnessAmount = Float(v / 100) }
        if let v = stage.detail { raw.detailAmount = Float(v / 100) }
        if let v = stage.lensCorrection, raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = v >= 0.5 }
        raw.scaleFactor = Float(min(1, Double(longEdge) / max(raw.nativeSize.width, raw.nativeSize.height)))
        return try pixels(raw.outputImage!)
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
                let fresh = try Self.freshDecode(url, stage, longEdge: longEdge)
                #expect(reused == fresh, "\(url.lastPathComponent) stage \(index)")
            }
        }
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
