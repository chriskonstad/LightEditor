import XCTest

/// Opening a photo from Apple Photos on the Mac, without touching a Photos library:
/// both ways in hand the app something that identifies the photo, and the app finds
/// it in its own library (here the test's folder library, which matches the same way
/// `PhotoKitLibrary` does) and opens it in the editor.
@MainActor
final class MacOpenFromPhotosTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = MacUITest.makeApp(library: try MacUITest.makeLibrary())
        app.launch()
        XCTAssertTrue(app.element("library.photo.0").waitForExistence(timeout: 30), "the library didn't load")
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    /// Image › Edit With › LightEditor (or Finder's Open With): Photos hands over a
    /// copy of the file; the app opens the library photo it came from.
    func testEditWithOpensTheLibraryPhoto() throws {
        app.open(MacUITest.template.appending(path: "DSCF2030.raf"))
        assertEditorOpened("DSCF2030.raf")
    }

    /// Share › Edit in LightEditor: the share extension opens this link, made from the
    /// shared copy's name, capture time and size.
    func testShareLinkOpensTheLibraryPhoto() throws {
        let link = try XCTUnwrap(URL(string: "lighteditor://edit?name=dscf2030&taken=2025:01:31%2021:15:41&size=7728x5152"))
        app.open(link)
        assertEditorOpened("DSCF2030.raf")
    }

    private func assertEditorOpened(_ photo: String) {
        app.activate()
        XCTAssertTrue(app.waitForEditor(timeout: 60), "no photo opened")
        XCTAssertTrue(app.windows.firstMatch.title.contains(photo) || app.element("editor.title").label.contains(photo),
                      "opened the wrong photo: \(app.windows.firstMatch.title)")
    }
}
