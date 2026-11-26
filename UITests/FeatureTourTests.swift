import XCTest

/// A scripted walk through recent features, for screenshots and a screen recording
/// to look at after a change: canvas background and vignette, the color wheels,
/// the mask overlay hiding while adjusting, and the Finish tab's border and
/// watermark. It checks the features respond, not pixel output (that's
/// `RenderGoldenTests`). Run with `scripts/ui-tour.sh` (`just ui-tour`), which also
/// records a video; `scripts/test-ui.sh` skips it.
@MainActor
final class FeatureTourTests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0

    nonisolated private var output: URL {
        UITestConfig.outputFolder.appending(path: "tour")
    }

    override func setUp() {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    func testFeatureTour() throws {
        let library = FileManager.default.temporaryDirectory.appending(path: "tour-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: UITestConfig.libraryPath), to: library)
        app = XCUIApplication()
        app.launchArguments = [
            "-FixtureLibrary", library.path,
            "-ResetState", "YES",
            "-ApplePersistenceIgnoreState", "YES",
            // Not -canvasBackground: a launch argument would override the menu's choice.
        ]
        app.launch()
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for title in ["Don’t Allow", "Don't Allow", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }

        let photo = element("library.photo.0")
        XCTAssertTrue(photo.waitForExistence(timeout: 30), "the fixture library didn't load")
        photo.tap()
        XCTAssertTrue(waitUntilEnabled("editor.export", timeout: 120), "the editor never finished decoding")
        pause(1)

        // 1. Vignette stays inside the photo, on each canvas background.
        tab("Grade")
        let vignette = element("slider.effects.vignette.amount")
        if reveal(vignette, label: "Vignette") {
            drag(vignette, from: 0.5, to: 0.98)
            shot("vignette-plus-dark-background")
            for background in ["White", "Mid gray (18%)", "Black"] {
                if chooseBackground(background) { shot("vignette-plus-\(background.prefix(8).lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-"))-background") }
            }
            drag(vignette, from: 0.98, to: 0.02)
            shot("vignette-minus-black-background")
            _ = chooseBackground("Dark")
        } else {
            XCTFail("couldn't find the vignette slider")
        }

        // 2. Color wheels: overview, then one wheel open with exact sliders.
        tab("Grade")
        _ = reveal(element("wheel.open.shadows"), label: "COLOR GRADING")
        shot("wheels-overview")
        let shadows = element("wheel.open.shadows")
        if shadows.waitForExistence(timeout: 3) {
            shadows.tap()
            pause(0.8)
            shot("wheel-open-shadows")
            let wheel = element("wheel.shadows")
            if wheel.exists {
                let center = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: -wheel.frame.width * 0.25, dy: wheel.frame.height * 0.15)))
                pause(0.6)
            }
            let hue = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'slider.grade.shadows'")).firstMatch
            if hue.exists { drag(hue, from: 0.5, to: 0.6) }
            shot("wheel-open-shadows-adjusted")
            _ = tapIfPresent("wheel.overview")
            pause(0.6)
            shot("wheels-overview-after")
        } else {
            XCTFail("couldn't open the shadows wheel")
        }

        // 3. Masks: the red overlay shows while making the mask, hides on adjusting.
        tab("Masks")
        if tapIfPresent("mask.create.Radial gradient") {
            pause(1)
            shot("mask-radial-overlay-shown")
            let exposure = element("mask.slider.light.exposure")
            if reveal(exposure, label: "Exposure") {
                drag(exposure, from: 0.5, to: 0.8)
                pause(0.8)
                shot("mask-adjusted-overlay-hidden")
            } else {
                XCTFail("couldn't find the mask's exposure slider")
            }
            if tapIfPresent("mask.overlay") {
                pause(0.6)
                shot("mask-overlay-toggled-back-on")
            }
        } else {
            XCTFail("couldn't create a radial mask")
        }

        // 4. Finish: border, extra bottom, canvas and watermark.
        tab("Finish")
        let width = element("slider.finish.border.width")
        if width.waitForExistence(timeout: 3) {
            drag(width, from: 0.0, to: 0.35)
            let bottom = element("slider.finish.border.bottom")
            if bottom.exists { drag(bottom, from: 0.0, to: 0.4) }
            shot("border-white-polaroid")
            // The custom color swatch opens the system color picker.
            if tapIfPresent("border.custom") {
                pause(1)
                shot("border-custom-color-picker")
                app.swipeDown(velocity: .fast)
                pause(0.8)
            }
            if reveal(element("toggle.watermark"), label: "Watermark") {
                element("toggle.watermark").tap()
                pause(0.8)
                shot("border-with-watermark")
            }
            if reveal(element("canvas.4x5"), label: "Canvas") {
                element("canvas.4x5").tap()
                _ = reveal(element("border.black"), label: "Color") && tapIfPresent("border.black")
                pause(0.8)
                shot("canvas-4x5-black-border")
            }
        } else {
            XCTFail("couldn't find the Finish tab's border width slider")
        }
    }

    // MARK: Helpers

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func shot(_ name: String) {
        pause(0.8)
        step += 1
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let file = output.appending(path: String(format: "%02d-%@.png", step, name))
        try? screenshot.pngRepresentation.write(to: file)
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func tab(_ title: String) {
        let segment = app.segmentedControls.buttons[title].firstMatch
        if segment.waitForExistence(timeout: 3) {
            segment.tap()
        } else {
            XCTFail("no \(title) tab")
        }
        pause(0.8)
    }

    @discardableResult
    private func tapIfPresent(_ id: String, timeout: TimeInterval = 3) -> Bool {
        let target = element(id)
        guard target.waitForExistence(timeout: timeout), target.isHittable else { return false }
        target.tap()
        return true
    }

    private func waitUntilEnabled(_ id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element(id).exists, element(id).isEnabled { return true }
            pause(0.5)
        }
        return false
    }

    /// Drags along a slider from one fraction of its width to another.
    private func drag(_ slider: XCUIElement, from: CGFloat, to: CGFloat) {
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        pause(0.5)
    }

    /// Brings `target` on screen by tapping its text label, which XCUITest scrolls into
    /// view first. Dragging the panel to scroll it can grab a control instead (a drag
    /// that starts on the tone curve moves a curve point).
    private func reveal(_ target: XCUIElement, label: String) -> Bool {
        _ = target.waitForExistence(timeout: 2)
        if target.exists, target.isHittable { return true }
        let text = app.staticTexts[label].firstMatch
        if text.exists {
            text.tap()
            pause(0.6)
        }
        return target.exists && target.isHittable
    }

    /// Picks a canvas background from the editor's More menu (iPhone) or view bar.
    private func chooseBackground(_ name: String) -> Bool {
        let opened = tapIfPresent("editor.more", timeout: 2) || tapIfPresent("canvasBackground", timeout: 2)
        guard opened else { return false }
        pause(0.6)
        let submenu = app.buttons["Background"].firstMatch
        if submenu.waitForExistence(timeout: 2) { submenu.tap(); pause(0.5) }
        let option = app.buttons[name].firstMatch
        guard option.waitForExistence(timeout: 2) else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.12)).tap()
            return false
        }
        option.tap()
        pause(0.8)
        return true
    }
}
