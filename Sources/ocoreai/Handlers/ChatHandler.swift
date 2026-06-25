// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// chat_handler.swift — OpenAI-compatible chat completions handler
///
/// DEFENSIVE: Full OpenAI API compat layer (chat completions, SSE streaming,
/// tool calling, usage tracking). If CoreAI ships an official OpenAI-compatible
/// server backend, this entire file can be replaced. Until then, this is the
/// best available interface layer on the CoreAI stack.
/// See ROADMAP.md for replacement triggers.
///
/// ### Inference Pipeline:
/// 1. Scheduler submit (OOMGuard + priority queue) → 2. Acquire engine session
/// 3. Tokenize messages → 4. Apply 3-layer param fallback
/// 5. Dispatch stream/non-stream → 6. Incremental decode → 7. Tool call detection
/// 8. Scheduler complete (memory release + lifecycle done)
///
/// ### Streaming:
/// SSE NDJSON with prefix-preserving incremental decode.
/// Full accumulation → detokenize → diff extraction (aligned with Apple `respondVanilla`).
///
/// ### Tool Calling:
/// Full function/AGI tool call support — model requests tool invocation,
/// client executes, sends follow-up with tool role messages, model integrates results.
///
/// ### Parameter Fallback Chain (v9):
/// 1. Request body (highest priority)
/// 2. Model runtime defaults (PATCH endpoint)
/// 3. System hard-coded defaults

#if coreai
import CoreAI
import CoreAILanguageModels
#endif
import Foundation
import HTTPTypes
import Hummingbird
import Logging

// MARK: - Adaptive Reasoning (三思而后行)

/// Per-session complexity analyzer — adaptive thinking budget.
private let complexityAnalyzer = ComplexityAnalyzer()

/// Thinking budget manager — scaffolding injection + adaptive calibration.
private let thinkingBudget = ThinkingBudget()

// MARK: - Self-Correction Integration

/// Top-level pipeline instance — Sendable, zero cost when self-correction is off.
private let selfCorrectionPipeline = SelfCorrectionPipeline()

/// Decide whether to activate the post-inference self-correction pipeline.
///
/// ## Activation criteria:
///   1. ``ChatCompletionRequest/selfCorrection`` is explicitly ``true``, OR
///   2. (Future) confidence from Phase 1 rule check drops below 0.85.
///
/// When disabled this is a single ``Bool`` check — no allocations, no async hops.
private func shouldRunSelfCorrection(_ request: ChatCompletionRequest) -> Bool {
    request.selfCorrection == true
}

/// Resolve session ID for self-correction memory persistence.
private func resolveSessionId(for request: ChatCompletionRequest) -> Int64 {
    Int64(request.sessionID ?? "0") ?? 0
}

/// Build a corrected message list for re-generation during self-correction.
///
/// Replaces the system message with ``systemOverride`` and appends few-shot
/// ``examples`` as assistant/user pairs before the existing messages.
///
/// - Parameters:
///   - original: Full message list from the initial inference pass
///   - systemOverride: Corrected system prompt from the self-correction pipeline
///   - examples: Optional few-shot examples
/// - Returns: New ``Message`` array ready for re-generation
private func buildCorrectedMessages(
    original: [Message],
    systemOverride: String?,
    examples: [String]?
) -> [Message] {
    var result: [Message] = []

    // Inject system override if provided
    if let override = systemOverride {
        result.append(Message(role: "system", content: override))
    } else {
        // Preserve original system message
        if let sys = original.first, sys.role == "system" {
            result.append(sys)
        }
    }

    // Inject few-shot examples if provided
    if let examples = examples, !examples.isEmpty {
        for (index, example) in examples.enumerated() {
            let role: String
            if index % 2 == 0 {
                role = "user"
            } else {
                role = "assistant"
            }
            result.append(Message(role: role, content: example))
        }
    }

    // Append non-system original messages
    for msg in original where msg.role != "system" {
        result.append(msg)
    }

    return result
}

// MARK: - Main Handler

