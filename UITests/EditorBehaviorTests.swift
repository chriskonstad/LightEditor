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
