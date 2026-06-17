// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// SessionPool.swift — ChatSession pooling for KV cache reuse across turns
//
// Provides per-conversation ChatSession pooling with LRU eviction and TTL-based expiry.
//
// ### Architecture:
// - **SessionPoolConfig**: Pool configuration (always compiled, trait-agnostic)
// - **MLXSessionPool** (actor, `#if mlx`): Owns the session pool map, handles eviction,
//   acquire/create, and hit-rate metrics.
// - **PooledChatSession** (struct, `#if mlx`): Metadata wrapper around a ``ChatSession``
//   with last-access timestamp for LRU tracking.
//
// ### Integration:
// - EnginePool delegates to SessionPool via acquire/release
// - When a pooled session is reused, the KV cache (prompt context) is preserved.
// - TTL expiry + LRU cap prevent unbounded memory growth.

import Logging

// MARK: - Configuration (trait-agnostic)

/// Session pool configuration — per-pool limits and TTL.
struct SessionPoolConfig: Sendable {
    /// Whether conversation pooling is enabled.
    /// When false, requests fall back to create-and-destroy (current behavior).
    var enabled: Bool = true

    /// Time-to-live for an idle pooled session (seconds).
    /// Sessions older than this are evicted on next ``acquire`` call.
    /// Default 600s (10 min) balances memory vs reuse.
    var sessionTTLSeconds: Int = 600

    /// Maximum number of pooled sessions across all models.
    /// Beyond this, LRU eviction removes the oldest session.
    /// Default 16 is safe for Apple Silicon UMA with ~4B models.
    var maxSessions: Int = 16

    /// Log hit/miss metrics every N acquires for observability.
    var metricsLogInterval: Int = 100

    /// Default configuration
    static let `default`: SessionPoolConfig = .init()
}

#if mlx

import Foundation
import MLXLLM
import MLXLMCommon

// MARK: - Pooled Session Entry

/// Metadata wrapper around a ``ChatSession`` with LRU tracking.
///
/// ``ChatSession`` is not ``Sendable`` (holds GPU-backed KV cache state),
/// but we need to cross isolation boundaries inside the actor.
/// The actor serializes all access so the underlying type is safe.
struct PooledChatSession: @unchecked Sendable {
    /// The underlying MLX chat session (holds KV cache)
    let session: ChatSession

    /// Timestamp of last access (acquire for inference)
    var lastAccessedAt: ContinuousClock.Instant

    /// Number of messages already baked into this session's KV cache.
    /// Used to send only delta messages on subsequent turns, avoiding duplication.
    let messageCount: Int
}

// MARK: - Session Pool Actor

