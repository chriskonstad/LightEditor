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
        let ms = { (d: Duration) in String(format: "%.2f ms", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
        print("BUDGET \(name): \(ms(time)) (budget \(ms(budget)))")
        #expect(time <= budget, "\(name) took \(ms(time)), over its budget of \(ms(budget))")
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
