// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ThinkingBudgetTests.swift — Verify adaptive budget multiplier logic
/// and scaffolding injection by complexity band.

import Foundation
import Testing

@testable import ocoreai

@Suite("ThinkingBudget")
struct ThinkingBudgetTests {
    // MARK: - Scaffolding by Band

    @Test("simpleBandReturnsEmpty")
    func simpleBandReturnsEmpty() async throws {
        let tb = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.2, length: 0.1, intent: 0.2, history: 0.1, band: .simple,
            taskType: .general)
        let scaffold = await tb.scaffolding(for: score, sessionId: "s1")
        #expect(scaffold == "")
    }

    @Test("mediumBandReturnsScaffold")
    func mediumBandReturnsScaffold() async throws {
        let tb = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.5, length: 0.4, intent: 0.6, history: 0.5, band: .medium,
            taskType: .general)
        let scaffold = await tb.scaffolding(for: score, sessionId: "s1")
        #expect(!scaffold.isEmpty)
        #expect(scaffold.contains("PERCEIVE"))
        #expect(scaffold.contains("REASON"))
        #expect(scaffold.contains("ACT"))
        #expect(!scaffold.contains("SELF-CHECK"))
    }

    @Test("complexBandReturnsFullScaffold")
    func complexBandReturnsFullScaffold() async throws {
        let tb = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.9, length: 0.9, intent: 0.9, history: 0.8, band: .complex,
            taskType: .general)
        let scaffold = await tb.scaffolding(for: score, sessionId: "s1")
        #expect(!scaffold.isEmpty)
        #expect(scaffold.contains("PERCEIVE"))
        #expect(scaffold.contains("REASON"))
        #expect(scaffold.contains("ACT"))
        #expect(scaffold.contains("SELF-CHECK"))
    }

    // MARK: - Quality Tracking & Multiplier

    @Test("defaultMultiplierIs10")
    func defaultMultiplierIs10() async throws {
        let tb = ThinkingBudget()
        let m = await tb.currentMultiplier(for: "new-session")
        #expect(m == 1.0)
    }

    @Test("highQualityBumpsMultiplier")
    func highQualityBumpsMultiplier() async throws {
        let tb = ThinkingBudget()
        for _ in 0 ..< 5 {
            await tb.recordQuality(0.95, for: "s1")
        }
        let m = await tb.currentMultiplier(for: "s1")
        #expect(m > 1.0)
        #expect(m <= 2.0)
    }

    @Test("lowQualityReducesMultiplier")
    func lowQualityReducesMultiplier() async throws {
        let tb = ThinkingBudget()
        for _ in 0 ..< 5 {
            await tb.recordQuality(0.1, for: "s2")
        }
        let m = await tb.currentMultiplier(for: "s2")
        #expect(m < 1.0)
        #expect(m >= 0.5)
    }

    @Test("multiplierCappedAt20")
    func multiplierCappedAt20() async throws {
        let tb = ThinkingBudget()
        for _ in 0 ..< 20 {
            await tb.recordQuality(1.0, for: "s3")
        }
        let m = await tb.currentMultiplier(for: "s3")
        #expect(m <= 2.0)
    }

    @Test("multiplierFlooredAt05")
    func multiplierFlooredAt05() async throws {
        let tb = ThinkingBudget()
        for _ in 0 ..< 20 {
            await tb.recordQuality(0.0, for: "s4")
        }
        let m = await tb.currentMultiplier(for: "s4")
        #expect(m >= 0.5)
    }

    @Test("qualityClampedTo0_1")
    func qualityClampedTo0_1() async throws {
        let tb = ThinkingBudget()
        await tb.recordQuality(-0.5, for: "s5")
        await tb.recordQuality(1.5, for: "s5")
        _ = await tb.currentMultiplier(for: "s5")
    }

    @Test("perSessionIsolation")
    func perSessionIsolation() async throws {
        let tb = ThinkingBudget()
        for _ in 0 ..< 5 {
            await tb.recordQuality(0.9, for: "a")
            await tb.recordQuality(0.1, for: "b")
        }
        let ma = await tb.currentMultiplier(for: "a")
        let mb = await tb.currentMultiplier(for: "b")
        #expect(ma > mb)
    }

    @Test("historyCappedAt20")
    func historyCappedAt20() async throws {
        let tb = ThinkingBudget()
        for _ in 0 ..< 25 {
            await tb.recordQuality(0.5, for: "s6")
        }
        _ = await tb.currentMultiplier(for: "s6")
    }

    // MARK: - Session Key Set Bound (unbounded-key leak regression)

    @Test("sessionKeySetBoundedAtCapLRUEvictingOldest")
    func sessionKeySetBoundedAtCapLRUEvictingOldest() async throws {
        let tb = ThinkingBudget()
        #expect(await tb.sessionKeyCount == 0)
        // 64 distinct sessions × quality 0.95 → each multiplier 1.0+0.2 = 1.2
        for i in 0 ..< 64 { await tb.recordQuality(0.95, for: "k\(i)") }
        #expect(await tb.sessionKeyCount == ThinkingBudget.maxSessionKeys)
        // 65th session crosses the cap → oldest ("k0") evicted, key set stays at cap
        await tb.recordQuality(0.95, for: "k64")
        #expect(await tb.sessionKeyCount == ThinkingBudget.maxSessionKeys)
        // Evicted session's calibration resets to default; retained/added keep 1.2
        #expect(await tb.currentMultiplier(for: "k0") == 1.0)
        #expect(await tb.currentMultiplier(for: "k1") == 1.2)
        #expect(await tb.currentMultiplier(for: "k64") == 1.2)
    }

    @Test("LRUTouchPreservesRecentlyUsedKeyOverOldest")
    func lruTouchPreservesRecentlyUsedKeyOverOldest() async throws {
        let tb = ThinkingBudget()
        for i in 0 ..< 63 { await tb.recordQuality(0.95, for: "a\(i)") }
        #expect(await tb.sessionKeyCount == 63)
        // Touch "a0" — most-recent, must survive the next eviction (2nd 0.95 → 1.4)
        await tb.recordQuality(0.95, for: "a0")
        #expect(await tb.sessionKeyCount == 63)
        await tb.recordQuality(0.95, for: "b0")  // 64th key — fits, no eviction
        #expect(await tb.sessionKeyCount == 64)
        await tb.recordQuality(0.95, for: "c0")  // 65th — evicts OLDEST surviving = "a1"
        #expect(await tb.sessionKeyCount == 64)
        #expect(await tb.currentMultiplier(for: "a1") == 1.0)  // evicted → default
        #expect(await tb.currentMultiplier(for: "a0") == 1.4)  // touched → preserved
        #expect(await tb.currentMultiplier(for: "b0") == 1.2)
    }
}
