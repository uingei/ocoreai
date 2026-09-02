// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// completions_handler.swift — OpenAI-compatible text completion handler
///
/// Thin handler over the shared inference pipeline (POST /v1/completions).
/// Reuses the SAME stages as ``chatCompletionsHandler`` (model resolve, content
/// guard, prompt-injection, scheduler admission, engine acquire, 3-layer sampling
/// fallback, stream/non-stream dispatch) MINUS chat-specific machinery (tools,
/// message-builder system prompt, persistence, self-correction).
///
/// Prompt semantics (A1 / P1): each prompt is wrapped as a single user message
/// and generated through ``handle/generateFromMessages(_:sampling:options:conversationId:cancellation:)`` —
/// the exact same pipeline the green chat endpoint already uses. That is the
/// "thin handler reusing the pipeline" path (不造轮子). The true raw-text /
/// no-chat-template MLX entry (vllm /v1/completions semantics;
/// mlx-swift-lm `UserInput(.text)`) is the post-monolith-split batch — it
/// touches the 1,857-line `runInferenceBody`, which is deliberately NOT modified
/// here.
///
/// P1 boundary (documented, no expansion):
/// - `n > 1`: accepted, generated sequentially (one pass per choice).
/// - `echo` / `suffix` / `logprobs` / `logprob_token_ids` / `min_tokens` /
///   `skip_special_tokens`: decoded for wire parity, no-op. (True `logprobs`
///   value = A2 — coreai-models loglikelihood, separate batch.)
///
/// Wire shape (source: vllm `completion/protocol.py` 345-610 @ cdefd9d4):
/// `object="text_completion"`, `id="cmpl-*"`, `choices[].text`, `finish_reason`,
/// `usage`. Streaming = SSE `data: {CompletionChunk}` … `data: [DONE]`.

import Foundation
import HTTPTypes
import Hummingbird
import Logging

// MARK: - Top-level handler

