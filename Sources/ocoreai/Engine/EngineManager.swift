// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineManager.swift — CoreAI engine lifecycle, pooling, and inference orchestration
///
/// ### Architecture:
/// - **EnginePool** (actor): Shared mutable state — loaded models, session acquisition,
///   runtime parameter hot-swap, and TaskGroup inference dispatch.
/// - **LoadedModel** (private actor): Per-model state — CAS warmup guard, inference lock,
///   session counting, metadata.
/// - **EngineHandle** (struct): Non-blocking facade returned to handlers; delegates to pool
///   via actor mailbox. Never blocks.
///
/// ### Compliance (Apple):
/// - v8: `EnginePool` → ``actor`` (was @MainActor class) for strict concurrency
/// - v8: All force-unwraps → ``guard`` + ``throw``
/// - v8: `ContinuousClock.Instant` replaces UInt64 nanoseconds
/// - v8: Logger API aligned (label:, message:)
///
/// ### Runtime Parameter Hot-Swap:
/// Per-model sampling defaults updated via ``EnginePool/updateSamplingConfig(modelId:config:)``
/// without restart. Defaults cascade: ``request.body`` → ``ModelSamplingConfig.runtime`` → ``SystemDefault``.
///
/// ### Dual-Backend (v18):
/// - 'coreai' trait: CoreAI framework (macOS 27+)
/// - 'mlx' trait: MLXLLM (macOS 15+)
/// - Neither: stub types from ``InferenceStubs``

import Atomics
import Foundation
import Logging

// MARK: - Imports (guarded by 'coreai' trait)

#if coreai
import CoreAI
import CoreAILanguageModels
import CoreAIShared
#endif

#if mlx
import MLXLLM
import MLXLMCommon
#endif

// MARK: - Configuration

/// Engine pool configuration — passed by value, immutable after initialization.
///
/// Controls concurrent session limits, queue depth, model paths, warmup behavior,
/// and optional KV cache management.
struct EnginePoolConfig: Sendable {
    /// Maximum concurrent inference sessions before queuing
    var maxConcurrentSessions: Int

    /// Maximum queued requests before rejection
    var maxQueueSize: Int

    /// Base filesystem path to model configuration files
    var modelConfigPath: String

    /// Base filesystem path to model weight directories
    var modelDirectory: String

    /// Default model identifier (Hub id or local path)
    /// Format: "hf:org/model" for HuggingFace, "mscope:org/model" for ModelScope, or "/path/to/model"
    var defaultModelId: String

    /// Number of tokens for the prewarm (warmup) inference run
    var warmupTokens: Int

    /// Optional KV cache management configuration (nil = kvCache disabled)
    var kvCacheConfig: KVCacheManager.Config?

    /// Hard timeout for a single inference request (seconds).
    /// Prevents hung inference from permanently holding resources.
    var inferenceTimeoutSeconds: Int

    /// Optional session pool configuration (nil = pooling disabled).
    /// When enabled, ChatSession instances are pooled per-conversation for KV cache reuse.
    var sessionPoolConfig: SessionPoolConfig?

    /// Default configuration with sensible production values
    static let `default`: EnginePoolConfig = .init(
        maxConcurrentSessions: 8,
        maxQueueSize: 32,
        modelConfigPath: "./models/config.json",
        modelDirectory: "./models",
        defaultModelId: "hf:mlx-community/Qwen3.5-4B-OptiQ-4bit",
        warmupTokens: 4,
        kvCacheConfig: nil,
        inferenceTimeoutSeconds: 180,
        sessionPoolConfig: .default
    )
}

// MARK: - Cancellation Token

/// Lightweight cancellation token for propagating cancellation across task boundaries.
///
/// Used by SSE handlers to cancel inference running in unrelated root Tasks.
struct InferenceCancellation: Sendable {
    private let _token: Task<Void, Error>?

    /// Non-cancellable handle (used for non-stream endpoints)
    static let none: Self = .init()

    /// Cancellable handle — cancels underlying task when ``cancel()`` is called
    static func cancellable() -> Self {
        .init(_token: Task { () })
    }

    /// Check if this token has been cancelled
    /// - Returns: true if the cancel signal has been sent
    var isCancelled: Bool {
        _token?.isCancelled == true
    }

    /// Send cancellation signal to all holders of this token
    func cancel() {
        _token?.cancel()
    }

    private init(_token: Task<Void, Error>? = nil) {}
}

// MARK: - Inference Event

