// Copyright 2026 uingei@163.com.
// Licensed under MIT.
//
// EngineLogprobs.swift — A2 loglikelihood (POST /v1/completions `logprobs`)
//
// Ported copy-first from coreai-models (Apple, BSD-3-Clause) —
// swift/Sources/Tools/llm-server/CompletionHandler.swift (b11ac19):
//   supportsLogits gate → 501 · busy gate → 429
//   tokens = tokenizer.encode(text:) (raw, no chat template)
//   paddingToken = tokens[0]; continuation = dropFirst() + [paddingToken]
//     (lm-eval slices logprobs[ctxlen:-1]; the padding token is what :-1 drops)
//   topN = min(logprobs ?? 1, 20)
//   options = InferenceOptions(includeLogits: true, forcedContinuation: continuation)
//   engine.reset() → engine.generate([tokens[0]], .greedy, options)
//   collect output.logits → LogProbabilities.compute(logits: targets: topK:)
//   first token logprob=nil, offset=0; rest decode + value + offset + topN alternatives
//   echo → decode(allTokens); else text=""
//   finish_reason="stop", object="text_completion"
//
// Gated to CoreAI (same as LogProbabilities.swift): the pipeline consumes
// InferenceEngine / LogitsScalarType / LogProbabilities, all CoreAI-side.
// Consumers (CompletionsHandler loglikelihood branch) are likewise
// CoreAI-gated (LogProbabilities.swift header contract).

#if canImport(CoreAI)

import Foundation

/// A2 loglikelihood choice payload (engine-side, pre wire-encoding).
/// `logprobs` is nil for the <2-tokens degenerate prompt (upstream L126-128).
@available(macOS 27.0, iOS 27.0, *)
struct LoglikelihoodResult: Sendable {
    let text: String
    let logprobs: LogprobsResult?
    let promptTokens: Int

    init(text: String, logprobs: LogprobsResult?, promptTokens: Int) {
        self.text = text
        self.logprobs = logprobs
        self.promptTokens = promptTokens
    }
}

// MARK: - A2 loglikelihood (EnginePool extension)

extension EnginePool {

    /// Score per-token log probabilities for a raw text prompt.
    ///
    /// Mirrors upstream `processOnePrompt` (coreai-models CompletionHandler
    /// L113-215): raw encode → padding continuation → forced greedy decode →
    /// collect per-position logits → LogProbabilities over the continuation.
    ///
    /// - Parameters:
    ///   - modelId: Loaded model identifier
    ///   - text: Raw prompt text (NO chat template — text-completion semantics)
    ///   - topN: Top-K alternatives per token (handler clamps to `min(logprobs ?? 1, 20)`)
    ///   - echo: When true, `text` returns the decoded prompt; else ""
    @available(macOS 27.0, iOS 27.0, *)
    func collectLogits(
        modelId: String,
        text: String,
        topN: Int,
        echo: Bool,
    ) async throws -> LoglikelihoodResult {
        guard let loaded = loadedModels[modelId] else {
            throw AppError.modelNotFound(modelId)
        }
        guard let provider = await tokenizerManager.getTokenizer(for: modelId) else {
            throw AppError.tokenizationFailed("No tokenizer registered for model: \(modelId)")
        }

        /// Raw encode — upstream `state.tokenizer.encode(text:)` (no chat template).
        let allTokens = Array(provider.underlying.encode(text: text).map(Int32.init))

        /// Upstream L126-128: <2 tokens → empty choice (text "", no logprobs), no error.
        guard allTokens.count >= 2 else {
            return LoglikelihoodResult(text: "", logprobs: nil, promptTokens: allTokens.count)
        }

        /// Upstream L130-133: context overflow → 400.
        guard allTokens.count <= loaded.modelConfig.maxContextLength else {
            throw AppError.invalidRequest(
                "Prompt length \(allTokens.count) exceeds max context \(loaded.modelConfig.maxContextLength)"
            )
        }

        /// lm-eval sends echo=true, max_tokens=1 and slices logprobs[ctxlen:-1].
        /// The :-1 discards the last entry. Append a padding token so :-1 drops
        /// it instead of discarding real data. (upstream L135-139)
        let paddingToken = allTokens[0]
        let continuation = Array(allTokens.dropFirst()) + [paddingToken]

        /// Single-slot scoring busy gate → 429 (upstream L33-40).
        guard loaded.tryAcquireInference() else {
            throw AppError.engineBusy
        }
        defer { loaded.releaseInference() }

        let engine = try await loaded.getCachedEngine()

        /// Capability gate → 501 (upstream L23-32 `supportsLogprobs`); the
        /// pipelined engine reports false and the MLX backend never reaches here.
        guard engine.supportsLogits else {
            throw AppError.logitsUnsupported
        }

        let options = InferenceOptions(
            maxTokens: continuation.count,
            includeLogits: true,
            forcedContinuation: continuation)

        try await engine.reset()

        /// Greedy decode — upstream `samplingConfiguration: .greedy`.
        let sampling = SamplingConfiguration(temperature: 0, mode: .greedy)
        let genSequence = try await engine.generate(
            with: [allTokens[0]],
            samplingConfiguration: sampling,
            inferenceOptions: options)

        /// Upstream L155-160: collect per-position logits (kept, not discarded).
        var allLogits: [[LogitsScalarType]] = []
        for try await output in genSequence {
            if let logits = output.logits {
                allLogits.append(logits)
            }
        }

        /// Upstream L162: per-target logprob over the continuation (position i
        /// = logProb(target_i | prefix), which is exactly the prompt token at i+1).
        let probs = LogProbabilities.compute(logits: allLogits, targets: continuation, topK: topN)

        /// Upstream L164-200: build the OpenAI logprobs payload.
        var tokens: [String] = []
        var tokenLogprobs: [Double?] = []
        var topLogprobsList: [[String: Double]?] = []
        var textOffsets: [Int] = []
        var currentOffset = 0

        /// First token: logprob nil (no preceding context), offset 0.
        let firstTokenStr = try await provider.detokenize(tokenIds: [allTokens[0]])
        tokens.append(firstTokenStr)
        tokenLogprobs.append(nil)
        topLogprobsList.append(nil)
        textOffsets.append(0)
        currentOffset += firstTokenStr.utf8.count

        for entry in probs.entries {
            let tokenStr = try await provider.detokenize(tokenIds: [entry.tokenId])
            tokens.append(tokenStr)
            tokenLogprobs.append(entry.value)
            textOffsets.append(currentOffset)
            currentOffset += tokenStr.utf8.count

            if topN > 0 {
                var topMap: [String: Double] = [:]
                for alt in entry.alternatives {
                    topMap[try await provider.detokenize(tokenIds: [alt.tokenId])] = alt.value
                }
                topLogprobsList.append(topMap)
            } else {
                topLogprobsList.append(nil)
            }
        }

        let logprobsResult = LogprobsResult(
            tokens: tokens,
            tokenLogprobs: tokenLogprobs,
            topLogprobs: topLogprobsList,
            textOffset: textOffsets,
        )

        /// Upstream L202-207: echo → decoded prompt; else empty text.
        let responseText =
            echo
            ? (try await detokenize(modelId: modelId, tokens: allTokens))
            : ""

        return LoglikelihoodResult(
            text: responseText,
            logprobs: logprobsResult,
            promptTokens: allTokens.count,
        )
    }
}

#endif
