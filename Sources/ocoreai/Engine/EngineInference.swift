// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineInference.swift — Inference execution as EnginePool extension
///
/// Contains ``doInference`` and ``_runInference`` — the heavy inference
/// runners that execute off-actor in background Tasks. Split from
/// EnginePool.swift so the actor's core orchestration stays lean.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Logging
import MLX
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon
import MLXVLM

#if canImport(CoreAI)
import CoreAI
#endif

// MARK: - Sendable wrappers for MTP speculative decoding
//
// MLXLMCommon's SendableBox is package-private, so we provide local wrappers
// to safely cross @Sendable closure boundaries. These are safe because
// both model and drafter sit behind SerialAccessContainers that enforce
// single-threaded access within modelContainer.perform / mtpDrafterContainer.perform.

/// @unchecked Sendable wrapper for MTP drafter model — enables injection into
/// modelContainer.perform(nonSendable:) closure via perform(nonSendable:values:_:).
struct MTPDrafterModelWrapper: @unchecked Sendable {
    let model: any MLXLMCommon.MTPDrafterModel
}

// MARK: - Guided Generation Helper Types

/// Cached tokenizer biases for guided generation — mirrors upstream
/// `ModelCache.TokenizerBias`. Immutable once computed, safe to cache
/// per-model in `LoadedModel._cachedTokenBias`.
struct TokenBiasCache: @unchecked Sendable {
    let closing: MLXArray
    let whitespace: MLXArray
    let whitespaceTokenIDs: Set<Int>
}

// MARK: - FoundationModels integration (macOS 27+)
//
// Imports MLXFoundationModels so we can access capability gates,
// ToolCallingMode, ConfigurationResolver, and Executor logic from
// the MLXLanguageModel.respond() pipeline while preserving our
// SSE streaming, SessionPool, and MTP speculative decoding.
#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
import MLXFoundationModels
import FoundationModels
#endif

// MARK: - Guided Gen Diagnostic Diagnostics

/// Result carried out of the `GuidedGenerationDiagnosticSink.$current.withValue` block
/// so downstream can log structured diagnostic data even after the sink is unbound.
private enum GuidedGenerationDiagnosticResult {
    case success(tokenCount: Int, sink: GuidedGenerationDiagnosticSink)
}

// MARK: - Guided Gen Diagnostic Logging

/// Log guided generation completion diagnostics.
private func logGuidedGen(
    _ logger: Logger,
    modelId: String,
    grammarTerminated: Bool,
    tokenCount: Int,
    sampledTokens: Int,
    fastForwardTokens: Int,
    incomplete: Bool,
    finalBufferPresent: Bool,
    parsedAsToolCall: Bool?,
    parsedName: String?
) {
    let tc = parsedAsToolCall.map(String.init) ?? "nil"
    let nm = parsedName ?? "nil"
    logger.info(
        "Guided gen diagnostics: model=\(modelId) grammarTerm=\(grammarTerminated) tokens=\(tokenCount) sampled=\(sampledTokens) ff=\(fastForwardTokens) incomplete=\(incomplete) finalBuf=\(finalBufferPresent) toolCall=\(tc) name=\(nm)"
    )
}

/// Log guided generation error diagnostics.
private func logGuidedGenError(
    _ logger: Logger,
    modelId: String,
    error: Error,
    grammarTerminated: Bool,
    tokenCountBeforeFailure: Int,
    sampledTokens: Int,
    fastForwardTokens: Int,
    incomplete: Bool,
    finalBuffer: String?
) {
    let errDesc = error.localizedDescription
    let buf = finalBuffer.map { "\($0.prefix(120))" } ?? "nil"
    logger.error(
        "Guided gen ERROR: model=\(modelId) err=\(errDesc) grammarTerm=\(grammarTerminated) tokensBeforeFail=\(tokenCountBeforeFailure) sampled=\(sampledTokens) ff=\(fastForwardTokens) incomplete=\(incomplete) finalBuf=\(buf)"
    )
}

// MARK: - Guided Generation Bias Cache

/// Cached tokenizer-derived logit biases for guided generation — mirrors upstream
/// ModelCache.tokenizerBiases. These are pure tokenizer functions computed once.
/// NOTE: Bias caching is deferred pending Synchronization.AsyncLock availability
/// in non-actor contexts. Currently re-computed per inference (low overhead).

// MARK: - Perception Media Attachment (free function)

/// Attach perception capture media (image bytes + audio) to the last
/// user-role message. Perceptual context rides the USER turn, not system
/// instructions (skill: perception injection = user message, not system).
///
/// Pure/free — no `EnginePool` self, no shared state; the `makeImage`/`makeAudio`
/// closures are injected so callers decide byte-decoding semantics (data-URL /
/// EXIF / temp `.caf`). This keeps the attach logic independently testable
/// without constructing a full inference actor.
///
/// Returns temp audio file URLs the caller must clean up after inference.
/// Chat.Message is a Sendable struct with `var images`/`var audios`, so
/// post-map mutation of the last user message is safe.
func attachPerceptionMedia(
    _ messages: inout [Chat.Message],
    mediaParts: [ContentPart],
    makeImage: (String) -> MLXLMCommon.UserInput.Image?,
    makeAudio: (String) -> (audio: MLXLMCommon.UserInput.Audio?, tempURL: URL?)
) -> [URL] {
    var images: [MLXLMCommon.UserInput.Image] = []
    var audios: [MLXLMCommon.UserInput.Audio] = []
    var tempURLs: [URL] = []
    for part in mediaParts {
        if let img = part.imageUrl, let image = makeImage(img.url) {
            images.append(image)
        }
        if let audio = part.audioURL {
            let result = makeAudio(audio.url)
            if let audioInput = result.audio {
                audios.append(audioInput)
            }
            if let tempFile = result.tempURL {
                tempURLs.append(tempFile)
            }
        }
    }
    guard !images.isEmpty || !audios.isEmpty,
        let lastUser = messages.lastIndex(where: { $0.role == .user })
    else { return tempURLs }
    messages[lastUser].images.append(contentsOf: images)
    messages[lastUser].audios.append(contentsOf: audios)
    return tempURLs
}

// MARK: - MLX Media Decoders (free functions)

/// Convert a string that may be a data URL (`data:image/…;base64,…`) or a
/// regular URL into an ``MLXLMCommon/UserInput/Image``.
/// Data URLs are decoded to `CIImage`; remote/local URLs are passed through.
/// Free function — does not capture `EnginePool` self (avoids Sendable taint in
/// the inference body); independently testable (b4).
func makeMLXImage(from urlString: String) -> MLXLMCommon.UserInput.Image? {
    // Handle data: URIs (camera/screen snapshots come as base64 data URLs)
    if urlString.hasPrefix("data:") {
        // Use the LAST comma — base64 payload or URL-encoded data may contain commas
        if let lastComma = urlString.lastIndex(of: ",") {
            let base64Data = String(urlString[urlString.index(after: lastComma)...])
            guard let data = Data(base64Encoded: base64Data) else { return nil }
            // Decode via CGImageSource with auto-orient so EXIF orientation
            // is baked into pixel data before CIImage consumes it (CIImage
            // ignores EXIF orientation, causing rotated output.  Aligns with
            // mlx-swift-examples ChatView.swift L105-128.)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let cgImage = CGImageSourceCreateImageAtIndex(
                    source,
                    0,
                    ["ShouldAutoOrient": true] as CFDictionary
                )
            else { return nil }
            return .ciImage(CIImage(cgImage: cgImage))
        }

        return nil
    }

    // Fallback: regular URL (http, file, etc.)
    if let url = URL(string: urlString) {
        return .url(url)
    }

    return nil
}

/// Convert a string that may be a data URL (`data:audio/…;base64,…`) or a
/// regular URL into an ``MLXLMCommon/UserInput/Audio``.
/// Data URLs are decoded to a temp `.caf` file; remote/local URLs are passed through.
/// Free function — returns (audio, tempURL) so callers can clean up the temp file
/// after inference. Independently testable (b4).
func makeMLXAudio(from urlString: String) -> (
    audio: MLXLMCommon.UserInput.Audio?, tempURL: URL?
) {
    // Handle data: URIs (recordings come as base64 data URLs)
    if urlString.hasPrefix("data:") {
        // Use the LAST comma — base64 payload may contain commas
        guard let lastComma = urlString.lastIndex(of: ",") else { return (nil, nil) }
        let base64Data = String(urlString[urlString.index(after: lastComma)...])
        guard let data = Data(base64Encoded: base64Data) else { return (nil, nil) }
        // Write to temp file so AVAssetReader can decode it
        let tmpName = "ocoreai_audio_\(UUID().uuidString.prefix(8)).caf"
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(tmpName)
        do {
            try data.write(to: tmpURL)
            return (.url(tmpURL), tmpURL)
        } catch {
            return (nil, nil)
        }
    }

    // Fallback: regular URL (http, file, etc.) — no temp file created
    if let url = URL(string: urlString) {
        return (.url(url), nil)
    }

    return (nil, nil)
}

extension EnginePool {
    // MARK: - Entry Points (TaskGroup dispatch)

