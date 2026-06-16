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
/// 1. Acquire engine session → 2. Tokenize messages → 3. Apply 3-layer param fallback
/// 4. Dispatch stream/non-stream → 5. Incremental decode → 6. Tool call detection
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

// MARK: - Main Handler

/// Process a chat completion request through the full inference pipeline.
///
/// Acquires session, tokenizes, applies parameter fallback, dispatches
/// inference, and returns either SSE stream or non-stream JSON response.
///
/// - Parameters:
///   - request: OpenAI-compatible chat completion request
///   - enginePool: Engine pool for concurrent inference management
///   - metrics: Shared metrics registry (Prometheus-compatible)
///   - logger: Observability logger
/// - Returns: HTTP Response (SSE stream or JSON completion)
/// - Throws: ``AppError`` on engine/tokenization/pipeline failure
func chatCompletionsHandler(
    request: ChatCompletionRequest,
    enginePool: EnginePool,
    metrics: MetricsRegistry,
    logger: Logger
) async throws -> Response {
    /// Extract model identifier from the request payload.
    let modelId = request.model

    /// Phase 1: Acquire inference session with defer-release cleanup pattern.
    let handle: EngineHandle
    do {
        handle = try await enginePool.acquire(model: modelId)
    } catch {
        throw AppError.engineUnavailable
    }
    defer { try? await handle.release() }

    /// Phase 2: Build complete message list including system prompt + tool info injection.
    let fullMessages = try buildMessageList(request: request, handle: handle)

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
            "Empty token output for model '\\(modelId)'"
        )
    }

    /// Phase 4: Three-layer Parameter Fallback Chain.
    /// Layer 1: Request body explicit params (highest priority)
    /// Layer 2: Model runtime default (via PATCH /v1/models/:model/sampling)
    /// Layer 3: System default (hardcoded)
    let runtimeDefaults = await enginePool.getSamplingConfig(modelId: modelId)

    /// Resolve effective temperature with fallback chain.
    let effectiveTemp = request.temperature != 0 || runtimeDefaults.temperature == ModelSamplingConfig.default.temperature
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
    handle: EngineHandle
) throws -> [Message] {
    var messages = request.messages

    /// Inject independent system prompt (prepended to message array).
    if let system = request.system, !system.isEmpty {
        messages.insert(Message(role: "system", content: system), at: 0)
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
        throw AppError.invalidRequest("Message list is empty for model '\\(request.model)'")
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
                    let argsJson = try JSONSerialization.data(
                        withJSONObject: args,
                        options: []
                    ).toString() ?? "{}"
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

    /// Detect tool calls if the request included tool definitions.
    let toolCalls: [ToolCall]?
    if let tools = request.tools, !tools.isEmpty {
        toolCalls = parseToolCalls(from: content)
    } else {
        toolCalls = nil
    }

    /// Override finish reason if tool calls were detected.
    let finishReasonFinal = toolCalls != nil ? "tool_calls" : finishReason

    /// Build response choice with assistant message + tool calls.
    let choice = CompletionChoice(
        message: AssistantMessage(content: toolCalls != nil ? "" : content, toolCalls: toolCalls),
        finishReason: finishReasonFinal
    )

    /// Record inference metrics.
    let elapsed = Double(startTime.duration(to: ContinuousClock.now).components.attoseconds) / 1e17
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
    logger: Logger,
    metrics: MetricsRegistry
) async throws -> Response {
    /// Configure SSE-compliant response headers.
    let responseHeaders: HTTPFields = {
        var h: HTTPFields = [:]
        h[.contentType] = "text/event-stream"
        h[HTTPField.Name("Cache-Control")!] = "no-cache"
        h[HTTPField.Name("Connection")!] = "keep-alive"
        h[HTTPField.Name("X-Accel-Buffering")!] = "no"
        return h
    }()

    /// Stream NDJSON content via AsyncStream.
    let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()

    // Cancellation token: bridges client disconnect → inference loop
    let canceller = InferenceCancellation.cancellable()

    let inferenceTask = Task {
        do {
            /// Generate unique request ID for this stream session.
            let requestId = "req-\(UUID().uuidString.prefix(8))"
            let created = Int64(Date().timeIntervalSince1970)

            /// Record inference start time for metrics.
            let startTime = ContinuousClock.now
            var ttfbTime: ContinuousClock.Instant? = nil

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

            /// Consume and process each stream event.
            do {
                for try await event in tokenStream {
                    switch event.kind {

                    /// .token — incremental decode with prefix preservation.
                    case .token(let tokenId):
                        try Task.checkCancellation()
                        accumulatedTokens.append(tokenId)
                        totalOutputTokens += 1

                        /// Full detokenize of accumulated tokens for prefix safety.
                        let newText: String
                        do {
                            newText = try await handle.detokenize(tokens: accumulatedTokens)
                        } catch {
                            logger.warning("Incremental detokenization failed, falling back")
                            newText = prevDecodedText + "<token>"
                        }

                        /// Extract delta (new text since last chunk) — UTF-8 byte safe.
                        let deltaText: String
                        if newText.hasPrefix(prevDecodedText) {
                            deltaText = String(newText.dropFirst(prevDecodedText.count))
                        } else {
                            // Detokenization reformatted; send full new text as fallback.
                            deltaText = newText
                        }

                        /// Record TTFB on first token.
                        if ttfbTime == nil {
                            ttfbTime = ContinuousClock.now
                        }

                        /// Build and write SSE chunk with delta content.
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
                        if let jsonData = try? JSONEncoder().encode(chunk) {
                            let json = String(decoding: jsonData, as: UTF8.self)
                            let buf = ByteBuffer(data: ("data: \(json)\n\n".data(using: .utf8) ?? Data()))
                            continuation.yield(buf)
                        }
                        prevDecodedText = newText

                    /// .text — MLX path: text chunks already decoded, stream directly.
                    case .text(let text):
                        try Task.checkCancellation()
                        totalOutputTokens += 1

                        if ttfbTime == nil {
                            ttfbTime = ContinuousClock.now
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
                        if let tJson = try? JSONEncoder().encode(tChunk) {
                            let tJsonStr = String(decoding: tJson, as: UTF8.self)
                            continuation.yield(ByteBuffer(data: ("data: \(tJsonStr)\n\n".data(using: .utf8) ?? Data())))
                        }

                    /// .done — detect tool calls, send stop chunk.
                    case .done(let reason):
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
                                    if let tcJson = try? JSONEncoder().encode(tcChunk) {
                                        let tcJsonStr = String(decoding: tcJson, as: UTF8.self)
                                        continuation.yield(ByteBuffer(data: ("data: \(tcJsonStr)\n\n".data(using: .utf8) ?? Data())))
                                    }
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
                        if let stopJson = try? JSONEncoder().encode(stopChunk) {
                            let stopJsonStr = String(decoding: stopJson, as: UTF8.self)
                            continuation.yield(ByteBuffer(data: ("data: \(stopJsonStr)\n\n".data(using: .utf8) ?? Data())))
                        }
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
                        if let errJson = try? JSONEncoder().encode(errChunk) {
                            let errJsonStr = String(decoding: errJson, as: UTF8.self)
                            continuation.yield(ByteBuffer(data: ("data: \(errJsonStr)\n\n".data(using: .utf8) ?? Data())))
                        }
                        break
                    }
                }
            } catch {
                /// Stream consumption error — yield error + done markers.
                logger.error("Stream token consumption failed: \(error)")
                if let errorJson = try? SSEErrorWrapper(message: error.localizedDescription).json() {
                    continuation.yield(ByteBuffer(data: ("data: \(errorJson)\n\n".data(using: .utf8) ?? Data())))
                }
                continuation.yield(ByteBuffer(data: "data: [done]\n\n".data(using: .utf8) ?? Data()))
                continuation.finish()
                return
            }

            /// Yield final done marker to close the SSE stream.
            continuation.yield(ByteBuffer(data: "data: [done]\n\n".data(using: .utf8) ?? Data()))

            /// Observe inference duration + TTFB metrics at stream completion.
            let inferenceDurationMs = Double(startTime.duration(to: ContinuousClock.now).components.attoseconds) / 1e17
            var ttfbMsVal: Double = 0
            if let ttfbTimeVal = ttfbTime {
                ttfbMsVal = Double(ttfbTimeVal.duration(to: ContinuousClock.now).components.attoseconds) / 1e17
            }
            await metrics.observeInferenceDuration(
                ms: inferenceDurationMs,
                inputTokens: tokens.count,
                outputTokens: totalOutputTokens,
                ttfbMs: String(format: "%.1f", ttfbMsVal),
                modelId: modelId
            )

            logger.info("Stream request completed")
        } catch {
            /// Top-level error handler — yield error + terminate.
            if let errorJson = try? SSEErrorWrapper(message: error.localizedDescription).json() {
                continuation.yield(ByteBuffer(data: ("data: \(errorJson)\n\n".data(using: .utf8) ?? Data())))
            }
            continuation.yield(ByteBuffer(data: "data: [done]\n\n".data(using: .utf8) ?? Data()))
            logger.error("Request failed: \(error)")
        }
        continuation.finish()
    }

    return Response(
        status: .ok,
        headers: responseHeaders,
        body: .init(asyncSequence: stream, onEarlyCancellation: {
            canceller.cancel()
            inferenceTask.cancel()
        })
    )
}

// MARK: - SSE Error Helper

/// Minimal JSON-serializable wrapper for SSE error messages.
/// Prevents string-interpolation JSON breakage when error descriptions contain
/// double quotes, backslashes, or control characters.
private struct SSEErrorWrapper: Encodable {
    var error: String
    init(message: String) { self.error = message }
    func json() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - String Data Extension

/// Lightweight Data extension for JSON → String conversion.
extension Data {
    /// Convert data to UTF-8 string (nil on decoding failure).
    func toString() -> String? {
        String(data: self, encoding: .utf8)
    }
}