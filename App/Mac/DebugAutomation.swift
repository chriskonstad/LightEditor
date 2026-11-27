#if DEBUG
#if os(macOS)
import AppKit
import MetalKit
#endif
import EditorCore
import SwiftUI

/// Development-only hooks for driving the app (the photo, tab and demo hooks also
/// work in the iOS simulator) without screen-recording access,
/// e.g. for App Store screenshots:
/// - `-OpenFirstAsset YES` opens the first photo, `-OpenAsset <file name>` that one, or
///   `-OpenAssetIndex <n>` the n-th;
/// - then `-SetParams "effects.vignette.amount=100,light.exposure=0.5"` sets scalar
///   parameters, as if each slider had been moved;
/// - then `-AutoTone YES`, `-ApplyPreset <name>` and `-EditorTab <presets|light|color|effects|detail|masks|finish>`;
/// - `-OpenWheel <shadows|midtones|highlights|global>` opens that color wheel, and
///   `-ScrollTo <view id>` scrolls the panel to a section (`section.grading`);
/// - `-HideSidebar YES` collapses the sidebar;
/// - `-SnapshotTo <dir>` writes a PNG of the window every two seconds, with the photo
///   painted in (window snapshots leave Metal content blank);
/// - `-WatermarkLogo <file>` imports a logo (an SVG goes through `SVGToPDF`, as
///   in the Finish tab) and makes it the photo's watermark;
/// - `-DemoMaskOverlay YES` walks through the mask overlay's auto-hide (add a radial
///   mask, raise its exposure, then move it), four seconds per step, for snapshots.
enum DebugAutomation {
    /// The Finish tab's logo import, without the file picker.
    @MainActor
    static func setWatermarkLogo(_ path: String, editor: EditorModel) async {
        guard let store = editor.app.lutStore.logos else { return }
        let url = URL(fileURLWithPath: path)
        do {
            let logo = url.pathExtension.lowercased() == "svg"
                ? try store.importLogo(pdf: try await SVGToPDF.convert(try Data(contentsOf: url)), name: url.deletingPathExtension().lastPathComponent)
                : try store.importLogo(from: url)
            editor.set(.watermarkSize, .scalar(12))
            editor.set(.watermarkOpacity, .scalar(90))
            editor.set(.watermark, .watermark(Watermark(logo: logo, position: .bottomRight)))
        } catch {
            print("WatermarkLogo: \(error)")
        }
    }