/// Process a chat completion request through the full inference pipeline.
///
/// Routes through ``SchedulerActor`` for OOM protection and priority scheduling,
/// then acquires session, tokenizes, applies parameter fallback, dispatches
/// inference, and returns either SSE stream or non-stream JSON response.
///
/// - Parameters:
///   - request: OpenAI-compatible chat completion request
///   - enginePool: Engine pool for concurrent inference management
///   - scheduler: Request scheduler with OOMGuard + priority queue
///   - metrics: Shared metrics registry (Prometheus-compatible)
///   - sessionCompressor: Session persistence layer
///   - systemPromptBuilder: System prompt assembly (skills injection)
///   - logger: Observability logger
/// - Returns: HTTP Response (SSE stream or JSON completion)
func chatCompletionsHandler(
    request: ChatCompletionRequest,
    enginePool: EnginePool,
    scheduler: SchedulerActor,
    metrics: MetricsRegistry,
    sessionCompressor: SessionCompressor,
    systemPromptBuilder: SystemPromptBuilder,
    logger: Logger
) async throws -> Response {
    /// Extract model identifier from the request payload.
    let modelId = request.model

    /// Safety check: filter harmful input before scheduling
    if let contentGuard = await OcoreaiEngine.shared.activeContentGuard {
        let messageText = request.messages.map { $0.textContent() }.joined(separator: " ")
        let result = await contentGuard.checkInput(messageText)
        if result.isBlocked {
            let errorBody: [String: Any] = [
                "error": [
                    "message": result.rejectionReason ?? "Content safety violation",
                    "type": "content_policy_violation",
                    "code": 400,
                    "categories": result.triggeredCategories.map(\.rawValue),
                ]
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: errorBody, options: []) else {
                return Response(status: .badRequest)
            }
            var headers: HTTPFields = [:]
            headers[.contentType] = "application/json"
            return Response(status: .badRequest, headers: headers, body: .init(contentsOf: [ByteBuffer(data: data)]))
        }
    }

    /// Phase 1: Submit to scheduler (OOMGuard + priority queue)
    let schedulingRequest = SchedulingRequest(
        id: "req-\(UUID().uuidString.prefix(8))",
        priority: .chat,
        modelId: modelId,
        prompt: request.messages.first?.textContent() ?? "",
        tokenBudget: request.maxTokens ?? 4096
    )
    try await scheduler.submit(schedulingRequest)

    /// Phase 1b: Acquire engine handle
    let handle: EngineHandle
    do {
        handle = try await enginePool.acquire(model: modelId)
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

    /// Phase 2: Build complete message list including system prompt + tool info injection.
    let fullMessages = try await buildMessageList(
        request: request, handle: handle, systemPromptBuilder: systemPromptBuilder,
        sessionCompressor: sessionCompressor
    )

    /// Phase 3: Tokenize messages for prompt token count.
    /// (Token count needed for metrics; actual inference passes messages directly on MLX path.)
    let tokens: [Int32]
    do {
        tokens = try await handle.tokenize(messages: fullMessages)
    } catch {
        throw AppError.tokenizationFailed(error.localizedDescription)
    }

    /// Validate tokenization returned at least one token.
    guard !tokens.isEmpty else {
        throw AppError.tokenizationFailed(
            "Empty token output for model '\(modelId)'"
        )
    }

    /// Phase 4: Three-layer Parameter Fallback Chain.
    /// Layer 1: Request body explicit params (highest priority)
    /// Layer 2: Model runtime default (via PATCH /v1/models/:model/sampling)
    /// Layer 3: System default (hardcoded)
    let runtimeDefaults = await enginePool.getSamplingConfig(modelId: modelId)

    /// Resolve effective temperature with fallback chain.
    let effectiveTemp = request.temperature != 0.0 || runtimeDefaults.temperature == ModelSamplingConfig.default.temperature
        ? request.temperature
        : runtimeDefaults.temperature

    /// Resolve optional parameters with nil → runtime → nil cascade.
    let effectiveTopP = request.topP ?? runtimeDefaults.topP
    let effectiveTopK = request.topK ?? runtimeDefaults.topK
    let effectiveMaxTokens = request.maxTokens ?? runtimeDefaults.maxTokens

    /// Build normalized sampling configuration (drops redundant params when temperature == 0).
    let rawSampling = SamplingConfiguration(
        temperature: Double(effectiveTemp),
        topP: effectiveTopP.map(Double.init),
        topK: effectiveTopK,
        stopSequences: nil,
        logitBias: nil,
        combined: true
    )
    let sampling = rawSampling.normalized()

    /// Log warning if normalization dropped parameters.
    if sampling != rawSampling {
        logger.warning("Sampling config normalized (redundant params dropped)")
    }

    /// Build inference options with same fallback chain.
    let inferenceOpts = InferenceOptions(
        maxTokens: effectiveMaxTokens,
        includeLogits: false
    )

    /// Log if runtime defaults override system defaults.
    let hasOverride = (runtimeDefaults.temperature != ModelSamplingConfig.default.temperature ||
                      runtimeDefaults.topP != nil ||
                      runtimeDefaults.topK != nil ||
                      runtimeDefaults.maxTokens != nil)
    if hasOverride {
        logger.info("Using runtime sampling override for: \(modelId)")
    }

    /// Phase 5: Dispatch to stream OR non-stream path based on request flag.
    /// Use ``generateFromMessages`` — MLX path passes messages directly to ChatSession,
    /// eliminating the tokenize→detokenize→re-tokenize loop.
    if request.stream == true {
        return try await streamWithToolCalling(
            handle: handle,
            tokens: tokens,
            messages: fullMessages,
            sampling: sampling,
            options: inferenceOpts,
            request: request,
            modelId: modelId,
            sessionCompressor: sessionCompressor,
            logger: logger,
            metrics: metrics
        )
    } else {
        return try await nonStreamWithToolCalling(
            handle: handle,
            tokens: tokens,
            messages: fullMessages,
            sampling: sampling,
            options: inferenceOpts,
            request: request,
            modelId: modelId,
            sessionCompressor: sessionCompressor,
            logger: logger,
            metrics: metrics
        )
    }
}

// MARK: - Message Construction

/// Build complete message list including system prompt and tool definitions.
///
/// Injects two elements before user messages:
/// 1. System prompt from ``request/system`` (highest priority, prepended)
/// 2. Tool definitions as formatted markdown in system message
///
/// - Parameters:
///   - request: Chat completion request with messages and optional tools
///   - handle: Engine handle (for model metadata)
/// - Returns: Ordered ``Message`` array ready for tokenization
/// - Throws: ``AppError.invalidRequest`` if validation fails
private func buildMessageList(
    request: ChatCompletionRequest,
    handle: EngineHandle,
    systemPromptBuilder: SystemPromptBuilder,
    sessionCompressor: SessionCompressor
) async throws -> [Message] {
    var messages = request.messages

    /// Inject skill-based system prompt from SystemPromptBuilder.
    let builtSystemPrompt = await systemPromptBuilder.buildSystemPrompt()

    /// Recall permanent memory — cue-spreading surface related past events.
    var memoryContext = ""
    do {
        let recalled = try await sessionCompressor.recallPermanentMemory(limit: 10)
        if !recalled.isEmpty {
            let summaries = recalled.map {
                "**[\($0.memoryType.rawValue)]** \($0.cause) → \($0.result)"
            }.joined(separator: "\n")
            memoryContext = """

    ## Recalled Memory
    The following structured knowledge from past sessions is relevant:

    \(summaries)
    """
        }
    } catch {
        // Memory recall failure is non-fatal — proceed without it
    }

    /// User-provided system prompt takes highest priority.
    let finalSystem: String
    if let userSystem = request.system, !userSystem.isEmpty {
        finalSystem = userSystem + "\n\n" + builtSystemPrompt + memoryContext
    } else if !builtSystemPrompt.isEmpty {
        finalSystem = builtSystemPrompt + memoryContext
    } else {
        finalSystem = memoryContext.isEmpty ? "" : memoryContext
    }

    /// Inject system message (prepended to message array).
    if !finalSystem.isEmpty {
        messages.insert(Message(role: "system", content: finalSystem), at: 0)
    }

    /// Inject tool definitions into system message (if tools present).
    if let tools = request.tools, !tools.isEmpty {
        /// Format tool definitions as markdown blocks for the model.
        let toolDefs = tools.compactMap { tool -> String? in
            guard let desc = tool.function.description else { return nil }
            return "## Tool: \(tool.function.name)\nDescription: \(desc)"
        }.joined(separator: "\n\n")

        if !toolDefs.isEmpty {
            /// If system message exists, append tool info; otherwise insert new system message.
            if let firstSystem = messages.firstIndex(where: { $0.role == "system" }) {
                if case .text(var existingContent) = messages[firstSystem].content {
                    existingContent += "\n\nAvailable tools:\n\(toolDefs)"
                    messages[firstSystem].content = .text(existingContent)
                }
            } else {
                let toolMessage = Message(role: "system", content: "You have access to the following tools:\n\n\(toolDefs)")
                messages.insert(toolMessage, at: 0)
            }
        }
    }

    /// Guard: message list must not be empty after construction.
    guard !messages.isEmpty else {
        throw AppError.invalidRequest("Message list is empty for model '\(request.model)'")
    }


    /// Inject adaptive reasoning scaffold (三思而后行) — auto-calibrated by input complexity
    let adaptiveSessionId = request.sessionID ?? "\(UUID().uuidString.prefix(8))"
    let userMessage = messages.first(where: { $0.role == "user" })?.textContent()
        ?? request.messages.first?.textContent() ?? ""
    let complexity = await complexityAnalyzer.analyze(
        input: userMessage,
        messageCount: max(1, messages.count),
        sessionId: adaptiveSessionId
    )
    let reasoningScaffold = await thinkingBudget.scaffolding(for: complexity, sessionId: adaptiveSessionId)
    if !reasoningScaffold.isEmpty {
        if let sysIdx = messages.firstIndex(where: { $0.role == "system" }) {
            if case .text(var existingContent) = messages[sysIdx].content {
                existingContent += "\n\n" + reasoningScaffold
                messages[sysIdx].content = .text(existingContent)
            }
        }
    }
    return messages
}

// MARK: - Tool Call Detection & Parsing

/// Detect and parse tool calls from generated model content.
///
/// Parses JSON array of `{"name": "...", "arguments": "..."}` objects.
/// Falls back to nil if content does not match tool call format.
///
/// - Parameter content: Raw generated text from the model
/// - Returns: Array of ``ToolCall`` if detected, otherwise nil
private func parseToolCalls(from content: String) -> [ToolCall]? {
    guard !content.isEmpty else { return nil }

    /// Attempt standard JSON array parsing for tool call objects.
    do {
        let jsonData = content.data(using: .utf8) ?? Data()
        if let toolArray = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
            var toolCalls: [ToolCall] = []
            for toolObj in toolArray {
                if let name = toolObj["name"] as? String,
                   let args = toolObj["arguments"] {
                    /// Serialize arguments back to JSON string for OpenAI compatibility.
                    let argsJson = String(data: try JSONSerialization.data(
                        withJSONObject: args,
                        options: []
                    ), encoding: .utf8) ?? "{}"
                    let tc = ToolCall(
                        id: "call_\(UUID().uuidString.prefix(8))",
                        function: ToolCallFunction(name: name, arguments: argsJson)
                    )
                    toolCalls.append(tc)
                }
            }
            return toolCalls.isEmpty ? nil : toolCalls
        }
    } catch {
        return nil
    }

    /// Legacy fallback: detect Claude-style tool_use markers.
    if content.contains("<tool_code>") || (content.contains("\n\n") && content.contains("```json")) {
        return nil
    }

    return nil
}