/// Unified event type streamed from the inference pipeline to the handler.
///
/// Events flow through ``AsyncThrowingStream`` so the HTTP layer can emit SSE chunks.
struct InferenceEvent: Sendable {
    /// Event kind discriminator
    enum Kind: Sendable {
        /// Generated token (`Int32` token ID — Core AI path)
        case token(Int32)

        /// Generated text chunk (MLX path — already decoded)
        case text(String)

        /// Generation complete (optional `StopReason`)
        case done(StopReason?)

        /// Fatal inference error
        case error(String)
    }

    /// Event payload
    var kind: Kind
}

// MARK: - Engine Pool Actor

/// Shared engine pool with ``actor`` isolation for mutable ``loadedModels``.
///
/// Responsible for:
/// - Lazy model loading on first request
/// - Tokenization/detokenization via ``TokenizerManager``
/// - Session acquisition/release bookkeeping
/// - TaskGroup inference dispatch (never blocks the actor)
/// - Runtime sampling parameter hot-swap
/// - Graceful shutdown
actor EnginePool {

    // MARK: - State

    /// Immutable pool configuration
    private let config: EnginePoolConfig

    /// Logger for observability
    private let logger: Logger

    /// Tokenizer registry (shared, thread-safe actor)
    let tokenizerManager: TokenizerManager

    /// Loaded model instances keyed by model ID
    private var loadedModels: [String: LoadedModel] = [:]

    /// KV cache manager (optional — nil when feature disabled).
    /// When set, active sessions are tracked and evicted on GPU memory pressure.
    private let kvCacheManager: KVCacheManager?

    // MARK: - Model Loading

#if coreai
    /// Two-phase Core AI model loader — specializes models at load time
    /// so inference reuses a pre-compiled ``AIModel`` instead of ``EngineFactory``.
    private let coreAIPreparedModelLoader: CoreAIModelLoader
#endif

#if mlx
    /// MLX model loader — loads models via MLXLLM
    private let mlxModelLoader: MLXModelLoader

    /// MLX ChatSession pool for KV cache reuse (nil = pooling disabled)
    private let sessionPool: MLXSessionPool?
#endif

    // MARK: - Runtime Parameter Store (hot-swappable)

    /// Per-model runtime sampling defaults — updated via ``PATCH`` endpoint.
    /// Cascade priority: ``ChatCompletionRequest`` body → this dict → ``ModelSamplingConfig/default``.
    private var modelSamplingDefaults: [String: ModelSamplingConfig] = [:]

    /// Tracked inference tasks — used by ``shutdown()`` to cancel + await all running inferences
    private var trackedTasks: [Task<Void, Never>] = []

    // MARK: - Initialization

    /// Create the engine pool with the given config, logger, tokenizer manager,
    /// and optional KV cache manager.
    ///
    /// - Parameters:
    ///   - config: Pool configuration
    ///   - logger: Observability logger
    ///   - tokenizerManager: Shared tokenizer registry
    ///   - kvCacheConfig: KV cache management configuration (nil = disabled)
    ///   - coreAILoadingConfig: Core AI two-phase loading config (v15, coreai trait only)
    ///   - hfToken: Optional HuggingFace API token (for gated models)
    ///   - modelScopeToken: Optional ModelScope API token (for private repos)
    init(
        config: EnginePoolConfig = .default,
        logger: Logger,
        tokenizerManager: TokenizerManager,
        kvCacheConfig: KVCacheManager.Config? = nil,
        coreAILoadingConfig: CoreAILoadingConfig = .init(),
        hfToken: String? = nil,
        modelScopeToken: String? = nil
    ) {
        precondition(config.maxConcurrentSessions > 0, "maxConcurrentSessions must be positive")
        precondition(config.maxQueueSize > 0, "maxQueueSize must be positive")
        precondition(config.warmupTokens > 0, "warmupTokens must be positive")
        self.config = config
        self.logger = logger
        self.tokenizerManager = tokenizerManager
        self.kvCacheManager = kvCacheConfig.map { KVCacheManager(config: $0, logger: logger) }
#if coreai
        self.coreAIPreparedModelLoader = CoreAIModelLoader(
            config: coreAILoadingConfig,
            logger: logger
        )
        logger.info("CoreAIModelLoader initialized (v15 two-phase specialization)")
#elseif mlx
        self.mlxModelLoader = MLXModelLoader(
            logger: logger,
            modelScopeToken: modelScopeToken,
            hfToken: hfToken
        )
        logger.info("MLXModelLoader initialized (MLXLLM backend)")

        // Session Pool — KV cache reuse for conversation continuity
        if let poolConfig = config.sessionPoolConfig, poolConfig.enabled {
            self.sessionPool = MLXSessionPool(config: poolConfig, logger: logger)
            logger.info("MLXSessionPool enabled (max=\(poolConfig.maxSessions), ttl=\(poolConfig.sessionTTLSeconds)s)")
        } else {
            self.sessionPool = nil
            logger.info("MLXSessionPool disabled (create-and-destroy per request)")
        }
#else
        logger.info("EnginePool initialized (no inference trait — stub backend)")
#endif
    }

    // MARK: - Tokenization

    /// Convert ContentPolymorphic to String for tokenization input.
    private static func contentToString(_ content: ContentPolymorphic?) -> String {
        guard let content = content else { return "" }
        switch content {
        case .text(let s): return s
        case .parts(let parts): return parts.compactMap { $0.text }.joined(separator: " ")
        }
    }

    /// Tokenize a message array using the tokenizer for the given model.
    func tokenize(modelId: String, messages: [Message]) async throws -> [Int32] {
        guard let provider = await tokenizerManager.getTokenizer(for: modelId) else {
            throw AppError.modelNotFound(modelId)
        }
        let dicts: [[String: String]] = messages.map {
            ["role": $0.role, "content": Self.contentToString($0.content)]
        }
        return try await provider.tokenize(messages: dicts)
    }

    /// Detokenize a token array using the tokenizer for the given model.
    func detokenize(modelId: String, tokens: [Int32]) async throws -> String {
        guard let provider = await tokenizerManager.getTokenizer(for: modelId) else {
            throw AppError.modelNotFound(modelId)
        }
        return try await provider.detokenize(tokenIds: tokens)
    }

    // MARK: - Acquire / Release

    /// Acquire an inference session handle for the given model.
    ///
    /// Lazily loads the model on first access. Triggers prewarm if needed.
    /// Registers the session with ``KVCacheManager`` (if enabled) so GPU cache
    /// accounting and eviction can operate.
    ///
    /// - Parameter modelId: Model identifier
    /// - Returns: ``EngineHandle`` facade containing the session ID for tracking
    /// - Throws: ``AppError/engineUnavailable`` if model failed to load
    func acquire(model modelId: String) async throws -> EngineHandle {
        if loadedModels[modelId] == nil {
            loadedModels[modelId] = try await loadModel(modelId)
        }
        guard let model = loadedModels[modelId] else {
            throw AppError.engineUnavailable
        }

        try await model.prewarmIfNeeded(config.warmupTokens)
        model.acquireSession()

        // Register session with KV cache manager for GPU tracking.
        let sessionId = UUID().uuidString
        if let kvCache = kvCacheManager {
            // NOTE: CoreAI does not yet expose per-session AsyncKVState,
            // so we register the session ID with a zero-byte estimate.
            // The eviction loop will still operate on session age.
            await kvCache.registerZeroSession(sessionId: sessionId)
        }

        logger.info(
            "Session acquired",
            metadata: [
                "model": .string(modelId),
                "active": .string(String(model.activeSessions)),
                "session": .string(sessionId),
            ]
        )

        return EngineHandle(modelId: modelId, sessionId: sessionId, pool: self)
    }

    /// Release session back to the pool (called from ``EngineHandle``).
    /// Unregisters the session from ``KVCacheManager`` if enabled.
    func releaseSession(modelId: String, sessionId: String) async {
        loadedModels[modelId]?.releaseSession()
        await kvCacheManager?.unregister(sessionId: sessionId)
    }

    /// Mark an existing session as active — resets the idle eviction timer.
    func markSessionActive(sessionId: String) async {
        await kvCacheManager?.markActive(sessionId: sessionId)
    }

    // MARK: - Inference (TaskGroup dispatch)

    /// Start inference, returning an ``AsyncThrowingStream`` the caller consumes.
    ///
    /// Heavy execution runs off-actor in a background ``Task``, so the actor mailbox
    /// never blocks. Events stream via SSE to the HTTP handler.
    ///
    /// - Parameters:
    ///   - modelId: Model identifier
    ///   - input: Tokenized input array
    ///   - sampling: Sampling configuration
    ///   - options: Inference options (maxTokens, etc.)
    ///   - metrics: Per-request metrics collector
    ///   - cancellation: Cancellation token — SSE handlers pass a cancellable token so client disconnect stops inference
    /// - Returns: Async stream of ``InferenceEvent`` values
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
                // Register with shutdown tracker
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
                await self.registerTrackedTask(tracker)
                defer { await self.removeTrackedTask(tracker) }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await tracker.value }
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(500))
                        while !Task.isCancelled {
                            if cancellation.isCancelled || ContinuousClock.now >= deadline {
                                group.cancelAll()
                                break
                            }
                            try await Task.sleep(for: .milliseconds(500))
                        }
                    }
                }
            }
        }
    }

    /// MLX-specific inference entry — accepts messages directly, skipping tokenize→detokenize→re-tokenize loop.
    ///
    /// MLX `ChatSession` handles tokenization internally, so passing raw messages
    /// eliminates the detokenize step and avoids MLX re-tokenize overhead.
    ///
    /// - Parameters:
    ///   - modelId: Model identifier
    ///   - messages: Message array (passed directly to MLX ChatSession)
    ///   - sampling: Sampling configuration
    ///   - options: Inference options (maxTokens, etc.)
    ///   - metrics: Per-request metrics collector
    ///   - conversationId: Optional conversation ID for session pooling / KV cache reuse
    ///   - cancellation: Cancellation token — SSE handlers pass a cancellable token so client disconnect stops inference
    /// - Returns: Async stream of ``InferenceEvent`` values
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
                // Register with shutdown tracker
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
                await self.registerTrackedTask(tracker)
                defer { await self.removeTrackedTask(tracker) }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await tracker.value }
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(500))
                        while !Task.isCancelled {
                            if cancellation.isCancelled || ContinuousClock.now >= deadline {
                                group.cancelAll()
                                break
                            }
                            try await Task.sleep(for: .milliseconds(500))
                        }
                    }
                }
            }
        }
    }
    #endif

    #if mlx
    /// Internal inference runner that accepts messages directly for MLX path.
    ///
    /// Unlike ``_runInference(modelId:input:sampling:options:metrics:continuation:)``,
    /// this variant passes messages to ``ChatSession`` without tokenize/detokenize round-trip.
    ///
    /// When ``sessionPool`` is non-nil and a ``conversationId`` is provided, the runner
    /// acquires a pooled ``ChatSession`` (KV cache warm) instead of creating a fresh one.
    private func _runInferenceWithMessages(
        modelId: String,
        messages: [Message],
        sampling: SamplingConfiguration,
        options: InferenceOptions,
        metrics: PerRequestMetrics,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation,
        conversationId: String?,
        cancellation: InferenceCancellation = .none
    ) async {
        guard let loaded = loadedModels[modelId] else {
            continuation.yield(.init(kind: .error("Model not loaded: \(modelId)")))
            continuation.finish()
            return
        }

        // Count tokens for metrics (single tokenize, no detokenize round-trip)
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

        guard loaded.tryAcquireInference() else {
            continuation.yield(.init(kind: .error("Engine busy")))
            continuation.finish()
            return
        }
        defer { loaded.releaseInference() }

        guard let mlxHandle = loaded.mlxModelHandle else {
            continuation.yield(.init(kind: .error("MLX model handle not loaded: \(modelId)")))
            continuation.finish()
            return
        }

        // Convert internal [Message] to MLX [Chat.Message] — no detokenize needed
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
            maxTokens: options.maxTokens
        )

        // Session pool: acquire pooled session or create fresh one
        var chatSession: ChatSession
        let convKey: String = conversationId ?? "\(modelId):ephemeral"
        var isPoolHit = false
        var deltaOffset = 0 // messages already in KV cache (skip for delta)
        if let pool = sessionPool {
            let acquired = await pool.acquire(
                from: mlxHandle.modelContainer,
                modelId: modelId,
                conversationId: convKey,
                genParams: genParams
            )
            chatSession = acquired.session
            isPoolHit = acquired.isHit
            deltaOffset = acquired.processedMessageCount
            if isPoolHit {
                logger.debug("Pool HIT for \(convKey) — KV cache reused (offset=\(deltaOffset))")
            }
        } else {
            // Fallback: create fresh session (no pooling)
            chatSession = ChatSession(
                mlxHandle.modelContainer,
                generateParameters: genParams
            )
        }

        // Pool release guard — return session to pool after inference
        let poolRef = sessionPool

        do {
            // Send only delta messages (new messages since last turn) to avoid KV duplication
            let messagesToSend: [Chat.Message]
            if isPoolHit && deltaOffset < mlxMessages.count {
                messagesToSend = Array(mlxMessages[deltaOffset...])
            } else if isPoolHit && deltaOffset >= mlxMessages.count {
                // Edge case: cached session thinks it has more messages than we sent
                // (e.g. client retried with shorter history). Reset — send all.
                logger.warning("Pool session messageCount (\(deltaOffset)) >= current messages (\(mlxMessages.count)), sending all")
                messagesToSend = mlxMessages
            } else {
                // Fresh session — send all messages
                messagesToSend = mlxMessages
            }

            let genStream: AsyncThrowingStream<MLXLMCommon.Generation, Error> =
                try await chatSession.streamDetails(to: messagesToSend)

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
                    case .info, .toolCall: break // ignored for inference
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
        } catch {
            continuation.yield(.init(kind: .error(error.localizedDescription)))
        }

        metrics.inferenceMs = metrics.overallMs

        // Release session back to pool (synchronous, after inference completes)
        if let pool = poolRef {
            // Track total messages now baked into KV cache for next turn's delta
            let newMessageCount = isPoolHit ? (deltaOffset + mlxMessages.count - deltaOffset) : mlxMessages.count
            await pool.release(
                session: chatSession,
                modelId: modelId,
                conversationId: convKey,
                processedMessageCount: newMessageCount
            )
        }

        continuation.finish()
    }
    #endif

    /// Internal inference runner — executes inside a background ``Task`` (not on actor).
    ///
    /// 1. Validates model is loaded and input fits within context window
    /// 2. Acquires CAS inference guard (prevents concurrent generation on same model)
    /// 3. Creates engine, generates tokens, streams events via continuation
    /// 4. Resets KV cache, logs metrics, finishes stream
    /// 5. Hard timeout enforces resource release
    private func _runInference(
        modelId: String,
        input: [Int32],
        sampling: SamplingConfiguration,
        options: InferenceOptions,
        metrics: PerRequestMetrics,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation,
        cancellation: InferenceCancellation = .none
    ) async {
        // 1. Validate model is loaded
        guard let loaded = loadedModels[modelId] else {
            continuation.yield(.init(kind: .error("Model not loaded: \(modelId)")))
            continuation.finish()
            return
        }

        // 2. Validate input fits context window
        let tokenCount = input.count
        if tokenCount > loaded.modelConfig.maxContextLength {
            continuation.yield(.init(kind: .error(
                "Input \(tokenCount) exceeds max context \(loaded.modelConfig.maxContextLength)"
            )))
            continuation.finish()
            return
        }

        // 3. Begin metrics tracking
        metrics.promptTokenCount = tokenCount
        metrics.start()

        // 4. CAS contention guard — prevents concurrent inference on same model
        guard loaded.tryAcquireInference() else {
            continuation.yield(.init(kind: .error("Engine busy")))
            continuation.finish()
            return
        }
        defer { loaded.releaseInference() }

#if coreai
        // 5. CoreAI inference path — create engine, generate, stream tokens
        do {
            let engine = try await EngineFactory.createEngine(
                config: loaded.configData,
                modelURL: loaded.modelURL,
                options: loaded.engineOptions
            )
            // Generate token stream
            let sequence = try engine.generate(
                with: input,
                samplingConfiguration: sampling,
                inferenceOptions: options
            )

            // Stream each generated token
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

            // Stop signal (only if not cancelled)
            if !Task.isCancelled {
                continuation.yield(.init(kind: .done(sequence.stopReason)))
            }

            // Engine cleanup: reset KV cache + release (log errors only, don't send to continuation)
            do {
                try await engine.reset()
                logger.info("Engine cache reset completed")
            } catch {
                logger.warning("Engine reset failed: \(error.localizedDescription)")
            }

        } catch {
            continuation.yield(.init(kind: .error(error.localizedDescription)))
        }
#endif

#if mlx
        // 5. MLX inference path — stream text chunks via ChatSession
        do {
            guard let mlxHandle = loaded.mlxModelHandle else {
                continuation.yield(.init(kind: .error("MLX model handle not loaded: \(modelId)")))
                continuation.finish()
                return
            }

            // Build messages from tokenizer output (MLX handles tokenization internally,
            // but we need to pass text — use the first element as prompt text)
            // Since _runInference receives tokenized input, we detokenize first
            let promptText = (try? await detokenize(modelId: modelId, tokens: input))
                ?? "<detokenization failed>"
            let mlxMessages: [Chat.Message] = [.init(role: .user, content: promptText)]

            let genParams = makeGenerateParameters(
                from: sampling,
                maxTokens: options.maxTokens
            )

            let chatSession = ChatSession(
                mlxHandle.modelContainer,
                generateParameters: genParams
            )

            let genStream: AsyncThrowingStream<MLXLMCommon.Generation, Error> =
                try await chatSession.streamDetails(to: mlxMessages)

            // Log TTFB after first token
            metrics.firstTokenMs = metrics.overallMs

            // Generate and stream tokens
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
                    case .info, .toolCall: break // ignored for inference
                    }
                }
            } catch {
                continuation.yield(.init(kind: .error(error.localizedDescription)))
            }

            // Stop signal
            if !Task.isCancelled {
                continuation.yield(.init(kind: .done(nil)))
            }

        } catch {
            continuation.yield(.init(kind: .error(error.localizedDescription)))
        }
