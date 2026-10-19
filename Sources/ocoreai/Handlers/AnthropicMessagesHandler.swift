// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AnthropicMessagesHandler.swift — Anthropic Messages API handler
///
/// Handles ``POST /v1/messages`` by converting Anthropic format → internal
/// ``ChatCompletionRequest`` → inference pipeline → Anthropic response envelope.
///
/// ### Conversion Flow:
/// 1. Decode ``AnthropicMessageRequest``
/// 2. Convert to ``ChatCompletionRequest`` via ``toChatCompletionRequest()``
/// 3. Reuse existing ``chatCompletionsHandler`` (or inline logic to avoid double SSE)
/// 4. Map response back to ``AnthropicMessageResponse`` / SSE stream
///
/// ### Key Mapping:
/// | Anthropic | Internal | OpenAI |
/// |-----------|----------|--------|
/// | stop_reason | finish_reason | finish_reason |
/// | end_turn | — | stop |
/// | max_tokens | — | length |
/// | tool_use | — | tool_calls |

import Foundation
import HTTPTypes
import Hummingbird
import Logging

#if canImport(CoreAI)
import CoreAI
#endif

// MARK: - Main Handler

/// Handle an Anthropic Messages API request.
///
/// Converts Anthropic request → internal pipeline → Anthropic response.
/// Supports both streaming and non-streaming modes.
///
/// - Parameters:
///   - request: Anthropic message request
///   - enginePool: Engine pool for inference
///   - metrics: Shared metrics registry
///   - sessionCompressor: Session persistence layer
///   - systemPromptBuilder: System prompt assembly (skills injection)
///   - logger: Observability logger
/// - Returns: HTTP Response (SSE stream or JSON)
func anthropicMessagesHandler(
    request: AnthropicMessageRequest,
    enginePool: EnginePool,
    scheduler: SchedulerActor,
    metrics: MetricsRegistry,
    sessionCompressor _: SessionCompressor,
    semanticSearch _: SemanticSearch?,
    systemPromptBuilder _: SystemPromptBuilder,
    logger: Logger,
) async throws -> Response {
    /// Numeric domain gate, first line — the Anthropic sibling of the one in
    /// ``chatCompletionsHandler``. Before this, a negative `max_tokens` on this wire reached
    /// the scheduler and trapped the process (measured 10-17); a spec-invalid value now comes
    /// back 400 naming the field and Anthropic's own range (`temperature` is [0, 1] here).
    if let error = request.numericDomainError() {
        throw error
    }

    let modelId = request.model

    // Capture content guard early — used for both input and output safety
    let streamGuard: ContentGuard? = await OcoreaiEngine.shared.activeContentGuard

    // Safety check: filter harmful input before scheduling
    if let contentGuard = streamGuard {
        // One reader of "what text did the client send", shared with the prompt the model
        // gets (`AnthropicMessage.plainText`) — the guard and the prompt must not disagree.
        let messageText: String = request.messages.first?.plainText ?? ""
        if !messageText.isEmpty {
            let result = await contentGuard.checkInput(messageText)
            if result.isBlocked {
                let detail = NSDictionary(dictionary: [
                    "message": result.rejectionReason ?? "Content safety violation",
                    "type": "content_policy_violation",
                    "code": 400,
                    "categories": result.triggeredCategories.map(\.rawValue),
                ])
                let errorBody = NSDictionary(dictionary: ["error": detail])
                guard let data = try? JSONSerialization.data(withJSONObject: errorBody, options: [])
                else {
                    return Response(status: .badRequest)
                }
                var headers: HTTPFields = [:]
                headers[.contentType] = "application/json"
                return Response(
                    status: .badRequest, headers: headers,
                    body: .init(contentsOf: [ByteBuffer(data: data)]))
            }
        }
    }

    // Prompt injection detection — uses precompiled regex from AuthConfig
    if AuthConfig.default.promptInjectionEnabled {
        // Convert Anthropic messages to internal Message for detection
        let chatReq = try toChatCompletionRequest(request)
        if AuthConfig.detectPromptInjection(
            in: chatReq.messages,
            patterns: AuthConfig.defaultPromptInjectionRegexes,
        ) {
            let detail = NSDictionary(dictionary: [
                "message": "Potential prompt injection detected",
                "type": "prompt_injection",
                "code": 400,
            ])
            let errorBody = NSDictionary(dictionary: ["error": detail])
            guard let data = try? JSONSerialization.data(withJSONObject: errorBody, options: [])
            else {
                return Response(status: .badRequest)
            }
            var headers: HTTPFields = [:]
            headers[.contentType] = "application/json"
            return Response(
                status: .badRequest, headers: headers,
                body: .init(contentsOf: [ByteBuffer(data: data)]))
        }
    }

    // ═══════════════════════════════════════════════════════
    // Convert Anthropic → internal ChatCompletionRequest
    // ═══════════════════════════════════════════════════════
    let chatRequest = try toChatCompletionRequest(request)

    // ═══════════════════════════════════════════════════════
    // Phase 1: Submit to scheduler (OOMGuard + priority queue)
    // ═══════════════════════════════════════════════════════
    let promptText: String = request.messages.first?.plainText ?? ""

    let schedulingRequest = SchedulingRequest(
        id: "msg-\(UUID().uuidString.prefix(8))",
        priority: .chat,
        modelId: modelId,
        prompt: promptText,
        tokenBudget: request.maxTokens ?? 4096,
    )
    do {
        let dispatched = try await scheduler.submitAndDispatch(schedulingRequest)
        guard dispatched != nil else {
            // Higher-priority request dispatched instead — ours still in queue.
            // Clean up scheduler state to prevent orphaned .pending entry.
            await scheduler.fail(
                schedulingRequest.id, with: "Higher-priority request dispatched first")
            throw AppError.engineUnavailable
        }
    } catch let e as SchedulerError {
        await scheduler.fail(schedulingRequest.id, with: e.localizedDescription)
        switch e {
        case .admissionRefused:
            throw AppError.engineUnavailable
        case .oomRefused(let used, let budget):
            throw AppError.memoryExhausted(usedGB: used, budgetGB: budget)
        case .queueFull:
            throw AppError.poolExhausted(0)
        default:
            throw AppError.engineUnavailable
        }
    }

    // ═══════════════════════════════════════════════════════
    // Phase 1b: Acquire engine handle
    // ═══════════════════════════════════════════════════════
    let handle: EngineHandle
    do {
        handle = try await enginePool.acquire(model: modelId)
    } catch let e as AppError {
        await scheduler.fail(schedulingRequest.id, with: e.localizedDescription)
        throw e
    } catch {
        await scheduler.fail(schedulingRequest.id, with: error.localizedDescription)
        throw AppError.engineUnavailable
    }
    defer {
        Task {
            await handle.release()
            await scheduler.complete(schedulingRequest.id)
        }
    }

    // ═══════════════════════════════════════════════════════

    // Phase 2: Build messages + input token count
    // ═══════════════════════════════════════════════════════
    let fullMessages = try buildAnthropicMessageList(request: request)

    /// Input token count (metrics) — tokenize or CJK-heuristic (chat Phase 3).
    /// On the MLX axis the tokenizer registry is empty (real tokenizer lives in
    /// the engine), so we gracefully fall back to a character-based estimate
    /// instead of blocking the request — same discipline as Chat/Completions.
    var inputTokenCount: Int
    do {
        let tok = try await handle.tokenize(messages: fullMessages)
        inputTokenCount = max(1, tok.count)
    } catch {
        logger.warning(
            "Tokenization failed, using heuristic estimate for metrics — \(error.localizedDescription)"
        )
        inputTokenCount = estimatePromptTokensFallback(fullMessages)
    }

    guard inputTokenCount > 0 else {
        throw AppError.invalidRequest("Empty prompt for model '\(modelId)'")
    }

    // ═══════════════════════════════════════════════════════
    // Phase 3: Parameter fallback chain
    // ═══════════════════════════════════════════════════════
    let runtimeDefaults = await enginePool.getSamplingConfig(modelId: modelId)

    let effectiveTemp: Float = request.temperature ?? runtimeDefaults.temperature

    let effectiveTopP = request.topP ?? runtimeDefaults.topP
    let effectiveTopK = request.topK ?? runtimeDefaults.topK
    let effectiveMaxTokens = request.maxTokens ?? runtimeDefaults.maxTokens

    let rawSampling = SamplingConfiguration(
        temperature: Double(effectiveTemp),
        topP: effectiveTopP.map(Double.init),
        topK: effectiveTopK,
        mode: runtimeDefaults.mode,
        stopSequences: request.stopSequences,
        combined: true,
    )
    let sampling = rawSampling.normalized()

    // ═══════════════════════════════════════════════════════
    // Phase 3b: Tool surface — assembled from the same helpers as the OpenAI face
    // (`ChatHandler` Phase 3), so "this request declared tools" means one thing on
    // both wires. Before this, `tools[]` on `/v1/messages` reached the model only as
    // system-prompt text (no `declaredToolNames`, no specs, no grammar): the engine's
    // tool path never ran, so a call the model made had nothing to be recognised by and
    // nothing to be constrained by — and the `.toolCall` event was dropped at both consuming sites.
    // ═══════════════════════════════════════════════════════
    let declaredTools: [ToolDef]? = chatRequest.tools
    /// Anthropic's demand, translated once (`any`→required, `tool`→function:<name>).
    let toolChoice: String? = request.toolChoice?.openAIVocabulary
    /// `tool_choice:{"type":"none"}` = zero tools this turn; declaring nothing is also
    /// zero (the engine's `resolveToolSurface` choke). Same shape as ChatHandler's.
    let declaredToolNames: [String]? = {
        if toolChoice == "none" { return [] }
        return declaredTools?.map { $0.function.name }
    }()
    /// Forcing follows the DEMAND, never the presence of a declaration — one rule for
    /// every face of the product (`shouldConstrainOutput`, Models/OpenAIModels.swift).
    let useGuidedGeneration = shouldConstrainOutput(
        declaredTools: declaredTools,
        responseFormat: nil,
        toolChoice: toolChoice
    )
    /// Grammar built from the DECLARATION, never a narrowed subset: grammar == surface
    /// == what the client sent.
    let grammarSchema: String? =
        useGuidedGeneration
        ? buildGrammarSchema(from: declaredTools, responseFormat: nil)
        : nil
    if let toolChoice {
        logger.info(
            "Anthropic tool_choice \(request.toolChoice?.type ?? "?") → \(toolChoice)")
    }
    if let declaredToolNames, !declaredToolNames.isEmpty {
        logger.info(
            "Anthropic tool declaration: \(declaredToolNames.count) declared [\(declaredToolNames.joined(separator: ", "))]"
        )
    }

    let inferenceOpts = InferenceOptions(
        maxTokens: effectiveMaxTokens,
        includeLogits: false,
        useGuidedGeneration: useGuidedGeneration,
        grammarSchema: grammarSchema,
        // Native calls run the ChatSession toolDispatch loop, not the one-shot guided
        // path — same routing decision as the OpenAI face, keyed on the declaration.
        hasNativeTools: declaredTools?.isEmpty == false,
        // The whitelist, in the caller's order: what the model may call, and the only
        // names the engine will inject.
        declaredToolNames: declaredToolNames,
        // The caller's own parameter schemas, so a tool this server does not register is
        // still declarable (and its call still deliverable to the caller).
        declaredToolSpecsJSON: openAIToolSpecsJSON(from: declaredTools),
        // Wire HTTP consumer — `.interactive` cannot be asked of an external
        // process: gate `.ask` verdicts fail-closed instead of parking on the
        // broker (codex `codex-rs/exec/src/lib.rs:566` headless → Never).
        headless: true
    )

    // ═══════════════════════════════════════════════════════
    // Phase 4: Dispatch to stream OR non-stream
    // ═══════════════════════════════════════════════════════
    if request.stream == true {
        return try await streamAnthropicResponse(
            handle: handle,
            inputTokenCount: inputTokenCount,
            messages: fullMessages,
            sampling: sampling,
            options: inferenceOpts,
            request: chatRequest,
            enginePool: enginePool,
            modelId: modelId,
            logger: logger,
            metrics: metrics,
            contentGuard: streamGuard,
        )
    } else {
        return try await nonStreamAnthropicResponse(
            handle: handle,
            inputTokenCount: inputTokenCount,
            messages: fullMessages,
            sampling: sampling,
            options: inferenceOpts,
            request: chatRequest,
            enginePool: enginePool,
            modelId: modelId,
            logger: logger,
            metrics: metrics,
            contentGuard: streamGuard,
        )
    }
}

