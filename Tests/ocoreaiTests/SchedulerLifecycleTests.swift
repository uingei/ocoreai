// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Scheduler lifecycle tests — submit → dispatch → complete/fail/interrupt
/// Verifies: memory tracking, OOM protection, priority queue, request states

#if canImport(Testing)
import Testing
import Foundation
import Logging
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

        // 4. Status query
        let status = await sched.status(of: "req-1")
        #expect(status != nil)
        #expect(status?.state == .completed)
    }

    @Test("优先队列：P0 interrupt 在 P1 chat 之前 dispatch")
    func testPriorityOrdering() async {
        let sched = SchedulerActor(maxQueueSize: 128, log: Logger(label: "test.priority"))

        let low = SchedulingRequest(id: "bg", priority: .background, modelId: "m", prompt: "bg", tokenBudget: 2048)
        let high = SchedulingRequest(id: "urgent", priority: .interrupt, modelId: "m", prompt: "urgent", tokenBudget: 2048)

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
        let sched = SchedulerActor(maxQueueSize: 128, memoryTracker: tracker, log: Logger(label: "test.fail"))

        let req = SchedulingRequest(id: "fail-me", priority: .chat, modelId: "m", prompt: "test", tokenBudget: 4096)
        _ = try? await sched.submit(req)
        _ = await sched.dispatch()

        #expect(await sched.activeCount == 1)
        let usageBefore = await tracker.usageFraction()
        await sched.fail("fail-me", with: "model not loaded")
        let usageAfter = await tracker.usageFraction()

        #expect(usageAfter < usageBefore)
        let status = await sched.status(of: "fail-me")
        #expect(status?.state == .failed)
    }

    @Test("interrupt → 活跃请求立即释放")
    func testInterruptActiveRequest() async {
        let sched = SchedulerActor(maxQueueSize: 128, log: Logger(label: "test.interrupt"))

        let req = SchedulingRequest(id: "intr", priority: .chat, modelId: "m", prompt: "interruptible", tokenBudget: 4096)
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

        _ = try? await sched.submit(SchedulingRequest(id: "a", priority: .chat, modelId: "m", prompt: "a", tokenBudget: 512))
        _ = try? await sched.submit(SchedulingRequest(id: "b", priority: .chat, modelId: "m", prompt: "b", tokenBudget: 512))

        do {
            _ = try await sched.submit(SchedulingRequest(id: "c", priority: .chat, modelId: "m", prompt: "c", tokenBudget: 512))
            #expect(Bool(false))
        } catch {
            #expect(error is SchedulerError)
        }
    }

    @Test("snapshot → 调度器健康状态")
    func testSnapshot() async {
        let sched = SchedulerActor(maxQueueSize: 128, log: Logger(label: "test.snapshot"))

        let req = SchedulingRequest(id: "snap", priority: .chat, modelId: "m", prompt: "snap test", tokenBudget: 4096)
        _ = try? await sched.submit(req)
        _ = await sched.dispatch()

        let snap = await sched.snapshot()
        #expect(snap.inferringCount == 1)
        #expect(snap.totalRequests >= 1)
    }
}
#endif
