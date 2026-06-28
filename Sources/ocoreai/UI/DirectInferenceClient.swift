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
	let topP: Double?
	let topK: Int?
	let maxTokens: Int?

	/// Cancellation token for mid-stream interrupt support.
	/// When nil (default), the request is non-cancellable.
	let cancellation: InferenceCancellation?

	init(
		modelId: String,
		messages: [Message],
		temperature: Double? = nil,
		maxTokens: Int? = nil,
		sessionId: String? = nil,
		cancellation: InferenceCancellation? = nil,
	) {
		self.modelId = modelId
		self.messages = messages
		systemPrompt = nil
		tools = nil
		self.sessionId = sessionId
		self.temperature = temperature
		topP = nil
		topK = nil
		self.maxTokens = maxTokens
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

		// Phase 2: Submit to scheduler (streaming)
		let schedulingRequest = SchedulingRequest(
			id: "req-\(UUID().uuidString.prefix(8))",
			priority: .chat,
			modelId: request.modelId,
			prompt: request.messages.first?.textContent() ?? "",
			tokenBudget: request.maxTokens ?? 4096,
		)
		try await scheduler.submit(schedulingRequest)

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
			stopSequences: nil,
			logitBias: nil,
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

// MARK: - Non-Streaming Implementation

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

		// Phase 2: Scheduler (non-streaming)
		let schedulingRequest = SchedulingRequest(
			id: "req-\(UUID().uuidString.prefix(8))",
			priority: .chat,
			modelId: request.modelId,
			prompt: request.messages.first?.textContent() ?? "",
			tokenBudget: request.maxTokens ?? 4096,
		)
		try await scheduler.submit(schedulingRequest)

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
		let effectiveTopP = Double(runtimeDefaults.topP ?? 1.0)
		let effectiveTopK = runtimeDefaults.topK
		let effectiveMaxTokens = request.maxTokens ?? runtimeDefaults.maxTokens

		let sampling = SamplingConfiguration(
			temperature: effectiveTemp,
			topP: effectiveTopP,
			topK: effectiveTopK,
			stopSequences: nil,
			logitBias: nil,
			combined: true,
		).normalized()

		let inferenceOpts = InferenceOptions(
			maxTokens: effectiveMaxTokens,
			includeLogits: false,
		)

		// Phase 5: Generate
		await handle.markActive()

		let tokenStream = handle.generateFromMessages(
			messages: fullMessages,
			sampling: sampling,
			options: inferenceOpts,
		)

		var outputTokens = 0
		var completeText = ""
		var finishReason: String? = nil

		do {
			for try await event in tokenStream {
				switch event.kind {
				case .token:
					outputTokens += 1
				case let .text(text):
					outputTokens += 1
					completeText += text
				case let .done(reason):
					finishReason = stopReasonToString(reason) ?? "stop"
				case let .error(errorMsg):
					throw AppError.generationError(errorMsg)
				}
			}
		}

		return DirectInferenceResult(
			content: completeText,
			stopReason: finishReason ?? "stop",
			outputTokens: outputTokens,
		)
	}
}

// MARK: - Chunk Types

struct DirectChatChunk {
	let text: String
	let isComplete: Bool
	let stopReason: String?
	let outputTokens: Int?

	init(
		text: String,
		isComplete: Bool,
		stopReason: String? = nil,
		outputTokens: Int? = nil,
	) {
		self.text = text
		self.isComplete = isComplete
		self.stopReason = stopReason
		self.outputTokens = outputTokens
	}
}

struct DirectInferenceResult {
	let content: String
	let stopReason: String
	let outputTokens: Int
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
		case .messageBuilderNotReady: "Message builder not yet ready"
		case let .contentBlocked(reason): "Content blocked: \(reason)"
		}
	}
}
