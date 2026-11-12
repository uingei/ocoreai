// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineInferenceGuided.swift — the grammar-constrained guided lane, as an EnginePool method
///
/// Extracted from ``EngineInference.swift`` (god-file decomposition, step 2 after
/// ``EngineInferenceSupport.swift``). This lane was a nested function inside
/// `_runInferenceWithMessages` reaching its inputs through implicit captures; it is now a
/// real method whose parameters name every input, so the unit reads and changes apart from
/// the host. Move only, no logic change — the three file-private diagnostics helpers travel
/// with it because its call sites are their only callers.

import Foundation
import Logging
import MLX
import MLXGuidedGeneration
import MLXLMCommon

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

extension EnginePool {
    // handleGuidedGeneration: MLXGuidedGeneration grammar-constrained path
    /// Bridges GuidedGenerationLoop (sync emit callback) → SSE continuation.
    /// All inference within modelContainer.perform for thread-safe ModelContext.
    ///
    /// The parameters are the host's locals at the extraction point (`handleRef`/`log` were
    /// already hoisted there for the closure); `config` stays `self.config`, the Sendable
    /// `let` the perform closure already read through the nested function's implicit self.
    func handleGuidedGeneration(
        messagePairs: [(role: String, content: String)],
        instructions: String?,
        grammarSchema: String,
        maxTokens: Int,
        toolSpecs: [ToolSpec]? = nil,
        handleRef: any MLXModelHandle,
        loaded: LoadedModel,
        genParams: MLXLMCommon.GenerateParameters,
        requestStopSequences: [String],
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation,
        cancellation: InferenceCancellation,
        metrics: PerRequestMetrics,
        log: Logger,
        modelId: String,
    ) async throws {
        try await handleRef.modelContainer.perform { context in
            // Rebuild Chat.Message inside the @Sendable closure to avoid
            // cross-actor capture of non-Sendable [Chat.Message].
            // This lane prepares its own LMInput, so the instructions are in this list
            // or they are not in the prompt at all.
            var messages = promptMessagesCarryingInstructions(
                messagePairs.map { pair in
                    Chat.Message(
                        role: Chat.Message.Role(rawValue: pair.role) ?? .system,
                        content: pair.content
                    )
                },
                instructions: instructions
            )
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
            // Declare the tools this grammar constrains. Without `tools:` the
            // chat template renders no tool block, so the model was forced into
            // a call shape it had never been shown — the schema said what a call
            // looks like while nothing said which tools exist, what they do, or
            // what their arguments mean (10-18: the guided path built
            // `UserInput(prompt:.chat(...))` with no tools at all).
            let userInput = UserInput(
                prompt: .chat(messages), processing: uiProcessing, tools: toolSpecs)
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
                // Terminal for this turn — the caller returns after the guided
                // branch, so the stream must close here (it used to be closed by
                // accident, via the fall-through into the standard path).
                continuation.finish()
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
                continuation.finish()
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
            // Clamped to the budget — a reserve that meets or exceeds maxTokens
            // puts every step in the force-closing zone and corrupts small-budget
            // structured calls (see `guidedCompletionReserves`).
            let reserves = guidedCompletionReserves(
                maxTokens: maxTokens, structuralReserve: structuralReserve)
            let completionReserve = reserves.completion
            let hardReserve = reserves.hard

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
                        // respect grammar lifecycle — upstream GuidedGenerationLoop.run()
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
                // 上游 canonical 对齐 (MLXFoundationModels/MLXLanguageModel.swift:1386/1704):
                // incompleteOutput(预算耗尽语法未终止) → 保留已流式产出的部分文本,
                // 转 `.success` 终态照常收尾, 不 500(活体: Qwen3.5-4B sampled=2792
                // finalBuf=nil → 旧行为硬 500 全丢)。prematureEOS/其它错误照抛。
                let absorbed = absorbGuidedGenerationPartialOutput(
                    error: error,
                    sink: diagnosticSink,
                    accumulatedText: guidedAccumulated)
                if absorbed {
                    diagnosticResult = .success(
                        tokenCount: diagnosticSink.generatedTokenCount,
                        sink: diagnosticSink)
                    // The `.success` block above sits before this catch, so once the
                    // loop throws it is skipped: absorbing the partial output left the
                    // stream without any `.done`, and ChatHandler kept its default
                    // `finish_reason: "stop"` for a turn whose grammar never
                    // terminated (live 10-13: `json_schema` + max_tokens=24 returned
                    // corrupt partial text as a completed turn). Emit the same two
                    // events, in the same order, as the success path.
                    continuation.yield(
                        .init(
                            kind: .guidedGenDiagnostic(
                                grammarTerminated: diagnosticSink.grammarTerminated,
                                incompleteOutput: diagnosticSink.incompleteOutput)))
                    let absorbedTokens = diagnosticSink.generatedTokenCount
                    let absorbedTokPerSec =
                        absorbedTokens > 0
                        ? Double(absorbedTokens) / (Double(metrics.overallMs) / 1000.0)
                        : nil
                    continuation.yield(
                        .init(
                            kind: .done(
                                diagnosticSink.grammarTerminated ? .eos : .maxTokens,
                                tokenCount: absorbedTokens,
                                tokPerSec: absorbedTokPerSec,
                                promptTokPerSec: nil,
                                reasoningTokenCount: 0)))
                    doneAlreadyYielded = true
                } else {
                    // emit .done before throwing — prevents continuation leak.
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

            // The guided branch OWNS this turn's stream, so it closes it here.
            // Before this, nothing finished the continuation, and control fell
            // through into the standard ChatSession path below — whose pooled
            // session had already been released at the top of the guided branch
            // — which logged "Standard ChatSession path entered with nil
            // chatSession" and emitted a spurious `.error`. Live consequence
            // (2026-10-12, macOS 26, gemma-4-e2b-it-4bit): a grammar-constrained
            // turn that generated successfully still returned
            // `500 Engine internal error: no active chat session` — every
            // `response_format: json_schema` request and every tool-declared turn
            // that took the guided path. `finish()` is idempotent, so the
            // error paths that already terminated are unaffected.
            continuation.finish()
        }
    }
}