// MARK: - Message Construction

/// CJK-aware prompt-token heuristic — mirror of the inline
/// fallback in `ChatHandler` (bytes/3 for CJK-heavy, bytes/4 for Latin).
///
/// `internal` (not `private`) so the exact-value contract is directly
/// unit-tested — `AnthropicInputTokenEstimateTests`. Out of the public
/// API surface deliberately: it is a metrics heuristic, not an API.
func estimatePromptTokensFallback(_ messages: [Message]) -> Int {
    /// CJK-aware estimation — UTF-8 bytes/4 overestimates for CJK text.
    /// Use bytes/3 for CJK-heavy content, bytes/4 for Latin-heavy.
    let totalBytes = messages.reduce(0) { $0 + $1.textContent().utf8.count }
    let totalChars = messages.reduce(0) { $0 + $1.textContent().count }
    guard totalChars > 0 else { return 0 }
    let avgBytesPerChar = Double(totalBytes) / Double(totalChars)
    let divisor = avgBytesPerChar > 1.5 ? 3 : 4
    return max(1, Int(Double(totalBytes) / Double(divisor)))
}

/// Build the inference message list from an Anthropic request: the conversation
/// turns plus the leading `system` message (string or text-block form).
///
/// `tools[]` deliberately does NOT appear here. It travels as a structured surface
/// (`InferenceOptions.declaredToolNames`/`declaredToolSpecsJSON` → `resolveToolSurface`
/// → the chat template's tool block), which is the only place the engine reads tools
/// from — the same route that makes a tool-declaring `/v1/chat/completions` turn call
/// at all. Rendering them into system text as well was a second, schema-less copy of
/// the same declaration: the model saw the tool name twice and its parameters never.
///
/// `internal`, not `private`: `POST /v1/messages/count_tokens` counts *this* list, so
/// the pre-flight answer is the message half of what `/v1/messages` feeds the model,
/// from one builder — one truth for both routes (the tool block is template-side on
/// this server and on `/v1/chat/completions` alike, so neither counts it).
func buildAnthropicMessageList(request: AnthropicMessageRequest) throws -> [Message] {
    // `toInternalMessage` is where block types get honoured or refused by name; this
    // function only adds the Anthropic-specific injection (the `system` field).
    var messages: [Message] = try request.messages.map { try $0.toInternalMessage() }

    // Inject system prompt (string or text-block form — see AnthropicSystemContent)
    if let system = request.system?.text, !system.isEmpty {
        messages.insert(Message(role: "system", content: .text(system)), at: 0)
    }

    guard !messages.isEmpty else {
        throw AppError.invalidRequest("Message list is empty for model '\(request.model)'")
    }

    return messages
}