/// Handle `POST /v1/completions` (text completion, stream or non-stream).
///
/// - Parameters:
///   - request: Decoded ``CompletionRequest``
///   - enginePool: Engine pool for concurrent inference
///   - scheduler: OOM-guard + priority admission
///   - metrics: Shared Prometheus metrics registry
///   - logger: Observability logger
/// - Returns: SSE ``Response`` (stream) or JSON ``Response`` (non-stream)
func completionsHandler(
    request: CompletionRequest,
    enginePool: EnginePool,
    scheduler: SchedulerActor,
    metrics: MetricsRegistry,
    logger: Logger,
) async throws -> Response {
    /// Normalize prompts; reject empty / all-blank.
    let prompts = request.prompt.filter {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !prompts.isEmpty else {
        throw AppError.invalidRequest(
            "Prompt must be a non-empty string or a non-empty array of strings.")
    }
    let n = max(1, request.n)

    /// Resolve model (per-model default, else 400 — parity with chat).
    let fallbackModel = await enginePool.defaultModelId()
    guard let modelId = resolveModel(requested: request.model, defaultModelId: fallbackModel) else {
        throw AppError.invalidRequest(
            "Missing 'model' field and no default model is configured. "
                + "Set a default via PATCH /v1/models/:model/sampling with {\"default_model\": true}."
        )
    }

    /// Content-safety input guard (parity with chat).
    if let contentGuard = await OcoreaiEngine.shared.activeContentGuard {
        let text = prompts.joined(separator: " ")
        let result = await contentGuard.checkInput(text)
        if result.isBlocked {
            return try completionsBlockedResponse(
                reason: result.rejectionReason,
                categories: result.triggeredCategories,
            )
        }
    }

    /// Prompt-injection detection (parity with chat).
    if AuthConfig.default.promptInjectionEnabled {
        let msgs = prompts.map { Message(role: "user", content: $0) }
        if AuthConfig.detectPromptInjection(
            in: msgs, patterns: AuthConfig.defaultPromptInjectionRegexes)
        {
            throw AppError.invalidRequest("Potential prompt injection detected")
        }
    }

    /// A2 loglikelihood — `logprobs` requests score per-token log probabilities
    /// (coreai-models CompletionHandler contract) rather than generate.
    /// `#if canImport(CoreAI)` guards the engine-side path: outside CoreAI the
    /// wire still accepts the field (parity) and 501s via `AppError.logitsUnsupported`.
    if request.logprobs != nil {
        #if canImport(CoreAI)
        if #available(macOS 27.0, iOS 27.0, *) {
            return try await completionsLoglikelihood(
                enginePool: enginePool,
                prompts: prompts,
                request: request,
                modelId: modelId,
                logger: logger,
            )
        }
        throw AppError.logitsUnsupported
        #else
        throw AppError.logitsUnsupported
        #endif
    }

    /// Scheduler admission (parallelism + OOM gate).
    let schedulingRequest = SchedulingRequest(
        id: "req-\(UUID().uuidString.prefix(8))",
        priority: .chat,
        modelId: modelId,
        prompt: prompts.first ?? "",
        tokenBudget: request.maxTokens ?? 4096,
    )
    do {
        let dispatched = try await scheduler.submitAndDispatch(schedulingRequest)
        guard dispatched != nil else {
            await scheduler.fail(
                schedulingRequest.id, with: "Higher-priority request dispatched first")
            throw AppError.engineUnavailable
        }
    } catch let e as SchedulerError {
        await scheduler.fail(schedulingRequest.id, with: e.localizedDescription)
        switch e {
        case .queueFull:
            throw AppError.poolExhausted(0)
        default:
            throw AppError.engineUnavailable
        }
    }

    /// Acquire engine handle.
    let handle: EngineHandle
    do {
        handle = try await enginePool.acquire(model: modelId)
    } catch {
        await scheduler.fail(schedulingRequest.id, with: error.localizedDescription)
        throw AppError.engineUnavailable
    }

    /// Sampling: 3-layer fallback (request > runtime > system), mirror chat Phase 4.
    let runtimeDefaults = await enginePool.getSamplingConfig(modelId: modelId)
    let effectiveTemp: Float = request.temperature
    let effectiveTopP = request.topP ?? runtimeDefaults.topP
    let effectiveTopK = request.topK ?? runtimeDefaults.topK
    let effectiveMinP = request.minP ?? runtimeDefaults.minP
    let effectiveMaxTokens = request.maxTokens ?? runtimeDefaults.maxTokens
    let effectiveSeed = request.seed ?? runtimeDefaults.seed
    let effectivePresencePenalty =
        request.presencePenalty != 0 ? request.presencePenalty : runtimeDefaults.presencePenalty
    let effectiveFrequencyPenalty =
        request.frequencyPenalty != 0 ? request.frequencyPenalty : runtimeDefaults.frequencyPenalty
    let effectiveRepetitionPenalty =
        request.repetitionPenalty ?? runtimeDefaults.repetitionPenalty
    let effectiveRepetitionPenaltyWindow =
        request.repetitionPenaltyWindow ?? runtimeDefaults.repetitionPenaltyWindow

    let rawSampling = SamplingConfiguration(
        seed: effectiveSeed,
        temperature: Double(effectiveTemp),
        topP: effectiveTopP.map(Double.init),
        topK: effectiveTopK,
        mode: runtimeDefaults.mode,
        minP: effectiveMinP.map(Double.init),
        repetitionPenalty: effectiveRepetitionPenalty,
        repetitionPenaltyWindow: effectiveRepetitionPenaltyWindow,
        presencePenalty: Double(effectivePresencePenalty),
        frequencyPenalty: Double(effectiveFrequencyPenalty),
        stopSequences: request.stop,
        logitBias: nil,
        combined: true,
        prefill: .init(stepSize: nil, chunking: runtimeDefaults.prefill.chunking),
        maxKVSize: nil,
        repetitionContextSize: runtimeDefaults.repetitionContextSize,
        presenceContextSize: runtimeDefaults.presenceContextSize,
        frequencyContextSize: runtimeDefaults.frequencyContextSize,
    )
    let sampling = rawSampling.normalized()

    let options = InferenceOptions(
        maxTokens: effectiveMaxTokens,
        includeLogits: false,
        useGuidedGeneration: false,
        grammarSchema: nil,
        enableReasoning: false,
        reasoningLevel: nil,
        reasoningEffort: nil,
    )

    /// Prompt token count (metrics) — tokenize or CJK-heuristic (chat Phase 3).
    var promptTokenCount: Int
    do {
        let first = prompts.map { Message(role: "user", content: $0) }
        let tok = try await handle.tokenize(messages: first)
        promptTokenCount = max(1, tok.count)
    } catch {
        let totalBytes = prompts.reduce(0) { $0 + $1.utf8.count }
        let totalChars = prompts.reduce(0) { $0 + $1.count }
        let avg = totalChars > 0 ? Double(totalBytes) / Double(totalChars) : 1.0
        let divisor = avg > 1.5 ? 3 : 4
        promptTokenCount = max(1, Int(Double(totalBytes) / Double(divisor)))
    }

    /// Dispatch stream / non-stream; structured cleanup on both paths.
    var result: Response?
    do {
        if request.stream {
            result = try await completionsStream(
                handle: handle,
                prompts: prompts,
                n: n,
                promptTokenCount: promptTokenCount,
                sampling: sampling,
                options: options,
                request: request,
                modelId: modelId,
                logger: logger,
                metrics: metrics,
            )
        } else {
            result = try await completionsNonStream(
                handle: handle,
                prompts: prompts,
                n: n,
                promptTokenCount: promptTokenCount,
                sampling: sampling,
                options: options,
                request: request,
                modelId: modelId,
                logger: logger,
                metrics: metrics,
            )
        }
    } catch {
        await handle.release()
        await scheduler.complete(schedulingRequest.id)
        throw error
    }

    /// Cleanup on success.
    await handle.release()
    await scheduler.complete(schedulingRequest.id)
    guard let finalResult = result else {
        logger.error("Completions pipeline produced no response")
        throw AppError.inferenceFailed("No response generated")
    }
    return finalResult
}

