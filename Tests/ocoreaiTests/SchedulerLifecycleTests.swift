// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Scheduler lifecycle tests — submit → dispatch → complete/fail/interrupt
/// Verifies: memory tracking, OOM protection, priority queue, release-on-completion

import Foundation
import Logging
import Testing
import ocoreaiTestUtilities

@testable import ocoreai

@Suite("SchedulerActor Lifecycle")
struct SchedulerLifecycleTests {

    @Test("submit → dispatch → complete 完整生命周期")
    func testSubmitDispatchComplete() async {
        let sched = SchedulerActor(maxQueueSize: 128, log: Logger(label: "test.lifecycle"))

        let request = SchedulingRequest(
            id: "req-1",
            priority: .chat,
            modelId: "llama-3.1-8b",
            prompt: "hello world",
            tokenBudget: 4096
        )

        // 1. Submit → pending
        let did = try? await sched.submit(request)
        #expect(did != nil)
        #expect(await sched.pendingCount == 1)
        #expect(await sched.activeCount == 0)

        // 2. Dispatch → inferring
        let dispatched = await sched.dispatch()
        #expect(dispatched != nil)
        #expect(dispatched?.id == "req-1")
        #expect(await sched.pendingCount == 0)
        #expect(await sched.activeCount == 1)

        // 3. Complete → done
        await sched.complete("req-1")
        #expect(await sched.activeCount == 0)
    }

    @Test("优先队列：P0 interrupt 在 P1 chat 之前 dispatch")
    func testPriorityOrdering() async {
        let sched = SchedulerActor(maxQueueSize: 128, log: Logger(label: "test.priority"))

        let low = SchedulingRequest(
            id: "bg", priority: .background, modelId: "m", prompt: "bg", tokenBudget: 2048)
        let high = SchedulingRequest(
            id: "urgent", priority: .interrupt, modelId: "m", prompt: "urgent", tokenBudget: 2048)

        _ = try? await sched.submit(low)
        _ = try? await sched.submit(high)

        let first = await sched.dispatch()
        #expect(first?.id == "urgent")

        let second = await sched.dispatch()
        #expect(second?.id == "bg")
    }

    @Test("fail → 状态变更 + memory release")
    func testFailWithStateChange() async {
        let tracker = MemoryTracker(budgetBytes: 1_048_576)
        let sched = SchedulerActor(
            maxQueueSize: 128, memoryTracker: tracker, log: Logger(label: "test.fail"))

        let req = SchedulingRequest(
            id: "fail-me", priority: .chat, modelId: "m", prompt: "test", tokenBudget: 4096)
        _ = try? await sched.submit(req)
        _ = await sched.dispatch()

        #expect(await sched.activeCount == 1)
        let usageBefore = await tracker.usageFraction()
        await sched.fail("fail-me", with: "model not loaded")
        let usageAfter = await tracker.usageFraction()

        #expect(usageAfter < usageBefore)
    }

    @Test("interrupt → 活跃请求立即释放")
    func testInterruptActiveRequest() async {
        let sched = SchedulerActor(maxQueueSize: 128, log: Logger(label: "test.interrupt"))

        let req = SchedulingRequest(
            id: "intr", priority: .chat, modelId: "m", prompt: "interruptible", tokenBudget: 4096)
        _ = try? await sched.submit(req)
        _ = await sched.dispatch()
        #expect(await sched.activeCount == 1)

        let interrupted = await sched.interrupt("intr")
        #expect(interrupted != nil)
        #expect(interrupted?.id == "intr")
        #expect(await sched.activeCount == 0)
    }

    @Test("queue full → SchedulerError.queueFull")
    func testQueueFull() async {
        let sched = SchedulerActor(maxQueueSize: 2, log: Logger(label: "test.full"))

        _ = try? await sched.submit(
            SchedulingRequest(id: "a", priority: .chat, modelId: "m", prompt: "a", tokenBudget: 512)
        )
        _ = try? await sched.submit(
            SchedulingRequest(id: "b", priority: .chat, modelId: "m", prompt: "b", tokenBudget: 512)
        )

        do {
            _ = try await sched.submit(
                SchedulingRequest(
                    id: "c", priority: .chat, modelId: "m", prompt: "c", tokenBudget: 512))
            #expect(Bool(false))
        } catch {
            #expect(error as? SchedulerError == .queueFull, "Expected .queueFull, got: \(error)")
        }
    }

    // ── release on completion ────────────────────────────────────────────────
    // The actor lives as long as the server, so anything keyed by a fresh request id that
    // survives its completion is a leak (the pit references paid for: hermes-agent
    // `bound the pending-created-topics cache`). The table that leaked used to be capped at
    // 256; it has since been deleted outright — nothing is retained per finished request, so
    // the honest assertion is that *nothing* accumulates: after 300 full cycles the queue, the
    // active set and the tracker's reservation are all back to zero.

    @Test("300 full cycles leave no queue residue and no held reservation")
    func nothingAccumulatesAcrossThreeHundredRequests() async throws {
        let tracker = MemoryTracker(budgetBytes: 1 << 40)
        let sched = SchedulerActor(
            maxQueueSize: 128, memoryTracker: tracker, log: Logger(label: "test.bound"))

        for i in 0 ..< 300 {
            let id = "req-\(i)"
            _ = try await sched.submit(
                SchedulingRequest(
                    id: id, priority: .chat, modelId: "m", prompt: "p", tokenBudget: 512))
            let dispatched = await sched.dispatch()
            #expect(dispatched?.id == id)
            await sched.complete(id)
        }

        #expect(await sched.pendingCount == 0)
        #expect(await sched.activeCount == 0)
        #expect(await tracker.usageFraction() == 0, "every reservation must be released")
    }
}