// MARK: - Non-stream Response

/// Handle non-streaming Anthropic Messages request.
private func nonStreamAnthropicResponse(
    handle: EngineHandle,
    inputTokenCount: Int,
    messages: [Message],
    sampling: SamplingConfiguration,
    options: InferenceOptions,
    request: ChatCompletionRequest,
    enginePool: EnginePool,
    modelId: String,
    logger: Logger,
    metrics: MetricsRegistry,
    contentGuard: ContentGuard? = nil,
) async throws -> Response {
    let requestId = "msg-\(UUID().uuidString.prefix(8))"
    let startTime = ContinuousClock.now

    await handle.markActive()

    let tokenStream = handle.generateFromMessages(
        messages: messages,
        sampling: sampling,
        options: options,
    )

    var accumulatedTokens: [Int32] = []
    var accumulatedText: String? = nil
    var totalOutputTokens = 0
    var finishReason = "end_turn"
    var detectedToolCalls: [ToolCall]? = nil

    do {
        for try await event in tokenStream {
            switch event.kind {
            case .token(let tokenId):
                try Task.checkCancellation()
                accumulatedTokens.append(tokenId)
                totalOutputTokens += 1

            case .text(let text):
                try Task.checkCancellation()
                totalOutputTokens += 1
                accumulatedText = (accumulatedText ?? "") + text

            case .done(let reason, let doneTokenCount, _, _, _, _, _, _, _, _):
                let openaiReason = stopReasonToString(reason) ?? "stop"
                finishReason = openAIToAnthropicStopReason(openaiReason)
                // Authoritative token count from the engine — overwrite the
                // per-event estimate (fallback when the engine reports none).
                if let doneTokenCount {
                    totalOutputTokens = doneTokenCount
                }

            case .error(let errorMsg):
                finishReason = "error"
                logger.error("Generation error: \(errorMsg)")
            case .toolCall(let tc):
                // The engine already recognised this call. Collect every one (a turn may
                // emit several) — dropping them here is what made the Anthropic face
                // answer `end_turn` to a request whose model had called.
                detectedToolCalls = (detectedToolCalls ?? []) + [tc]
            case .toolResult:
                // Tool finished — informational for this handler, model context already has it
                break
            case .reasoning(let r):
                // Anthropic non-stream: reasoning text flows into accumulatedText
                try Task.checkCancellation()
                totalOutputTokens += 1
                accumulatedText = (accumulatedText ?? "") + r
            case .guidedGenDiagnostic(
                grammarTerminated: _,
                incompleteOutput: true
            ):
                // GAP-4: log guided gen diagnostics in Anthropic non-stream path
                logger.warning("Anthropic handler: guided gen incomplete")
            case .guidedGenDiagnostic:
                break
            case .prefillProgress:
                // Prefill progress — silent in Anthropic handler.
                break
            case .incompleteOutput(let incomplete):
                if incomplete {
                    logger.warning("Anthropic handler: incomplete output")
                }
            case .channel(let ch):
                logger.info("Compute channel: \(ch)")
            }
        }
    } catch {
        logger.error("Non-stream token consumption failed: \(error)")
        throw AppError.inferenceFailed(error.localizedDescription)
    }

    // Detokenize
    let content: String
    if let preDecoded = accumulatedText {
        content = preDecoded
    } else {
        do {
            content = try await handle.detokenize(tokens: accumulatedTokens)
        } catch {
            logger.info("Detokenization failed, returning placeholder")
            content = "<decode failed>"
        }
    }

    // Check output safety before serializing
    if let contentGuard, !content.isEmpty {
        let checkResult = await contentGuard.checkOutput(content)
        if !checkResult.passed {
            logger.warning(
                "Anthropic non-stream output blocked: \(checkResult.triggeredCategories)")
            let detail = NSDictionary(dictionary: [
                "message": checkResult.rejectionReason ?? "Content safety violation",
                "type": "content_policy_violation",
                "code": 400,
                "categories": checkResult.triggeredCategories.map(\.rawValue),
            ])
            let errorBody = NSDictionary(dictionary: ["error": detail])
            guard let data = try? JSONSerialization.data(withJSONObject: errorBody, options: [])
            else {
                return Response(status: .badRequest)
            }
            var headers: HTTPFields = [:]
            headers[.contentType] = "application/json"
            return Response(
                status: .badRequest, headers: headers,
                body: .init(contentsOf: [ByteBuffer(data: data)]))
        }
    }

    // Record metrics
    let dur = startTime.duration(to: ContinuousClock.now)
    let elapsed = Double(dur.components.seconds) * 1000 + Double(dur.components.attoseconds) / 1e15
    await metrics.observeInferenceDuration(elapsed / 1000.0)
    await metrics.incrementTokens(kind: "generated", count: totalOutputTokens)
    await metrics.incrementTokens(kind: "prompt", count: inputTokenCount)

    /// The calls this turn produced: the structured ones the engine emitted, and only
    /// as a fallback a dialect parsed out of the answer text (same precedence as
    /// ChatHandler L1141 — upstream consumes the native dialect and strips it from the
    /// text, so text alone sees nothing).
    let toolCalls: [ToolCall]? =
        if let detected = detectedToolCalls, !detected.isEmpty {
            detected
        } else if request.tools?.isEmpty == false {
            parseToolCalls(from: content)
        } else {
            nil
        }

    /// `content` = text block, then one `tool_use` block per delivered call
    /// (`{"type":"tool_use","id","name","input":{…}}`, vllm serving.py:870-877).
    /// `input` is a JSON object here, unlike OpenAI's `arguments` string; a payload
    /// that is not an object is dropped and logged rather than laundered into `{}`,
    /// because a client would execute a call with arguments the model never sent.
    var contentBlocks: [AnthropicAssistantContent] = []
    if !content.isEmpty {
        contentBlocks.append(AnthropicAssistantContent(text: content))
    }
    var deliveredCalls: [ToolCall] = []
    for call in toolCalls ?? [] {
        let rawArguments = call.function.arguments
        guard let input = anthropicToolInput(fromJSON: rawArguments) else {
            logger.warning(
                "Anthropic tool_use dropped: arguments for \(call.function.name) are not a JSON object — no call delivered rather than one with invented arguments"
            )
            continue
        }
        contentBlocks.append(
            AnthropicAssistantContent(
                toolUseId:
                    call.id.isEmpty ? "toolu_\(UUID().uuidString.prefix(8))" : call.id,
                name: call.function.name,
                input: input
            )
        )
        deliveredCalls.append(call)
    }
    /// Anthropic's canonical empty completion is a single empty text block, not `[]`
    /// — strict clients index `content[0]` (same reasoning as vllm serving.py:879-883).
    if contentBlocks.isEmpty {
        contentBlocks.append(AnthropicAssistantContent(text: ""))
    }

    if deliveredCalls.isEmpty, toolChoiceDemandsCall(request.toolChoice) {
        let demandedBy = request.toolChoice ?? "any"
        logger.warning(
            "tool_choice=\(demandedBy) demanded a tool call and none was produced — no call fabricated (finish=\(finishReason), content \(content.isEmpty ? "empty" : "text only"))"
        )
    }

    /// Per-model delivery fact for `tool_call_delivery` on `/v1/models`: measured at
    /// this wire edge, so the Anthropic face's traffic counts too, and `parsed` means
    /// the client actually received a `tool_use` block.
    let declaredNamesForDelivery = request.tools?.map { $0.function.name } ?? []
    if !declaredNamesForDelivery.isEmpty {
        await enginePool.recordToolCallDelivery(
            modelId: modelId,
            outcome: deliveredCalls.isEmpty
                ? ToolCallDeliveryLedger.classifyTurn(
                    text: content, declaredNames: declaredNamesForDelivery)
                : .parsed,
            calledNames: deliveredCalls.map { $0.function.name }
        )
    }

    // Build Anthropic response
    let usage = AnthropicUsage(inputTokens: inputTokenCount, outputTokens: totalOutputTokens)
    let stopReason = deliveredCalls.isEmpty ? finishReason : "tool_use"

    let response = AnthropicMessageResponse(
        id: requestId,
        content: contentBlocks,
        model: modelId,
        stopReason: stopReason.isEmpty ? nil : stopReason,
        usage: usage,
    )

    logger.info("Anthropic non-stream request completed")

    var headers: HTTPFields = [:]
    headers[.contentType] = "application/json"
    let bodyData = try JSONEncoder().encode(response)
    return Response(
        status: .ok, headers: headers, body: .init(contentsOf: [ByteBuffer(data: bodyData)]))
}

