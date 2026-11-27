import XCTest

/// Behavior checks that need the real app: things a unit test can't see, such as
/// text entry. Run by scripts/test-ui.sh on every device it tests.
@MainActor
final class EditorBehaviorTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    /// Every typed character lands in the watermark field and survives Return, which
    /// commits it as one undo step.
    func testTypingAWatermarkKeepsEveryCharacter() throws {
        let library = FileManager.default.temporaryDirectory.appending(path: "tour-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: UITestConfig.libraryPath), to: library)
        app = XCUIApplication()
        app.launchArguments = [
            "-FixtureLibrary", library.path, "-ResetState", "YES", "-ApplePersistenceIgnoreState", "YES",
            "-OpenAssetIndex", "0", "-EditorTab", "finish",
        ]
        app.launch()
        XCTAssertTrue(waitUntilEnabled("editor.export", timeout: 120) || waitUntilEnabled("toolbar.export", timeout: 5), "the editor never finished decoding")
        XCTAssertTrue(reveal(element("toggle.watermark"), label: "Watermark"))
        element("toggle.watermark").tap()
        let field = element("watermark.text")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard")
        field.typeText("Hello watermark")
        pause(1)
        XCTAssertEqual(field.value as? String, "Hello watermark")
        // Return commits it as one undo step; the text must survive that too.
        field.typeText("\n")
        pause(1)
        XCTAssertEqual(field.value as? String, "Hello watermark", "the watermark changed when committed")
    }

    /// The same in landscape on iPad, where the editor's controls are a side inspector.
    func testTypingAWatermarkInLandscape() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPhone is portrait-only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        try testTypingAWatermarkKeepsEveryCharacter()
    }

    /// The border last used is offered as "Last used border" wherever there's none,
    /// e.g. after resetting it or on the next photo, and one tap brings it back.
    func testLastUsedBorderComesBack() throws {
        let library = FileManager.default.temporaryDirectory.appending(path: "tour-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: UITestConfig.libraryPath), to: library)
        app = XCUIApplication()
        app.launchArguments = [
            "-FixtureLibrary", library.path, "-ResetState", "YES", "-ApplePersistenceIgnoreState", "YES",
            "-OpenAssetIndex", "0", "-EditorTab", "finish", "-SetParams", "finish.border.width=6,finish.border.bottom=10",
        ]
        app.launch()
        XCTAssertTrue(waitUntilEnabled("editor.export", timeout: 120) || waitUntilEnabled("toolbar.export", timeout: 5), "the editor never finished decoding")
        let width = element("slider.finish.border.width")
        let deadline = Date().addingTimeInterval(20)
        while width.value as? String != "+6", Date() < deadline { pause(0.5) }
        XCTAssertEqual(width.value as? String, "+6", "the launch arguments didn't set the border")
        let button = element("lastUsed.border")
        XCTAssertFalse(button.exists, "offered the border this photo already has")

        let reset = element("reset.finishing")
        XCTAssertTrue(reset.waitForExistence(timeout: 3), "no Reset for the border")
        reset.tap()
        if app.buttons["Reset to defaults"].waitForExistence(timeout: 1) { app.buttons["Reset to defaults"].tap() }
        pause(1)
        XCTAssertEqual(width.value as? String, "0")
        XCTAssertTrue(button.waitForExistence(timeout: 3), "no Last used border button after resetting it")
        button.tap()
        pause(1)
        XCTAssertEqual(width.value as? String, "+6")
        XCTAssertEqual(element("slider.finish.border.bottom").value as? String, "+10")
        XCTAssertFalse(button.exists, "still offered after applying it")
    }

    // MARK: Helpers

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func waitUntilEnabled(_ id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element(id).exists, element(id).isEnabled { return true }
            pause(0.5)
        }
        return false
    }

    /// Brings `target` on screen by tapping its text label, which XCUITest scrolls
    /// into view first.
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
}
