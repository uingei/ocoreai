// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Behavioral invariant tests for OOMGuard, Scheduler, and AgentLoop.
///
/// These tests exercise state machines and invariants that the 800+ DTO
/// round-trip tests never touch — actual bug-finding surface area.

import Testing
@testable import ocoreai
import ocoreaiTestUtilities

// MARK: - OOMGuard state machine

@Suite("OOMGuard downgrade chain state machine")
struct OOMGuardBehavioralTests {

    @Test("starts at 8-bit quantization (normal precision)")
    func initialLevel() async {
        let oomGuard = OOMGuard()
        #expect(await oomGuard.currentQuantization() == .bits8)
    }

    @Test("warning triggers 8bit→4bit downgrade")
    func warningDowngrade() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .warning)
        #expect(await oomGuard.currentQuantization() == .bits4)
    }

    @Test("critical triggers 8bit→4bit downgrade")
    func criticalDowngrade() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .critical)
        #expect(await oomGuard.currentQuantization() == .bits4)
    }

    @Test("oom triggers hard refuse")
    func oomRefuse() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .oom)
        #expect(await oomGuard.currentQuantization() == .refuse)
        #expect(await oomGuard.shouldAcceptRequest() == false)
    }

    @Test("normal recovers from 4bit to 8bit")
    func normalRecovery() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .warning)
        #expect(await oomGuard.currentQuantization() == .bits4)
        await oomGuard.respond(to: .normal)
        #expect(await oomGuard.currentQuantization() == .bits8)
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
        #expect(await oomGuard.currentQuantization() == .bits8)
        await oomGuard.respond(to: .warning)
        #expect(await oomGuard.currentQuantization() == .bits4)
        await oomGuard.respond(to: .critical)
        #expect(await oomGuard.currentQuantization() == .bits4)
        await oomGuard.respond(to: .oom)
        #expect(await oomGuard.currentQuantization() == .refuse)
    }

    @Test("idempotent: repeated warning when already at 4bit stays at 4bit")
    func idempotentWarning() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .warning)
        await oomGuard.respond(to: .warning)
        #expect(await oomGuard.currentQuantization() == .bits4)
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

    @Test("critical when already at 4bit stays at 4bit")
    func criticalFrom4bitNoOp() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .warning)
        await oomGuard.respond(to: .critical)
        #expect(await oomGuard.currentQuantization() == .bits4)
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

    @Test("idempotent: normal on bits8 is no-op")
    func normalWhenAt8bit() async {
        let oomGuard = OOMGuard()
        await oomGuard.respond(to: .normal)
        #expect(await oomGuard.currentQuantization() == .bits8)
    }
}