// MARK: - Single-pass text generation (shared primitive)

/// Generate one text completion for a single prompt.
///
/// - Parameters:
///   - handle: Acquired engine handle
///   - prompt: Raw text prompt
///   - sampling: Normalized sampling configuration
///   - options: Inference options (maxTokens, etc.)
///   - logger: Observability logger
///   - onText: Streaming sink (per decoded text chunk); no-op for non-stream
/// - Returns: `(accumulated text, output token count, finish reason)`
private func generateTextCompletion(
    handle: EngineHandle,
    prompt: String,
    sampling: SamplingConfiguration,
    options: InferenceOptions,
    logger: Logger,
    cancellation: InferenceCancellation = .none,
    onText: @Sendable (String) async -> Void = { _ in },
) async throws -> (text: String, outputTokens: Int, finishReason: String) {
    let messages = [Message(role: "user", content: prompt)]
    let stream = handle.generateFromMessages(
        messages: messages,
        sampling: sampling,
        options: options,
        cancellation: cancellation,
    )

    var acc = ""
    var tokens = 0
    var finish = "stop"
    for try await event in stream {
        switch event.kind {
        case .token:
            tokens += 1
        case .text(let t):
            acc += t
            tokens += 1
            await onText(t)
        case .done(let reason, let tokenCount, let promptTokenCount, _, _, _, _, _, _):
            if let tokenCount {
                tokens = tokenCount
            }
            finish = stopReasonToString(reason) ?? "stop"
        case .reasoning(let r):
            acc += r
        case .error(let msg):
            throw AppError.generationError(msg)
        default:
            break
        }
    }
    return (acc, tokens, finish)
}

// MARK: - Non-streaming

