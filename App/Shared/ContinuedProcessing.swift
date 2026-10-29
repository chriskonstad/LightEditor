#if os(iOS)
import BackgroundTasks
import EditorCore
import os

/// Keeps a long job running when the app goes to the background or the screen locks.
///
/// Each covered job gets its own `BGContinuedProcessingTask`. iOS shows the job's label,
/// detail and progress in a Live Activity on the Lock Screen and in the Dynamic Island,
/// where the user can also stop it, and lets the work keep using the GPU on devices that
/// support background GPU access. The job runs the same way either way; this only asks iOS
/// to keep the app alive and shows how far it has got.
@MainActor
enum ContinuedProcessing {
    nonisolated private static let log = Logger(subsystem: Signposts.subsystem, category: "background")

    /// Must match the wildcard in `BGTaskSchedulerPermittedIdentifiers` (App/Resources/Info.plist).
    private static var prefix: String { (Bundle.main.bundleIdentifier ?? "lighteditor") + ".bulk" }

    /// Asks iOS to keep `job` running in the background. Call it while the app is in the
    /// foreground, right after the user starts the job.
    static func cover(_ job: Job) {
        let identifier = "\(prefix).\(job.id.uuidString)"
        // Each identifier is registered once, for this job only; continued processing
        // tasks may register after launch.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { return }
                run(task, for: job)
            }
        }
        guard registered else {
            log.error("Couldn't register \(identifier, privacy: .public); is the prefix in BGTaskSchedulerPermittedIdentifiers?")
            return
        }
        let title = job.label
        let subtitle = job.detail ?? "Starting…"
        // Submission can block, so it stays off the main thread.
        Task.detached(priority: .userInitiated) {
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            // The job is already running in the foreground; a task that can't start now is no use later.
            request.strategy = .fail
            // Renders and AI run on the GPU, which needs background GPU access once the app leaves the screen.
            if BGTaskScheduler.supportedResources.contains(.gpu) {
                request.requiredResources = .gpu
            }
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } catch {
                log.error("Continued processing for \(title, privacy: .public) wasn't accepted: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Mirrors the job into the task until it ends, and stops the job if iOS or the user ends the task.
    private static func run(_ task: BGContinuedProcessingTask, for job: Job) {
        guard job.isActive else {
            task.setTaskCompleted(success: job.state == .finished)
            return
        }
        let units: Int64 = 1000
        task.progress.totalUnitCount = units
        task.expirationHandler = {
            Task { @MainActor in job.cancel() }
        }
        job.onChange = { job in
            task.progress.completedUnitCount = Int64((job.progress ?? 0) * Double(units))
            task.updateTitle(job.label, subtitle: job.detail ?? "")
            guard !job.isActive else { return }
            job.onChange = nil
            task.setTaskCompleted(success: job.state == .finished)
        }
        job.onChange?(job)
    }
}
#endif
