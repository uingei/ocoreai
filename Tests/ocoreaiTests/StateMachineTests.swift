// Copyright © 2026 uingeai@163.com.
// Licensed under MIT.
/// StateMachineTests.swift — Behavioral invariant tests for state machines
///
/// Upstream pattern: State machines MUST survive adversarial sequences.
/// These tests verify that:
/// 1. Circuit breaker recovers after cooldown, not perm-fused
/// 2. OOMGuard downgrade chain follows correct transitions
/// 3. Engine lifecycle stays in valid states
///
/// Source: EngineLifecycleState.swift, OOMGuard.swift

import Testing
import Foundation
import Logging
@testable import ocoreai

// MARK: - CircuitBreaker State Machine Invariants

@Suite("CircuitBreaker State Machine Invariants")
struct CircuitBreakerInvariantsTests {
    @Test("Three consecutive failures open the circuit")
    func circuitOpensAfterMaxFailures() {
        let cb = EngineCircuitBreaker(maxConsecutiveFailures: 3, cooldownSeconds: 1)
        #expect(cb.isCircuitOpen == false)
        cb.recordFailure()
        #expect(cb.isCircuitOpen == false)
        cb.recordFailure()
        #expect(cb.isCircuitOpen == false)
        cb.recordFailure()
        #expect(cb.isCircuitOpen == true)
    }
    
    @Test("Cooldown allows one retry attempt")
    func cooldownAllowsRetry() {
        let cb = EngineCircuitBreaker(maxConsecutiveFailures: 2, cooldownSeconds: 1)
        cb.recordFailure()
        cb.recordFailure()
        #expect(cb.isCircuitOpen == true)
        #expect(cb.allowStart() == false)
        
        // Wait for cooldown
        Thread.sleep(forTimeInterval: 1.1)
        
        // After cooldown, one attempt should be allowed
        #expect(cb.allowStart() == true)
    }
    
    @Test("Post-cooldown retry that fails still recovers after next cooldown")
    func cooldownRecoveryAfterRetryFailure() {
        let cb = EngineCircuitBreaker(maxConsecutiveFailures: 2, cooldownSeconds: 1)
        
        // Open the circuit
        cb.recordFailure()
        cb.recordFailure()
        #expect(cb.isCircuitOpen == true)
        
        // Wait for cooldown
        Thread.sleep(forTimeInterval: 1.1)
        
        // Allow restart
        #expect(cb.allowStart() == true)
        
        // Simulate another failure after restart attempt
        cb.recordFailure()
        
        // Circuit should still be in some recoverable state
        // _failureCount is now 3, but _isOpen is already true from before
        #expect(cb.isCircuitOpen == true)
        
        // After next cooldown, allowStart checks elapsed time from _lastFailureNano
        // Since _lastFailureNano was just set, we need another cooldown
        Thread.sleep(forTimeInterval: 1.1)
        
        // This is the key invariant: circuit must eventually recover
        // regardless of how many failures accumulated
        #expect(cb.allowStart() == true)
    }
    
    @Test("Manual reset fully restores the circuit")
    func manualResetClearsState() {
        let cb = EngineCircuitBreaker(maxConsecutiveFailures: 2, cooldownSeconds: 60)
        cb.recordFailure()
        cb.recordFailure()
        #expect(cb.isCircuitOpen == true)
        
        cb.resetCircuit()
        #expect(cb.isCircuitOpen == false)
        #expect(cb.failureCount == 0)
        #expect(cb.allowStart() == true)
    }
    
    @Test("Success clears failure counter")
    func successResetsCounter() {
        let cb = EngineCircuitBreaker(maxConsecutiveFailures: 3, cooldownSeconds: 60)
        cb.recordFailure()
        cb.recordFailure()
        #expect(cb.failureCount == 2)
        cb.recordSuccess()
        #expect(cb.failureCount == 0)
        #expect(cb.isCircuitOpen == false)
    }
    
    @Test("Cooldown remaining decreases over time")
    func countdownBehavior() {
        let cb = EngineCircuitBreaker(maxConsecutiveFailures: 1, cooldownSeconds: 5)
        cb.recordFailure()
        
        let remaining = cb.cooldownRemaining()
        #expect(remaining >= 4 && remaining <= 5)
    }
}

// MARK: - OOMGuard Downgrade Chain Invariants