// MARK: - Non-stream with Tool Calling

/// Handle non-streaming chat completion with full tool call pipeline.
///
/// Accumulates all generated tokens, performs single detokenization,
/// checks for tool calls, returns structured ``ChatCompletion`` JSON response.
///
/// - Parameters:
///   - handle: Acquired engine handle
///   - tokens: Tokenized input prompt
///   - sampling: Normalized sampling configuration
///   - options: Inference options (maxTokens, logits)
///   - request: Original chat completion request
///   - modelId: Model identifier
///   - logger: Observability logger
///   - metrics: Shared metrics registry for recording inference metrics
/// - Returns: JSON ``Response`` with ``ChatCompletion`` payload
private func nonStreamWithToolCalling(
    handle: EngineHandle,
    tokens: [Int32],
    messages: [Message],
    sampling: SamplingConfiguration,
    options: InferenceOptions,
    request: ChatCompletionRequest,
    modelId: String,
    sessionCompressor: SessionCompressor,
    logger: Logger,
    metrics: MetricsRegistry
) async throws -> Response {
    /// Generate unique request ID for tracing.
    let requestId = "req-\(UUID().uuidString.prefix(8))"
    let created = Int64(Date().timeIntervalSince1970)

    /// Record inference start time for metrics.
    let startTime = ContinuousClock.now

    /// Mark session active — resets KV cache idle eviction timer.
    await handle.markActive()

    /// Start inference — MLX path passes messages directly to ChatSession,
    /// eliminating the tokenize→detokenize→re-tokenize loop.
    let tokenStream = handle.generateFromMessages(
        messages: messages,
        sampling: sampling,
        options: options
    )

    var accumulatedTokens: [Int32] = []
    var accumulatedText: String? = nil
    var totalOutputTokens = 0
    var finishReason = "stop"

    /// Consume all events from the token stream.
    do {
        for try await event in tokenStream {
            switch event.kind {
            /// Accumulate generated token IDs.
            case .token(let tokenId):
                try Task.checkCancellation()
                accumulatedTokens.append(tokenId)
                totalOutputTokens += 1

            /// MLX path: text chunks already decoded — accumulate directly.
            case .text(let text):
                try Task.checkCancellation()
                totalOutputTokens += 1
                accumulatedText = (accumulatedText ?? "") + text

            /// Capture generation completion reason.
            case .done(let reason):
                finishReason = stopReasonToString(reason) ?? "stop"

            /// Log and propagate inference errors.
            case .error(let errorMsg):
                finishReason = "error"
                logger.error("Generation error: \(errorMsg)")
            }
        }
    } catch {
        logger.error("Non-stream token consumption failed: \(error)")
        throw AppError.inferenceFailed(error.localizedDescription)
    }

    /// Detokenize full accumulated token array to get complete output text.
    /// MLX path uses pre-decoded accumulatedText; CoreAI path detokenizes tokens.
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

    // MARK: Post-inference Self-Correction (zero overhead when disabled)
    var finalContent = content
    if shouldRunSelfCorrection(request) {
        let sessionId = resolveSessionId(for: request)
        let originalPrompt = messages.first(where: { $0.role == "user" })?.textContent()
            ?? request.messages.first?.textContent() ?? ""
        let fallbackContent = finalContent
        do {
            let result = try await selfCorrectionPipeline.evaluate(
                prompt: originalPrompt,
                response: finalContent,
                sessionId: sessionId,
                generate: { systemOverride, examples in
                    // Re-generate with corrected system prompt.
                    // Build a corrected message list and re-run inference.
                    let correctedSampling = sampling
                    let correctedOpts = options
                    let correctedStream = handle.generateFromMessages(
                        messages: buildCorrectedMessages(
                            original: messages,
                            systemOverride: systemOverride,
                            examples: examples
                        ),
                        sampling: correctedSampling,
                        options: correctedOpts
                    )
                    var accTokens: [Int32] = []
                    var accText: String? = nil
                    for try await evt in correctedStream {
                        switch evt.kind {
                        case .token(let id):
                            accTokens.append(id)
                        case .text(let txt):
                            accText = (accText ?? "") + txt
                        case .done: break
                        case .error(let msg):
                            logger.warning("Self-correction re-gen error: \(msg)")
                        }
                    }
                    if let pre = accText { return pre }
                    do {
                        return try await handle.detokenize(tokens: accTokens)
                    } catch {
                        return fallbackContent
                    }
                },
                logger: logger,
                persistMemory: { event in
                    _ = await sessionCompressor.addMemory(event)
                }
            )
            finalContent = result.finalResponse
            logger.info("Self-correction converged at phase \(result.finalPhase) in \(result.iterations) iterations")
        } catch {
            logger.warning("Self-correction failed: \(error); using original response")
        }
    }

    /// Detect tool calls if the request included tool definitions.
    let toolCalls: [ToolCall]?
    if let tools = request.tools, !tools.isEmpty {
        toolCalls = parseToolCalls(from: finalContent)
    } else {
        toolCalls = nil
    }

    /// Override finish reason if tool calls were detected.
    let finishReasonFinal = toolCalls != nil ? "tool_calls" : finishReason

    /// Build response choice with assistant message + tool calls.
    let choice = CompletionChoice(
        message: AssistantMessage(content: toolCalls != nil ? "" : finalContent, toolCalls: toolCalls),
        finishReason: finishReasonFinal
    )

    /// Record inference metrics.
    let dur = startTime.duration(to: ContinuousClock.now)
    let elapsed = Double(dur.components.seconds) * 1000 + Double(dur.components.attoseconds) / 1e15
    await metrics.observeInferenceDuration(elapsed / 1_000.0)
    await metrics.incrementTokens(kind: "generated", count: totalOutputTokens)
    await metrics.incrementTokens(kind: "prompt", count: tokens.count)

    /// Assemble full ChatCompletion response with usage statistics.
    let completion = ChatCompletion(
        id: requestId,
        created: created,
        model: modelId,
        choices: [choice],
        usage: Usage(input: tokens.count, output: totalOutputTokens)
    )

    /// Persist conversation to SQLite (fire-and-forget, non-blocking).
    Task {
        await persistConversation(
            request: request,
            messages: messages,
            assistantContent: finalContent,
            modelId: modelId,
            promptTokens: tokens.count,
            outputTokens: totalOutputTokens,
            compressor: sessionCompressor
        )
    }

    logger.info("Non-stream request completed")

    var headers: HTTPFields = [:]
    headers[.contentType] = "application/json"
    let bodyData = try JSONEncoder().encode(completion)
    return Response(status: .ok, headers: headers, body: .init(contentsOf: [ByteBuffer(data: bodyData)]))
}

