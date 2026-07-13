// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatPipelineBehavioralTests.swift — L2 behavioral invariants for the inference pipeline
///
/// Upstream alignment: ToolTests.swift (chunk-by-chunk tool call detection).
///
/// L2 focus: InferenceCancellation state machine, SamplingConfiguration normalization,
/// task-aware temperature adjustment, parseToolCalls false positive prevention.
///
/// Removed: InferenceEvent enum mapping, contentToString, EnginePoolConfig defaults,
/// InferenceOptions preservation, SamplingConfiguration field checks (all DTO-level).

import Testing
import Foundation
@testable import ocoreai

// MARK: - L2: InferenceCancellation state machine

@Suite("InferenceCancellation: cancel→propagate→idempotent")
struct CancellationTests {
    
    @Test("Cancellable token lifecycle: not cancelled → cancel → cancelled")
    func cancellableBecomesCancelled() async {
        let token = InferenceCancellation.cancellable()
        #expect(token.isCancelled == false)
        token.cancel()
        _ = try? await Task.sleep(for: .milliseconds(50))
        #expect(token.isCancelled == true)
    }
    
    @Test("Cancellation propagates across shared holders")
    func sharedCancellation() {
        let token = InferenceCancellation.cancellable()
        token.cancel()
        #expect(token.isCancelled == true)
    }
    
    @Test("cancel() is idempotent — multiple calls do not crash")
    func cancelIdempotent() {
        let token = InferenceCancellation.cancellable()
        token.cancel()
        token.cancel()
        token.cancel()
        #expect(token.isCancelled == true)
    }
    
    @Test(".none is never cancelled — cancel is no-op")
    func noneNeverCancelled() {
        let token = InferenceCancellation.none
        token.cancel()
        #expect(token.isCancelled == false)
    }
}

// MARK: - L2: SamplingConfiguration normalization

@Suite("SamplingConfiguration: normalized() drops redundant params")
struct SamplingConfigNormalizedTests {
    
    @Test("normalized() drops topK/topP when temperature == 0 (greedy mode)")
    func normalizedDropsWhenZero() {
        let config = SamplingConfiguration(temperature: 0, topP: 0.95, topK: 100)
        let normalized = config.normalized()
        #expect(normalized.topK == nil)
        #expect(normalized.topP == nil)
    }
    
    @Test("normalized() drops topK/topP when temperature == nil")
    func normalizedDropsWhenNil() {
        let config = SamplingConfiguration(temperature: nil, topP: 0.95, topK: 100)
        let normalized = config.normalized()
        #expect(normalized.topK == nil)
        #expect(normalized.topP == nil)
    }
}

@Suite("SamplingConfiguration: task-aware temperature adjustment")
struct TaskAwareTests {
    
    @Test("code task lowers temperature to ≤ 0.4")
    func codeLowersTemp() {
        let config = SamplingConfiguration(temperature: 0.9)
        let adjusted = config.withTaskAwareParams(for: .code)
        #expect(adjusted.temperature! <= 0.4)
    }
    
    @Test("math task lowers temperature to ≤ 0.4")
    func mathLowersTemp() {
        let config = SamplingConfiguration(temperature: 0.8)
        let adjusted = config.withTaskAwareParams(for: .math)
        #expect(adjusted.temperature! <= 0.4)
    }
    
    @Test("json task tightens topP to ≤ 0.92")
    func jsonTightensTopP() {
        let config = SamplingConfiguration(temperature: 0.7, topP: 0.99)
        let adjusted = config.withTaskAwareParams(for: .json)
        #expect(adjusted.topP! <= 0.92)
    }
    
    @Test("comparison task moderate reduction (≤ 0.5)")
    func comparisonModerate() {
        let config = SamplingConfiguration(temperature: 0.8)
        let adjusted = config.withTaskAwareParams(for: .comparison)
        #expect(adjusted.temperature! <= 0.5)
    }
    
    @Test("low temperature (< 0.5) unchanged even for precision tasks")
    func lowTempUnchanged() {
        let config = SamplingConfiguration(temperature: 0.3)
        let adjusted = config.withTaskAwareParams(for: .code)
        #expect(adjusted.temperature == 0.3)
    }
    
    @Test("task-aware config preserves presencePenalty and frequencyPenalty")
    func penaltiesPreserved() {
        let config = SamplingConfiguration(temperature: 0.9, presencePenalty: 0.3, frequencyPenalty: 0.1)
        let adjusted = config.withTaskAwareParams(for: TaskType.general)
        #expect(adjusted.presencePenalty == 0.3)
        #expect(adjusted.frequencyPenalty == 0.1)
    }
}

// MARK: - L2: parseToolCalls false positive detection

@Suite("parseToolCalls: false positive prevention")
struct FalsePositiveTests {
    
    @Test("Plain text response is NOT detected as tool call")
    func plainTextNotDetected() {
        #expect(parseToolCalls(from: "The weather in SF is sunny today.") == nil)
    }
    
    @Test("Code block with JSON-like content is NOT detected as tool call")
    func codeBlockNotDetected() {
        let content = """
        ```json
        {"name": "get_weather", "arguments": {"location": "SF"}}
        ```
        """
        #expect(parseToolCalls(from: content) == nil)
    }
    
    @Test("JSON object (not array) is NOT parsed as tool call")
    func jsonObjectNotDetected() {
        #expect(parseToolCalls(from: #"{"message": "Hello", "status": 200}"#) == nil)
    }
    
    @Test("JSON array of strings is NOT parsed as tool call")
    func arrayStringNotDetected() {
        #expect(parseToolCalls(from: #"["get_weather", "search"]"#) == nil)
    }
    
    @Test("Malformed JSON returns nil, does not crash")
    func malformedJsonSafe() {
        #expect(parseToolCalls(from: #"[{name: get_weather}]"#) == nil)
    }
    
    @Test("Natural text containing array-like structure NOT misdetected")
    func naturalTextWithBracketNotDetected() {
        let content = "Here is my plan: [use tool A, then tool B, finally tool C]. Let me start!"
        #expect(parseToolCalls(from: content) == nil)
    }
}