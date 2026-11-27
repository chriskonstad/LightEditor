import XCTest

/// App Store screenshots for iPhone and iPad (docs/app-store/screenshots.md). Each
/// shot is a fresh launch set up with the debug launch arguments (photo, preset,
/// parameters, tab, scroll position), so the set is the same on every run. Run
/// with `scripts/app-store-screenshots.sh` (`just screenshots`), which picks the
/// devices, cleans the status bar and collects the PNGs; `scripts/test-ui.sh` skips it.
///
/// Only the two fixtures without people in them are used: the sunset (DSCF2030.raf)
/// and the cat (DSC04921.ARW).
@MainActor
final class AppStoreScreenshotTests: XCTestCase {
    private struct Shot {
        var name: String
        var arguments: [String]
    }

    private static let sunset = "DSCF2030.raf"
    private static let cat = "DSC04921.ARW"

    private static let shots: [Shot] = [
        Shot(name: "01-light", arguments: ["-OpenAsset", sunset, "-AutoTone", "YES", "-EditorTab", "light"]),
        Shot(name: "02-color", arguments: [
            "-OpenAsset", cat, "-EditorTab", "color", "-ScrollTo", "section.hsl",
            "-SetParams", "color.hsl.red.hue=12,color.hsl.red.saturation=-18,color.hsl.red.luminance=10,color.hsl.orange.saturation=25,color.vibrance=15",
        ]),
        Shot(name: "03-grading", arguments: [
            "-OpenAsset", sunset, "-ApplyPreset", "Teal & orange", "-EditorTab", "color",
            "-ScrollTo", "section.grading", "-OpenWheel", "shadows",
        ]),
        Shot(name: "04-presets", arguments: ["-OpenAsset", sunset, "-ApplyPreset", "Velvia", "-AutoTone", "YES", "-EditorTab", "presets"]),
        Shot(name: "05-effects", arguments: [
            "-OpenAsset", cat, "-ApplyPreset", "B&W", "-EditorTab", "effects",
            "-SetParams", "effects.vignette.amount=-35,effects.grain.amount=30",
        ]),
        Shot(name: "06-masks", arguments: ["-OpenAsset", sunset, "-AutoTone", "YES", "-EditorTab", "masks"]),
        Shot(name: "07-finish", arguments: [
            "-OpenAsset", cat, "-ApplyPreset", "Classic Chrome", "-EditorTab", "finish",
            "-SetParams", "finish.border.width=5,finish.border.bottom=12",
        ]),
    ]

    private var output: URL {
        UITestConfig.outputFolder.appending(path: "app-store")
    }

    override func setUp() {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // The iPad set is landscape: the filmstrip, photo and inspector side by side.
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
    }

    func testCaptureAppStoreScreenshots() throws {
        let library = FileManager.default.temporaryDirectory.appending(path: "shots-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: UITestConfig.libraryPath), to: library)
        for shot in Self.shots {
            let app = UITestConfig.makeApp()
            app.launchArguments = [
                "-FixtureLibrary", library.path,
                "-ResetState", "YES",
                "-ApplePersistenceIgnoreState", "YES",
            ] + shot.arguments
            app.launch()
            let export = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["editor.export", "toolbar.export"])).firstMatch
            XCTAssertTrue(export.waitForExistence(timeout: 60), "\(shot.name): the editor didn't open")
            let deadline = Date().addingTimeInterval(120)
            while !export.isEnabled, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
            XCTAssertTrue(export.isEnabled, "\(shot.name): the photo never finished decoding")
            // The preset, parameters, tab and scroll are applied once it's ready; then
            // the full-quality render replaces the quick one.
            Thread.sleep(forTimeInterval: 5)
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = shot.name
            attachment.lifetime = .keepAlways
            add(attachment)
            try Self.uprightPNG(screenshot.image).write(to: output.appending(path: "\(shot.name).png"))
            app.terminate()
        }
    }

    /// The screenshot as PNG with its pixels upright. In landscape, XCUITest's own PNG
    /// stores portrait pixels plus an orientation tag, which App Store Connect may ignore.
    private static func uprightPNG(_ image: UIImage) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
