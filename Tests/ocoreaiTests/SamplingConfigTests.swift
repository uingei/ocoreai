// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SamplingConfigTests.swift — Sampling normalization logic
///
/// Coverage:
/// - normalized() drops topK/topP when temperature is 0 (greedy mode)
/// - normalized() keeps topK/topP when temperature > 0
/// - nil temperature → drops topK/topP (greedy default)
/// - Equatable conformance

import Testing
@testable import ocoreai

@Suite("SamplingConfiguration Normalization")
struct SamplingConfigTests {
    
    @Test("greedy mode drops topK and topP")
    func greedyDropsSampling() {
        var config = SamplingConfiguration(
            temperature: 0,
            topP: 0.9,
            topK: 50,
            minP: 0.1,
            presencePenalty: 0.2,
            frequencyPenalty: 0.1
        )
        let normalized = config.normalized()
        #expect(normalized.topK == nil)
        #expect(normalized.topP == nil)
        #expect(normalized.temperature == 0)
        // Non-redundant params must survive
        #expect(normalized.presencePenalty == 0.2)
        #expect(normalized.frequencyPenalty == 0.1)
    }
    
    @Test("nil temperature drops topK and topP")
    func nilTempDropsSampling() {
        var config = SamplingConfiguration(
            temperature: nil,
            topP: 0.9,
            topK: 50
        )
        let normalized = config.normalized()
        #expect(normalized.topK == nil)
        #expect(normalized.topP == nil)
    }
    
    @Test("non-zero temperature keeps topK and topP")
    func nonZeroTempKeepsSampling() {
        var config = SamplingConfiguration(
            temperature: 0.7,
            topP: 0.9,
            topK: 50,
            minP: 0.05
        )
        let normalized = config.normalized()
        #expect(normalized.topK == 50)
        #expect(normalized.topP == 0.9)
        #expect(normalized.temperature == 0.7)
    }
    
    @Test("normalized is no-op when nothing to drop")
    func normalizedNoOp() {
        var config = SamplingConfiguration(
            temperature: 0.7,
            presencePenalty: 0.1
        )
        let normalized = config.normalized()
        #expect(normalized == config)
    }
    
    @Test("Equatable detects normalization difference")
    func equatableDetectsNormalization() {
        var config = SamplingConfiguration(
            temperature: 0,
            topP: 0.9,
            topK: 50
        )
        let normalized = config.normalized()
        #expect(normalized != config) // topK/topP were dropped
    }
}
