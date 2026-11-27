import XCTest

/// Mac app performance, measured with XCTest metrics on this Mac:
/// - launch to the library,
/// - opening a RAW until the editor is ready,
/// - display frames while dragging a slider (the app's `DisplayFrame` signpost).
///
/// scripts/test-mac-ui.sh reads the results from the result bundle and compares
/// them with MacUITests/perf-baselines.json for this Mac model (`--record-perf`
/// writes it), failing on a clear regression. Numbers only mean something on the
/// same hardware, so each model has its own baseline.
@MainActor
final class MacPerformanceTests: XCTestCase {
    private var library: URL!

    override func setUp() async throws {
        library = try MacUITest.makeLibrary()
    }

    override func tearDown() async throws {
    }

    private var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        return options
    }

    func testLaunch() throws {
        let app = MacUITest.makeApp(library: library)
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            app.launch()
            app.terminate()
        }
    }

    /// From launch to the editor being ready on a 61 MP ARW.
    func testOpenARawPhoto() throws {
        let app = MacUITest.makeApp(library: library, ["-OpenAsset", "DSC04921.ARW", "-EditorTab", "light"])
        measure(metrics: [XCTClockMetric()], options: options) {
            app.launch()
            XCTAssertTrue(app.waitForEditor(), "the photo never opened")
            app.terminate()
        }
    }

    /// Frames drawn while dragging exposure back and forth: how long each takes to
    /// grade and display, from the app's own signposts.
    func testSliderDragFrames() throws {
        let app = MacUITest.makeApp(library: library, ["-OpenAsset", "DSC04921.ARW", "-EditorTab", "light"])
        app.launch()
        XCTAssertTrue(app.waitForEditor(), "the photo never opened")
        let exposure = app.element("slider.light.exposure")
        XCTAssertTrue(exposure.waitForExistence(timeout: 5))
        let frames = XCTOSSignpostMetric(subsystem: "com.chriskonstad.lighteditor", category: "Display", name: "DisplayFrame")
        measure(metrics: [frames, XCTClockMetric()], options: options) {
            app.drag(exposure, from: 0.3, to: 0.8)
            app.drag(exposure, from: 0.8, to: 0.3)
        }
        app.terminate()
    }
}
