// Copyright © 2022-2026 uingei@163.com.
// Licensed under MIT.
/// DirectInferenceClient.swift — SwiftUI → EnginePool Fast Path
///
/// Direct bridge between SwiftUI views and the inference engine.
/// Bypasses HTTP entirely — uses native `AsyncStream` for streaming
/// and typed `Message` objects for zero-serialization data flow.
///
/// ### Flow:
/// 1. UI sends ``InferenceRequest`` → 2. MessageBuilder assembles context
///    → 3. Scheduler submit (OOMGuard) → 4. EnginePool.acquire()
///    → 5. generateFromMessages() → 6. AsyncStream<InferenceEvent>
///    → 7. SwiftUI views consume text deltas in real-time

import Foundation

// MARK: - Inference Request

struct InferenceRequest {
	let modelId: String
	let messages: [Message]
	let systemPrompt: String?
	let tools: [ToolDef]?
	let sessionId: String?

	/// Sampling parameters (Double to match EnginePool / SamplingConfiguration)
	let temperature: Double?
	/// Stop sequences for generation control (from ChatCompletionRequest `.stop`)
	let stopSequences: [String]?
	/// Logit bias for token probability shaping
	let logitBias: [String: Double]?
	let topP: Double?
	let topK: Int?
	let maxTokens: Int?

	/// Cancellation token for mid-stream interrupt support.
	/// When nil (default), the request is non-cancellable.
	let cancellation: InferenceCancellation?

	init(
		modelId: String,
		messages: [Message],
		systemPrompt: String? = nil,
		tools: [ToolDef]? = nil,
		temperature: Double? = nil,
		topP: Double? = nil,
		topK: Int? = nil,
		maxTokens: Int? = nil,
		stopSequences: [String]? = nil,
		logitBias: [String: Double]? = nil,
		sessionId: String? = nil,
		cancellation: InferenceCancellation? = nil,
	) {
		self.modelId = modelId
		self.messages = messages
		self.systemPrompt = systemPrompt
		self.tools = tools
		self.temperature = temperature
		self.topP = topP
		self.topK = topK
		self.maxTokens = maxTokens
		self.stopSequences = stopSequences
		self.logitBias = logitBias
		self.sessionId = sessionId
		self.cancellation = cancellation
	}
}

// MARK: - Inference Result

struct StreamingInferenceResult {
	var accumulatedText: String
	var stopReason: String?
	var inputTokens: Int
	var outputTokens: Int
}

// MARK: - Direct Inference Client

@MainActor
final class DirectInferenceClient {
	static let shared = DirectInferenceClient()

	private init() {}

	/// Stream inference results directly from EnginePool.
	func stream(request: InferenceRequest) async throws -> AsyncStream<DirectChatChunk> {
		guard let engine = OcoreaiEngine.shared.activeEnginePool else {
			throw DirectInferenceError.engineNotReady
		}
		guard let messageBuilder = OcoreaiEngine.shared.activeMessageBuilder else {
			throw DirectInferenceError.messageBuilderNotReady
		}
		guard let scheduler = OcoreaiEngine.shared.activeScheduler else {
			throw DirectInferenceError.schedulerNotReady
		}

		// Safety check: filter harmful input before scheduling
		if let contentGuard = OcoreaiEngine.shared.activeContentGuard {
			let messageText = request.messages.map { $0.textContent() }.joined(separator: " ")
			let result = await contentGuard.checkInput(messageText)
			if result.isBlocked {
				throw DirectInferenceError.contentBlocked(result.rejectionReason ?? "Content safety violation")
			}
		}

		return AsyncStream(DirectChatChunk.self) { continuation in
			Task {
				do {
					try await self.doStreamInference(
						request: request,
						enginePool: engine,
						scheduler: scheduler,
						messageBuilder: messageBuilder,
						continuation: continuation,
					)
				} catch {
					continuation.finish()
				}
			}
		}
	}

	/// Non-streaming inference — returns complete result.
	func complete(request: InferenceRequest) async throws -> DirectInferenceResult {
		guard let engine = OcoreaiEngine.shared.activeEnginePool else {
			throw DirectInferenceError.engineNotReady
		}
		guard let messageBuilder = OcoreaiEngine.shared.activeMessageBuilder else {
			throw DirectInferenceError.messageBuilderNotReady
		}
		guard let scheduler = OcoreaiEngine.shared.activeScheduler else {
			throw DirectInferenceError.schedulerNotReady
		}

		return try await doCompleteInference(
			request: request,
			enginePool: engine,
			scheduler: scheduler,
			messageBuilder: messageBuilder,
		)
	}
}

// MARK: - Streaming Implementation

