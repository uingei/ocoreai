// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AdmissionGate Behavioral Tests — budget control, jitter protection,
/// reservation lifecycle, and emergency abort.
///
/// Methodology matches upstream pattern:
/// - KVCacheTests: parameterized budget thresholds + capacity overflow
/// - ChatSessionTests: interrupt + resume lifecycle
///
/// Focus on invariants that prevent OOM when AdmissionGate is the
/// last line of defense between a request and GPU memory exhaustion.

import Testing
import Foundation
@testable import ocoreai

// MARK: - AdmissionGate: reservation lifecycle

@Suite("AdmissionGate: reservation admission → release lifecycle")
struct AdmissionGateReservationTests {

    @Test("Empty gate admits any request")
    func emptyGateAdmits() async {
        // No MemoryTracker → defer to downstream OOMGuard (infinite headroom)
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil
        )

        let result = await gate.check(
            requestId: "req-1",
            inputTokens: 4096,
            maxOutputTokens: 2048
        )

        #expect(result.admitted)
        #expect(result.reason == nil)
    }

    @Test("estimateCost matches formula: (input + output) * KBPerToken")
    func estimatedCostFormula() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil
        )

        // KBPerToken = 1024 bytes (1KB)
        let cost = await gate.estimatedCost(inputTokens: 100, maxOutputTokens: 200)
        #expect(cost == UInt64(300 * 1024))
    }

    @Test("Admit reserves memory, release frees it")
    func admitThenRelease() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil
        )

        await gate.admit("r1", inputTokens: 100, maxOutputTokens: 100)
        let state1 = await gate.state()
        #expect(state1.active == 1)
        #expect(state1.requests == 1)
        #expect(state1.reserved > 0)

        await gate.release("r1")
        let state2 = await gate.state()
        #expect(state2.active == 0)
        #expect(state2.requests == 0)
        #expect(state2.reserved == 0)
    }

    @Test("Release of unknown request ID is safe (no-op)")
    func releaseUnknownId() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil
        )

        await gate.release("nonexistent")
        let state = await gate.state()
        #expect(state.active == 0)
        #expect(state.reserved == 0)
    }

    @Test("Multiple admissions accumulate, releases decrement correctly")
    func multipleAdmissions() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 16,
            memoryTracker: nil
        )

        await gate.admit("r1", inputTokens: 100, maxOutputTokens: 100)
        await gate.admit("r2", inputTokens: 200, maxOutputTokens: 200)
        await gate.admit("r3", inputTokens: 50, maxOutputTokens: 50)

        let s1 = await gate.state()
        #expect(s1.active == 3)
        #expect(s1.requests == 3)

        // Release middle — s1.reserved should decrease by r2's cost
        let r2cost = await gate.estimatedCost(inputTokens: 200, maxOutputTokens: 200)
        await gate.release("r2")

        let s2 = await gate.state()
        #expect(s2.active == 2)
        #expect(s2.requests == 2)
        #expect(s2.reserved == s1.reserved - r2cost)
    }
}

// MARK: - AdmissionGate: jitter protection

@Suite("AdmissionGate: jitter protection — maxConcurrentPreFills guard")
struct AdmissionGateJitterTests {

    @Test("Jitter rejects when activePreFills >= maxConcurrentPreFills")
    func jitterBlocksAtLimit() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 2,
            memoryTracker: nil
        )

        await gate.admit("r1", inputTokens: 100, maxOutputTokens: 100)
        await gate.admit("r2", inputTokens: 100, maxOutputTokens: 100)

        // Third request should be rejected by jitter protection
        let result = await gate.check(
            requestId: "r3",
            inputTokens: 100,
            maxOutputTokens: 100
        )

        #expect(!result.admitted)
        #expect(result.reason?.contains("Jitter") == true)
    }

    @Test("Jitter unblocks after release")
    func jitterUnblocksAfterRelease() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 2,
            memoryTracker: nil
        )

        await gate.admit("r1", inputTokens: 100, maxOutputTokens: 100)
        await gate.admit("r2", inputTokens: 100, maxOutputTokens: 100)

        // Blocked
        let blocked = await gate.check(
            requestId: "r3",
            inputTokens: 100,
            maxOutputTokens: 100
        )
        #expect(!blocked.admitted)

        // Release one → unblock
        await gate.release("r1")
        let unblocked = await gate.check(
            requestId: "r3",
            inputTokens: 100,
            maxOutputTokens: 100
        )
        #expect(unblocked.admitted)
    }

    @Test("Jitter limit = 1: only one concurrent pre-fill")
    func jitterLimitOne() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 1,
            memoryTracker: nil
        )

        await gate.admit("r1", inputTokens: 100, maxOutputTokens: 100)

        let result = await gate.check(
            requestId: "r2",
            inputTokens: 100,
            maxOutputTokens: 100
        )

        #expect(!result.admitted)
        #expect(result.reason?.contains("Jitter") == true)
    }
}

