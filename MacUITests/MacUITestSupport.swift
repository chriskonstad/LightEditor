import XCTest

/// Setup shared by the Mac UI tests: a sample library the sandboxed Debug app may
/// read (it allows /private/tmp/LightEditorUITests/ for this, and nothing else
/// outside its container), the checkers when scripts/test-mac-ui.sh asks for them,
/// and a few helpers.
enum MacUITest {
    static let environment = ProcessInfo.processInfo.environment
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Where screenshots and the audit report go.
    static var outputFolder: URL {
        environment["MAC_UITEST_OUTPUT"].map { URL(fileURLWithPath: $0) } ?? repoRoot.appending(path: "build/mac-ui")
    }

    /// A fresh copy of two fixtures (no people in them), so each test starts clean.
    static func makeLibrary() throws -> URL {
        let folder = URL(fileURLWithPath: "/private/tmp/LightEditorUITests").appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["DSC04921.ARW", "DSCF2030.raf"] {
            try FileManager.default.copyItem(at: repoRoot.appending(path: "Fixtures/\(name)"), to: folder.appending(path: name))
        }
        return folder
    }

    /// The app, with the Main Thread Checker and the Thread Performance Checker
    /// loaded when MAC_UITEST_CHECKERS=1 (their reports go to the system log, which
    /// the script reads).
    @MainActor static func makeApp(library: URL, _ arguments: [String] = [], reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FixtureLibrary", library.path, "-ApplePersistenceIgnoreState", "YES", "-HideSidebar", "YES"]
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

    /// Drags a slider by a fraction of its width with the mouse.
    func drag(_ slider: XCUIElement, from: CGFloat = 0.5, to: CGFloat) {
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
        start.click(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5)))
        Thread.sleep(forTimeInterval: 0.6)
    }
}

/// Saves a screenshot of the app's window as a PNG and an attachment.
@MainActor func saveScreenshot(_ app: XCUIApplication, _ name: String, test: XCTestCase) {
    let shot = app.windows.firstMatch.exists ? app.windows.firstMatch.screenshot() : app.screenshot()
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    test.add(attachment)
    let folder = MacUITest.outputFolder.appending(path: "screens")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? shot.pngRepresentation.write(to: folder.appending(path: "\(name).png"))
}
