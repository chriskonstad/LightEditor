import Foundation
#if os(iOS)
import UIKit
#endif

/// Keeps the app running briefly in the background so a save in flight can finish.
struct BackgroundActivity: Sendable {
    #if os(iOS)
    private let id: UIBackgroundTaskIdentifier

    @MainActor
    static func begin(_ name: String) -> BackgroundActivity {
        BackgroundActivity(id: UIApplication.shared.beginBackgroundTask(withName: name))
    }

    func end() {
        let id = self.id
        Task { @MainActor in UIApplication.shared.endBackgroundTask(id) }
    }
    #else
    @MainActor
    static func begin(_ name: String) -> BackgroundActivity { BackgroundActivity() }
    func end() {}
    #endif
}
