// Copyright 2026 Apple Inc. (BSD-3-clause upstream)
// Adapted for ocoreai — aligned with coreai-models CompositeSampler.swift
//
// Provides `CompositeSampler.sample(from:config:)` for the sequential engine
// CPU fallback path. Ocoreai's `SamplingConfiguration.fallbackSampler` routes here.

import Foundation

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
    /// Mutates `logits` in-place (temperature scaling step).
    ///
    /// - Parameter logits: Mutable array of logits (Float16 or Float depending on arch).
    /// - Parameter config: Sampling parameters.
    /// - Returns: Sampled token ID.
    static func sample(
        from logits: inout [LogitsScalarType],
        config: SamplingConfiguration
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

        return sampleFromDistribution(filtered)
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

    static func sampleFromDistribution(_ probs: [Float]) -> Int32 {
        let r = Float.random(in: 0 ..< 1)
        var cum: Float = 0
        for (i, p) in probs.enumerated() {
            cum += p
            if r < cum { return Int32(i) }
        }
        return Int32(probs.count - 1)
    }
}

/// Extension to match upstream SamplingConfiguration.fallbackSampler
extension SamplingConfiguration {
    /// Samples next token via CPU composite sampler.
    /// Mutates logits in-place (temperature scaling).
    /// - Returns: Sampled token ID.
    func fallbackSampler(from logits: inout [LogitsScalarType]) -> Int32 {
        CompositeSampler.sample(from: &logits, config: self)
    }
}