// MARK: - SSE Stream with Tool Calling

/// Handle SSE streaming chat completion with tool call support.
///
/// Uses incremental decode with prefix preservation:
/// accumulates tokens → full detokenize → diff extraction on each step.
/// Aligned with Apple `respondVanilla` strategy; prevents multi-byte UTF-8 truncation.
///
/// - Parameters:
///   - handle: Acquired engine handle
///   - tokens: Tokenized input prompt
///   - sampling: Normalized sampling configuration
///   - options: Inference options (maxTokens, logits)
///   - request: Original chat completion request
///   - modelId: Model identifier
///   - logger: Observability logger
///   - metrics: Shared metrics registry for recording inference metrics
/// - Returns: SSE ``Response`` with NDJSON ``ChatCompletionChunk`` payloads
private func streamWithToolCalling(
    handle: EngineHandle,
    tokens: [Int32],
    messages: [Message],
    sampling: SamplingConfiguration,
    options: InferenceOptions,
    request: ChatCompletionRequest,
    modelId: String,
    sessionCompressor: SessionCompressor,
    logger: Logger,
    metrics: MetricsRegistry
) async throws -> Response {
    /// Configure SSE-compliant response headers.
    let responseHeaders = SSEHeaders

    /// Stream NDJSON content via AsyncStream.
    let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()

    // Cancellation token: bridges client disconnect → inference loop
    let canceller = InferenceCancellation.cancellable()

    _ = Task {
        /// Generate unique request ID for this stream session.
        let requestId = "req-\(UUID().uuidString.prefix(8))"
        let created = Int64(Date().timeIntervalSince1970)

        /// Record inference start time for metrics.
        let startTime = ContinuousClock.now
        var ttfbTime: ContinuousClock.Instant? = nil

        /// Streaming output safety guard — reused for every chunk
        let streamGuard = await OcoreaiEngine.shared.activeContentGuard

        /// Mark session active — resets KV cache idle eviction timer.
        await handle.markActive()

        /// Start inference — MLX path passes messages directly to ChatSession.
        let tokenStream = handle.generateFromMessages(
            messages: messages,
            sampling: sampling,
            options: options,
            cancellation: canceller
        )

        var totalOutputTokens = 0
        var accumulatedTokens: [Int32] = []
        var prevDecodedText = ""
        /// Batch decode interval — detokenize every N tokens to avoid O(n²).
        let decodeBatchSize = 8

        /// Consume and process each stream event.
        do {
            for try await event in tokenStream {
                switch event.kind {

                /// .token — batch detokenize with prefix preservation.
                case .token(let tokenId):
                    try Task.checkCancellation()
                    accumulatedTokens.append(tokenId)
                    totalOutputTokens += 1

                    /// Record TTFB on first token.
                    if ttfbTime == nil {
                        ttfbTime = ContinuousClock.now
                    }

                    /// Only detokenize every N tokens or on final batch.
                    guard accumulatedTokens.count % decodeBatchSize == 0 || totalOutputTokens == options.maxTokens else { continue }

                    /// Batch detokenize of accumulated tokens for prefix safety.
                    let newText: String
                    do {
                        newText = try await handle.detokenize(tokens: accumulatedTokens)
                    } catch {
                        logger.warning("Batch detokenization failed (size=\(accumulatedTokens.count)), falling back")
                        continue
                    }

                    /// Extract delta (new text since last chunk) — UTF-8 byte safe.
                    var deltaText: String
                    if newText.hasPrefix(prevDecodedText) {
                        deltaText = String(newText.dropFirst(prevDecodedText.count))
                    } else {
                        // Detokenization reformatted; send full new text as fallback.
                        deltaText = newText
                    }

                    /// Emit SSE chunk if there's new text (with safety filter).
                    if !deltaText.isEmpty {
                        // Safety check: filter harmful output in real-time
                        if let contentGuard = streamGuard {
                            let checkResult = await contentGuard.checkOutput(deltaText)
                            if !checkResult.passed {
                                logger.warning("Streaming output blocked: \(checkResult.triggeredCategories)")
                                yieldSSERaw("[SSEError: Output blocked by content guard: \(checkResult.rejectionReason ?? "Safety violation")]", to: continuation)
                                continuation.finish()
                                return
                            }
                        }
                        let choice = ChunkChoice(
                            delta: ChatDelta(content: deltaText),
                            finishReason: nil
                        )
                        let chunk = ChatCompletionChunk(
                            id: requestId,
                            created: created,
                            model: modelId,
                            choices: [choice]
                        )
                        _ = yieldSSE(chunk, to: continuation)
                    }
                    prevDecodedText = newText

                /// .text — MLX path: text chunks already decoded, stream directly.
                case .text(let text):
                    try Task.checkCancellation()
                    totalOutputTokens += 1

                    if ttfbTime == nil {
                        ttfbTime = ContinuousClock.now
                    }

                    // Safety check: filter harmful output in real-time
                    if let contentGuard = streamGuard {
                        let checkResult = await contentGuard.checkOutput(text)
                        if !checkResult.passed {
                            logger.warning("Streaming output blocked (.text): \(checkResult.triggeredCategories)")
                            yieldSSERaw("[SSEError: Output blocked by content guard: \(checkResult.rejectionReason ?? "Safety violation")]", to: continuation)
                            continuation.finish()
                            return
                        }
                    }

                    prevDecodedText.append(text)
                    let tChoice = ChunkChoice(
                        delta: ChatDelta(content: text),
                        finishReason: nil
                    )
                    let tChunk = ChatCompletionChunk(
                        id: requestId,
                        created: created,
                        model: modelId,
                        choices: [tChoice]
                    )
                    _ = yieldSSE(tChunk, to: continuation)

                /// .done — flush remaining tokens, detect tool calls, send stop chunk.
                case .done(let reason):
                    /// Final flush: detokenize any remaining tokens not yet emitted.
                    if !accumulatedTokens.isEmpty && accumulatedTokens.count % decodeBatchSize != 0 {
                        do {
                            let finalText = try await handle.detokenize(tokens: accumulatedTokens)
                            if finalText.hasPrefix(prevDecodedText) {
                                let remainder = String(finalText.dropFirst(prevDecodedText.count))
                                if !remainder.isEmpty {
                                    // Safety check: final flush content
                                    if let contentGuard = streamGuard {
                                        let checkResult = await contentGuard.checkOutput(remainder)
                                        if !checkResult.passed {
                                            logger.warning("Streaming output blocked (final flush): \(checkResult.triggeredCategories)")
                                            yieldSSERaw("[SSEError: Output blocked by content guard: \(checkResult.rejectionReason ?? "Safety violation")]", to: continuation)
                                            continuation.finish()
                                            return
                                        }
                                    }
                                    let choice = ChunkChoice(
                                        delta: ChatDelta(content: remainder),
                                        finishReason: nil
                                    )
                                    let chunk = ChatCompletionChunk(
                                        id: requestId,
                                        created: created,
                                        model: modelId,
                                        choices: [choice]
                                    )
                                    _ = yieldSSE(chunk, to: continuation)
                                    prevDecodedText = finalText
                                }
                            }
                        } catch {
                            logger.warning("Final flush detokenization failed: \(error)")
                        }
                    }

                    let finishReason = stopReasonToString(reason) ?? "stop"
                    var finalFinishReason = finishReason

                    /// Check for tool calls at stream end.
                    if let tools = request.tools, !tools.isEmpty {
                        if let toolCalls = parseToolCalls(from: prevDecodedText) {
                            finalFinishReason = "tool_calls"
                            /// Send individual tool call delta chunks.
                            for tc in toolCalls {
                                let tcChunk = ChatCompletionChunk(
                                    id: requestId,
                                    created: created,
                                    model: modelId,
                                    choices: [ChunkChoice(
                                        delta: ChatDelta(
                                            role: "assistant",
                                            toolCalls: [tc]
                                        ),
                                        finishReason: "tool_calls"
                                    )]
                                )
                                _ = yieldSSE(tcChunk, to: continuation)
                            }
                        }
                    }

                    /// Send final stop chunk with finish reason.
                    let stopChunk = ChatCompletionChunk(
                        id: requestId,
                        created: created,
                        model: modelId,
                        choices: [ChunkChoice(
                            delta: ChatDelta(content: nil),
                            finishReason: finalFinishReason
                        )]
                    )
                    _ = yieldSSE(stopChunk, to: continuation)
                    break

                /// .error — send error chunk and terminate.
                case .error(let errorMsg):
                    let errChunk = ChatCompletionChunk(
                        id: requestId,
                        created: created,
                        model: modelId,
                        choices: [ChunkChoice(
                            delta: ChatDelta(content: "[error: \(errorMsg)]"),
                            finishReason: "error"
                        )]
                    )
                    _ = yieldSSE(errChunk, to: continuation)
                    break
                }
            }
        } catch {
            /// Stream consumption error — yield error + done markers.
            logger.error("Stream token consumption failed: \(error)")
            let errChunk = ChatCompletionChunk(
                id: requestId,
                created: created,
                model: modelId,
                choices: [ChunkChoice(
                    delta: ChatDelta(content: "[error: \(error.localizedDescription)]"),
                    finishReason: "error"
                )]
            )
            _ = yieldSSE(errChunk, to: continuation)
            yieldSSERaw("[done]", to: continuation)
            continuation.finish()
            return
        }

        /// Yield final done marker to close the SSE stream.
        yieldSSERaw("[done]", to: continuation)

        /// Observe inference duration + TTFB metrics at stream completion.
        let infDur = startTime.duration(to: ContinuousClock.now)
        let inferenceDurationMs = Double(infDur.components.seconds) * 1000 + Double(infDur.components.attoseconds) / 1e15
        var ttfbMsVal: Double = 0
        if let ttfbTimeVal = ttfbTime {
            let ttfbDur = ttfbTimeVal.duration(to: ContinuousClock.now)
            ttfbMsVal = Double(ttfbDur.components.seconds) * 1000 + Double(ttfbDur.components.attoseconds) / 1e15
        }
        await metrics.observeInferenceDuration(
            ms: inferenceDurationMs,
            inputTokens: tokens.count,
            outputTokens: totalOutputTokens,
            ttfbMs: String(format: "%.1f", ttfbMsVal),
            modelId: modelId
        )

        /// Persist stream conversation to SQLite
        await persistConversation(
            request: request,
            messages: messages,
            assistantContent: prevDecodedText,
            modelId: modelId,
            promptTokens: tokens.count,
            outputTokens: totalOutputTokens,
            compressor: sessionCompressor
        )

        // MARK: Post-stream Self-Correction Trace (Phase 1 only — zero token cost)
        // Inline correction is too expensive for SSE; instead run the fast rule-based
        // critique and persist the trace for post-stream analysis.
        if shouldRunSelfCorrection(request) {
            let lastContent = prevDecodedText
            Task {
                let sessionId = resolveSessionId(for: request)
                let originalPrompt = messages.first(where: { $0.role == "user" })?.textContent()
                    ?? request.messages.first?.textContent() ?? ""
                do {
                    let _ = try await selfCorrectionPipeline.evaluate(
                        prompt: originalPrompt,
                        response: lastContent,
                        sessionId: sessionId,
                        generate: { _, _ in lastContent }, // no-op: stream already sent
                        logger: logger,
                        persistMemory: { event in
                            _ = await sessionCompressor.addMemory(event)
                        }
                    )
                } catch {
                    logger.warning("Post-stream self-correction trace failed: \(error)")
                }
            }
        }

        logger.info("Stream request completed")
        continuation.finish()
    }

    return Response(
        status: .ok,
        headers: responseHeaders,
        body: .init(asyncSequence: stream)
    )
}

