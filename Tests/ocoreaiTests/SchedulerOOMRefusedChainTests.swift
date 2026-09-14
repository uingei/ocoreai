// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Live chain test — real ``OOMGuard`` + real ``SchedulerActor`` (no mocks of
/// the actors under test): the refusal must surface the budget snapshot
/// captured at the throw site, not a static message.
@_spi(Testing) import Foundation
import Testing

@testable import ocoreai

@MainActor
@Suite("Scheduler OOM refusal carries live budget snapshot")
struct SchedulerOOMRefusedChainTests {
    @Test("refusal carries used/budget from the snapshot at throw time")
    func liveChainRefusalCarriesBudget() async throws {
        let oomGuard = OOMGuard()
        await oomGuard.setLevel(.refuse)
        await oomGuard.updateUsage(
            14 * 1_073_741_824,
            budget: 16 * 1_073_741_824
        )

        let scheduler = SchedulerActor(oomGuard: oomGuard)
        let request = SchedulingRequest(
            id: "oom-chain-1", priority: .chat, modelId: "test", prompt: "oom probe"
        )

        do {
            _ = try await scheduler.submit(request)
            Issue.record("submit should throw while OOMGuard is in refuse")
        } catch let error as SchedulerError {
            guard case .oomRefused(let used, let budget) = error else {
                // swift-format-ignore: multiple
                Issue.record("expected oomRefused, got \(error)")
                return
            }
            #expect(used == 14, "usedGB must round 14.0 → 14")
            #expect(budget == 16, "budgetGB must round 16.0 → 16")
            let desc = error.errorDescription ?? ""  // swift-format-ignore: multiple
            #expect(desc.contains("14"), "description carries used value: \(desc)")
            #expect(desc.contains("16"), "description carries budget value: \(desc)")
        }
    }

    @Test("acceptance path unchanged — guard not refusing admits")
    func liveChainAcceptsWhenNotRefused() async throws {
        let oomGuard = OOMGuard()
        await oomGuard.setLevel(.bits4)
        let scheduler = SchedulerActor(oomGuard: oomGuard)
        let request = SchedulingRequest(
            id: "oom-chain-ok", priority: .chat, modelId: "test", prompt: "ok probe"
        )
        let id = try await scheduler.submit(request)
        #expect(id == "oom-chain-ok")
    }
}