// MARK: - SSE Stream Response

/// Handle streaming Anthropic Messages request.
private func streamAnthropicResponse(
    handle: EngineHandle,
    inputTokenCount: Int,
    messages: [Message],
    sampling: SamplingConfiguration,
    options: InferenceOptions,
    request: ChatCompletionRequest,
    enginePool: EnginePool,
    modelId: String,
    logger: Logger,
    metrics: MetricsRegistry,
    contentGuard: ContentGuard? = nil,
) async throws -> Response {
    let responseHeaders = SSEHeaders

    let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()

    // Cancellation token: bridges client disconnect → inference loop
    let canceller = InferenceCancellation.cancellable()

    // Bridge SSE stream closure → inference cancellation so client disconnect
    // stops GPU work.
    continuation.onTermination = { @Sendable _ in
        canceller.cancel()
    }

    // Safety guard for streaming — captured early for inline safety checks
    let streamGuard = contentGuard

    _ = Task {
        do {
            let requestId = "msg-\(UUID().uuidString.prefix(8))"
            let startTime = ContinuousClock.now

            await handle.markActive()

            let tokenStream = handle.generateFromMessages(
                messages: messages,
                sampling: sampling,
                options: options,
                cancellation: canceller,
            )

            var totalOutputTokens = 0
            var accumulatedTokens: [Int32] = []
            var prevDecodedText = ""
            var finishReason = "stop"
            var deliveredToolCalls: [ToolCall] = []
            var emitter = AnthropicStreamEmitter()
            /// Everything the engine produced this turn, for the stream-end parse and the
            /// delivery ledger (`parseToolCalls` is all-or-nothing on the whole answer).
            var answerText = ""

            // Emit message_start event
            let startResponse = AnthropicMessageResponse(
                id: requestId,
                content: [],
                model: modelId,
                stopReason: nil,
                usage: AnthropicUsage(inputTokens: inputTokenCount, outputTokens: 0),
            )
            let messageStart = AnthropicStreamEvent.messageStart(message: startResponse)
            writeSSEEvent(continuation, event: messageStart)

            // Consume tokens and stream deltas
            do {
                for try await event in tokenStream {
                    switch event.kind {
                    case .token(let tokenId):
                        try Task.checkCancellation()
                        accumulatedTokens.append(tokenId)
                        totalOutputTokens += 1

                        let newText: String
                        do {
                            newText = try await handle.detokenize(tokens: accumulatedTokens)
                        } catch {
                            logger.warning("Incremental detokenization failed")
                            newText = prevDecodedText + "<token>"
                        }

                        let deltaText: String =
                            if newText.hasPrefix(prevDecodedText) {
                                String(newText.dropFirst(prevDecodedText.count))
                            } else {
                                newText
                            }
                        prevDecodedText = newText

                        // Safety check: filter harmful output in real-time
                        if let contentGuard = streamGuard {
                            let checkResult = await contentGuard.checkOutput(deltaText)
                            if !checkResult.passed {
                                logger.warning(
                                    "Anthropic streaming output blocked: \(checkResult.triggeredCategories)"
                                )
                                let errorEvent = AnthropicStreamEvent(
                                    type: "error", index: nil, message: nil, delta: nil,
                                    usage: AnthropicStreamUsage(
                                        outputTokens: totalOutputTokens,
                                        inputTokens: inputTokenCount),
                                )
                                writeSSEEvent(continuation, event: errorEvent)
                                continuation.finish()
                                return
                            }
                        }

                        // Answer text goes through the emitter, which may hold it
                        answerText += deltaText
                        for event in emitter.feedText(deltaText) {
                            writeSSEEvent(continuation, event: event)
                        }

                    case .text(let text):
                        try Task.checkCancellation()
                        totalOutputTokens += 1

                        // Safety check: filter harmful output in real-time
                        if let contentGuard = streamGuard {
                            let checkResult = await contentGuard.checkOutput(text)
                            if !checkResult.passed {
                                logger.warning(
                                    "Anthropic streaming output blocked (.text): \(checkResult.triggeredCategories)"
                                )
                                let errorEvent = AnthropicStreamEvent(
                                    type: "error", index: nil, message: nil, delta: nil,
                                    usage: AnthropicStreamUsage(
                                        outputTokens: totalOutputTokens,
                                        inputTokens: inputTokenCount),
                                )
                                writeSSEEvent(continuation, event: errorEvent)
                                continuation.finish()
                                return
                            }
                        }

                        answerText += text
                        for event in emitter.feedText(text) {
                            writeSSEEvent(continuation, event: event)
                        }

                    case .done(let reason, let doneTokenCount, _, _, _, _, _, _, _, _):
                        finishReason = stopReasonToString(reason) ?? "stop"

                        // Authoritative token count from the engine — overwrite the
                        // per-event estimate (a `.text`/`.reasoning` case is a text
                        // segment/chunk, not a token). Same pattern as the ChatHandler
                        // stream `.done` branch and the non-streaming path.
                        if let doneTokenCount {
                            totalOutputTokens = doneTokenCount
                        }
                    case .error(let errorMsg):
                        logger.error("Stream generation error: \(errorMsg)")
                    case .toolCall(let tc):
                        // Deliver it: `content_block_start` naming a `tool_use` block, then
                        // its arguments as `input_json_delta` (sglang serving.py:1194-1220,
                        // vllm serving.py:970-980). Each call closes the previous block and
                        // takes the next index, so a multi-call turn stays addressable.
                        deliveredToolCalls.append(tc)
                        for event in emitter.emitToolCall(
                            id: tc.id.isEmpty ? "toolu_\(UUID().uuidString.prefix(8))" : tc.id,
                            name: tc.function.name,
                            arguments: tc.function.arguments
                        ) {
                            writeSSEEvent(continuation, event: event)
                        }
                    case .toolResult:
                        // Tool finished — informational, model context already carried the result
                        break
                    case .reasoning:
                        // Reasoning text flows into Anthropic text delta as normal content
                        break
                    case .guidedGenDiagnostic(
                        grammarTerminated: _,
                        incompleteOutput: true
                    ):
                        // GAP-4: log in Anthropic SSE path
                        logger.warning("Anthropic SSE: guided gen incomplete")
                    case .guidedGenDiagnostic:
                        break
                    case .prefillProgress:
                        // Prefill progress — silent in Anthropic SSE handler.
                        break
                    case .incompleteOutput(let incomplete):
                        if incomplete {
                            logger.warning("Anthropic SSE: incomplete output")
                        }
                    case .channel(let ch):
                        logger.info("Anthropic SSE: compute channel \(ch)")
                    }
                }
            } catch {
                logger.error("Stream token consumption failed: \(error)")
                throw AppError.inferenceFailed(error.localizedDescription)
            }

            /// The calls this stream delivers: the ones the engine emitted as events, and
            /// as a fallback the dialect parsed out of the settled answer. The fallback is
            /// not optional on this face: a calls-only grammar makes the model *write* the
            /// call in plain JSON (measured 10-19 — 35 text deltas spelling
            /// `"name": "get_weather"`, then `end_turn`, and no `.toolCall` at all), and
            /// `/v1/chat/completions` already recovers exactly this with the same
            /// `parseToolCalls` at its own stream end (ChatHandler L1727).
            let streamToolCalls: [ToolCall] =
                if !deliveredToolCalls.isEmpty {
                    []
                } else if request.tools?.isEmpty == false {
                    parseToolCalls(from: answerText) ?? []
                } else {
                    []
                }
            if !streamToolCalls.isEmpty {
                /// The held-back text IS the payload — ship it as blocks, not as prose
                /// sitting next to the structured call the client will execute.
                emitter.discardPendingText()
            }
            for call in streamToolCalls {
                deliveredToolCalls.append(call)
                for event in emitter.emitToolCall(
                    id:
                        call.id.isEmpty ? "toolu_\(UUID().uuidString.prefix(8))" : call.id,
                    name: call.function.name,
                    arguments: call.function.arguments
                ) {
                    writeSSEEvent(continuation, event: event)
                }
            }
            /// Prose that never resolved into a call is released here, at the last moment.
            for event in emitter.flushText() { writeSSEEvent(continuation, event: event) }
            /// A turn that produced nothing still gets one empty text block: strict SDKs
            /// index `content[0]` after opening the stream (vllm serving.py:879-883).
            for event in emitter.ensureSomeBlock() { writeSSEEvent(continuation, event: event) }
            for event in emitter.close() { writeSSEEvent(continuation, event: event) }

            if deliveredToolCalls.isEmpty, toolChoiceDemandsCall(request.toolChoice) {
                let demandedBy = request.toolChoice ?? "any"
                logger.warning(
                    "SSE tool_choice=\(demandedBy) demanded a tool call and none was produced — no call fabricated (finish=\(finishReason))"
                )
            }

            /// `tool_call_delivery` for `/v1/models`, measured on this face too
            /// (`ToolCallDeliveryLedger`); `parsed` = a `tool_use` block reached the client.
            let declaredNamesForDelivery = request.tools?.map { $0.function.name } ?? []
            if !declaredNamesForDelivery.isEmpty {
                await enginePool.recordToolCallDelivery(
                    modelId: modelId,
                    outcome: deliveredToolCalls.isEmpty
                        ? ToolCallDeliveryLedger.classifyTurn(
                            text: answerText, declaredNames: declaredNamesForDelivery)
                        : .parsed,
                    calledNames: deliveredToolCalls.map { $0.function.name }
                )
            }

            // Emit message_delta — Anthropic carries stop_reason here, and SDKs key
            // on it; message_stop alone leaves the turn without a terminal reason.
            let streamStopReason = openAIToAnthropicStopReason(
                deliveredToolCalls.isEmpty ? finishReason : "tool_calls")
            let deltaEvent = AnthropicStreamEvent.messageDelta(
                stopReason: streamStopReason,
                outputTokens: totalOutputTokens,
            )
            writeSSEEvent(continuation, event: deltaEvent)

            // Emit message_stop with final usage
            let finalEvent = AnthropicStreamEvent.messageStop(
                inputTokens: inputTokenCount,
                outputTokens: totalOutputTokens,
            )
            writeSSEEvent(continuation, event: finalEvent)

            // Record metrics
            let dur = startTime.duration(to: ContinuousClock.now)
            let elapsed =
                Double(dur.components.seconds) * 1000 + Double(dur.components.attoseconds) / 1e15
            await metrics.observeInferenceDuration(elapsed / 1000.0)
            await metrics.incrementTokens(kind: "generated", count: totalOutputTokens)
            await metrics.incrementTokens(kind: "prompt", count: inputTokenCount)

        } catch {
            // On error, write a single error event
            let errorEvent = AnthropicStreamEvent(
                type: "error", index: nil, message: nil, delta: nil,
                usage: AnthropicStreamUsage(outputTokens: 0, inputTokens: 0),
            )
            writeSSEEvent(continuation, event: errorEvent)
        }
        continuation.finish()
    }

    return Response(
        status: .ok,
        headers: responseHeaders,
        body: .init(asyncSequence: stream),
    )
}

