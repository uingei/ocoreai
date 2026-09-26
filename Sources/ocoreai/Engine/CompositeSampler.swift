// Copyright 2026 Apple Inc. (BSD-3-clause upstream)
// Adapted for ocoreai — aligned with coreai-models CompositeSampler.swift
//
// Provides `CompositeSampler.sample(from:config:)` for the sequential engine
// CPU fallback path. Ocoreai's `SamplingConfiguration.fallbackSampler` routes here.
//
// Gated behind #if canImport(CoreAI) — LogitsScalarType lives inside CoreAI engine module.

import Foundation

#if canImport(CoreAI)

/// CPU fallback sampler for CoreAI path.
///
/// Algorithm (aligned with upstream coreai-models `CompositeSampler`):
/// 1. Temperature scaling: logits / temperature
/// 2. Softmax → probability distribution
/// 3. MinP filter (relative threshold)
/// 4. TopP filter (cumulative nucleus)
/// 5. TopK filter (hard vocabulary limit)
/// 6. Multinomial sample via inverse CDF
///
/// Temperature == 0 → argmax (greedy).

enum CompositeSampler {

    /// Sample one token from the logit distribution using the given configuration.
    /// Uses the system (non-reproducible) RNG.
    /// Mutates `logits` in-place (temperature scaling step).
    ///
    /// - Parameters:
    ///   - logits: Mutable array of logits (Float16 or Float depending on arch).
    ///   - config: Sampling parameters.
    /// - Returns: Sampled token ID.
    static func sample(
        from logits: inout [LogitsScalarType],
        config: SamplingConfiguration
    ) -> Int32 {
        var rng = SystemRandomNumberGenerator()
        return sample(from: &logits, config: config, using: &rng)
    }

    /// Samples from a caller-supplied RNG (coreai-models #265).
    ///
    /// `inout` so state advances across calls. Use this for deterministic / reproducible
    /// sampling (tests, evals). For non-deterministic use, call the no-RNG overload.
    static func sample(
        from logits: inout [LogitsScalarType],
        config: SamplingConfiguration,
        using rng: inout some RandomNumberGenerator
    ) -> Int32 {
        guard !logits.isEmpty else { return 0 }

        // Greedy path
        let temp = config.temperature ?? 1.0
        guard temp > 0 else {
            return argmax(logits)
        }

        // Convert to Float for numerical stability
        var f32: [Float]
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        f32 = logits.map { Float($0) }
        #else
        f32 = logits
        #endif

        // Temperature scaling — this is the mutation the caller expects
        for i in f32.indices {
            f32[i] /= Float(temp)
        }

        // Softmax
        let probs = softmax(&f32)

        // Filters (applied in order: minP → topP → topK)
        let filtered = applyFilters(probs, config: config)

        // Restore to original scalar type for caller
        #if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
        logits = filtered.map { LogitsScalarType($0) }
        #else
        logits = filtered
        #endif

        return sampleFromDistribution(filtered, using: &rng)
    }

    // MARK: - Internal helpers

    static func argmax<T: BinaryFloatingPoint & Comparable>(_ data: [T]) -> Int32 {
        var bestIdx = 0
        var bestVal = data[0]
        for i in 1 ..< data.count {
            if data[i] > bestVal {
                bestVal = data[i]
                bestIdx = i
            }
        }
        return Int32(bestIdx)
    }

    static func softmax(_ logits: inout [Float]) -> [Float] {
        let maxVal = logits.max() ?? 0
        let exps = logits.map { exp($0 - maxVal) }
        let sum = exps.reduce(0, +)
        guard sum > 0, sum.isFinite else {
            return Array(repeating: 0, count: exps.count)
        }
        return exps.map { $0 / sum }
    }

    static func applyFilters(_ probs: [Float], config: SamplingConfiguration) -> [Float] {
        var filtered = probs

        // minP filter
        if let minP = config.minP, minP > 0 {
            let maxProb = filtered.max() ?? 0
            let threshold = Float(minP) * maxProb
            for i in filtered.indices {
                if filtered[i] < threshold { filtered[i] = 0 }
            }
            let sum = filtered.reduce(0, +)
            guard sum > 0 else { return filtered }
            filtered = filtered.map { $0 / sum }
        }

        // topP (nucleus) filter
        if let topP = config.topP, topP < 1.0 {
            let nucleus = topPSubset(filtered, cumulativeProb: Float(topP))
            filtered = nucleus
            let sum = filtered.reduce(0, +)
            guard sum > 0 else { return filtered }
            filtered = filtered.map { $0 / sum }
        }

        // topK filter
        if let topK = config.topK, topK > 0 && topK < filtered.count {
            let top = topKSubset(filtered, k: topK)
            filtered = top
            let sum = filtered.reduce(0, +)
            guard sum > 0 else { return filtered }
            filtered = filtered.map { $0 / sum }
        }

        return filtered
    }

    static func topPSubset(_ probs: [Float], cumulativeProb: Float) -> [Float] {
        let indexed = probs.enumerated().sorted { $0.element > $1.element }
        var cum: Float = 0
        var kept = [Float](repeating: 0, count: probs.count)
        for (i, p) in indexed {
            kept[i] = p
            cum += p
            if cum >= cumulativeProb { break }
        }
        return kept
    }

    static func topKSubset(_ probs: [Float], k: Int) -> [Float] {
        let indexed = probs.enumerated().sorted { $0.element > $1.element }.prefix(k)
        var kept = [Float](repeating: 0, count: probs.count)
        for (i, p) in indexed {
            kept[i] = p
        }
        return kept
    }

