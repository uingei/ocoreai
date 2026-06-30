// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// OOMGuardTests.swift — Quantization downgrade chain for GPU memory protection.
///
/// Coverage:
/// - Initial state is 4-bit (most aggressive)
/// - Downgrade chain: bits4 → bits8 → refuse
/// - Recovery: normal signal restores bits4 from bits8
/// - Event history tracking with max depth
/// - Manual override sets level directly
/// - shouldAcceptRequest returns false when at refuse level

import Testing
import Logging
@testable import ocoreai

@Suite("OOMGuard Downgrade Chain")
struct OOMGuardDowngradeTests {
    
    func makeGuard() async -> OOMGuard {
        OOMGuard(log: Logger(label: "test.oomguard"))
    }
    
    @Test("initial quantization is 4-bit")
    func initialLevel() async {
        let g = await makeGuard()
        #expect(await g.currentQuantization() == .bits4)
    }
    
    @Test("normal signal does not downgrade")
    func normalLevelNoChange() async {
        let g = await makeGuard()
        await g.respond(to: .normal)
        #expect(await g.currentQuantization() == .bits4)
    }
    
    @Test("warning downgrades to 8-bit")
    func warningDowngrades() async {
        let g = await makeGuard()
        await g.respond(to: .warning)
        #expect(await g.currentQuantization() == .bits8)
    }
    
    @Test("critical at 4-bit downgrades to 8-bit")
    func criticalFromBits4() async {
        let g = await makeGuard()
        await g.respond(to: .critical)
        #expect(await g.currentQuantization() == .bits8)
    }
    
    @Test("oom forces hard refuse")
    func oomRefuses() async {
        let g = await makeGuard()
        await g.respond(to: .oom)
        #expect(await g.currentQuantization() == .refuse)
    }
    
    @Test("shouldAcceptRequest true at 4-bit")
    func acceptAtBits4() async {
        let g = await makeGuard()
        #expect(await g.shouldAcceptRequest() == true)
    }
    
    @Test("shouldAcceptRequest true at 8-bit")
    func acceptAtBits8() async {
        let g = await makeGuard()
        await g.respond(to: .warning)
        #expect(await g.shouldAcceptRequest() == true)
    }
    
    @Test("shouldAcceptRequest false at refuse")
    func rejectAtRefuse() async {
        let g = await makeGuard()
        await g.respond(to: .oom)
        #expect(await g.shouldAcceptRequest() == false)
    }
    
    @Test("recovery: normal restores 4-bit from 8-bit")
    func recoveryFromWarning() async {
        let g = await makeGuard()
        await g.respond(to: .warning)
        #expect(await g.currentQuantization() == .bits8)
        await g.respond(to: .normal)
        #expect(await g.currentQuantization() == .bits4)
    }
    
    @Test("recovery does nothing when already at 4-bit")
    func recoveryNoopAtBits4() async {
        let g = await makeGuard()
        await g.respond(to: .warning)
        await g.respond(to: .normal)
        await g.respond(to: .normal)
        #expect(await g.currentQuantization() == .bits4)
    }
    
    @Test("full downgrade chain: 4bit → 8bit → refuse")
    func fullDowngradeChain() async {
        let g = await makeGuard()
        #expect(await g.currentQuantization() == .bits4)
        
        await g.respond(to: .warning)
        #expect(await g.currentQuantization() == .bits8)
        
        await g.respond(to: .oom)
        #expect(await g.currentQuantization() == .refuse)
        #expect(await g.shouldAcceptRequest() == false)
    }
    
    @Test("event history records transitions")
    func eventHistory() async {
        let g = await makeGuard()
        await g.respond(to: .warning)
        await g.respond(to: .oom)
        await g.respond(to: .normal)
        
        let events = await g.recentEvents(count: 10)
        #expect(events.count == 2) // warning→bits8, oom→refuse (normal at refuse is no-op)
        
        #expect(events[0].fromLevel == .bits4)
        #expect(events[0].toLevel == .bits8)
        #expect(events[0].triggerLevel == .warning)
        
        #expect(events[1].fromLevel == .bits8)
        #expect(events[1].toLevel == .refuse)
        #expect(events[1].triggerLevel == .oom)
    }
    
    @Test("manual override sets quantization level")
    func manualOverride() async {
        let g = await makeGuard()
        await g.setLevel(.refuse)
        #expect(await g.currentQuantization() == .refuse)
        
        await g.setLevel(.bits4)
        #expect(await g.currentQuantization() == .bits4)
    }
}
