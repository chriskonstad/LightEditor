import ImageIO
import XCTest

/// Whole user journeys, start to finish, checked against what lands on disk.
///
/// Each journey starts in the library of a fresh folder holding two RAWs with no
/// people in them (the cat, DSC04921.ARW, and the sunset, DSCF2030.raf), goes
/// through the screens a person would, and then reads the folder library's files:
/// the edit (`.raweditor/<photo>.recipe.json`), the image saved with it
/// (`.rendered`), and any exported copy. The simulator's test runner can read the
/// Mac's files, which is what makes the end result checkable here.
@MainActor
final class JourneyTests: XCTestCase {
    private var app: XCUIApplication!
    private var library: URL!

    private static let cat = "DSC04921.ARW"
    private static let sunset = "DSCF2030.raf"

    override func setUp() async throws {
        continueAfterFailure = false
        library = FileManager.default.temporaryDirectory.appending(path: "journey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        for name in [Self.cat, Self.sunset] {
            try FileManager.default.copyItem(at: UITestConfig.repoRoot.appending(path: "Fixtures/\(name)"), to: library.appending(path: name))
        }
        app = UITestConfig.makeApp()
        app.launchArguments = ["-FixtureLibrary", library.path, "-ResetState", "YES", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(element("library.photo.0").waitForExistence(timeout: 30), "the library didn't load")
    }

    override func tearDown() async throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: library)
    }

    // MARK: Journeys

    /// Open a photo, edit it, go back: the edit is saved with the photo (its recipe
    /// and a full-size image), and it's there when the photo opens again.
    func testEditSaveAndReopen() throws {
        open(0)
        let exposure = raise("light.exposure")
        leaveEditor()

        let recipe = try waitForRecipe(Self.cat)
        XCTAssertEqual(try XCTUnwrap(recipe["light.exposure"] as? Double), try XCTUnwrap(Self.number(exposure)), accuracy: 0.006,
                       "the saved recipe doesn't have the exposure that was set")
        let saved = try waitForFile(sidecar(Self.cat, "rendered"))
        let size = try XCTUnwrap(Self.pixelSize(saved))
        XCTAssertGreaterThan(max(size.width, size.height), 6000, "the image saved with the edit isn't full size: \(size)")

        open(0)
        XCTAssertEqual(slider("light.exposure").value as? String, exposure, "the edit wasn't there when the photo opened again")
    }

    /// Copy one photo's edits and paste them onto another from the library: the look
    /// goes across and is saved, but the border doesn't (it's off by default when
    /// pasting, as an output setting).
    func testCopyAndPasteToAnotherPhoto() throws {
        open(0)
        let exposure = raise("light.exposure")
        tab("Finish")
        drag(slider("finish.border.width"), from: 0.02, to: 0.4)
        tap(["editor.copy", "toolbar.copy"])
        leaveEditor()
        _ = try waitForRecipe(Self.cat)

        XCTAssertTrue(tapIfPresent("library.select"), "no Select in the library")
        element("library.photo.1").tap()
        XCTAssertTrue(tapIfPresent("library.paste"), "no Paste in the library")
        pause(1.5)  // The sheet slides up; judge the button once it's there.
        XCTAssertTrue(element("paste.confirm").isHittable, "the paste sheet's Paste button is off screen")
        XCTAssertTrue(tapIfPresent("paste.confirm"), "no Paste button in the paste sheet")

        let pasted = try waitForRecipe(Self.sunset)
        XCTAssertEqual(try XCTUnwrap(pasted["light.exposure"] as? Double), try XCTUnwrap(Self.number(exposure)), accuracy: 0.006,
                       "the pasted exposure didn't arrive")
        XCTAssertNil(pasted["output"], "the border was pasted, though output settings are off by default")
        _ = try waitForFile(sidecar(Self.sunset, "rendered"))
    }

    /// Add a border and export a copy: the exported file is the photo plus its border,
    /// while the image saved with the edit stays the photo alone.
    func testExportACopyWithABorder() throws {
        open(0)
        tab("Finish")
        drag(slider("finish.border.width"), from: 0.02, to: 0.4)
        tap(["editor.export", "toolbar.export"])
        XCTAssertTrue(tapIfPresent("export.saveCopy", timeout: 10), "no Save to Photos in the export sheet")
        let exported = try waitForFile(timeout: 120) { [library] in
            (try? FileManager.default.contentsOfDirectory(atPath: library!.path))?
                .first { !$0.hasPrefix(".") && $0 != Self.cat && $0 != Self.sunset }
                .map { library!.appending(path: $0) }
        }
        leaveEditor()
        let saved = try waitForFile(sidecar(Self.cat, "rendered"))
        let withBorder = try XCTUnwrap(Self.pixelSize(exported)), alone = try XCTUnwrap(Self.pixelSize(saved))
        XCTAssertGreaterThan(withBorder.width, alone.width, "the export has no border: \(withBorder) vs \(alone)")
        XCTAssertGreaterThan(withBorder.height, alone.height, "the export has no border: \(withBorder) vs \(alone)")
    }

    /// Save a look as a preset, then apply it to another photo.
    func testSaveAPresetAndApplyIt() throws {
        open(0)
        let exposure = raise("light.exposure")
        tab("Presets")
        XCTAssertTrue(tapIfPresent("preset.save"), "no New preset")
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "no name field for the preset")
        name.typeText("Journey look")
        app.alerts.buttons["Save"].tap()
        leaveEditor()

        open(1)
        tab("Presets")
        XCTAssertTrue(tapIfPresent("preset.Journey look"), "the new preset isn't in the list")
        pause(1)
        tab("Light")
        XCTAssertEqual(slider("light.exposure").value as? String, exposure, "applying the preset didn't set its exposure")
    }

    // MARK: Steps

    private func open(_ index: Int) {
        let tile = element("library.photo.\(index)")
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "no photo \(index) in the library")
        tile.tap()
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if ["editor.export", "toolbar.export"].contains(where: { element($0).exists && element($0).isEnabled }) { return }
            pause(0.5)
        }
        XCTFail("photo \(index) never finished opening")
    }

    /// Back to the library: the editor's own button on iPhone, the navigation bar's on iPad.
    private func leaveEditor() {
        if !tapIfPresent("editor.back", timeout: 2) {
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(element("library.photo.0").waitForExistence(timeout: 10), "didn't get back to the library")
    }

    private func tab(_ title: String) {
        let segment = app.segmentedControls.buttons[title].firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "no \(title) tab")
        segment.tap()
        pause(0.6)
    }

    private func slider(_ key: String) -> XCUIElement { element("slider.\(key)") }

    /// Drags a slider up from the middle and returns the value it shows.
    private func raise(_ key: String) -> String {
        let control = slider(key)
        XCTAssertTrue(control.waitForExistence(timeout: 5), "no \(key) slider")
        drag(control, from: 0.5, to: 0.72)
        let value = control.value as? String ?? ""
        XCTAssertNotEqual(value, "0.00")
        XCTAssertNotEqual(value, "0")
        return value
    }

    private func drag(_ control: XCUIElement, from: CGFloat, to: CGFloat) {
        if !control.isHittable { control.swipeUp() }
        let start = control.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: control.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
        pause(0.8)
    }

    private func tap(_ ids: [String]) {
        for id in ids where element(id).exists && element(id).isHittable {
            element(id).tap()
            pause(0.6)
            return
        }
        XCTFail("none of \(ids) on screen")
    }

    /// Taps a control, scrolling to it first if it's off screen (rows of a form or
    /// list don't exist until they're scrolled into view). Having to scroll is
    /// recorded with a screenshot, since a button people need shouldn't hide.
    @discardableResult
    private func tapIfPresent(_ id: String, timeout: TimeInterval = 5) -> Bool {
        guard reveal(id, timeout: timeout) else { return false }
        element(id).tap()
        pause(0.6)
        return true
    }

    /// Scrolls until the control is on screen; false if it never shows up.
    private func reveal(_ id: String, timeout: TimeInterval = 5) -> Bool {
        let target = element(id)
        _ = target.waitForExistence(timeout: timeout)
        var scrolls = 0
        while !(target.exists && target.isHittable), scrolls < 6 {
            if scrolls == 0 {
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "had to scroll to \(id)"
                shot.lifetime = .keepAlways
                add(shot)
            }
            scrollArea().swipeUp(velocity: .slow)
            scrolls += 1
            pause(0.5)
        }
        return target.exists && target.isHittable
    }

    /// What to swipe to scroll: a sheet when one is up, else the editor's control
    /// panel (on iPad a swipe in the middle of the screen would pan the photo).
    private func scrollArea() -> XCUIElement {
        if app.sheets.firstMatch.exists { return app.sheets.firstMatch }
        let tabs = app.segmentedControls.firstMatch
        if tabs.exists {
            let below = app.scrollViews.allElementsBoundByIndex
                .filter { $0.frame.minY >= tabs.frame.maxY - 1 && $0.frame.height > 120 && $0.isHittable }
                .min { $0.frame.minY < $1.frame.minY }
            if let below { return below }
        }
        return app
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    // MARK: Checking the files

    private func sidecar(_ photo: String, _ kind: String) -> URL {
        library.appending(path: ".raweditor/\(photo).\(kind == "recipe" ? "recipe.json" : kind)")
    }

    /// The saved recipe's parameters, look and output merged (output under "output").
    private func waitForRecipe(_ photo: String) throws -> [String: Any] {
        let url = try waitForFile(sidecar(photo, "recipe"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var params = json["params"] as? [String: Any] ?? [:]
        if let output = json["output"] { params["output"] = output }
        return params
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 120) throws -> URL {
        try waitForFile(timeout: timeout) { FileManager.default.fileExists(atPath: url.path) ? url : nil }
    }

    /// Waits for a file to appear and stop growing (saves write in the background).
    private func waitForFile(timeout: TimeInterval, _ find: () -> URL?) throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSize = -1
        while Date() < deadline {
            if let url = find(), let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 0 {
                if size == lastSize { return url }
                lastSize = size
            }
            pause(1)
        }
        throw NSError(domain: "JourneyTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "timed out after \(Int(timeout)) s waiting for a file to be written"])
    }

    static func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    /// "+1.25" or "−0.50" (a real minus sign) as a number.
    static func number(_ shown: String) -> Double? {
        Double(shown.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "+", with: ""))
    }
}