    static func sampleFromDistribution(
        _ probs: [Float], using rng: inout some RandomNumberGenerator
    ) -> Int32 {
        let r = Float.random(in: 0 ..< 1, using: &rng)
        var cum: Float = 0
        for (i, p) in probs.enumerated() {
            cum += p
            if r < cum { return Int32(i) }
        }
        return Int32(probs.count - 1)
    }
}

/// Applies repetition penalty to logits based on token generation history.
///
/// For each unique token ID in the recent history:
/// - If logit > 0: divide by penalty factor
/// - If logit < 0: multiply by penalty factor
///
/// Discourages the model from re-emitting recently generated tokens.
/// Mirrors upstream coreai-models `Samplers/RepetitionPenaltyProcessor.swift`
/// (5660fc6, #176) — sign-aware divide/multiply, dedup, range-guarded.
struct RepetitionPenaltyProcessor {
    /// Apply repetition penalty to logits in-place.
    ///
    /// - Parameters:
    ///   - logits: Mutable logits array (vocab-sized). Modified in-place.
    ///   - recentTokenIds: Token IDs from recent generation history.
    ///   - penalty: The penalty factor (> 1.0 penalizes, 1.0 = no-op).
    static func apply<C: Collection<Int32>>(
        to logits: inout [LogitsScalarType],
        recentTokenIds: C,
        penalty: Float
    ) {
        guard penalty > 1.0 else { return }
        guard !recentTokenIds.isEmpty else { return }

        let vocabSize = logits.count
        var seen = Set<Int32>(minimumCapacity: min(recentTokenIds.count, 512))

        for tokenId in recentTokenIds {
            guard tokenId >= 0 && Int(tokenId) < vocabSize else { continue }
            guard seen.insert(tokenId).inserted else { continue }

            let logit = Float(logits[Int(tokenId)])
            if logit > 0 {
                logits[Int(tokenId)] = LogitsScalarType(logit / penalty)
            } else if logit < 0 {
                logits[Int(tokenId)] = LogitsScalarType(logit * penalty)
            }
        }
    }
}

/// Extension to match upstream SamplingConfiguration.fallbackSampler.
/// The two-arg form samples without repetition penalty (explicit no-penalty);
/// the `(from:tokenHistory:)` overload applies the penalty first when configured.
///
/// #265 (6441c8c) — `sampling.seed`, when set, routes the multinomial through a
/// `SeededRandomNumberGenerator` derived from `(seed, step)`: each generation step
/// gets its own generator, so reproducibility does not depend on a running stream's
/// position (survives prefix reuse / reset / cancel). `step` is required while `seed`
/// is set and ignored otherwise. Greedy (temperature 0) is argmax and ignores both.
extension SamplingConfiguration {
    /// Samples next token via CPU composite sampler (no repetition penalty).
    /// Mutates logits in-place (temperature scaling).
    /// - Parameters:
    ///   - logits: Mutable logits array. May be modified during sampling.
    ///   - step: Generation step index. Required when `seed` is set; ignored otherwise.
    /// - Returns: Sampled token ID.
    func fallbackSampler(from logits: inout [LogitsScalarType], step: Int? = nil) -> Int32 {
        sampleToken(from: &logits, step: step)
    }

    /// Samples the next token with repetition penalty applied first.
    ///
    /// Applies repetition penalty (if configured) to the logits based on token
    /// history, then delegates to the standard sampler pipeline.
    /// - Parameters:
    ///   - logits: Mutable logits array. May be modified during sampling.
    ///   - tokenHistory: Recent generated token IDs for the penalty (prompt
    ///     tokens excluded by the caller — only tokens generated this turn).
    ///   - step: Generation step index. Required when `seed` is set; ignored otherwise.
    /// - Returns: Sampled token ID.
    func fallbackSampler(
        from logits: inout [LogitsScalarType],
        tokenHistory: some Collection<Int32>,
        step: Int? = nil
    ) -> Int32 {
        if needsRepetitionPenalty, let penalty = repetitionPenalty {
            let window =
                repetitionPenaltyWindow.map { min($0, tokenHistory.count) }
                ?? tokenHistory.count
            let recentTokens = tokenHistory.suffix(window)
            RepetitionPenaltyProcessor.apply(
                to: &logits, recentTokenIds: recentTokens, penalty: Float(penalty))
        }
        return sampleToken(from: &logits, step: step)
    }

    /// Samples a token from already-prepared logits (repetition penalty / masking,
    /// if any, applied by the caller), routing through `seed` (coreai-models #265).
    ///
    /// With `seed` set, each step derives its own `SeededRandomNumberGenerator` from
    /// `(seed, step)`, so the sampled token is reproducible and independent of any
    /// running generator's stream position. With `seed` nil, the system generator is
    /// used. Greedy (temperature 0) is argmax and ignores the generator. Used by both
    /// `fallbackSampler` overloads and the constrained-decoding path so seeded sampling
    /// is reproducible everywhere.
    /// - Parameters:
    ///   - logits: Mutable logits array. May be modified during sampling.
    ///   - step: Generation step index. Required when `seed` is set; ignored otherwise.
    /// - Returns: Sampled token ID.
    func sampleToken(from logits: inout [LogitsScalarType], step: Int?) -> Int32 {
        guard let seed else {
            return CompositeSampler.sample(from: &logits, config: self)
        }
        guard let step else {
            preconditionFailure("A generation step index is required when a sampling seed is set.")
        }
        var rng = SeededRandomNumberGenerator(
            seed: UInt64(bitPattern: seed) &+ UInt64(bitPattern: Int64(step)))
        return CompositeSampler.sample(from: &logits, config: self, using: &rng)
    }
}

#endif  // canImport(CoreAI)