#endif

#if !coreai && !mlx
        // 5. Stub inference path — neither coreai nor mlx trait enabled
        continuation.yield(.init(kind: .error("Inference unavailable — neither coreai nor mlx trait enabled")))
#endif

        // 6. Finalize metrics + close stream
        metrics.inferenceMs = metrics.overallMs
        continuation.finish()
    }

    // MARK: - Model Loading

    /// Lazy-load a model by ID from the filesystem.
    ///
    /// Reads ``config.json``, validates, resolves weight path, then runs
    /// Core AI two-phase specialization (v15) before returning a ``LoadedModel``.
    ///
    /// - Parameter modelId: Model identifier
    /// - Returns: Loaded model instance ready for inference
    /// - Throws: File I/O error or ``ModelConfig`` validation failure
    private func loadModel(_ modelId: String) async throws -> LoadedModel {
        logger.info("Loading model: \(modelId)")

        var configURL = URL(fileURLWithPath: config.modelConfigPath)
        let candidate = configURL
            .appendingPathComponent(modelId)
            .appendingPathComponent("config.json")
        if candidate.isFileURL, FileManager.default.fileExists(atPath: candidate.path) {
            configURL = candidate
        }

        let configData = try Data(contentsOf: configURL)
        let modelConfig = try ModelConfig(parsing: configData)
        try modelConfig.validate()

        let baseDir = URL(fileURLWithPath: config.modelDirectory)
            .appendingPathComponent(modelId)
        let modelName = modelConfig.serializedModel.first ?? "\(modelId).aimodel"
        let modelURL = baseDir.appendingPathComponent(modelName)

        logger.info("Model \(modelId) metadata loaded")

#if coreai
        // v15: Two-phase Core AI loading — specialize at load time, reuse across requests
        let preparedModel = try await coreAIPreparedModelLoader.load(
            modelURL: modelURL,
            modelId: modelId
        )

        let loadTag = preparedModel.isSpecialized ? "specialized" : "fallback (EngineFactory)"
        logger.info(
            "Model \(modelId) prepared: \(loadTag)",
            metadata: [
                "specialized": .string(String(preparedModel.isSpecialized)),
            ]
        )

        return LoadedModel(
            configData: configData,
            modelURL: modelURL,
            modelConfig: modelConfig,
            preparedModel: preparedModel,
            logger: logger
        )
#elseif mlx
        // MLX loading path — loads model via MLXLLM
        let mlxHandle = try await mlxModelLoader.load(
            modelURL: modelURL,
            modelId: modelId
        )
        logger.info("MLX model \(modelId) loaded successfully")

        let model = LoadedModel(
            configData: configData,
            modelURL: modelURL,
            modelConfig: modelConfig,
            logger: logger
        )
        model.setMLXHandle(mlxHandle)
        return model
#else
        // Stub: no inference backend available
        return LoadedModel(
            configData: configData,
            modelURL: modelURL,
            modelConfig: modelConfig,
            logger: logger
        )
#endif
    }

    // MARK: - Inspection

    /// List loaded models with metadata (used by ``GET /v1/models`` endpoint).
    ///
    /// - Returns: Array of model info dictionaries
    func listModels() -> [[String: String]] {
        loadedModels.compactMap { id, model in
            [
                "id": id,
                "max_context_length": String(model.modelConfig.maxContextLength),
                "vocab_size": String(model.modelConfig.vocabSize),
                "tokenizer": model.modelConfig.tokenizer,
            ]
        }
    }

    /// Snapshot of engine pool health (used by ``GET /health`` endpoint).
    ///
    /// - Returns: Summary with model count, active sessions, and GPU cache usage
    func engineSummary() async -> EngineSummary {
        let gpuCacheGB = await kvCacheManager?.gpuUsageGB() ?? 0.0
#if coreai
        /* v15: count models with specialization compiled */
        let specializedCount = loadedModels.values.filter { $0.preparedModel.isSpecialized }.count
#else
        let specializedCount = 0
#endif
        return EngineSummary(
            loadedModels: loadedModels.count,
            activeSessions: loadedModels.values.reduce(0, { $0 + $1.activeSessions }),
            gpuCacheGB: gpuCacheGB,
            specializedModels: specializedCount
        )
    }

    /// Count of loaded model instances.
    ///
    /// - Returns: Model count
    func loadedModelCount() -> Int { loadedModels.count }

    /// Current GPU cache usage in gigabytes (0 if KV cache disabled).
    ///
    /// - Returns: GPU cache usage in GB
    func gpuCacheUsageGB() async -> Double {
        await kvCacheManager?.gpuUsageGB() ?? 0.0
    }

    // MARK: - Runtime Parameter API (hot-swap)

    /// Get current runtime sampling defaults for a model.
    ///
    /// - Parameter modelId: Model identifier
    /// - Returns: Sampling config (falls back to ``ModelSamplingConfig/default``)
    func getSamplingConfig(modelId: String) -> ModelSamplingConfig {
        modelSamplingDefaults[modelId] ?? .default
    }

    /// Update sampling defaults for a model in-place (no restart needed).
    ///
    /// - Parameters:
    ///   - modelId: Model identifier
    ///   - config: New sampling configuration
    func updateSamplingConfig(modelId: String, config: ModelSamplingConfig) {
        modelSamplingDefaults[modelId] = config
        logger.info("Sampling config updated for model: \(modelId)")
    }

    /// Reset sampling defaults for a specific model back to system defaults.
    ///
    /// - Parameter modelId: Model identifier to reset
    func resetSamplingConfig(modelId: String) {
        modelSamplingDefaults.removeValue(forKey: modelId)
        logger.info("Sampling config reset to defaults for model: \(modelId)")
    }

    /// Reset ALL model sampling defaults back to system defaults.
    func resetAllSamplingConfig() {
        modelSamplingDefaults.removeAll()
        logger.info("All sampling configs reset to defaults")
    }

    // MARK: - Tracked Task Management

    /// Register an inference task for graceful shutdown tracking
    func registerTrackedTask(_ task: Task<Void, Never>) {
        trackedTasks.append(task)
    }

    /// Remove a completed inference task from tracking
    func removeTrackedTask(_ task: Task<Void, Never>) {
        trackedTasks.removeAll { $0 === task }
    }

    // MARK: - Graceful Shutdown

    /// Drain all loaded models and release resources.
    ///
    /// Called during application shutdown to terminate inference tasks
    /// and release GPU/SSD cached data.
    func shutdown() async {
        // 1. Cancel all active inference tasks and wait for them to complete
        //    This prevents use-after-free when models are unloaded below.
        let tasksToWait = trackedTasks
        trackedTasks.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for task in tasksToWait {
                group.addTask {
                    task.cancel()
                    try? await task.value
                }
            }
        }
        logger.info("All tracked inference tasks cancelled")

        // 2. Clear session pool before model teardown (releases pooled KV caches)
        #if mlx
        if let pool = sessionPool {
            await pool.clear()
        }
        #endif

        // 3. Cold-store all active KV cache sessions to SSD before unloading models
        if let kvCache = kvCacheManager {
            await kvCache.coldStoreActiveSessions()
            await kvCache.shutdown()
        }

        // 4. Unload models and reclaim GPU memory
        for model in loadedModels.values {
            model.cleanup()
        }
        loadedModels.removeAll()
    }
}

