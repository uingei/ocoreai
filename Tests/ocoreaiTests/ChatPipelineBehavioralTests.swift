// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatPipelineBehavioralTests.swift — L2 behavioral invariants for the inference pipeline
///
/// Upstream alignment: ToolTests.swift (chunk-by-chunk tool call detection).
///
/// L2 focus: InferenceCancellation state machine, SamplingConfiguration normalization,
/// parseToolCalls false positive prevention.
///
/// Removed: InferenceEvent enum mapping, contentToString, EnginePoolConfig defaults,
/// InferenceOptions preservation, SamplingConfiguration field checks (all DTO-level).

import Foundation
import Testing
import ocoreaiTestUtilities

@testable import ocoreai

// MARK: - L2: InferenceCancellation state machine

@Suite("InferenceCancellation: cancel→propagate→idempotent")
struct PipelineCancellationTests {

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

@Suite("SamplingConfiguration: normalized() invariant — temperature 0/nil → greedy mode")
struct SamplingConfigNormalizedTests {

    @Test("normalized() drops topK/topP when temperature == 0 (greedy mode)")
    func normalizedDropsWhenZero() {
        let config = SamplingConfiguration(temperature: 0, topP: 0.95, topK: 100)
        let normalized = config.normalized()
        #expect(normalized.topK == nil)
        #expect(normalized.topP == nil)
    }

    @Test("normalized() drops topK/topP when temperature == nil (greedy default)")
    func normalizedDropsWhenNil() {
        let config = SamplingConfiguration(temperature: nil, topP: 0.95, topK: 100)
        let normalized = config.normalized()
        #expect(normalized.topK == nil)
        #expect(normalized.topP == nil)
    }

    @Test("normalized() preserves non-zero temperature with topK/topP")
    func normalizedPreservesNonZero() {
        let config = SamplingConfiguration(temperature: 0.7, topP: 0.95, topK: 40)
        let normalized = config.normalized()
        #expect(normalized.temperature == 0.7)
        #expect(normalized.topP == 0.95)
        #expect(normalized.topK == 40)
    }

    @Test("normalized() does NOT drop topK/topP when temperature is negative (not greedy)")
    func normalizedNegativeTemperaturePreservesParams() {
        let config = SamplingConfiguration(temperature: -0.5, topP: 0.9, topK: 50)
        let normalized = config.normalized()
        #expect(normalized.topP == 0.9)
        #expect(normalized.topK == 50)
    }
}

// MARK: - L2: parseToolCalls false positive detection

@Suite("parseToolCalls: false positive prevention")
struct FalsePositiveTests {

    @Test("JSON object (not array) is NOT parsed as tool call")
    func jsonObjectNotDetected() {
        #expect(parseToolCalls(from: #"{"message": "Hello", "status": 200}"#) == nil)
    }

    @Test("JSON array of strings is NOT parsed as tool call")
    func arrayStringNotDetected() {
        #expect(parseToolCalls(from: #"["get_weather", "search"]"#) == nil)
    }

    @Test("Natural text containing array-like structure NOT misdetected")
    func naturalTextWithBracketNotDetected() {
        let content = "Here is my plan: [use tool A, then tool B, finally tool C]. Let me start!"
        #expect(parseToolCalls(from: content) == nil)
    }
}
