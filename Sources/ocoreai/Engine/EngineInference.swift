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
        cancellation: InferenceCancellation = .none
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
                        cancellation: cancellation
                    )
                    ()
                }
                self.registerTrackedTask(tracker)
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await tracker.value
                    }
                    group.addTask {
                        // SilenceReason.gcdCancel: Task.sleep cancellation is expected
                        	do { try await Task.sleep(for: .milliseconds(500)) } catch {}
                        	while cancellation.isCancelled == false, ContinuousClock.now < deadline {
                        		do { try Task.checkCancellation() } catch {
                        			cancellation.cancel()
                        			break
                        		}
                        		// SilenceReason.gcdCancel: Task.sleep cancellation is expected
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
                self.removeTrackedTask(tracker)
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
        cancellation: InferenceCancellation = .none
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
                        cancellation: cancellation
                    )
                    ()
                }
                self.registerTrackedTask(tracker)
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await tracker.value
                    }
                    group.addTask {
                        // SilenceReason.gcdCancel: Task.sleep cancellation is expected
                        	do { try await Task.sleep(for: .milliseconds(500)) } catch {}
                        	while cancellation.isCancelled == false, ContinuousClock.now < deadline {
                        		do { try Task.checkCancellation() } catch {
                        			cancellation.cancel()
                        			break
                        		}
                        		// SilenceReason.gcdCancel: Task.sleep cancellation is expected
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
                self.removeTrackedTask(tracker)
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
        cancellation: InferenceCancellation = .none
    ) async {
        guard let loaded = loadedModels[modelId] else {
            continuation.yield(.init(kind: .error("Model not loaded: \(modelId)")))
            continuation.finish()
            return
        }

        let tokenCount = input.count
        if tokenCount > loaded.modelConfig.maxContextLength {
            continuation.yield(.init(kind: .error(
                "Input \(tokenCount) exceeds max context \(loaded.modelConfig.maxContextLength)"
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
                inferenceOptions: options
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
        // Route to _runInferenceWithMessages which uses SessionPool for ChatSession
        // reuse + KV cache management. Convert raw tokens → message → back to tokens
        // via that path's proper tokenization + session pooling.
        let promptText = (try? await detokenize(modelId: modelId, tokens: input))
            ?? "<detokenization failed>"
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
            skipLock: true  // caller (_runInference) already holds inference guard
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
        skipLock: Bool = false
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
                    "Input \(tokenCount) exceeds max context \(loaded.modelConfig.maxContextLength)"
                )))
                continuation.finish()
                return
            }
        } catch {
            continuation.yield(.init(kind: .error("Tokenization failed: \(error.localizedDescription)")))
            continuation.finish()
            return
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
            case .text(let text):
                let role: Chat.Message.Role
                switch msg.role {
                case "system": role = .system
                case "assistant": role = .assistant
                default: role = .user
                }
                return Chat.Message(role: role, content: text)
            case .parts(let parts):
                let role: Chat.Message.Role
                switch msg.role {
                case "system": role = .system
                case "assistant": role = .assistant
                case "tool": role = .tool
                default: role = .user
                }
                return Chat.Message(role: role, content: parts.compactMap { $0.text }.joined(separator: " "))
            case nil:
                return Chat.Message(role: .user, content: "")
            }
        }

        let genParams = makeGenerateParameters(
            from: sampling,
            maxTokens: options.maxTokens,
            kvCacheQuant: config.kvCacheQuantization
        )

        var chatSession: ChatSession
        let convKey: String = conversationId ?? "\(modelId):ephemeral"
        var isPoolHit = false
        var deltaOffset = 0
        if let pool = self.sessionPool {
            let acquired = await pool.acquire(
                from: mlxHandle.modelContainer,
                modelId: modelId,
                conversationId: convKey,
                genParams: genParams
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
                generateParameters: genParams
            )
        }

        let poolRef = self.sessionPool

        do {
            let messagesToSend: [Chat.Message]
            if isPoolHit && deltaOffset < mlxMessages.count {
                messagesToSend = Array(mlxMessages[deltaOffset...])
            } else if isPoolHit && deltaOffset >= mlxMessages.count {
                logger.warning("Pool session messageCount (\(deltaOffset)) >= current messages (\(mlxMessages.count)), sending all")
                messagesToSend = mlxMessages
            } else {
                messagesToSend = mlxMessages
            }

            let genStream: AsyncThrowingStream<MLXLMCommon.Generation, Error> =
                chatSession.streamDetails(to: messagesToSend)

            metrics.firstTokenMs = metrics.overallMs

            var inferenceError: Error?
            do {
                for try await generation in genStream {
                    if Task.isCancelled || cancellation.isCancelled {
                        continuation.yield(.init(kind: .done(StopReason.cancelled)))
                        break
                    }
                    switch generation {
                    case .chunk(let text):
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

        metrics.inferenceMs = metrics.overallMs

        if let pool = poolRef {
            let newMessageCount = isPoolHit ? (deltaOffset + mlxMessages.count - deltaOffset) : mlxMessages.count
            await pool.release(
                pooled: PooledChatSession(
                    session: chatSession,
                    lastAccessedAt: ContinuousClock.now,
                    messageCount: newMessageCount
                ),
                modelId: modelId,
                conversationId: convKey,
                processedMessageCount: newMessageCount
            )
        }

        continuation.finish()
    }
    #endif
}
