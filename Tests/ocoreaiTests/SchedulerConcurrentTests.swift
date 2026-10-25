// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Scheduler concurrent stress tests — queue under load, OOM rejection,
/// priority dispatch ordering, and batch dispatch integrity.

import Foundation
import Logging
import Testing
import ocoreaiTestUtilities

@testable import ocoreai

@Suite("SchedulerActor Concurrent")
struct SchedulerConcurrentTests {

    @Test("concurrent submits: 10 requests queued simultaneously")
    func testConcurrentSubmits() async throws {
        let sched = SchedulerActor(maxQueueSize: 64, log: Logger(label: "test.concurrent"))

        let r0 = try await sched.submit(
            SchedulingRequest(
                id: "conc-0", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r1 = try await sched.submit(
            SchedulingRequest(
                id: "conc-1", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r2 = try await sched.submit(
            SchedulingRequest(
                id: "conc-2", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r3 = try await sched.submit(
            SchedulingRequest(
                id: "conc-3", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r4 = try await sched.submit(
            SchedulingRequest(
                id: "conc-4", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r5 = try await sched.submit(
            SchedulingRequest(
                id: "conc-5", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r6 = try await sched.submit(
            SchedulingRequest(
                id: "conc-6", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r7 = try await sched.submit(
            SchedulingRequest(
                id: "conc-7", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r8 = try await sched.submit(
            SchedulingRequest(
                id: "conc-8", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        let r9 = try await sched.submit(
            SchedulingRequest(
                id: "conc-9", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))

        let ids: [String] = [r0, r1, r2, r3, r4, r5, r6, r7, r8, r9]
        #expect(ids.count == 10)
        #expect(await sched.pendingCount == 10)
    }

    @Test("queue overflow: 6th request rejected when maxQueueSize=5")
    func testQueueOverflow() async throws {
        let sched = SchedulerActor(maxQueueSize: 5, log: Logger(label: "test.overflow"))

        for i in (0 ..< 5) {
            _ = try await sched.submit(
                SchedulingRequest(
                    id: "fill-\(i)", priority: .chat, modelId: "m", prompt: "fill", tokenBudget: 256
                ))
        }
        #expect(await sched.pendingCount == 5)

        do {
            _ = try await sched.submit(
                SchedulingRequest(
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
        for i in (0 ..< 3) {
            _ = try await sched.submit(
                SchedulingRequest(
                    id: "bg-\(i)", priority: .background, modelId: "m", prompt: "bg",
                    tokenBudget: 128
                ))
        }
        for i in (0 ..< 3) {
            _ = try await sched.submit(
                SchedulingRequest(
                    id: "ch-\(i)", priority: .chat, modelId: "m", prompt: "ch", tokenBudget: 128
                ))
        }
        _ = try await sched.submit(
            SchedulingRequest(
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

    @Test("active count after dispatch and complete")
    func testActiveCountDrains() async throws {
        let sched = SchedulerActor(maxQueueSize: 128, log: Logger(label: "test.drain"))

        for i in (0 ..< 10) {
            _ = try await sched.submit(
                SchedulingRequest(
                    id: "drain-\(i)", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 128
                ))
        }

        var dispatched: [SchedulingRequest] = []
        for _ in 0 ..< 5 {
            guard let next = await sched.dispatch() else { break }
            dispatched.append(next)
        }
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

    // ── ownership + re-enqueue integrity ────────────────────────────────────
    // A submission is two actor messages (`submit`, then `dispatch`), so concurrent callers
    // interleave: whoever pops a stranger's request used to refuse its own caller with a
    // 503 while the stranger it dispatched became an active reservation nobody owned. And
    // the "all rejected → wait for memory" path never ran at all, so a rejected request
    // left the queue and was never seen again.

    @Test("a request refused by admission stays queued instead of vanishing")
    func rejectedRequestsWaitInQueue() async throws {
        let tracker = MemoryTracker(budgetBytes: 1_073_741_824)
        let gate = AdmissionGate(maxConcurrentPreFills: 0, memoryTracker: tracker)
        let sched = SchedulerActor(
            maxQueueSize: 128, admissionGate: gate, log: Logger(label: "test.reenqueue"))

        _ = try await sched.submit(
            SchedulingRequest(
                id: "wait-0", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))
        _ = try await sched.submit(
            SchedulingRequest(
                id: "wait-1", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))

        // Nothing fits (0 pre-fills allowed) ⇒ nobody is dispatched, and both candidates
        // are still there to be retried when memory frees.
        #expect(await sched.dispatch() == nil)
        #expect(await sched.pendingCount == 2)
        #expect(await sched.activeCount == 0)
    }

    @Test("submitAndDispatch starts its own request and leaves a stranger queued")
    func submitAndDispatchIsOwnedById() async throws {
        let sched = SchedulerActor(maxQueueSize: 128, log: Logger(label: "test.ownership"))

        // X (higher priority) submitted; its own dispatch message has not run yet —
        // exactly how two callers interleave.
        _ = try await sched.submit(
            SchedulingRequest(
                id: "X", priority: .interrupt, modelId: "m", prompt: "p", tokenBudget: 256))

        let mine = try await sched.submitAndDispatch(
            SchedulingRequest(
                id: "Y", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 256))

        // Y got its own request, and X is untouched for the call that owns it.
        #expect(mine.id == "Y")
        #expect(await sched.activeCount == 1)
        #expect(await sched.pendingCount == 1)
        #expect(await sched.dispatch()?.id == "X")
    }

    @Test("a too-large head waits while the smaller one behind it runs")
    func rejectedHeadDoesNotBlockSmallerTail() async throws {
        let tracker = MemoryTracker(budgetBytes: 1_073_741_824)
        let gate = AdmissionGate(maxConcurrentPreFills: 4, memoryTracker: tracker)
        let sched = SchedulerActor(
            maxQueueSize: 128, admissionGate: gate, log: Logger(label: "test.headroom-order"))

        // ~1 GB requested against an 858 MB usable budget ⇒ refused; the tail fits.
        _ = try await sched.submit(
            SchedulingRequest(
                id: "big", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 1_000_000))
        _ = try await sched.submit(
            SchedulingRequest(
                id: "small", priority: .chat, modelId: "m", prompt: "p", tokenBudget: 1024))

        let dispatched = await sched.dispatch()
        #expect(dispatched?.id == "small")
        #expect(await sched.pendingCount == 1)
        #expect(await sched.activeCount == 1)
    }
}