private func completionsNonStream(
    handle: EngineHandle,
    prompts: [String],
    n: Int,
    promptTokenCount: Int,
    sampling: SamplingConfiguration,
    options: InferenceOptions,
    request: CompletionRequest,
    modelId: String,
    logger: Logger,
    metrics: MetricsRegistry,
) async throws -> Response {
    let created = Int64(Date().timeIntervalSince1970)
    let requestId = "cmpl-\(UUID().uuidString.prefix(24))"
    let startTime = ContinuousClock.now

    /// Mark session active (resets KV-cache idle eviction timer).
    await handle.markActive()

    /// Sequential generation: each prompt × `n` choices (P1 boundary).
    var choices: [TextCompletionChoice] = []
    var totalOutputTokens = 0
    var choiceIdx = 0
    for prompt in prompts {
        for _ in 0 ..< n {
            let (text, outTok, finish) = try await generateTextCompletion(
                handle: handle,
                prompt: prompt,
                sampling: sampling,
                options: options,
                logger: logger,
            )
            totalOutputTokens += outTok
            choices.append(
                TextCompletionChoice(text: text, finishReason: finish, index: choiceIdx))
            choiceIdx += 1
        }
    }

    /// Record inference metrics.
    let dur = startTime.duration(to: ContinuousClock.now)
    let elapsed = Double(dur.components.seconds) * 1000 + Double(dur.components.attoseconds) / 1e15
    await metrics.observeInferenceDuration(elapsed / 1000.0)
    await metrics.incrementTokens(kind: "generated", count: totalOutputTokens)
    await metrics.incrementTokens(kind: "prompt", count: promptTokenCount)

    let response = TextCompletionResponse(
        id: requestId,
        created: created,
        model: modelId,
        choices: choices,
        usage: Usage(input: promptTokenCount, output: totalOutputTokens),
    )

    var headers: HTTPFields = [:]
    headers[.contentType] = "application/json"
    let body = try JSONEncoder().encode(response)
    return Response(
        status: .ok,
        headers: headers,
        body: .init(contentsOf: [ByteBuffer(data: body)]),
    )
}

// MARK: - Streaming

private func completionsStream(
    handle: EngineHandle,
    prompts: [String],
    n: Int,
    promptTokenCount: Int,
    sampling: SamplingConfiguration,
    options: InferenceOptions,
    request: CompletionRequest,
    modelId: String,
    logger: Logger,
    metrics: MetricsRegistry,
) async throws -> Response {
    let created = Int64(Date().timeIntervalSince1970)
    let requestId = "cmpl-\(UUID().uuidString.prefix(24))"
    let includeUsage = request.streamOptions?.includeUsage ?? false

    /// SSE-compliant stream + client-disconnect → inference cancellation bridge.
    let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()
    let canceller = InferenceCancellation.cancellable()
    continuation.onTermination = { @Sendable _ in
        canceller.cancel()
    }

    _ = Task {
        /// Streaming output safety guard (mirror chat `streamWithToolCalling`).
        let streamGuard = await OcoreaiEngine.shared.activeContentGuard
        await handle.markActive()
        var choiceIdx = 0
        do {
            for prompt in prompts {
                for _ in 0 ..< n {
                    /// Freeze the choice index as a `let` so the @Sendable sink
                    /// captures no mutable state.
                    let idx = choiceIdx
                    let (text, outTok, finish) = try await generateTextCompletion(
                        handle: handle,
                        prompt: prompt,
                        sampling: sampling,
                        options: options,
                        logger: logger,
                        cancellation: canceller,
                        onText: { chunk in
                            /// Output safety check per chunk — block → notify + stop GPU work.
                            if let guardRef = streamGuard {
                                let checkResult = await guardRef.checkOutput(chunk)
                                if !checkResult.passed {
                                    logger.warning(
                                        "Completions stream output blocked: \(checkResult.triggeredCategories)"
                                    )
                                    yieldSSERaw(
                                        "[SSEError: Output blocked by content guard: \(checkResult.rejectionReason ?? "Safety violation")]",
                                        to: continuation,
                                    )
                                    canceller.cancel()
                                    return
                                }
                            }
                            let c = CompletionChunk(
                                id: requestId,
                                created: created,
                                model: modelId,
                                choices: [
                                    CompletionChunkChoice(
                                        text: chunk, finishReason: nil, index: idx)
                                ],
                            )
                            _ = yieldSSE(c, to: continuation)
                        },
                    )

                    /// Stop chunk — finish_reason (and usage when requested).
                    let stopChunk = CompletionChunk(
                        id: requestId,
                        created: created,
                        model: modelId,
                        choices: [
                            CompletionChunkChoice(
                                text: "", finishReason: finish, index: idx)
                        ],
                        usage: includeUsage
                            ? Usage(
                                input: promptTokenCount, output: outTok) : nil,
                    )
                    _ = yieldSSE(stopChunk, to: continuation)
                    _ = text  // final text retained for parity; not in wire today
                    choiceIdx += 1
                }
            }
            yieldSSERaw("[DONE]", to: continuation)
        } catch {
            yieldSSERaw("[SSEError: \(error.localizedDescription)]", to: continuation)
        }
        continuation.finish()
    }

    return Response(
        status: .ok,
        headers: SSEHeaders,
        body: .init(asyncSequence: stream),
    )
}

