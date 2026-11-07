#if os(macOS) && DEBUG
import AppKit
import MetalKit
import EditorCore
import SwiftUI

/// Development-only hooks for driving the Mac app without screen-recording access,
/// e.g. for App Store screenshots:
/// - `-OpenFirstAsset YES` opens the first photo, or `-OpenAsset <file name>` that one;
/// - then `-AutoTone YES`, `-ApplyPreset <name>` and `-EditorTab <presets|light|color|grade|detail|masks>`;
/// - `-HideSidebar YES` collapses the sidebar;
/// - `-SnapshotTo <dir>` writes a PNG of the window every two seconds, with the photo
///   painted in (window snapshots leave Metal content blank).
enum DebugAutomation {
    @MainActor
    static func start(app: AppModel) {
        let defaults = UserDefaults.standard
        let name = defaults.string(forKey: "OpenAsset")
        if defaults.bool(forKey: "OpenFirstAsset") || name != nil {
            Task {
                for _ in 0..<50 where app.assets.count == 0 { try? await Task.sleep(for: .milliseconds(200)) }
                let assets = (0..<app.assets.count).map { app.assets[$0] }
                guard let asset = name.map({ name in assets.first { $0.id == name } }) ?? assets.first else { return }
                app.editing = asset
                for _ in 0..<100 where app.activeEditor?.phase != .ready { try? await Task.sleep(for: .milliseconds(200)) }
                guard let editor = app.activeEditor else { return }
                if let preset = defaults.string(forKey: "ApplyPreset"), let match = app.presets.first(where: { $0.name == preset }) {
                    editor.apply(match)
                }
                if defaults.bool(forKey: "AutoTone") { editor.autoTone() }
                if let tab = defaults.string(forKey: "EditorTab").flatMap(EditorModel.Tab.init(rawValue:)) { editor.tab = tab }
            }
        }
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
    }

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
}
#endif
