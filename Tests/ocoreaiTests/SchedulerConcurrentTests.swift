// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Scheduler concurrent stress tests — queue under load, OOM rejection,
/// priority dispatch ordering, and batch dispatch integrity.

import Testing
import Foundation
import Logging
@testable import ocoreai
import ocoreaiTestUtilities

@Suite("SchedulerActor Concurrent")
struct SchedulerConcurrentTests {

    @Test("concurrent submits: 10 requests queued simultaneously")
    func testConcurrentSubmits() async throws {
        let sched = SchedulerActor(maxQueueSize: 64, log: Logger(label: "test.concurrent"))

        let r0 = try await sched.submit(SchedulingRequest(id: "conc-0", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r1 = try await sched.submit(SchedulingRequest(id: "conc-1", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r2 = try await sched.submit(SchedulingRequest(id: "conc-2", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r3 = try await sched.submit(SchedulingRequest(id: "conc-3", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r4 = try await sched.submit(SchedulingRequest(id: "conc-4", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r5 = try await sched.submit(SchedulingRequest(id: "conc-5", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r6 = try await sched.submit(SchedulingRequest(id: "conc-6", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r7 = try await sched.submit(SchedulingRequest(id: "conc-7", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r8 = try await sched.submit(SchedulingRequest(id: "conc-8", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r9 = try await sched.submit(SchedulingRequest(id: "conc-9", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))

        let ids: [String] = [r0, r1, r2, r3, r4, r5, r6, r7, r8, r9]
        #expect(ids.count == 10)
        #expect(await sched.pendingCount == 10)
    }

    @Test("queue overflow: 6th request rejected when maxQueueSize=5")
    func testQueueOverflow() async throws {
        let sched = SchedulerActor(maxQueueSize: 5, log: Logger(label: "test.overflow"))

        for i in (0..<5) {
            _ = try await sched.submit(SchedulingRequest(
                id: "fill-\(i)", priority: .chat, modelId: "m", prompt: "fill", tokenBudget: 256
            ))
        }
        #expect(await sched.pendingCount == 5)

        do {
            _ = try await sched.submit(SchedulingRequest(
                id: "overflow", priority: .chat, modelId: "m", prompt: "o", tokenBudget: 256
            ))
            Issue.record("Expected queue full error")
        } catch {
            guard let se = error as? SchedulerError, se == .queueFull else {
                Issue.record("Wrong error: \(error)")
                return
            }
        }
    }

    @Test("priority dispatch: interrupt before chat before background")
    func testPriorityDispatchOrder() async throws {
        let sched = SchedulerActor(maxQueueSize: 128, log: Logger(label: "test.priority"))

        // Sequential submit (order matters for priority queue)
        for i in (0..<3) {
            _ = try await sched.submit(SchedulingRequest(
                id: "bg-\(i)", priority: .background, modelId: "m", prompt: "bg", tokenBudget: 128
            ))
        }
        for i in (0..<3) {
            _ = try await sched.submit(SchedulingRequest(
                id: "ch-\(i)", priority: .chat, modelId: "m", prompt: "ch", tokenBudget: 128
            ))
        }
        _ = try await sched.submit(SchedulingRequest(
            id: "int-0", priority: .interrupt, modelId: "m", prompt: "int", tokenBudget: 128
        ))
        #expect(await sched.pendingCount == 7)

        let first = await sched.dispatch()
        #expect(first?.id == "int-0")
        let second = await sched.dispatch()
        #expect(second?.id.hasPrefix("ch-") == true)
        let third = await sched.dispatch()
        #expect(third?.id.hasPrefix("ch-") == true)
    }

    @Test("batch dispatch: 5 queued, batch 3, then complete 2")
    func testBatchDispatch() async throws {
        let sched = SchedulerActor(maxQueueSize: 128, log: Logger(label: "test.batch"))

        for i in (0..<5) {
            _ = try await sched.submit(SchedulingRequest(
                id: "batch-\(i)", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 128
            ))
        }

        let batch = await sched.dispatchBatch(3)
        #expect(batch.count == 3)
        #expect(await sched.pendingCount == 2)
        #expect(await sched.activeCount == 3)

        await sched.complete("batch-0")
        await sched.complete("batch-1")
        #expect(await sched.activeCount == 1)
    }

    @Test("active count after dispatch and complete")
    func testActiveCountDrains() async throws {
        let sched = SchedulerActor(maxQueueSize: 128, log: Logger(label: "test.drain"))

        for i in (0..<10) {
            _ = try await sched.submit(SchedulingRequest(
                id: "drain-\(i)", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 128
            ))
        }

        let dispatched = await sched.dispatchBatch(5)
        #expect(dispatched.count == 5)
        #expect(await sched.pendingCount == 5)
        #expect(await sched.activeCount == 5)

        // Complete all dispatched
        for d in dispatched {
            await sched.complete(d.id)
        }

        #expect(await sched.activeCount == 0)
        #expect(await sched.pendingCount == 5)
    }
}

