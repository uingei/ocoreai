// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineLifecycleBehavioralTests.swift — State machine + circuit breaker
///
/// Methodology: upstream-style behavioral invariants.
/// - ChatSessionTests: real mode transitions (streaming→tool→interrupt)
/// - KVCacheTests: parameterized across 6+ cache types, numeric precision
///
/// Focus: EngineLifecycleState transitions + EngineCircuitBreaker guards.
/// These are the safety nets that prevent crash-loops on GPU OOM.

import Testing
@testable import ocoreai
import Foundation

// MARK: - EngineLifecycleState transition invariants

@Suite("EngineLifecycleState: transition guards and display properties")
struct EngineLifecycleStateTests {

    @Test("isHealthy: only ready and degraded accept requests")
    func isHealthyStates() {
        #expect(EngineLifecycleState.ready.isHealthy == true)
        #expect(EngineLifecycleState.degraded.isHealthy == true)
        #expect(EngineLifecycleState.idle.isHealthy == false)
        #expect(EngineLifecycleState.starting.isHealthy == false)
        #expect(EngineLifecycleState.stopping.isHealthy == false)
        #expect(EngineLifecycleState.error.isHealthy == false)
    }

    @Test("isTransitioning: only starting and stopping are transitional")
    func isTransitioningStates() {
        #expect(EngineLifecycleState.starting.isTransitioning == true)
        #expect(EngineLifecycleState.stopping.isTransitioning == true)
        #expect(EngineLifecycleState.idle.isTransitioning == false)
        #expect(EngineLifecycleState.ready.isTransitioning == false)
        #expect(EngineLifecycleState.degraded.isTransitioning == false)
        #expect(EngineLifecycleState.error.isTransitioning == false)
    }

    @Test("displayLabel returns human-readable status for each state")
    func displayLabels() {
        #expect(EngineLifecycleState.idle.displayLabel == "Idle")
        #expect(EngineLifecycleState.starting.displayLabel == "Starting...")
        #expect(EngineLifecycleState.ready.displayLabel == "Ready")
        #expect(EngineLifecycleState.degraded.displayLabel == "Degraded")
        #expect(EngineLifecycleState.stopping.displayLabel == "Stopping...")
        #expect(EngineLifecycleState.error.displayLabel == "Circuit Open")
    }

    @Test("statusIcon maps to SF Symbols")
    func statusIcons() {
        #expect(EngineLifecycleState.idle.statusIcon == "circle.dashed")
        #expect(EngineLifecycleState.starting.statusIcon == "arrow.triangle.2.circlepath")
        #expect(EngineLifecycleState.ready.statusIcon == "checkmark.circle.fill")
        #expect(EngineLifecycleState.degraded.statusIcon == "exclamationmark.triangle.fill")
        #expect(EngineLifecycleState.stopping.statusIcon == "pause.circle.fill")
        #expect(EngineLifecycleState.error.statusIcon == "xmark.octagon.fill")
    }

}

// MARK: - EngineCircuitBreaker behavioral invariants

@Suite("EngineCircuitBreaker: consecutive failure threshold and cooldown")
struct EngineCircuitBreakerTests {

    @Test("Circuit is closed on initialization")
    func initialCircuitClosed() {
        let breaker = EngineCircuitBreaker(maxConsecutiveFailures: 3, cooldownSeconds: 60)
        #expect(breaker.isCircuitOpen == false)
        #expect(breaker.failureCount == 0)
        #expect(breaker.cooldownRemaining() == 0)
    }

    @Test("recordSuccess resets failure counter")
    func successResetsCount() {
        let breaker = EngineCircuitBreaker(maxConsecutiveFailures: 3, cooldownSeconds: 60)
        breaker.recordFailure()
        breaker.recordFailure()
        #expect(breaker.failureCount == 2)
        breaker.recordSuccess()
        #expect(breaker.failureCount == 0)
        #expect(breaker.isCircuitOpen == false)
    }

    @Test("Circuit opens exactly after N consecutive failures")
    func circuitOpensAfterNFailures() {
        let breaker = EngineCircuitBreaker(maxConsecutiveFailures: 3, cooldownSeconds: 60)
        
        breaker.recordFailure()
        #expect(breaker.isCircuitOpen == false)
        #expect(breaker.failureCount == 1)
        
        breaker.recordFailure()
        #expect(breaker.isCircuitOpen == false)
        #expect(breaker.failureCount == 2)
        
        breaker.recordFailure()
        #expect(breaker.isCircuitOpen == true)
        #expect(breaker.failureCount == 3)
    }

    @Test("Circuit open blocks allowStart")
    func openCircuitBlocksStart() {
        let breaker = EngineCircuitBreaker(maxConsecutiveFailures: 2, cooldownSeconds: 60)
        
        breaker.recordFailure()
        breaker.recordFailure()
        #expect(breaker.isCircuitOpen == true)
        #expect(breaker.allowStart() == false)
    }

