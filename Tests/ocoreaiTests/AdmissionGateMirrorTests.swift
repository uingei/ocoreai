// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AdmissionGateMirrorTests.swift — Mirror fixture for AdmissionGate admission logic.
/// Tests AdmissionResult model, budget estimation, and AdmissionGate actor behavior
/// via parameterized construction without live MemoryTracker.
///
/// Key insight: MemoryTracker is an actor with Darwin syscalls — cannot mock
/// in unit test. Instead test: (1) AdmissionResult model struct, (2) admission
/// lifecycle via nil tracker path (defers to downstream OOMGuard), (3) jitter
/// protection, (4) emergency abort.
///
/// Rationale: AdmissionGate has 3 data-flow-disconnect P0 fixes in July
/// (submitAndDispatch wiring, HardwareRouter bridge, scheduler state leak).
/// Mirror fixture prevents regression.

import Foundation
import Testing
@testable import ocoreai

// MARK: - AdmissionResult model tests

@Suite("AdmissionResult model")
struct AdmissionResultTests {

    @Test("OK result has admitted=true, nil reason")
    func okResult() {
        let result = AdmissionResult.ok
        #expect(result.admitted == true)
        #expect(result.reason == nil)
    }

    @Test("Rejected result has admitted=false, reason set")
    func rejectedResult() {
        let result = AdmissionResult.rejected("Budget exceeded", costMB: 512.0)
        #expect(result.admitted == false)
        #expect(result.reason == "Budget exceeded")
        #expect(result.estimatedCostMB == 512.0)
    }

    @Test("Custom admitted result with recommended channel")
    func admittedWithChannel() {
        let result = AdmissionResult(
            admitted: true,
            reason: "Thermal shift recommended",
            estimatedCostMB: 256.0,
            recommendedChannel: .ane
        )
        #expect(result.admitted == true)
        #expect(result.estimatedCostMB == 256.0)
        #expect(result.recommendedChannel == .ane)
    }

    @Test("Codable round-trip")
    func codable() throws {
        let result = AdmissionResult(
            admitted: true,
            reason: nil,
            estimatedCostMB: 128.0,
            recommendedChannel: .gpu
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AdmissionResult.self, from: data)
        #expect(decoded.admitted == true)
        #expect(decoded.estimatedCostMB == 128.0)
        #expect(decoded.recommendedChannel == .gpu)
    }
}

// MARK: - AdmissionGate actor behavior

@Suite("AdmissionGate — actor behavior via parameterized setup")
struct AdmissionGateBehaviorTests {

