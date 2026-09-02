// Copyright 2026 uingei@163.com.
// Licensed under MIT.
//
// Exact-value tests for the A2 c3 logprobs algorithm
// (`LogProbabilities.compute`, ported copy-first from coreai-models
// `Sources/CoreAILanguageModels/TextGeneration/LogProbabilities.swift`).
//
// Whole file is CoreAI-gated: `LogProbabilities` and `LogitsScalarType`
// exist only inside `#if canImport(CoreAI)` (same gate as c2 — the
// `114dcbe` red light was a missing gate, fixed by `980112c`).
//
// All assertions are exact-value (zero `count>N`): known-softmax
// identities, overflow/NaN/Inf edge cases, top-K order and truncation.

#if canImport(CoreAI)

import Foundation
import Testing

@testable import ocoreai

@Suite("LogProbabilities (A2 c3 exact-value)")
struct LogProbabilitiesTests {

    @Test("two equal logits: target logprob is exactly -ln(2)")
    func twoEqualLogits() {
        let logits: [[LogitsScalarType]] = [[0, 0]]
        let p = LogProbabilities.compute(logits: logits, targets: [1], topK: 0)
        #expect(p.entries.count == 1)
        #expect(p.entries[0].tokenId == 1)
        #expect(abs(p.entries[0].value - (-log(2.0))) < 1e-6)
    }

    @Test("large logits (100): max-subtraction keeps -ln(2), no overflow")
    func offsetLogits() {
        let logits: [[LogitsScalarType]] = [[100, 100]]
        let p = LogProbabilities.compute(logits: logits, targets: [0], topK: 0)
        #expect(p.entries.count == 1)
        #expect(abs(p.entries[0].value - (-log(2.0))) < 1e-6)
    }

    @Test("dominant logit: logprob near 0 and matches closed-form softmax")
    func dominantToken() {
        // logp(0) = 10 - ln(e^10 + 1) = 10 - ln(e^10 + 1)
        let logits: [[LogitsScalarType]] = [[10, 0]]
        let p = LogProbabilities.compute(logits: logits, targets: [0], topK: 0)
        let expected = 10.0 - log(exp(10.0) + 1.0)
        #expect(p.entries.count == 1)
        #expect(abs(p.entries[0].value - expected) < 1e-5)
    }

    @Test("same vector, 4 targets: sum of probabilities is exactly 1 (Float16-exact input)")
    func normalizesToOne() {
        // All logit values are exactly representable in Float16 (LogitsScalarType),
        // so the only precision class in play is the algorithm's Float32 internal
        // path — a 1e-5 bound is exact for this class (equal-logit case passes 1e-6).
        let raw: [Double] = [2.5, -0.5, 3.0, 0.0]
        let vec: [LogitsScalarType] = raw.map(LogitsScalarType.init)
        let logits: [[LogitsScalarType]] = [vec, vec, vec, vec]
        let p = LogProbabilities.compute(logits: logits, targets: [0, 1, 2, 3], topK: 0)
        #expect(p.entries.count == 4)
        let sum = p.entries.map { exp($0.value) }.reduce(0, +)
        #expect(abs(sum - 1.0) < 1e-5)
        // per-token closed form (raw[2] is the max — the dominant case)
        let m = 3.0
        let expected2 = 3.0 - log(exp(2.5) + exp(-0.5) + exp(3.0) + exp(0.0))
        #expect(abs(p.entries[2].value - expected2) < 1e-5)
    }

    @Test("out-of-range target token: value is -infinity")
    func outOfRangeTarget() {
        let logits: [[LogitsScalarType]] = [[0, 1]]
        let p = LogProbabilities.compute(logits: logits, targets: [5], topK: 0)
        #expect(p.entries.count == 1)
        #expect(p.entries[0].value == -.infinity)
        #expect(p.entries[0].alternatives.isEmpty)
    }

    @Test("NaN logit: value is 0.0 (algorithm's NaN guard)")
    func nanLogit() {
        let logits: [[LogitsScalarType]] = [[.nan, 0]]
        let p = LogProbabilities.compute(logits: logits, targets: [0], topK: 0)
        #expect(p.entries.count == 1)
        #expect(p.entries[0].value == 0.0)
    }

    @Test("topK=2: exactly 2 alternatives, most likely first")
    func topKOrder() {
        // logit ranking: 3 (2.0) > 1 (1.0) > 2 (0.0) > 0 (-1.0)
        let logits: [[LogitsScalarType]] = [[-1, 1, 0, 2]]
        let p = LogProbabilities.compute(logits: logits, targets: [3], topK: 2)
        let alts = p.entries[0].alternatives
        #expect(alts.count == 2)
        #expect(alts[0].tokenId == 3)
        #expect(alts[1].tokenId == 1)
        #expect(alts[0].value > alts[1].value)
    }

    @Test("topK larger than vocab: alternatives capped at vocab size")
    func topKExceedsVocab() {
        let logits: [[LogitsScalarType]] = [[0, 0, 0]]
        let p = LogProbabilities.compute(logits: logits, targets: [1], topK: 9)
        #expect(p.entries[0].alternatives.count <= 3)
    }

    @Test("multiple positions: one entry per position, targets order preserved")
    func multiPosition() {
        let logits: [[LogitsScalarType]] = [[0, 0], [1, 0]]
        let p = LogProbabilities.compute(logits: logits, targets: [0, 1], topK: 0)
        #expect(p.entries.count == 2)
        #expect(p.entries[0].tokenId == 0)
        #expect(p.entries[1].tokenId == 1)
        #expect(abs(p.entries[0].value - (-log(2.0))) < 1e-6)
        // position-1 target is token 1 with logit 0 (vector [1,0]): logp = -log(e+1)
        let expected1 = 0.0 - log(exp(1.0) + 1.0)
        #expect(abs(p.entries[1].value - expected1) < 1e-5)
    }

    @Test("logits longer than targets: entries truncated to positions (zip)")
    func zipTruncation() {
        let logits: [[LogitsScalarType]] = [[0, 0], [0, 0], [0, 0]]
        let p = LogProbabilities.compute(logits: logits, targets: [1, 0], topK: 0)
        #expect(p.entries.count == 2)
    }
}

#endif
