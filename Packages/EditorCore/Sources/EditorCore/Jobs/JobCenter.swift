import Foundation
import Observation

/// One unit of background work shown in the job tray.
@MainActor
@Observable
public final class Job: Identifiable {
    public enum State: Equatable, Sendable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    public let id = UUID()
    public var label: String
    public var detail: String?
    /// 0...1, or nil while the amount of work is unknown.
    public var progress: Double?
    /// Photos this job still has to process, when it works on photos.
    public var remaining: Int?
    public private(set) var state: State = .running
    /// Jobs that finish within the reveal delay are never shown, so cache hits don't flicker.
    public fileprivate(set) var isRevealed = false
    public let startedAt = Date()

    fileprivate var task: Task<Void, Never>?

    init(label: String, detail: String?) {
        self.label = label
        self.detail = detail
    }

    public var isActive: Bool { state == .running }

    public func cancel() {
        task?.cancel()
        if state == .running { state = .cancelled }
    }

    fileprivate func finish(_ state: State) {
        if self.state == .running { self.state = state }
        if state == .finished { progress = 1 }
        remaining = nil
    }
}

/// A Sendable handle that background work uses to report progress.
public struct JobReporter: Sendable {
    let job: Job

    public func progress(_ value: Double?, detail: String? = nil, remaining: Int? = nil) {
        let job = self.job
        Task { @MainActor in
            guard job.isActive else { return }
            job.progress = value.map { min(max($0, 0), 1) }
            if let detail { job.detail = detail }
            if let remaining { job.remaining = remaining }
        }
    }
}

/// The observable model behind the job tray.
///
/// Every background operation longer than about 100 ms goes through `run`, so it
/// is visible, shows progress and can be cancelled.
@MainActor
@Observable
public final class JobCenter {
    public private(set) var jobs: [Job] = []

    /// How long a job runs before it appears in the tray.
    public var revealDelay: Duration = .milliseconds(120)
    /// How long a finished job lingers so the user sees it complete.
    public var lingerDuration: Duration = .seconds(1.5)

    public init() {}

    /// Jobs that should be visible in the tray right now.
    public var visibleJobs: [Job] { jobs.filter(\.isRevealed) }
    public var activeCount: Int { jobs.count(where: { $0.isActive && $0.isRevealed }) }
    /// Photos still to process across running jobs.
    public var photosRemaining: Int { jobs.filter { $0.isActive && $0.isRevealed }.compactMap(\.remaining).reduce(0, +) }

    /// Runs `operation` as a tracked job. The returned task yields its result.
    @discardableResult
    public func run<T: Sendable>(
        _ label: String,
        detail: String? = nil,
        photos: Int? = nil,
        operation: @escaping @Sendable (JobReporter) async throws -> T
    ) -> Task<T, any Error> {
        let job = Job(label: label, detail: detail)
        job.remaining = photos
        jobs.append(job)
        let reporter = JobReporter(job: job)
        let work = Task.detached(priority: .userInitiated) {
            try await operation(reporter)
        }
        job.task = Task { [weak self] in
            await withTaskCancellationHandler {
                let result = await work.result
                switch result {
                case .success: job.finish(.finished)
                case .failure(let error) where error is CancellationError: job.finish(.cancelled)
                case .failure(let error): job.finish(.failed(error.localizedDescription))
                }
            } onCancel: {
                work.cancel()
            }
            // Linger in a fresh task: this one may be cancelled, which would skip the sleep.
            Task { [weak self] in
                try? await Task.sleep(for: self?.lingerDuration ?? .seconds(1))
                self?.remove(job)
            }
        }
        Task { [revealDelay] in
            try? await Task.sleep(for: revealDelay)
            if job.state == .running { job.isRevealed = true }
        }
        return Task {
            try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        }
    }

    public func cancelAll() {
        for job in jobs { job.cancel() }
    }

    private func remove(_ job: Job) {
        // Failed jobs stay until the user has had a chance to read them.
        if case .failed = job.state, job.isRevealed {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                self?.jobs.removeAll { $0 === job }
            }
            return
        }
        jobs.removeAll { $0 === job }
    }
}