/// Actor-owned pool of ``ChatSession`` instances keyed by
/// (modelId, conversationId). Handles TTL expiry + LRU eviction.
actor MLXSessionPool {

    // MARK: - State

    private let config: SessionPoolConfig
    private let logger: Logger
    private var pool: [String: PooledChatSession] = [:]

    // Hit-rate metrics
    private var hitCount = 0
    private var missCount = 0
    private var totalAcquireAttempts = 0

    // MARK: - Initialization

    init(config: SessionPoolConfig, logger: Logger) {
        self.config = config
        self.logger = logger
        logger.info(
            "MLXSessionPool initialized: maxSessions=\(config.maxSessions), ttl=\(config.sessionTTLSeconds)s"
        )
    }

    // MARK: - Acquire / Create

    /// Acquire a ``ChatSession`` for the given (model, conversation) key.
    ///
    /// If a pooled session exists and is within TTL, it is **returned and removed**
    /// from the pool (borrow pattern). The caller must ``release(session:modelId:conversationId:processedMessageCount:)``
    /// after inference completes.
    ///
    /// If no pooled session exists (or it expired), a **new** session is created.
    ///
    /// - Parameters:
    ///   - modelContainer: MLX model container (needed to create new sessions)
    ///   - modelId: Model identifier for pooling key
    ///   - conversationId: Conversation identifier
    ///   - genParams: Generate parameters for new session creation
    /// - Returns: Tuple of (ChatSession, isHit: Bool, processedMessageCount: Int)
    func acquire(
        from modelContainer: MLXLMCommon.ModelContainer,
        modelId: String,
        conversationId: String,
        genParams: MLXLMCommon.GenerateParameters
    ) -> (session: ChatSession, isHit: Bool, processedMessageCount: Int) {
        // 1. Expire stale sessions
        evictExpired()

        // 2. Build pool key
        let key = poolKey(modelId: modelId, conversationId: conversationId)

        // 3. Try hit
        if let pooled = pool[key] {
            pool[key] = nil
            hitCount += 1
            totalAcquireAttempts += 1
            logHitRateIfNeeded()
            logger.debug("Session pool HIT: \(key)")
            return (session: pooled.session, isHit: true, processedMessageCount: pooled.messageCount)
        }

        // 4. Miss — create fresh session
        let freshSession = ChatSession(
            modelContainer,
            generateParameters: genParams
        )
        missCount += 1
        totalAcquireAttempts += 1
        logHitRateIfNeeded()
        logger.debug("Session pool MISS: \(key)")
        return (session: freshSession, isHit: false, processedMessageCount: 0)
    }

    /// Return a session back to the pool after inference completes.
    ///
    /// - Parameters:
    ///   - session: The session to pool (must not be nil if pooled)
    ///   - modelId: Model identifier for re-keying
    ///   - conversationId: Conversation identifier for re-keying
    ///   - processedMessageCount: Total messages now baked into the KV cache
    ///     (session's prior count + delta messages sent this turn)
    func release(
        session: ChatSession,
        modelId: String,
        conversationId: String,
        processedMessageCount: Int
    ) {
        let key = poolKey(modelId: modelId, conversationId: conversationId)

        pool[key] = PooledChatSession(
            session: session,
            lastAccessedAt: ContinuousClock.now,
            messageCount: processedMessageCount
        )

        // LRU eviction if pool exceeds max
        if pool.count > config.maxSessions {
            evictLRU()
        }
    }

    // MARK: - Eviction

    private func evictExpired() {
        let now = ContinuousClock.now
        let ttl = Duration.seconds(config.sessionTTLSeconds)
        let before = pool.count
        let keysToRemove: [String] = pool.compactMap { key, entry in
            let expired = now.duration(from: entry.lastAccessedAt) >= ttl
            if expired {
                logger.debug("Evicted expired session: \(key)")
            }
            return expired ? key : nil
        }
        for key in keysToRemove {
            pool.removeValue(forKey: key)
        }
        let removed = before - pool.count
        if removed > 0 {
            logger.info("Expired \(removed) session(s) from pool (\(pool.count) remain)")
        }
    }

    private func evictLRU() {
        guard let oldestKey = pool.min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt })?.key else {
            return
        }
        pool.removeValue(forKey: oldestKey)
        logger.info("LRU evicted: \(oldestKey) (pool: \(pool.count))")
    }

    // MARK: - Inspection

    /// Current pool size
    var pooledCount: Int { pool.count }

    /// Pool size and hit-rate snapshot for metrics
    func stats() -> (count: Int, hitRate: Double) {
        let total = hitCount + missCount
        let rate = total > 0 ? Double(hitCount) / Double(total) * 100.0 : 0.0
        return (count: pool.count, hitRate: rate)
    }

    /// Force-clear the pool (e.g. during shutdown or model unload)
    func clear() {
        let count = pool.count
        pool.removeAll()
        hitCount = 0
        missCount = 0
        totalAcquireAttempts = 0
        logger.info("Session pool cleared (\(count) sessions evicted)")
    }

    /// Clear only sessions for a specific model (during model unload)
    func clear(modelId: String) {
        let keysToRemove: [String] = pool.compactMap { key, _ in
            key.hasPrefix("\(modelId):") ? key : nil
        }
        for key in keysToRemove {
            pool.removeValue(forKey: key)
        }
    }

    // MARK: - Helpers

    private func poolKey(modelId: String, conversationId convId: String) -> String {
        "\(modelId):\(convId)"
    }

    private func logHitRateIfNeeded() {
        guard totalAcquireAttempts % config.metricsLogInterval == 0,
              totalAcquireAttempts > 0 else { return }
        let total = hitCount + missCount
        let rate = total > 0 ? Double(hitCount) / Double(total) * 100.0 : 0.0
        logger.info(
            "Session pool stats after \(total) acquires: \(pool.count) pooled, hit rate \(String(format: "%.1f%%", rate))",
        )
    }
}

#endif // mlx
