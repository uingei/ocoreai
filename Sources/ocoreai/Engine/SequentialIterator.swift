// Copyright 2026 Apple Inc. (BSD-3-clause upstream)
// Absorbed: coreai-models #251 (89ba0d4) — shared iterator helpers
// (clampMaxTokens + nextToken) for the two sequential engines.
//   upstream: swift/Sources/CoreAILanguageModels/InferenceEngines/SequentialIterator.swift
//
// Gated behind #if canImport(CoreAI) — `LogitsScalarType` + `SamplingConfiguration.fallbackSampler`
// live in the CoreAI-gated engine modules (unlike upstream, where the whole module is unconditional).

#if canImport(CoreAI)

/// Token-count clamp and next-token selection shared by the sequential engines' iterators.
///
/// Each engine keeps its own `next()` control flow; only these identical pure-value helpers
/// live here.
enum SequentialIterator {
    /// The generation-length cap for an iterator.
    ///
    /// A forced continuation replays exactly its own tokens; otherwise the requested budget
    /// (`nil` meaning "unbounded") is clamped to the context left after the prompt.
    static func clampMaxTokens(
        requested: Int?,
        forcedCount: Int?,
        inputCount: Int,
        maxContextLength: Int
    ) -> Int {
        if let forcedCount {
            return forcedCount
        }
        return min(requested ?? Int.max, max(0, maxContextLength - inputCount))
    }

    /// Select the next token: the forced-continuation token when replaying, otherwise the
    /// sampler's choice.
    ///
    /// `logits` is taken by value; the sampler mutates a copy-on-write copy so the caller's
    /// buffer (which it may also return to the consumer) is left untouched.
    static func nextToken(
        fromLogits logits: [LogitsScalarType],
        forced: [Int32]?,
        step: Int,
        sampling: SamplingConfiguration,
        tokenHistory: ArraySlice<Int32>
    ) -> Int32 {
        if let forced {
            return forced[step]
        }
        var mutableLogits = logits
        return sampling.fallbackSampler(
            from: &mutableLogits, tokenHistory: tokenHistory, step: step)
    }
}

#endif  // canImport(CoreAI)