// MARK: - LoadedModel

/// Per-model engine state — immutable metadata with atomic counters.
///
/// Manages warmup lifecycle (CAS-guarded), inference contention (CAS lock),
/// and session counting (atomic). Marked `@unchecked Sendable` because mutable
/// atomics carry cross-execution-context state that the compiler cannot verify.
private final class LoadedModel: @unchecked Sendable {

    // MARK: - Metadata

    /// Raw model config binary data
    let configData: Data

    /// Resolved filesystem path to model weights
    let modelURL: URL

    /// Parsed model configuration (context length, vocab, tokenizer)
    let modelConfig: ModelConfig

#if coreai
    /// v15: Specialized Core AI model — compiled once at load time, reused across requests
    let preparedModel: CoreAIPreparedModel

    /// Engine options (KV cache strategy, etc.) — used when fallback path active
    let engineOptions: EngineOptions
#endif

#if mlx
    /// MLXLLM model handle — loaded once at load time, reused across inference
    var mlxModelHandle: (any MLXModelHandle)?
#endif

    /// Logger for observability
    let logger: Logger

    // MARK: - Warmup (CAS-guarded, runs once)

    /// Atomic flag — `true` after prewarm completes
    private let wasPrewarmed = ManagedAtomic<Bool>(false)

    /// Run the warmup (preflight) inference once, guarded by CAS.
    ///
    /// - Parameter warmupTokens: Number of tokens to generate during warmup
    func prewarmIfNeeded(_ warmupTokens: Int) async throws {
        // CAS exchange: only the first caller enters; others return immediately
        guard wasPrewarmed.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }

        logger.info("Prewarming \(modelConfig.name ?? "model")...")
        let startTime = ContinuousClock.now

        #if coreai
        do {
            let engine = try await EngineFactory.createEngine(
                config: configData,
                modelURL: modelURL,
                options: engineOptions
            )
            let seq = try engine.generate(
                with: Array(repeating: 0, count: 8),
                samplingConfiguration: SamplingConfiguration(),
                inferenceOptions: InferenceOptions(maxTokens: warmupTokens)
            )
            // Drain stream to complete warmup
            for try await _ in seq {}
        } catch {
            logger.warning("Warmup skipped (non-fatal): \(error)")
        }
        #elseif mlx
        do {
            guard let handle = mlxModelHandle else {
                logger.warning("MLX warmup skipped: no model handle")
                return
            }
            let mlxMessages: [Chat.Message] = [.init(role: .user, content: "warmup")]
            let mlxParams = makeGenerateParameters(
                from: SamplingConfiguration(),
                maxTokens: warmupTokens
            )
            let session = ChatSession(
                handle.modelContainer,
                generateParameters: mlxParams
            )
            let genStream: AsyncThrowingStream<MLXLMCommon.Generation, Error> =
                try await session.streamDetails(to: mlxMessages)
            for try await _ in genStream { break }
        } catch {
            logger.warning("MLX warmup skipped (non-fatal): \(error)")
        }
        #else
        // Stub warmup — no inference backend available
        logger.info("Warmup skipped (no inference trait)")
        #endif