// MARK: - AdmissionGate: emergency abort

@Suite("AdmissionGate: emergency abort — OOMGuard cascade")
struct AdmissionGateEmergencyTests {

    @Test("Emergency abort clears all reservations")
    func emergencyClearsAll() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 16,
            memoryTracker: nil
        )

        await gate.admit("r1", inputTokens: 1000, maxOutputTokens: 500)
        await gate.admit("r2", inputTokens: 2000, maxOutputTokens: 1000)
        await gate.admit("r3", inputTokens: 500, maxOutputTokens: 250)

        let before = await gate.state()
        #expect(before.active == 3)
        #expect(before.requests == 3)
        #expect(before.reserved > 0)

        await gate.emergencyAbort()

        let after = await gate.state()
        #expect(after.active == 0)
        #expect(after.requests == 0)
        #expect(after.reserved == 0)
    }

    @Test("Post-emergency: gate admits new requests normally")
    func postEmergencyAdmits() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil
        )

        await gate.admit("r1", inputTokens: 100, maxOutputTokens: 100)
        await gate.emergencyAbort()

        let result = await gate.check(
            requestId: "r2",
            inputTokens: 100,
            maxOutputTokens: 100
        )

        #expect(result.admitted)
    }
}

// MARK: - AdmissionGate: idempotent check for already-reserved requests

@Suite("AdmissionGate: idempotency — duplicate check for same requestId")
struct AdmissionGateIdempotencyTests {

    @Test("check() returns .ok when request is already reserved")
    func duplicateCheckReturnsOK() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil
        )

        // First check should admit
        let r1 = await gate.check(
            requestId: "r1",
            inputTokens: 100,
            maxOutputTokens: 100
        )
        #expect(r1.admitted)

        // Admit the request
        await gate.admit("r1", inputTokens: 100, maxOutputTokens: 100)

        // Second check for same ID should return .ok (already reserved)
        // — this is the continuation path: the request was admitted, now
        // downstream is checking again before dispatch. Must not re-estimate.
        let r2 = await gate.check(
            requestId: "r1",
            inputTokens: 100,
            maxOutputTokens: 100
        )
        #expect(r2.admitted)
        #expect(r2.reason == nil)
    }

    @Test("Duplicate check bypasses jitter — same ID is a continuation, not new")
    func duplicateCheckBypassesJitter() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 1,
            memoryTracker: nil
        )

        await gate.admit("r1", inputTokens: 100, maxOutputTokens: 100)
        // Gate is full (1/1)

        // New request blocked by jitter
        let blocked = await gate.check(
            requestId: "r2",
            inputTokens: 100,
            maxOutputTokens: 100
        )
        #expect(!blocked.admitted)

        // But re-check of existing request succeeds (continuation path)
        let ok = await gate.check(
            requestId: "r1",
            inputTokens: 100,
            maxOutputTokens: 100
        )
        #expect(ok.admitted)
    }
}

// MARK: - AdmissionGate: budget enforcement (with MemoryTracker)

@Suite("AdmissionGate: budget enforcement with MemoryTracker")
struct AdmissionGateBudgetTests {

    @Test("State reporting includes budget when MemoryTracker present")
    func stateReportsBudget() async {
        let eightGB = UInt64(8 * 1024 * 1024 * 1024)
        let tracker = MemoryTracker(budgetBytes: eightGB)
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: tracker
        )

        let state = await gate.state()
        #expect(state.totalBudget == eightGB)
    }

    @Test("State tracking: budget=0 when no tracker")
    func stateNoTrackerReportsZeroBudget() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil
        )

        let state = await gate.state()
        #expect(state.totalBudget == 0)
    }

    @Test("Admission after admit increments active count in state")
    func admitIncrementsState() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil
        )

        #expect(await gate.state().active == 0)
        await gate.admit("x", inputTokens: 100, maxOutputTokens: 100)
        #expect(await gate.state().active == 1)
    }

    @Test("Reserved bytes never go negative — underflow protection")
    func reservedBytesNoUnderflow() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil
        )

        // Admit large, release small — should not underflow
        await gate.admit("big", inputTokens: 5000, maxOutputTokens: 5000)
        // Try to release something else that doesn't exist, activePreFills
        // could conceptually reach negative but release of unknown is a no-op
        await gate.release("nonexistent")

        let state = await gate.state()
        #expect(state.reserved > 0)
        #expect(state.active == 1)
    }
}
