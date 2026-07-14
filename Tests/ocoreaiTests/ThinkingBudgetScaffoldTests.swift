// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ThinkingBudget scaffolding tests — adaptive multiplier adjustment,
/// taskType→scaffold mapping, and quality feedback calibration.
///
/// Matches upstream methodology: parameterized across ComplexityBand + TaskType
/// to verify the full scaffold selection matrix.

import Testing
import Foundation
@testable import ocoreai
import ocoreaiTestUtilities

@Suite("ThinkingBudget — Adaptive complexity band adjustment")
struct ThinkingBudgetAdaptiveTests {

    // MARK: - Simple band: zero-overhead for non-precision tasks

    @Test("Simple band + general task → empty scaffolding (zero overhead)")
    func simpleGeneralIsZeroOverhead() async {
        let budget = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.1, length: 0.1, intent: 0.1, history: 0.1,
            band: .simple, taskType: .general
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "s1")
        #expect(scaffold.isEmpty)
    }

    @Test("Simple band + factual task → empty scaffolding")
    func simpleFactualIsZeroOverhead() async {
        let budget = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.2, length: 0.1, intent: 0.2, history: 0.1,
            band: .simple, taskType: .factual
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "s1")
        #expect(scaffold.isEmpty)
    }

    @Test("Simple band + code task → precision scaffold injected")
    func simpleCodeGetsPrecisionCheck() async {
        let budget = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.3, length: 0.3, intent: 0.2, history: 0.1,
            band: .simple, taskType: .code
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "s1")
        #expect(!scaffold.isEmpty)
        #expect(scaffold.contains("code"))
    }

    @Test("Simple band + math task → precision scaffold injected")
    func simpleMathGetsPrecisionCheck() async {
        let budget = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.2, length: 0.1, intent: 0.3, history: 0.1,
            band: .simple, taskType: .math
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "s1")
        #expect(!scaffold.isEmpty)
        #expect(scaffold.contains("calculation"))
    }

    @Test("Simple band + json task → precision scaffold injected")
    func simpleJsonGetsPrecisionCheck() async {
        let budget = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.3, length: 0.2, intent: 0.3, history: 0.1,
            band: .simple, taskType: .json
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "s1")
        #expect(!scaffold.isEmpty)
        #expect(scaffold.contains("fields") || scaffold.contains("types"))
    }

    // MARK: - Medium band: domain-specific protocols

    @Test("Medium band + code → Code Protocol scaffold")
    func mediumCodeGetsCodeProtocol() async {
        let budget = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.5, length: 0.4, intent: 0.5, history: 0.3,
            band: .medium, taskType: .code
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "s1")
        #expect(!scaffold.isEmpty)
        #expect(scaffold.contains("Code Protocol"))
        #expect(scaffold.contains("UNDERSTAND"))
    }

    @Test("Medium band + math → Calculation Protocol scaffold")
    func mediumMathGetsCalcProtocol() async {
        let budget = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.5, length: 0.4, intent: 0.5, history: 0.3,
            band: .medium, taskType: .math
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "s1")
        #expect(!scaffold.isEmpty)
        #expect(scaffold.contains("Calculation Protocol"))
    }

    @Test("Medium band + json → Structured Output Protocol")
    func mediumJsonGetsStructProtocol() async {
        let budget = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.5, length: 0.4, intent: 0.5, history: 0.3,
            band: .medium, taskType: .json
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "s1")
        #expect(!scaffold.isEmpty)
        #expect(scaffold.contains("Structured Output Protocol"))
    }

    @Test("Medium band + comparison → Comparison Protocol")
    func mediumComparisonGetsCompareProtocol() async {
        let budget = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.5, length: 0.4, intent: 0.5, history: 0.3,
            band: .medium, taskType: .comparison
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "s1")
        #expect(!scaffold.isEmpty)
        #expect(scaffold.contains("Comparison Protocol"))
    }

    @Test("Medium band + general → Reasoning Protocol")
    func mediumGeneralGetsReasoningProtocol() async {
        let budget = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.5, length: 0.4, intent: 0.5, history: 0.3,
            band: .medium, taskType: .general
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "s1")
        #expect(!scaffold.isEmpty)
        #expect(scaffold.contains("Reasoning Protocol"))
    }

    // MARK: - Complex band: deep protocols

    @Test("Complex band + code → 深度代码审查 scaffold")
    func complexCodeGetsDeepProtocol() async {
        let budget = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.9, length: 0.8, intent: 0.9, history: 0.7,
            band: .complex, taskType: .code
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "s1")
        #expect(!scaffold.isEmpty)
        #expect(scaffold.contains("深度代码审查"))
    }

    @Test("Complex band + math → 验算 scaffold")
    func complexMathGetsVerifyProtocol() async {
        let budget = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.9, length: 0.8, intent: 0.9, history: 0.7,
            band: .complex, taskType: .math
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "s1")
        #expect(!scaffold.isEmpty)
        #expect(scaffold.contains("验算"))
    }

    @Test("Complex band + general → 三思而后行 scaffold")
    func complexGeneralGetsDeepReasoning() async {
        let budget = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.9, length: 0.8, intent: 0.9, history: 0.7,
            band: .complex, taskType: .general
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "s1")
        #expect(!scaffold.isEmpty)
        #expect(scaffold.contains("三思而后行"))
    }

    // MARK: - Adaptive multiplier: quality feedback adjusts band

    @Test("High quality feedback increases multiplier → band upgrade")
    func highQualityBumpsMultiplier() async {
        let budget = ThinkingBudget()
        // Record 5 consecutive high-quality outputs to push multiplier ≥ 1.5
        for _ in 0 ..< 5 {
            await budget.recordQuality(0.95, for: "s1")
        }
        let m = await budget.currentMultiplier(for: "s1")
        #expect(m >= 1.5)

        // A simple-band score should now get medium-band scaffold
        let score = ComplexityScore(
            composite: 0.1, length: 0.1, intent: 0.1, history: 0.1,
            band: .simple, taskType: .general
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "s1")
        // simple + general = "" with default multiplier, but with upgraded
        // multiplier → adjustedBand becomes .medium → Reasoning Protocol
        #expect(!scaffold.isEmpty)
        #expect(scaffold.contains("Reasoning Protocol"))
    }

    @Test("Low quality feedback decreases multiplier → band downgrade")
    func lowQualityReducesMultiplier() async {
        let budget = ThinkingBudget()
        // Record 5 consecutive low-quality outputs to push multiplier ≤ 0.7
        for _ in 0 ..< 5 {
            await budget.recordQuality(0.1, for: "s1")
        }
        let m = await budget.currentMultiplier(for: "s1")
        #expect(m <= 0.7)

        // A complex-band score should now get medium-band scaffold (downgraded)
        let score = ComplexityScore(
            composite: 0.9, length: 0.8, intent: 0.9, history: 0.7,
            band: .complex, taskType: .code
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "s1")
        // complex → medium downgrade: should get Code Protocol, not 深度代码审查
        #expect(!scaffold.isEmpty)
        // Medium code scaffold does NOT contain "深度"
        #expect(!scaffold.contains("深度代码审查"))
        #expect(scaffold.contains("Code Protocol"))
    }

    // MARK: - Multiplier bounds

    @Test("Multiplier capped at 2.0")
    func multiplierCappedAtMax() async {
        let budget = ThinkingBudget()
        // Record many high-quality outputs
        for _ in 0 ..< 20 {
            await budget.recordQuality(1.0, for: "s1")
        }
        let m = await budget.currentMultiplier(for: "s1")
        #expect(m <= 2.0)
    }

    @Test("Multiplier floor at 0.5")
    func multiplierFloorAtMin() async {
        let budget = ThinkingBudget()
        for _ in 0 ..< 20 {
            await budget.recordQuality(0.0, for: "s1")
        }
        let m = await budget.currentMultiplier(for: "s1")
        #expect(m >= 0.5)
    }

    // MARK: - Per-session isolation

    @Test("Multiplier is per-session, not global")
    func multiplierPerSession() async {
        let budget = ThinkingBudget()
        // Session A gets high quality
        for _ in 0 ..< 5 {
            await budget.recordQuality(0.95, for: "sessionA")
        }
        // Session B gets low quality
        for _ in 0 ..< 5 {
            await budget.recordQuality(0.1, for: "sessionB")
        }

        let mA = await budget.currentMultiplier(for: "sessionA")
        let mB = await budget.currentMultiplier(for: "sessionB")
        #expect(mA > mB)
        #expect(mA >= 1.5)
        #expect(mB <= 0.7)
    }

    // MARK: - Default multiplier for unknown sessions

    @Test("New session uses default multiplier 1.0")
    func defaultMultiplier() async {
        let budget = ThinkingBudget()
        let m = await budget.currentMultiplier(for: "new-session")
        #expect(m == 1.0)
    }

    // MARK: - Band adjustment with default multiplier (no change)

    @Test("Default multiplier preserves score band — no upgrade or downgrade")
    func defaultMultiplierPreservesBand() async {
        let budget = ThinkingBudget()
        let score = ComplexityScore(
            composite: 0.5, length: 0.4, intent: 0.5, history: 0.3,
            band: .medium, taskType: .code
        )
        let scaffold = await budget.scaffolding(for: score, sessionId: "fresh")
        // .medium + .code → mediumCodeScaffold (Code Protocol, no 深度)
        #expect(scaffold.contains("Code Protocol"))
        #expect(!scaffold.contains("深度代码审查"))
    }
}
