// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// coreai-models #265 (6441c8c) — "Add reproducible generation: seed and
// system_fingerprint". Upstream: swift/Sources/CoreAILanguageModels/Samplers/
// SeededRandomNumberGenerator.swift. Verbatim port (consume-not-reinvent):
// ocoreai already decodes the wire `seed` field and honors it on the MLX path
// (MLXBridge `params.seed`), but the CoreAI CPU sampling path (CompositeSampler)
// drew uniform randoms via `Float.random`, silently ignoring the seed.
// This generator backs the `sampling.seed` path through
// `SamplingConfiguration.sampleToken(from:step:)`.

/// A deterministic `RandomNumberGenerator` seeded by a single 64-bit value.
///
/// Backs reproducible sampling: given the same seed, `next()` produces the same
/// sequence of values on every run and every machine. Use it with
/// `CompositeSampler.sample(from:config:using:)` (via `SamplingConfiguration.seed`)
/// when a generation must be repeatable — determinism-under-load tests, evals, and
/// bug reproduction. For ordinary generation, leave `seed` nil so the sampler uses
/// the system generator.
///
/// A custom conformance is necessary because the standard library's
/// `SystemRandomNumberGenerator` reads OS entropy and has no seed input, so it cannot
/// produce reproducible output on any platform. The `UInt64` width is the
/// `RandomNumberGenerator` protocol's `next()` output type, not something specific here.
///
/// The algorithm is SplitMix64 (Steele, Lea & Flood 2014): a fixed odd increment
/// advances the state, then two xor-shift/multiply rounds mix it. It is fast, has a
/// full 2^64 period, and passes standard statistical tests — enough for a sampling
/// determinism knob (it is not a cryptographic generator).
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    /// Creates a generator seeded with `seed`. Any 64-bit value is valid, including 0.
    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
