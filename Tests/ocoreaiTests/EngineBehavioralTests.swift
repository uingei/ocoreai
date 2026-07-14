// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Behavioral invariant tests for OOMGuard, Scheduler, and AgentLoop.
///
/// These tests exercise state machines and invariants that the 800+ DTO
/// round-trip tests never touch — actual bug-finding surface area.

import Testing
@testable import ocoreai

// MARK: - OOMGuard state machine

@Suite("OOMGuard downgrade chain state machine")
struct OOMGuardBehavioralTests {

    @Test("starts at 4-bit quantization")
    func initialLevel() async {
        let oomGuard = OOMGuard()
        #expect(await oomGuard.currentQuantization() == .bits4)
    }

    @Test("warning triggers 4bit→8bit downgrade")
    func warningDowngrade() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .warning)
        #expect(await oomGuard.currentQuantization() == .bits8)
    }

    @Test("critical triggers 4bit→8bit downgrade")
    func criticalDowngrade() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .critical)
        #expect(await oomGuard.currentQuantization() == .bits8)
    }

    @Test("oom triggers hard refuse")
    func oomRefuse() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .oom)
        #expect(await oomGuard.currentQuantization() == .refuse)
        #expect(await oomGuard.shouldAcceptRequest() == false)
    }

    @Test("normal recovers from 8bit to 4bit")
    func normalRecovery() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .warning)
        #expect(await oomGuard.currentQuantization() == .bits8)
        await oomGuard.respond(to: .normal)
        #expect(await oomGuard.currentQuantization() == .bits4)
    }

    @Test("normal does NOT recover from refuse — manual setLevel required")
    func noAutoRecoveryFromRefuse() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .oom)
        await oomGuard.respond(to: .normal)
        #expect(await oomGuard.currentQuantization() == .refuse)
    }

    @Test("full downgrade chain: warning→oom→refuse")
    func fullDowngradeChain() async {
        let oomGuard = OOMGuard()
        #expect(await oomGuard.currentQuantization() == .bits4)
        await oomGuard.respond(to: .warning)
        #expect(await oomGuard.currentQuantization() == .bits8)
        await oomGuard.respond(to: .critical)
        #expect(await oomGuard.currentQuantization() == .bits8)
        await oomGuard.respond(to: .oom)
        #expect(await oomGuard.currentQuantization() == .refuse)
    }

    @Test("repeated warning when already at 8bit stays at 8bit")
    func idempotentWarning() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .warning)
        await oomGuard.respond(to: .warning)
        #expect(await oomGuard.currentQuantization() == .bits8)
    }

    @Test("shouldAcceptRequest reflects quantization level")
    func shouldAcceptReflectsLevel() async {
        let oomGuard = OOMGuard()
        #expect(await oomGuard.shouldAcceptRequest())
        await oomGuard.respond(to: .warning)
        #expect(await oomGuard.shouldAcceptRequest())
        await oomGuard.respond(to: .oom)
        #expect(await oomGuard.shouldAcceptRequest() == false)
    }

    @Test("downgrade events recorded in history")
    func eventsRecorded() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .warning)
        await oomGuard.respond(to: .oom)
        let events = await oomGuard.recentEvents()
        #expect(events.count >= 2)
    }

    @Test("critical when already at 8bit stays at 8bit")
    func criticalFrom8bitNoOp() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .warning)
        await oomGuard.respond(to: .critical)
        #expect(await oomGuard.currentQuantization() == .bits8)
    }

    @Test("manual override allows recovery from refuse")
    func manualOverride() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .oom)
        #expect(await oomGuard.currentQuantization() == .refuse)
        await oomGuard.setLevel(.bits4)
        #expect(await oomGuard.currentQuantization() == .bits4)
        #expect(await oomGuard.shouldAcceptRequest())
    }

    @Test("idempotent: normal on bits4 is no-op")
    func normalWhenAt4bit() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .normal)
        #expect(await oomGuard.currentQuantization() == .bits4)
    }
}

// MARK: - SamplingConfiguration normalized() edge cases

@Suite("SamplingConfiguration.normalized() edge cases")
struct SamplingNormalizationTests {

    @Test("negative temperature is not treated as greedy")
    func negativeTemperaturePreservesParams() {
        let config = SamplingConfiguration(temperature: -0.5, topP: 0.9, topK: 50)
        let normalized = config.normalized()
        #expect(normalized.topP == 0.9)
        #expect(normalized.topK == 50)
    }
}
