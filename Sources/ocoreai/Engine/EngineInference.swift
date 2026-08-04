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
        if #available(macOS 27.0, *) {
            // CoreAI lacks grammar constraints and tool dispatch — fall back to MLX
            if options.grammarSchema != nil || options.useGuidedGeneration {
                logger.info(
                    "Falling back to MLX for grammar/tool-constrained request on model \(modelId)")
                let promptText: String
                do {
                    promptText = try await detokenize(modelId: modelId, tokens: input)
                } catch {
                    logger.warning(
                        "Detokenize failed for CoreAI→MLX fallback: \(error.localizedDescription)")
                    continuation.yield(
                        .init(kind: .error("Detokenization failed — cannot fall back MLX path")))
                    continuation.finish()
                    return
                }

                // Check for model-specific reasoning control tokens that will be lost in detokenize→retokenize roundtrip.
                // Qwen3: 151645=<thinking_open>, 151646=<thinking_close>
                let reasoningControlTokens = Set([151645, 151646])
                if input.contains(where: { reasoningControlTokens.contains(Int($0)) }) {
                    logger.warning(
                        "CoreAI input contains reasoning control tokens that would be lost in MLX fallback — staying on CoreAI path, grammar constraints dropped for model \(modelId)"
                    )
                    // Continue to CoreAI path below, grammar/stopSeq silently ignored.
                } else {
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
                    return
                }
            }
            // Warn about sampling fields CoreAI SDK cannot honor
            // (CoreAI.SamplingConfiguration only supports temperature/topK/topP/minP/combined)
            let coreaiUnhonoredFields: [String] = [
                sampling.seed != nil ? "seed" : "",
                sampling.repetitionPenalty != nil ? "repetitionPenalty" : "",
                sampling.presencePenalty != nil ? "presencePenalty" : "",
                sampling.frequencyPenalty != nil ? "frequencyPenalty" : "",
            ].filter { !$0.isEmpty }

            // stopSequences are NOT supported by CoreAI's engine.generate
            // → explicitly fall back to MLX path to avoid silent failures
            let hasStopSeq = !(sampling.stopSequences ?? []).isEmpty
            if hasStopSeq {
                logger.info("Falling back to MLX for stopSequences on model \(modelId)")
                let promptText: String
                do {
                    promptText = try await detokenize(modelId: modelId, tokens: input)
                } catch {
                    logger.warning(
                        "Detokenize failed for stopSeq MLX fallback: \(error.localizedDescription)")
                    continuation.yield(
                        .init(kind: .error("Detokenization failed — cannot fall back MLX path")))
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
                return
            }

            if !coreaiUnhonoredFields.isEmpty {
                logger.warning(
                    "[CoreAI] Sampling fields not honored by SDK: \(coreaiUnhonoredFields.joined(separator: ", "))"
                )
            }

            do {
                // Use cached engine — CoreAI 34f0db3: single engine per model preserves
                // KV cache across turns. TokenHistory.resolve handles prefix caching automatically.
                let engine = try await loaded.getCachedEngine()
                let sequence = try await engine.generate(
                    with: input,
                    samplingConfiguration: sampling,
                    inferenceOptions: options,
                )

                var streamCancelled = false
                do {
                    for try await output in sequence {
                        if Task.isCancelled || cancellation.isCancelled {
                            streamCancelled = true
                            // Drain remaining output to release GPU memory
                            // (CoreAI keeps pending tokens on GPU until consumed or drained)
                            break
                        }
                        metrics.incrementGenerated()
                        if metrics.generatedTokenCount == 1 {
                            metrics.firstTokenMs = metrics.overallMs
                        }
                        continuation.yield(
                            .init(
                                kind: .token(
                                    (output as? InferenceOutput)?.tokenId ?? 0
                                )))
                    }
                } catch {
                    continuation.yield(
                        .init(
                            kind: .error(
                                InferenceError.guidedGenerationFailed("generation failed")
                                    .errorDescription ?? "error")))
                    return
                }

                if streamCancelled {
                    // Drain remaining tokens to free CoreAI GPU memory
                    // (upstream #113 fix: pipelined sequence retains output until consumed)
                    logger.debug("CoreAI stream cancelled — draining remaining output")
                    do {
                        for try await _ in sequence {}
                    } catch {
                        // Drain error — the stream was already cancelled, this is expected
                        logger.debug("CoreAI drain error: \(error.localizedDescription)")
                    }
                    continuation.yield(
                        .init(
                            kind: .done(
                                StopReason.cancelled,
                                tokenCount: metrics.generatedTokenCount,
                                tokPerSec: metrics.generatedTokenCount > 0
                                    ? Double(metrics.generatedTokenCount)
                                        / (Double(metrics.overallMs) / 1000.0)
                                    : nil)))
                } else if !Task.isCancelled {
                    // Read actual stop reason from sequence; default to maxTokens if unset
                    // (e.g., empty prefix-hit path or early termination edge case)
                    let stopReason: StopReason = sequence.stopReason?.stopReason ?? .maxTokens
                    continuation.yield(
                        .init(
                            kind: .done(
                                stopReason,
                                tokenCount: metrics.generatedTokenCount,
                                tokPerSec: metrics.generatedTokenCount > 0
                                    ? Double(metrics.generatedTokenCount)
                                        / (Double(metrics.overallMs) / 1000.0)
                                    : nil)))
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

        // Check for model-specific reasoning control tokens that will be lost in detokenize→retokenize roundtrip
        // P0-fix: removed universal ASCII control chars (newline=198, ESC=27) — they fire on every request
        // and flood the log. Only flag reasoning-specific tokens (<|begin_of_thought|>, <|eot_id|>).
        let reasoningControlTokens = Set([151645, 151646])  // <|begin_of_thought|>, <|eot_id|>
        if input.contains(where: { reasoningControlTokens.contains(Int($0)) }) {
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
    // MARK: - MLX Image Helper

    /// Convert a string that may be a data URL (`data:image/…;base64,…`) or a
    /// regular URL into an ``MLXLMCommon/UserInput/Image``.
    /// Data URLs are decoded to `CIImage`; remote/local URLs are passed through.
    /// Top-level free function — does not capture `self` (avoids Sendable taint).
    nonisolated func makeMLXImage(from urlString: String) -> MLXLMCommon.UserInput.Image? {
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
    /// Top-level free function — does not capture `self` (avoids Sendable taint).
    /// Returns the created temp file URL (if any) so callers can clean up after inference.
    nonisolated func makeMLXAudio(from urlString: String) -> (
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
        let computeChannel: ComputeChannel
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

        // P0 fix: CoreAI `_runInference` cannot tokenize multimodal content —
        // `contentToString()` in EnginePool.tokenize() silently drops images/videos/audio,
        // producing text-only output for VLM requests. When ANE is selected but multimodal
        // content is present, force GPU fallback to MLX path which handles VLM natively.
        #if canImport(CoreAI)
        if computeChannel == .ane, !hasMultimodalContent(messages) {
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
        let systemInstructions: String? =
            switch messages.first(where: { $0.role == "system" })?.content {
            case .text(let t): t
            case .parts(let p): p.first(where: { $0.text != nil })?.text
            case nil: nil
            }
        let nonSystemMessages = messages.filter { $0.role != "system" }

        let mlxMessages: [Chat.Message] = nonSystemMessages.map { msg in
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

        let genParams = makeGenerateParameters(
            from: sampling,
            maxTokens: options.maxTokens,
            kvCacheQuant: config.kvCacheQuantization,
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

                // Closing token bias + whitespace bias — computed per-inference.
                // (Upstream caches these; we defer bias caching pending async-safe lock
                // in non-actor MLX context. Bias compute is ~1ms so impact is minimal.)
                let closingBias = ClosingTokenBias.compute(
                    tokenizer: context.tokenizer,
                    eosTokenId: context.tokenizer.eosTokenId
                )
                let (whitespaceBias, whitespaceTokenIDs) = WhitespaceTokenBias.compute(
                    tokenizer: context.tokenizer)

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
                            kvBits: genParams.kvBits,
                            kvGroupSize: genParams.kvGroupSize,
                            quantizedKVStart: genParams.quantizedKVStart,
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
                                            tokPerSec: tokPerSec)))
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
                                            StopReason.stopSequence, tokenCount: guidedTokenCount,
                                            tokPerSec: tokPerSec)))
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
                                            stopReason, tokenCount: tc, tokPerSec: tokPerSec)))
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
                                    tokPerSec: tokPerSec)))
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
        @Sendable func checkStopSequence(
            segment: String,
            accumulated: String,
            eventKind: @escaping @Sendable (String) -> InferenceEvent.Kind,
            tokenCount: Int?,
            tokenFallback: Int
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
                            tokPerSec: tokPerSec)))
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
        func runInferenceBody() async throws {
            let convKey: String = conversationId ?? "\(modelId):ephemeral"
            var isPoolHit = false
            var chatSession: ChatSession?
            var registeredToolSpecs: [ToolSpec]?

            // Bridge ToolRegistry → ChatSession tools + toolDispatch
            if let registry = toolRegistry {
                let specs = await registry.toToolSpecs()
                if !specs.isEmpty {
                    registeredToolSpecs = specs
                }

            }

            // MARK: - macOS 27: LanguageModelSession bridge
            // LanguageModelSession → Executor.respond() → ToolCallingModeResolution
            // + Think-then-Call + AllowedToolOutputRouter + CompletionReserve
            // All activated by passing full tools/transcript/context options.
            #if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
            if #available(macOS 27.0, *), let mlxLM = loaded.mlxLanguageModel {
                log.info("Using LanguageModelSession (macOS 27 SDK path)")

                // --- Build FM Tool array from ToolRegistry ---
                // tools: [] is the #1 degradation vector — it short-circuits
                // Executor.respond()'s entire tool-calling pipeline.
                var fmTools: [any FoundationModels.Tool]? = nil
                if let registry = toolRegistry {
                    let specs = await registry.toToolSpecs()
                    if !specs.isEmpty {
                        fmTools = FMToolProxy.tools(from: registry, toolSpecs: specs, log: log)
                        log.info("Injected \(fmTools!.count) tools into FM session")
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
                let tcMode: FoundationModels.GenerationOptions.ToolCallingMode =
                    (fmTools?.isEmpty == false) ? .allowed : .disallowed
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
                                if fmEmitter != nil {
                                    for segment in fmEmitter!.process(text) {
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
                                if fmEmitter != nil {
                                    for segment in fmEmitter!.process(partial.content) {
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
            // Tool dispatch closure: ChatSession owns tool execution via its built-in
            // loop (ChatSession.swift L748 restart). Both pool-hit and new-session paths
            // set tools+toolDispatch so tool calls are handled internally.
            // AgentLoop (Agents/AgentLoop.swift) is no longer used for MLX/ChatSession
            // paths — it serves only as a fallback for CoreAI/bridge paths where
            // ChatSession is unavailable.
            //
            // Fix: ChatSession L1043 intercepts .toolCall events when toolDispatch != nil
            // ("collect tool calls for dispatch; if no toolDispatch the caller handles
            //  them via the transform") — they never reach streamDetails. Intercepted
            // tool calls are tracked here so we can emit .toolCall events downstream
            // after the stream loop completes but before .done.
            // Thread-safe via actor — @Sendable closures can't mutate outer vars in Swift 6.
            let tracker = _InterceptedToolCallTracker()
            var toolDispatchClosure: (@Sendable (MLXLMCommon.ToolCall) async throws -> String)? =
                nil
            if let registry = toolRegistry {
                toolDispatchClosure = { toolCall in
                    await tracker.record(toolCall)
                    let argsDict = toolCall.function.arguments.mapValues { $0.anyValue }
                    let jsonEncoded = try JSONSerialization.data(
                        withJSONObject: argsDict
                    )
                    let argsString = String(decoding: jsonEncoded, as: UTF8.self)
                    return try await registry.call(toolCall.function.name, arguments: argsString)
                }
            }

            // Upstream Executor.respond() gates reasoning behind mayRunReasoningPath:
            //   mayRunReasoningPath = enabledToolDefinitions.isEmpty && request.schema == nil
            // When tools or grammar schema are present, the constrained/tool path handles
            // thinking internally — injecting reasoningContext there would double-inject
            // thinking kwargs into an already tool-aware template.
            let mayRunReasoning =
                (registeredToolSpecs ?? []).isEmpty && options.grammarSchema == nil

            let reasoningContext: [String: any Sendable]?
            if mayRunReasoning,
                let rc = await handleRef.modelContainer.configuration.reasoningConfig
            {
                let thinkingEnabled = options.enableReasoning ? true : nil
                do {
                    reasoningContext = try rc.promptStrategy.additionalContext(
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
                    reasoningContext = nil
                }
            } else if !mayRunReasoning,
                await handleRef.modelContainer.configuration.reasoningConfig != nil
            {
                log.info(
                    "Reasoning suppressed — tools or grammar schema present (mayRunReasoningPath)")
                reasoningContext = nil
            } else {
                reasoningContext = nil
            }

            // Track which messages to feed to ChatSession. ChatSession accumulates
            // KV cache internally — on pool hits we only feed the new message(s),
            // on pool miss / no pool we feed the full history.
            var newMessages: [Chat.Message]

            if let pool = poolRef {
                let acquired = await pool.acquire(
                    from: handleRef.modelContainer,
                    modelId: modelId,
                    conversationId: convKey,
                    genParams: genParams,
                    speculativeDecoding: specConfig,
                    instructions: systemInstructions,
                    processing: sessionProcessing,
                )
                chatSession = acquired.pooled.session
                isPoolHit = acquired.isHit
                // P0-fix: release on any exit path (throw, early return, normal completion).
                // Previously pool.release was ordered code at L2114 — skipped by
                // handleGuidedGeneration throw (L938/L954/L1141), MTP early return (L1563),
                // and any modelContainer.perform error. Caused persistent pool slot leak.
                defer {
                    if let pooledSession = chatSession {
                        await pool.release(
                            pooled: PooledChatSession(
                                session: pooledSession,
                                lastAccessedAt: ContinuousClock.now,
                            ),
                            modelId: modelId,
                            conversationId: convKey,
                        )
                    }
                }
                if isPoolHit {
                    log.debug("Pool HIT for \(convKey) — KV cache reused")
                    // Pool hit: ChatSession's KV cache already has history baked in.
                    // Only pass new messages — don't re-tokenize or re-prefill old ones.
                    newMessages = [mlxMessages.last ?? Chat.Message(role: .user, content: "")]
                } else {
                    // Pool miss / cold start: pass full history including system
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
                /// Upstream reasonnigConfig already has the prompt strategy baked in via
                /// LLMModelFactory._load. The ReasoningEventEmitter below parses
                /// model-rendered thinking tags (ReasoningConfig.swift:106-124).
                chatSession = ChatSession(
                    handleRef.modelContainer,
                    instructions: systemInstructions,
                    speculativeDecoding: spec,
                    generateParameters: gp,
                    processing: sessionProcessing,
                    additionalContext: reasoningContext,
                    tools: registeredToolSpecs,
                    toolDispatch: toolDispatchClosure
                )
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
                if let schema = options.grammarSchema,
                    let maxTokens = options.maxTokens,
                    await handleRef.modelContainer.configuration.reasoningConfig == nil,
                    mlxMessages.allSatisfy({
                        $0.images.isEmpty && $0.videos.isEmpty && $0.audios.isEmpty
                    })
                {
                    log.info("Routing through GuidedGenerationLoop with grammar constraint")
                    try await handleGuidedGeneration(
                        messagePairs: mlxMessages.map {
                            (role: $0.role.rawValue, content: $0.content)
                        },
                        grammarSchema: schema,
                        maxTokens: maxTokens,
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
                else if self.mtpDrafterContainer != nil, mlxMessages.count > 0,
                    mlxMessages.allSatisfy({
                        $0.images.isEmpty && $0.audios.isEmpty && $0.videos.isEmpty
                    })
                {
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
                        return
                    }
                    let drafterWrapper: MTPDrafterModelWrapper
                    drafterWrapper = await drafterContainer.perform { drafterCtx in
                        MTPDrafterModelWrapper(model: drafterCtx.model)
                    }

                    // Snapshot toolDispatchClosure before entering nonSendable closure to avoid
                    // Swift 6 concurrency warning (var captured in concurrently-executing code).
                    let mtpToolDispatch = toolDispatchClosure

                    let mtpResult = try await handleRef.modelContainer.perform(
                        nonSendable: drafterWrapper
                    ) { context, wrapped in
                        let drafterModel = wrapped.model

                        // All state scoped inside closure — @Sendable compliant
                        var localAccumulatedText = ""
                        var localFirstToken = false
                        var localTokenCount: Int?
                        var localStopReason: StopReason?
                        var localGenerationTokPerSec: Double?
                        var localPromptTokPerSec: Double?
                        // MTP speculative decoding metrics — only populated on MTP path
                        var localProposedDraftTokens: Int?
                        var localAcceptedDraftTokens: Int?
                        var localPassthroughReason: String?
                        var localStoppedBySeq = false

                        // MARK: - MTP Tool Dispatch Loop
                        // Accumulate tool call / result messages across iterations.
                        // Mirrors ChatSession restart-loop: collect tool calls → dispatch →
                        // append tool results → re-prepare input → regenerate.
                        var mtpMessages: [Chat.Message] = messagePairs.map { pair in
                            Chat.Message(
                                role: Chat.Message.Role(rawValue: pair.role) ?? .system,
                                content: pair.content
                            )
                        }
                        // Strip trailing empty assistant message — mirrors upstream MLXChatExample
                        if let last = mtpMessages.last, last.role == .assistant,
                            last.content.isEmpty
                        {
                            mtpMessages.removeLast()
                        }

                        // MARK: - Reasoning setup (shared across loop iterations)
                        // ReasoningEventEmitter: upstream segment router for reasoning
                        // vs response. Only activate when reasoning config is present —
                        // non-reasoning models bypass emitter and pass text through.
                        let reasoningConfig = context.configuration.reasoningConfig

                        // Tool dispatch loop: iterates until model produces no more
                        // tool calls. Mirrors ChatSession.swift L748 restart-loop.
                        // P2-fix: hard iteration cap (10) prevents runaway tool loops
                        // from models stuck in tool-call cycles.
                        var toolCallDetected = false
                        var mtpToolLoopCount = 0
                        let maxMtpToolLoop = 10
                        while mtpToolLoopCount < maxMtpToolLoop {
                            mtpToolLoopCount += 1
                            if Task.isCancelled || cancellation.isCancelled {
                                localStoppedBySeq = true
                                break
                            }

                            // Re-prepare input for each iteration (includes tool results)
                            let mtpProcessing = UserInput.Processing(resize: config.vlmImageResize)
                            let mtpUserInput = UserInput(
                                prompt: .chat(mtpMessages),
                                processing: mtpProcessing,
                                additionalContext: reasoningContext
                            )
                            let mtpInput = try await context.processor.prepare(input: mtpUserInput)

                            // Reset per-iteration state
                            toolCallDetected = false
                            var iterationToolCalls: [MLXLMCommon.ToolCall] = []

                            // Reset reason emitter per iteration — compute primedInside
                            // from rendered prompt tail so it doesn't misroute reasoning blocks.
                            var reasonEmitter: ReasoningEventEmitter?
                            if let rc = reasoningConfig {
                                let tokens = mtpInput.text.tokens.asArray(Int32.self)
                                let renderedTail = context.tokenizer.decode(
                                    tokenIds: tokens.suffix(64).map(Int.init)
                                )
                                let primed = ReasoningEventEmitter.promptEndsInsideReasoning(
                                    renderedPromptTail: renderedTail, config: rc
                                )
                                reasonEmitter = ReasoningEventEmitter(
                                    config: rc, primedInside: primed)
                            }

                            let mtpGenStream = try MLXLMCommon.generate(
                                input: mtpInput,
                                parameters: genParams,
                                context: context,
                                mtpDrafter: drafterModel,
                                blockSize: 4
                            )

                            for try await generation in mtpGenStream {
                                if Task.isCancelled || cancellation.isCancelled {
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
                                    if reasonEmitter != nil {
                                        for segment in reasonEmitter!.process(text) {
                                            switch segment {
                                            case .reasoning(let segmentText):
                                                localAccumulatedText += segmentText
                                                let (shouldBreak, newText) = checkStopSequence(
                                                    segment: segmentText,
                                                    accumulated: localAccumulatedText,
                                                    eventKind: { .reasoning($0) },
                                                    tokenCount: localTokenCount,
                                                    tokenFallback: metrics.generatedTokenCount
                                                )
                                                if shouldBreak {
                                                    localAccumulatedText = newText
                                                    localStoppedBySeq = true
                                                    break
                                                }
                                            case .response(let segmentText):
                                                localAccumulatedText += segmentText
                                                let (shouldBreak, newText2) = checkStopSequence(
                                                    segment: segmentText,
                                                    accumulated: localAccumulatedText,
                                                    eventKind: { .text($0) },
                                                    tokenCount: localTokenCount,
                                                    tokenFallback: metrics.generatedTokenCount
                                                )
                                                if shouldBreak {
                                                    localAccumulatedText = newText2
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
                                            tokenFallback: metrics.generatedTokenCount
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
                                    // SpeculativeDecodingTelemetry carries roundCount, draftTokenCount,
                                    // acceptedDraftTokenCount, targetModelCallCount, draftModelCallCount,
                                    // targetVerifiedTokenCount, emittedTokenCount — full SD telemetry.
                                    _ = completionInfo.speculativeDecodingTelemetry?.roundCount ?? 0
                                case .toolCall(let mlxTC):
                                    // Collect tool calls for dispatch after iteration
                                    iterationToolCalls.append(mlxTC)
                                    let tc = InferenceEvent.mlxToolCall(from: mlxTC)
                                    continuation.yield(.init(kind: .toolCall(tc)))
                                    toolCallDetected = true
                                }
                            }

                            // If no tool calls were detected, or we hit a stop condition, exit the loop
                            guard toolCallDetected && !localStoppedBySeq else { break }

                            // Dispatch collected tool calls and accumulate results
                            for toolCall in iterationToolCalls {
                                // Use toolDispatchClosure if available (dispatches via ToolRegistry)
                                // Otherwise dispatch inline
                                let result: String
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
                                // Append tool result message for next iteration
                                mtpMessages.append(
                                    Chat.Message.tool(result, id: toolCall.id)
                                )
                            }
                        }

                        return MTPResult(
                            accumulatedText: localAccumulatedText,
                            tokenCount: localTokenCount,
                            stopReason: localStopReason,
                            stoppedBySequence: localStoppedBySeq,
                            generationTokPerSec: localGenerationTokPerSec,
                            promptTokPerSec: localPromptTokPerSec,
                            proposedDraftTokens: localProposedDraftTokens,
                            acceptedDraftTokens: localAcceptedDraftTokens,
                            passthroughReason: localPassthroughReason,
                            collectedToolCalls: []
                        )
                    }

                    // Sync MTP result back to outer scope
                    if let tc = mtpResult.tokenCount {
                        actualTokenCount = tc
                    }
                    if let sr = mtpResult.stopReason {
                        lastStopReason = sr
                    }
                    if let generationPS = mtpResult.generationTokPerSec {
                        generationTokPerSec = generationPS
                    }
                    if let ptokPs = mtpResult.promptTokPerSec {
                        promptTokPerSec = ptokPs
                    }
                    if let proposedDraft = mtpResult.proposedDraftTokens {
                        mtpProposedDraftTokens = proposedDraft
                    }
                    if let acceptedDraft = mtpResult.acceptedDraftTokens {
                        mtpAcceptedDraftTokens = acceptedDraft
                    }
                    if let passthrough = mtpResult.passthroughReason {
                        mtpPassthroughReason = passthrough
                    }
                    if !mtpResult.stoppedBySequence, actualTokenCount != nil {
                        continuation.yield(
                            .init(
                                kind: .done(
                                    lastStopReason ?? .maxTokens,
                                    tokenCount: actualTokenCount ?? metrics.generatedTokenCount,
                                    tokPerSec: generationTokPerSec,
                                    promptTokPerSec: promptTokPerSec,
                                    proposedDraftTokens: mtpProposedDraftTokens,
                                    acceptedDraftTokens: mtpAcceptedDraftTokens,
                                    passthroughReason: mtpPassthroughReason)))
                    }
                }
                // MARK: - Standard ChatSession Path (default fallback)
                /// Uses ChatSession.streamDetails for text + multimodal generation.
                else {
                    log.info("Routing through ChatSession for standard generation")

                    // ReasoningEventEmitter: upstream segment router. Only activate when
                    // reasoning config is present — non-reasoning models bypass emitter.
                    // Primed state: when ChatSession pre-fills the opening delimiter (Qwen3, R1),
                    // the emitter must start inside reasoning or it misroutes the entire block.
                    // Since streamDetails renders internally and we can't read LMInput tokens,
                    // infer primedInside from reasoningPromptStrategy — mirrors upstream behavior.
                    let standardReasoningConfig = await handleRef.modelContainer.configuration
                        .reasoningConfig
                    var standardEmitter: ReasoningEventEmitter?
                    if let rc = standardReasoningConfig {
                        // PromptStrategy inference: alwaysOn = model always reasons (primed),
                        // templateFlag with defaultOn = thinking enabled by template (primed),
                        // .none = no reasoning (shouldn't have config, but default false).
                        let primed =
                            switch rc.promptStrategy {
                            case .alwaysOn:
                                true
                            case .templateFlag(_, let defaultOn):
                                defaultOn
                            case .none:
                                false
                            }
                        standardEmitter = ReasoningEventEmitter(config: rc, primedInside: primed)
                    }

                    // Accumulate text across chunks for stop sequence matching
                    // (mirrors MTP path localAccumulatedText at L808)
                    var localStandardAccumulated = ""

                    // ChatSession's KV cache already holds context from previous rounds.
                    // newMessages (set above) contains only what's not yet cached:
                    //   - pool hit  → new user message only
                    //   - pool miss → full history including system instructions
                    for try await generation in chatSession!.streamDetails(
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
                                        StopReason.cancelled, tokenCount: actualTokenCount ?? 0,
                                        tokPerSec: cancelTokPerSec)))
                            break
                        }
                        switch generation {
                        case .chunk(let text):
                            if actualTokenCount == nil {
                                metrics.firstTokenMs = metrics.overallMs
                            }
                            metrics.incrementGenerated()
                            // Conditionally route through emitter if reasoning config present
                            if standardEmitter != nil {
                                for segment in standardEmitter!.process(text) {
                                    switch segment {
                                    case .reasoning(let segmentText):
                                        localStandardAccumulated += segmentText
                                        let (shouldBreakS1, newTextS1) = checkStopSequence(
                                            segment: segmentText,
                                            accumulated: localStandardAccumulated,
                                            eventKind: { .reasoning($0) },
                                            tokenCount: actualTokenCount,
                                            tokenFallback: metrics.generatedTokenCount
                                        )
                                        if shouldBreakS1 {
                                            localStandardAccumulated = newTextS1
                                            lastStopReason = .stopSequence
                                            break
                                        }
                                    case .response(let segmentText):
                                        localStandardAccumulated += segmentText
                                        let (shouldBreakS2, newTextS2) = checkStopSequence(
                                            segment: segmentText,
                                            accumulated: localStandardAccumulated,
                                            eventKind: { .text($0) },
                                            tokenCount: actualTokenCount,
                                            tokenFallback: metrics.generatedTokenCount
                                        )
                                        if shouldBreakS2 {
                                            localStandardAccumulated = newTextS2
                                            lastStopReason = .stopSequence
                                            break
                                        }
                                    }
                                }
                            } else {
                                // No reasoning config — pass through as plain text
                                localStandardAccumulated += text
                                let (shouldBreakS3, newTextS3) = checkStopSequence(
                                    segment: text,
                                    accumulated: localStandardAccumulated,
                                    eventKind: { .text($0) },
                                    tokenCount: actualTokenCount,
                                    tokenFallback: metrics.generatedTokenCount
                                )
                                if shouldBreakS3 {
                                    localStandardAccumulated = newTextS3
                                    lastStopReason = .stopSequence
                                    break
                                }
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
                        case .toolCall(let mlxTC):
                            let tc = InferenceEvent.mlxToolCall(from: mlxTC)
                            continuation.yield(.init(kind: .toolCall(tc)))
                        }
                    }

                    // Emit any tool calls intercepted by ChatSession's internal
                    // tool loop (L780). When toolDispatch was set, ChatSession
                    // internally collects & dispatches tools — the caller never
                    // sees .toolCall in streamDetails. Track-and-emit ensures
                    // downstream consumers (ChatHandler, DirectInferenceClient)
                    // still receive tool call events for telemetry/UI.
                    let trackedCalls = await tracker.fetch()
                    for mlxTC in trackedCalls {
                        let tc = InferenceEvent.mlxToolCall(from: mlxTC)
                        continuation.yield(.init(kind: .toolCall(tc)))
                    }

                    // Emit final .done event with prompt throughput
                    if !Task.isCancelled {
                        continuation.yield(
                            .init(
                                kind: .done(
                                    lastStopReason ?? .eos,
                                    tokenCount: actualTokenCount ?? metrics.generatedTokenCount,
                                    tokPerSec: generationTokPerSec,
                                    promptTokPerSec: promptTokPerSec)))
                    }
                }

            }

            // pool.release is handled by defer in `if let pool = poolRef { ... }` block above.
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
                try await runInferenceBody()
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
            try await runInferenceBody()
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
}

// MARK: - Tool Call Tracking

/// Thread-safe tracker for tool calls intercepted by ChatSession's internal loop.
/// When `toolDispatch` is set on ChatSession, `.toolCall` events are consumed internally
/// and never reach `streamDetails` (ChatSession.swift L780). This actor records each
/// intercepted call so we can re-emit them downstream after the stream completes.
actor _InterceptedToolCallTracker {
    private var calls: [MLXLMCommon.ToolCall] = []

    func record(_ call: MLXLMCommon.ToolCall) {
        calls.append(call)
    }

    func fetch() -> [MLXLMCommon.ToolCall] {
        calls
    }
}