// MARK: - SSE Helpers

/// Owns what the Anthropic SSE client sees: which content block is open and at which
/// index, plus answer text held back until it is known not to be a tool-call payload.
///
/// Two protocol facts shape it. Blocks are numbered, not deltas: text and every
/// `tool_use` need their own `content_block_start`/`stop` pair at their own index, or a
/// client accumulating two calls cannot tell them apart (sglang serves this with the same
/// ensure/close pair, serving.py:880-935). And a call must not arrive as prose: our
/// calls-only grammar makes the model *write* `[{…}]`, so text whose first character is
/// `[`/`{` is undecided until the answer settles — shipping it live would show the
/// client a JSON blob and then, or instead, the structured block. Prose releases at the
/// first character that cannot begin a call object; `parseToolCalls` at stream end
/// applies the same all-or-nothing rule the non-stream path and `ChatHandler` use.
/// `internal`, not `private`: the hold/flush rule is an exact-value contract (what a
/// client sees, and in which order), and `estimatePromptTokensFallback` above sets the
/// precedent for testing a handler helper directly.
struct AnthropicStreamEmitter {
    private var index = 0
    private var openKind: String? = nil
    private var pending = ""
    private var isStreamingText = false
    /// Whether any block was ever opened — the "nothing to show" fallback's premise.
    private(set) var hasEmittedAnyBlock = false

