// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AgentLoopModelTests.swift — AgentLoop data model tests (pure structs, no backend needed)

import Foundation
import Testing
@testable import ocoreai

@Suite("AgentLoopResult")
struct AgentLoopResultTests {
    @Test("Defaults: empty text, stop finish reason, 0 iterations")
    func defaults() {
        let result = AgentLoopResult()
        #expect(result.text == "")
        #expect(result.iterationCount == 0)
        #expect(result.iters.isEmpty)
        #expect(result.finishReason == "stop")
        #expect(result.totalTokens == 0)
        #expect(result.toolCalls == nil)
    }
    
    @Test("Stop response with text")
    func stopResponse() {
        var result = AgentLoopResult()
        result.text = "Hello, how can I help?"
        result.iterationCount = 1
        result.finishReason = "stop"
        #expect(result.text == "Hello, how can I help?")
        #expect(result.finishReason == "stop")
    }
    
    @Test("Tool call response")
    func toolCallResponse() {
        var result = AgentLoopResult()
        result.text = ""
        result.toolCalls = [ToolCall(
            id: "call1",
            type: "function",
            function: ToolCallFunction(name: "search", arguments: "{\"q\": \"test\"}")
        )]
        result.iterationCount = 1
        result.finishReason = "tool_calls"
        #expect(result.toolCalls?.count == 1)
        #expect(result.toolCalls?.first?.function.name == "search")
    }
    
    @Test("Max iteration result")
    func maxIterResult() {
        var result = AgentLoopResult()
        result.text = "[agent-loop: max iterations reached]"
        result.iterationCount = 30
        result.finishReason = "max_iter"
        #expect(result.finishReason == "max_iter")
    }
    
    @Test("Timeout result")
    func timeoutResult() {
        var result = AgentLoopResult()
        result.text = "[agent-loop: timeout after 180s]"
        result.finishReason = "timeout"
        #expect(result.finishReason == "timeout")
    }
}

@Suite("AgentLoopIterationLog")
struct AgentLoopIterationLogTests {
    @Test("Description format contains iteration, token count, tool count")
    func descriptionFormat() {
        let log = AgentLoopIterationLog(
            iteration: 3,
            tok: 256,
            toolN: 2,
            ms: 450.7,
            tag: "[search,calculate]"
        )
        let desc = log.description
        #expect(desc.contains("iter-3"))
        #expect(desc.contains("tok=256"))
        #expect(desc.contains("tools=2"))
        #expect(desc.contains("[search,calculate]"))
    }
}

@Suite("SamplingConfiguration")
struct SamplingConfigurationTests {
    @Test("Default config has all nils and combined=true")
    func defaults() {
        let config = SamplingConfiguration()
        #expect(config.seed == nil)
        #expect(config.temperature == nil)
        #expect(config.topP == nil)
        #expect(config.topK == nil)
        #expect(config.minP == nil)
        #expect(config.repetitionPenalty == nil)
        #expect(config.presencePenalty == nil)
        #expect(config.frequencyPenalty == nil)
        #expect(config.stopSequences == nil)
        #expect(config.logitBias == nil)
        #expect(config.combined == true)
    }
    
    @Test("Config with values")
    func withValues() {
        let config = SamplingConfiguration(
            seed: 42,
            temperature: 0.8,
            topP: 0.9,
            topK: 50,
            minP: 0.05,
            repetitionPenalty: 1.1,
            stopSequences: ["\n"],
            combined: false
        )
        #expect(config.seed == 42)
        #expect(config.temperature == 0.8)
        #expect(config.topP == 0.9)
        #expect(config.topK == 50)
        #expect(config.combined == false)
    }
    
    @Test("Normalized with temperature=0 drops topK/topP (greedy mode)")
    func normalizedGreedyDropsSampling() {
        let config = SamplingConfiguration(
            temperature: 0,
            topP: 0.9,
            topK: 50
        )
        let normalized = config.normalized()
        #expect(normalized.temperature == 0)
        #expect(normalized.topK == nil)
        #expect(normalized.topP == nil)
    }
    
    @Test("Normalized with nil temperature drops topK/topP")
    func normalizedNilTempDropsSampling() {
        let config = SamplingConfiguration(
            temperature: nil,
            topP: 0.9,
            topK: 50
        )
        let normalized = config.normalized()
        #expect(normalized.topK == nil)
        #expect(normalized.topP == nil)
    }
    
    @Test("Normalized preserves non-sampling fields")
    func normalizedPreservesFields() {
        let config = SamplingConfiguration(
            seed: 99,
            temperature: 0.7,
            minP: 0.1,
            repetitionPenalty: 1.2,
            stopSequences: ["END"],
            combined: false
        )
        let normalized = config.normalized()
        #expect(normalized.seed == 99)
        #expect(normalized.temperature == 0.7)
        #expect(normalized.minP == 0.1)
        #expect(normalized.repetitionPenalty == 1.2)
        #expect(normalized.stopSequences == ["END"])
        #expect(normalized.combined == false)
    }
    
    @Test("SamplingConfiguration equatable")
    func equatable() {
        let a = SamplingConfiguration(seed: 1, temperature: 0.5)
        let b = SamplingConfiguration(seed: 1, temperature: 0.5)
        let c = SamplingConfiguration(seed: 2, temperature: 0.5)
        #expect(a == b)
        #expect(a != c)
    }
    
    @Test("Codable roundtrip")
    func codableRoundtrip() throws {
        let original = SamplingConfiguration(
            seed: 42,
            temperature: 0.8,
            topP: 0.95,
            stopSequences: ["\n\n\n"],
            combined: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SamplingConfiguration.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("InferenceOptions")
struct InferenceOptionsTests {
    @Test("Defaults")
    func defaults() {
        let opts = InferenceOptions()
        #expect(opts.maxTokens == nil)
        #expect(opts.includeLogits == false)
    }
    
    @Test("With maxTokens")
    func withMaxTokens() {
        let opts = InferenceOptions(maxTokens: 2048, includeLogits: true)
        #expect(opts.maxTokens == 2048)
        #expect(opts.includeLogits == true)
    }
    
    @Test("Codable roundtrip")
    func codable() throws {
        let original = InferenceOptions(maxTokens: 4096, includeLogits: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InferenceOptions.self, from: data)
        #expect(decoded.maxTokens == 4096)
        #expect(decoded.includeLogits == true)
    }
}
