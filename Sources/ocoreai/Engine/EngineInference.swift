// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineInference.swift — Inference execution as EnginePool extension
///
/// Contains ``doInference`` and ``_runInference`` — the heavy inference
/// runners that execute off-actor in background Tasks. Split from
/// EnginePool.swift so the actor's core orchestration stays lean.

import Foundation
import Logging

#if coreai
	import CoreAI
	import CoreAILanguageModels
	import CoreAIShared
#endif

#if mlx
	import MLX
	import MLXLLM
	import MLXLMCommon
#endif

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
				registerTrackedTask(tracker)
				await withTaskGroup(of: Void.self) { group in
					group.addTask {
						await tracker.value
					}
					group.addTask {
						do { try await Task.sleep(for: .milliseconds(500)) } catch {}
						while cancellation.isCancelled == false, ContinuousClock.now < deadline {
							do { try Task.checkCancellation() } catch {
								cancellation.cancel()
								break
							}
							do { try await Task.sleep(for: .milliseconds(500)) } catch {
								cancellation.cancel()
								break
							}
						}
						if ContinuousClock.now >= deadline {
							cancellation.cancel()
						}
					}
				}
				removeTrackedTask(tracker)
			}
		}
	}

	/// MLX-specific inference entry — accepts messages directly.
	#if mlx
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
					registerTrackedTask(tracker)
					await withTaskGroup(of: Void.self) { group in
						group.addTask {
							await tracker.value
						}
						group.addTask {
							do { try await Task.sleep(for: .milliseconds(500)) } catch {}
							while cancellation.isCancelled == false, ContinuousClock.now < deadline {
								do { try Task.checkCancellation() } catch {
									cancellation.cancel()
									break
								}
								do { try await Task.sleep(for: .milliseconds(500)) } catch {
									cancellation.cancel()
									break
								}
							}
							if ContinuousClock.now >= deadline {
								cancellation.cancel()
							}
						}
					}
					removeTrackedTask(tracker)
				}
			}
		}
	#endif

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

		#if coreai
			do {
				// Use cached engine — CoreAI 34f0db3: single engine per model preserves
				// KV cache across turns. TokenHistory.resolve handles prefix caching automatically.
				let engine = try await loaded.getCachedEngine()
				let sequence = try engine.generate(
					with: input,
					samplingConfiguration: sampling,
					inferenceOptions: options,
				)

				do {
					for try await output in sequence {
						if Task.isCancelled || cancellation.isCancelled {
							continuation.yield(.init(kind: .done(StopReason.cancelled)))
							break
						}
						metrics.incrementGenerated()
						if metrics.generatedTokenCount == 1 {
							metrics.firstTokenMs = metrics.overallMs
						}
						continuation.yield(.init(kind: .token(output.tokenId)))
					}
				} catch {
					continuation.yield(.init(kind: .error(error.localizedDescription)))
					return
				}

				if !Task.isCancelled {
					continuation.yield(.init(kind: .done(sequence.stopReason)))
				}

				// CoreAI 34f0db3: no per-turn reset. KV cache persists across turns;
				// TokenHistory.resolve manages prefix reuse and divergence rewind.
				// Explicit reset only on model switch or hard error.

			} catch {
				continuation.yield(.init(kind: .error(error.localizedDescription)))
			}
		#endif

		#if mlx
			// [KNOWN LIMITATION] MLXLLM ChatSession only accepts [Chat.Message], not raw tokens.
			// Detokenize → Message → re-tokenize path drops special control tokens
			// (e.g. <|begin_of_thought|>, <|eot_id|>). Track upstream for promptTokens API:
			// https://github.com/ml-explore/mlx-swift-examples/issues
			// Mitigation: log warning when input may contain non-text tokens.
			let promptText = await (try? detokenize(modelId: modelId, tokens: input))
				?? "<detokenization failed>"
		
			// Check for known control tokens that will be lost in detokenize→retokenize roundtrip
			let knownControlTokens = Set([151645, 151646, 198, 27]) // <|begin_of_thought|>, <|eot_id|>, newline, ESC
			if input.contains(where: { knownControlTokens.contains(Int($0)) }) {
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

		#if !coreai && !mlx
			continuation.yield(.init(kind: .error("Inference unavailable — neither coreai nor mlx trait enabled")))
		#endif

		metrics.inferenceMs = metrics.overallMs
		continuation.finish()
	}

	#if mlx
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
			guard let loaded = loadedModels[modelId] else {
				continuation.yield(.init(kind: .error("Model not loaded: \(modelId)")))
				continuation.finish()
				return
			}

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
				switch msg.content {
				case let .text(text):
					let role: Chat.Message.Role = switch msg.role {
					case "system": .system
					case "assistant": .assistant
					default: .user
					}
					return Chat.Message(role: role, content: text)
				case let .parts(parts):
					let role: Chat.Message.Role = switch msg.role {
					case "system": .system
					case "assistant": .assistant
					case "tool": .tool
					default: .user
					}
					return Chat.Message(role: role, content: parts.compactMap(\.text).joined(separator: " "))
				case nil:
					return Chat.Message(role: .user, content: "")
				}
			}

			let genParams = makeGenerateParameters(
				from: sampling,
				maxTokens: options.maxTokens,
				kvCacheQuant: config.kvCacheQuantization,
			)

			// Build speculative decoding config once before inference body
			let specConfig = loaded.createSpeculativeConfig()

			// Layer 0: Wired memory GPU hard-isolation (opt-in via config)
			// Wraps the entire inference from session creation through generation to pool release.
			// Prevents model weights/KV cache from being paged out during inference.
			let wiredConfig = config.wiredMemory
			var wireTicket: WiredMemoryTicket?
			if wiredConfig.enabled {
				let policy: any WiredMemoryPolicy = if wiredConfig.policy == "sum" {
					MLX.WiredSumPolicy()
				} else {
					MLX.WiredMaxPolicy()
				}
				wireTicket = WiredMemoryTicket(
					size: max(0, wiredConfig.bytesOverride),
					policy: policy
				)
			}

			// runInferenceBody: session acquisition → generation → pool release
			func runInferenceBody() async throws {
				var chatSession: ChatSession
				let convKey: String = conversationId ?? "\(modelId):ephemeral"
				var isPoolHit = false
				var deltaOffset = 0
				if let pool = sessionPool {
					let acquired = await pool.acquire(
						from: mlxHandle.modelContainer,
						modelId: modelId,
						conversationId: convKey,
						genParams: genParams,
						speculativeDecoding: specConfig,
					)
					chatSession = acquired.pooled.session
					isPoolHit = acquired.isHit
					deltaOffset = acquired.pooled.messageCount
					if isPoolHit {
						logger.debug("Pool HIT for \(convKey) — KV cache reused (offset=\(deltaOffset))")
					}
				} else {
					chatSession = ChatSession(
						mlxHandle.modelContainer,
						speculativeDecoding: specConfig,
						generateParameters: genParams,
					)
				}

				let poolRef = sessionPool

				do {
					let messagesToSend: [Chat.Message]
					if isPoolHit, deltaOffset < mlxMessages.count {
						messagesToSend = Array(mlxMessages[deltaOffset...])
					} else if isPoolHit, deltaOffset >= mlxMessages.count {
						logger.warning("Pool session messageCount (\(deltaOffset)) >= current messages (\(mlxMessages.count)), sending all")
						messagesToSend = mlxMessages
					} else {
						messagesToSend = mlxMessages
					}

					let genStream: AsyncThrowingStream<MLXLMCommon.Generation, Error> =
						chatSession.streamDetails(to: messagesToSend)

					var firstTokenRecorded = false
					var inferenceError: Error?
					do {
						for try await generation in genStream {
							if Task.isCancelled || cancellation.isCancelled {
								continuation.yield(.init(kind: .done(StopReason.cancelled)))
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
								continuation.yield(.init(kind: .text(text)))
							case .info, .toolCall: break
							}
						}
					} catch {
						inferenceError = error
					}

					if let inferenceError {
						continuation.yield(.init(kind: .error(inferenceError.localizedDescription)))
					} else if !Task.isCancelled {
						continuation.yield(.init(kind: .done(nil)))
					}
				}

				if let pool = poolRef {
					let newMessageCount = isPoolHit ? (deltaOffset + mlxMessages.count - deltaOffset) : mlxMessages.count
					await pool.release(
						pooled: PooledChatSession(
							session: chatSession,
							lastAccessedAt: ContinuousClock.now,
							messageCount: newMessageCount,
						),
						modelId: modelId,
						conversationId: convKey,
						processedMessageCount: newMessageCount,
					)
				}
			}

			// Execute — conditionally wrapped in WiredMemoryTicket for GPU hard-isolation (L0)
			do {
				if let ticket = wireTicket {
					try await WiredMemoryTicket.withWiredLimit(ticket) {
						try await runInferenceBody()
					}
				} else {
					try await runInferenceBody()
				}
			} catch {
				// Wired memory admission denied or inference body threw — report as error event
				continuation.yield(.init(kind: .error(error.localizedDescription)))
			}

			metrics.inferenceMs = metrics.overallMs
			continuation.finish()
			}
			#endif
			}
