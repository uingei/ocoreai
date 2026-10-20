// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PipelineGateTests.swift — the backpressure gate's accounting, and exactly-once waiter
/// consumption.
///
/// This suite exists because the class used to sit inside `CoreAIPipelinedEngine.swift`'s single
/// file-level `#if canImport(CoreAI)`, which deleted it on the macOS 26 SDK — so the comment
/// claiming "exercised by `PipelineGateTests`" described a suite that could not compile, let
/// alone run, on any runner this project has (CLT SDK 26.5 has no CoreAI; CI is macos-26). The
/// type now lives in `Engine/PipelineGate.swift`, gated on what its body actually needs —
/// `os.OSAllocatedUnfairLock`, available at the package floor — so these tests compile and run on
/// the CLT route on this macOS 26 host.
///
/// The invariant worth pinning came across the language boundary from codex #55581 (`e8aa7c1678`,
/// read 10-20): a one-shot waiter must leave the state before it is consumed. codex polled a
/// `oneshot` receiver while it was still stored, so a closed receiver stayed in session state and
/// a later `await` panicked instead of falling back. The local equivalents are (a) resuming a
/// waiter that is still in `waiters` — a double resume traps at runtime — and (b) handing out a
/// permit nobody holds, which turns the gate back into the encode backlog it exists to bound.
///
/// What is NOT asserted, stated rather than hidden: FIFO *order* of woken waiters. The queue is
/// FIFO by construction (`removeFirst`), but the order in which three `Task`s reach `acquire` is
/// not something the test controls, so a strict ordering assertion here would be flaky rather
/// than meaningful. The tests assert the properties that hold regardless: every queued waiter is
/// woken exactly once, and the slot counts never exceed capacity.

import Foundation
import Testing

@testable import ocoreai

@Suite("PipelineGate — slot accounting and exactly-once consumption")
struct PipelineGateTests {

    /// Polls one interval at a time (never to a deadline — AGENTS.md § Concurrency) until
    /// `waiters` reaches `count`, and reports whether it got there.
    private static func waitUntil(_ gate: PipelineGate, waiters count: Int) async -> Bool {
        var waitedMs = 0
        while gate._waitersForTesting < count && waitedMs < 2000 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            waitedMs += 5
        }
        return gate._waitersForTesting >= count
    }

    @Test("capacity floors at 1 — acquire takes a slot, release gives it back")
    func capacityFloor() async {
        let gate = PipelineGate(capacity: 0)
        await gate.acquire()
        #expect(gate._inFlightForTesting == 1)
        gate.release()
        #expect(gate._inFlightForTesting == 0)
        #expect(gate._waitersForTesting == 0)
    }

    @Test("fills to capacity, queues the next acquire, and transfers the slot on release")
    func transferOnRelease() async throws {
        let gate = PipelineGate(capacity: 2)
        await gate.acquire()
        await gate.acquire()
        #expect(gate._inFlightForTesting == 2)

        let queued = Task { await gate.acquire() }
        // Premise floor: without a real waiter the rest of this test would be vacuous.
        #expect(
            await Self.waitUntil(gate, waiters: 1),
            "the third acquire never queued — it went straight through")
        #expect(gate._inFlightForTesting == 2, "capacity was exceeded while a waiter was queued")

        gate.release()
        await queued.value
        // The woken waiter took the released slot: count unchanged, queue empty, one resume only.
        #expect(gate._inFlightForTesting == 2)
        #expect(gate._waitersForTesting == 0)

        gate.release()
        gate.release()
        #expect(gate._inFlightForTesting == 0)
    }

    @Test("a release nobody holds cannot mint permits")
    func unbalancedReleaseCannotInflateCapacity() async throws {
        let gate = PipelineGate(capacity: 1)
        gate.release()  // nothing is held — must not go negative
        #expect(gate._inFlightForTesting == 0)

        await gate.acquire()
        #expect(gate._inFlightForTesting == 1)

        // capacity 1 still means 1: the phantom permit from the stray release must not let a
        // second encode through.
        let queued = Task { await gate.acquire() }
        #expect(
            await Self.waitUntil(gate, waiters: 1),
            "a stray release handed out a permit past capacity")
        gate.release()
        await queued.value
        gate.release()
        #expect(gate._inFlightForTesting == 0)
    }

    @Test("concurrent holders all pass through exactly once and accounting returns to zero")
    func conservationUnderContention() async throws {
        let gate = PipelineGate(capacity: 3)
        let holders = 12
        let completed = SentinelCounter()

        var tasks: [Task<Void, Never>] = []
        for _ in 0 ..< holders {
            tasks.append(
                Task {
                    await gate.acquire()
                    try? await Task.sleep(nanoseconds: 2_000_000)
                    gate.release()
                    await completed.bump()
                })
        }

        // Peak contention, observed while the work runs: proves the queue was actually used
        // rather than the whole test passing because nothing ever blocked.
        var peakWaiters = 0
        var waitedMs = 0
        while await completed.count() < holders && waitedMs < 5000 {
            peakWaiters = max(peakWaiters, gate._waitersForTesting)
            try? await Task.sleep(nanoseconds: 5_000_000)
            waitedMs += 5
        }
        for task in tasks { await task.value }

        #expect(await completed.count() == holders)
        #expect(
            peakWaiters >= 1,
            "no contention ever formed — capacity 3 with 12 holders queued nothing")
        #expect(peakWaiters <= holders - 1)
        #expect(gate._inFlightForTesting == 0)
        #expect(gate._waitersForTesting == 0)
    }
}

/// Counts completions off the gate so the stress test can wait on progress, not on sleep.
actor SentinelCounter {
    private var n = 0
    func bump() { n += 1 }
    func count() -> Int { n }
}
