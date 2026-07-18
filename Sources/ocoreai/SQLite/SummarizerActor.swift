// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SummarizerActor.swift — LLM-powered summarization delegate
///
/// Sits between SessionCompressor and EnginePool:
///   SessionCompressor (actor) → SummarizerActor (actor) → EnginePool (actor)
///
/// Breaks the circular dependency: MessageBuilder depends on SessionCompressor,
/// SessionCompressor depends on SummarizerActor, SummarizerActor depends on EnginePool + MessageBuilder.

import Foundation
import Logging

/// Configuration for the summarizer.
struct SummarizerConfig: Sendable {
	/// Model ID used for summarization (e.g. a small fast model).
	/// Falls back to the first loaded model in EnginePool.
	var modelId: String?

	/// Maximum output tokens for the summary.
	var maxTokens: Int = 256
}

extension SummarizerConfig {
	static let `default` = SummarizerConfig()
}

/// Actor that performs LLM-driven text summarization.
actor SummarizerActor {
	private let logger: Logger
	private let enginePool: EnginePool
	private let messageBuilder: MessageBuilder
	private let config: SummarizerConfig

	init(
		enginePool: EnginePool,
		messageBuilder: MessageBuilder,
		config: SummarizerConfig,
		log: Logger? = nil,
	) {
		self.logger = log ?? Logger(label: "ocoreai.summarizer")
		self.enginePool = enginePool
		self.messageBuilder = messageBuilder
		self.config = config
	}

	/// Summarize raw text using the inference engine.
	func summarize(_ text: String) async throws -> String {
		// Resolve model ID
		let resolvedId: String? = if let id = config.modelId, await enginePool.isModelLoaded(id) {
			id
		} else {
			await enginePool.firstLoadedModelId()
		}

		guard let modelId = resolvedId else {
			logger.warning("No model for summarization, truncating input")
			return String(text.prefix(500))
		}

		// Build summary prompt
		let context = MessageBuilderContext(
			modelId: modelId,
			rawMessages: [Message(role: "user", content:
				"Summarize the following conversation in 3-5 concise bullet points. Focus on key topics, decisions, and outcomes:\n\n\(text)"
			)],
			userSystemPrompt: nil,
			tools: nil,
			sessionId: "summarizer"
		)
		let fullMessages = try await messageBuilder.buildMessages(context: context)

		// Acquire handle
		let handle = try await enginePool.acquire(model: modelId)

		// Use a nested function — release is handled inside generateSummary explicitly
		return try await self.generateSummary(
			handle: handle,
			modelId: modelId,
			messages: fullMessages
		)
	}

	// MARK: - Private

	private func generateSummary(
		handle: EngineHandle,
		modelId: String,
		messages: [Message]
	) async throws -> String {
		let _ = await handle.markActive()

		let runtimeDefaults = await enginePool.getSamplingConfig(modelId: modelId)
		let sampling = SamplingConfiguration(
			temperature: 0.3,
			topP: 0.9,
			topK: runtimeDefaults.topK,
			stopSequences: nil,
			logitBias: nil,
			combined: true,
		).normalized()

		let options = InferenceOptions(
			maxTokens: config.maxTokens,
			includeLogits: false,
		)

		let stream = handle.generateFromMessages(
			messages: messages,
			sampling: sampling,
			options: options,
			conversationId: "summarizer",
			cancellation: .none,
		)

		var summary = ""
		do {
			for try await event in stream {
				switch event.kind {
				case .token:
					break
				case let .text(t):
					summary += t
				case .done(_, _): break
				case let .error(msg):
					// Release before re-throwing
					await handle.release()
					throw NSError(domain: "SummarizerActor", code: 1,
					              userInfo: [NSLocalizedDescriptionKey: msg])
				}
			}
		}

		// Release handle after successful inference
		await handle.release()

		if summary.isEmpty {
			logger.warning("Summarizer returned empty")
			throw NSError(domain: "SummarizerActor", code: 2,
			              userInfo: [NSLocalizedDescriptionKey: "Empty summary"])
		}

		logger.info("Summary generated (\(summary.count) chars)")
		return summary
	}

	/// Return a Sendable closure for SessionCompressor injection.
	func makeCallback() -> @Sendable (String) async throws -> String {
		let ref = self
		return { text in
			try await ref.summarize(text)
		}
	}
}