    /// The open block's index; every call site opens on the line above.
    var currentIndex: Int { index }

    /// One piece of answer text as the engine produced it. Empty when the piece is still
    /// undecided (held) — the content then leaves through ``flushText()``.
    mutating func feedText(_ piece: String) -> [AnthropicStreamEvent] {
        guard !piece.isEmpty else { return [] }
        if isStreamingText {
            return [AnthropicStreamEvent.textDelta(index: index, text: piece)]
        }
        pending += piece
        guard !Self.couldBeToolCallPayload(pending) else { return [] }
        return flushText()
    }

    /// Releases whatever text is held, as prose.
    mutating func flushText() -> [AnthropicStreamEvent] {
        guard !pending.isEmpty else { return [] }
        let text = pending
        pending = ""
        return openTextBlock()
            + [AnthropicStreamEvent.textDelta(index: index, text: text)]
    }

    /// A recognised call: flush prose buffered ahead of it (vllm flushes its
    /// `pending_content` before opening a block, serving.py:985-997), then give the call
    /// its own block, with arguments as `input_json_delta`.
    mutating func emitToolCall(id: String, name: String, arguments: String)
        -> [AnthropicStreamEvent]
    {
        var events = flushText()
        events += close()
        openKind = "tool_use"
        hasEmittedAnyBlock = true
        events.append(AnthropicStreamEvent.toolUseBlockStart(index: index, id: id, name: name))
        if !arguments.isEmpty {
            events.append(
                AnthropicStreamEvent.inputJsonDelta(index: index, partialJson: arguments))
        }
        return events
    }