// MARK: - Persistence Helper

/// Persist user/assistant messages to SQLite after inference completes.
/// Fire-and-forget — errors are logged but do not affect the response.
private func persistConversation(
    request: ChatCompletionRequest,
    messages: [Message],
    assistantContent: String,
    modelId: String,
    promptTokens: Int,
    outputTokens: Int,
    compressor: SessionCompressor
) async {
    let logger = Logger(label: "ocoreai.persist")

    do {
        // Resolve session: use request.sessionID as database id if parseable, else create new
        let sessionId: Int64
        if let sidStr = request.sessionID, let sid = Int64(sidStr) {
            sessionId = sid
        } else {
            sessionId = try await compressor.createSession(modelId: modelId)
        }

        // Persist user messages (skip system + assistant)
        let userMsgCount = messages.filter { $0.role != "system" && $0.role != "assistant" }.count
        let tokensPerMsg = max(1, promptTokens / max(1, userMsgCount))

        for msg in messages where msg.role != "system" && msg.role != "assistant" {
            let text = msg.textContent()
            try await compressor.addMessage(
                sessionId: sessionId,
                role: msg.role,
                content: text,
                tokenCount: tokensPerMsg
            )
        }

        // Persist assistant response
        try await compressor.addMessage(
            sessionId: sessionId,
            role: "assistant",
            content: assistantContent,
            tokenCount: outputTokens
        )
    } catch {
        // Non-fatal — response already sent to client
        logger.error("Persist failed: \(error)")
    }
}

/// Extract plain text from Message.content
extension Message {
    func textContent() -> String {
        switch content {
        case .text(let s): return s
        case .parts(let parts): return parts.compactMap { $0.text }.joined(separator: " ")
        case .none: return ""
        }
    }
}
/// SSEErrorWrapper has been replaced by yieldSSE(yieldSSError:) + ChatCompletionChunk.
/// All error paths now use structured chat chunk format consistently.
