// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineHandle.swift — Non-blocking facade returned by EnginePool/acquire
///
/// Extracted from EngineManager.swift. Every handler creates one per
/// request and ``defer``-releases it. All operations delegate to the
/// pool actor via mailbox isolation — the handle never blocks.

import Foundation

// MARK: - Engine Handle (Type-Erased Facade)

/// Lightweight non-blocking facade returned by ``EnginePool/acquire(model:)``.
///
/// Delegates all operations to ``EnginePool`` via actor mailbox isolation.
/// The handler creates one handle per request and releases it on completion.
struct EngineHandle: Sendable {
    /// Model identifier for this handle
    let modelId: String

    /// Session tracking ID (used by KV cache manager for GPU accounting)
    let sessionId: String

    /// Reference to the engine pool actor
    let pool: EnginePool

    /// Create a new handle pointing to the given pool.
    init(modelId: String, sessionId: String, pool: EnginePool) {
        self.modelId = modelId
        self.sessionId = sessionId
        self.pool = pool
    }

    // MARK: - Lifecycle

    /// Release the session back to the pool (actor mailbox send).
    /// Call via ``defer`` to ensure cleanup on all code paths.
    func release() async {
        await pool.releaseSession(modelId: modelId, sessionId: sessionId)
    }

    /// Mark this session as active — resets the idle eviction timer.
    /// Called at the start of inference.
    func markActive() async {
        await pool.markSessionActive(sessionId: sessionId)
    }

    // MARK: - Tokenization (via pool delegation)

    /// Tokenize messages using the model's tokenizer.
    ///
    /// - Parameter messages: Message array
    /// - Returns: Token ID array
    func tokenize(messages: [Message]) async throws -> [Int32] {
        try await pool.tokenize(modelId: modelId, messages: messages)
    }

    /// Detokenize token IDs back to text.
    ///
    /// - Parameter tokens: Token ID array
    /// - Returns: Decoded text
    func detokenize(tokens: [Int32]) async throws -> String {
        try await pool.detokenize(modelId: modelId, tokens: tokens)
    }

    /// Count tokens for a raw text string (wraps in single user message).
    ///
    /// - Parameter text: Raw text to count
    /// - Returns: Token count
    func countTokens(text: String) async throws -> Int {
        let messages: [Message] = [.init(role: "user", content: text)]
        return try await tokenize(messages: messages).count
    }

    // MARK: - Inference (delegates to pool)

    /// Start generation — returns async stream of ``InferenceEvent`` values.
    ///
    /// - Parameters:
    ///   - input: Tokenized input array
    ///   - sampling: Sampling configuration
    ///   - options: Inference options
    ///   - cancellation: Cancellation token (default ``none`` — never autocancels)
    /// - Returns: Async throwing stream of events
    func generateTokens(
        input: [Int32],
        sampling: SamplingConfiguration,
        options: InferenceOptions,
        cancellation: InferenceCancellation = .none
    ) -> AsyncThrowingStream<InferenceEvent, Error> {
        let metrics = PerRequestMetrics()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in
                // 当消费者停止消费（取消/错误/完成），立即通知底层推理取消
                cancellation.cancel()
            }
            Task {
                do {
                    for try await event in await pool.doInference(
                        modelId: modelId,
                        input: input,
                        sampling: sampling,
                        options: options,
                        metrics: metrics,
                        cancellation: cancellation
                    ) {
                        guard !Task.isCancelled else { break }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Start generation from messages directly — eliminates tokenize→detokenize→re-tokenize loop on MLX path.
    ///
    /// On MLX backend: passes messages directly to ``ChatSession`` (MLX tokenizes internally).
    /// On CoreAI backend: falls through to ``generateTokens(input:sampling:options:)`` after tokenizing.
    ///
    /// - Parameters:
    ///   - messages: Message array (tokenized on CoreAI, passed directly on MLX)
    ///   - sampling: Sampling configuration
    ///   - options: Inference options
    ///   - conversationId: Optional conversation ID for session pooling / KV cache reuse
    ///   - cancellation: Cancellation token (default ``none`` — never autocancels)
    /// - Returns: Async throwing stream of events
    func generateFromMessages(
        messages: [Message],
        sampling: SamplingConfiguration,
        options: InferenceOptions,
        conversationId: String? = nil,
        cancellation: InferenceCancellation = .none
    ) -> AsyncThrowingStream<InferenceEvent, Error> {
        let metrics = PerRequestMetrics()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in
                // 当消费者停止消费，立即取消底层推理
                cancellation.cancel()
            }
            Task {
                do {
#if mlx
                    // MLX path: direct message-to-ChatSession, no tokenize detour
                    for try await event in await pool.doInferenceMLX(
                        modelId: modelId,
                        messages: messages,
                        sampling: sampling,
                        options: options,
                        metrics: metrics,
                        conversationId: conversationId,
                        cancellation: cancellation
                    ) {
                        guard !Task.isCancelled else { break }
                        continuation.yield(event)
                    }
#else
                    // CoreAI / stub path: tokenize then infer (unchanged)
                    let tokens = try await pool.tokenize(modelId: modelId, messages: messages)
                    guard !tokens.isEmpty else {
                        let err = NSError(domain: "ocoreai", code: 400,
                            userInfo: [NSLocalizedDescriptionKey: "Empty token output for model '\(modelId)'"])
                        continuation.finish(throwing: err)
                        return
                    }
                    for try await event in await pool.doInference(
                        modelId: modelId,
                        input: tokens,
                        sampling: sampling,
                        options: options,
                        metrics: metrics,
                        cancellation: cancellation
                    ) {
                        guard !Task.isCancelled else { break }
                        continuation.yield(event)
                    }
#endif
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
