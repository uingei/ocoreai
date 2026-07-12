// Copyright (c) 2026 uingei@163.com.
// Licensed under MIT.
// Reasoning model tests - ComplexityScore, ComplexityBand, TaskType, ThinkingTelemetry

import Testing
import Foundation
@testable import ocoreai

@Suite("ComplexityScore")
struct ComplexityScoreTests {

    @Test("Construction with simple band")
    func simpleScore() {
        let score = ComplexityScore(
            composite: 0.2,
            length: 0.1,
            intent: 0.2,
            history: 0.1,
            band: .simple,
            taskType: .general
        )
        #expect(score.composite == 0.2)
        #expect(score.band == .simple)
        #expect(score.taskType == .general)
    }

    @Test("Construction with complex band for code task")
    func complexCodeScore() {
        let score = ComplexityScore(
            composite: 0.95,
            length: 0.8,
            intent: 0.9,
            history: 0.7,
            band: .complex,
            taskType: .code
        )
        #expect(score.composite < 1.0)
        #expect(score.band == .complex)
        #expect(score.taskType == .code)
    }

    @Test("Sendable concurrent access safe")
    func sendableAccess() async {
        let score = ComplexityScore(
            composite: 0.5,
            length: 0.4,
            intent: 0.5,
            history: 0.3,
            band: .medium,
            taskType: .analysis
        )
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    #expect(score.composite == 0.5)
                }
            }
        }
    }
}

@Suite("ComplexityBand threshold mapping")
struct ComplexityBandThresholdTests {

    @Test("Score 0.0 maps to simple")
    func zeroIsSimple() {
        #expect(ComplexityBand.for(score: 0.0) == .simple)
    }

    @Test("Score 0.33 maps to simple")
    func justBelowThreshold() {
        #expect(ComplexityBand.for(score: 0.33) == .simple)
    }

    @Test("Score 0.34 maps to medium")
    func atMediumThreshold() {
        #expect(ComplexityBand.for(score: 0.34) == .medium)
    }

    @Test("Score 0.5 maps to medium")
    func midRangeIsMedium() {
        #expect(ComplexityBand.for(score: 0.5) == .medium)
    }

    @Test("Score 0.66 maps to medium")
    func justBelowComplex() {
        #expect(ComplexityBand.for(score: 0.66) == .medium)
    }

    @Test("Score 0.67 maps to complex")
    func atComplexThreshold() {
        #expect(ComplexityBand.for(score: 0.67) == .complex)
    }

    @Test("Score 1.0 maps to complex")
    func maxIsComplex() {
        #expect(ComplexityBand.for(score: 1.0) == .complex)
    }

    @Test("Band raw values match names")
    func rawValues() {
        #expect(ComplexityBand.simple.rawValue == "simple")
        #expect(ComplexityBand.medium.rawValue == "medium")
        #expect(ComplexityBand.complex.rawValue == "complex")
    }
}

@Suite("TaskType")
struct TaskTypeTests {

    @Test("All task types exist")
    func allTypesExist() {
        let expected: [TaskType] = [
            .general, .code, .math, .json,
            .comparison, .analysis, .factual, .casual
        ]
        #expect(expected.count == 8)
    }

    @Test("TaskType Codable round-trip for all types")
    func allCodable() throws {
        let types: [TaskType] = [
            .general, .code, .math, .json,
            .comparison, .analysis, .factual, .casual
        ]
        for type in types {
            let data = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(TaskType.self, from: data)
            #expect(decoded == type)
        }
    }

    @Test("TaskType raw values")
    func rawValues() {
        #expect(TaskType.code.rawValue == "code")
        #expect(TaskType.math.rawValue == "math")
        #expect(TaskType.json.rawValue == "json")
        #expect(TaskType.analysis.rawValue == "analysis")
    }
}

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
