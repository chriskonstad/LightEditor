import XCTest

/// Settings for a UI test run, from the environment. `xcodebuild` passes variables
/// prefixed with TEST_RUNNER_ to the test runner without the prefix, which is how
/// scripts/test-ui.sh sets these.
enum UITestConfig {
    static let environment = ProcessInfo.processInfo.environment
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// A folder of photos the app opens as its library (`-FixtureLibrary`), so the
    /// simulator's Photos library is never touched. (A simulator app can read the
    /// Mac's file system.)
    static var libraryPath: String {
        if let path = environment["UITEST_LIBRARY"], !path.isEmpty { return path }
        return repoRoot.appending(path: "build/ui-test-library").path
    }

    /// Where screenshots and the audit report go, one folder per device.
    static var outputFolder: URL {
        let base = environment["UITEST_OUTPUT"].map { URL(fileURLWithPath: $0) } ?? repoRoot.appending(path: "build/ui-screenshots")
        return base.appending(path: deviceName.replacingOccurrences(of: " ", with: "-"))
    }

    /// The device type, without the "LightEditor UITest" prefix of the script's simulators.
    static var deviceName: String {
        let name = environment["SIMULATOR_DEVICE_NAME"] ?? "device"
        return name.replacingOccurrences(of: "LightEditor UITest ", with: "")
    }

    /// Set UITEST_STRICT=0 to report audit failures without failing the test.
    static var strict: Bool { environment["UITEST_STRICT"] != "0" }

    /// Known findings that don't fail the run (see `AuditBaseline`).
    static var baselineFile: URL { repoRoot.appending(path: "UITests/audit-baseline.txt") }
}

/// Dynamic Type sizes, as the launch argument `-UIPreferredContentSizeCategoryName` takes them.
enum ContentSize: String {
    case extraSmall = "UICTContentSizeCategoryXS"
    case large = "UICTContentSizeCategoryL"
    case extraExtraExtraLarge = "UICTContentSizeCategoryXXXL"
    case accessibilityMedium = "UICTContentSizeCategoryAccessibilityM"
    case accessibilityExtraExtraExtraLarge = "UICTContentSizeCategoryAccessibilityXXXL"

    var shortName: String {
        switch self {
        case .extraSmall: "XS"
        case .large: "L"
        case .extraExtraExtraLarge: "XXXL"
        case .accessibilityMedium: "AX1"
        case .accessibilityExtraExtraExtraLarge: "AX5"
        }
    }
}

/// One problem found on a screen.
struct AuditFinding {
    enum Kind: String {
        case clippedText = "clipped text"
        case smallHitTarget = "hit target under 44 pt"
        case offscreen = "laid out off screen"
        case hitRegion = "hit region"
        case appleAudit = "accessibility"
    }

    enum Status: String {
        /// New, and enforced: fails the test.
        case fail = "FAIL"
        /// In the baseline: a known issue that doesn't fail the test.
        case known
        /// A kind we only report (contrast, descriptions, …).
        case warn
    }

    let kind: Kind
    /// The screen's name without its number, e.g. "tab-light".
    let screen: String
    let element: String
    let detail: String
    var status: Status

    /// What the baseline matches on: no sizes or counts, which wobble between runs.
    func baselineKey(configuration: String) -> String {
        "\(UITestConfig.deviceName) | \(configuration) | \(screen) | \(kind.rawValue) | \(element)"
    }

    var line: String { "[\(status.rawValue)] \(screen): \(kind.rawValue): \(element) — \(detail)" }
}

/// Findings that were already there when the audit was introduced (or since accepted),
/// one per line in UITests/audit-baseline.txt. They're reported as "known" and don't
/// fail the run, so the audit catches regressions without blocking on old issues.
/// Fix one and the report lists its line as stale; delete it, or re-record with
/// `scripts/test-ui.sh --record-baseline`.
enum AuditBaseline {
    static let entries: Set<String> = {
        guard let text = try? String(contentsOf: UITestConfig.baselineFile, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty })
    }()
}

/// Walks the app's accessibility tree and runs Apple's accessibility audit, collecting
/// findings for the report.
@MainActor
final class ScreenAuditor {
    let app: XCUIApplication
    let contentSize: ContentSize
    let orientation: String
    private(set) var findings: [AuditFinding] = []
    private(set) var screens: [String] = []

    init(app: XCUIApplication, contentSize: ContentSize, orientation: String) {
        self.app = app
        self.contentSize = contentSize
        self.orientation = orientation
    }

    var configuration: String { "\(orientation)-\(contentSize.shortName)" }
    var folder: URL { UITestConfig.outputFolder.appending(path: configuration) }

    /// Screenshots and audits whatever is on screen now. `audit: false` only takes the
    /// screenshot, for system UI such as menus.
    func capture(_ screen: String, audit: Bool = true) {
        screens.append(screen)
        let file = String(format: "%02d-%@", screens.count, screen)
        // Let animations settle so frames are final, and let background jobs (decodes,
        // thumbnails) finish: the job tray pill comes and goes with them, which would
        // make findings depend on timing.
        Thread.sleep(forTimeInterval: 0.8)
        let jobTray = app.descendants(matching: .any)["jobTray"]
        let deadline = Date().addingTimeInterval(15)
        while jobTray.exists, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        saveScreenshot(file)
        guard audit else { return }
        checkTree(screen: screen)
        runAppleAudit(screen: screen)
    }