        let elapsed = Double(startTime.duration(to: ContinuousClock.now).components.attoseconds) / 1e17
        logger.info("Prewarmed in \(String(format: "%.1f", elapsed))ms")
    }

    // MARK: - Inference Contention Guard (CAS lock)

    /// Atomic lock — `true` while inference is running on this model
    private let inferenceGuard = ManagedAtomic<Bool>(false)

    /// Attempt to acquire the inference lock (non-blocking CAS).
    ///
    /// - Returns: `true` if lock acquired, `false` if another inference is active
    func tryAcquireInference() -> Bool {
        inferenceGuard.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged
    }

    /// Release the inference lock (called via ``defer``)
    func releaseInference() {
        inferenceGuard.store(false, ordering: .releasing)
    }

    // MARK: - Session Counting (atomic)

    /// Session counter
    private var sessionCount = 0

    /// Current active session count
    var activeSessions: Int { sessionCount }

    /// Increment session counter
    func acquireSession() { sessionCount += 1 }

    /// Decrement session counter
    func releaseSession() { sessionCount -= 1 }

    // MARK: - Cleanup

    /// Release all session state on shutdown.
    func cleanup() {
        sessionCount = 0
    }

    // MARK: - Initialization

#if coreai
    /// Create a loaded model instance with resolved config, weights, specialized model, and engine options.
    ///
    /// - Parameters:
    ///   - configData: Raw config binary
    ///   - modelURL: Weight filesystem path
    ///   - modelConfig: Parsed model configuration
    ///   - preparedModel: v15 specialized Core AI model (cached for reuse)
    ///   - logger: Observability logger
    init(configData: Data, modelURL: URL, modelConfig: ModelConfig, preparedModel: CoreAIPreparedModel, logger: Logger) {
        self.configData = configData
        self.modelURL = modelURL
        self.modelConfig = modelConfig
        self.preparedModel = preparedModel
        self.engineOptions = EngineOptions(kvCacheStrategy: .auto)
#if mlx
        self.mlxModelHandle = nil
#endif
        self.logger = logger
    }
#else // coreai — mlx path or stub
    /// Initialize model (mlx handle or neither-build stub).
    /// In mlx mode, ``mlxModelHandle`` is set via ``setMLXHandle(_:)`` after init.
    init(configData: Data, modelURL: URL, modelConfig: ModelConfig, logger: Logger) {
        self.configData = configData
        self.modelURL = modelURL
        self.modelConfig = modelConfig
#if mlx
        self.mlxModelHandle = nil
#endif
        self.logger = logger
    }
#if mlx
    /// Set MLX model handle after model loading completes.
    func setMLXHandle(_ handle: (any MLXModelHandle)) {
        self.mlxModelHandle = handle
    }
#endif
#endif // coreai
}

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
                        continuation.yield(event)
                    }
                    continuation.finish()
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
                        continuation.yield(event)
                    }
                    continuation.finish()
#endif
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
