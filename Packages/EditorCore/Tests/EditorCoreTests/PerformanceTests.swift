import CoreImage
import XCTest
@testable import EditorCore

/// Decode, grade and export timings.
///
/// Numbers only count from real devices (see CLAUDE.md). Baselines live in the
/// Xcode scheme once recorded on each device; a run that regresses past the
/// baseline's allowed deviation fails. Set EDITORCORE_RAW_FIXTURES to a folder with
/// an A7R V .ARW to include the RAW decode test.
final class PerformanceTests: XCTestCase {
    private var rawFixture: URL? {
        guard let path = ProcessInfo.processInfo.environment["EDITORCORE_RAW_FIXTURES"] else { return nil }
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)) ?? []
        return urls.first { $0.pathExtension.lowercased() == "arw" }
    }

    /// A busy recipe touching every custom kernel and most built-ins.
    private var heavyRecipe: Recipe {
        var recipe = Recipe()
        let clock = HybridLogicalClock(node: "perf")
        recipe.setScalar(.exposure, 0.4, at: clock.now())
        recipe.setScalar(.contrast, 20, at: clock.now())
        recipe.setScalar(.shadows, 30, at: clock.now())
        recipe.setScalar(.highlights, -40, at: clock.now())
        recipe.setScalar(.temperature, 6000, at: clock.now())
        recipe.setScalar(.vibrance, 20, at: clock.now())
        recipe.setScalar(.hsl(.blue, .saturation), -30, at: clock.now())
        recipe.setScalar(.hsl(.orange, .luminance), 15, at: clock.now())
        recipe.set(.gradeWheel(.shadows), .point(x: -0.3, y: -0.2), at: clock.now())
        recipe.set(.gradeWheel(.highlights), .point(x: 0.3, y: 0.2), at: clock.now())
        recipe.set(.toneCurve, .curve([CurvePoint(x: 0, y: 0.05), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 1)]), at: clock.now())
        recipe.setScalar(.vignetteAmount, -20, at: clock.now())
        return recipe
    }

    /// One preview-size grade, 2560 × 1707, rendered to a half-float buffer.
    func testGradePreviewFrame() throws {
        Kernels.warmUp()
        let base = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 2560, height: 1707))
        let inputs = GradeInputs(defaults: PhotoDefaults(values: [.temperature: 5500, .tint: 0]))
        let recipe = heavyRecipe
        let buffer = try XCTUnwrap(PixelBuffers.make(width: 2560, height: 1707))
        let destination = CIRenderDestination(pixelBuffer: buffer)
        measure(metrics: [XCTClockMetric()]) {
            let image = GradeGraph.apply(recipe, to: base, inputs: inputs)
            _ = try? RenderContext.shared.startTask(toRender: image, to: destination).waitUntilCompleted()
        }
    }

    func testRawDecodePreview() async throws {
        guard let url = rawFixture else { throw XCTSkip("Set EDITORCORE_RAW_FIXTURES to a folder with an .ARW") }
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let done = expectation(description: "decode")
            Task {
                let decoder = RawDecoder(cache: DecodeCache(directory: nil))
                _ = try await decoder.decode(PhotoSource(url: url), rawStage: RawStageParams(), longEdge: 2560)
                done.fulfill()
            }
            wait(for: [done], timeout: 60)
        }
    }

    func testFullResolutionExport() async throws {
        guard let url = rawFixture else { throw XCTSkip("Set EDITORCORE_RAW_FIXTURES to a folder with an .ARW") }
        let recipe = heavyRecipe
        let options = XCTMeasureOptions()
        options.iterationCount = 2
        measure(metrics: [XCTClockMetric()], options: options) {
            let done = expectation(description: "export")
            Task {
                _ = try await Exporter.render(source: PhotoSource(url: url), recipe: recipe, luts: nil, options: ExportOptions(format: .heic))
                done.fulfill()
            }
            wait(for: [done], timeout: 120)
        }
    }
}
