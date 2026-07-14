// Copyright (c) 2026 uingei@163.com.
// Licensed under MIT.
// Reasoning model tests - ThinkingTelemetry quality scoring + ThinkingBudget multiplier feedback
// Removed: ComplexityScore struct (compiler-enforced fields), ComplexityBand rawValues, TaskType enum
// (all self-proof — Codable round-trip is a language guarantee)

import Testing
import Foundation
@testable import ocoreai
import ocoreaiTestUtilities

@Suite("ThinkingTelemetry quality scoring")
struct ThinkingTelemetryTests {

    private func quality(
        complexity: Double,
        outputTokens: Int,
        maxTokens: Int = 4096,
        iterations: Int = 1,
        toolCalls: Int = 0,
        finishReason: String
    ) async -> Double {
        let budget = ThinkingBudget()
        return await ThinkingTelemetry.signal(
            sessionId: "test-session",
            complexity: complexity,
            outputTokens: outputTokens,
            maxTokens: maxTokens,
            iterationCount: iterations,
            toolCallCount: toolCalls,
            finishReason: finishReason,
            budget: budget
        )
    }

    @Test("Stop reason yields high quality with strong signals")
    func stopReasonHighQuality() async {
        let q = await quality(
            complexity: 0.8,
            outputTokens: 3686,
            iterations: 3,
            toolCalls: 2,
            finishReason: "stop"
        )
        #expect(q > 0.6)
        #expect(q <= 1.0)
    }

    @Test("Stop scores higher than max_tokens")
    func stopVsMaxTokens() async {
        let stopQ = await quality(complexity: 0.8, outputTokens: 100, finishReason: "stop")
        let maxQ = await quality(complexity: 0.8, outputTokens: 100, finishReason: "max_tokens")
        #expect(stopQ > maxQ)
    }

    @Test("Error finish reason produces zero quality")
    func errorFinishZero() async {
        let q = await quality(complexity: 0.8, outputTokens: 4000, finishReason: "error")
        #expect(q == 0.0)
    }

    @Test("Timeout finish reason produces zero quality")
    func timeoutFinishZero() async {
        let q = await quality(complexity: 0.8, outputTokens: 4000, finishReason: "timeout")
        #expect(q == 0.0)
    }

    @Test("Cancelled finish reason produces zero quality")
    func cancelledFinishZero() async {
        let q = await quality(complexity: 0.8, outputTokens: 2000, finishReason: "cancelled")
        #expect(q == 0.0)
    }

    @Test("Short output on complex task penalizes quality")
    func shortOutputComplexTask() async {
        let q = await quality(complexity: 0.8, outputTokens: 40, finishReason: "stop")
        #expect(q < 0.8)
    }

    @Test("Brief output on simple task scores reasonably")
    func briefOutputSimpleTask() async {
        let q = await quality(complexity: 0.1, outputTokens: 120, finishReason: "stop")
        #expect(q > 0.3)
    }

    @Test("Full output on medium task scores well")
    func fullOutputMediumTask() async {
        let q = await quality(complexity: 0.5, outputTokens: 3500, finishReason: "stop")
        #expect(q > 0.6)
    }

    @Test("Multi-turn with tools boosts quality")
    func multiTurnToolBoost() async {
        let singleQ = await quality(complexity: 0.8, outputTokens: 2867, finishReason: "stop")
        let multiQ = await quality(
            complexity: 0.8,
            outputTokens: 2867,
            iterations: 5,
            toolCalls: 4,
            finishReason: "stop"
        )
        #expect(multiQ > singleQ)
    }

    @Test("Quality clamped to [0.0, 1.0] range")
    func qualityClamped() async {
        #expect(await quality(complexity: 0.0, outputTokens: 0, finishReason: "stop") >= 0.0)
        #expect(await quality(complexity: 1.0, outputTokens: 10000, finishReason: "stop") <= 1.0)
        #expect(await quality(complexity: 0.5, outputTokens: 100, finishReason: "error") == 0.0)
    }

    @Test("High quality bumps budget multiplier")
    func qualityBumpsMultiplier() async {
        let budget = ThinkingBudget()
        let initial = await budget.currentMultiplier(for: "s1")
        #expect(initial == 1.0)
        for _ in 0..<5 {
            await budget.recordQuality(0.95, for: "s1")
        }
        let after = await budget.currentMultiplier(for: "s1")
        #expect(after > initial)
    }

    @Test("Low quality reduces multiplier")
    func lowQualityReducesMultiplier() async {
        let budget = ThinkingBudget()
        for _ in 0..<5 {
            await budget.recordQuality(0.1, for: "s2")
        }
        let after = await budget.currentMultiplier(for: "s2")
        #expect(after < 1.0)
    }

    @Test("Sessions maintain independent multipliers")
    func independentSessionMultipliers() async {
        let budget = ThinkingBudget()
        for _ in 0..<5 {
            await budget.recordQuality(0.95, for: "sessionA")
            await budget.recordQuality(0.1, for: "sessionB")
        }
        let a = await budget.currentMultiplier(for: "sessionA")
        let b = await budget.currentMultiplier(for: "sessionB")
        #expect(a > b)
    }

    @Test("Convenience overload works correctly")
    func convenienceOverload() async {
        let budget = ThinkingBudget()
        let q = await ThinkingTelemetry.signal(
            sessionId: "conv-sesh",
            complexity: 0.7,
            outputTokens: 3000,
            maxTokens: 4096,
            iterationCount: 2,
            toolCallCount: 1,
            finishReason: "stop",
            budget: budget
        )
        #expect(q > 0.5)
        #expect(q <= 1.0)
    }
}