    /// The held text turned out to be the call payload: drop it rather than ship both.
    mutating func discardPendingText() {
        pending = ""
    }

    /// Closes the open block, if any.
    mutating func close() -> [AnthropicStreamEvent] {
        guard openKind != nil else { return [] }
        openKind = nil
        isStreamingText = false
        let event = AnthropicStreamEvent.contentBlockStop(index: index)
        index += 1
        return [event]
    }

    /// One empty text block for a turn that produced nothing at all.
    mutating func ensureSomeBlock() -> [AnthropicStreamEvent] {
        guard !hasEmittedAnyBlock else { return [] }
        return openTextBlock()
    }

    private mutating func openTextBlock() -> [AnthropicStreamEvent] {
        if openKind == "text" { return [] }
        let closing = close()
        openKind = "text"
        isStreamingText = true
        hasEmittedAnyBlock = true
        return closing + [AnthropicStreamEvent.contentBlockStart(index: index)]
    }

    /// Could this still turn out to be a tool-call payload? Both shapes our grammar can
    /// force start with `[` (an array of call objects) or `{`.
    static func couldBeToolCallPayload(_ text: String) -> Bool {
        let trimmed = text.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        return trimmed.isEmpty || trimmed.hasPrefix("[") || trimmed.hasPrefix("{")
    }
}

/// Write a single SSE event to the async stream continuation
private func writeSSEEvent(
    _ continuation: AsyncStream<ByteBuffer>.Continuation,
    event: AnthropicStreamEvent,
) {
    let jsonData = try? JSONEncoder().encode(event)
    guard let jsonData else { return }
    let jsonString = String(decoding: jsonData, as: UTF8.self)
    let line = "event: \(event.type)\ndata: \(jsonString)\n\n"
    if let data = line.data(using: .utf8) {
        continuation.yield(ByteBuffer(data: data))
    }
}
