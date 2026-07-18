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

#if canImport(CoreAI)
	import CoreAI
	import CoreAILanguageModels
#endif
import Foundation
import HTTPTypes
import Hummingbird
import Logging

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
	systemPromptBuilder _: SystemPromptBuilder,
	logger: Logger,
) async throws -> Response {
	let modelId = request.model

	// Capture content guard early — used for both input and output safety
	let streamGuard: ContentGuard? = await OcoreaiEngine.shared.activeContentGuard

	// Safety check: filter harmful input before scheduling
	if let contentGuard = streamGuard {
		let messageText: String = if let first = request.messages.first, let content = first.content {
			switch content {
			case let .text(s): s
			case let .blocks(blocks): blocks.compactMap(\.text).joined(separator: "\n")
			}
		} else {
			""
		}
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
				guard let data = try? JSONSerialization.data(withJSONObject: errorBody, options: []) else {
					return Response(status: .badRequest)
				}
				var headers: HTTPFields = [:]
				headers[.contentType] = "application/json"
				return Response(status: .badRequest, headers: headers, body: .init(contentsOf: [ByteBuffer(data: data)]))
			}
		}
	}

	// Prompt injection detection — uses precompiled regex from AuthConfig
	if AuthConfig.default.promptInjectionEnabled {
		// Convert Anthropic messages to internal Message for detection
		let chatReq = toChatCompletionRequest(request)
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
			guard let data = try? JSONSerialization.data(withJSONObject: errorBody, options: []) else {
				return Response(status: .badRequest)
			}
			var headers: HTTPFields = [:]
			headers[.contentType] = "application/json"
			return Response(status: .badRequest, headers: headers, body: .init(contentsOf: [ByteBuffer(data: data)]))
		}
	}

	// ═══════════════════════════════════════════════════════
	// Convert Anthropic → internal ChatCompletionRequest
	// ═══════════════════════════════════════════════════════
	let chatRequest = toChatCompletionRequest(request)

	// ═══════════════════════════════════════════════════════
	// Phase 1: Submit to scheduler (OOMGuard + priority queue)
	// ═══════════════════════════════════════════════════════
	// Helper: extract prompt text from first Anthropic message
	let promptText: String
	if let first = request.messages.first, let content = first.content {
		switch content {
		case let .text(s): promptText = s
		case let .blocks(blocks):
			let texts = blocks.compactMap(\.text).joined(separator: "\n")
			promptText = texts.isEmpty ? "" : texts
		}
	} else {
		promptText = ""
	}

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
			await scheduler.fail(schedulingRequest.id, with: "Higher-priority request dispatched first")
			throw AppError.engineUnavailable
		}
	} catch let e as SchedulerError {
		await scheduler.fail(schedulingRequest.id, with: e.localizedDescription)
		switch e {
		case .admissionRefused, .oomRefused:
			throw AppError.engineUnavailable
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

	// Phase 2: Build messages + tokenize
	// ═══════════════════════════════════════════════════════
	let fullMessages = try buildAnthropicMessageList(request: request, handle: handle)

	let tokens: [Int32]
	do {
		tokens = try await handle.tokenize(messages: fullMessages)
	} catch {
		throw AppError.tokenizationFailed(error.localizedDescription)
	}

	guard !tokens.isEmpty else {
		throw AppError.tokenizationFailed("Empty token output for model '\(modelId)'")
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
		stopSequences: request.stopSequences,
		logitBias: nil,
		combined: true,
	)
	let sampling = rawSampling.normalized()

	let inferenceOpts = InferenceOptions(
		maxTokens: effectiveMaxTokens,
		includeLogits: false,
	)

	// ═══════════════════════════════════════════════════════
	// Phase 4: Dispatch to stream OR non-stream
	// ═══════════════════════════════════════════════════════
	if request.stream == true {
		return try await streamAnthropicResponse(
			handle: handle,
			tokens: tokens,
			messages: fullMessages,
			sampling: sampling,
			options: inferenceOpts,
			request: chatRequest,
			modelId: modelId,
			logger: logger,
			metrics: metrics,
			contentGuard: streamGuard,
		)
	} else {
		return try await nonStreamAnthropicResponse(
			handle: handle,
			tokens: tokens,
			messages: fullMessages,
			sampling: sampling,
			options: inferenceOpts,
			request: chatRequest,
			modelId: modelId,
			logger: logger,
			metrics: metrics,
			contentGuard: streamGuard,
		)
	}
}

// MARK: - Message Construction

/// Build message list with Anthropic conventions:
/// - system prompt injected as system message
/// - tool definitions prepended if tools present
private func buildAnthropicMessageList(
	request: AnthropicMessageRequest,
	handle _: EngineHandle,
) throws -> [Message] {
	var messages: [Message] = request.messages.map { msg in
		switch msg.content {
		case let .some(.text(s)):
			return Message(role: msg.role, content: .text(s))
		case let .some(.blocks(blocks)):
			let texts = blocks.compactMap { b -> String? in
				switch b.type {
				case .text: return b.text
				case .toolUse: return nil
				}
			}.joined(separator: "\n")
			return Message(role: msg.role, content: texts.isEmpty ? nil : .text(texts))
		case .none:
			return Message(role: msg.role, content: nil)
		}
	}

	// Inject system prompt
	if let system = request.system, !system.isEmpty {
		messages.insert(Message(role: "system", content: .text(system)), at: 0)
	}

	// Inject tool definitions
	if let tools = request.tools, !tools.isEmpty {
		let toolDefs = tools.compactMap { tool -> String? in
			let desc = tool.description ?? ""
			return "## Tool: \(tool.name)\nDescription: \(desc)"
		}.joined(separator: "\n\n")

		if !toolDefs.isEmpty {
			if let idx = messages.firstIndex(where: { $0.role == "system" }) {
				if case var .text(existing) = messages[idx].content {
					existing += "\n\nAvailable tools:\n\(toolDefs)"
					messages[idx].content = .text(existing)
				}
			} else {
				messages.insert(
					Message(role: "system", content: .text(
						"You have access to the following tools:\n\n\(toolDefs)",
					)),
					at: 0,
				)
			}
		}
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
	tokens: [Int32],
	messages: [Message],
	sampling: SamplingConfiguration,
	options: InferenceOptions,
	request _: ChatCompletionRequest,
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

	do {
		for try await event in tokenStream {
			switch event.kind {
			case let .token(tokenId):
				try Task.checkCancellation()
				accumulatedTokens.append(tokenId)
				totalOutputTokens += 1

			case let .text(text):
				try Task.checkCancellation()
				totalOutputTokens += 1
				accumulatedText = (accumulatedText ?? "") + text

			case let .done(reason, _):
					let openaiReason = stopReasonToString(reason) ?? "stop"
				finishReason = openAIToAnthropicStopReason(openaiReason)

			case let .error(errorMsg):
				finishReason = "error"
				logger.error("Generation error: \(errorMsg)")
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
			logger.warning("Anthropic non-stream output blocked: \(checkResult.triggeredCategories)")
			let detail = NSDictionary(dictionary: [
				"message": checkResult.rejectionReason ?? "Content safety violation",
				"type": "content_policy_violation",
				"code": 400,
				"categories": checkResult.triggeredCategories.map(\.rawValue),
			])
			let errorBody = NSDictionary(dictionary: ["error": detail])
			guard let data = try? JSONSerialization.data(withJSONObject: errorBody, options: []) else {
				return Response(status: .badRequest)
			}
			var headers: HTTPFields = [:]
			headers[.contentType] = "application/json"
			return Response(status: .badRequest, headers: headers, body: .init(contentsOf: [ByteBuffer(data: data)]))
		}
	}

	// Record metrics
	let dur = startTime.duration(to: ContinuousClock.now)
	let elapsed = Double(dur.components.seconds) * 1000 + Double(dur.components.attoseconds) / 1e15
	await metrics.observeInferenceDuration(elapsed / 1000.0)
	await metrics.incrementTokens(kind: "generated", count: totalOutputTokens)
	await metrics.incrementTokens(kind: "prompt", count: tokens.count)

	// Build Anthropic response
	let assistantContent = AnthropicAssistantContent(text: content)
	let usage = AnthropicUsage(inputTokens: tokens.count, outputTokens: totalOutputTokens)

	let response = AnthropicMessageResponse(
		id: requestId,
		content: [assistantContent],
		model: modelId,
		stopReason: finishReason.isEmpty ? nil : finishReason,
		usage: usage,
	)

	logger.info("Anthropic non-stream request completed")

	var headers: HTTPFields = [:]
	headers[.contentType] = "application/json"
	let bodyData = try JSONEncoder().encode(response)
	return Response(status: .ok, headers: headers, body: .init(contentsOf: [ByteBuffer(data: bodyData)]))
}

// MARK: - SSE Stream Response

/// Handle streaming Anthropic Messages request.
private func streamAnthropicResponse(
	handle: EngineHandle,
	tokens: [Int32],
	messages: [Message],
	sampling: SamplingConfiguration,
	options: InferenceOptions,
	request _: ChatCompletionRequest,
	modelId: String,
	logger: Logger,
	metrics: MetricsRegistry,
	contentGuard: ContentGuard? = nil,
) async throws -> Response {
	let responseHeaders = SSEHeaders

	let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()

	// Cancellation token: bridges client disconnect → inference loop
	let canceller = InferenceCancellation.cancellable()

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

			// Emit message_start event
			let startResponse = AnthropicMessageResponse(
				id: requestId,
				content: [],
				model: modelId,
				stopReason: nil,
				usage: AnthropicUsage(inputTokens: tokens.count, outputTokens: 0),
			)
			let messageStart = AnthropicStreamEvent.messageStart(message: startResponse)
			writeSSEEvent(continuation, event: messageStart)

			// Emit content_block_start
			let blockStart = AnthropicStreamEvent.contentBlockStart(index: 0)
			writeSSEEvent(continuation, event: blockStart)

			// Consume tokens and stream deltas
			do {
				for try await event in tokenStream {
					switch event.kind {
					case let .token(tokenId):
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

						let deltaText: String = if newText.hasPrefix(prevDecodedText) {
							String(newText.dropFirst(prevDecodedText.count))
						} else {
							newText
						}
						prevDecodedText = newText

						// Safety check: filter harmful output in real-time
						if let contentGuard = streamGuard {
							let checkResult = await contentGuard.checkOutput(deltaText)
							if !checkResult.passed {
								logger.warning("Anthropic streaming output blocked: \(checkResult.triggeredCategories)")
								let errorEvent = AnthropicStreamEvent(
									type: "error", index: nil, message: nil, delta: nil,
									usage: AnthropicStreamUsage(outputTokens: totalOutputTokens, inputTokens: tokens.count),
								)
								writeSSEEvent(continuation, event: errorEvent)
								continuation.finish()
								return
							}
						}

						// Emit delta event
						let deltaEvent = AnthropicStreamEvent.textDelta(index: 0, text: deltaText)
						writeSSEEvent(continuation, event: deltaEvent)

					case let .text(text):
						try Task.checkCancellation()
						totalOutputTokens += 1

						// Safety check: filter harmful output in real-time
						if let contentGuard = streamGuard {
							let checkResult = await contentGuard.checkOutput(text)
							if !checkResult.passed {
								logger.warning("Anthropic streaming output blocked (.text): \(checkResult.triggeredCategories)")
								let errorEvent = AnthropicStreamEvent(
									type: "error", index: nil, message: nil, delta: nil,
									usage: AnthropicStreamUsage(outputTokens: totalOutputTokens, inputTokens: tokens.count),
								)
								writeSSEEvent(continuation, event: errorEvent)
								continuation.finish()
								return
							}
						}

						let deltaEvent = AnthropicStreamEvent.textDelta(index: 0, text: text)
						writeSSEEvent(continuation, event: deltaEvent)

					case .done(_, _):
						break

					case let .error(errorMsg):
						logger.error("Stream generation error: \(errorMsg)")
					}
				}
			} catch {
				logger.error("Stream token consumption failed: \(error)")
				throw AppError.inferenceFailed(error.localizedDescription)
			}

			// Emit content_block_stop
			let blockStop = AnthropicStreamEvent.contentBlockStop(index: 0)
			writeSSEEvent(continuation, event: blockStop)

			// Emit message_stop with final usage
			let finalEvent = AnthropicStreamEvent.messageStop(
				inputTokens: tokens.count,
				outputTokens: totalOutputTokens,
			)
			writeSSEEvent(continuation, event: finalEvent)

			// Record metrics
			let dur = startTime.duration(to: ContinuousClock.now)
			let elapsed = Double(dur.components.seconds) * 1000 + Double(dur.components.attoseconds) / 1e15
			await metrics.observeInferenceDuration(elapsed / 1000.0)
			await metrics.incrementTokens(kind: "generated", count: totalOutputTokens)
			await metrics.incrementTokens(kind: "prompt", count: tokens.count)

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