    @Test("allowStart returns true when circuit is closed")
    func allowStartWhenClosed() {
        let breaker = EngineCircuitBreaker(maxConsecutiveFailures: 3, cooldownSeconds: 60)
        breaker.recordFailure()
        #expect(breaker.allowStart() == true)
    }

    @Test("cooldownRemaining is positive when circuit is open")
    func cooldownRemainingPositive() {
        let breaker = EngineCircuitBreaker(maxConsecutiveFailures: 2, cooldownSeconds: 60)
        breaker.recordFailure()
        breaker.recordFailure()
        #expect(breaker.isCircuitOpen == true)
        #expect(breaker.cooldownRemaining() > 0)
        // Should be close to 60 (the cooldown period)
        #expect(breaker.cooldownRemaining() <= 60)
    }

    @Test("cooldownRemaining is 0 when circuit is closed")
    func cooldownRemainingZeroWhenClosed() {
        let breaker = EngineCircuitBreaker(maxConsecutiveFailures: 3, cooldownSeconds: 60)
        #expect(breaker.cooldownRemaining() == 0)
    }

    @Test("resetCircuit closes the circuit and clears failure count")
    func resetClosesCircuit() {
        let breaker = EngineCircuitBreaker(maxConsecutiveFailures: 2, cooldownSeconds: 60)
        breaker.recordFailure()
        breaker.recordFailure()
        #expect(breaker.isCircuitOpen == true)
        
        breaker.resetCircuit()
        #expect(breaker.isCircuitOpen == false)
        #expect(breaker.failureCount == 0)
        #expect(breaker.cooldownRemaining() == 0)
    }

    @Test("Mixed success/failure: success resets counter before threshold")
    func mixedSuccessFailure() {
        let breaker = EngineCircuitBreaker(maxConsecutiveFailures: 3, cooldownSeconds: 60)
        breaker.recordFailure()
        breaker.recordFailure()
        breaker.recordSuccess() // resets to 0
        breaker.recordFailure()
        #expect(breaker.isCircuitOpen == false)
        #expect(breaker.failureCount == 1)
    }

    @Test("Circuit with maxFailures=1 opens on first failure")
    func singleFailureThreshold() {
        let breaker = EngineCircuitBreaker(maxConsecutiveFailures: 1, cooldownSeconds: 60)
        breaker.recordFailure()
        #expect(breaker.isCircuitOpen == true)
        #expect(breaker.allowStart() == false)
    }

    @Test("allowStart after cooldown expires permits retry")
    func allowStartAfterCooldown() async {
        // Use a very short cooldown to test expiry
        let breaker = EngineCircuitBreaker(maxConsecutiveFailures: 1, cooldownSeconds: 1)
        breaker.recordFailure()
        #expect(breaker.isCircuitOpen == true)
        #expect(breaker.allowStart() == false)
        
        // Wait for cooldown
        _ = try? await Task.sleep(for: .seconds(2))
        // isCircuitOpen is still true (we don't auto-close), but allowStart checks elapsed time
        #expect(breaker.allowStart() == true)
    }

    @Test("Failure timestamps are recorded")
    func failureTimestampsRecorded() {
        let breaker = EngineCircuitBreaker(maxConsecutiveFailures: 5, cooldownSeconds: 60)
        breaker.recordFailure()
        breaker.recordFailure()
        breaker.recordFailure()
        #expect(breaker.failureCount == 3)
        // Internal: failureTimestamps should have 3 entries
        // We can only verify via failureCount since timestamps are private
    }

    @Test("Circuit remains open after recording more failures")
    func additionalFailuresDoNotCloseCircuit() {
        let breaker = EngineCircuitBreaker(maxConsecutiveFailures: 2, cooldownSeconds: 60)
        breaker.recordFailure()
        breaker.recordFailure()
        #expect(breaker.isCircuitOpen == true)
        breaker.recordFailure() // extra failure
        breaker.recordFailure()
        #expect(breaker.isCircuitOpen == true)
        #expect(breaker.failureCount == 4)
    }
}

// MARK: - Transition safety: degraded state still healthy

@Suite("EngineLifecycleState: degraded state behavior")
struct DegradedStateTests {

    @Test("Degraded engine still accepts inference (isHealthy=true)")
    func degradedStillHealthy() {
        // This is a CRITICAL invariant: degraded means some subsystem failed
        // (e.g. HTTP server), but the engine itself is still running.
        // Users should NOT see a full shutdown for a partial failure.
        #expect(EngineLifecycleState.degraded.isHealthy == true)
        #expect(EngineLifecycleState.degraded.isTransitioning == false)
    }

    @Test("Degraded state has warning icon, not error icon")
    func degradedIconIsWarningNotError() {
        // degraded = exclamation triangle (warning), error = stop sign (fatal)
        // They should NOT be the same — UI relies on this distinction
        #expect(EngineLifecycleState.degraded.statusIcon != EngineLifecycleState.error.statusIcon)
    }
}
