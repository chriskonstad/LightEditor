#if os(macOS) && DEBUG
import AppKit
import EditorCore
import SwiftUI

/// Development-only hooks for driving the Mac app without screen-recording access:
/// `-OpenFirstAsset YES` opens the first photo, and `-SnapshotTo <dir>` writes a PNG
/// of the main window every two seconds (the Metal photo area renders as blank).
enum DebugAutomation {
    @MainActor
    static func start(app: AppModel) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "OpenFirstAsset") {
            Task {
                for _ in 0..<50 where app.assets.count == 0 { try? await Task.sleep(for: .milliseconds(200)) }
                if app.assets.count > 0 { app.editing = app.assets[0] }
            }
        }
        if let directory = defaults.string(forKey: "SnapshotTo") {
            Task {
                var index = 0
                while true {
                    try? await Task.sleep(for: .seconds(2))
                    guard let view = NSApp.windows.first(where: \.isVisible)?.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
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
}
#endif