    /// Start inference, returning an ``AsyncThrowingStream`` the caller consumes.
    func doInference(
        modelId: String,
        input: [Int32],
        sampling: SamplingConfiguration,
        options: InferenceOptions,
        metrics: PerRequestMetrics,
        cancellation: InferenceCancellation = .none,
    ) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [self] in
                let deadline = ContinuousClock.now + .seconds(config.inferenceTimeoutSeconds)
                // P0-2 fix: tracker, register, and cleanup inside group eliminates race window
                let tracker = Task<Void, Never> {
                    await self._runInference(
                        modelId: modelId,
                        input: input,
                        messages: nil,
                        sampling: sampling,
                        options: options,
                        metrics: metrics,
                        continuation: continuation,
                        cancellation: cancellation,
                    )
                    ()
                }
                await registerTrackedTask(tracker)
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await tracker.value
                    }
                    group.addTask {
                        // Single-shot watchdog: sleep until deadline once, then cancel.
                        // Replaces the previous 500ms polling loop which woke up 600+ times
                        // per 300s request — pure CPU waste for a single deadline check.
                        do { try await Task.sleep(until: deadline, clock: .continuous) } catch {}
                        cancellation.cancel()
                    }
                }
                await removeTrackedTask(tracker)
            }
        }
    }

    /// MLX-specific inference entry — accepts messages directly.
    func doInferenceMLX(
        modelId: String,
        messages: [Message],
        sampling: SamplingConfiguration,
        options: InferenceOptions,
        metrics: PerRequestMetrics,
        conversationId: String? = nil,
        cancellation: InferenceCancellation = .none,
    ) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [self] in
                let deadline = ContinuousClock.now + .seconds(config.inferenceTimeoutSeconds)
                // P0-2 fix: tracker, register, and cleanup outside group eliminates race window
                let tracker = Task<Void, Never> {
                    await self._runInferenceWithMessages(
                        modelId: modelId,
                        messages: messages,
                        sampling: sampling,
                        options: options,
                        metrics: metrics,
                        continuation: continuation,
                        conversationId: conversationId,
                        cancellation: cancellation,
                    )
                    ()
                }
                await registerTrackedTask(tracker)
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await tracker.value
                    }
                    group.addTask {
                        // Single-shot watchdog: sleep until deadline once, then cancel.
                        // Replaces the previous 500ms polling loop which woke up 600+ times
                        // per 300s request — pure CPU waste for a single deadline check.
                        do { try await Task.sleep(until: deadline, clock: .continuous) } catch {}
                        cancellation.cancel()
                    }
                }
                await removeTrackedTask(tracker)
            }
        }
    }

    // MARK: - Internal Runners

    private func _runInference(
        modelId: String,
        input: [Int32],
        messages: [Message]?,
        sampling: SamplingConfiguration,
        options: InferenceOptions,
        metrics: PerRequestMetrics,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation,
        cancellation: InferenceCancellation = .none,
    ) async {
        guard let loaded = loadedModels[modelId] else {
            continuation.yield(.init(kind: .error("Model not loaded: \(modelId)")))
            continuation.finish()
            return
        }

        let tokenCount = input.count
        if tokenCount > loaded.modelConfig.maxContextLength {
            continuation.yield(
                .init(
                    kind: .error(
                        "Input \(tokenCount) exceeds max context \(loaded.modelConfig.maxContextLength)",
                    )))
            continuation.finish()
            return
        }

        metrics.promptTokenCount = tokenCount
        metrics.start()

        guard loaded.tryAcquireInference() else {
            continuation.yield(.init(kind: .error("Engine busy")))
            continuation.finish()
            return
        }
        defer { loaded.releaseInference() }

        #if canImport(CoreAI)
        if #available(macOS 27.0, iOS 27.0, *) {
            // CoreAI constrained decoding — grammar requests stay on CoreAI path.
            // CoreAI is CoreAI, MLX is MLX — no cross-framework fallback.
            do {
                let engine = try await loaded.getCachedEngine()
                // Grammar request → route to the constrained path by ENGINE
                // CAPABILITY, aligned with upstream coreai-models
                // CoreAILanguageModel.respondConstrained (L582-596):
                //   ConstrainedGenerationCapable (GPU pipelined, #170)
                //     → PipelinedConstrainedDecodingStrategy
                //       (xgrammar bitmask applied inside the MPSGraph sampler
                //        on GPU — no ~296KB logits CPU round-trip per token)
                //   otherwise
                //     → sequential _runConstrainedDecoding (CPU bitmask loop)
                if options.grammarSchema != nil || options.useGuidedGeneration {
                    if let pipeline = engine as? any ConstrainedGenerationCapable {
                        // GPU pipelined constrained decoding (#170) — dispatched
                        // by capability so dynamic-structure models (auto →
                        // pipelined) keep their grammar constraints.
                        await _runPipelinedConstrainedDecoding(
                            engine: pipeline,
                            modelId: modelId,
                            messages: messages,
                            input: input,
                            sampling: sampling,
                            options: options,
                            metrics: metrics,
                            continuation: continuation,
                            cancellation: cancellation
                        )
                        return
                    }
                    // Capability unavailable — sequential constrained loop
                    // (unchanged pre-#170 behavior for non-GPU engines).
                    if let sequential = engine as? CoreAISequentialEngine {
                        await _runConstrainedDecoding(
                            engine: sequential,
                            modelId: modelId,
                            messages: messages,
                            input: input,
                            sampling: sampling,
                            options: options,
                            metrics: metrics,
                            continuation: continuation,
                            cancellation: cancellation
                        )
                        return
                    }
                    logger.warning(
                        "Grammar constrained request but engine is \(String(describing: type(of: engine))) — falling back to standard CoreAI, grammar constraints dropped"
                    )
                }

                // upstream CoreAILanguageModel.Executor.respondVanilla() pipeline:
                //   token stream → detokenize deltas → ThinkTagParser → ToolCallParser
                //   → .text / .reasoning / .toolCall events
                // We replicate that segmentation here so CoreAI path no longer
                // bypasses reasoning segmentation and tool-call detection.
                // Upstream: ThinkTagParser defaults to ``; open/close
                // markers resolved at model init from tokenizer token ids
                // (CoreAILanguageModel.swift L384-388). Use upstream defaults
                // unless model-specific detection is available.
                // Detect primedInside: Qwen3-thinking / DeepSeek-R1 prefill the opening
                // delimiter into the prompt, so the first generated token is already
                // reasoning content. Without this, the entire thought block is misrouted
                // to .text events.
                let openMarker = "<think" + "ing>"
                let closeMarker = "</think" + "ing>"
                let primedInside: Bool
                do {
                    let tailPrompt = try await detokenize(modelId: modelId, tokens: input)
                    primedInside = ThinkTagParser.promptEndsInsideReasoning(
                        renderedPromptTail: tailPrompt,
                        openMarker: openMarker,
                        closeMarker: closeMarker
                    )
                } catch {
                    primedInside = false
                    logger.warning(
                        "CoreAI primedInside detection failed — defaulting to false: \(error.localizedDescription)"
                    )
                }
                var thinkParser = ThinkTagParser(
                    open: openMarker,
                    close: closeMarker,
                    primedInside: primedInside
                )
                var toolParser = ToolCallParser()
                var accumulatedTokens: [Int32] = []
                // Track reasoning characters for accurate reasoningTokenCount reporting
                // (CoreAI path doesn't provide per-token reasoning boundaries.)
                var accumulatedReasoningChars = 0
                // Decode in batches to reduce detokenize overhead — mirrors MLX path
                // batch detokenize strategy (ChatHandler L778 decodeBatchSize = 8).
                let decodeBatchSize = 8
                // Native stop sequence detection — no MLX fallback needed.
                // upstream CoreAIExecutor.respondVanilla() does the same text-level check
                // after each detokenize step (StopSequences.matches on decoded span).
                let stopSequences = sampling.stopSequences ?? []

                // Generate token stream — store in genSequence to avoid shadowing stdlib `sequence`
                let genSequence = try await engine.generate(
                    with: input,
                    samplingConfiguration: sampling,
                    inferenceOptions: options
                )

                do {
                    var streamCancelled = false
                    var effectiveStopReason: StopReason? = nil
                    do {
                        for try await output in genSequence {
                            if Task.isCancelled || cancellation.isCancelled {
                                streamCancelled = true
                                break
                            }
                            let tokenId = (output as? InferenceOutput)?.tokenId ?? 0
                            accumulatedTokens.append(tokenId)
                            metrics.incrementGenerated()
                            if metrics.generatedTokenCount == 1 {
                                metrics.firstTokenMs = metrics.overallMs
                            }

                            // Decode batch when aligned
                            guard accumulatedTokens.count % decodeBatchSize == 0
                            else { continue }

                            // Detokenize batch + run through parser pipeline (inline, no local closure)
                            do {
                                let decoded: String = try await detokenize(
                                    modelId: modelId,
                                    tokens: accumulatedTokens
                                )

                                // Stop sequence detection — check decoded text before feeding parsers
                                // (aligned with upstream StopSequences text-level check after each detokenize)
                                if let hit = Self.firstMatchStopSequence(
                                    in: decoded, sequences: stopSequences)
                                {
                                    let preStop = String(decoded[decoded.startIndex ..< hit.offset])
                                    if !preStop.isEmpty {
                                        accumulatedReasoningChars += Self.yieldParserEvents(
                                            preStop,
                                            thinkParser: &thinkParser,
                                            toolParser: &toolParser,
                                            continuation: continuation
                                        )
                                    }
                                    effectiveStopReason = .stopSequence
                                    accumulatedTokens = []
                                    break
                                }

                                accumulatedReasoningChars += Self.yieldParserEvents(
                                    decoded,
                                    thinkParser: &thinkParser,
                                    toolParser: &toolParser,
                                    continuation: continuation
                                )
                            } catch {
                                logger.warning(
                                    "CoreAI batch detokenize failed (size=\(accumulatedTokens.count)): \(error.localizedDescription)"
                                )
                            }
                            accumulatedTokens = []
                        }
                    } catch {
                        // Flush residual tokens before error
                        if !accumulatedTokens.isEmpty {
                            do {
                                let decoded = try await detokenize(
                                    modelId: modelId,
                                    tokens: accumulatedTokens
                                )
                                accumulatedReasoningChars += Self.yieldParserEvents(
                                    decoded,
                                    thinkParser: &thinkParser,
                                    toolParser: &toolParser,
                                    continuation: continuation
                                )
                            } catch {
                                logger.warning(
                                    "CoreAI residual detokenize failed: \(error.localizedDescription)"
                                )
                            }
                            accumulatedTokens = []
                        }
                        continuation.yield(
                            .init(
                                kind: .error(
                                    InferenceError.guidedGenerationFailed("generation failed")
                                        .errorDescription ?? "error")))
                        return
                    }

                    // Flush residual tokens
                    if !accumulatedTokens.isEmpty {
                        do {
                            let decoded = try await detokenize(
                                modelId: modelId,
                                tokens: accumulatedTokens
                            )
                            accumulatedReasoningChars += Self.yieldParserEvents(
                                decoded,
                                thinkParser: &thinkParser,
                                toolParser: &toolParser,
                                continuation: continuation
                            )
                        } catch {
                            logger.warning(
                                "CoreAI residual detokenize failed: \(error.localizedDescription)")
                        }
                        accumulatedTokens = []
                    }

                    // Flush parsers — emit held-back buffers
                    for thinkEvent in thinkParser.flush() {
                        switch thinkEvent {
                        case .reasoning(let segText):
                            accumulatedReasoningChars += segText.utf8.count
                            continuation.yield(.init(kind: .reasoning(segText)))
                        case .text(let segText):
                            for toolEvent in toolParser.consume(segText) {
                                switch toolEvent {
                                case .text(let plainText):
                                    continuation.yield(.init(kind: .text(plainText)))
                                case .toolCall(let id, let name, let argsJSON):
                                    continuation.yield(
                                        .init(
                                            kind: .toolCall(
                                                ToolCall(
                                                    id: id,
                                                    type: "function",
                                                    function: ToolCallFunction(
                                                        name: name,
                                                        arguments: argsJSON
                                                    )
                                                )
                                            )))
                                }
                            }
                        }
                    }
                    // Handle residual toolCallParser events from flush — unclosed tool call
                    // blocks at EOS are dropped (malformed JSON is not useful to surface),
                    // but plain text held back for marker matching must still be emitted.
                    for toolFlushEvent in toolParser.flush() {
                        switch toolFlushEvent {
                        case .text(let plainText):
                            continuation.yield(.init(kind: .text(plainText)))
                        case .toolCall(let id, let name, let argsJSON):
                            continuation.yield(
                                .init(
                                    kind: .toolCall(
                                        ToolCall(
                                            id: id,
                                            type: "function",
                                            function: ToolCallFunction(
                                                name: name,
                                                arguments: argsJSON
                                            )
                                        )
                                    )))
                        }
                    }

                    if streamCancelled {
                        // Drain remaining tokens to free CoreAI GPU memory
                        // (upstream #113 fix: pipelined sequence retains output until consumed)
                        logger.debug("CoreAI stream cancelled — draining remaining output")
                        do {
                            for try await _ in genSequence {}
                        } catch {
                            logger.debug("CoreAI drain error: \(error.localizedDescription)")
                        }
                    }

                    let stopReason: StopReason
                    if streamCancelled {
                        stopReason = .cancelled
                    } else if effectiveStopReason == .stopSequence {
                        stopReason = .stopSequence
                    } else {
                        stopReason = genSequence.stopReason?.stopReason ?? .maxTokens
                    }
                    // Estimate prompt throughput from inference start overhead
                    // (tokenization + warmup share the prefix of overallMs with inference;
                    //  using overallMs as denominator yields a conservative lower bound)
                    let promptTokPerSec: Double? =
                        metrics.promptTokenCount > 0 && Double(metrics.overallMs) > 0
                        ? Double(metrics.promptTokenCount) / (Double(metrics.overallMs) / 1000.0)
                        : nil
                    // Estimate reasoning token count from reasoning character count
                    // (CoreAI path lacks per-token reasoning boundaries; ~3.5 chars/token heuristic)
                    let reasoningTokenCount: Int? =
                        accumulatedReasoningChars > 0
                        ? Int(Double(accumulatedReasoningChars) / 3.5)
                        : nil
                    continuation.yield(
                        .init(
                            kind: .done(
                                stopReason,
                                tokenCount: metrics.generatedTokenCount,
                                tokPerSec: metrics.generatedTokenCount > 0
                                    ? Double(metrics.generatedTokenCount)
                                        / (Double(metrics.overallMs) / 1000.0)
                                    : nil,
                                promptTokPerSec: promptTokPerSec,
                                reasoningTokenCount: reasoningTokenCount)))
                }

                // CoreAI 34f0db3: no per-turn reset. KV cache persists across turns;
                // TokenHistory.resolve manages prefix reuse and divergence rewind.
                // Explicit reset only on model switch or hard error.

            } catch {
                continuation.yield(
                    .init(
                        kind: .error(
                            InferenceError.standardPathFailed("CoreAI generation failed")
                                .errorDescription ?? "error")))
            }
        } else {
            // macOS 26 SDK: CoreAI headers are present but runtime is < 27.0
            // → fall back to MLX ChatSession path (detokenize → _runInferenceWithMessages)
            // This is the same fallback as the #else branch below, duplicated because
            // the #else cannot be reached when canImport(CoreAI) is true.
            logger.info(
                "CoreAI SDK present but macOS < 27.0 — falling back to MLX for model \\(modelId)")
            let promptText: String
            do {
                promptText = try await detokenize(modelId: modelId, tokens: input)
            } catch {
                logger.warning(
                    "Detokenize failed for CoreAI→MLX runtime fallback: \\(error.localizedDescription)"
                )
                continuation.yield(
                    .init(kind: .error("Detokenization failed — inference cannot proceed")))
                continuation.finish()
                return
            }
            let mlxMessages: [Message] = [.init(role: "user", content: promptText)]
            await _runInferenceWithMessages(
                modelId: modelId,
                messages: mlxMessages,
                sampling: sampling,
                options: options,
                metrics: metrics,
                continuation: continuation,
                conversationId: nil,
                cancellation: cancellation,
                skipLock: true
            )
        }
        #else
        // [KNOWN LIMITATION] MLXLLM ChatSession only accepts [Chat.Message], not raw tokens.
        // Detokenize → Message → re-tokenize path drops special control tokens
        // (e.g. <|begin_of_thought|>, <|eot_id|>). Track upstream for promptTokens API:
        // https://github.com/ml-explore/mlx-swift-examples/issues
        // Mitigation: log warning when input may contain non-text tokens.
        let promptText: String
        do {
            promptText = try await detokenize(modelId: modelId, tokens: input)
        } catch {
            logger.warning("Detokenize failed in #else fallback: \(error.localizedDescription)")
            continuation.yield(
                .init(kind: .error("Detokenization failed — inference cannot proceed")))
            continuation.finish()
            return
        }

        // Check for reasoning control tokens that will be lost in
        // detokenize→retokenize roundtrip. Qwen3: 151645/151646; other families
        // (DeepSeek, Gemma) use different IDs. Text-level fallback catches all.
        // P0-fix: removed universal ASCII control chars (newline=198, ESC=27) —
        // they fire on every request and flood the log.
        let hasReasoningMarkers =
            promptText.contains("< thinking>") || promptText.contains("</ thinking>")
            || promptText.contains("<think") || promptText.contains("</think")
        if hasReasoningMarkers || input.contains(where: { $0 == 151645 || $0 == 151646 }) {
            logger.warning("MLX token→text→token path may drop control tokens for model \(modelId)")
        }

        let mlxMessages: [Message] = [.init(role: "user", content: promptText)]
        await _runInferenceWithMessages(
            modelId: modelId,
            messages: mlxMessages,
            sampling: sampling,
            options: options,
            metrics: metrics,
            continuation: continuation,
            conversationId: nil,
            cancellation: cancellation,
            skipLock: true,  // caller (_runInference) already holds inference guard
        )
        #endif

        metrics.inferenceMs = metrics.overallMs
        continuation.finish()
    }

    // MARK: - MLX ToolCall Conversion

    /// Convert ocoreai ``ToolCall`` to upstream MLXLMCommon ``ToolCall``.
    /// Top-level free function so it doesn't capture EnginePool self — avoids
    /// Sendable taint in the inference body closure for WiredMemoryTicket.
    nonisolated func mLXToolCall(from tc: ToolCall) -> MLXLMCommon.ToolCall {
        func parseArgs(_ args: String) -> [String: any Sendable] {
            let data = args.data(using: .utf8) ?? Data()
            guard
                let obj = try? JSONSerialization.jsonObject(with: data, options: [])
                    as? [String: Any]
            else {
                return [:]
            }
            var result: [String: any Sendable] = [:]
            for (key, value) in obj {
                switch value {
                case let s as String: result[key] = s
                case let d as Double: result[key] = d
                case let i as Int: result[key] = i
                case let b as Bool: result[key] = b
                case let dict as [String: Any]: result[key] = _convJSONDict(dict)
                default: break
                }
            }
            return result
        }
        func _convJSONDict(_ dict: [String: Any]) -> any Sendable {
            var result: [String: any Sendable] = [:]
            for (k, v) in dict {
                result[k] = _convJSON(v)
            }
            return result
        }
        func _convJSON(_ value: Any) -> any Sendable {
            switch value {
            case let s as String: return s
            case let d as Double: return d
            case let i as Int: return i
            case let b as Bool: return b
            case let dict as [String: Any]: return _convJSONDict(dict)
            case let arr as [Any]:
                let mapped = arr.map { _convJSON($0) }
                // [any Sendable] conforms to Sendable
                return mapped as any Sendable
            default: return "null"
            }
        }
        return MLXLMCommon.ToolCall(
            function: MLXLMCommon.ToolCall.Function(
                name: tc.function.name,
                arguments: parseArgs(tc.function.arguments)
            ),
            id: tc.id
        )
    }

    // MARK: - CoreAI Constrained Decoding

    #if canImport(CoreAI)
    /// GPU pipelined grammar-constrained decoding (#170).
    ///
    /// Dispatch companion to `_runConstrainedDecoding`: same request context,
    /// but the decode loop runs on the GPU pipelined engine — the xgrammar
    /// bitmask is applied inside the MPSGraph sampler (no ~296KB logits CPU
    /// round-trip per token). Aligned with upstream coreai-models
    /// `CoreAILanguageModel.respondConstrained` (L582-596), which routes to
    /// `PipelinedConstrainedDecodingStrategy` when the engine is
    /// `ConstrainedGenerationCapable`.
    ///
    /// Text segmentation (ThinkTagParser → ToolCallParser) reuses the same
    /// helpers as the other CoreAI paths (`.text` / `.reasoning` / `.toolCall`).
    @available(macOS 27.0, iOS 27.0, *)
    private func _runPipelinedConstrainedDecoding(
        engine: any ConstrainedGenerationCapable,
        modelId: String,
        messages: [Message]?,
        input: [Int32],
        sampling: SamplingConfiguration,
        options: InferenceOptions,
        metrics: PerRequestMetrics,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation,
        cancellation: InferenceCancellation
    ) async {
        _ = messages
        defer { continuation.finish() }

        // Tokenizer — CoreAI-native path: swift-transformers tokenizer
        // registered via TokenizerManager (same provider the sequential loop uses).
        guard let provider = await tokenizerManager.getTokenizer(for: modelId) else {
            continuation.yield(
                .init(
                    kind: .error(
                        InferenceError.standardPathFailed(
                            "No tokenizer registered for model: \(modelId)"
                        )
                        .errorDescription ?? "error")))
            return
        }
        let tokenizer = provider.underlying

        let jsonSchema =
            options.grammarSchema
                ?? """
                {"type":"object","properties":{}}
                """

        let stopSequences = StopSequences(
            for: tokenizer,
            additionalSequences: (sampling.stopSequences ?? []).map {
                Array(provider.underlying.encode(text: $0).map(Int32.init))
            },
            additionalEosTokenIds: [Int32(0)]
        )

        let maxTokens = options.maxTokens ?? 4096

        // Same think/tool parser setup + primedInside detection as the
        // sequential constrained loop (upstream ThinkTagParser defaults).
        let openMarker = "<think" + "ing>"
        let closeMarker = "</think" + "ing>"
        let primedInside: Bool
        do {
            let tailPrompt = try await detokenize(modelId: modelId, tokens: input)
            primedInside = ThinkTagParser.promptEndsInsideReasoning(
                renderedPromptTail: tailPrompt,
                openMarker: openMarker,
                closeMarker: closeMarker
            )
        } catch {
            primedInside = false
            logger.warning(
                "Pipelined constrained primedInside detection failed: \(error.localizedDescription)"
            )
        }
        var thinkParser = ThinkTagParser(
            open: openMarker, close: closeMarker, primedInside: primedInside)
        var toolParser = ToolCallParser()
        var accumulatedTokens: [Int32] = []
        var accumulatedReasoningChars = 0

        do {
            // Strategy: capability-selected per upstream respondConstrained —
            // the engine conforms to ConstrainedGenerationCapable, so the
            // decoded sequence is a GPU pipelined one.
            let sequence: PipelinedConstrainedSequence =
                try await PipelinedConstrainedDecodingStrategy(
                    jsonSchema: jsonSchema
                ).decode(
                    from: .tokens(Array(input.map { Int($0) })),
                    tokenizer: tokenizer,
                    inferenceEngine: engine,
                    samplingConfiguration: sampling,
                    options: InferenceOptions(maxTokens: maxTokens),
                    stopSequences: stopSequences
                )

            for try await result in sequence {
                if Task.isCancelled || cancellation.isCancelled { break }

                metrics.incrementGenerated()
                if metrics.generatedTokenCount == 1 {
                    metrics.firstTokenMs = metrics.overallMs
                }
                accumulatedTokens.append(result.tokenId)

                let text = result.text
                guard !text.isEmpty else { continue }

                for thinkEvent in thinkParser.consume(text) {
                    switch thinkEvent {
                    case .reasoning(let segText):
                        accumulatedReasoningChars += segText.utf8.count
                        continuation.yield(.init(kind: .reasoning(segText)))
                    case .text(let segText):
                        for toolEvent in toolParser.consume(segText) {
                            switch toolEvent {
                            case .text(let plainText):
                                continuation.yield(.init(kind: .text(plainText)))
                            case .toolCall(let id, let name, let argsJSON):
                                continuation.yield(
                                    .init(
                                        kind: .toolCall(
                                            ToolCall(
                                                id: id,
                                                type: "function",
                                                function: ToolCallFunction(
                                                    name: name,
                                                    arguments: argsJSON
                                                )
                                            )
                                        )))
                            }
                        }
                    }
                }
            }

            // Grammar/EOS termination → flush residual + .done (same flush
            // convention as the sequential constrained loop).
            await self._flushResidualTokensAsync(
                &accumulatedTokens,
                modelId: modelId,
                thinkParser: &thinkParser,
                toolParser: &toolParser,
                continuation: continuation,
                metrics: metrics,
                logger: self.logger,
                stopReason: .eos,
                tokenCount: metrics.generatedTokenCount,
                reasoningTokenCount: accumulatedReasoningChars
            )
        } catch {
            continuation.yield(
                .init(
                    kind: .error(
                        InferenceError.standardPathFailed(
                            "Pipelined constrained decoding failed: \(error.localizedDescription)"
                        )
                        .errorDescription ?? "error")))
        }
    }

    /// CoreAI-native grammar constrained decoding loop.
    ///
    /// Architecture: CoreAI is CoreAI, MLX is MLX — no cross-framework fallback.
    /// This loop runs entirely within the CoreAI engine's inference context.
    ///
    /// Pipeline: prefill → [logits → grammar bitmask mask → CompositeSampler.sample
    /// → GrammarConstraint.accept → detokenize batch → parser yield] × maxTokens
    ///
    /// Aligned with upstream ConstrainedGenerationSession.applyMask() pattern:
    /// each decode step gets raw logits from SequentialEngine, applies xgrammar
    /// bitmask via _applyBitmask, then samples through CompositeSampler.
    @available(macOS 27.0, iOS 27.0, *)
    private func _runConstrainedDecoding(
        engine: CoreAISequentialEngine,
        modelId: String,
        messages: [Message]?,
        input: [Int32],
        sampling: SamplingConfiguration,
        options: InferenceOptions,
        metrics: PerRequestMetrics,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation,
        cancellation: InferenceCancellation
    ) async {
        guard let loaded = loadedModels[modelId] else {
            continuation.yield(.init(kind: .error("Model not loaded: \(modelId)")))
            continuation.finish()
            return
        }

        let stopSequences = sampling.stopSequences ?? []
        let maxTokens = options.maxTokens ?? loaded.modelConfig.maxContextLength

        // ThinkTagParser + ToolCallParser — same as standard CoreAI path
        let openMarker = "<think" + "ing>"
        let closeMarker = "</think" + "ing>"
        let primedInside: Bool
        do {
            let tailPrompt = try await detokenize(modelId: modelId, tokens: input)
            primedInside = ThinkTagParser.promptEndsInsideReasoning(
                renderedPromptTail: tailPrompt,
                openMarker: openMarker,
                closeMarker: closeMarker
            )
        } catch {
            primedInside = false
            logger.warning(
                "Constrained decoding primedInside detection failed: \(error.localizedDescription)"
            )
        }
        var thinkParser = ThinkTagParser(
            open: openMarker, close: closeMarker, primedInside: primedInside)
        var toolParser = ToolCallParser()

        // — Grammar constraint setup —
        // CoreAI-native tokenizer path: CoreAI models have no `mlxModelHandle`,
        // so the constraint is built from the CoreAI-side swift-transformers
        // tokenizer (registered via TokenizerManager), bridged through
        // `TokenizersMLXTokenizerAdapter`. `GrammarTokenizer`/`GrammarConstraint`
        // are xgrammar-backed (MLXCXGrammar C++ shim) — no MLX tensor
        // dependencies. fastForward is disabled because the adapter's
        // applyChatTemplate is conformance-only.
        do {
            guard let provider = await tokenizerManager.getTokenizer(for: modelId) else {
                continuation.yield(
                    .init(
                        kind: .error(
                            InferenceError.standardPathFailed(
                                "No tokenizer registered for model: \(modelId)"
                            )
                            .errorDescription ?? "error")))
                continuation.finish()
                return
            }
            let host = TokenizersMLXTokenizerAdapter(base: provider.underlying)
            let grammarTokenizer = try loaded.getOrCreateGrammarTokenizer(from: host)
            let constraint = try loaded.getOrCreateConstraint(
                grammarTokenizer: grammarTokenizer,
                hostTokenizer: host,
                jsonSchema: options.grammarSchema
                    ?? """
                    {"type":"object","properties":{}}
                    """,
                fastForward: false
            )

            // — Constrained decode loop —
            var accumulatedTokens: [Int32] = []
            var accumulatedReasoningChars = 0
            var firstYielded = false
            var grammarTerminated = false
            var effectiveStopReason: StopReason? = nil
            let decodeBatchSize = 8

            // Phase 1: Prefill — let engine process all input tokens
            // startConstrainedDecoding returns DecodeStepLogits on first call
            // (logits for position 0 post-prefill) or nil if prefill complete.
            let initLogits = try await engine.startConstrainedDecoding(
                with: input,
                maxTokens: maxTokens
            )

            // Phase 2: Per-token decode loop
            // The loop: logits → grammar mask → sample → commit → feed to engine
            // First iteration uses initLogits from prefill; subsequent iterations
            // get logits from feedToken().
            var nextLogits: CoreAISequentialEngine.DecodeStepLogits? = initLogits
            for step in 0 ..< maxTokens {
                if Task.isCancelled || cancellation.isCancelled {
                    await self._flushResidualTokensAsync(
                        &accumulatedTokens,
                        modelId: modelId,
                        thinkParser: &thinkParser,
                        toolParser: &toolParser,
                        continuation: continuation,
                        metrics: metrics,
                        logger: self.logger,
                        stopReason: .cancelled,
                        tokenCount: metrics.generatedTokenCount,
                        reasoningTokenCount: accumulatedReasoningChars
                    )
                    return
                }

                // Need logits for this step
                guard let logitsBundle = nextLogits, !logitsBundle.logits.isEmpty
                else {
                    // Engine exhausted (no more decode positions)
                    await self._flushResidualTokensAsync(
                        &accumulatedTokens,
                        modelId: modelId,
                        thinkParser: &thinkParser,
                        toolParser: &toolParser,
                        continuation: continuation,
                        metrics: metrics,
                        logger: self.logger,
                        stopReason: .maxTokens,
                        tokenCount: metrics.generatedTokenCount,
                        reasoningTokenCount: accumulatedReasoningChars
                    )
                    return
                }

                // Clone logits — grammar constraint mutates in-place
                var logits: [LogitsScalarType] = logitsBundle.logits
                nextLogits = nil

                // Grammar mask: disallowed tokens → -inf (upstream ConstrainedGen pattern)
                if !grammarTerminated {
                    do {
                        let maskResult = try constraint.computeMask()
                        if maskResult.needsApply {
                            maskResult.mask.withUnsafeBufferPointer { maskBuf in
                                var f32logits = logits.map { Float($0) }
                                Self._applyBitmask(
                                    &f32logits,
                                    mask: maskBuf,
                                    vocabSize: maskResult.mask.count * 32
                                )
                                logits = f32logits.map { LogitsScalarType($0) }
                            }
                        }
                        if maskResult.isTerminated {
                            grammarTerminated = true
                        }
                    } catch {
                        logger.warning(
                            "Constrained mask compute failed (step \(step)): \(error.localizedDescription)"
                        )
                    }
                }

                // Sample token from masked logits
                let tokenId = CompositeSampler.sample(from: &logits, config: sampling)

                // Commit token to grammar state (may fast-forward)
                do {
                    let commitResult = try constraint.commitToken(tokenId)
                    // Emit fast-forward tokens if any (structural grammar tokens)
                    for ffToken in commitResult.tokens {
                        accumulatedTokens.append(ffToken)
                        metrics.incrementGenerated()
                        if step == 0 && accumulatedTokens.count == 1 {
                            metrics.firstTokenMs = metrics.overallMs
                        }
                    }
                    if commitResult.isTerminated {
                        grammarTerminated = true
                    }
                } catch {
                    logger.warning(
                        "Constrained commit failed (step \(step) token \(tokenId)): \(error.localizedDescription)"
                    )
                }

                // Check EOS
                if tokenId == engine.config.eosTokenId {
                    accumulatedTokens.append(tokenId)
                    metrics.incrementGenerated()
                    await self._flushResidualTokensAsync(
                        &accumulatedTokens,
                        modelId: modelId,
                        thinkParser: &thinkParser,
                        toolParser: &toolParser,
                        continuation: continuation,
                        metrics: metrics,
                        logger: self.logger,
                        stopReason: .eos,
                        tokenCount: metrics.generatedTokenCount,
                        reasoningTokenCount: accumulatedReasoningChars
                    )
                    return
                }

                // Grammar terminated
                if grammarTerminated {
                    accumulatedTokens.append(tokenId)
                    metrics.incrementGenerated()
                    await self._flushResidualTokensAsync(
                        &accumulatedTokens,
                        modelId: modelId,
                        thinkParser: &thinkParser,
                        toolParser: &toolParser,
                        continuation: continuation,
                        metrics: metrics,
                        logger: self.logger,
                        stopReason: .maxTokens,
                        tokenCount: metrics.generatedTokenCount,
                        reasoningTokenCount: accumulatedReasoningChars
                    )
                    return
                }

                accumulatedTokens.append(tokenId)
                metrics.incrementGenerated()
                if step == 0 {
                    metrics.firstTokenMs = metrics.overallMs
                }

                // Batch detokenize every decodeBatchSize tokens
                guard accumulatedTokens.count % decodeBatchSize != 0
                else {
                    await self._detokenizeAndYieldBatch(
                        &accumulatedTokens,
                        modelId: modelId,
                        thinkParser: &thinkParser,
                        toolParser: &toolParser,
                        continuation: continuation,
                        metrics: metrics,
                        logger: self.logger,
                        stopSequences: stopSequences,
                        effectiveStopReason: &effectiveStopReason,
                        accumulatedReasoningChars: &accumulatedReasoningChars
                    )
                    // Feed sampled token back to engine to advance decode
                    do {
                        nextLogits = try await engine.feedToken(tokenId, maxTokens: maxTokens)
                    } catch {
                        logger.warning(
                            "Constrained feedToken failed (step \(step)): \(error.localizedDescription)"
                        )
                    }
                    continue
                }

                // Feed sampled token back to engine to advance decode
                do {
                    nextLogits = try await engine.feedToken(tokenId, maxTokens: maxTokens)
                } catch {
                    logger.warning(
                        "Constrained feedToken failed (step \(step)): \(error.localizedDescription)"
                    )
                }
            }

            // Flush any remaining tokens and close
            await self._flushResidualTokensAsync(
                &accumulatedTokens,
                modelId: modelId,
                thinkParser: &thinkParser,
                toolParser: &toolParser,
                continuation: continuation,
                metrics: metrics,
                logger: self.logger,
                stopReason: effectiveStopReason ?? .maxTokens,
                tokenCount: metrics.generatedTokenCount,
                reasoningTokenCount: accumulatedReasoningChars
            )

        } catch {
            continuation.yield(
                .init(
                    kind: .error(
                        InferenceError.standardPathFailed(
                            "Constrained decoding failed: \(error.localizedDescription)"
                        )
                        .errorDescription ?? "error")))
            continuation.finish()
        }
    }

    #endif  // canImport(CoreAI)

    /// Apply xgrammar bitmask to logits — disallowed tokens → -inf.
    /// LSB-first int32 bitmask: bit `i` of word `w` covers token `w*32+i`.
    private static func _applyBitmask(
        _ logits: inout [Float],
        mask: UnsafeBufferPointer<Int32>,
        vocabSize: Int
    ) {
        for wordIdx in 0 ..< mask.count {
            var word = mask[wordIdx]
            for bit in 0 ..< 32 {
                let tokenIdx = wordIdx * 32 + bit
                guard tokenIdx < vocabSize, tokenIdx < logits.count else { return }
                if (word & (1 << bit)) == 0 {
                    logits[tokenIdx] = Float.leastNormalMagnitude * -1
                }
            }
        }
    }

    /// Flush remaining accumulated tokens, run through parser pipeline,
    /// flush held-back parser buffers, and yield the final .done event.
    @available(macOS 27.0, iOS 27.0, *)
    private func _flushResidualTokensAsync(
        _ accumulatedTokens: inout [Int32],
        modelId: String,
        thinkParser: inout ThinkTagParser,
        toolParser: inout ToolCallParser,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation,
        metrics: PerRequestMetrics,
        logger: Logger,
        stopReason: StopReason,
        tokenCount: Int,
        reasoningTokenCount: Int
    ) async {
        if !accumulatedTokens.isEmpty {
            do {
                let decoded = try await detokenize(modelId: modelId, tokens: accumulatedTokens)
                _ = Self.yieldParserEvents(
                    decoded,
                    thinkParser: &thinkParser,
                    toolParser: &toolParser,
                    continuation: continuation
                )
            } catch {
                logger.warning(
                    "Constrained decode residual flush failed: \(error.localizedDescription)")
            }
            accumulatedTokens = []
        }

        for thinkEvent in thinkParser.flush() {
            switch thinkEvent {
            case .reasoning(let segText):
                continuation.yield(.init(kind: .reasoning(segText)))
            case .text(let segText):
                for toolEvent in toolParser.consume(segText) {
                    switch toolEvent {
                    case .text(let plainText):
                        continuation.yield(.init(kind: .text(plainText)))
                    case .toolCall(let id, let name, let argsJSON):
                        continuation.yield(
                            .init(
                                kind: .toolCall(
                                    ToolCall(
                                        id: id, type: "function",
                                        function: ToolCallFunction(name: name, arguments: argsJSON))
                                )))
                    }
                }
            }
        }

        let tokPerSec =
            tokenCount > 0
            ? Double(tokenCount) / (Double(metrics.overallMs) / 1000.0)
            : nil
        continuation.yield(
            .init(
                kind: .done(
                    stopReason,
                    tokenCount: tokenCount,
                    tokPerSec: tokPerSec,
                    promptTokPerSec: nil,
                    reasoningTokenCount: reasoningTokenCount
                )))
        continuation.finish()
    }

    /// Detokenize a batch of tokens, check stop sequences, and yield parser events.
    /// Sets `effectiveStopReason` if a stop sequence is hit.
    @available(macOS 27.0, iOS 27.0, *)
    private func _detokenizeAndYieldBatch(
        _ accumulatedTokens: inout [Int32],
        modelId: String,
        thinkParser: inout ThinkTagParser,
        toolParser: inout ToolCallParser,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation,
        metrics: PerRequestMetrics,
        logger: Logger,
        stopSequences: [String],
        effectiveStopReason: inout StopReason?,
        accumulatedReasoningChars: inout Int
    ) async {
        do {
            let decoded: String
            decoded = try await detokenize(modelId: modelId, tokens: accumulatedTokens)

            // Stop sequence check
            if let hit = Self.firstMatchStopSequence(in: decoded, sequences: stopSequences) {
                let preStop = String(decoded[decoded.startIndex ..< hit.offset])
                if !preStop.isEmpty {
                    accumulatedReasoningChars += Self.yieldParserEvents(
                        preStop,
                        thinkParser: &thinkParser,
                        toolParser: &toolParser,
                        continuation: continuation
                    )
                }
                effectiveStopReason = .stopSequence
                accumulatedTokens = []
                return
            }

            accumulatedReasoningChars += Self.yieldParserEvents(
                decoded,
                thinkParser: &thinkParser,
                toolParser: &toolParser,
                continuation: continuation
            )
        } catch {
            logger.warning(
                "Constrained decode batch detokenize failed: \(error.localizedDescription)")
        }
        accumulatedTokens = []
    }

    private func _runInferenceWithMessages(
        modelId: String,
        messages: [Message],
        sampling: SamplingConfiguration,
        options: InferenceOptions,
        metrics: PerRequestMetrics,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation,
        conversationId: String?,
        cancellation: InferenceCancellation = .none,
        skipLock: Bool = false,
    ) async {
        // Query HardwareRouter for runtime compute channel decision.
        // Channel drives session pool + speculative decoding for .cpu.
        // Note: per-request device switching (GPU→CPU) is not possible — device
        // is bound at ModelContainer load time. True CPU inference requires
        // architectural change (separate ModelContainer with CPU device).
        var computeChannel: ComputeChannel
        if let router = hardwareRouter, let tracker = memoryTracker {
            computeChannel = router.query(
                gpuActiveBytes: await tracker.gpuActiveMemoryBytes(),
                gpuBudgetBytes: await tracker.getBudget(),
                priority: .chat
            )
            let gpuGB = String(
                format: "%.1f", Double(await tracker.gpuActiveMemoryBytes()) / 1_073_741_824.0)
            let budgetGB = String(
                format: "%.1f", Double(await tracker.getBudget()) / 1_073_741_824.0)

            switch computeChannel {
            case .gpu:
                logger.debug("HardwareRouter → GPU for \(modelId) (gpu: \(gpuGB)/\(budgetGB) GB)")
            case .cpu:
                logger.warning(
                    "HardwareRouter → CPU for \(modelId) (gpu: \(gpuGB)/\(budgetGB) GB) — disabling session pool + speculative decoding"
                )
            case .ane:
                #if canImport(CoreAI)
                logger.info("HardwareRouter → ANE for \(modelId) (gpu: \(gpuGB)/\(budgetGB) GB)")
                #else
                logger.warning(
                    "HardwareRouter → ANE for \(modelId) but CoreAI unavailable, falling back to GPU (gpu: \(gpuGB)/\(budgetGB) GB)"
                )
                computeChannel = .gpu
                #endif
            }
        } else {
            computeChannel = .gpu
            logger.debug("HardwareRouter not initialized, defaulting to GPU for \(modelId)")
        }

        guard let loaded = loadedModels[modelId] else {
            continuation.yield(.init(kind: .error("Model not loaded: \(modelId)")))
            continuation.finish()
            return
        }

        // Vision capability guard: reject multimodal input for LLM-only models.
        // Aligns with MLXLanguageModel Executor.respond() L950-965 — the adapter
        // is the only place that can enforce .vision before loading any weights.
        func hasMultimodalContent(_ msgs: [Message]) -> Bool {
            msgs.contains { msg in
                if case .parts(let parts) = msg.content {
                    return !parts.lazy.filter {
                        $0.imageUrl != nil || $0.videoUrl != nil || $0.audioURL != nil
                    }.isEmpty
                }
                return false
            }
        }
        if !loaded.isVlm, hasMultimodalContent(messages) {
            continuation.yield(
                .init(
                    kind: .error(
                        "Model \(modelId) does not support multimodal input — images, videos, or audio require a VLM"
                    )))
            continuation.finish()
            return
        }

        // P0-fix: Validate ANE runtime availability and content compatibility
        // before emitting channel event. On macOS/iOS < 27 with canImport(CoreAI) compiled,
        // _runInference falls back to MLX GPU via the #available guard below —
        // without this check, downstream (UI/SSE) receives .ane event while actual
        // inference runs on GPU.
        // X6-fix: Also check multimodal content — CoreAI `_runInference` cannot tokenize
        // multimodal content (`contentToString()` in EnginePool.tokenize() silently drops
        // images/videos/audio, producing text-only output for VLM requests).
        // b3: Also check captured perception media — the b2 injection delivers image/
        // audio bytes only via the MLX path. If ANE is selected, a VLM's perception
        // media would be silently dropped (CoreAI cannot tokenize VLM media), so
        // fall back to GPU exactly like user-attached media.
        // Gate both BEFORE badge emit so the badge reflects the actual accelerator.
        #if canImport(CoreAI)
        if computeChannel == .ane {
            let perceptionMediaParts = await PerceptionEngine.shared.mediaContentParts()
            let perceptionMediaPresent = loaded.isVlm && !perceptionMediaParts.isEmpty
            if !PlatformHelpers.isCoreAIRuntimeAvailable {
                logger.warning(
                    "HardwareRouter → ANE but CoreAI runtime unavailable, falling back to GPU for \(modelId)"
                )
                computeChannel = .gpu
            } else if hasMultimodalContent(messages) {
                logger.info(
                    "ANE selected but multimodal content present (CoreAI cannot tokenize VLM), falling back to GPU for \(modelId)"
                )
                computeChannel = .gpu
            } else if perceptionMediaPresent {
                logger.info(
                    "ANE selected but perception media present (CoreAI cannot tokenize VLM media), falling back to GPU for \(modelId)"
                )
                computeChannel = .gpu
            }
        }
        #endif

        // Emit channel identification event — tells downstream (UI, diagnostics)
        // which inference pipeline produced the response: FM/Metal GPU, CPU, or CoreAI ANE.
        continuation.yield(.init(kind: .channel(computeChannel)))

        #if canImport(CoreAI)
        if computeChannel == .ane {
            logger.info("ANE channel: routing model \(modelId) through CoreAI engine")
            do {
                let tokens = try await tokenize(modelId: modelId, messages: messages)
                let count = tokens.count
                if count > loaded.modelConfig.maxContextLength {
                    continuation.yield(
                        .init(
                            kind: .error(
                                "Input \(count) exceeds max context \(loaded.modelConfig.maxContextLength)"
                            )))
                    continuation.finish()
                    return
                }
                metrics.promptTokenCount = count
                metrics.start()
                await _runInference(
                    modelId: modelId,
                    input: tokens,
                    messages: messages,
                    sampling: sampling,
                    options: options,
                    metrics: metrics,
                    continuation: continuation,
                    cancellation: cancellation
                )
            } catch {
                continuation.yield(
                    .init(
                        kind: .error(
                            InferenceError.standardPathFailed("MTP/standard inference failed")
                                .errorDescription ?? "error")))
                continuation.finish()
                return
            }
            return
        }
        #endif

        let tokenCount: Int
        do {
            let tokens = try await tokenize(modelId: modelId, messages: messages)
            tokenCount = tokens.count
            if tokenCount > loaded.modelConfig.maxContextLength {
                continuation.yield(
                    .init(
                        kind: .error(
                            "Input \(tokenCount) exceeds max context \(loaded.modelConfig.maxContextLength)",
                        )))
                continuation.finish()
                return
            }
        } catch {
            /// Fallback: mlx containers have their own tokenizer, use heuristic estimate
            /// P1-fix: CJK-aware estimation — UTF-8 bytes/4 overestimates for CJK text
            /// (CJK chars are 3 bytes UTF-8 but ~1.5 tokens on average, not 1).
            /// Use bytes/3 for CJK-heavy content, bytes/4 for Latin-heavy.
            /// Character-level detection: if avg bytes per char > 1.5, likely CJK.
            logger.warning(
                "Tokenization failed, using heuristic estimate for metrics — \(error.localizedDescription)"
            )
            let totalBytes = messages.reduce(0) { $0 + $1.textContent().utf8.count }
            let totalChars = messages.reduce(0) { $0 + $1.textContent().count }
            let avgBytesPerChar = totalChars > 0 ? Double(totalBytes) / Double(totalChars) : 1.0
            // CJK threshold: avg bytes/char > 1.5 indicates non-Latin dominant text
            let divisor = avgBytesPerChar > 1.5 ? 3 : 4
            tokenCount = max(1, Int(Double(totalBytes) / Double(divisor)))
        }

        metrics.promptTokenCount = tokenCount
        metrics.start()

        // skipLock: caller already holds inference guard (e.g. _runInference delegate path)
        var lockHeldByUs = false
        if !skipLock {
            guard loaded.tryAcquireInference() else {
                continuation.yield(.init(kind: .error("Engine busy")))
                continuation.finish()
                return
            }
            lockHeldByUs = true
        }
        defer { if lockHeldByUs { loaded.releaseInference() } }

        guard let mlxHandle = loaded.mlxModelHandle else {
            continuation.yield(.init(kind: .error("MLX model handle not loaded: \(modelId)")))
            continuation.finish()
            return
        }

        // Convert messages to MLX format, collecting temp audio file URLs for later cleanup.
        // Data: audio URLs are decoded to /tmp .caf files — we must delete them after
        // inference completes (success or failure) to prevent disk leaks.
        var tempAudioURLs: [URL] = []
        defer {
            for url in tempAudioURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // Extract system prompt for ChatSession's instructions: channel.
        // Upstream L186/L219: instructions are prepended as .system messages
        // inside ChatSession — passing them via messages: triggers duplicate
        // tokenization (upstream L319-322).
        //
        // P-S1 fix: Append perception context to system instructions so
        // multimodal environment awareness flows through the correct path
        // (system context, not user message parts).
        var systemInstructions: String? =
            switch messages.first(where: { $0.role == "system" })?.content {
            case .text(let t): t
            case .parts(let p): p.first(where: { $0.text != nil })?.text
            case nil: nil
            }

        // Inject perception context as system augmentation
        let perceptionContext = await PerceptionEngine.shared.contextText()
        if !perceptionContext.isEmpty {
            systemInstructions =
                (systemInstructions ?? "") + (systemInstructions?.isEmpty == false ? "\n" : "")
                + perceptionContext
        }

        let nonSystemMessages = messages.filter { $0.role != "system" }

        var mlxMessages: [Chat.Message] = nonSystemMessages.map { msg in
            let role: Chat.Message.Role =
                switch msg.role {
                case "assistant": .assistant
                case "tool": .tool
                default: .user
                }

            // Assistant with tool calls — use factory with toolCalls param
            if let tcs = msg.toolCalls, !tcs.isEmpty {
                let mlxTCs = tcs.map { mLXToolCall(from: $0) }
                return Chat.Message.assistant("", toolCalls: mlxTCs)
            }

            // Tool result — use factory with id param for tool call correlation
            if msg.role == "tool", let tid = msg.toolCallID {
                let contentStr = contentToString(msg.content).0
                return Chat.Message.tool(contentStr, id: tid)
            }

            // Default: content-based construction via general init
            switch msg.content {
            case .text(let text):
                return Chat.Message(role: role, content: text)
            case .parts(let parts):
                var textParts: [String] = []
                var images: [MLXLMCommon.UserInput.Image] = []
                var videos: [MLXLMCommon.UserInput.Video] = []
                var audios: [MLXLMCommon.UserInput.Audio] = []
                for part in parts {
                    if let text = part.text {
                        textParts.append(text)
                    }
                    if let img = part.imageUrl, let image = makeMLXImage(from: img.url) {
                        images.append(image)
                    }
                    if let video = part.videoUrl {
                        // Video URL into VLM — upstream processes frames via Gemma4Processor
                        if let url = URL(string: video.url) {
                            videos.append(.url(url))
                        }
                    }
                    if let audio = part.audioURL {
                        // Data URLs are decoded to temp .caf files via makeMLXAudio helper
                        let result = makeMLXAudio(from: audio.url)
                        if let audioInput = result.audio {
                            audios.append(audioInput)
                        }
                        if let tempFile = result.tempURL {
                            tempAudioURLs.append(tempFile)
                        }
                    }
                }
                return Chat.Message(
                    role: role,
                    content: textParts.joined(separator: " "),
                    images: images,
                    videos: videos,
                    audios: audios,
                )
            case nil:
                return Chat.Message(role: role, content: "")
            }
        }

        // b2: Delivery of perception media (image bytes/audio) — attach to the
        // last user message so VLMs receive actual pixels/audio. The LLM-only
        // rejection at L1448 (hasMultimodalContent) already guards user-attached
        // media; perception media is only injected for VLMs (loaded.isVlm), so
        // the same guarantee holds here. Text/OCR frames stay on the system
        // path via contextText() — see mediaContentParts() doc.
        if loaded.isVlm {
            let perceptionMedia = await MainActor.run {
                PerceptionEngine.shared.mediaContentParts()
            }
            if !perceptionMedia.isEmpty {
                let mediaTempURLs = attachPerceptionMedia(
                    &mlxMessages,
                    mediaParts: perceptionMedia,
                    makeImage: makeMLXImage,
                    makeAudio: makeMLXAudio
                )
                tempAudioURLs.append(contentsOf: mediaTempURLs)
            }
        }

        let genParams = makeGenerateParameters(
            from: sampling,
            maxTokens: options.maxTokens,
            kvCacheQuant: config.kvCacheQuantization,
            progressHandler: { processed, total in
                continuation.yield(
                    .init(kind: .prefillProgress(processed: processed, total: total))
                )
            },
        )

        // Build speculative decoding config once before inference body.
        // CPU channel: disable session pool + speculative decoding (no shared memory, no Metal kernel).
        let specConfig: MLXLMCommon.SpeculativeDecodingConfig?
        if computeChannel == .cpu {
            specConfig = nil
        } else {
            specConfig = loaded.createSpeculativeConfig()
        }

        // Request-level stop sequences — pull out before inference body to avoid self-capture
        let requestStopSequences = (sampling.stopSequences ?? []).filter { !$0.isEmpty }

        // Hoist sessionPool, mlxHandle, logger before creating inference closure.
        // CPU channel: bypass session pool (KV cache not reusable across device boundaries).
        let poolRef: MLXSessionPool?
        if computeChannel == .cpu {
            poolRef = nil
        } else {
            poolRef = sessionPool
        }
        let handleRef = mlxHandle
        let log = self.logger

        // handleGuidedGeneration: MLXGuidedGeneration grammar-constrained path
        /// Bridges GuidedGenerationLoop (sync emit callback) → SSE continuation.
        /// All inference within modelContainer.perform for thread-safe ModelContext.
        func handleGuidedGeneration(
            messagePairs: [(role: String, content: String)],
            grammarSchema: String,
            maxTokens: Int,
        ) async throws {
            try await handleRef.modelContainer.perform { context in
                // Rebuild Chat.Message inside the @Sendable closure to avoid
                // cross-actor capture of non-Sendable [Chat.Message].
                var messages = messagePairs.map { pair in
                    Chat.Message(
                        role: Chat.Message.Role(rawValue: pair.role) ?? .system,
                        content: pair.content
                    )
                }
                // Strip trailing empty assistant message so the chat template
                // leaves the assistant turn open for generation — mirrors upstream
                // MLXChatExample pattern (see upstream L104-107)
                if let last = messages.last, last.role == .assistant, last.content.isEmpty {
                    messages.removeLast()
                }
                // Pass processing params (resize) to control VLM image scale — mirrors
                // MLXChatExample: UserInput.Processing(resize: CGSize(width:1024, height:1024))
                // Value read from config so users can tune per-image token overhead.
                let uiProcessing = UserInput.Processing(resize: config.vlmImageResize)
                let userInput = UserInput(prompt: .chat(messages), processing: uiProcessing)
                let lmInput = try await context.processor.prepare(input: userInput)

                // Build GrammarTokenizer — cached per-model via LoadedModel mirror of
                // MLXFoundationModels.MLXLanguageModel.swift L163 ModelCache.xgTokenizers.
                // First call builds + caches; subsequent guided gen requests reuse cached.
                let grammarTokenizer: GrammarTokenizer
                do {
                    grammarTokenizer = try loaded.getOrCreateGrammarTokenizer(
                        from: context.tokenizer)
                } catch {
                    continuation.yield(
                        .init(
                            kind: .error(
                                InferenceError.tokenizerBuildFailed(
                                    "Grammar tokenizer build failed"
                                ).errorDescription ?? "error")))
                    return
                }

                // Build GrammarConstraint — use cached constraint templates for repeated schemas.
                // Passing fastForward: true + hostTokenizer enables xgrammar's
                // FindJumpForwardString to emit deterministic structural tokens instead of
                // sampling them, reducing latency for JSON grammar traversal by 2-10x.
                // Mirrors upstream ModelCache.makeConstraint(modelID:kind:source:tokenizer:hostTokenizer:fastForward:).
                let constraint: GrammarConstraint
                do {
                    constraint = try loaded.getOrCreateConstraint(
                        grammarTokenizer: grammarTokenizer,
                        hostTokenizer: context.tokenizer,
                        jsonSchema: grammarSchema,
                        fastForward: true
                    )
                } catch {
                    continuation.yield(
                        .init(
                            kind: .error(
                                InferenceError.grammarBuildFailed("Grammar constraint build failed")
                                    .errorDescription ?? "error")))
                    return
                }

                // Token count tracking for guided path
                var guidedTokenCount = 0
                var firstYielded = false
                var guidedAccumulated = ""  // for stop-sequence matching
                // Track whether emit callback already yielded a .done event —
                // prevents double .done emission when the callback breaks the
                // loop early (stop sequence, cancellation).
                var doneAlreadyYielded = false

                // GuidedGenerationDiagnosticSink: zero-cost in production (TaskLocal,
                // nil when unbound). Binds here so upstream recording sites in
                // GuidedGenerationLoop capture token IDs, termination reason, and
                // buffer integrity — structured data for debugging guided gen failures.
                let diagnosticSink = GuidedGenerationDiagnosticSink()
                let diagnosticResult: GuidedGenerationDiagnosticResult

                // Closing token bias + whitespace bias — cached per-model (mirrors upstream
                // ModelCache.tokenizerBiases). First call computes (~1ms), subsequent
                // calls hit the LoadedModel cache.
                let tokenBias = loaded.getOrCreateTokenBias(
                    tokenizer: context.tokenizer)
                let closingBias = tokenBias.closing
                let whitespaceBias = tokenBias.whitespace
                let whitespaceTokenIDs = tokenBias.whitespaceTokenIDs

                // Dynamic completion reserve — mirrors upstream CompletionReserve.estimate
                // (MLXGuidedGeneration/CompletionReserve.swift:23). Hardcoded 64/0 caused
                // premature truncation for complex schemas. Upstream recipe:
                //   structuralReserve = token count of minimal valid JSON for schema
                //   completionReserve = max(structuralReserve * 3, maxTokens / 4)
                //   hardReserve = structuralReserve * 8
                let structuralReserve = CompletionReserve.estimate(
                    schemaJSON: grammarSchema,
                    tokenizer: context.tokenizer
                )
                let completionReserve = Swift.max(structuralReserve * 3, maxTokens / 4)
                let hardReserve = structuralReserve * 8

                // Extract KV quantization params from typed config for GuidedGenerationLoop
                // (which still consumes legacy scalar kvBits/kvGroupSize/quantizedKVStart).
                let guidedKVParams = extractKVQuantizationParams(from: genParams.kvCache)

                do {
                    diagnosticResult = try GuidedGenerationDiagnosticSink.$current.withValue(
                        diagnosticSink
                    ) {
                        // Run GuidedGenerationLoop with emit callback → SSE yield
                        // Bias parameters: completionReserve + hardReserve provide soft/hard
                        // closing zones so JSON output gracefully terminates instead of
                        // running out of tokens mid-structure.
                        let tokenCount = try GuidedGenerationLoop.run(
                            input: lmInput,
                            context: context,
                            constraint: constraint,
                            maxTokens: maxTokens,
                            vocabSize: Int(loaded.modelConfig.vocabSize),
                            kvBits: guidedKVParams.bits,
                            kvGroupSize: guidedKVParams.groupSize,
                            quantizedKVStart: guidedKVParams.compressionStart,
                            completionReserve: completionReserve,
                            hardReserve: hardReserve,
                            closingBias: closingBias,
                            whitespaceBias: whitespaceBias,
                            whitespaceTokenIDs: whitespaceTokenIDs,
                            diagnosticLog: false,
                        ) { text in
                            guard !Task.isCancelled && !cancellation.isCancelled else {
                                doneAlreadyYielded = true
                                let tokPerSec =
                                    guidedTokenCount > 0
                                    ? Double(guidedTokenCount)
                                        / (Double(metrics.overallMs) / 1000.0)
                                    : nil
                                continuation.yield(
                                    .init(
                                        kind: .done(
                                            StopReason.cancelled,
                                            tokenCount: guidedTokenCount,
                                            tokPerSec: tokPerSec,
                                            promptTokPerSec: nil,
                                            reasoningTokenCount: 0)))
                                return false
                            }
                            // Record TTFT on first text chunk
                            if !firstYielded {
                                metrics.firstTokenMs = metrics.overallMs
                                firstYielded = true
                            }
                            metrics.incrementGenerated()
                            guidedTokenCount += 1
                            guidedAccumulated += text
                            // Check stop sequences in guided path
                            if let match = requestStopSequences.first(where: {
                                guidedAccumulated.hasSuffix($0)
                            }) {
                                doneAlreadyYielded = true
                                let trimmed = String(
                                    guidedAccumulated.prefix(guidedAccumulated.count - match.count))
                                if !trimmed.isEmpty {
                                    continuation.yield(.init(kind: .text(trimmed)))
                                }
                                let tokPerSec =
                                    guidedTokenCount > 0
                                    ? Double(guidedTokenCount)
                                        / (Double(metrics.overallMs) / 1000.0)
                                    : nil
                                continuation.yield(
                                    .init(
                                        kind: .done(
                                            StopReason.stopSequence,
                                            tokenCount: guidedTokenCount,
                                            tokPerSec: tokPerSec,
                                            promptTokPerSec: nil,
                                            reasoningTokenCount: 0)))
                                return false
                            }
                            continuation.yield(.init(kind: .text(text)))
                            return true
                        }
                        // Snapshot diagnostics after loop completes
                        return .success(tokenCount: tokenCount, sink: diagnosticSink)
                    }

                    // Complete guided generation
                    if !Task.isCancelled && !cancellation.isCancelled || doneAlreadyYielded {
                        switch diagnosticResult {
                        case .success(let tc, _):
                            logGuidedGen(
                                log,
                                modelId: modelId,
                                grammarTerminated: diagnosticSink.grammarTerminated,
                                tokenCount: tc,
                                sampledTokens: diagnosticSink.sampledTokenIDs.count,
                                fastForwardTokens: diagnosticSink.fastForwardTokenIDs.count,
                                incomplete: diagnosticSink.incompleteOutput,
                                finalBufferPresent: diagnosticSink.finalBuffer != nil,
                                parsedAsToolCall: diagnosticSink.parsedAsToolCall,
                                parsedName: diagnosticSink.parsedName)
                            // P1-fix: respect grammar lifecycle — upstream GuidedGenerationLoop.run()
                            // only calls grammar-terminated when the constraint accepted the output.
                            // When grammar didn't terminate (maxTokens exhausted), reporting .eos
                            // misleads downstream (structured parsing, UI, metrics).
                            if !doneAlreadyYielded {
                                // Emit structured guided gen diagnostic before .done —
                                // carries grammarTerminated + incompleteOutput so downstream
                                // (UI, structured parsers) can react to grammar lifecycle state.
                                continuation.yield(
                                    .init(
                                        kind: .guidedGenDiagnostic(
                                            grammarTerminated: diagnosticSink.grammarTerminated,
                                            incompleteOutput: diagnosticSink.incompleteOutput)))
                                let stopReason: StopReason =
                                    diagnosticSink.grammarTerminated
                                    ? .eos : .maxTokens
                                let tokPerSec =
                                    tc > 0
                                    ? Double(tc) / (Double(metrics.overallMs) / 1000.0)
                                    : nil
                                continuation.yield(
                                    .init(
                                        kind: .done(
                                            stopReason,
                                            tokenCount: tc,
                                            tokPerSec: tokPerSec,
                                            promptTokPerSec: nil,
                                            reasoningTokenCount: 0)))
                            }
                        }
                    }
                } catch {
                    // Log diagnostic data even on failure — grammar/schema mismatch
                    // is one of the hardest-to-debug guided gen issues.
                    logGuidedGenError(
                        log,
                        modelId: modelId,
                        error: error,
                        grammarTerminated: diagnosticSink.grammarTerminated,
                        tokenCountBeforeFailure: diagnosticSink.generatedTokenCount,
                        sampledTokens: diagnosticSink.sampledTokenIDs.count,
                        fastForwardTokens: diagnosticSink.fastForwardTokenIDs.count,
                        incomplete: diagnosticSink.incompleteOutput,
                        finalBuffer: diagnosticSink.finalBuffer)
                    // P1-fix: emit .done before throwing — prevents continuation leak.
                    // The outer do-catch (L1259/1283) will propagate the error as
                    // .error event, but downstream also expects a terminal .done.
                    if !doneAlreadyYielded {
                        let tokPerSec =
                            diagnosticSink.generatedTokenCount > 0
                            ? Double(diagnosticSink.generatedTokenCount)
                                / (Double(metrics.overallMs) / 1000.0)
                            : nil
                        continuation.yield(
                            .init(
                                kind: .done(
                                    .error,
                                    tokenCount: diagnosticSink.generatedTokenCount,
                                    tokPerSec: tokPerSec,
                                    promptTokPerSec: nil,
                                    reasoningTokenCount: 0)))
                    }
                    throw error
                }
            }
        }

        // P1-fix: extract stop-sequence matching into shared helper.
        // Previously duplicated 5× inside runInferenceBody (MTP reasoning/response,
        // MTP no-reasoning, standard reasoning/response, standard no-reasoning).
        // Returns (shouldBreak: Bool, updatedAccumulated: String).
        // `segment` = current chunk to yield on normal path.
        // `accumulated` = running text checked for stop-sequence suffix.
        // Extra .done fields (promptTokPerSec, reasoningTokenCount, draft metrics) propagated
        // with nil defaults so callers that don't track them still compile.
        @Sendable func checkStopSequence(
            segment: String,
            accumulated: String,
            eventKind: @escaping @Sendable (String) -> InferenceEvent.Kind,
            tokenCount: Int?,
            tokenFallback: Int,
            promptTokPerSec: Double? = nil,
            reasoningTokenCount: Int? = nil
        ) -> (Bool, String) {
            if requestStopSequences.isEmpty {
                continuation.yield(.init(kind: eventKind(segment)))
                return (false, accumulated)
            }
            if let match = requestStopSequences.first(where: { accumulated.hasSuffix($0) }) {
                let trimmed = String(accumulated.prefix(accumulated.count - match.count))
                if !trimmed.isEmpty {
                    continuation.yield(.init(kind: eventKind(segment)))
                }
                let tc = tokenCount ?? tokenFallback
                let tokPerSec: Double? =
                    tc > 0 ? Double(tc) / (Double(metrics.overallMs) / 1000.0) : nil
                continuation.yield(
                    .init(
                        kind: .done(
                            StopReason.stopSequence,
                            tokenCount: tc,
                            tokPerSec: tokPerSec,
                            promptTokPerSec: promptTokPerSec,
                            reasoningTokenCount: reasoningTokenCount)))
                return (true, accumulated)
            }
            continuation.yield(.init(kind: eventKind(segment)))
            return (false, accumulated)
        }

        // runInferenceBody: session acquisition → generation → pool release
        /// When useGuidedGeneration is true, routes through GuidedGenerationLoop
        /// for grammar-constrained output (tool calls, JSON schema).
        /// Otherwise uses upstream ChatSession.streamDetails for standard generation.
        ///
        /// Bridge: when tools are registered, we pass them to ChatSession along with
        /// a toolDispatch closure that routes ToolCall → ToolRegistry.call() and back.
        /// This activates the ChatSession's built-in tool-dispatch agent loop (L748 restart)
        /// instead of relying solely on the local AgentLoop coordinator.
        func runInferenceBody(wiredMemoryTicket: MLX.WiredMemoryTicket?) async throws {
            // P-S2: Fetch perception context via MainActor to bridge @MainActor
            // PerceptionEngine into the nonisolated inference body.
            // String result is trivially Sendable — safe to capture in @Sendable closures.
            @Sendable
            func fetchPerceptionContext() async -> String {
                await MainActor.run {
                    PerceptionEngine.shared.contextText()
                }
            }
            let convKey: String = conversationId ?? "\(modelId):ephemeral"
            var chatSession: ChatSession?
            /// Full pooled session wrapper (carries message history for prefix matching).
            /// Used by releasePoolSlot to return the session with its history intact.
            var pooledSession: PooledChatSession?
            /// Collected assistant text from Standard reasoning/ChatSession path.
            /// Used to build MessageHistoryKey for pool message history before final release.
            var stdAccumulated: String?
            var registeredToolSpecs: [ToolSpec]?

            // Bridge ToolRegistry → ChatSession tools + toolDispatch
            // Upstream ToolCallingModeResolution.resolve("disallowed") →
            // enabledToolDefinitions = [] → !isEmpty check fails → skip tool path.
            // We must honor the same contract: when user explicitly sets "disallowed",
            // treat the tool table as empty regardless of what ToolRegistry provides.
            if let registry = toolRegistry {
                let specs = await registry.toToolSpecs()
                if !specs.isEmpty,
                    options.toolCallingMode?.lowercased() != "disallowed"
                {
                    registeredToolSpecs = specs
                }
            }

            // MARK: - macOS 27: LanguageModelSession bridge
            // LanguageModelSession → Executor.respond() → ToolCallingModeResolution
            // + Think-then-Call + AllowedToolOutputRouter + CompletionReserve
            // All activated by passing full tools/transcript/context options.
            #if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
            if #available(macOS 27.0, iOS 27.0, *), let mlxLM = loaded.mlxLanguageModel {
                log.info("Using LanguageModelSession (macOS 27 SDK path)")

                // Observe: FM path declares .reasoning for all models (generic runtime).
                // Executor.respond() requires BOTH declaresReasoning AND
                // resolved.reasoningConfig; when reasoningConfig is nil the pipeline
                // naturally falls through to standard generation. Log the state so
                // debugging matches between declares and actual factory-injected config.
                let hasReasoningConfig =
                    (await handleRef.modelContainer.configuration.reasoningConfig) != nil
                log.debug(
                    "FM path reasoning capability: declared=true, factory_injected=\(hasReasoningConfig)"
                )

                // --- Build FM Tool array from ToolRegistry ---
                // tools: [] is the #1 degradation vector — it short-circuits
                // Executor.respond()'s entire tool-calling pipeline.
                var fmTools: [any FoundationModels.Tool]? = nil
                if let registry = toolRegistry {
                    let specs = await registry.toToolSpecs()
                    if !specs.isEmpty {
                        let fmToolsArray = FMToolProxy.tools(
                            from: registry, toolSpecs: specs, log: log)
                        fmTools = fmToolsArray
                        log.info("Injected \(fmToolsArray.count) tools into FM session")
                    }
                }

                // --- Build transcript with full conversation history ---
                // Previously only last user message text was passed. Now we
                // send system instructions + full message pairs + tool definitions
                // so Executor.respond() has correct KV cache context.
                let sdkInstructions: String? =
                    (systemInstructions?.isEmpty == false)
                    ? systemInstructions
                    : nil
                let transcript = FMTranscriptHelpers.build(
                    systemInstructions: sdkInstructions,
                    messages: mlxMessages,
                    tools: fmTools
                )

                // Create session with tools + transcript (not just instructions)
                let langSession = LanguageModelSession(
                    model: mlxLM,
                    tools: fmTools ?? [],
                    transcript: transcript
                )

                // --- GenerationOptions: sampling params ---
                // SDK SamplingMode factory methods (static, not init):
                //   .greedy, .random(topK:seed:), .random(probabilityThreshold:seed:)
                let samplingMode: GenerationOptions.SamplingMode? =
                    if sampling.mode == .greedy {
                        .greedy
                    } else if let topK = sampling.topK, sampling.mode != .default {
                        .random(top: topK, seed: sampling.seed.map { UInt64($0) })
                    } else if let topP = sampling.topP, sampling.mode != .default {
                        .random(probabilityThreshold: topP, seed: sampling.seed.map { UInt64($0) })
                    } else {
                        nil
                    }
                // P1-fix: toolCalling mode must match actual tool state.
                // Using .allowed when no tools exist causes FM SDK to inject tool-calling
                // template markers into the prompt — triggering spurious tool responses
                // from models that don't actually know tools. Use .disallowed when empty.
                // Upstream ToolCallingModeResolution supports .allowed / .required / .disallowed.
                // .required enables think-then-call reasoning phase before tool dispatch.
                let tcMode: FoundationModels.GenerationOptions.ToolCallingMode
                if fmTools?.isEmpty == false {
                    // Tools available — resolve mode from explicit option or default to .allowed
                    switch options.toolCallingMode?.lowercased() {
                    case "required":
                        tcMode = .required
                    case "disallowed":
                        tcMode = .disallowed
                    default:
                        tcMode = .allowed
                    }
                } else {
                    // No tools — force .disallowed regardless of user preference
                    tcMode = .disallowed
                }
                let genOpts: GenerationOptions = GenerationOptions(
                    samplingMode: samplingMode,
                    temperature: sampling.temperature,
                    maximumResponseTokens: options.maxTokens,
                    toolCallingMode: tcMode
                )

                // --- ContextOptions: reasoning level ---
                // SDK ReasoningLevel: .light, .moderate, .deep, .custom(String)
                // Upstream Executor.respond() routing: thinkingEnabled() maps
                // .light/.moderate/.deep → true; .custom("no_think") → false.
                // When user provides explicit reasoningLevel, honor it.
                // When only boolean reasoning toggle, default to .deep.
                let ctxOpts: ContextOptions
                if let levelStr = options.reasoningLevel {
                    switch levelStr.lowercased() {
                    case "light":
                        ctxOpts = ContextOptions(reasoningLevel: .light)
                        log.info("Reasoning level: .light")
                    case "moderate":
                        ctxOpts = ContextOptions(reasoningLevel: .moderate)
                        log.info("Reasoning level: .moderate")
                    case "deep":
                        ctxOpts = ContextOptions(reasoningLevel: .deep)
                        log.info("Reasoning level: .deep")
                    default:
                        if options.enableReasoning {
                            ctxOpts = ContextOptions(reasoningLevel: .deep)
                        } else {
                            ctxOpts = ContextOptions()
                        }
                    }
                } else if options.enableReasoning {
                    // Legacy boolean path — defaults to .deep for alignment
                    ctxOpts = ContextOptions(reasoningLevel: .deep)
                    log.info("Reasoning enabled via ContextOptions.reasoningLevel=.deep")
                } else {
                    ctxOpts = ContextOptions()
                }

                // --- Guided generation: when grammarSchema is present,
                // use FM's schema-constrained streamResponse overload.
                // ResponseStream<GeneratedContent> yields GeneratedContent which
                // conforms to ConvertibleFromGeneratedContent — use String.init
                // to extract text from the schema-validated output.
                let fmGuidedSchema: FoundationModels.GenerationSchema? =
                    if let schemaJSON = options.grammarSchema,
                        let data = schemaJSON.data(using: .utf8),
                        let gs = try? JSONDecoder().decode(
                            FoundationModels.GenerationSchema.self, from: data
                        )
                    {
                        gs
                    } else {
                        nil
                    }

                /* P1-fix: use actual user prompt text instead of empty string.
                   streamResponse(to:) forwards to Executor.respond() which calls
                   TranscriptConverter.mlxMessages(). When the transcript contains
                   only instructions + empty response pairs (no prompt entry),
                   mlxMessages returns [] and upstream crashes at L943 with
                   "Cannot respond with empty messages". Extract the last user
                   message from mlxMessages to provide the actual input. */
                let fmPromptText = FMTranscriptHelpers.lastUserPromptText(
                    from: mlxMessages as [MLXLMCommon.Chat.Message])

                do {
                    var fmStopReason: StopReason = .stopSequence
                    // P1-fix: Reasoning routing + stop sequence for FM path.
                    // Both guided and regular branches previously emitted .text only,
                    // bypassing ReasoningEventEmitter (no reasoning segmentation) and
                    // not checking requestStopSequences. Wire same patterns as MTP/standard.
                    let fmReasoningConfig = await handleRef.modelContainer.configuration
                        .reasoningConfig
                    var fmEmitter: ReasoningEventEmitter?
                    if let rc = fmReasoningConfig {
                        let primed =
                            switch rc.promptStrategy {
                            case .alwaysOn: true
                            case .templateFlag(_, let defaultOn): defaultOn
                            case .none: false
                            }
                        fmEmitter = ReasoningEventEmitter(config: rc, primedInside: primed)
                    }
                    var fmAccumulated = ""
                    // Note: streamResponse returns text chunks, not token events —
                    // FM SDK provides no per-token callback, so tokenCount is nil
                    // (same as tokPerSec/promptTokPerSec for FM path).

                    if let guidedSchema = fmGuidedSchema {
                        log.info("FM path: guided generation with schema constraints")
                        for try await gc in langSession.streamResponse(
                            to: fmPromptText,
                            schema: guidedSchema,
                            options: genOpts,
                            contextOptions: ctxOpts
                        ) {
                            if Task.isCancelled || cancellation.isCancelled {
                                fmStopReason = .cancelled
                                break
                            }
                            // Snapshot.rawContent is GeneratedContent. Extract text via
                            // ConvertibleFromGeneratedContent — disambiguate by typing
                            // the parameter so the compiler doesn't pick
                            // RangeReplaceableCollection.init.
                            let text = (try? String(gc.rawContent)) ?? ""
                            if !text.isEmpty {
                                // Route through reasoning emitter when available,
                                // then check stop sequences (same as MTP/standard path).
                                if let e = fmEmitter {
                                    var emitter = e
                                    for segment in emitter.process(text) {
                                        switch segment {
                                        case .reasoning(let segText):
                                            fmAccumulated += segText
                                            if checkStopSequence(
                                                segment: segText,
                                                accumulated: fmAccumulated,
                                                eventKind: { .reasoning($0) },
                                                tokenCount: nil,
                                                tokenFallback: 0
                                            ).0 {
                                                fmStopReason = .stopSequence
                                                break
                                            }
                                        case .response(let segText):
                                            fmAccumulated += segText
                                            if checkStopSequence(
                                                segment: segText,
                                                accumulated: fmAccumulated,
                                                eventKind: { .text($0) },
                                                tokenCount: nil,
                                                tokenFallback: 0
                                            ).0 {
                                                fmStopReason = .stopSequence
                                                break
                                            }
                                        }
                                    }
                                } else {
                                    // No reasoning config — stop sequence check on plain text
                                    fmAccumulated += text
                                    if checkStopSequence(
                                        segment: text,
                                        accumulated: fmAccumulated,
                                        eventKind: { .text($0) },
                                        tokenCount: nil,
                                        tokenFallback: 0
                                    ).0 {
                                        fmStopReason = .stopSequence
                                        break
                                    }
                                }
                            }
                        }
                        fmStopReason = fmStopReason == .stopSequence ? .eos : fmStopReason
                    } else {
                        for try await partial in langSession.streamResponse(
                            to: fmPromptText,
                            options: genOpts,
                            contextOptions: ctxOpts
                        ) {
                            if Task.isCancelled || cancellation.isCancelled {
                                fmStopReason = .cancelled
                                break
                            }
                            if !partial.content.isEmpty {
                                // Route through reasoning emitter when available,
                                // then check stop sequences (same as MTP/standard path).
                                if let e = fmEmitter {
                                    var emitter = e
                                    for segment in emitter.process(partial.content) {
                                        switch segment {
                                        case .reasoning(let segText):
                                            fmAccumulated += segText
                                            if checkStopSequence(
                                                segment: segText,
                                                accumulated: fmAccumulated,
                                                eventKind: { .reasoning($0) },
                                                tokenCount: nil,
                                                tokenFallback: 0
                                            ).0 {
                                                fmStopReason = .stopSequence
                                                break
                                            }
                                        case .response(let segText):
                                            fmAccumulated += segText
                                            if checkStopSequence(
                                                segment: segText,
                                                accumulated: fmAccumulated,
                                                eventKind: { .text($0) },
                                                tokenCount: nil,
                                                tokenFallback: 0
                                            ).0 {
                                                fmStopReason = .stopSequence
                                                break
                                            }
                                        }
                                    }
                                } else {
                                    // No reasoning config — stop sequence check on plain text
                                    fmAccumulated += partial.content
                                    if checkStopSequence(
                                        segment: partial.content,
                                        accumulated: fmAccumulated,
                                        eventKind: { .text($0) },
                                        tokenCount: nil,
                                        tokenFallback: 0
                                    ).0 {
                                        fmStopReason = .stopSequence
                                        break
                                    }
                                }
                            }
                        }
                    }

                    continuation.yield(
                        .init(
                            kind: .done(
                                fmStopReason,
                                tokenCount: nil,
                                tokPerSec: nil,
                                promptTokPerSec: nil
                            )
                        ))
                    continuation.finish()
                    return
                } catch {
                    log.error("LanguageModelSession error: \(error.localizedDescription)")
                    continuation.yield(.init(kind: .error(error.localizedDescription)))
                    continuation.finish()
                    return
                }
            }
            #endif

            // Unified processing config for VLM resize — consistent across all
            // inference paths (ChatSession, Guided gen, MTP). Value read from config
            // so users can tune per-image token overhead.
            let sessionProcessing = MLXLMCommon.UserInput.Processing(
                resize: config.vlmImageResize
            )

            // ChatSession path: acquire or create session
            // Always create chatSession — guided path (grammarSchema) and MTP/standard path
            // all consume the shared chatSession variable below. Even when useGuidedGeneration
            // is true, the guided path may fall through (e.g., multimodal + grammar conflict)
            // and still need a valid session.
            // Hoist registry ref before closure — ToolRegistry is an actor, capture is safe
            // Tool dispatch via ChatSession's built-in restart loop (ChatSession.swift L1208).
            // When toolDispatch != nil, ChatSession collects .toolCall events internally,
            // executes them, and appends tool results as pending messages that trigger
            // another generation pass — all inside ChatSession.streamMap().
            //
            // Real-time .toolCall events:
            // - MTP path (L2437): direct event yield per iteration
            // - Std non-reasoning path (L2938): streamDetails emits .toolCall
            // - Std reasoning path: No tool calls (tools → mayRunReasoning == false)
            //
            // Double-serialization fix: removed tracker.post-hoc record + JSON roundtrip.
            // ChatSession.toolDispatch closure now calls registry directly — no intermediate
            // actor, no JSON encode/decode of MLXLMCommon.JSONValue.
            var toolDispatchClosure: (@Sendable (MLXLMCommon.ToolCall) async throws -> String)? =
                nil
            if let registry = toolRegistry {
                // Double-serialization fix: removed tracker record + JSON roundtrip.
                // Previously: MLXLMCommon.JSONValue → JSONSerialization → String → registry.call().
                // Now: MLXLMCommon.JSONValue → direct registry.call() via .anyValue.
                toolDispatchClosure = { [registry, logger = self.logger] toolCall in
                    // MLXLMCommon.ToolCall carries JSONValue args that need JSON-string
                    // serialization for ToolRegistry.call(arguments: String).
                    // Previously this went through _InterceptedToolCallTracker (JSON roundtrip)
                    // which added post-hoc delay; now direct inline serialization.
                    let argsDict =
                        toolCall.function.arguments
                        .mapValues { $0.anyValue } as? [String: Any] ?? [:]

                    // P0-fix: replace fatalError with graceful error response
                    // (tool args should always serialize, but release must not crash)
                    guard
                        let data = try? JSONSerialization.data(
                            withJSONObject: argsDict,
                            options: []
                        ),
                        let jsonArgs = String(data: data, encoding: .utf8)
                    else {
                        logger.error(
                            "Tool dispatch: args serialization failed for \\(toolCall.function.name)"
                        )
                        return
                            "[tool_dispatch_error: could not serialize arguments for \\(toolCall.function.name)]"
                    }

                    let toolResult = try await registry.call(
                        toolCall.function.name,
                        arguments: jsonArgs,
                        caller: "mlx_engine"
                    )
                    // P-S2: Append fresh perception context to tool result so the model
                    // sees updated environment state on each tool dispatch iteration.
                    // Uses MainActor.run to bridge @MainActor PerceptionEngine boundary.
                    let freshContext = await fetchPerceptionContext()
                    if !freshContext.isEmpty {
                        return toolResult + "\n" + freshContext
                    }
                    return toolResult
                }
            }

            // Upstream Executor.respond() gates reasoning behind mayRunReasoningPath:
            //   mayRunReasoningPath = enabledToolDefinitions.isEmpty && request.schema == nil
            // When tools or grammar schema are present, the constrained/tool path handles
            // thinking internally — injecting reasoningContext there would double-inject
            // thinking kwargs into an already tool-aware template.
            let mayRunReasoning =
                (registeredToolSpecs ?? []).isEmpty && options.grammarSchema == nil

            // Snapshot reasoningConfig once here (replaces the second actor hop at L1807
            // which repeated the same .configuration.reasoningConfig lookup).
            let reasoningConfig = await handleRef.modelContainer.configuration.reasoningConfig

            var baseReasoningContext: [String: any Sendable]?
            if mayRunReasoning,
                let rc = reasoningConfig
            {
                // Mirror upstream thinkingEnabled(for:) reasoning level resolution:
                //   reasoningLevel set → parse to Bool?
                //   reasoningLevel nil → pass nil (promptStrategy fallback to defaultOn)
                // Upstream L1329-1349 (FM path) does the same for chat session.
                let thinkingEnabled: Bool? = {
                    if let level = options.reasoningLevel?.lowercased() {
                        switch level {
                        case "light", "moderate", "deep":
                            return true
                        default:
                            // .custom("no_think") or unknown → interpret via enableReasoning flag
                            return options.enableReasoning ? true : false
                        }
                    }
                    // User didn't specify reasoning level — let promptStrategy use defaultOn
                    return nil
                }()
                do {
                    baseReasoningContext = try rc.promptStrategy.additionalContext(
                        forThinkingEnabled: thinkingEnabled
                    )
                } catch {
                    if let err = error as? MLXLMCommon.ReasoningError,
                        err == .cannotDisableReasoning
                    {
                        log.warning(
                            "Model \(modelId) cannot disable reasoning — ignoring user request"
                        )
                    }
                    baseReasoningContext = nil
                }
            } else if !mayRunReasoning,
                reasoningConfig != nil
            {
                log.info(
                    "Reasoning suppressed — tools or grammar schema present (mayRunReasoningPath)")
                baseReasoningContext = nil
            } else {
                baseReasoningContext = nil
            }
            // Wire-not-brain reasoning effort (08-23): inject the caller's raw
            // value into the jinja chat-template context. The model template
            // reads it only with thinking enabled and validates it itself
            // (Qwen3.8 raise_exception). No local mapping — the word table is
            // codex-aligned; unsupported values are the model's to reject.
            let reasoningContext: [String: any Sendable]? =
                ReasoningEffortWire.context(baseReasoningContext, rawValue: options.reasoningEffort)

            // Track which messages to feed to ChatSession. ChatSession accumulates
            // KV cache internally — on pool hits we only feed the suffix starting at
            // divergenceIndex, on pool miss / no pool we feed the full history.
            var newMessages: [Chat.Message]
            var divergenceIndex: Int = 0
            // Keep pool reference in scope beyond the if-let block so guided gen / MTP /
            // std reasoning paths (below) can return the slot early when they can't
            // reuse ChatSession's private cache.
            let poolRefForRelease = poolRef
            _ = poolRefForRelease  // used below in guided gen / MTP / std reasoning early-release

            if let pool = poolRef {
                let keys = mlxMessages.map(MessageHistoryKey.from)
                let acquired = await pool.acquire(
                    from: handleRef.modelContainer,
                    modelId: modelId,
                    conversationId: convKey,
                    genParams: genParams,
                    speculativeDecoding: specConfig,
                    instructions: systemInstructions,
                    processing: sessionProcessing,
                    prefixMessages: keys
                )
                chatSession = acquired.pooled.session
                pooledSession = acquired.pooled
                divergenceIndex = acquired.divergenceIndex
                // Pool slot is released at end of inference body (below).
                // Early-release paths (guided gen / MTP / std on pool hit) release
                // via poolRefForRelease and nil out chatSession to prevent double release.
                if divergenceIndex > 0 {
                    log.debug(
                        "Pool reuse for \(convKey) — divergence at \(divergenceIndex)/\(mlxMessages.count),"
                    )
                    log.debug(
                        "Passing \(mlxMessages.count - divergenceIndex) message(s) — skipping cached prefix"
                    )
                    // Cached prefix covers messages[..<divergenceIndex]; only feed the suffix.
                    newMessages = Array(mlxMessages[divergenceIndex...])
                } else {
                    // Pool hit but no prefix match (e.g. system instructions changed)
                    // or cold miss / pool miss. Pass full history including system
                    // instructions so processor.prepare() can prefill the complete context.
                    newMessages = mlxMessages
                }
                chatSession?.additionalContext = reasoningContext
                chatSession?.tools = registeredToolSpecs
                chatSession?.toolDispatch = toolDispatchClosure
            } else {
                // No pool — always cold start
                newMessages = mlxMessages
                let spec: MLXLMCommon.SpeculativeDecodingConfig? = specConfig
                let gp: MLXLMCommon.GenerateParameters = genParams
                /// ChatSession creation — reasoning context injected via
                /// reasoningConfig.promptStrategy.additionalContext().
                /// Upstream reasoningConfig already has the prompt strategy baked in via
                /// LLMModelFactory._load. The ReasoningEventEmitter below parses
                /// model-rendered thinking tags (ReasoningConfig.swift:106-124).
                ///
                /// components: custom logitProcessorFactory for grammar-constrained
                /// decoding (unused here — guided path uses GuidedGenerationLoop).
                /// Penalty enforcement is automatic via
                /// GenerateParameters.processor(), independent of components.
                chatSession = ChatSession(
                    handleRef.modelContainer,
                    instructions: systemInstructions,
                    speculativeDecoding: spec,
                    generateParameters: gp,
                    components: .init(),
                    processing: sessionProcessing,
                    additionalContext: reasoningContext,
                    tools: registeredToolSpecs,
                    toolDispatch: toolDispatchClosure
                )
            }

            // releasePoolSlot: RAII helper to release the pooled ChatSession
            // and nil it out. Safe to call multiple times — pooledSession == nil
            // on subsequent calls (no-op). Used by all inference paths including
            // the catch handler to guarantee pool slot is never leaked.
            // Swift 6 strict concurrency: clear locals BEFORE await to avoid
            // "sending 'chatSession' risks causing data races". Captured `pooled`
            // stays alive for the release call.
            func releasePoolSlot() async {
                if let pool = poolRefForRelease,
                    let pooled = pooledSession
                {
                    pooledSession = nil
                    chatSession = nil
                    await pool.release(
                        pooled: pooled,
                        modelId: modelId,
                        conversationId: convKey,
                        assistantMessage: nil
                    )
                }
            }

            // Override: release pool slot with the assistant response for message
            // history extension. Called only after standard path completes.
            // Same Swift 6 pattern: clear locals before await.
            func releasePoolSlotWithAssistant(_ historyKey: MessageHistoryKey?) async {
                if let pool = poolRefForRelease,
                    let pooled = pooledSession
                {
                    pooledSession = nil
                    chatSession = nil
                    await pool.release(
                        pooled: pooled,
                        modelId: modelId,
                        conversationId: convKey,
                        assistantMessage: historyKey
                    )
                }
            }

            do {
                // State for Guided/MTP branches — standard ChatSession manages its own
                var actualTokenCount: Int?
                var generationTokPerSec: Double?
                var promptTokPerSec: Double?
                var lastStopReason: StopReason?
                // MTP speculative decoding metrics — thread from MTPResult to .done
                var mtpProposedDraftTokens: Int?
                var mtpAcceptedDraftTokens: Int?
                var mtpPassthroughReason: String?

                // MARK: - Guided Generation Path (grammar-constrained)
                // NOTE: Guided path uses pure-text messagePairs — cannot carry images/videos/audios.
                // Multimodal messages with grammar schema fall through to ChatSession (full round-trip).
                // Reasoning models fall through to ChatSession (Guided lacks ReasoningEventEmitter).
                // This mirrors upstream MTP path at L925 and aligns with MLXChatExample pattern
                // where Chat.Message carries images/videos directly without loss.
                // Compute effective maxTokens for guided gen: if user didn't specify one,
                // provide a reasonable default so guided gen isn't skipped unnecessarily.
                let effectiveMaxTokens = options.maxTokens ?? 2048

                if let schema = options.grammarSchema,
                    Self.reasoningSafeForConstrainedPaths(
                        await handleRef.modelContainer.configuration),
                    mlxMessages.allSatisfy({
                        $0.images.isEmpty && $0.videos.isEmpty && $0.audios.isEmpty
                    })
                {
                    // Guided gen creates its own KV cache scope inside GuidedGenerationLoop,
                    // so it can't reuse ChatSession's cache (private, only visible to ChatSession).
                    // Return the pooled slot before inference to avoid leaking; guided gen
                    // will cold-start with full message history.
                    if chatSession != nil {
                        log.debug(
                            "Pooled session acquired but guided gen can't reuse ChatSession cache — returning slot"
                        )
                        // Swift 6: clear refs before await to avoid data-race on chatSession
                        if let pool = poolRefForRelease, let pooled = pooledSession {
                            pooledSession = nil
                            chatSession = nil
                            await pool.release(
                                pooled: pooled,
                                modelId: modelId,
                                conversationId: convKey,
                                assistantMessage: nil
                            )
                        }
                    }
                    log.info("Routing through GuidedGenerationLoop with grammar constraint")
                    try await handleGuidedGeneration(
                        messagePairs: mlxMessages.map {
                            (role: $0.role.rawValue, content: $0.content)
                        },
                        grammarSchema: schema,
                        maxTokens: effectiveMaxTokens,
                    )
                } else if options.grammarSchema != nil {
                    // Grammar requested but multimodal content present — guided path cannot handle it.
                    // Fall through to ChatSession below; grammar will be best-effort ignored.
                    log.warning(
                        "Dropping grammar constraint for multimodal message on model \(modelId)")
                }
                // MARK: - MTP Speculative Decoding Path
                // MTP tool dispatch loop: .toolCall detected → dispatch via toolDispatchClosure
                // → collect results → append tool/response messages → re-generate.
                // Mirrors ChatSession.swift L748 restart loop.
                // VLM requests fall through to ChatSession (MTP cannot carry images/videos/audios).
                else if self.mtpDrafterContainer != nil, !mlxMessages.isEmpty,
                    mlxMessages.allSatisfy({
                        $0.images.isEmpty && $0.audios.isEmpty && $0.videos.isEmpty
                    })
                {
                    // MTP creates its own TokenIterator scope — can't reuse ChatSession's cache.
                    // Same pattern as guided gen: return the pooled slot.
                    if chatSession != nil {
                        log.debug(
                            "Pooled session acquired but MTP can't reuse ChatSession cache — returning slot"
                        )
                        // Swift 6: clear refs before await to avoid data-race on chatSession
                        if let pool = poolRefForRelease, let pooled = pooledSession {
                            pooledSession = nil
                            chatSession = nil
                            await pool.release(
                                pooled: pooled,
                                modelId: modelId,
                                conversationId: convKey,
                                assistantMessage: nil
                            )
                        }
                    }
                    log.info("Routing through MTP speculative decoding")
                    let messagePairs: [(role: String, content: String)] = mlxMessages.map {
                        (role: $0.role.rawValue, content: $0.content)
                    }

                    struct MTPResult: Sendable {
                        let accumulatedText: String
                        let tokenCount: Int?
                        let stopReason: StopReason?
                        let stoppedBySequence: Bool
                        let generationTokPerSec: Double?
                        let promptTokPerSec: Double?
                        let proposedDraftTokens: Int?
                        let acceptedDraftTokens: Int?
                        let passthroughReason: String?
                        let collectedToolCalls: [MLXLMCommon.ToolCall]
                    }

                    // SAFETY: mtpDrafterContainer is an actor; its contents could be
                    // released between the if-let guard (L1009) and this point via an
                    // await boundary. Hoist to a local optional and bail gracefully.
                    guard let drafterContainer = self.mtpDrafterContainer else {
                        log.warning(
                            "MTP drafter released during inference — falling back to ChatSession")
                        // RAII: release pool slot before early return (pool miss case).
                        // Pool hit case already early-released and niled chatSession at L2073.
                        await releasePoolSlot()
                        return
                    }
                    let drafterWrapper: MTPDrafterModelWrapper
                    drafterWrapper = await drafterContainer.perform { drafterCtx in
                        MTPDrafterModelWrapper(model: drafterCtx.model)
                    }

                    // Snapshot toolDispatchClosure before entering nonSendable closure to avoid
                    // Swift 6 concurrency warning (var captured in concurrently-executing code).
                    let mtpToolDispatch = toolDispatchClosure

                    // Upstream ChatSession.respond() lock reduction:
                    // modelContainer.perform { } only wraps prepare() + generate() per iteration;
                    // the for-await stream consumption runs outside the lock (L1055).
                    // TokenIterator inside generate() accesses context.model,
                    // context.tokenizer, context.configuration — all immutable.
                    // P1-fix: thread wiredMemoryTicket through generate().

                    // Build initial messages outside lock
                    var mtpMessages: [Chat.Message] = messagePairs.map { pair in
                        Chat.Message(
                            role: Chat.Message.Role(rawValue: pair.role) ?? .system,
                            content: pair.content
                        )
                    }
                    // Strip trailing empty assistant message — mirrors upstream MLXChatExample
                    if let last = mtpMessages.last, last.role == .assistant, last.content.isEmpty {
                        mtpMessages.removeLast()
                    }

                    // MTP local state — scoped outside lock
                    var localAccumulatedText = ""
                    var localFirstToken = false
                    var localTokenCount: Int?
                    var localStopReason: StopReason?
                    var localGenerationTokPerSec: Double?
                    var localPromptTokPerSec: Double?
                    var localProposedDraftTokens: Int?
                    var localAcceptedDraftTokens: Int?
                    var localPassthroughReason: String?
                    var localStoppedBySeq = false

                    // P1-3: Think-then-call Phase 1 — upstream MLXLanguageModel.respond().
                    // Think-then-call is gated to the enable_thinking family (Qwen3/QwQ):
                    // their template renders the tool block AND honors `enable_thinking`.
                    // R1-style `.alwaysOn` models are tool-blind — they skip Phase 1.
                    let mtpReasoningConfig = await handleRef.modelContainer.configuration
                        .reasoningConfig
                    // Upstream: toolAwareContext ensures thinking key matches how
                    // generation is driven. For .templateFlag models with tools,
                    // this injects enable_thinking key: true into the prompt
                    // (mirrors upstream MLXLanguageModel.respond() L1178-1199).
                    // Without this, .templateFlag models in tool path would generate
                    // without thinking context — degenerate decode on first tokens.
                    // Upstream L1153-1154: think-then-call gated on thinkingEnabled != false.
                    // Upstream L1184-1188: enabled = declaresReasoning ? thinkingEnabled(for:level) ?? defaultOn : false
                    // MTP path: all models declare .reasoning (L444), so declaresReasoning ≡ true.
                    // Compute thinkingEnabled by honoring reasoningLevel (like FM path L1329-1349)
                    // and falling back to defaultOn when user provides no explicit signal.
                    let mtpThinkingEnabled: Bool
                    let mtpToolAwareContext: [String: any Sendable]?
                    if let rc = mtpReasoningConfig,
                        case .templateFlag(let key, let defaultOn) = rc.promptStrategy
                    {
                        // Resolve reasoning level → Bool? (same as FM path L1329-1349)
                        let resolved: Bool? = { () -> Bool? in
                            if let level = options.reasoningLevel?.lowercased() {
                                switch level {
                                case "light", "moderate", "deep":
                                    return true
                                default:
                                    // .custom("no_think") or unknown → interpret via enableReasoning fallback
                                    return options.enableReasoning ? true : false
                                }
                            }
                            return nil  // User didn't specify — fall through to defaultOn
                        }()
                        let enabled = resolved ?? defaultOn
                        mtpThinkingEnabled = enabled
                        mtpToolAwareContext = ReasoningEffortWire.context(
                            [key: enabled], rawValue: options.reasoningEffort)
                    } else {
                        // Non-templateFlag model (alwaysOn or none) — same as upstream L1191-1193
                        mtpThinkingEnabled = options.enableReasoning
                        mtpToolAwareContext = nil
                    }
                    /// Upstream L1149-1157: thinkThenCallConfig is computed for ALL tool paths
                    /// (.allowed AND .required) — no .required mode gate. Phase 1 thinking happens
                    /// whenever the model declares reasoning, has a templateFlag prompt strategy,
                    /// and thinking is not explicitly disabled. In .allowed mode the model freely
                    /// decides whether to reason during Phase 2 tool iterations.
                    // FIX B: Phase 1 thinking enabled for .allowed mode too (upstream alignment)
                    // Phase 1: think-then-call reasoning phase. Upstream does not require
                    // .required mode for this — it's gated on thinkThenCallConfig availability,
                    // which depends on mtpReasoningConfig + templateFlag + mtpThinkingEnabled.
                    var phase1ThinkingText: String?
                    var phase1ReasoningTokenCount: Int = 0  // Phase 1 reasoning token count
                    var phase2ReasoningTokenCount: Int = 0  // Phase 2 (tool loop) reasoning tokens
                    if let rc = mtpReasoningConfig,
                        mtpToolDispatch != nil,
                        case .templateFlag = rc.promptStrategy,
                        mtpThinkingEnabled
                    {
                        // Phase 1: all work inside perform{} to avoid Sendable boundary issues
                        do {
                            let phase1Pairs = mtpMessages.map { m -> (String, String) in
                                (m.role.rawValue, m.content)
                            }
                            let phase1Result:
                                (thinkingText: String, closed: Bool, tokenCount: Int) =
                                    try await handleRef.modelContainer.perform { context in
                                        let reasoningCtx = try? rc.promptStrategy.additionalContext(
                                            forThinkingEnabled: mtpThinkingEnabled ? true : nil
                                        )
                                        let rebuiltPhase1Messages = phase1Pairs.map { pair in
                                            Chat.Message(
                                                role: Chat.Message.Role(rawValue: pair.0)
                                                    ?? .system,
                                                content: pair.1
                                            )
                                        }
                                        let phase1Processing = UserInput.Processing(
                                            resize: config.vlmImageResize
                                        )
                                        let phase1UserInput = UserInput(
                                            prompt: .chat(rebuiltPhase1Messages),
                                            processing: phase1Processing,
                                            additionalContext: reasoningCtx
                                        )
                                        let phase1Input = try await context.processor.prepare(
                                            input: phase1UserInput
                                        )
                                        let tokens = phase1Input.text.tokens.asArray(Int32.self)
                                        let tailText = context.tokenizer.decode(
                                            tokenIds: tokens.suffix(64).map(Int.init)
                                        )
                                        let primedInside =
                                            ReasoningEventEmitter.promptEndsInsideReasoning(
                                                renderedPromptTail: tailText,
                                                config: rc
                                            )
                                        var collector = ReasoningTokenCollector(
                                            config: rc, primedInside: primedInside,
                                            tokenizer: context.tokenizer
                                        )
                                        var phase1ThinkingAccumulated = ""
                                        let (phase1Stream, phase1Task) =
                                            try MLXLMCommon.generateTokensTask(
                                                input: phase1Input,
                                                parameters: genParams,
                                                context: context,
                                                components: .init(),
                                                wiredMemoryTicket: wiredMemoryTicket
                                            )
                                        for await generation in phase1Stream {
                                            if Task.isCancelled || cancellation.isCancelled {
                                                phase1Task.cancel()
                                                _ = await phase1Task.value
                                                break
                                            }
                                            guard case .token(let token) = generation else {
                                                continue
                                            }
                                            for segment in collector.ingest(token) {
                                                switch segment {
                                                case .reasoning(let text):
                                                    phase1ThinkingAccumulated += text
                                                case .response:
                                                    // Response tokens in Phase 1 — ignore, they're noise
                                                    break
                                                }
                                            }
                                            if collector.shouldStopAfterReasoning {
                                                break
                                            }
                                        }
                                        // Drain task — Phase 1 done, Phase 2 will use fresh generation
                                        phase1Task.cancel()
                                        _ = await phase1Task.value
                                        Stream.gpu.synchronize()
                                        for segment in collector.finalize() {
                                            switch segment {
                                            case .reasoning(let text):
                                                phase1ThinkingAccumulated += text
                                            case .response:
                                                break
                                            }
                                        }
                                        return (
                                            phase1ThinkingAccumulated,
                                            collector.shouldStopAfterReasoning,
                                            collector.reasoningTokenIDs.count
                                        )
                                    }
                            // Emit Phase 1 thinking events
                            if phase1Result.closed, !phase1Result.thinkingText.isEmpty {
                                // Re-emit phase 1 thinking as reasoning events
                                continuation.yield(
                                    .init(kind: .reasoning(phase1Result.thinkingText)))
                                phase1ThinkingText = phase1Result.thinkingText
                                phase1ReasoningTokenCount = phase1Result.tokenCount
                                log.info(
                                    "Phase 1 think-then-call completed (\\(phase1Result.tokenCount) tokens)"
                                )
                            }
                        } catch {
                            log.warning(
                                "Phase 1 think-then-call failed: \\(error.localizedDescription)")
                        }
                    }  // end if let rc = mtpReasoningConfig
                    // Append Phase 1 thinking as assistant message before tool dispatch
                    if let thinkingText = phase1ThinkingText {
                        mtpMessages.append(
                            Chat.Message(
                                role: .assistant,
                                content: thinkingText
                            )
                        )
                    }
                    // Tool dispatch loop: iterates until model produces no more
                    // tool calls. Mirrors ChatSession.swift L748 restart-loop.
                    // P2-fix: hard iteration cap (10) prevents runaway tool loops
                    var mtpToolLoopCount = 0
                    let maxMtpToolLoop = 10
                    while mtpToolLoopCount < maxMtpToolLoop {
                        mtpToolLoopCount += 1
                        if Task.isCancelled || cancellation.isCancelled {
                            // Emit cancelled .done event — same as ChatSession path (L2528-2538).
                            // Without this, the caller never receives a terminal event.
                            let cancelTokPerSec =
                                (actualTokenCount ?? 0) > 0
                                ? Double(actualTokenCount ?? 0)
                                    / (Double(metrics.overallMs) / 1000.0)
                                : nil
                            continuation.yield(
                                .init(
                                    kind: .done(
                                        StopReason.cancelled,
                                        tokenCount: actualTokenCount ?? metrics.generatedTokenCount,
                                        tokPerSec: cancelTokPerSec,
                                        promptTokPerSec: localPromptTokPerSec,
                                        reasoningTokenCount: min(
                                            phase1ReasoningTokenCount + phase2ReasoningTokenCount,
                                            actualTokenCount ?? metrics.generatedTokenCount) > 0
                                            ? min(
                                                phase1ReasoningTokenCount
                                                    + phase2ReasoningTokenCount,
                                                actualTokenCount ?? metrics.generatedTokenCount)
                                            : nil,
                                        proposedDraftTokens: mtpProposedDraftTokens,
                                        acceptedDraftTokens: mtpAcceptedDraftTokens,
                                        passthroughReason: mtpPassthroughReason)))
                            break
                        }

                        // Reset per-iteration state
                        var iterationToolCalls: [MLXLMCommon.ToolCall] = []
                        var toolCallDetected = false

                        // Per-iteration streaming inside a fresh perform { } — this is the
                        // short-lived lock equivalent to upstream ChatSession.respond() pattern.
                        struct MTPIterationResult {
                            let stream: AsyncStream<MLXLMCommon.Generation>
                            let renderedTail: String
                        }
                        let iterResult: MTPIterationResult
                        // Snapshot messages as raw pairs — [Chat.Message] is non-Sendable.
                        // Convert to (role, content) pairs and reconstruct inside perform.
                        let iterationPairs = mtpMessages.map { m -> (String, String) in
                            (m.role.rawValue, m.content)
                        }
                        let snapMtpToolAwareContext = mtpToolAwareContext
                        // N1-fix: completionReserve floor on MTP phase2 per-iteration budget.
                        // Upstream MLXLanguageModel.respond() L1372-1376:
                        //   phase2MaxTokens = max(maxT - reasoningTokenIDs.count, completionReserve)
                        // where completionReserve = maxTokens / 4 (minimum floor).
                        // Without this, long reasoning spans can consume all tokens in early
                        // iterations, leaving zero budget for tool dispatch on later iterations.
                        let mtpReasoningTotal =
                            phase1ReasoningTokenCount + phase2ReasoningTokenCount
                        let mtpRemainingBudget = (options.maxTokens ?? .max) - mtpReasoningTotal
                        let mtpCompletionReserve = (options.maxTokens ?? .max) / 4
                        // Snapshot as let to satisfy Sendable closure capture rules —
                        // GenerateParameters is a struct, so a copy is cheap.
                        let iterGenParams: GenerateParameters = {
                            var params = genParams
                            params.maxTokens = Swift.max(mtpRemainingBudget, mtpCompletionReserve)
                            return params
                        }()

                        do {
                            iterResult = try await handleRef.modelContainer.perform(
                                nonSendable: drafterWrapper
                            ) { context, wrapped in
                                let drafterModel = wrapped.model
                                // P1-fix: ensure MTP KV cache exists (lazy init inside the
                                // perform lock so model reference is available).
                                // Conversation-aware: each dialog gets its own cache bucket.
                                try loaded.initializeMTPKVCacheIfNeeded(
                                    conversationId: convKey,
                                    model: context.model,
                                    parameters: genParams
                                )
                                // Reconstruct Chat.Message from Sendable pairs
                                let messages = iterationPairs.map { (role, content) in
                                    Chat.Message(
                                        role: Chat.Message.Role(rawValue: role) ?? .system,
                                        content: content)
                                }
                                let mtpProcessing = UserInput.Processing(
                                    resize: config.vlmImageResize)
                                let mtpUserInput = UserInput(
                                    prompt: .chat(messages),
                                    processing: mtpProcessing,
                                    additionalContext: snapMtpToolAwareContext ?? reasoningContext
                                )
                                let mtpInput = try await context.processor.prepare(
                                    input: mtpUserInput)
                                // P1-fix: thread wiredMemoryTicket through MTP generate().
                                // Upstream: generate(input:cache:parameters:context:mtpDrafter:blockSize:components:wiredMemoryTicket:)
                                // Evaluate.swift L2025
                                // P1-fix: thread cached MTP KV cache to avoid cold-start on each
                                // generation. KVCache objects are reference types — they hold
                                // pointers to GPU memory, so the array is cheap to pass and the
                                // objects are updated in-place by upstream during generation.
                                let mtpKVCache = loaded.mtpKVCache(conversationId: convKey)
                                let mtpGenStream = try MLXLMCommon.generate(
                                    input: mtpInput,
                                    cache: mtpKVCache,
                                    parameters: iterGenParams,
                                    context: context,
                                    mtpDrafter: drafterModel,
                                    // blockSize must be >= 2 (upstream precondition) and <= 16
                                    // (user-config via specDecoding.numDraftTokens). Upstream also
                                    // auto-clamps to narrowest sliding window at init time.
                                    blockSize: Swift.max(
                                        2, loaded.specDecodingConfig.numDraftTokens),
                                    components: .init(),
                                    wiredMemoryTicket: wiredMemoryTicket
                                )
                                // Capture primedInside for reasoning emitter — compute outside perform.
                                // LMInput not Sendable, so export token count + tokenizer ref.
                                let tokens = mtpInput.text.tokens.asArray(Int32.self)
                                let tail = context.tokenizer.decode(
                                    tokenIds: tokens.suffix(64).map(Int.init)
                                )
                                return MTPIterationResult(stream: mtpGenStream, renderedTail: tail)
                            }
                        } catch {
                            continuation.yield(
                                .init(
                                    kind: .error(
                                        InferenceError.standardPathFailed(
                                            "MTP generation failed: \(error.localizedDescription)"
                                        ).errorDescription ?? "error"
                                    )))
                            return
                        }

                        // Stream consumed OUTSIDE modelContainer.perform lock
                        var reasoningEmitter: ReasoningEventEmitter?
                        // Fix 2: reuse mtpReasoningConfig from L1842 instead of re-fetching
                        if let rc = mtpReasoningConfig {
                            let primed = ReasoningEventEmitter.promptEndsInsideReasoning(
                                renderedPromptTail: iterResult.renderedTail, config: rc
                            )
                            reasoningEmitter = ReasoningEventEmitter(
                                config: rc, primedInside: primed)
                        }

                        for try await generation in iterResult.stream {
                            if Task.isCancelled || cancellation.isCancelled {
                                // Inline emit .done(.cancelled) — same as std cancel path (L2379).
                                // Outer .done (L2234) is blocked by localStoppedBySeq=true,
                                // so we must emit here or the caller never gets a terminal event.
                                let mtpCancelTokPerSec =
                                    (actualTokenCount ?? 0) > 0
                                    ? Double(actualTokenCount ?? 0)
                                        / (Double(metrics.overallMs) / 1000.0)
                                    : nil
                                continuation.yield(
                                    .init(
                                        kind: .done(
                                            StopReason.cancelled,
                                            tokenCount: actualTokenCount
                                                ?? metrics.generatedTokenCount,
                                            tokPerSec: mtpCancelTokPerSec,
                                            promptTokPerSec: localPromptTokPerSec,
                                            reasoningTokenCount: min(
                                                phase1ReasoningTokenCount
                                                    + phase2ReasoningTokenCount,
                                                actualTokenCount
                                                    ?? metrics.generatedTokenCount) > 0
                                                ? min(
                                                    phase1ReasoningTokenCount
                                                        + phase2ReasoningTokenCount,
                                                    actualTokenCount
                                                        ?? metrics.generatedTokenCount)
                                                : nil,
                                            proposedDraftTokens: mtpProposedDraftTokens,
                                            acceptedDraftTokens: mtpAcceptedDraftTokens,
                                            passthroughReason: mtpPassthroughReason)))
                                localStoppedBySeq = true
                                break
                            }
                            switch generation {
                            case .chunk(let text):
                                if !localFirstToken {
                                    metrics.firstTokenMs = metrics.overallMs
                                    localFirstToken = true
                                }
                                metrics.incrementGenerated()
                                // If reasoning config is available, route through emitter.
                                // Otherwise pass text through directly as .text.
                                if let e = reasoningEmitter {
                                    var emitter = e
                                    for segment in emitter.process(text) {
                                        switch segment {
                                        case .reasoning(let segmentText):
                                            localAccumulatedText += segmentText
                                            let (shouldBreak2, newText2) = checkStopSequence(
                                                segment: segmentText,
                                                accumulated: localAccumulatedText,
                                                eventKind: { .reasoning($0) },
                                                tokenCount: localTokenCount,
                                                tokenFallback: metrics.generatedTokenCount,
                                                promptTokPerSec: localPromptTokPerSec,
                                                reasoningTokenCount: phase1ReasoningTokenCount
                                                    + phase2ReasoningTokenCount
                                            )
                                            if shouldBreak2 {
                                                localAccumulatedText = newText2
                                                localStoppedBySeq = true
                                                break
                                            }
                                        case .response(let segmentText):
                                            localAccumulatedText += segmentText
                                            let (shouldBreak, newText) = checkStopSequence(
                                                segment: segmentText,
                                                accumulated: localAccumulatedText,
                                                eventKind: { .text($0) },
                                                tokenCount: localTokenCount,
                                                tokenFallback: metrics.generatedTokenCount,
                                                promptTokPerSec: localPromptTokPerSec,
                                                reasoningTokenCount: phase1ReasoningTokenCount
                                                    + phase2ReasoningTokenCount
                                            )
                                            if shouldBreak {
                                                localAccumulatedText = newText
                                                localStoppedBySeq = true
                                                break
                                            }
                                        }
                                    }
                                } else {
                                    // No reasoning config — pass through as plain text
                                    localAccumulatedText += text
                                    let (shouldBreak3, newText3) = checkStopSequence(
                                        segment: text,
                                        accumulated: localAccumulatedText,
                                        eventKind: { .text($0) },
                                        tokenCount: localTokenCount,
                                        tokenFallback: metrics.generatedTokenCount,
                                        promptTokPerSec: localPromptTokPerSec,
                                        reasoningTokenCount: phase1ReasoningTokenCount
                                            + phase2ReasoningTokenCount
                                    )
                                    if shouldBreak3 {
                                        localAccumulatedText = newText3
                                        localStoppedBySeq = true
                                        break
                                    }
                                }
                            case .info(let completionInfo):
                                localTokenCount = completionInfo.generationTokenCount
                                // Capture both throughput metrics from upstream GenerateCompletionInfo
                                localPromptTokPerSec = completionInfo.promptTokensPerSecond
                                localGenerationTokPerSec = completionInfo.tokensPerSecond
                                localStopReason =
                                    switch completionInfo.stopReason {
                                    case .stop: .eos
                                    case .length: .maxTokens
                                    case .cancelled: .cancelled
                                    }
                                // Capture MTP speculative decoding metrics from upstream
                                localProposedDraftTokens = completionInfo.proposedDraftTokens
                                localAcceptedDraftTokens = completionInfo.acceptedDraftTokens
                                localPassthroughReason = completionInfo.passthroughReason
                                // P1-fix: Capture speculativeDecodingTelemetry (upstream Evaluate.swift:L2138)
                                _ = completionInfo.speculativeDecodingTelemetry?.roundCount ?? 0
                                // D2-fix: Phase 2 reasoning token tracking.
                                // When inside a reasoning span at end of iteration, attribute
                                // the iteration's tokens to the reasoning count (upstream pattern:
                                // AllowedToolOutputRouter counts per-token while isInsideReasoning).
                                if reasoningEmitter?.isInsideReasoning == true {
                                    phase2ReasoningTokenCount += completionInfo.generationTokenCount
                                }
                            case .toolCall(let mlxTC):
                                // Collect tool calls for dispatch after iteration
                                iterationToolCalls.append(mlxTC)
                                let tc = InferenceEvent.mlxToolCall(from: mlxTC)
                                continuation.yield(.init(kind: .toolCall(tc)))
                                toolCallDetected = true
                            case .rejectedToolCall(let rejection):
                                // Upstream #512/#538 (mlx-swift-lm 7871b09): model produced
                                // tool-call-shaped output that could not be parsed/authorized.
                                // Intentionally NOT treated as a detected tool call —
                                // toolCallDetected stays false so the MTP loop does not
                                // exit to dispatch a non-executable call; the loop
                                // continues on the next iteration (model gets another
                                // chance to emit a well-formed tool call). Deliberately
                                // does not log rawTextPreview (upstream: may contain
                                // sensitive argument values). reason/toolName/detail
                                // are the safe diagnostic fields.
                                self.logger.warning(
                                    "MTP path: rejected tool call — reason=\(rejection.reason.rawValue) tool=\((rejection.toolName.map { String($0) } ?? "nil")) detail=\((rejection.detail.map { String($0) } ?? "nil"))"
                                )
                            }
                        }

                        // If no tool calls were detected, or we hit a stop condition, exit the loop
                        // .required mode: tools are mandatory — if model produces no tool call,
                        // this is a contract violation (upstream L1270-1272: ".required enables
                        // think-then-call reasoning phase before tool dispatch").
                        guard toolCallDetected && !localStoppedBySeq else {
                            let isRequiredMode = options.toolCallingMode?.lowercased() == "required"
                            // G4 fix: only warn on .required when the model stopped for non-normal
                            // reasons (cancelled/error) AND produced no tool call.
                            // EOS/maxTokens/stopSequence are legitimate termination — not a violation.
                            let abnormalStop =
                                localStopReason == .cancelled
                                || localStopReason == .error

                            if isRequiredMode, !toolCallDetected, abnormalStop {
                                log.warning(
                                    "MTP .required mode: model produced no tool call — tools were mandatory"
                                )
                                let errTokPerSec =
                                    (actualTokenCount ?? 0) > 0
                                    ? Double(actualTokenCount ?? 0)
                                        / (Double(metrics.overallMs) / 1000.0)
                                    : nil
                                continuation.yield(
                                    .init(
                                        kind: .done(
                                            localStopReason ?? .maxTokens,
                                            tokenCount: actualTokenCount
                                                ?? metrics.generatedTokenCount,
                                            tokPerSec: errTokPerSec,
                                            promptTokPerSec: localPromptTokPerSec,
                                            reasoningTokenCount: min(
                                                phase1ReasoningTokenCount
                                                    + phase2ReasoningTokenCount,
                                                actualTokenCount
                                                    ?? metrics.generatedTokenCount) > 0
                                                ? min(
                                                    phase1ReasoningTokenCount
                                                        + phase2ReasoningTokenCount,
                                                    actualTokenCount
                                                        ?? metrics.generatedTokenCount)
                                                : nil,
                                            proposedDraftTokens: mtpProposedDraftTokens,
                                            acceptedDraftTokens: mtpAcceptedDraftTokens,
                                            passthroughReason: mtpPassthroughReason)))
                            }
                            break
                        }

                        // Dispatch collected tool calls and accumulate results
                        for toolCall in iterationToolCalls {
                            // Use toolDispatchClosure if available (dispatches via ToolRegistry)
                            // Otherwise dispatch inline
                            var result: String
                            do {
                                if let dispatch = mtpToolDispatch {
                                    result = try await dispatch(toolCall)
                                } else {
                                    // Build JSON arguments string for inline dispatch
                                    let argsDict = toolCall.function.arguments.mapValues {
                                        $0.anyValue
                                    }
                                    let jsonEncoded = try JSONSerialization.data(
                                        withJSONObject: argsDict
                                    )
                                    let argsString = String(
                                        decoding: jsonEncoded, as: UTF8.self)
                                    result =
                                        try await toolRegistry?.call(
                                            toolCall.function.name, arguments: argsString)
                                        ?? "[\(toolCall.function.name): tool registry not available]"
                                }
                            } catch {
                                result =
                                    "[\(toolCall.function.name): \(error.localizedDescription)]"
                                log.warning(
                                    "MTP tool dispatch error for \(toolCall.function.name): \(error)"
                                )
                            }
                            // P-S2: Append fresh perception context to tool result so the model
                            // sees updated environment state on each MTP iteration.
                            // Uses MainActor.run to bridge @MainActor PerceptionEngine boundary.
                            let perception = await fetchPerceptionContext()
                            if !perception.isEmpty {
                                // Append to result string only for inline path;
                                // mtpToolDispatch already injects perception via standard path fix.
                                if mtpToolDispatch == nil {
                                    result = result + "\n" + perception
                                }
                            }
                            // Append tool result message for next iteration
                            mtpMessages.append(
                                Chat.Message.tool(result, id: toolCall.id)
                            )
                        }
                    }
                    // Sync MTP result back to outer scope
                    if let tc = localTokenCount {
                        actualTokenCount = tc
                    }
                    if let sr = localStopReason {
                        lastStopReason = sr
                    }
                    if let generationPS = localGenerationTokPerSec {
                        generationTokPerSec = generationPS
                    }
                    if let ptokPs = localPromptTokPerSec {
                        promptTokPerSec = ptokPs
                    }
                    if let proposedDraft = localProposedDraftTokens {
                        mtpProposedDraftTokens = proposedDraft
                    }
                    if let acceptedDraft = localAcceptedDraftTokens {
                        mtpAcceptedDraftTokens = acceptedDraft
                    }
                    if let passthrough = localPassthroughReason {
                        mtpPassthroughReason = passthrough
                    }
                    if !localStoppedBySeq, actualTokenCount != nil {
                        continuation.yield(
                            .init(
                                kind: .done(
                                    lastStopReason ?? .maxTokens,
                                    tokenCount: actualTokenCount ?? metrics.generatedTokenCount,
                                    tokPerSec: generationTokPerSec,
                                    promptTokPerSec: promptTokPerSec,
                                    reasoningTokenCount: min(
                                        phase1ReasoningTokenCount
                                            + phase2ReasoningTokenCount,
                                        actualTokenCount ?? metrics.generatedTokenCount) > 0
                                        ? min(
                                            phase1ReasoningTokenCount
                                                + phase2ReasoningTokenCount,
                                            actualTokenCount ?? metrics.generatedTokenCount)
                                        : nil,
                                    proposedDraftTokens: mtpProposedDraftTokens,
                                    acceptedDraftTokens: mtpAcceptedDraftTokens,
                                    passthroughReason: mtpPassthroughReason)))
                    }
                }
                // MARK: - Standard Path — reasoning branch via generateTokens()
                /// Upstream: MLXLanguageModel.runReasoning uses generateTokens() → raw .token IDs
                /// → NaiveStreamingDetokenizer → ReasoningTokenCollector → segments.
                /// This gives true token-level reasoning count (1 .token == 1 real token).
                /// Non-reasoning path continues through ChatSession.streamDetails() below.
                struct StandardReasoningResult: Sendable {
                    let stoppedBySequence: Bool
                    let stopReason: StopReason?
                    let tokenCount: Int?
                    let reasoningTokenCount: Int
                    let genTokPerSec: Double?
                    let promptTokPerSec: Double?
                    let tokenIds: [Int]
                    // Whether generation terminated mid-thought (budget exhausted, cut-off, etc.)
                    // Upstream: runAllowedToolGeneration.result.endedInsideReasoning
                    let endedInsideReasoning: Bool
                    // MTP speculative decoding metrics (always nil on non-MTP models)
                    let proposedDraftTokens: Int?
                    let acceptedDraftTokens: Int?
                    let passthroughReason: String?
                    // Collected assistant response text for pool message history tracking
                    let accumulatedText: String?
                }

                // SAFETY: [Chat.Message] is non-Sendable — snapshot as Sendable
                // message pairs before entering @Sendable closure, exactly like
                // MTP path (L1763) and guided gen (L905).
                var stdMsgPairs: [(role: String, content: String)] = newMessages.map {
                    (role: $0.role.rawValue, content: $0.content)
                }
                if !stdMsgPairs.isEmpty, stdMsgPairs.last?.content.isEmpty == true,
                    stdMsgPairs.last?.role == "assistant"
                {
                    stdMsgPairs.removeLast()
                }

                // Fetch reasoning config outside closure (Sendable value)
                let reasoningConfigSnapshot = await handleRef.modelContainer.configuration
                    .reasoningConfig

                if mayRunReasoning, let rc = reasoningConfigSnapshot {
                    // Std reasoning only on unconstrained path (no tools, no schema).
                    // Upstream Executor.respond() gates reasoning behind mayRunReasoningPath:
                    //   mayRunReasoningPath = enabledToolDefinitions.isEmpty && request.schema == nil
                    // When tools or grammar schema are present, the constrained/tool path handles
                    // thinking internally — entering std reasoning here would double-inject
                    // thinking kwargs and bypass the tool-aware prompt rendering.
                    // P2-fix: removed early pool release — reasoning needs token-level segmentation
                    // that ChatSession doesn't provide, but the pooled session should be returned
                    // normally downstream so subsequent std requests can reuse the KV cache.
                    log.info("Routing through reasoning path — upstream generateTokens() alignment")

                    let stdResult: StandardReasoningResult

                    do {
                        // Snapshot: stdMsgPairs is a var (mutated by continueGeneration downstream),
                        // so copy to a let before crossing the @Sendable closure boundary.
                        let msgPairsSnapshot = stdMsgPairs
                        let primed: Bool
                        do {
                            // Upstream: reasoningPrimedInside(input:, config:, tokenizer:)
                            // computes primed from rendered prompt tail tokens, not from promptStrategy switch.
                            // This prevents misrouting when model pre-fill differs from strategy defaults.
                            primed = try await Self.computeReasoningPrimedInside(
                                messages: msgPairsSnapshot,
                                config: rc,
                                resize: config.vlmImageResize,
                                additionalContext: reasoningContext,
                                container: handleRef.modelContainer
                            )
                        }
                        stdResult = try await handleRef.modelContainer.perform { context in
                            // Rebuild Chat.Message inside @Sendable closure to avoid
                            // cross-actor capture of non-Sendable [Chat.Message].
                            let rebuiltMessages = msgPairsSnapshot.map { pair in
                                Chat.Message(
                                    role: Chat.Message.Role(rawValue: pair.role) ?? .system,
                                    content: pair.content
                                )
                            }

                            // Prepare LMInput inside closure for thread-safe ModelContext.
                            let stdProcessing = UserInput.Processing(resize: config.vlmImageResize)
                            let stdUserInput = UserInput(
                                prompt: .chat(rebuiltMessages),
                                processing: stdProcessing,
                                additionalContext: reasoningContext
                            )
                            let stdInput = try await context.processor.prepare(input: stdUserInput)

                            // ReasoningTokenCollector: token-level reasoning segment routing.
                            // Mirrors upstream MLXLanguageModel.runReasoning pattern.
                            var collector = ReasoningTokenCollector(
                                config: rc, primedInside: primed,
                                tokenizer: context.tokenizer)

                            var localStdAccumulated = ""
                            var localStdFirstToken = false
                            var localStdTokenCount: Int?
                            var localStdPromptTokPerSec: Double?
                            var localStdGenTokPerSec: Double?
                            var localStdStopReason: StopReason?
                            var localStdStoppedBySeq = false
                            var localStdReasoningTokenCount = 0
                            var localStdTokenIds: [Int] = []
                            // MTP speculative decoding metrics (nil on non-MTP models)
                            var localStdProposedDraftTokens: Int?
                            var localStdAcceptedDraftTokens: Int?
                            var localStdPassthroughReason: String?

                            // Std reasoning: generateTokensTask() returns (AsyncStream, Task)
                            // P1 (ThinkingBudget hard-budget): Build GenerationComponents with
                            // upstream ThinkingBudgetProcessor when budgetTransition is present
                            // (QwenReasoningProtocol supplies one). Budget limits reasoning tokens
                            // to half of maxTokens, reserving the other half for the answer.
                            // The existing ocoreai ThinkingBudget actor (adaptive scaffolding) and
                            // ThinkingBudgetProcessor (hard token ceiling) are orthogonal.
                            let genComponents: MLXLMCommon.GenerationComponents
                            do {
                                let budgetTokens = (genParams.maxTokens ?? 2048) / 2
                                let budgetConfig = try MLXLMCommon.ThinkingBudgetConfiguration(
                                    maximumTokenCount: budgetTokens,
                                    minimumAnswerTokenCount: 256,
                                    transitionOverride: nil  // use rc's own budgetTransition
                                )
                                genComponents = try MLXLMCommon.GenerationComponents()
                                    .applyingThinkingBudget(
                                        budgetConfig,
                                        reasoning: rc,
                                        tokenizer: context.tokenizer,
                                        diagnosticHandler: nil)
                            } catch {
                                // If budget setup fails (e.g. protocol lacks transition),
                                // fall back to no hard budget — adaptive scaffolding still active
                                log.warning("ThinkingBudget hard-budget not applied: \(error)")
                                genComponents = MLXLMCommon.GenerationComponents()
                            }
                            let (stdTokenStream, stdTokenTask) = try MLXLMCommon.generateTokensTask(
                                input: stdInput,
                                parameters: genParams,
                                context: context,
                                components: genComponents,
                                wiredMemoryTicket: wiredMemoryTicket
                            )

                            for await generation in stdTokenStream {
                                if Task.isCancelled || cancellation.isCancelled {
                                    localStdStoppedBySeq = true
                                    localStdStopReason = .cancelled
                                    continuation.yield(
                                        .init(
                                            kind: .done(
                                                .cancelled,
                                                tokenCount: localStdTokenCount
                                                    ?? metrics.generatedTokenCount,
                                                tokPerSec: localStdGenTokPerSec,
                                                promptTokPerSec: localStdPromptTokPerSec,
                                                reasoningTokenCount: min(
                                                    localStdReasoningTokenCount,
                                                    localStdTokenCount
                                                        ?? metrics.generatedTokenCount))))
                                    // G5 fix: cancel the generation task before breaking
                                    // to release GPU kernel references and prevent handle leak
                                    stdTokenTask.cancel()
                                    break
                                }
                                switch generation {
                                case .token(let token):
                                    // True token-level processing — one .token == one real token.
                                    if !localStdFirstToken {
                                        metrics.firstTokenMs = metrics.overallMs
                                        localStdFirstToken = true
                                    }
                                    // Track reasoning token count while inside reasoning span
                                    if collector.isInsideReasoning {
                                        localStdReasoningTokenCount += 1
                                    }

                                    // Ingest token → get routed segments
                                    let segments = collector.ingest(token)
                                    localStdTokenIds.append(token)
                                    for segment in segments {
                                        switch segment {
                                        case .reasoning(let segmentText):
                                            localStdAccumulated += segmentText
                                            let (shouldBreak, newText) = checkStopSequence(
                                                segment: segmentText,
                                                accumulated: localStdAccumulated,
                                                eventKind: { .reasoning($0) },
                                                tokenCount: localStdTokenCount,
                                                tokenFallback: localStdTokenIds.count,
                                                promptTokPerSec: localStdPromptTokPerSec,
                                                reasoningTokenCount: localStdReasoningTokenCount
                                            )
                                            if shouldBreak {
                                                localStdAccumulated = newText
                                                localStdStoppedBySeq = true
                                                localStdStopReason = .stopSequence
                                            }
                                        case .response(let segmentText):
                                            localStdAccumulated += segmentText
                                            let (shouldBreak2, newText2) = checkStopSequence(
                                                segment: segmentText,
                                                accumulated: localStdAccumulated,
                                                eventKind: { .text($0) },
                                                tokenCount: localStdTokenCount,
                                                tokenFallback: localStdTokenIds.count,
                                                promptTokPerSec: localStdPromptTokPerSec,
                                                reasoningTokenCount: localStdReasoningTokenCount
                                            )
                                            if shouldBreak2 {
                                                localStdAccumulated = newText2
                                                localStdStoppedBySeq = true
                                                localStdStopReason = .stopSequence
                                            }
                                        }
                                    }
                                case .info(let info):
                                    localStdTokenCount = info.generationTokenCount
                                    localStdPromptTokPerSec = info.promptTokensPerSecond
                                    localStdGenTokPerSec = info.tokensPerSecond
                                    localStdStopReason =
                                        switch info.stopReason {
                                        case .stop: .eos
                                        case .length: .maxTokens
                                        case .cancelled: .cancelled
                                        }
                                    // MTP speculative decoding metrics (upstream Evaluate.swift)
                                    localStdProposedDraftTokens = info.proposedDraftTokens
                                    localStdAcceptedDraftTokens = info.acceptedDraftTokens
                                    localStdPassthroughReason = info.passthroughReason
                                }
                            }

                            // Flush any remaining buffered text from collector
                            // Upstream: record whether generation ended mid-thought so we can
                            // emit incompleteOutput metadata. Capture isInsideReasoning before
                            // finalize() mutates the collector state.
                            let endedInsideReasoning = collector.isInsideReasoning
                            let finalSegments = collector.finalize()
                            for segment in finalSegments {
                                switch segment {
                                case .reasoning(let segmentText):
                                    continuation.yield(.init(kind: .reasoning(segmentText)))
                                case .response(let segmentText):
                                    continuation.yield(.init(kind: .text(segmentText)))
                                }
                            }

                            // Skill pattern: deterministic cleanup after stream exhaustion
                            await stdTokenTask.value

                            return StandardReasoningResult(
                                stoppedBySequence: localStdStoppedBySeq,
                                stopReason: localStdStopReason,
                                tokenCount: localStdTokenCount,
                                reasoningTokenCount: min(
                                    localStdReasoningTokenCount,
                                    localStdTokenCount ?? metrics.generatedTokenCount),
                                genTokPerSec: localStdGenTokPerSec,
                                promptTokPerSec: localStdPromptTokPerSec,
                                tokenIds: localStdTokenIds,
                                endedInsideReasoning: endedInsideReasoning,
                                proposedDraftTokens: localStdProposedDraftTokens,
                                acceptedDraftTokens: localStdAcceptedDraftTokens,
                                passthroughReason: localStdPassthroughReason,
                                accumulatedText: localStdAccumulated.isEmpty
                                    ? nil : localStdAccumulated
                            )
                        }
                    } catch {
                        continuation.yield(
                            .init(
                                kind: .error(
                                    InferenceError.standardPathFailed(
                                        "reasoning generation failed: \(error.localizedDescription)"
                                    ).errorDescription ?? "error"
                                )
                            )
                        )
                        return
                    }

                    // Sync reasoning result back to outer scope
                    if let tc = stdResult.tokenCount {
                        actualTokenCount = tc
                    }
                    if let sr = stdResult.stopReason {
                        lastStopReason = sr
                    }
                    generationTokPerSec = stdResult.genTokPerSec
                    promptTokPerSec = stdResult.promptTokPerSec
                    metrics.generatedTokenCount += stdResult.tokenIds.count
                    // Capture assistant text for pool message history tracking
                    stdAccumulated = stdResult.accumulatedText

                    // Upstream: emit diagnostic metadata about generation state.
                    if !stdResult.stoppedBySequence, !Task.isCancelled {
                        // Upstream: if generation ended inside a reasoning block
                        // (budget exhausted before closing </think>), emit incompleteOutput
                        // metadata so downstream knows the thought was truncated.
                        // Mirrors runReasoning's result.endedInsideReasoning check.
                        if stdResult.endedInsideReasoning {
                            continuation.yield(
                                .init(
                                    kind: .guidedGenDiagnostic(
                                        grammarTerminated: false,
                                        incompleteOutput: true)))
                        }
                        continuation.yield(
                            .init(
                                kind: .done(
                                    lastStopReason ?? .eos,
                                    tokenCount: actualTokenCount ?? metrics.generatedTokenCount,
                                    tokPerSec: generationTokPerSec,
                                    promptTokPerSec: promptTokPerSec,
                                    reasoningTokenCount: min(
                                        stdResult.reasoningTokenCount,
                                        actualTokenCount ?? metrics.generatedTokenCount)
                                )
                            )
                        )
                    }

                    // MARK: - Standard ChatSession Path (non-reasoning fallback)
                    /// Non-reasoning models continue through ChatSession.streamDetails()
                    /// for text + multimodal generation with tool dispatch support.
                } else {
                    var localStdAccumulated = ""
                    // MTP speculative decoding telemetry — populated when ChatSession
                    // internal iterator is SpeculativeTokenIterator (non-reasoning MTP path).
                    // Same fields as MTP bypass path — .done carries them regardless of path.
                    var localStdProposedDraftTokens: Int?
                    var localStdAcceptedDraftTokens: Int?
                    var localStdPassthroughReason: String?

                    // ChatSession's KV cache already holds context from previous rounds.
                    // newMessages (set above) contains only what's not yet cached:
                    //   - pool hit  → new user message only
                    //   - pool miss → full history including system instructions
                    // `chatSession` was acquired before the reasoning/fm branches; if it
                    // is nil here the FM path already consumed it — report, don't crash.
                    guard let chatSession else {
                        logger.error("Standard ChatSession path entered with nil chatSession")
                        continuation.yield(
                            .init(kind: .error("Engine internal error: no active chat session")))
                        continuation.finish()
                        return
                    }
                    for try await generation in chatSession.streamDetails(
                        to: newMessages
                    ) {
                        if Task.isCancelled || cancellation.isCancelled {
                            let cancelTokPerSec =
                                (actualTokenCount ?? 0) > 0
                                ? Double(actualTokenCount ?? 0)
                                    / (Double(metrics.overallMs) / 1000.0)
                                : nil
                            continuation.yield(
                                .init(
                                    kind: .done(
                                        StopReason.cancelled,
                                        tokenCount: actualTokenCount ?? 0,
                                        tokPerSec: cancelTokPerSec,
                                        promptTokPerSec: promptTokPerSec,
                                        reasoningTokenCount: 0)))
                            break
                        }
                        switch generation {
                        case .chunk(let text):
                            if actualTokenCount == nil {
                                metrics.firstTokenMs = metrics.overallMs
                            }
                            metrics.incrementGenerated()
                            localStdAccumulated += text
                            let (shouldBreakS3, newText3) = checkStopSequence(
                                segment: text,
                                accumulated: localStdAccumulated,
                                eventKind: { .text($0) },
                                tokenCount: actualTokenCount,
                                tokenFallback: metrics.generatedTokenCount,
                                promptTokPerSec: promptTokPerSec
                            )
                            if shouldBreakS3 {
                                localStdAccumulated = newText3
                                lastStopReason = .stopSequence
                                break
                            }
                        case .info(let completionInfo):
                            if actualTokenCount == nil {
                                actualTokenCount = completionInfo.generationTokenCount
                            }
                            // Capture both throughput metrics from upstream GenerateCompletionInfo
                            promptTokPerSec = completionInfo.promptTokensPerSecond
                            generationTokPerSec = completionInfo.tokensPerSecond
                            lastStopReason =
                                switch completionInfo.stopReason {
                                case .stop: .eos
                                case .length: .maxTokens
                                case .cancelled: .cancelled
                                }
                            // MTP speculative decoding metrics — present when ChatSession
                            // uses SpeculativeTokenIterator internally. Nil on standard path.
                            localStdProposedDraftTokens = completionInfo.proposedDraftTokens
                            localStdAcceptedDraftTokens = completionInfo.acceptedDraftTokens
                            localStdPassthroughReason = completionInfo.passthroughReason
                        case .toolCall(let mlxTC):
                            let tc = InferenceEvent.mlxToolCall(from: mlxTC)
                            continuation.yield(.init(kind: .toolCall(tc)))
                        case .rejectedToolCall(let rejection):
                            // Upstream #512/#538 (mlx-swift-lm 7871b09): no-tools
                            // standard ChatSession path — a rejection here is a
                            // protocol anomaly, not a dispatchable event. Matches
                            // upstream own convention (MLXLanguageModel logs it on
                            // the non-throwing decoder path). Deliberately does not
                            // log rawTextPreview (upstream: may contain sensitive
                            // argument values). reason/toolName/detail are the safe
                            // diagnostic fields.
                            self.logger.warning(
                                "Standard ChatSession path: rejected tool call — reason=\(rejection.reason.rawValue) tool=\((rejection.toolName.map { String($0) } ?? "nil")) detail=\((rejection.detail.map { String($0) } ?? "nil"))"
                            )
                        }
                    }

                    // Emit final .done event with prompt throughput + MTP telemetry
                    if !Task.isCancelled {
                        continuation.yield(
                            .init(
                                kind: .done(
                                    lastStopReason ?? .eos,
                                    tokenCount: actualTokenCount ?? metrics.generatedTokenCount,
                                    tokPerSec: generationTokPerSec,
                                    promptTokPerSec: promptTokPerSec,
                                    reasoningTokenCount: 0,
                                    proposedDraftTokens: localStdProposedDraftTokens,
                                    acceptedDraftTokens: localStdAcceptedDraftTokens,
                                    passthroughReason: localStdPassthroughReason)))
                    }
                    // Capture assistant text for pool message history tracking
                    if !localStdAccumulated.isEmpty {
                        stdAccumulated = localStdAccumulated
                    }
                }

            } catch let error {
                // RAII: guarantee pool slot release on any inference exception.
                await releasePoolSlot()
                throw error
            }

            // Normal completion: release pool slot if still held.
            // Early-return paths (guided gen / MTP on pool hit) already released and niled chatSession,
            // so subsequent calls to releasePoolSlot are no-ops.
            //
            // Set lastAssistantMessage for pooled session history extension:
            // - Standard reasoning path: localStdAccumulated (from reasoning TokenCollector)
            // - Standard ChatSession path: localStdAccumulated (from streamDetails)
            // FM path accumulates in fmAccumulated, MTP in mtpAccumulated — both are local
            // to their respective blocks and released before this point via early-release.
            // At this scope, localStdAccumulated holds the assistant response text.
            if let acc = stdAccumulated {
                let assistantKey = MessageHistoryKey(
                    role: "assistant",
                    contentHash: "\(acc)".hashValue
                )
                await releasePoolSlotWithAssistant(assistantKey)
            } else {
                await releasePoolSlot()
            }
        }

        // Layer 0: Wired memory GPU hard-isolation + GPU telemetry
        // Scopes wired limit to this inference request. Auto-released on completion/error.
        // Policy: WiredMaxPolicy when config.wiredMemory.policy == "max", else WiredSumPolicy.
        let logRef = self.logger
        if config.wiredMemory.enabled {
            // Estimate ticket size: per-request GPU memory delta (KV cache + activations).
            // Weights are already resident in the LoadedModel's GPU memory — they are NOT
            // per-request overhead and must not be counted here (P0-fix: prev formula included
            // vocabSize*8 which double-counted resident weights, causing admission gate to
            // under-estimate per-request headroom and over-accept requests that could OOM).
            //
            // KV cache per-token estimate for 4bit quantized models:
            //   ~2 KiB/token (covers K+V across all layers at 4-bit quantization).
            // For context lengths L: ticket ≈ L * 2048 bytes.
            // bytesOverride from config takes priority when set.
            let ticketSize: Int
            if config.wiredMemory.bytesOverride > 0 {
                ticketSize = Int(config.wiredMemory.bytesOverride)
            } else {
                ticketSize = Int(loaded.modelConfig.maxContextLength) * 2048
            }

            // FIXED: Hashable policies derive stable identity from their value (cap), not UUID.
            // Custom ID broke WiredMemoryManager's grouping/hysteresis logic.
            // Aligns with upstream WiredMemoryPolicies.swift — 4 policies supported:
            //   sum → WiredSumPolicy, max → WiredMaxPolicy,
            //   budget → WiredBudgetPolicy, fixed → WiredFixedPolicy.
            let wmPolicy: any WiredMemoryPolicy =
                switch config.wiredMemory.policy {
                case "sum":
                    WiredSumPolicy(cap: nil)
                case "budget":
                    WiredBudgetPolicy(
                        baseBytes: config.wiredMemory.budgetBaseBytes,
                        cap: config.wiredMemory.budgetCap
                    )
                case "fixed":
                    WiredFixedPolicy(limit: max(1, config.wiredMemory.fixedLimit))
                default:
                    WiredMaxPolicy()
                }

            let ticket = WiredMemoryTicket(
                size: ticketSize,
                policy: wmPolicy,
                manager: .shared,
                kind: WiredMemoryTicketKind.active,
            )

            // GPU telemetry: pre-inference snapshot
            let preSnapshot = Memory.snapshot()
            logRef.debug(
                "GPU pre-inference [\(modelId)] active: \(preSnapshot.activeMemory / 1_048_576)MB, cache: \(preSnapshot.cacheMemory / 1_048_576)MB, peak: \(preSnapshot.peakMemory / 1_048_576)MB"
            )
            _ = await self.memoryTracker?.reportGPUActiveBytes(UInt64(preSnapshot.activeMemory))

            // Acquire wired limit, run inference, then release
            _ = await ticket.start()
            let caughtError: (any Error)?
            do {
                try await runInferenceBody(wiredMemoryTicket: ticket)
                caughtError = nil
            } catch {
                caughtError = error
            }
            _ = await ticket.end()

            // GPU telemetry: post-inference snapshot
            let postSnapshot = Memory.snapshot()
            let gpuDelta = preSnapshot.delta(postSnapshot)
            logRef.debug(
                "GPU post-inference delta [\(modelId)] active: \(gpuDelta.activeMemory / 1_048_576)MB, cache: \(gpuDelta.cacheMemory / 1_048_576)MB"
            )

            // Propagate error if caught
            if caughtError != nil {
                continuation.yield(
                    .init(
                        kind: .error(
                            InferenceError.standardPathFailed("inference failed").errorDescription
                                ?? "error")))
            }

            metrics.inferenceMs = metrics.overallMs
            continuation.finish()
            return
        }

        // Execute inference body without wired memory scoping
        do {
            try await runInferenceBody(wiredMemoryTicket: nil)
        } catch {
            continuation.yield(
                .init(
                    kind: .error(
                        InferenceError.standardPathFailed("inference failed").errorDescription
                            ?? "error")))
        }

        metrics.inferenceMs = metrics.overallMs
        continuation.finish()
    }

    // MARK: - Static helpers (CoreAI path)

    /// Check decoded text for any stop sequence. Returns the earliest match offset.
    /// Aligned with upstream `StopSequences.matches` but at text level.
    private struct StopMatch { let offset: String.Index }
    private static func firstMatchStopSequence(in text: String, sequences: [String]) -> StopMatch? {
        var bestEarly: StopMatch? = nil
        for seq in sequences where !seq.isEmpty {
            if let range = text.range(of: seq) {
                if let current = bestEarly {
                    if range.lowerBound < current.offset {
                        bestEarly = StopMatch(offset: range.lowerBound)
                    }
                } else {
                    bestEarly = StopMatch(offset: range.lowerBound)
                }
            }
        }
        return bestEarly
    }

    /// Yield ThinkTagParser + ToolCallParser events for a decoded text segment.
    /// Extracted to avoid duplicating the switch chain across 3 call sites.
    /// Returns the number of reasoning characters emitted (for reasoningTokenCount estimation).
    nonisolated private static func yieldParserEvents(
        _ decoded: String,
        thinkParser: inout ThinkTagParser,
        toolParser: inout ToolCallParser,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation
    ) -> Int {
        var reasoningChars = 0
        for thinkEvent in thinkParser.consume(decoded) {
            switch thinkEvent {
            case .reasoning(let segText):
                reasoningChars += segText.utf8.count
                continuation.yield(.init(kind: .reasoning(segText)))
            case .text(let segText):
                for toolEvent in toolParser.consume(segText) {
                    switch toolEvent {
                    case .text(let plainText):
                        continuation.yield(.init(kind: .text(plainText)))
                    case .toolCall(let id, let name, let argsJSON):
                        continuation.yield(
                            .init(
                                kind: .toolCall(
                                    ToolCall(
                                        id: id,
                                        type: "function",
                                        function: ToolCallFunction(
                                            name: name,
                                            arguments: argsJSON
                                        )
                                    )
                                )))
                    }
                }
            }
        }
        return reasoningChars
    }
}

