import CoreImage
import CoreVideo
import Foundation

/// Times the preview pipeline's stages on a real photo, for tuning on devices.
/// Debug builds run it with `-RenderBenchmark YES` (see the app's diagnostics).
public enum RenderBenchmark {
    /// A busy but typical edit: tone, presence (with blurs), color, HSL, grading, vignette.
    static func typicalRecipe() -> Recipe {
        var recipe = Recipe()
        let stamp = HLCStamp(millis: 1, node: "bench")
        for (key, value) in [(ParamKey.exposure, 0.3), (.contrast, 15), (.highlights, -30), (.shadows, 25), (.clarity, 20),
                             (.texture, 10), (.dehaze, 10), (.vibrance, 15), (.vignetteAmount, -15),
                             (.hsl(.blue, .saturation), 20), (.hsl(.orange, .luminance), 10)] as [(ParamKey, Double)] {
            recipe.setScalar(key, value, at: stamp)
        }
        recipe.set(.gradeWheel(.shadows), .point(x: 0.2, y: -0.1), at: stamp)
        return recipe
    }

    /// Renders `image`'s `rect` into a buffer the size of `rect`; returns milliseconds.
    static func time(_ image: CIImage, rect: CGRect, context: CIContext = RenderContext.shared) throws -> Double {
        guard let buffer = PixelBuffers.make(width: Int(rect.width), height: Int(rect.height)) else { throw DecodeError.renderFailed }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = RenderContext.linearP3
        let start = ContinuousClock.now
        let task = try context.startTask(toRender: image, from: rect, to: destination, at: .zero)
        _ = try task.waitUntilCompleted()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    /// The median of `runs` timings after one warm-up, plus the cold first run.
    static func measure(_ label: String, runs: Int = 3, log: (String) -> Void, _ body: () throws -> Double) {
        do {
            let cold = try body()
            let warm = try (0..<runs).map { _ in try body() }.sorted()[runs / 2]
            log(String(format: "%@: cold %.0f ms, warm %.0f ms", label, cold, warm))
        } catch {
            log("\(label): failed \(error)")
        }
    }

    public static func run(url: URL, screen: CGSize = CGSize(width: 1206, height: 804), log: @escaping @Sendable (String) -> Void) async {
        let source = PhotoSource(url: url, key: "bench-\(UUID().uuidString)")
        let decoder = RawDecoder(cache: DecodeCache(directory: nil))
        let recipe = typicalRecipe()
        let inputs = GradeInputs(defaults: .generic)
        let screenRect = CGRect(origin: .zero, size: screen)
        do {
            var clock = ContinuousClock.now
            let base = try await decoder.decode(source, rawStage: RawStageParams(), longEdge: 2560)
            log("decode 2560: \(clock.duration(to: .now))")
            let full = try await decoder.lazyImage(source, rawStage: RawStageParams(), longEdge: nil).0
            log("full-res extent \(full.extent.size)")

            // Graph building alone, on this thread.
            clock = .now
            for _ in 0..<20 { _ = GradeGraph.apply(recipe, to: base.image, inputs: inputs) }
            log("graph build: \(clock.duration(to: .now) / 20) each")

            // Fit: graded image scaled into the screen.
            func fit(_ image: CIImage) -> CIImage {
                let scale = min(screen.width / image.extent.width, screen.height / image.extent.height)
                return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            measure("fit, grade 2560 then scale (today)", log: log) {
                try time(fit(GradeGraph.apply(recipe, to: base.image, inputs: inputs)), rect: screenRect)
            }
            var proxies: [Int: DecodedImage] = [:]
            for edge in [1280, 800, 640] {
                let proxy = try await decoder.decode(source, rawStage: RawStageParams(), longEdge: edge)
                proxies[edge] = proxy
                measure("fit, grade \(edge) proxy", log: log) {
                    try time(fit(GradeGraph.apply(recipe, to: proxy.image, inputs: inputs)), rect: screenRect)
                }
            }
            if let proxy = proxies[1280], let small = proxies[640] {
                var guided = inputs
                guided.presenceGuide = small.image
                measure("fit, grade 1280 proxy, blurs from 640", log: log) {
                    try time(fit(GradeGraph.apply(recipe, to: proxy.image, inputs: guided)), rect: screenRect)
                }
            }
            var plain = recipe
            for key in [ParamKey.clarity, .texture, .dehaze] { plain.set(key, nil, at: HLCStamp(millis: 2, node: "bench")) }
            measure("fit, grade 2560, no clarity/texture/dehaze", log: log) {
                try time(fit(GradeGraph.apply(plain, to: base.image, inputs: inputs)), rect: screenRect)
            }

            // 100%: the visible screen-sized area from the middle of the full-res image.
            let center = CGRect(x: full.extent.midX - screen.width / 2, y: full.extent.midY - screen.height / 2,
                                width: screen.width, height: screen.height).integral
            measure("100%, grade full-res RAW (today)", runs: 2, log: log) {
                try time(GradeGraph.apply(recipe, to: full, inputs: inputs), rect: center)
            }
            measure("100%, RAW decode only", runs: 2, log: log) { try time(full, rect: center) }
            let tile = CGRect(x: center.minX, y: center.minY, width: 1024, height: 1024)
            measure("tile 1024 RAW decode", runs: 2, log: log) { try time(full, rect: tile) }
            // The visible area plus a margin, decoded once into a buffer, then graded.
            let margin = center.insetBy(dx: -512, dy: -512).intersection(full.extent)
            if let buffer = PixelBuffers.make(width: Int(margin.width), height: Int(margin.height)) {
                let destination = CIRenderDestination(pixelBuffer: buffer)
                destination.colorSpace = RenderContext.linearP3
                clock = .now
                _ = try RenderContext.shared.startTask(toRender: full, from: margin, to: destination, at: .zero).waitUntilCompleted()
                log("decode visible + margin \(margin.size): \(clock.duration(to: .now))")
                let cached = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: RenderContext.linearP3])
                    .transformed(by: CGAffineTransform(translationX: margin.minX, y: margin.minY))
                // Full extent: the cached area over the 2560 base scaled up, as a tile source would be.
                let upscale = full.extent.width / base.image.extent.width
                let fallback = base.image.transformed(by: CGAffineTransform(scaleX: upscale, y: upscale))
                let tiled = cached.composited(over: fallback).cropped(to: full.extent)
                measure("100%, grade cached tiles", log: log) {
                    try time(GradeGraph.apply(recipe, to: tiled, inputs: inputs), rect: center)
                }
                measure("100%, grade cached tiles, no clarity/texture/dehaze", log: log) {
                    try time(GradeGraph.apply(plain, to: tiled, inputs: inputs), rect: center)
                }
                var guided = inputs
                guided.presenceGuide = base.image
                measure("100%, grade cached tiles, blurs from 2560", log: log) {
                    try time(GradeGraph.apply(recipe, to: tiled, inputs: guided), rect: center)
                }
                // How far the guided blurs land from the full-resolution ones, in sRGB 8-bit steps.
                let probe = CGRect(x: center.midX - 128, y: center.midY - 128, width: 256, height: 256)
                let difference = GradeGraph.apply(recipe, to: tiled, inputs: guided)
                    .applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: GradeGraph.apply(recipe, to: tiled, inputs: inputs)])
                    .cropped(to: probe)
                var bitmap = [UInt8](repeating: 0, count: 256 * 256 * 4)
                RenderContext.shared.render(difference, toBitmap: &bitmap, rowBytes: 256 * 4, bounds: probe, format: .RGBA8,
                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                let channels = bitmap.enumerated().filter { $0.offset % 4 != 3 }.map { Int($0.element) }
                log(String(format: "guided blur difference: mean %.2f, max %d (of 255)",
                           Double(channels.reduce(0, +)) / Double(channels.count), channels.max() ?? 0))
            }
            measure("histogram from graded 2560 (today)", log: log) {
                let start = ContinuousClock.now
                _ = Histogram.compute(GradeGraph.apply(recipe, to: base.image, inputs: inputs))
                let d = start.duration(to: .now)
                return Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000
            }
            let tiny = try await decoder.decode(source, rawStage: RawStageParams(), longEdge: 256)
            measure("histogram from 256 proxy", log: log) {
                let start = ContinuousClock.now
                _ = Histogram.compute(GradeGraph.apply(recipe, to: tiny.image, inputs: inputs))
                let d = start.duration(to: .now)
                return Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000
            }
        } catch {
            log("failed: \(error)")
        }
        log("done")
    }
}