extension DirectInferenceClient {
	private func doStreamInference(
		request: InferenceRequest,
		enginePool: EnginePool,
		scheduler: SchedulerActor,
		messageBuilder: MessageBuilder,
		continuation: AsyncStream<DirectChatChunk>.Continuation,
	) async throws {
		// Phase 1: Build message context
		let context = MessageBuilderContext(
			modelId: request.modelId,
			rawMessages: request.messages,
			userSystemPrompt: request.systemPrompt,
			tools: request.tools,
			sessionId: request.sessionId ?? UUID().uuidString,
		)
		let fullMessages = try await messageBuilder.buildMessages(context: context)

		// Phase 2: Submit to scheduler + dispatch (streaming)
		let schedulingRequest = SchedulingRequest(
			id: "req-\(UUID().uuidString.prefix(8))",
			priority: .chat,
			modelId: request.modelId,
			prompt: request.messages.first?.textContent() ?? "",
			tokenBudget: request.maxTokens ?? 4096,
		)
		do {
			let dispatched = try await scheduler.submitAndDispatch(schedulingRequest)
			guard dispatched != nil else {
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

		// Phase 3: Acquire engine handle
		let handle: EngineHandle
		do {
			handle = try await enginePool.acquire(model: request.modelId)
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

		// Phase 4: Build sampling config
		let runtimeDefaults = await enginePool.getSamplingConfig(modelId: request.modelId)
		let effectiveTemp = request.temperature ?? Double(runtimeDefaults.temperature)
		let effectiveTopP = request.topP ?? Double(runtimeDefaults.topP ?? 1.0)
		let effectiveTopK = request.topK ?? runtimeDefaults.topK
		let effectiveMaxTokens = request.maxTokens ?? runtimeDefaults.maxTokens

		let sampling = SamplingConfiguration(
			temperature: effectiveTemp,
			topP: effectiveTopP,
			topK: effectiveTopK,
			stopSequences: request.stopSequences,
			logitBias: request.logitBias,
			combined: true,
		).normalized()

		let inferenceOpts = InferenceOptions(
			maxTokens: effectiveMaxTokens,
			includeLogits: false,
		)

		// Phase 5: Dispatch inference
		await handle.markActive()

		// Pass cancellation token to propagate UI cancel signal to the inference layer
		let cancellation = request.cancellation ?? .none

		let tokenStream = handle.generateFromMessages(
			messages: fullMessages,
			sampling: sampling,
			options: inferenceOpts,
			conversationId: request.sessionId,
			cancellation: cancellation,
		)

		var outputTokens = 0
		var accumulatedText = ""
		var finishReason: String? = nil

		// Streaming output safety guard
		let streamGuard = OcoreaiEngine.shared.activeContentGuard

		do {
			for try await event in tokenStream {
				switch event.kind {
				case .token:
					outputTokens += 1
				case let .text(text):
					outputTokens += 1
					// Safety check: filter harmful output
					if let contentGuard = streamGuard {
						let checkResult = await contentGuard.checkOutput(text)
						if !checkResult.passed {
							continuation.yield(.init(text: "[Safety Filter: \(checkResult.rejectionReason ?? "Content safety violation")]", isComplete: true))
							continuation.finish()
							return
						}
					}
					accumulatedText += text
					continuation.yield(.init(text: text, isComplete: false))
				case let .done(reason):
					finishReason = stopReasonToString(reason) ?? "stop"
				case let .error(errorMsg):
					continuation.finish()
					throw AppError.generationError(errorMsg)
				}
			}
		}

		// Send final chunk
		continuation.yield(.init(
			text: "",
			isComplete: true,
			stopReason: finishReason ?? "stop",
			outputTokens: outputTokens,
		))
		continuation.finish()
	}
}

// MARK: - Non-Streaming Implementation (with Agent Loop)

extension DirectInferenceClient {
	private func doCompleteInference(
		request: InferenceRequest,
		enginePool: EnginePool,
		scheduler: SchedulerActor,
		messageBuilder: MessageBuilder,
	) async throws -> DirectInferenceResult {
		// Phase 1: Build message context
		let context = MessageBuilderContext(
			modelId: request.modelId,
			rawMessages: request.messages,
			userSystemPrompt: request.systemPrompt,
			tools: request.tools,
			sessionId: request.sessionId ?? UUID().uuidString,
		)
		let fullMessages = try await messageBuilder.buildMessages(context: context)

		// Phase 2: Submit to scheduler + dispatch (non-streaming)
		let schedulingRequest = SchedulingRequest(
			id: "req-\(UUID().uuidString.prefix(8))",
			priority: .chat,
			modelId: request.modelId,
			prompt: request.messages.first?.textContent() ?? "",
			tokenBudget: request.maxTokens ?? 4096,
		)
		do {
			let dispatched = try await scheduler.submitAndDispatch(schedulingRequest)
			guard dispatched != nil else {
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

		// Phase 3: Acquire engine
		let handle: EngineHandle
		do {
			handle = try await enginePool.acquire(model: request.modelId)
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

		// Phase 4: Sampling config
		let runtimeDefaults = await enginePool.getSamplingConfig(modelId: request.modelId)
		let effectiveTemp = request.temperature ?? Double(runtimeDefaults.temperature)
		let effectiveTopP = request.topP ?? Double(runtimeDefaults.topP ?? 1.0)
		let effectiveTopK = request.topK ?? runtimeDefaults.topK
		let effectiveMaxTokens = request.maxTokens ?? runtimeDefaults.maxTokens

		let samplingConfig = SamplingConfiguration(
			temperature: effectiveTemp,
			topP: effectiveTopP,
			topK: effectiveTopK,
			stopSequences: request.stopSequences,
			logitBias: request.logitBias,
			combined: true,
		).normalized()

		let infOpts = InferenceOptions(
			maxTokens: effectiveMaxTokens,
			includeLogits: false,
		)

		// Phase 5: Dispatch inference — Agent loop if tools available
		await handle.markActive()

		let tokenBudget = effectiveMaxTokens ?? 4096
		var completeText = ""
		var outputTok = 0

		// Collect tool call parts from agent loop iterations
		var collectedToolCallParts: [ToolCallPart]? = nil
		
		// If tools are defined, try agent loop
		if let tools = request.tools, !tools.isEmpty {
			if let registry = OcoreaiEngine.shared.activeToolRegistry {
				let loopConfig = AgentLoopConfig(
					maxIter: 30,
					tokenBudget: tokenBudget,
					guardMargin: 512,
					timeoutSeconds: 120,
					registry: registry,
					builder: messageBuilder,
					caller: "ui-direct"
				)
				let agentResult = try await AgentLoop.run(
					config: loopConfig,
					handle: handle,
					initialMessages: fullMessages,
					modelId: request.modelId,
					sampling: samplingConfig,
					options: infOpts
				)
				completeText = agentResult.text
				outputTok = agentResult.totalTokens
				
				// Extract tool calls from agent loop iterations
				if !agentResult.iters.isEmpty {
					var parts: [ToolCallPart] = []
					for iter in agentResult.iters {
						if iter.toolN > 0 {
							parts.append(ToolCallPart(
								callId: "iter-\(iter.iteration)",
								name: iter.tag,
								resultSummary: "\(iter.toolN) tool(s), \(iter.tok) tokens, \(Int(iter.ms))ms",
								durationMs: iter.ms
							))
						}
					}
					if !parts.isEmpty {
						collectedToolCallParts = parts
					}
				}
			}
		}

		// If agent loop was not triggered (no tools or no registry), do single inference
		if completeText.isEmpty && outputTok == 0 {
			let tokenStream = handle.generateFromMessages(
				messages: fullMessages,
				sampling: samplingConfig,
				options: infOpts
			)
			for try await event in tokenStream {
				switch event.kind {
				case .token:
					outputTok += 1
				case let .text(text):
					outputTok += 1
					completeText += text
				case .done:
					break
				case let .error(msg):
					throw AppError.generationError(msg)
				}
			}
		}

		return DirectInferenceResult(
			content: completeText,
			stopReason: "stop",
			outputTokens: outputTok,
			toolCallParts: collectedToolCallParts
		)
	}
}

// MARK: - Chunk Types

/// Intermediate chunk emitted by the streaming inference loop.
///
/// The `text` field carries streaming text deltas for real-time display.
/// The optional `metadata` field carries structured event data (tool calls,
/// reasoning start/end) from the agent loop. When metadata is present,
/// ChatViewModel accumulates structured parts alongside the flat text.
struct DirectChatChunk {
	let text: String
	let isComplete: Bool
	let stopReason: String?
	let outputTokens: Int?
	/// Structured metadata for agent loop events (optional).
	/// When present, the client should accumulate these into a structured ChatMessage.
	let metadata: DirectChunkMetadata?

	/// Metadata for structured inference events beyond plain text deltas.
	enum DirectChunkMetadata: Codable {
		case toolCall(ToolCallMeta)
		case reasoningStart
		case reasoningEnd
	}

	/// Compact tool call metadata emitted during agent loop iterations.
	struct ToolCallMeta: Codable {
		let name: String
		let arguments: String?
		let resultSummary: String?
		let durationMs: Double?
	}

	init(
		text: String,
		isComplete: Bool,
		stopReason: String? = nil,
		outputTokens: Int? = nil,
		metadata: DirectChunkMetadata? = nil
	) {
		self.text = text
		self.isComplete = isComplete
		self.stopReason = stopReason
		self.outputTokens = outputTokens
		self.metadata = metadata
	}
}

struct DirectInferenceResult {
	let content: String
	let stopReason: String
	let outputTokens: Int
	/// Aggregated tool call parts from agent loop iterations.
	/// Populated when AgentLoop ran multiple iterations with tool execution.
	let toolCallParts: [ToolCallPart]?
	
	init(
		content: String,
		stopReason: String,
		outputTokens: Int,
		toolCallParts: [ToolCallPart]? = nil
	) {
		self.content = content
		self.stopReason = stopReason
		self.outputTokens = outputTokens
		self.toolCallParts = toolCallParts
	}
}

// MARK: - Errors

enum DirectInferenceError: Error, LocalizedError {
	case engineNotReady
	case schedulerNotReady
	case messageBuilderNotReady
	case contentBlocked(String)

	var errorDescription: String? {
		switch self {
		case .engineNotReady: "Inference engine not yet ready"
		case .schedulerNotReady: "Scheduler not yet ready"
		case .messageBuilderNotReady: "Message builder not ready"
		case let .contentBlocked(reason): "Content blocked: \(reason)"
		}
	}
}
