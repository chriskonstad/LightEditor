import XCTest

/// Walks the main screens and audits each one: clipped text, touch targets under
/// 44 pt, content laid out past the window's sides, and Apple's accessibility audit.
/// Every screen is saved as a PNG under build/ui-screenshots/<device>/ for a look
/// after a UI change. Run with scripts/test-ui.sh (see docs/TESTING.md).
///
/// The app is dark-only (`preferredColorScheme(.dark)`), so there's no light pass.
@MainActor
final class ScreenAuditTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testScreensAtDefaultTextSize() throws {
        try walkScreens(contentSize: .large)
    }

    func testScreensAtLargestAccessibilityTextSize() throws {
        try walkScreens(contentSize: .accessibilityExtraExtraExtraLarge)
    }

    /// The iPhone app is portrait-only; iPads also get a landscape pass.
    func testScreensInLandscape() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPhone is portrait-only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        try walkScreens(contentSize: .large, orientation: "landscape")
    }

    // MARK: The walk

    private var app: XCUIApplication!

    private func launch(contentSize: ContentSize) -> XCUIApplication {
        // A fresh copy of the library for each test, so edits from one walk (the walk
        // adds a mask) don't change the next one's screens. APFS clones it instantly.
        let library = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: UITestConfig.libraryPath), to: library)
        } catch {
            XCTFail("Couldn't copy the fixture library from \(UITestConfig.libraryPath): \(error). Run scripts/test-ui.sh, which prepares it.")
        }
        let app = UITestConfig.makeApp()
        app.launchArguments = [
            "-FixtureLibrary", library.path,
            "-UIPreferredContentSizeCategoryName", contentSize.rawValue,
            // No leftover state (drafts, clipboard, restored windows) from a previous run.
            "-ResetState", "YES",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    private func walkScreens(contentSize: ContentSize, orientation: String = "portrait") throws {
        app = launch(contentSize: contentSize)
        // Local network and other permission prompts.
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for title in ["Don’t Allow", "Don't Allow", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        let auditor = ScreenAuditor(app: app, contentSize: contentSize, orientation: orientation)
        defer { auditor.finish() }

        // Library
        let firstPhoto = app.descendants(matching: .any)["library.photo.0"]
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 30), "the fixture library didn't load (\(UITestConfig.libraryPath))")
        auditor.capture("library")

        if tap(["library.settings"]) {
            auditor.capture("settings")
            dismissSheet(["Done"])
        }
        if tap(["library.devices"]) {
            auditor.capture("devices")
            dismissSheet(["Done"])
        }

        // Editor
        firstPhoto.tap()
        XCTAssertTrue(waitUntilEnabled(["editor.export", "toolbar.export"], timeout: 120), "the editor never finished decoding")
        auditor.capture("editor")

        for tab in ["Presets", "Light", "Color", "Effects", "Detail", "Finish", "Masks"] {
            let segment = app.segmentedControls.buttons[tab].firstMatch
            guard segment.exists else { continue }
            segment.tap()
            auditor.capture("tab-\(tab.lowercased())")
            if tab == "Finish", tap(["toggle.watermark"]) {
                // The watermark's settings appear once it's on. Its text field takes
                // focus; type something and dismiss the keyboard before auditing.
                let field = app.descendants(matching: .any)["watermark.text"].firstMatch
                if field.waitForExistence(timeout: 2) {
                    field.tap()
                    // Typing before the keyboard has appeared drops keystrokes.
                    _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
                    field.typeText("Test watermark")
                    // In the iPad landscape inspector XCUITest sometimes loses keys while it
                    // scrolls the field into view; retype once. (Typing itself is checked
                    // in both orientations by EditorBehaviorTests.)
                    if field.value as? String != "Test watermark" {
                        field.doubleTap()
                        field.typeText(XCUIKeyboardKey.delete.rawValue + "Test watermark")
                    }
                    if field.value as? String != "Test watermark" {
                        print("UIAudit: the walk couldn't type the watermark (got \(field.value ?? "nil"))")
                    }
                    field.typeText("\n")
                    Thread.sleep(forTimeInterval: 0.8)
                }
                auditor.capture("tab-finish-watermark")
            }
            if scrollPanel() { auditor.capture("tab-\(tab.lowercased())-scrolled") }
            if tab == "Color" {
                // Color grading closes the Color tab, below the HSL mixer.
                let wheel = app.descendants(matching: .any)["wheel.open.shadows"].firstMatch
                for _ in 0..<4 where !(wheel.exists && wheel.isHittable) {
                    guard scrollPanel() else { break }
                }
                auditor.capture("tab-color-grading")
                if tap(["wheel.open.shadows"]) {
                    // One wheel open, with its Hue, Saturation and Luminance sliders.
                    Thread.sleep(forTimeInterval: 0.6)
                    auditor.capture("wheel-open")
                    _ = tap(["wheel.overview"])
                }
            }
        }

        // Still on Masks: make a radial mask, which shows its settings.
        if tap(["mask.create.Radial gradient", "Radial gradient"]) {
            auditor.capture("mask-radial")
            if scrollPanel() { auditor.capture("mask-radial-scrolled") }
            if tap(["mask.new"]) {
                auditor.capture("mask-new-menu", audit: false)
                dismissMenu()
            }
        }
        if tap(["editor.more"]) {
            auditor.capture("more-menu", audit: false)
            dismissMenu()
        }
        if tap(["editor.crop", "Crop"]) {
            auditor.capture("crop")
            XCTAssertTrue(tapScrollingTools("crop.done"), "couldn't reach the crop tool's Done button")
        }
        if tap(["editor.retouch", "view.retouch"]) {
            auditor.capture("retouch")
            XCTAssertTrue(tapScrollingTools("retouch.done"), "couldn't reach the retouch tool's Done button")
        }
        if tap(["editor.export", "toolbar.export"]) {
            auditor.capture("export")
            dismissSheet(["Close"])
        }
    }

    // MARK: Helpers

    /// Taps the first enabled, hittable element among `identifiers` (or labels).
    @discardableResult
    private func tap(_ identifiers: [String], timeout: TimeInterval = 3) -> Bool {
        for id in identifiers {
            let element = app.descendants(matching: .any)[id].firstMatch
            if element.waitForExistence(timeout: timeout), element.isEnabled, element.isHittable {
                element.tap()
                return true
            }
        }
        return false
    }

    /// Taps a button in a tool panel, scrolling the panel up to reach it if needed.
    private func tapScrollingTools(_ identifier: String) -> Bool {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        for attempt in 0..<4 {
            if element.exists, element.isHittable {
                element.tap()
                return true
            }
            if attempt == 0 { _ = element.waitForExistence(timeout: 2) }
            // Drag the lower part of the screen up, along the left padding.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.9)).withOffset(CGVector(dx: 4, dy: 0))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.6)).withOffset(CGVector(dx: 4, dy: 0))
            start.press(forDuration: 0.05, thenDragTo: end)
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func waitUntilEnabled(_ identifiers: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for id in identifiers {
                let element = app.descendants(matching: .any)[id].firstMatch
                if element.exists, element.isEnabled { return true }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func dismissSheet(_ buttons: [String]) {
        for title in buttons {
            let button = app.buttons[title].firstMatch
            if button.waitForExistence(timeout: 2), button.isHittable {
                button.tap()
                Thread.sleep(forTimeInterval: 0.5)
                return
            }
        }
        // A sheet without a button: swipe it away.
        app.swipeDown(velocity: .fast)
    }

    private func dismissMenu() {
        // A tap outside closes a menu; the top-left corner is clear of controls.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.12)).tap()
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// Scrolls the editor's control panel by about half a screen, dragging along its
    /// left padding so no slider is grabbed. Returns false when there's nothing to scroll.
    private func scrollPanel() -> Bool {
        let tabs = app.segmentedControls.firstMatch.frame
        let panel = app.scrollViews.allElementsBoundByIndex
            .filter { $0.frame.minY >= tabs.maxY - 1 && $0.frame.height > 150 }
            .min { $0.frame.minY < $1.frame.minY }
        guard let panel else { return false }
        let before = panel.descendants(matching: .any).firstMatch.frame
        let origin = panel.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: 4, dy: panel.frame.height * 0.85))
        let end = origin.withOffset(CGVector(dx: 4, dy: panel.frame.height * 0.2))
        start.press(forDuration: 0.05, thenDragTo: end)
        Thread.sleep(forTimeInterval: 0.6)
        return panel.descendants(matching: .any).firstMatch.frame != before
    }
}