// MARK: - Reasoning Primed Detection (EnginePool helper)

extension EnginePool {
    /// Compute reasoning primed inside from rendered prompt tail, mirroring
    /// upstream `MLXLanguageModel.reasoningPrimedInside(input:config:tokenizer:)`.
    ///
    /// Upstream approach: prepare input → grab last 64 tokens → decode to text →
    /// `ReasoningEventEmitter.promptEndsInsideReasoning(tail:config:)`.
    /// This is more accurate than `switch promptStrategy` because it checks the
    /// actual rendered prompt tail rather than the strategy default.
    private static func computeReasoningPrimedInside(
        messages: [(role: String, content: String)],
        config: ReasoningConfig,
        resize: CGSize,
        additionalContext: [String: any Sendable]?,
        container: ModelContainer
    ) async throws -> Bool {
        // Rebuild Chat.Message for processor
        let rebuiltMessages = messages.map { pair in
            Chat.Message(
                role: Chat.Message.Role(rawValue: pair.role) ?? .system,
                content: pair.content
            )
        }

        // Prepare input to get tokenized prompt
        let processing = UserInput.Processing(resize: resize)
        let userInput = UserInput(
            prompt: .chat(rebuiltMessages),
            processing: processing,
            additionalContext: additionalContext
        )
        let input = try await container.processor.prepare(input: userInput)

        // Decode last 64 tokens as rendered tail (same as upstream)
        let tokens = input.text.tokens.asArray(Int.self)
        let tailTokenCount = Swift.min(64, tokens.count)
        let tailTokens = Array(tokens.suffix(tailTokenCount))
        let renderedTail = await container.tokenizer.decode(tokenIds: tailTokens)

        return ReasoningEventEmitter.promptEndsInsideReasoning(
            renderedPromptTail: renderedTail,
            config: config
        )
    }

    /// P1-1 fix: .alwaysOn reasoning model protection for guided gen / MTP paths.
    ///
    /// Upstream MLXLanguageModel.respond() (L1060-L1072) prevents models whose
    /// promptStrategy is .alwaysOn from being routed through grammar-constrained
    /// paths — the grammar would truncate thinking tokens, producing broken output.
    ///
    /// Returns true when safe to use guided gen / MTP (reasoning absent or suppressible).
    /// Returns false when the model has an .alwaysOn reasoning config that cannot
    /// be disabled — in which case the request must fall through to ChatSession
    /// where ReasoningEventEmitter handles thinking segmentation correctly.
    private static func reasoningSafeForConstrainedPaths(
        _ configuration: ModelConfiguration
    ) -> Bool {
        guard let rc = configuration.reasoningConfig else { return true }
        // .alwaysOn models cannot disable thinking — grammar would truncate reasoning
        do {
            _ = try rc.promptStrategy.additionalContext(forThinkingEnabled: false)
            return true
        } catch {
            return false
        }
    }
}
