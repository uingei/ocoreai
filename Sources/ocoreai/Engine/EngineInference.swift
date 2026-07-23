// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineInference.swift — Inference execution as EnginePool extension
///
/// Contains ``doInference`` and ``_runInference`` — the heavy inference
/// runners that execute off-actor in background Tasks. Split from
/// EnginePool.swift so the actor's core orchestration stays lean.

import Foundation
import Logging

#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
	import CoreAI
#endif

import MLX
import MLXLLM
import MLXLMCommon
import MLXGuidedGeneration
import MLXVLM
import CoreImage
import CoreGraphics

// MARK: - Inference Extension

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
			continuation.yield(.init(kind: .error(
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

		#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
			if #available(macOS 27.0, *) {
				// CoreAI lacks grammar constraints and tool dispatch — fall back to MLX
				if options.grammarSchema != nil || options.useGuidedGeneration {
					logger.info("Falling back to MLX for grammar/tool-constrained request on model \(modelId)")
					let promptText = await (try? detokenize(modelId: modelId, tokens: input))
						?? "<detokenization failed>"

					// Check for model-specific reasoning control tokens that will be lost in detokenize→retokenize roundtrip
					let reasoningControlTokens = Set([151645, 151646])
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
						skipLock: true
					)
					return
				}
				// Warn about sampling fields CoreAI SDK cannot honor
				// (CoreAI.SamplingConfiguration only supports temperature/topK/topP/minP/combined)
				let coreaiUnhonoredFields: [String] = [
					sampling.seed != nil ? "seed" : "",
					sampling.repetitionPenalty != nil ? "repetitionPenalty" : "",
					sampling.presencePenalty != nil ? "presencePenalty" : "",
					sampling.frequencyPenalty != nil ? "frequencyPenalty" : "",
					(sampling.stopSequences ?? []).isEmpty ? "" : "stopSequences",
					(sampling.logitBias ?? [:]).isEmpty ? "" : "logitBias",
				].filter { !$0.isEmpty }
				if !coreaiUnhonoredFields.isEmpty {
					logger.warning(
						"[\(type(of: self))] CoreAI path: sampling fields not honored by SDK: \(coreaiUnhonoredFields.joined(separator: ", "))"
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
							continuation.yield(.init(kind: .token(
								(output as? InferenceOutput)?.tokenId ?? 0
							)))
						}
					} catch {
						continuation.yield(.init(kind: .error(error.localizedDescription)))
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
						continuation.yield(.init(kind: .done(StopReason.cancelled, tokenCount: metrics.generatedTokenCount)))
					} else if !Task.isCancelled {
						// Read actual stop reason from sequence; default to maxTokens if unset
						// (e.g., empty prefix-hit path or early termination edge case)
						let stopReason: StopReason = sequence.stopReason?.stopReason ?? .maxTokens
						continuation.yield(.init(kind: .done(stopReason, tokenCount: metrics.generatedTokenCount)))
					}

					// CoreAI 34f0db3: no per-turn reset. KV cache persists across turns;
					// TokenHistory.resolve manages prefix reuse and divergence rewind.
					// Explicit reset only on model switch or hard error.

				} catch {
					continuation.yield(.init(kind: .error(error.localizedDescription)))
				}
			} else {
				// CoreAI unavailable on this macOS version
				continuation.yield(.init(kind: .error("CoreAI requires macOS 27.0")))
			}
		#else
			// [KNOWN LIMITATION] MLXLLM ChatSession only accepts [Chat.Message], not raw tokens.
			// Detokenize → Message → re-tokenize path drops special control tokens
			// (e.g. <|begin_of_thought|>, <|eot_id|>). Track upstream for promptTokens API:
			// https://github.com/ml-explore/mlx-swift-examples/issues
			// Mitigation: log warning when input may contain non-text tokens.
			let promptText = await (try? detokenize(modelId: modelId, tokens: input))
				?? "<detokenization failed>"

			// Check for model-specific reasoning control tokens that will be lost in detokenize→retokenize roundtrip
			// P0-fix: removed universal ASCII control chars (newline=198, ESC=27) — they fire on every request
			// and flood the log. Only flag reasoning-specific tokens (<|begin_of_thought|>, <|eot_id|>).
			let reasoningControlTokens = Set([151645, 151646]) // <|begin_of_thought|>, <|eot_id|>
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
				skipLock: true, // caller (_runInference) already holds inference guard
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
				guard let ciImage = CIImage(data: data) else { return nil }
				return .ciImage(ciImage)
			}

			return nil
		}

		// Fallback: regular URL (http, file, etc.)
		if let url = URL(string: urlString) {
			return .url(url)
		}

		return nil
	}

		// MARK: - MLX ToolCall Conversion

	/// Convert ocoreai ``ToolCall`` to upstream MLXLMCommon ``ToolCall``.
	/// Top-level free function so it doesn't capture EnginePool self — avoids
	/// Sendable taint in the inference body closure for WiredMemoryTicket.
	nonisolated func mLXToolCall(from tc: ToolCall) -> MLXLMCommon.ToolCall {
		func parseArgs(_ args: String) -> [String: any Sendable] {
			let data = args.data(using: .utf8) ?? Data()
			guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
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
				let gpuGB = String(format: "%.1f", Double(await tracker.gpuActiveMemoryBytes()) / 1_073_741_824.0)
				let budgetGB = String(format: "%.1f", Double(await tracker.getBudget()) / 1_073_741_824.0)
			
				switch computeChannel {
				case .gpu:
					logger.debug("HardwareRouter → GPU for \(modelId) (gpu: \(gpuGB)/\(budgetGB) GB)")
				case .cpu:
					logger.warning("HardwareRouter → CPU for \(modelId) (gpu: \(gpuGB)/\(budgetGB) GB) — disabling session pool + speculative decoding")
				case .ane:
					#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
						logger.info("HardwareRouter → ANE for \(modelId) (gpu: \(gpuGB)/\(budgetGB) GB)")
					#else
						logger.warning("HardwareRouter → ANE for \(modelId) but CoreAI unavailable, falling back to GPU (gpu: \(gpuGB)/\(budgetGB) GB)")
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

			// ANE path: delegate to _runInference → CoreAI engine (which supports ANE hardware)
			// Skip MLX-specific setup (session pool, guided gen, spec decoding) which requires GPU.
			#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
				if computeChannel == .ane {
					logger.info("ANE channel: routing model \(modelId) through CoreAI engine")
					do {
						let tokens = try await tokenize(modelId: modelId, messages: messages)
						let count = tokens.count
						if count > loaded.modelConfig.maxContextLength {
							continuation.yield(.init(kind: .error(
								"Input \(count) exceeds max context \(loaded.modelConfig.maxContextLength)")))
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
						continuation.yield(.init(kind: .error(error.localizedDescription)))
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
				continuation.yield(.init(kind: .error(
					"Input \(tokenCount) exceeds max context \(loaded.modelConfig.maxContextLength)",
				)))
				continuation.finish()
				return
			}
			} catch {
			// Fallback: mlx containers have their own tokenizer, use heuristic estimate
			logger.warning("Tokenization failed, using heuristic estimate for metrics — \(error.localizedDescription)")
			tokenCount = messages.reduce(0) { $0 + contentToString($1.content).0.utf8.count / 4 }
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

			let mlxMessages: [Chat.Message] = messages.map { msg in
				let role: Chat.Message.Role = switch msg.role {
				case "system": .system
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
				case let .text(text):
					return Chat.Message(role: role, content: text)
				case let .parts(parts):
					var textParts: [String] = []
					var images: [MLXLMCommon.UserInput.Image] = []
					var audios: [MLXLMCommon.UserInput.Audio] = []
					for part in parts {
						if let text = part.text {
							textParts.append(text)
						}
						if let img = part.imageUrl, let image = makeMLXImage(from: img.url) {
							images.append(image)
							}
						if let audio = part.audioURL {
							// Audio URL directly into VLM — upstream handles decoding via .asMLXArray()
							if let url = URL(string: audio.url) {
								audios.append(.url(url))
							}
						}
					}
					return Chat.Message(
						role: role,
						content: textParts.joined(separator: " "),
						images: images,
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
					let messages = messagePairs.map { pair in
						Chat.Message(
							role: Chat.Message.Role(rawValue: pair.role) ?? .system,
							content: pair.content
						)
					}
					let userInput = UserInput(prompt: .chat(messages))
					let lmInput = try await context.processor.prepare(input: userInput)

					// Build GrammarTokenizer from the model's tokenizer — canonical path
					// mirrors MLXFoundationModels.MLXLanguageModel.makeGrammarTokenizer.
					let grammarVocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
					let grammarTokenizer: GrammarTokenizer
					do {
						grammarTokenizer = try GrammarTokenizer(
							vocab: grammarVocab.vocab,
							vocabType: grammarVocab.vocabType,
							eosTokenId: Int32(context.tokenizer.eosTokenId ?? 0),
						)
					} catch {
						continuation.yield(.init(kind: .error(
							"GrammarTokenizer build failed: \(error.localizedDescription)")))
						continuation.finish()
						return
					}

					// Build GrammarConstraint from JSON schema string via native compile path
					let constraint: GrammarConstraint
					do {
						constraint = try GrammarConstraint(
							tokenizer: grammarTokenizer,
							jsonSchema: grammarSchema,
						)
					} catch {
						continuation.yield(.init(kind: .error(
							"GrammarConstraint build failed: \(error.localizedDescription)")))
						continuation.finish()
						return
					}

					// Token count tracking for guided path
					var guidedTokenCount = 0
					var firstYielded = false

					// Run GuidedGenerationLoop with emit callback → SSE yield
					let tokenCount = try GuidedGenerationLoop.run(
						input: lmInput,
						context: context,
						constraint: constraint,
						maxTokens: maxTokens,
						vocabSize: Int(loaded.modelConfig.vocabSize),
					) { text in
						guard !Task.isCancelled && !cancellation.isCancelled else {
							continuation.yield(.init(
								kind: .done(StopReason.cancelled,
									tokenCount: guidedTokenCount)))
							continuation.finish()
							return false
						}
						// Record TTFT on first text chunk
						if !firstYielded {
							metrics.firstTokenMs = metrics.overallMs
							firstYielded = true
						}
						metrics.incrementGenerated()
						guidedTokenCount += 1
						continuation.yield(.init(kind: .text(text)))
						return true
					}

					// Complete guided generation
					if !Task.isCancelled && !cancellation.isCancelled {
						continuation.yield(.init(
							kind: .done(.eos, tokenCount: tokenCount)))
					}
					continuation.finish()
				}
			}

			// runInferenceBody: session acquisition → generation → pool release
			/// When useGuidedGeneration is true, routes through GuidedGenerationLoop
			/// for grammar-constrained output (tool calls, JSON schema).
			/// Otherwise uses upstream ChatSession.streamDetails for standard generation.
			///
			/// Bridge: when tools are registered, we pass them to ChatSession along with
			/// a toolDispatch closure that routes ToolCall → ToolRegistry.call() and back.
			/// This activates the ChatSession's built-in tool-dispatch agent loop (L774-817)
			/// instead of relying solely on the local AgentLoop coordinator.
			func runInferenceBody() async throws {
				let convKey: String = conversationId ?? "\(modelId):ephemeral"
				var isPoolHit = false
				var deltaOffset = 0
				var chatSession: ChatSession?
				var registeredToolSpecs: [ToolSpec]?

				// Bridge ToolRegistry → ChatSession tools + toolDispatch
				if let registry = toolRegistry {
					let specs = await registry.toToolSpecs()
					if !specs.isEmpty {
						registeredToolSpecs = specs
					}
				}

				// ChatSession path: acquire or create session
				if options.useGuidedGeneration == false {
					// Hoist registry ref before closure — ToolRegistry is an actor, capture is safe
					if let pool = poolRef {
						let acquired = await pool.acquire(
							from: handleRef.modelContainer,
							modelId: modelId,
							conversationId: convKey,
							genParams: genParams,
							speculativeDecoding: specConfig,
						)
						chatSession = acquired.pooled.session
						isPoolHit = acquired.isHit
						deltaOffset = acquired.pooled.messageCount
						if isPoolHit {
							log.debug("Pool HIT for \(convKey) — KV cache reused (offset=\(deltaOffset))")
						}
						// Inject tools + toolDispatch into pooled session
						if let specs = registeredToolSpecs {
							chatSession?.tools = specs
							if let registry = toolRegistry {
								chatSession?.toolDispatch = { toolCall in
									let argsData = toolCall.function.arguments.mapValues { $0.anyValue }
									let jsonEncoded = try JSONSerialization.data(
										withJSONObject: argsData
									)
									let argsString = String(decoding: jsonEncoded, as: UTF8.self)
									return try await registry.call(toolCall.function.name, arguments: argsString)
								}
							}
						}
						} else {
						let spec: MLXLMCommon.SpeculativeDecodingConfig? = specConfig
						let gp: MLXLMCommon.GenerateParameters = genParams
						let toolSpecs: [ToolSpec]? = registeredToolSpecs
						var toolDispatchClosure: (@Sendable (MLXLMCommon.ToolCall) async throws -> String)? = nil
						if toolSpecs != nil, let registry = toolRegistry {
							toolDispatchClosure = { toolCall in
								let argsDict = toolCall.function.arguments.mapValues { $0.anyValue }
								let jsonEncoded = try JSONSerialization.data(
									withJSONObject: argsDict
								)
								let argsString = String(decoding: jsonEncoded, as: UTF8.self)
								return try await registry.call(toolCall.function.name, arguments: argsString)
							}
						}
						chatSession = ChatSession(
							handleRef.modelContainer,
							speculativeDecoding: spec,
							generateParameters: gp,
							tools: toolSpecs,
							toolDispatch: toolDispatchClosure
						)
					}
				}

				do {
					let messagesToSend: [Chat.Message]
					if isPoolHit, deltaOffset < mlxMessages.count {
						messagesToSend = Array(mlxMessages[deltaOffset...])
					} else if isPoolHit, deltaOffset >= mlxMessages.count {
						log.warning("Pool session messageCount (\(deltaOffset)) >= current messages (\(mlxMessages.count)), sending all")
						messagesToSend = mlxMessages
					} else {
						messagesToSend = mlxMessages
					}

					var inferenceError: Error?
					var accumulatedText = ""
					var actualTokenCount: Int?
					var lastStopReason: StopReason?
					var stoppedBySequence = false
					var firstTokenRecorded = false

					// MARK: - Guided Generation Path (grammar-constrained)
					if let schema = options.grammarSchema {
						log.info("Routing through GuidedGenerationLoop with grammar constraint")
						// Guided path: prepare input, build constraint, run token loop
						// All within modelContainer.perform for thread-safe ModelContext access
						try await handleGuidedGeneration(
							messagePairs: mlxMessages.map { (role: $0.role.rawValue, content: $0.content) },
							grammarSchema: schema,
							maxTokens: options.maxTokens ?? loaded.modelConfig.maxContextLength,
						)
					}
					// MARK: - Standard ChatSession Path
					else if let session = chatSession {
						let genStream: AsyncThrowingStream<MLXLMCommon.Generation, Error> =
							session.streamDetails(to: messagesToSend)

						do {
							for try await generation in genStream {
								if Task.isCancelled || cancellation.isCancelled {
									continuation.yield(.init(kind: .done(StopReason.cancelled, tokenCount: actualTokenCount ?? metrics.generatedTokenCount)))
									break
								}
								switch generation {
								case let .chunk(text):
									// firstTokenMs: record on first actual text chunk — isolates prefill/init time
									if !firstTokenRecorded {
										metrics.firstTokenMs = metrics.overallMs
										firstTokenRecorded = true
									}
									metrics.incrementGenerated()
									accumulatedText += text
									// Check if accumulated text matches any stop sequence
									if requestStopSequences.isEmpty {
										continuation.yield(.init(kind: .text(text)))
									} else if let match = requestStopSequences.first(where: { accumulatedText.hasSuffix($0) }) {
										// Trim the stop sequence from output and early-exit
										let trimmed = String(accumulatedText.prefix(accumulatedText.count - match.count))
										if !trimmed.isEmpty {
											continuation.yield(.init(kind: .text(trimmed)))
										}
										continuation.yield(.init(kind: .done(StopReason.stopSequence, tokenCount: actualTokenCount ?? metrics.generatedTokenCount)))
										stoppedBySequence = true
										break
									} else {
										continuation.yield(.init(kind: .text(text)))
									}
								case let .info(completionInfo):
									// Capture actual generation token count and stop reason from upstream
									actualTokenCount = completionInfo.generationTokenCount
									// Map upstream GenerateStopReason → our StopReason:
									//   .stop → .eos (model hit EOS)
									//   .length → .maxTokens (hit max token limit)
									//   .cancelled → .cancelled (task cancelled)
									lastStopReason = switch completionInfo.stopReason {
									case .stop: .eos
									case .length: .maxTokens
									case .cancelled: .cancelled
									}
								case .toolCall:
									// Tool calls are handled by AgentLoop.parseToolCalls() on accumulated text at stream end
									break
								}
							}
						} catch {
							inferenceError = error
						}

						if let inferenceError {
							continuation.yield(.init(kind: .error(inferenceError.localizedDescription)))
						} else if !Task.isCancelled && !stoppedBySequence {
							// Use upstream stop reason if available, fallback to .maxTokens
							let stopReason: StopReason = lastStopReason ?? .maxTokens
							continuation.yield(.init(kind: .done(stopReason, tokenCount: actualTokenCount ?? metrics.generatedTokenCount)))
						}
					}
					}

				if let pool = poolRef, let session = chatSession {
					// Only release pooled session when ChatSession path was used
					// (Guided path creates its own context, no pool management needed)
					await pool.release(
						pooled: PooledChatSession(
							session: session,
							lastAccessedAt: ContinuousClock.now,
							messageCount: mlxMessages.count,
						),
						modelId: modelId,
						conversationId: convKey,
						processedMessageCount: mlxMessages.count,
					)
				}
			}

			// Layer 0: Wired memory GPU hard-isolation + GPU telemetry
			// Scopes wired limit to this inference request. Auto-released on completion/error.
			// Policy: WiredMaxPolicy when config.wiredMemory.policy == "max", else WiredSumPolicy.
			let logRef = self.logger
			if config.wiredMemory.enabled {
				// Estimate ticket size: weights + activations + KV reserve.
				// vocab_size * 8 bytes (FP16→INT4 weights) + max_context * 64 (KV cache per token)
				// bytesOverride from config takes priority when set.
				let ticketSize: Int
				if config.wiredMemory.bytesOverride > 0 {
					ticketSize = Int(config.wiredMemory.bytesOverride)
				} else {
					ticketSize = Int(loaded.modelConfig.vocabSize) * 8
						+ Int(loaded.modelConfig.maxContextLength) * 64
				}

				// FIXED: Hashable policies derive stable identity from their value (cap), not UUID.
				// Custom ID broke WiredMemoryManager's grouping/hysteresis logic.
				let wmPolicy: any WiredMemoryPolicy = if config.wiredMemory.policy == "sum" {
					WiredSumPolicy(cap: nil)
				} else {
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
				logRef.debug("GPU pre-inference [\(modelId)] active: \(preSnapshot.activeMemory / 1_048_576)MB, cache: \(preSnapshot.cacheMemory / 1_048_576)MB, peak: \(preSnapshot.peakMemory / 1_048_576)MB")
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
				logRef.debug("GPU post-inference delta [\(modelId)] active: \(gpuDelta.activeMemory / 1_048_576)MB, cache: \(gpuDelta.cacheMemory / 1_048_576)MB")

				// Propagate error if caught
				if let caughtError {
					continuation.yield(.init(kind: .error(caughtError.localizedDescription)))
				}

				metrics.inferenceMs = metrics.overallMs
				continuation.finish()
				return
			}

			// Execute inference body without wired memory scoping
			do {
				try await runInferenceBody()
			} catch {
				continuation.yield(.init(kind: .error(error.localizedDescription)))
			}

			metrics.inferenceMs = metrics.overallMs
				continuation.finish()
				}
			}
