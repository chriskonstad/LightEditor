import XCTest

/// Setup shared by the Mac UI tests: a sample library the sandboxed Debug app may
/// read (it allows /private/tmp/LightEditorUITests/ for this, and nothing else
/// outside its container), the checkers when scripts/test-mac-ui.sh asks for them,
/// and a few helpers.
enum MacUITest {
    static let environment = ProcessInfo.processInfo.environment
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// The sample library: two fixtures (no people in them) that scripts/test-mac-ui.sh
    /// puts here. The sandboxed test runner can't write anywhere the app can read, so
    /// each test names a copy and the Debug app makes it (`-FixtureLibraryCopy`).
    static let template = URL(fileURLWithPath: "/private/tmp/LightEditorUITests/template")

    /// A new name for a test's own copy of the library.
    /// (The runner's sandbox can't even look at the template, so a missing one shows
    /// up as the editor never opening.)
    static func makeLibrary() throws -> URL {
        URL(fileURLWithPath: UUID().uuidString)
    }

    /// The app, with the Main Thread Checker and the Thread Performance Checker
    /// loaded when MAC_UITEST_CHECKERS=1 (their reports go to the system log, which
    /// the script reads).
    @MainActor static func makeApp(library: URL, _ arguments: [String] = [], reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FixtureLibrary", template.path, "-FixtureLibraryCopy", library.lastPathComponent,
                               "-ApplePersistenceIgnoreState", "YES", "-HideSidebar", "YES"]
            + (reset ? ["-ResetState", "YES"] : []) + arguments
        if environment["MAC_UITEST_CHECKERS"] == "1" {
            let developer = environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
            app.launchEnvironment["DYLD_INSERT_LIBRARIES"] = "\(developer)/usr/lib/libMainThreadChecker.dylib:/usr/lib/libRPAC.dylib"
            app.launchEnvironment["MTC_LOG_REPORTS_TO_OS_LOG"] = "1"
            app.launchEnvironment["MTC_SUPPRESS_SYSTEM_REPORTS"] = "1"
            app.launchEnvironment["PERFC_SUPPRESS_SYSTEM_REPORTS"] = "1"
        }
        return app
    }
}

extension XCUIApplication {
    func element(_ id: String) -> XCUIElement {
        descendants(matching: .any)[id].firstMatch
    }

    /// Waits for the editor's Export button to be enabled: the photo has decoded.
    func waitForEditor(timeout: TimeInterval = 120) -> Bool {
        let export = element("toolbar.export")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if export.exists, export.isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// A slider's shown value ("+0.50"), from its value label: on macOS the slider's
    /// own accessibility value doesn't reach UI tests.
    func sliderValue(_ key: String) -> String? {
        let label = element("value.\(key)")
        guard label.exists else { return nil }
        return (label.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label.label
    }

    /// Drags a slider by a fraction of its width with the mouse.
    func drag(_ slider: XCUIElement, from: CGFloat = 0.5, to: CGFloat) {
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
        start.click(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5)))
        Thread.sleep(forTimeInterval: 0.6)
    }
}

/// A screenshot of the app's window, kept as an attachment. The test runner's sandbox
/// can't write files to the repo, so scripts/test-mac-ui.sh exports attachments from
/// the result bundle into build/mac-ui/.
@MainActor func saveScreenshot(_ app: XCUIApplication, _ name: String, test: XCTestCase) {
    let shot = app.windows.firstMatch.exists ? app.windows.firstMatch.screenshot() : app.screenshot()
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    test.add(attachment)
}

/// Text kept as an attachment, e.g. the audit report (see `saveScreenshot`).
@MainActor func attach(_ text: String, named name: String, test: XCTestCase) {
    let attachment = XCTAttachment(string: text)
    attachment.name = name
    attachment.lifetime = .keepAlways
    test.add(attachment)
}
