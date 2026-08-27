// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation
import Testing

@testable import ocoreai

@Suite("Torch RNG source (Wan 2.1 noise)")
struct Wan21TorchRNGTests {
    @Test("Torch RNG deterministic across runs")
    func torchDeterministic() {
        var rng1 = TorchRandomSource(seed: 42)
        var rng2 = TorchRandomSource(seed: 42)
        let a = rng1.normalArray([64], mean: 0, stdev: 1)
        let b = rng2.normalArray([64], mean: 0, stdev: 1)
        #expect(a == b)
    }

    @Test("Torch RNG mean/variance within tolerance (seed=7)")
    func torchMoments() {
        var rng = TorchRandomSource(seed: 7)
        let samples = rng.normalArray([1024], mean: 0, stdev: 1)
        let mean = samples.reduce(0, +) / Float(samples.count)
        let variance = samples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(samples.count)
        #expect(abs(mean) < 0.1)
        #expect(abs(variance - 1.0) < 0.15)
    }

    @Test("Torch RNG differs across seeds")
    func torchSeedDependence() {
        var rng1 = TorchRandomSource(seed: 1)
        var rng2 = TorchRandomSource(seed: 2)
        let a = rng1.normalArray([16], mean: 0, stdev: 1)
        let b = rng2.normalArray([16], mean: 0, stdev: 1)
        #expect(a != b)
    }

    @Test("Torch RNG mean offset respected (mean=5.0, seed=42)")
    func torchMeanOffset() {
        var rng = TorchRandomSource(seed: 42)
        let samples = rng.normalArray([4096], mean: 5.0, stdev: 2.0)
        let mean = samples.reduce(0, +) / Float(samples.count)
        #expect(abs(mean - 5.0) < 0.2)
    }
}
