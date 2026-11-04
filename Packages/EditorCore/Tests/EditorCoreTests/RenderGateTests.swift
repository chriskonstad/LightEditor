import Foundation
import Synchronization
import Testing
@testable import EditorCore

@Suite struct RenderGateTests {
    @Test func urgentRendersGoAheadOfQueuedOnes() async throws {
        let gate = RenderGate()
        let order = Mutex<[String]>([])
        let (release, open) = AsyncStream<Void>.makeStream()
        let queuedCount = Mutex(0)
        // Hold the gate with a bulk render, then queue more behind it.
        let first = Task {
            try await gate.run {
                for await _ in release { break }
                order.withLock { $0.append("bulk 1") }
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        var waiting: [Task<Void, any Error>] = []
        for (name, priority) in [("bulk 2", RenderPriority.background), ("leave", .soon), ("bulk 3", .background), ("save now", .now), ("leave 2", .soon)] {
            waiting.append(Task {
                try await gate.run(priority: priority, queued: { queuedCount.withLock { $0 += 1 } }) {
                    order.withLock { $0.append(name) }
                }
            })
            // Queue them in this order.
            for _ in 0..<200 where queuedCount.withLock({ $0 }) < waiting.count { try await Task.sleep(for: .milliseconds(2)) }
        }
        open.yield()
        try await first.value
        for task in waiting { try await task.value }
        #expect(order.withLock { $0 } == ["bulk 1", "save now", "leave", "leave 2", "bulk 2", "bulk 3"])
    }
}
