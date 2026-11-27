import XCTest

/// What happens to an edit when the app is interrupted: sent to the background,
/// killed, warned about memory, or turned. Nothing the user did should be lost,
/// and the editor should carry on. Run by scripts/test-ui.sh and the checker run.
@MainActor
final class InterruptionTests: XCTestCase {
    private var app: XCUIApplication!
    private var library: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        library = FileManager.default.temporaryDirectory.appending(path: "interrupt-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: UITestConfig.libraryPath), to: library)
    }

    private func launch(reset: Bool) {
        app = UITestConfig.makeApp()
        app.launchArguments = ["-FixtureLibrary", library.path, "-ApplePersistenceIgnoreState", "YES",
                               "-OpenAsset", "DSC04921.ARW", "-EditorTab", "light"]
            + (reset ? ["-ResetState", "YES"] : [])
        app.launch()
        XCTAssertTrue(waitUntilEnabled(timeout: 120), "the editor never finished decoding")
    }

    private var exposure: XCUIElement { element("slider.light.exposure") }

    /// Drags exposure up and returns the value it shows.
    private func raiseExposure() -> String? {
        XCTAssertTrue(exposure.waitForExistence(timeout: 5), "no exposure slider")
        let start = exposure.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: exposure.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
        pause(1)
        let value = exposure.value as? String
        XCTAssertNotEqual(value, "0.00", "the drag didn't change exposure")
        return value
    }

    /// Background and back: the edit and the open photo are still there, and the
    /// editor still responds.
    func testBackgroundingKeepsTheEdit() throws {
        launch(reset: true)
        let value = raiseExposure()
        XCUIDevice.shared.press(.home)
        pause(2)
        app.activate()
        XCTAssertTrue(exposure.waitForExistence(timeout: 10), "the editor didn't come back")
        XCTAssertEqual(exposure.value as? String, value)
        XCTAssertTrue(waitUntilEnabled(timeout: 20), "the editor didn't recover after coming back")
        _ = raiseExposure()
    }

    /// Killed right after an edit (the system does this to background apps): the
    /// edit is back when the photo opens again.
    func testAnEditSurvivesTheAppBeingKilled() throws {
        launch(reset: true)
        let value = raiseExposure()
        // Drafts are written in the background within a moment of each change.
        pause(2)
        app.terminate()
        launch(reset: false)
        XCTAssertTrue(exposure.waitForExistence(timeout: 10))
        XCTAssertEqual(exposure.value as? String, value, "the edit was lost when the app was killed")
    }

    /// A memory warning frees caches, not edits: the photo still shows, the edit
    /// stays, and the next change still renders.
    func testAMemoryWarningKeepsTheEdit() throws {
        launch(reset: true)
        let value = raiseExposure()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("com.chriskonstad.lighteditor.debug.memoryWarning" as CFString), nil, nil, true)
        pause(2)
        XCTAssertEqual(exposure.value as? String, value)
        XCTAssertTrue(waitUntilEnabled(timeout: 30), "the editor didn't recover from the memory warning")
        XCTAssertNotEqual(raiseExposure(), value, "the editor stopped responding after the memory warning")
    }

    /// Turning the iPad mid-edit keeps the edit; the layout switches to the side inspector.
    func testRotatingKeepsTheEdit() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPhone is portrait-only") }
        launch(reset: true)
        let value = raiseExposure()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        pause(2)
        XCTAssertTrue(exposure.waitForExistence(timeout: 10))
        XCTAssertEqual(exposure.value as? String, value)
        XCUIDevice.shared.orientation = .portrait
        pause(2)
        XCTAssertEqual(exposure.value as? String, value)
    }

    // MARK: Helpers

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func waitUntilEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for id in ["editor.export", "toolbar.export"] where element(id).exists && element(id).isEnabled { return true }
            pause(0.5)
        }
        return false
    }
}