    @MainActor
    static func start(app: AppModel) {
        let defaults = UserDefaults.standard
        let name = defaults.string(forKey: "OpenAsset")
        let index = defaults.object(forKey: "OpenAssetIndex") != nil ? defaults.integer(forKey: "OpenAssetIndex") : nil
        if defaults.bool(forKey: "OpenFirstAsset") || name != nil || index != nil {
            Task {
                for _ in 0..<100 where app.assets.count <= (index ?? 0) { try? await Task.sleep(for: .milliseconds(200)) }
                let assets = (0..<app.assets.count).map { app.assets[$0] }
                let picked = index.flatMap { $0 < assets.count ? assets[$0] : nil }
                guard let asset = picked ?? name.map({ name in assets.first { $0.id == name } }) ?? assets.first else { return }
                app.editing = asset
                for _ in 0..<150 where app.activeEditor?.phase != .ready { try? await Task.sleep(for: .milliseconds(200)) }
                guard let editor = app.activeEditor else { return }
                if let preset = defaults.string(forKey: "ApplyPreset"), let match = app.presets.first(where: { $0.name == preset }) {
                    editor.apply(match)
                }
                if defaults.bool(forKey: "AutoTone") { editor.autoTone() }
                for pair in (defaults.string(forKey: "SetParams") ?? "").split(separator: ",") {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2, let value = Double(parts[1]) else { continue }
                    let key = ParamKey(String(parts[0]))
                    editor.setLive(key, value)
                    editor.commit(key)
                }
                if let range = defaults.string(forKey: "OpenWheel").flatMap(ToneRange.init(rawValue:)) { editor.wheelToOpen = range }
                if let tab = defaults.string(forKey: "EditorTab").flatMap(EditorModel.Tab.init(rawValue:)) { editor.tab = tab }
                if let target = defaults.string(forKey: "ScrollTo") { editor.panelScrollTarget = target }
                if let path = defaults.string(forKey: "WatermarkLogo") { await setWatermarkLogo(path, editor: editor) }
                if defaults.bool(forKey: "DemoMaskOverlay") { await demoMaskOverlay(editor) }
            }
        }
        #if os(macOS)
        if defaults.bool(forKey: "HideSidebar") {
            Task {
                // The split view shows up a moment after launch, and again whenever the
                // detail changes, so keep it collapsed for a while.
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(250))
                    func splits(in view: NSView) -> [NSSplitView] {
                        ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splits)
                    }
                    guard let root = NSApp.windows.first(where: \.isVisible)?.contentView else { continue }
                    for split in splits(in: root) {
                        if let item = (split.delegate as? NSSplitViewController)?.splitViewItems.first, item.behavior == .sidebar, !item.isCollapsed {
                            item.isCollapsed = true
                        }
                    }
                }
            }
        }
        if let directory = defaults.string(forKey: "SnapshotTo") {
            Task {
                var index = 0
                while true {
                    try? await Task.sleep(for: .seconds(2))
                    // The window's frame view, so the title bar and toolbar are in it too.
                    guard let view = NSApp.windows.first(where: \.isVisible)?.contentView?.superview,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let editor = app.activeEditor { drawCanvases(of: view, into: rep, renderer: editor.renderer) }
                    let url = URL(fileURLWithPath: directory).appending(path: String(format: "snapshot-%03d.png", index))
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    if let editor = app.activeEditor {
                        // The Metal canvas doesn't appear in cached snapshots; save what it shows.
                        let renderer = editor.renderer
                        let status = "frames=\(renderer.framesDrawn) drawable=\(renderer.lastDrawableSize) phase=\(editor.phase)"
                        try? Data(status.utf8).write(to: URL(fileURLWithPath: directory).appending(path: "renderer.txt"))
                        if let image = renderer.image,
                           let cg = RenderContext.shared.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: RenderContext.displayP3) {
                            let canvas = NSBitmapImageRep(cgImage: cg)
                            try? canvas.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appending(path: "canvas.png"))
                        }
                    }
                    index += 1
                }
            }
        }
        #endif
    }

    /// The same model calls the Masks panel and canvas make.
    @MainActor
    private static func demoMaskOverlay(_ editor: EditorModel) async {
        let step = Duration.seconds(4)
        editor.addMask(.radial(center: NormalizedPoint(x: 0.5, y: 0.6), radiusX: 0.3, radiusY: 0.25, angle: 0, feather: 0.5))
        print("DEMO step 1: added mask, overlay \(editor.showMaskOverlay)")
        try? await Task.sleep(for: step)
        editor.setMaskValueLive(.exposure, 1.5)
        editor.commitMaskValue(.exposure)
        print("DEMO step 2: exposure +1.5, overlay \(editor.showMaskOverlay)")
        try? await Task.sleep(for: step)
        editor.editSelectedShape("Move") { $0 = .radial(center: NormalizedPoint(x: 0.4, y: 0.6), radiusX: 0.3, radiusY: 0.25, angle: 0, feather: 0.5) }
        print("DEMO step 3: moved the mask, overlay \(editor.showMaskOverlay)")
        try? await Task.sleep(for: step)
        editor.setMaskValueLive(.exposure, 1.0)
        editor.commitMaskValue(.exposure)
        print("DEMO step 4: exposure +1.0, overlay \(editor.showMaskOverlay)")
    }

    #if os(macOS)
    /// Paints the renderer's last frame where its Metal view sits, since
    /// `cacheDisplay` leaves Metal content blank: so the snapshot shows the
    /// window as it looks, e.g. for App Store screenshots.
    @MainActor
    private static func drawCanvases(of root: NSView, into rep: NSBitmapImageRep, renderer: PreviewRenderer) {
        guard let frame = renderer.lastFrame,
              let cg = RenderContext.shared.createCGImage(frame, from: frame.extent, format: .RGBA8, colorSpace: RenderContext.displayP3) else { return }
        func metalViews(in view: NSView) -> [MTKView] {
            (view as? MTKView).map { [$0] } ?? view.subviews.flatMap(metalViews)
        }
        guard let canvas = metalViews(in: root).first(where: { $0.delegate === renderer }),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let rect = canvas.convert(canvas.bounds, to: root)
        // The context works in points (the rep's size) from the bottom left; a flipped
        // root view's coordinates start at the top.
        let y = root.isFlipped ? root.bounds.height - rect.maxY : rect.minY
        let target = CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.draw(cg, in: target)
        NSGraphicsContext.restoreGraphicsState()
    }
    #endif
}
#endif