    private func saveScreenshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(UITestConfig.deviceName) \(configuration) \(name)"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Screenshot \(name)") { $0.add(attachment) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: folder.appending(path: "\(name).png"))
    }

    private func record(_ kind: AuditFinding.Kind, _ screen: String, _ element: String, _ detail: String, enforced: Bool) {
        var finding = AuditFinding(kind: kind, screen: screen, element: element, detail: detail, status: enforced ? .fail : .warn)
        if enforced, AuditBaseline.entries.contains(finding.baselineKey(configuration: configuration)) { finding.status = .known }
        // The same element on the same screen once is enough (Apple's audit repeats some).
        guard !findings.contains(where: { $0.screen == screen && $0.kind == kind && $0.element == element && $0.detail == detail }) else { return }
        findings.append(finding)
    }

    // MARK: Our own checks, on one snapshot of the tree (one round trip, so it's fast)

    /// Controls we draw ourselves. System switches, sliders and steppers are left to
    /// Apple's hit-region audit: their visible frames are smaller than their hit areas.
    /// List cells are system rows, also left to Apple's audit.
    private static let tappableTypes: Set<XCUIElement.ElementType> = [.button, .link, .menuButton, .popUpButton, .textField]
    private static let leafTypes: Set<XCUIElement.ElementType> = [
        .staticText, .button, .image, .textField, .slider, .switch, .toggle, .link, .menuButton, .segmentedControl,
    ]
    private static let scrollingTypes: Set<XCUIElement.ElementType> = [.scrollView, .collectionView, .table]
    /// Bars whose buttons get system-sized hit areas larger than their frames.
    private static let systemBarTypes: Set<XCUIElement.ElementType> = [.navigationBar, .toolbar, .tabBar]

    private struct Context {
        var inScroller = false
        var scrollerFrame: CGRect?
        var inSegments = false
        var inSystemBar = false
    }

    /// Texts that a scroll view cuts off at its edge, by identifier and label. Apple's
    /// audit calls those clipped; scrolling isn't a layout bug, so they're not enforced.
    private var scrolledOutOfView: Set<String> = []

    private func checkTree(screen: String) {
        scrolledOutOfView = []
        guard let root = try? app.snapshot() else { return }
        let window = root.children.first { $0.elementType == .window }?.frame ?? root.frame
        walk(root, screen: screen, window: window, context: Context())
    }

    private func name(of element: XCUIElementSnapshot) -> String {
        let name = !element.identifier.isEmpty ? element.identifier : (element.label.isEmpty ? "unlabeled" : "\"\(element.label)\"")
        return "\(name) (\(element.elementType.name))"
    }

    private func walk(_ element: XCUIElementSnapshot, screen: String, window: CGRect, context: Context) {
        let frame = element.frame
        if let scroller = context.scrollerFrame, !scroller.insetBy(dx: -1, dy: -1).contains(frame) || !window.contains(frame) {
            for key in [element.identifier, "\"\(element.label)\""] where !key.isEmpty && key != "\"\"" { scrolledOutOfView.insert(key) }
        }
        if !frame.isEmpty, frame.intersects(window) {
            // Touch targets: 44 × 44 pt (Apple HIG), on enabled controls we lay out.
            if Self.tappableTypes.contains(element.elementType), element.isEnabled, !context.inSegments, !context.inSystemBar,
               element.label != "Sheet Grabber", frame.width < 43.5 || frame.height < 43.5 {
                record(.smallHitTarget, screen, name(of: element), "\(Int(frame.width.rounded()))×\(Int(frame.height.rounded())) pt", enforced: true)
            }
            // Content pushed past the window's sides, outside anything that scrolls.
            // Containers wider than the window (sheet backdrops) aren't content.
            if !context.inScroller, Self.leafTypes.contains(element.elementType), frame.width <= window.width,
               frame.minX < window.minX - 1 || frame.maxX > window.maxX + 1 {
                record(.offscreen, screen, name(of: element), "x \(Int(frame.minX))…\(Int(frame.maxX)) in a \(Int(window.width)) pt window", enforced: true)
            }
        }
        var inner = context
        inner.inScroller = context.inScroller || Self.scrollingTypes.contains(element.elementType)
        if Self.scrollingTypes.contains(element.elementType) {
            inner.scrollerFrame = context.scrollerFrame.map { $0.intersection(frame) } ?? frame
        }
        inner.inSegments = context.inSegments || element.elementType == .segmentedControl
        inner.inSystemBar = context.inSystemBar || Self.systemBarTypes.contains(element.elementType)
        for child in element.children {
            walk(child, screen: screen, window: window, context: inner)
        }
    }

    // MARK: Apple's accessibility audit

    /// Enforced: clipped text and hit regions. Reported only: contrast, Dynamic Type
    /// support, descriptions and traits.
    private static let enforcedAudits: XCUIAccessibilityAuditType = [.textClipped, .hitRegion]

    private func runAppleAudit(screen: String) {
        do {
            try app.performAccessibilityAudit(for: .all) { [self] issue in
                let element = issue.element.map { el -> String in
                    let id = el.identifier, label = el.label
                    return !id.isEmpty ? id : (label.isEmpty ? "unlabeled" : "\"\(label)\"")
                } ?? "screen"
                let kind: AuditFinding.Kind = switch issue.auditType {
                case .textClipped: .clippedText
                case .hitRegion: .hitRegion
                default: .appleAudit
                }
                var detail = kind == .appleAudit ? "\(issue.auditType.name): \(issue.compactDescription)" : issue.compactDescription
                var enforced = Self.enforcedAudits.contains(issue.auditType)
                if kind == .clippedText, scrolledOutOfView.contains(element) {
                    detail += " (cut off by scrolling)"
                    enforced = false
                } else if kind == .clippedText, element == "screen", screen.hasSuffix("-scrolled") {
                    // Apple's audit names no element, and a scrolled panel always has a
                    // row cut by its edge; which one depends on where the scroll stopped.
                    detail += " (no element; likely the scroll edge)"
                    enforced = false
                }
                record(kind, screen, element, detail, enforced: enforced)
                // Handled here: failures are reported together at the end of the test.
                return true
            }
        } catch {
            record(.appleAudit, screen, "audit", "\(error)", enforced: false)
        }
    }

    // MARK: Report

    /// Writes `audit.txt` (and `baseline.txt`, this run's enforced findings in baseline
    /// form) next to the screenshots, and fails the test on new enforced findings.
    func finish(file: StaticString = #filePath, line: UInt = #line) {
        let failures = findings.filter { $0.status == .fail }
        let known = findings.filter { $0.status == .known }
        let current = Set(findings.filter { $0.status != .warn }.map { $0.baselineKey(configuration: configuration) })
        let prefix = "\(UITestConfig.deviceName) | \(configuration) | "
        let walked = Set(screens)
        let stale = AuditBaseline.entries.filter { entry in
            guard entry.hasPrefix(prefix), !current.contains(entry) else { return false }
            // Only screens this run reached; a skipped screen isn't a fix.
            let screen = entry.dropFirst(prefix.count).components(separatedBy: " | ").first ?? ""
            return walked.contains(screen)
        }.sorted()

        var report = "\(UITestConfig.deviceName), \(orientation), Dynamic Type \(contentSize.shortName)\n"
        report += "Screens: \(screens.joined(separator: ", "))\n"
        report += "\(failures.count) new failures, \(known.count) known (in UITests/audit-baseline.txt), "
        report += "\(findings.count - failures.count - known.count) warnings, \(stale.count) fixed\n\n"
        let order: [AuditFinding.Status: Int] = [.fail: 0, .known: 1, .warn: 2]
        report += findings.sorted { (order[$0.status]!, $0.screen, $0.element) < (order[$1.status]!, $1.screen, $1.element) }
            .map(\.line).joined(separator: "\n")
        if !stale.isEmpty {
            report += "\n\nFixed (remove from UITests/audit-baseline.txt, or run scripts/test-ui.sh --record-baseline):\n"
            report += stale.joined(separator: "\n")
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? report.write(to: folder.appending(path: "audit.txt"), atomically: true, encoding: .utf8)
        let baseline = (["# prefix: \(prefix)"] + current.sorted()).joined(separator: "\n") + "\n"
        try? baseline.write(to: folder.appending(path: "baseline.txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(string: report)
        attachment.name = "audit \(configuration)"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Audit report") { $0.add(attachment) }
        print("UIAUDIT \(folder.path)/audit.txt: \(failures.count) new failures, \(known.count) known, \(stale.count) fixed")
        if !failures.isEmpty, UITestConfig.strict {
            XCTFail(
                "\(failures.count) new UI audit failures on \(UITestConfig.deviceName) \(configuration) (\(folder.path)/audit.txt):\n"
                    + failures.map(\.line).joined(separator: "\n"),
                file: file, line: line
            )
        }
    }
}

extension XCUIElement.ElementType {
    var name: String {
        switch self {
        case .button: "button"
        case .slider: "slider"
        case .switch: "switch"
        case .toggle: "toggle"
        case .textField: "text field"
        case .staticText: "text"
        case .image: "image"
        case .link: "link"
        case .menuButton: "menu button"
        case .popUpButton: "pop-up button"
        case .segmentedControl: "segmented control"
        case .cell: "cell"
        case .other: "other"
        default: "type \(rawValue)"
        }
    }
}

extension XCUIAccessibilityAuditType {
    var name: String {
        switch self {
        case .contrast: "contrast"
        case .elementDetection: "element detection"
        case .hitRegion: "hit region"
        case .sufficientElementDescription: "description"
        case .dynamicType: "dynamic type"
        case .textClipped: "text clipped"
        case .trait: "trait"
        default: "audit \(rawValue)"
        }
    }
}
