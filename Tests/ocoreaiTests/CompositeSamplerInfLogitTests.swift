// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// CompositeSamplerInfLogitTests.swift — the CPU fallback sampler survives a +inf logit.
///
/// coreai-models #524 (eed1a35) convicted the shared defect: an fp16 logit that overflowed to
/// +inf made `softmax` compute `inf - inf = NaN` at that position; this copy's `sum.isFinite`
/// guard then returned an all-zero distribution, and the inverse-CDF sample fell through to a
/// silent token id — the request kept generating, off-distribution, reporting nothing. #524's
/// stated limit is what the port implements: with a +inf present the softmax is uniform over
/// exactly the +inf positions.
///
/// The O(V log V) sort avoidance of the same commit is not ported: it is a latency change on a
/// fallback lane whose callers already accept CPU latency, and shipping half of a tested
/// upstream commit is the split this window read exists to stop. Ledger row:
/// docs/agent/coreai-fork-window-log.md.

import Foundation
import Testing

#if canImport(CoreAI)

@testable import ocoreai

@Suite("CPU CompositeSampler: a +inf logit yields the +inf positions, not a silent token 0")
struct CompositeSamplerInfLogitTests {

    @Test("softmax with +inf is uniform over exactly the +inf positions")
    func softmaxUniformOverInf() {
        var logits: [Float] = [1.0, .infinity, 3.0, .infinity, -2.0]
        let probs = CompositeSampler.softmax(&logits)
        #expect(probs[0] == 0)
        #expect(probs[1] == 0.5)
        #expect(probs[2] == 0)
        #expect(probs[3] == 0.5)
        #expect(probs[4] == 0)
    }

    @Test("the finite path is unchanged by the guard")
    func softmaxFiniteUnchanged() {
        var logits: [Float] = [0, 0]
        let probs = CompositeSampler.softmax(&logits)
        #expect(probs[0] == 0.5)
        #expect(probs[1] == 0.5)
    }

    @Test("sampling a logits vector with one +inf returns that id under any temperature > 0")
    func sampleReturnsInfPosition() {
        let config = SamplingConfiguration(temperature: 0.8)
        var rng = SystemRandomNumberGenerator()
        for _ in 0 ..< 16 {
            // The sampler feeds its filtered distribution back into `logits`, so each draw
            // starts from the overflowed logits a real step produces.
            var logits = [LogitsScalarType](repeating: 0, count: 64)
            logits[5] = .infinity
            #expect(CompositeSampler.sample(from: &logits, config: config, using: &rng) == 5)
        }
    }
}

#endif
