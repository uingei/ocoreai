import Foundation
import Testing

@testable import ocoreai

/// Regression (一对话就挂): headroom = budget − OUR reservations ONLY.
/// Whole-machine load (active+inactive+wired+compressed) was previously
/// subtracted from our cap, collapsing headroom to 0 whenever the box was
/// loaded, then rejecting every request. System pressure stays advisory
/// (level/routing) — never the per-request gate. Hermetic via the
/// systemUsageOverride seam, so results are independent of live machine load.

@Suite("AdmissionGate: whole-machine load must NOT gate headroom")
struct AdmissionGateHeadroomTests {

    @Test("60 GiB system load, 4 GiB cap => a 2 MiB chat request is admitted")
    func heavySystemLoadStillAdmits() async {
        let (gate, _) = Self.makeGate(
            budget: 1 << 32,  // 4 GiB cap
            systemLoad: 60 << 30  // 60 GiB whole-machine load
        )
        let result = await gate.check(
            requestId: "chat-1",
            inputTokens: 1000,  //  cost = (1000+1000) * 1KB = 2 MiB
            maxOutputTokens: 1000
        )
        #expect(result.admitted)
        #expect(result.reason == nil)
    }

    @Test("0 GiB system load => same request admits (baseline sanity)")
    func idleSystemAdmits() async {
        let (gate, _) = Self.makeGate(budget: 1 << 32, systemLoad: 0)
        let result = await gate.check(
            requestId: "chat-0",
            inputTokens: 1000,
            maxOutputTokens: 1000
        )
        #expect(result.admitted)
    }

    @Test("Our own reservations still gate: near-budget fill rejects a new big request")
    func ownReservationsGate() async {
        let budget = UInt64(1) << 30  // 1 GiB cap
        let (gate, _) = Self.makeGate(budget: budget, systemLoad: 60 << 30)
        // Fill 800 MiB of our own working set → 224 MiB left in the cap.
        await gate.admit("r1", inputTokens: 409_600, maxOutputTokens: 409_600)  // 800 MiB reserved
        // A 390 MiB request exceeds the 224 MiB left (and its 15% abort margin).
        let result = await gate.check(
            requestId: "r2",
            inputTokens: 200_000,  // (200000 + 200000) * 1KB = 390 MiB
            maxOutputTokens: 200_000
        )
        #expect(!result.admitted)
        #expect(
            result.reason?.contains("Budget") ?? false,
            "expected a Budget rejection, got: \(result.reason ?? "nil")")
    }

    @Test("After release, a request that was rejected is admitted again")
    func releaseRestoresHeadroom() async {
        let budget = UInt64(1) << 30  // 1 GiB cap
        let (gate, _) = Self.makeGate(budget: budget, systemLoad: 60 << 30)
        // 800 MiB reserved → 390 MiB request is rejected…
        await gate.admit("r1", inputTokens: 409_600, maxOutputTokens: 409_600)
        let blocked = await gate.check(
            requestId: "r2", inputTokens: 200_000, maxOutputTokens: 200_000)
        #expect(!blocked.admitted)
        // …but freeing those 800 MiB brings the 390 MiB request back under the cap.
        await gate.release("r1")
        let admitted = await gate.check(
            requestId: "r2", inputTokens: 200_000, maxOutputTokens: 200_000)
        #expect(
            admitted.admitted, "expected admission after release, got: \(admitted.reason ?? "nil")")
    }

    @Test("Admission cost estimate is exact: (input + output) * KBPerToken")
    func costEstimateExact() async {
        let (gate, _) = Self.makeGate(budget: 1 << 32, systemLoad: 60 << 30)
        let cost = await gate.estimatedCost(inputTokens: 3, maxOutputTokens: 4)
        #expect(cost == 7 * 1024)  // 7 tokens * 1KB/token (bits4 q4_0)
    }
}

extension AdmissionGateHeadroomTests {
    /// Real gate + real MemoryTracker, with the whole-machine usage reading
    /// pinned via the `systemUsageOverride` seam (production default is nil →
    /// live `host_statistics64`). Returns (gate, tracker) so tests can also
    /// assert tracker-level invariants independently of the gate.
    static func makeGate(
        budget: UInt64,
        systemLoad: UInt64
    ) -> (gate: AdmissionGate, tracker: MemoryTracker) {
        let tracker = MemoryTracker(
            budgetBytes: budget,
            systemUsageOverride: { systemLoad }
        )
        let gate = AdmissionGate(
            maxConcurrentPreFills: 16,  // jitter off — isolate the budget math
            memoryTracker: tracker
        )
        return (gate, tracker)
    }
}