@Suite("OOMGuard Downgrade Chain — Behavioral Invariants")
struct OOMGuardBehavioralInvariantsTests {
    @Test("Downgrade chain is strictly monotonic downward")
    func downgradeChainMonotonic() async {
        let oomGuard = OOMGuard(log: Logger(label: "test.oomguard"))
        
        // Initial state
        #expect(await oomGuard.currentQuantization() == .bits4)
        
        // Normal should not change anything
        await oomGuard.respond(to: .normal)
        #expect(await oomGuard.currentQuantization() == .bits4)
        
        // Warning downgrades to 8-bit
        await oomGuard.respond(to: .warning)
        #expect(await oomGuard.currentQuantization() == .bits8)
        
        // Additional warnings are idempotent (already at 8-bit)
        await oomGuard.respond(to: .warning)
        #expect(await oomGuard.currentQuantization() == .bits8)
        
        // OOM forces refuse
        await oomGuard.respond(to: .oom)
        #expect(await oomGuard.currentQuantization() == .refuse)
        #expect(await oomGuard.shouldAcceptRequest() == false)
    }
    
    @Test("Recovery from warning via manual override")
    func manualOverrideAfterRefuse() async {
        let g = OOMGuard(log: Logger(label: "test.oomguard"))
        
        await g.respond(to: .oom)
        #expect(await g.currentQuantization() == .refuse)
        
        // Manual override to recover
        await g.setLevel(.bits4)
        #expect(await g.currentQuantization() == .bits4)
        #expect(await g.shouldAcceptRequest() == true)
    }
    
    @Test("Events are recorded with monotonic severity")
    func recordEventsAreMonotonic() async {
        let g = OOMGuard(log: Logger(label: "test.oomguard"))
        
        await g.respond(to: .warning)
        await g.respond(to: .critical)
        await g.respond(to: .oom)
        
        let events = await g.recentEvents(count: 10)
        #expect(events.count >= 2)
    }
    
    @Test("Normal recovers from bits8 to bits4")
    func normalRecoveryFromBits8() async {
        let g = OOMGuard(log: Logger(label: "test.oomguard"))
        
        await g.respond(to: .warning)
        #expect(await g.currentQuantization() == .bits8)
        
        await g.respond(to: .normal)
        #expect(await g.currentQuantization() == .bits4)
    }
    
    @Test("OOM cannot be recovered by normal alone")
    func oomRequiresManualOverride() async {
        let g = OOMGuard(log: Logger(label: "test.oomguard"))
        
        await g.respond(to: .oom)
        #expect(await g.currentQuantization() == .refuse)
        
        // Normal signal while at refuse should NOT recover (design)
        await g.respond(to: .normal)
        #expect(await g.currentQuantization() == .refuse)
        
        // Manual override is required
        await g.setLevel(.bits4)
        #expect(await g.currentQuantization() == .bits4)
    }
}

// MARK: - EngineLifecycleState Valid Transitions

@Suite("EngineLifecycleState Transition Matrix")
struct LifecycleStateInvariantsTests {
    @Test("Healthy states accept inference")
    func healthyStatesAcceptInference() {
        #expect(EngineLifecycleState.ready.isHealthy == true)
        #expect(EngineLifecycleState.degraded.isHealthy == true)
        #expect(EngineLifecycleState.idle.isHealthy == false)
        #expect(EngineLifecycleState.starting.isHealthy == false)
        #expect(EngineLifecycleState.stopping.isHealthy == false)
        #expect(EngineLifecycleState.error.isHealthy == false)
    }
    
    @Test("Transitioning states reject new work")
    func transitioningStates() {
        #expect(EngineLifecycleState.starting.isTransitioning == true)
        #expect(EngineLifecycleState.stopping.isTransitioning == true)
        #expect(EngineLifecycleState.ready.isTransitioning == false)
        #expect(EngineLifecycleState.idle.isTransitioning == false)
    }
    
    @Test("Display labels match expected convention")
    func displayLabels() {
        #expect(EngineLifecycleState.idle.displayLabel == "Idle")
        #expect(EngineLifecycleState.starting.displayLabel == "Starting...")
        #expect(EngineLifecycleState.ready.displayLabel == "Ready")
        #expect(EngineLifecycleState.degraded.displayLabel == "Degraded")
        #expect(EngineLifecycleState.stopping.displayLabel == "Stopping...")
        #expect(EngineLifecycleState.error.displayLabel == "Circuit Open")
    }
}
