#if os(iOS) && DEBUG
import EditorCore
import Foundation

/// Development-only launch arguments for driving the iOS app in a simulator,
/// where synthetic taps don't always land:
/// - `-OpenAssetIndex <n>` opens the n-th photo of the library;
/// - then `-SetParams "effects.vignette.amount=100,light.exposure=0.5"` sets
///   scalar parameters, as if each slider had been moved.
/// The Mac has the same and more in `DebugAutomation`.
enum DebugEditorHooks {
    @MainActor
    static func start(app: AppModel) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "OpenAssetIndex") != nil else { return }
        let index = defaults.integer(forKey: "OpenAssetIndex")
        Task {
            for _ in 0..<100 where app.assets.count <= index { try? await Task.sleep(for: .milliseconds(200)) }
            guard index < app.assets.count else { return }
            app.editing = app.assets[index]
            for _ in 0..<150 where app.activeEditor?.phase != .ready { try? await Task.sleep(for: .milliseconds(200)) }
            guard let editor = app.activeEditor else { return }
            for pair in (defaults.string(forKey: "SetParams") ?? "").split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, let value = Double(parts[1]) else { continue }
                let key = ParamKey(String(parts[0]))
                editor.setLive(key, value)
                editor.commit(key)
            }
        }
    }
}
#endif
