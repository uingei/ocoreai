// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// #176 alignment — `RepetitionPenaltyProcessor` + `fallbackSampler(from:tokenHistory:)`.
// Aligned with upstream coreai-models `Samplers/RepetitionPenaltyProcessor.swift`
// + `Samplers/SamplingConfiguration.swift` @ 5660fc6 (merged 2026-08-20).
//
// Upstream test source: `Tests/LanguageModelsTests/RepetitionPenaltyProcessorTests.swift`.
// Re-written to ocoreai's @testable import + canImport gate (upstream used
// `@testable import CoreAILanguageModels` + `import CoreAIShared`).
//
// Guarded with `#if canImport(CoreAI)`: the symbols under test
// (RepetitionPenaltyProcessor, the fallbackSampler extension, and the
// LogitsScalarType sampler pipeline in CompositeSampler.swift) live inside a
// `#if canImport(CoreAI)` block (CompositeSampler.swift:11). On the macos-26
// runner (Xcode 26.6 / SDK 26.5) the CoreAI framework is absent, so that block
// is not compiled and there is nothing to test — the compiler skips the whole
// suite, identical convention to NDArrayHelpersAlignmentTests.swift (F1).
// On a macOS 27 target (canImport true) the suite runs and exercises the
// sign-aware divide/multiply, dedup, range-guard, window scoping, and the
// tokenHistory → penalty → sample path end to end.

import Foundation
import Testing

#if canImport(CoreAI)

@testable import ocoreai

@Suite("RepetitionPenaltyProcessor (#176 alignment with coreai-models 5660fc6)")
struct RepetitionPenaltyProcessorTests {

    @Test("Positive logits are divided by penalty")
    func positiveLogitsDivided() {
        var logits: [LogitsScalarType] = [0, 0, LogitsScalarType(2.0), 0, 0]
        RepetitionPenaltyProcessor.apply(to: &logits, recentTokenIds: [2], penalty: 2.0)
        #expect(abs(Float(logits[2]) - 1.0) < 1e-3)
    }

    @Test("Negative logits are multiplied by penalty")
    func negativeLogitsMultiplied() {
        var logits: [LogitsScalarType] = [0, 0, LogitsScalarType(-2.0), 0, 0]
        RepetitionPenaltyProcessor.apply(to: &logits, recentTokenIds: [2], penalty: 2.0)
        #expect(abs(Float(logits[2]) - (-4.0)) < 1e-2)
    }

    @Test("Zero logits unchanged")
    func zeroLogitsUnchanged() {
        var logits: [LogitsScalarType] = [0, 0, 0, 0, 0]
        RepetitionPenaltyProcessor.apply(
            to: &logits, recentTokenIds: [0, 1, 2, 3, 4], penalty: 1.5)
        for l in logits {
            #expect(l == 0)
        }
    }

    @Test("Penalty of 1.0 is a no-op")
    func penaltyOneIsNoop() {
        var logits: [LogitsScalarType] = [LogitsScalarType(3.0), LogitsScalarType(-1.0)]
        let original = logits
        RepetitionPenaltyProcessor.apply(to: &logits, recentTokenIds: [0, 1], penalty: 1.0)
        #expect(logits == original)
    }

    @Test("Duplicate token IDs penalized only once")
    func deduplication() {
        var logits1: [LogitsScalarType] = [LogitsScalarType(4.0), 0, 0]
        var logits2: [LogitsScalarType] = [LogitsScalarType(4.0), 0, 0]
        RepetitionPenaltyProcessor.apply(to: &logits1, recentTokenIds: [0], penalty: 2.0)
        RepetitionPenaltyProcessor.apply(to: &logits2, recentTokenIds: [0, 0, 0], penalty: 2.0)
        #expect(logits1[0] == logits2[0])
    }

    @Test("Out-of-range token IDs are ignored")
    func outOfRangeIgnored() {
        var logits: [LogitsScalarType] = [LogitsScalarType(1.0), LogitsScalarType(2.0)]
        RepetitionPenaltyProcessor.apply(to: &logits, recentTokenIds: [-1, 5, 100], penalty: 2.0)
        #expect(Float(logits[0]) == 1.0)
        #expect(Float(logits[1]) == 2.0)
    }

    @Test("fallbackSampler with tokenHistory applies penalty")
    func fallbackSamplerWithHistory() {
        let config = SamplingConfiguration(temperature: 0, repetitionPenalty: 2.0)
        // Token 0 has the highest logit but is penalized by history [0]; token 1 wins.
        var logits: [LogitsScalarType] = [
            LogitsScalarType(3.0), LogitsScalarType(2.0), LogitsScalarType(1.0),
        ]
        let token = config.fallbackSampler(from: &logits, tokenHistory: [0] as [Int32])
        #expect(token == 1)
    }

    @Test("Window limits which tokens are penalized")
    func windowLimitsScope() {
        let config = SamplingConfiguration(
            temperature: 0, repetitionPenalty: 2.0, repetitionPenaltyWindow: 1)
        // History [0, 1] but window=1 → only the last token (1) is penalized.
        // Token 1: 3.0/2.0 = 1.5 (drops below token 0's 2.0) → token 0 wins.
        var logits: [LogitsScalarType] = [
            LogitsScalarType(2.0), LogitsScalarType(3.0), LogitsScalarType(1.0),
        ]
        let token = config.fallbackSampler(from: &logits, tokenHistory: [0, 1] as [Int32])
        #expect(token == 0)
    }
}

#endif  // canImport(CoreAI)
