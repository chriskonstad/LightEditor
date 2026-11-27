import CoreImage
import Foundation
import Testing
@testable import EditorCore

/// Coarse performance regression guards for local runs on a Mac.
///
/// These are not device numbers (CLAUDE.md: only real devices count, and
/// `PerformanceTests` holds the XCTest baselines for those). Each budget is several
/// times what an M4 Pro measures (with room for an M1 and a busy machine), so they only fail on a real regression, such as an
/// accidental re-decode, a CPU fallback, or a slow graph build on the slider path,
/// and stay quiet when other work is running on the machine. They take a few
/// seconds, so they run only with EDITORCORE_PERF_BUDGETS=1 (`scripts/test-all.sh`).
///
/// Each prints a `BUDGET` line with the median of several runs.
///
/// On top of the coarse budgets, each measurement is compared with this Mac
/// model's baseline in Tests/perf-baselines.json, when there is one: more than 1.5×
/// the baseline (plus 2 ms, for the quick ones) fails, which catches regressions far
/// smaller than the budgets allow. `EDITORCORE_PERF_RECORD=1` records this Mac's
/// numbers (`just record-perf`); record on a quiet machine, and only after a change
/// that's meant to move them.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["EDITORCORE_PERF_BUDGETS"] == "1"))
struct PerformanceBudgetTests {
    /// The median wall time of `runs` calls after one warm-up call.
    static func median(runs: Int = 7, _ body: () throws -> Void) rethrows -> Duration {
        try body()
        var times = [Duration]()
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try body()
            times.append(ContinuousClock.now - start)
        }
        return times.sorted()[runs / 2]
    }

    static func median(runs: Int = 3, _ body: () async throws -> Void) async rethrows -> Duration {
        var times = [Duration]()
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try await body()
            times.append(ContinuousClock.now - start)
        }
        return times.sorted()[runs / 2]
    }

    static func check(_ name: String, _ time: Duration, budget: Duration) {
        let milliseconds = { (d: Duration) in Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
        let ms = { (d: Duration) in String(format: "%.2f ms", milliseconds(d)) }
        let measured = milliseconds(time)
        if ProcessInfo.processInfo.environment["EDITORCORE_PERF_RECORD"] == "1" {
            Baselines.record(name, measured)
            print("BUDGET \(name): \(ms(time)) (budget \(ms(budget)); recorded as the \(Baselines.model) baseline)")
            return
        }
        let baseline = Baselines.value(name)
        let limit = baseline.map { $0 * 1.5 + 2 }
        print("BUDGET \(name): \(ms(time)) (budget \(ms(budget))" + (baseline.map { String(format: "; %@ baseline %.2f ms", Baselines.model, $0) } ?? "") + ")")
        #expect(time <= budget, "\(name) took \(ms(time)), over its budget of \(ms(budget))")
        if let baseline, let limit {
            #expect(measured <= limit, "\(name) took \(ms(time)), more than 1.5× this Mac's baseline of \(String(format: "%.2f", baseline)) ms")
        }
    }

    /// Per-model baselines in Tests/perf-baselines.json: `{ "Mac16,7": { "name": ms } }`.
    enum Baselines {
        static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "perf-baselines.json")

        /// The hardware model, e.g. "Mac16,7" or "MacBookPro17,1".
        static let model: String = {
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var bytes = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname("hw.model", &bytes, &size, nil, 0)
            return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }()

        static func all() -> [String: [String: Double]] {
            guard let data = try? Data(contentsOf: file) else { return [:] }
            return (try? JSONDecoder().decode([String: [String: Double]].self, from: data)) ?? [:]
        }

        static func value(_ name: String) -> Double? { all()[model]?[name] }

        static func record(_ name: String, _ milliseconds: Double) {
            var all = all()
            all[model, default: [:]][name] = (milliseconds * 100).rounded() / 100
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(all).write(to: file, options: .atomic)
        }
    }

    static var heavyRecipe: Recipe {
        var recipe = Recipe()
        for testCase in RenderGoldenTests.cases where testCase.name == "everything" { testCase.edit(&recipe) }
        recipe.setMask(MaskLayer(
            name: "Radial", order: 1,
            components: [MaskComponent(shape: .radial(center: NormalizedPoint(x: 0.4, y: 0.5), radiusX: 0.3, radiusY: 0.3, angle: 0, feather: 0.5))],
            adjustments: [.exposure: 0.5, .saturation: 20]
        ), at: testClock.now())
        return recipe
    }

    static let previewSize = CGSize(width: 2560, height: 1707)
    static var previewBase: CIImage {
        RenderGoldenTests.chart.transformed(by: CGAffineTransform(scaleX: previewSize.width / RenderGoldenTests.chartSize.width,
                                                                  y: previewSize.height / RenderGoldenTests.chartSize.height))
    }

    /// Building the graph runs on the main thread for every slider move.
    @Test func gradeGraphBuild() {
        let recipe = Self.heavyRecipe, base = Self.previewBase
        let inputs = GradeInputs(defaults: RenderGoldenTests.warmDefaults)
        let time = Self.median(runs: 21) { _ = GradeGraph.apply(recipe, to: base, inputs: inputs) }
        Self.check("grade graph build", time, budget: .milliseconds(5))
    }

    /// One preview-size frame with a heavy recipe and a mask, rendered on the GPU.
    @Test func previewFrame() throws {
        Kernels.warmUp()
        let recipe = Self.heavyRecipe, base = Self.previewBase
        let inputs = GradeInputs(defaults: RenderGoldenTests.warmDefaults)
        let buffer = try #require(PixelBuffers.make(width: Int(Self.previewSize.width), height: Int(Self.previewSize.height)))
        let destination = CIRenderDestination(pixelBuffer: buffer)
        let time = try Self.median {
            let image = GradeGraph.apply(recipe, to: base, inputs: inputs)
            _ = try RenderContext.shared.startTask(toRender: image, to: destination).waitUntilCompleted()
        }
        Self.check("preview frame 2560 px", time, budget: .milliseconds(60))
    }

    /// A preview frame with depth, luminance and color range masks, the kind of
    /// recipe that tap-to-pick produces.
    @Test func rangeMaskedFrame() throws {
        Kernels.warmUp()
        var recipe = Self.heavyRecipe
        recipe.setMask(MaskLayer(name: "Ranges", order: 2, components: [
            MaskComponent(shape: .depth(near: 0.2, far: 0.6, feather: 0.1)),
            MaskComponent(operation: .intersect, shape: .luminance(low: 0.3, high: 0.9, feather: 0.1)),
            MaskComponent(operation: .add, shape: .color(l: 0.6, a: -0.03, b: -0.1, range: 0.4)),
        ], adjustments: [.exposure: 0.4, .clarity: 20]), at: testClock.now())
        var inputs = GradeInputs(defaults: RenderGoldenTests.warmDefaults)
        inputs.aiMasks = PreviewDepth(size: Self.previewSize)
        let buffer = try #require(PixelBuffers.make(width: Int(Self.previewSize.width), height: Int(Self.previewSize.height)))
        let destination = CIRenderDestination(pixelBuffer: buffer)
        let base = Self.previewBase
        let time = try Self.median {
            _ = try RenderContext.shared.startTask(toRender: GradeGraph.apply(recipe, to: base, inputs: inputs), to: destination).waitUntilCompleted()
        }
        Self.check("range-masked frame 2560 px", time, budget: .milliseconds(80))
    }

    /// A depth map the size of the preview, for the masked frame above.
    struct PreviewDepth: AIMaskProvider {
        let size: CGSize
        func mask(for shape: MaskShape) -> CIImage? {
            CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: size.width, y: size.height),
                "inputColor0": CIColor.black, "inputColor1": CIColor.white,
            ])!.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
        }
    }

    /// The Finish tab's preview: four-corner perspective, a border, and a turned
    /// text watermark (set at twice the size, rotated, then scaled with Lanczos).
    @Test func finishedFrame() throws {
        Kernels.warmUp()
        var recipe = Self.heavyRecipe
        recipe.set(.perspectiveCorners, .quad(PerspectiveQuad(
            topLeft: NormalizedPoint(x: 0.1, y: 0.05), topRight: NormalizedPoint(x: 0.88, y: 0.1),
            bottomRight: NormalizedPoint(x: 0.95, y: 0.95), bottomLeft: NormalizedPoint(x: 0.04, y: 0.9))), at: testClock.now())
        recipe.setScalar(.borderWidth, 5, at: testClock.now())
        recipe.setScalar(.borderBottom, 10, at: testClock.now())
        recipe.set(.watermark, .watermark(Watermark(text: "© Performance", center: NormalizedPoint(x: 0.5, y: 0.7), rotation: -15)), at: testClock.now())
        recipe.setScalar(.watermarkSize, 8, at: testClock.now())
        let inputs = GradeInputs(defaults: RenderGoldenTests.warmDefaults)
        let base = Self.previewBase
        let size = GradeGraph.apply(recipe, to: base, inputs: inputs).extent.size
        let buffer = try #require(PixelBuffers.make(width: Int(size.width), height: Int(size.height)))
        let destination = CIRenderDestination(pixelBuffer: buffer)
        let time = try Self.median {
            _ = try RenderContext.shared.startTask(toRender: GradeGraph.apply(recipe, to: base, inputs: inputs), to: destination).waitUntilCompleted()
        }
        Self.check("finished frame 2560 px (corners, border, turned watermark)", time, budget: .milliseconds(80))
    }

    /// Measuring a photo's depth once, for depth range masks (Neural Engine on a Mac).
    @Test(.enabled(if: DepthModelTests.modelURL != nil)) func depthMap() throws {
        DepthEstimator.shared.configure(modelURL: DepthModelTests.modelURL)
        let image = DepthModelTests.scene(width: 1536, height: 1024)
        let time = try Self.median(runs: 5) { _ = try DepthEstimator.shared.distanceMap(for: image) }
        Self.check("depth map 1536 px", time, budget: .seconds(2))
    }

    /// Recipes are encoded on every commit and decoded for every thumbnail.
    @Test func recipeCodec() throws {
        let recipe = RecipeCompatibilityTests.kitchenSink
        let time = try Self.median(runs: 21) {
            for _ in 0..<10 { _ = try RecipeCodec.decode(RecipeCodec.encode(recipe)) }
        }
        Self.check("recipe encode+decode ×10", time, budget: .milliseconds(20))
    }

    static var rawFixture: URL? {
        RawGoldenTests.rawFiles.first { $0.pathExtension.lowercased() == "arw" }
    }

    /// Opening a photo: a cold 2560 px decode of an A7R V file (61 MP).
    @Test(.enabled(if: rawFixture != nil)) func rawPreviewDecode() async throws {
        let url = try #require(Self.rawFixture)
        let time = try await Self.median {
            let decoder = RawDecoder(cache: DecodeCache(directory: nil))
            _ = try await decoder.decode(PhotoSource(url: url), rawStage: RawStageParams(), longEdge: 2560)
        }
        Self.check("RAW preview decode (cold)", time, budget: .seconds(15))
    }

    /// A full-resolution HEIC export from a cold decoder.
    @Test(.enabled(if: rawFixture != nil)) func fullSizeExport() async throws {
        let url = try #require(Self.rawFixture)
        let recipe = Self.heavyRecipe
        let time = try await Self.median(runs: 1) {
            let decoder = RawDecoder(cache: DecodeCache(directory: nil))
            _ = try await Exporter.render(source: PhotoSource(url: url), recipe: recipe, luts: nil, options: ExportOptions(format: .heic), decoder: decoder)
        }
        Self.check("full-size HEIC export (cold)", time, budget: .seconds(40))
    }
}
