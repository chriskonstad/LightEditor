import XCTest

/// The Mac editor: opening a photo, editing with the mouse, undo and redo from
/// the keyboard, every tab (screenshot plus Apple's accessibility audit against
/// MacUITests/audit-baseline.txt), and the watermark.
@MainActor
final class MacEditorTests: XCTestCase {
    private var app: XCUIApplication!
    private var library: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        library = try MacUITest.makeLibrary()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    private func open(_ photo: String = "DSC04921.ARW", tab: String = "light") {
        app = MacUITest.makeApp(library: library, ["-OpenAsset", photo, "-EditorTab", tab])
        app.launch()
        XCTAssertTrue(app.waitForEditor(), "the photo never opened")
    }

    func testEditUndoAndRedoWithTheKeyboard() throws {
        open()
        let exposure = app.element("slider.light.exposure")
        XCTAssertTrue(exposure.waitForExistence(timeout: 5), "no exposure slider")
        let key = "light.exposure"
        XCTAssertEqual(app.sliderValue(key), "0.00")
        app.drag(exposure, to: 0.7)
        let raised = app.sliderValue(key)
        XCTAssertNotNil(raised)
        XCTAssertNotEqual(raised, "0.00", "dragging with the mouse didn't change exposure")
        app.typeKey("z", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(app.sliderValue(key), "0.00", "⌘Z didn't undo")
        app.typeKey("z", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(app.sliderValue(key), raised, "⇧⌘Z didn't redo")
    }

    /// Each tab: a screenshot to look at, and Apple's audit. Known findings are in
    /// MacUITests/audit-baseline.txt; MAC_UITEST_RECORD=1 rewrites it.
    func testEveryTabAudits() throws {
        var findings: [String] = []
        for tab in ["presets", "light", "color", "effects", "detail", "masks", "finish"] {
            app?.terminate()
            open(tab: tab)
            Thread.sleep(forTimeInterval: 1)
            saveScreenshot(app, "tab-\(tab)", test: self)
            try app.performAccessibilityAudit { issue in
                let element = issue.element.map { $0.identifier.isEmpty ? "\"\($0.label)\"" : $0.identifier } ?? "screen"
                findings.append("tab-\(tab) | \(Self.name(of: issue.auditType)) | \(element)")
                return true  // Collected here; compared against the baseline below.
            }
        }
        try compareWithBaseline(Set(findings))
    }

    func testWatermarkTypingAndDragging() throws {
        open(tab: "finish")
        let toggle = app.element("toggle.watermark")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no watermark switch")
        toggle.click()
        let field = app.element("watermark.text")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeText("© Mac test\r")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(field.value as? String, "© Mac test")
        let box = app.element("watermark.box")
        XCTAssertTrue(box.waitForExistence(timeout: 5), "no watermark frame on the photo")
        let before = box.frame
        let grip = box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.click(forDuration: 0.1, thenDragTo: grip.withOffset(CGVector(dx: -120, dy: -80)))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertGreaterThan(abs(box.frame.midX - before.midX), 40, "dragging didn't move the watermark")
        saveScreenshot(app, "watermark-dragged", test: self)
    }

    // MARK: Audit baseline

    private static func name(of type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: "contrast"
        case .elementDetection: "element detection"
        case .hitRegion: "hit region"
        case .sufficientElementDescription: "description"
        case .action: "action"
        case .parentChild: "parent/child"
        default: "audit \(type.rawValue)"
        }
    }

    /// The baseline comes in through MAC_UITEST_BASELINE (the runner's sandbox can't
    /// read the repo), and the report goes out as attachments; scripts/test-mac-ui.sh
    /// handles both, and `--record` writes MacUITests/audit-baseline.txt from them.
    private func compareWithBaseline(_ findings: Set<String>) throws {
        attach(findings.sorted().joined(separator: "\n") + "\n", named: "audit-findings", test: self)
        if MacUITest.environment["MAC_UITEST_RECORD"] == "1" { return }
        let baseline = MacUITest.environment["MAC_UITEST_BASELINE"] ?? ""
        let known = Set(baseline.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty })
        let new = findings.subtracting(known).sorted()
        let fixed = known.subtracting(findings).sorted()
        let report = "\(findings.count) findings, \(new.count) new, \(fixed.count) fixed\n"
            + new.map { "[NEW] \($0)" }.joined(separator: "\n") + "\n" + fixed.map { "[fixed] \($0)" }.joined(separator: "\n")
        attach(report, named: "audit", test: self)
        XCTAssertTrue(new.isEmpty, "New Mac audit findings:\n" + new.joined(separator: "\n"))
    }
}

/// What happens to an edit when the Mac app is interrupted: hidden, or quit.
@MainActor
final class MacInterruptionTests: XCTestCase {
    private var app: XCUIApplication!
    private var library: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        library = try MacUITest.makeLibrary()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    private func launch(reset: Bool) {
        app = MacUITest.makeApp(library: library, ["-OpenAsset", "DSC04921.ARW", "-EditorTab", "light"], reset: reset)
        app.launch()
        XCTAssertTrue(app.waitForEditor(), "the photo never opened")
    }

    private var exposure: XCUIElement { app.element("slider.light.exposure") }

    func testHidingAndComingBackKeepsTheEdit() throws {
        launch(reset: true)
        app.drag(exposure, to: 0.7)
        let value = app.sliderValue("light.exposure")
        XCTAssertNotEqual(value, "0.00", "dragging didn't change exposure")
        app.typeKey("h", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.5)
        app.activate()
        XCTAssertTrue(exposure.waitForExistence(timeout: 10))
        XCTAssertEqual(app.sliderValue("light.exposure"), value)
        app.drag(exposure, from: 0.7, to: 0.4)
        XCTAssertNotEqual(app.sliderValue("light.exposure"), value, "the editor stopped responding after coming back")
    }

    func testAnEditSurvivesQuitting() throws {
        launch(reset: true)
        app.drag(exposure, to: 0.7)
        let value = app.sliderValue("light.exposure")
        XCTAssertNotEqual(value, "0.00", "dragging didn't change exposure")
        Thread.sleep(forTimeInterval: 2)  // Drafts are written within a moment of each change.
        app.terminate()
        launch(reset: false)
        XCTAssertTrue(exposure.waitForExistence(timeout: 10))
        XCTAssertEqual(app.sliderValue("light.exposure"), value, "the edit was lost when the app quit")
    }
}