// MARK: - Content-guard 400 body (shared helper)

/// Build the JSON 400 body for a blocked input (content-safety violation).
private func completionsBlockedResponse(
    reason: String?,
    categories: [SafetyCategory],
) throws -> Response {
    let detail = NSDictionary(dictionary: [
        "message": reason ?? "Content safety violation",
        "type": "content_policy_violation",
        "code": 400,
        "categories": categories.map(\.rawValue),
    ])
    let errorBody = NSDictionary(dictionary: ["error": detail])
    guard let data = try? JSONSerialization.data(withJSONObject: errorBody, options: []) else {
        return Response(status: .badRequest)
    }
    var headers: HTTPFields = [:]
    headers[.contentType] = "application/json"
    return Response(
        status: .badRequest,
        headers: headers,
        body: .init(contentsOf: [ByteBuffer(data: data)]),
    )
}

// MARK: - A2 loglikelihood (coreai-models CompletionHandler contract)

/// Engine-side gate: `EnginePool.collectLogits` (and its result type) exist
/// only inside `#if canImport(CoreAI)` (EngineLogprobs.swift) — so does this.
#if canImport(CoreAI)

/// Score per-token log probabilities for each prompt — the A2 wire form of
/// `logprobs` on `POST /v1/completions` (upstream coreai-models b11ac19,
/// `handleLoglikelihood` L66-111: topN clamp, sequential per-prompt scoring,
/// `object="text_completion"`, `finish_reason="stop"`).
///
/// Thin handler: all engine work delegates to ``EnginePool/collectLogits``
/// (engine-side contract in EngineLogprobs.swift, copy-first from upstream).
@available(macOS 27.0, iOS 27.0, *)
private func completionsLoglikelihood(
    enginePool: EnginePool,
    prompts: [String],
    request: CompletionRequest,
    modelId: String,
    logger: Logger,
) async throws -> Response {
    let created = Int64(Date().timeIntervalSince1970)
    let requestId = "cmpl-\(UUID().uuidString.prefix(24))"

    /// Upstream L74: `topN = min(logprobs ?? 1, 20)`.
    let topN = min(request.logprobs ?? 1, 20)
    let wantsEcho = request.echo

    var choices: [TextCompletionChoice] = []
    var totalPromptTokens = 0
    var choiceIdx = 0
    for prompt in prompts {
        let r = try await enginePool.collectLogits(
            modelId: modelId,
            text: prompt,
            topN: topN,
            echo: wantsEcho,
        )
        totalPromptTokens += r.promptTokens
        choices.append(
            TextCompletionChoice(
                text: r.text, finishReason: "stop", index: choiceIdx, logprobs: r.logprobs))
        choiceIdx += 1
    }

    let response = TextCompletionResponse(
        id: requestId,
        created: created,
        model: modelId,
        choices: choices,
        usage: Usage(input: totalPromptTokens, output: 0),
    )

    var headers: HTTPFields = [:]
    headers[.contentType] = "application/json"
    let body = try JSONEncoder().encode(response)
    logger.debug(
        "loglikelihood: \(prompts.count) prompt(s), topN=\(topN), echo=\(wantsEcho)")
    return Response(
        status: .ok,
        headers: headers,
        body: .init(contentsOf: [ByteBuffer(data: body)]),
    )
}
#endif
