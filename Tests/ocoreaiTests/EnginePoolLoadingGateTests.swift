// EnginePoolLoadingGateTests.swift — Regression gate for acquire()'s wait on an
// in-flight model load: a request must be released when the load finishes, not
// when the wait window expires.
//
// Background (10-13): waitForLoading() slept `Task.sleep(until: deadline)`, i.e.
// the whole 120 s window, instead of one poll interval. Every first chat request
// that arrived while boot prewarm held the loading slot therefore parked for the
// full window — 120.5/120.7/120.5/120.6/121.1 s across five cold processes, even
// though the model was ready after ~8 s.

import Foundation
import Logging
import Testing

@testable import ocoreai

private func makeGatePool() -> EnginePool {
    var config = EnginePoolConfig.default
    config.defaultModelId = ""
    return EnginePool(
        config: config,
        logger: Logger(label: "test.enginepool.loadinggate"),
        tokenizerManager: TokenizerManager()
    )
}

private func elapsedSeconds(_ start: ContinuousClock.Instant) -> Double {
    let d = start.duration(to: .now)
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

@Suite("EnginePool loading gate — release timing")
struct EnginePoolLoadingGateTests {

    /// The load owner releases the slot after ~150 ms. A parked waiter must come
    /// back promptly. Before the fix this waited the full 120 s window.
    @Test("a waiter is released when the load finishes, not at the deadline")
    func releasedWhenLoadFinishes() async throws {
        let pool = makeGatePool()
        let modelId = "test/gate-released"

        await pool.setLoadingForTesting(modelId, loading: true)
        #expect(await pool.isModelLoading(modelId))

        let start = ContinuousClock.now
        async let release: Void = {
            try await Task.sleep(for: .milliseconds(150))
            await pool.setLoadingForTesting(modelId, loading: false)
        }()
        try await pool.waitForLoading(modelId: modelId, timeoutSeconds: 120)
        let elapsed = elapsedSeconds(start)
        try await release

        // Prompt release: a few poll intervals after the slot came free, not the
        // 120 s window. Upper bound stays loose so a loaded CI box cannot flake it.
        #expect(elapsed >= 0.1, "expected at least one poll tick before release")
        #expect(elapsed < 5.0, "waiter parked for \(elapsed)s — gate slept to the deadline")
        #expect(!(await pool.isModelLoading(modelId)))
    }

    /// Nothing in flight → no sleep at all.
    @Test("no wait when the model is not loading")
    func noWaitWhenIdle() async throws {
        let pool = makeGatePool()
        let start = ContinuousClock.now
        try await pool.waitForLoading(modelId: "test/gate-idle", timeoutSeconds: 120)
        let elapsed = elapsedSeconds(start)
        #expect(elapsed < 1.0, "idle acquire slept \(elapsed)s")
    }

    /// The gate keys on the model id: a load on one model must not hold another.
    @Test("a load on one model does not park a request for another")
    func keyedByModelId() async throws {
        let pool = makeGatePool()
        await pool.setLoadingForTesting("test/gate-blocked", loading: true)
        defer { Task { await pool.setLoadingForTesting("test/gate-blocked", loading: false) } }

        let start = ContinuousClock.now
        try await pool.waitForLoading(modelId: "test/gate-free", timeoutSeconds: 120)
        let elapsed = elapsedSeconds(start)
        #expect(elapsed < 1.0, "unrelated model parked for \(elapsed)s")
    }

    /// A load that never finishes still fails the wait at the window edge, with
    /// the transient error the API layer turns into "retry" rather than a hang.
    @Test("an owner that never releases trips the deadline, at the deadline")
    func deadlineStillHonored() async throws {
        let pool = makeGatePool()
        let modelId = "test/gate-stuck"
        await pool.setLoadingForTesting(modelId, loading: true)
        defer { Task { await pool.setLoadingForTesting(modelId, loading: false) } }

        let start = ContinuousClock.now
        do {
            try await pool.waitForLoading(modelId: modelId, timeoutSeconds: 1)
            Issue.record("expected AppError.modelLoading after the wait window")
        } catch let error as AppError {
            guard case .modelLoading(let failedId) = error else {
                Issue.record("expected .modelLoading, got \(error)")
                return
            }
            #expect(failedId == modelId)
        }
        let elapsed = elapsedSeconds(start)
        #expect(elapsed >= 0.9, "wait gave up after \(elapsed)s, before its 1 s window")
        #expect(elapsed < 3.0, "wait overshoot the 1 s window: \(elapsed)s")
    }

    /// Cancellation must interrupt a parked waiter immediately — polling must not
    /// turn cancellation into another full-window stall.
    @Test("a parked waiter honours cancellation promptly")
    func cancellationInterruptsWait() async throws {
        let pool = makeGatePool()
        let modelId = "test/gate-cancel"
        await pool.setLoadingForTesting(modelId, loading: true)
        defer { Task { await pool.setLoadingForTesting(modelId, loading: false) } }

        let waiter = Task { try await pool.waitForLoading(modelId: modelId, timeoutSeconds: 120) }
        try await Task.sleep(for: .milliseconds(150))
        let start = ContinuousClock.now
        waiter.cancel()
        do {
            try await waiter.value
            Issue.record("cancelled waiter returned without error")
        } catch is CancellationError {
            let elapsed = elapsedSeconds(start)
            #expect(elapsed < 1.0, "cancellation took \(elapsed)s to interrupt the wait")
        }
    }
}