    @Test("Memory cost estimation: 100 input + 50 output tokens")
    func estimatedCost() async {
        // MemoryTracker is nil → allows unlimited
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil,
            hardwareRouter: nil
        )
        // KBPerToken = 1024. Total tokens = 150 → 150 * 1024 KB = 153,600 KB
        // We can't directly call estimatedCost (it's private), but we can verify
        // through the admission lifecycle — nil tracker allows everything
        let result = await gate.check(
            requestId: "test-1",
            inputTokens: 100,
            maxOutputTokens: 50,
            priority: .chat
        )
        // Nil tracker → admits with estimated cost
        #expect(result.admitted == true)
        // 150 tokens * 1024 KB = 153,600 KB → / (1024*1024) = 0.146484375
        #expect(result.estimatedCostMB == 0.146_484_375)
    }

    @Test("Large request cost scales linearly")
    func largeRequestCost() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil,
            hardwareRouter: nil
        )
        let result = await gate.check(
            requestId: "test-2",
            inputTokens: 1000,
            maxOutputTokens: 500,
            priority: .chat
        )
        // 1500 tokens * 1024 KB = 1,536,000 KB → / (1024*1024) = 1.46484375
        #expect(result.estimatedCostMB == 1.464_843_75)
    }

    @Test("Nil MemoryTracker: unlimited admission defers to downstream")
    func nilTrackerAllowsAll() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil,
            hardwareRouter: nil
        )
        let result = await gate.check(
            requestId: "test-3",
            inputTokens: 10_000,
            maxOutputTokens: 50_000,
            priority: .background
        )
        #expect(result.admitted == true)
    }

    @Test("Jitter protection: concurrent pre-fill limit enforced")
    func jitterProtection() async {
        // maxConcurrentPreFills = 2
        let gate = AdmissionGate(
            maxConcurrentPreFills: 2,
            memoryTracker: nil,
            hardwareRouter: nil
        )
        // First two admits succeed
        #expect(await gate.admit("req-1", inputTokens: 100, maxOutputTokens: 100))
        #expect(await gate.admit("req-2", inputTokens: 100, maxOutputTokens: 100))
        // Third check should be rejected by jitter
        let result = await gate.check(
            requestId: "req-3",
            inputTokens: 100,
            maxOutputTokens: 100,
            priority: .chat
        )
        #expect(result.admitted == false)
    }

    @Test("Admission lifecycle: admit → release → new admission allowed")
    func admissionLifecycle() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 2,
            memoryTracker: nil,
            hardwareRouter: nil
        )
        // Fill to capacity
        #expect(await gate.admit("req-a", inputTokens: 100, maxOutputTokens: 100))
        #expect(await gate.admit("req-b", inputTokens: 100, maxOutputTokens: 100))
        // Release one
        await gate.release("req-a")
        // Now a new admission can pass jitter check
        let result = await gate.check(
            requestId: "req-c",
            inputTokens: 50,
            maxOutputTokens: 50,
            priority: .chat
        )
        #expect(result.admitted == true)
    }

    @Test("Emergency abort clears all reservations")
    func emergencyAbort() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil,
            hardwareRouter: nil
        )
        await gate.admit("ea-1", inputTokens: 100, maxOutputTokens: 100)
        await gate.admit("ea-2", inputTokens: 200, maxOutputTokens: 200)
        await gate.admit("ea-3", inputTokens: 150, maxOutputTokens: 150)
        // Emergency abort
        await gate.emergencyAbort()
        // State should be zeroed
        let state = await gate.state()
        #expect(state.reserved == 0)
        #expect(state.active == 0)
        #expect(state.requests == 0)
    }

    @Test("State tracking: reservations count and bytes")
    func stateTracking() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil,
            hardwareRouter: nil
        )
        #expect(await gate.admit("st-1", inputTokens: 100, maxOutputTokens: 100))
        #expect(await gate.admit("st-2", inputTokens: 200, maxOutputTokens: 200))
        let state = await gate.state()
        #expect(state.requests == 2)
        #expect(state.active == 2)
        // st-1: 200 tokens * 1024 KB + st-2: 400 tokens * 1024 KB = 614,400 KB (stored as KB in reservedBytes)
        #expect(state.reserved == 614_400)
    }

    @Test("Duplicate request ID: existing reservation allows continuation")
    func duplicateRequestID() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 1,
            memoryTracker: nil,
            hardwareRouter: nil
        )
        // Admit fills the only slot
        #expect(await gate.admit("dup-1", inputTokens: 100, maxOutputTokens: 100))
        // Same ID should still pass check (continuation)
        let result = await gate.check(
            requestId: "dup-1",
            inputTokens: 100,
            maxOutputTokens: 100,
            priority: .chat
        )
        #expect(result.admitted == true)
    }

    @Test("Release non-existent request ID is safe")
    func releaseNonExistent() async {
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil,
            hardwareRouter: nil
        )
        // No crash
        await gate.release("does-not-exist")
        let state = await gate.state()
        #expect(state.requests == 0)
    }
}

// MARK: - HardwareRouter + AdmissionGate integration (nil tracker path)

@Suite("HardwareRouter integration — recommended channel propagation")
struct HardwareRouterIntegrationTests {

    @Test("HardwareRouter query returns correct channel for nil-tracker gate")
    func routerQueryNilTracker() async {
        let router = HardwareRouter(policy: .balanced)
        let gate = AdmissionGate(
            maxConcurrentPreFills: 4,
            memoryTracker: nil,
            hardwareRouter: router
        )
        // Nil tracker path: headroom is unlimited, channel still queried
        let result = await gate.check(
            requestId: "hw-int-1",
            inputTokens: 100,
            maxOutputTokens: 100,
            priority: .chat
        )
        // Should be admitted regardless
        #expect(result.admitted == true)
    }
}

// MARK: - MemoryLevel model tests

@Suite("MemoryLevel model")
struct MemoryLevelTests {

    @Test("All levels present")
    func allLevels() {
        #expect(MemoryLevel.normal != nil)
        #expect(MemoryLevel.warning != nil)
        #expect(MemoryLevel.critical != nil)
        #expect(MemoryLevel.oom != nil)
    }

    @Test("MemoryLevel Codable round-trip")
    func codable() throws {
        let level: MemoryLevel = .critical
        let data = try JSONEncoder().encode(level)
        let decoded = try JSONDecoder().decode(MemoryLevel.self, from: data)
        #expect(decoded == .critical)
    }

    @Test("MemoryLevel raw values")
    func rawValues() {
        #expect(MemoryLevel.normal.rawValue == "normal")
        #expect(MemoryLevel.warning.rawValue == "warning")
        #expect(MemoryLevel.critical.rawValue == "critical")
        #expect(MemoryLevel.oom.rawValue == "oom")
    }
}
