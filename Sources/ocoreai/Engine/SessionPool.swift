// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// SessionPool.swift — ChatSession pooling for KV cache reuse across turns
//
// Provides per-conversation ChatSession pooling with LRU eviction and TTL-based expiry.
// On-disk KV cache persistence enables session resume across pool evictions.
//
// ### Architecture:
// - **SessionPoolConfig**: Pool configuration (always compiled, trait-agnostic)
// - **MLXSessionPool** (actor): Owns the session pool map, handles eviction,
//   acquire/create, on-disk cache save/restore, and hit-rate metrics.
// - **PooledChatSession** (struct): Metadata wrapper around a ChatSession
//   with last-access timestamp for LRU tracking.
//
// ### Integration:
// - EnginePool delegates to SessionPool via acquire/release
// - When a pooled session is reused, the KV cache (prompt context) is preserved.
// - TTL expiry + LRU cap prevent unbounded memory growth.
// - On eviction, KV cache is persisted to disk via ChatSession.saveCache(to:).
// - On cold pool miss, loadPromptCache(url:) restores from disk if available.

import Foundation
import Logging
import MLXLLM
import MLXLMCommon

// MARK: - Configuration (trait-agnostic)

import CoreGraphics

/// Session pool configuration — per-pool limits and TTL.
struct SessionPoolConfig {
    /// Whether conversation pooling is enabled.
    var enabled: Bool = true

    /// Time-to-live for an idle pooled session (seconds).
    var sessionTTLSeconds: Int = 600

    /// Maximum number of pooled sessions across all models.
    var maxSessions: Int = 16

    /// Log hit/miss metrics every N acquires for observability.
    var metricsLogInterval: Int = 100

    /// When true, KV cache of an evicted session is persisted to disk
    /// via ChatSession.saveCache(to:) so the session can be resumed
    /// later with loadPromptCache(url:) instead of cold-start.
    var persistCache: Bool = true

    /// Maximum total on-disk KV cache size in bytes. When the cache directory
    /// exceeds this budget, oldest cache files are pruned before new ones are saved.
    /// Set to 0 to disable capping (not recommended for long-running services).
    /// Default: 1 GiB (enough for ~8 concurrent 128K-context sessions at ~50MB/session).
    var persistCacheMaxBytes: UInt64 = 1_073_741_824 // 1 GiB

    /// Directory for on-disk KV cache files (nil = auto-derive)
    var cacheDirectory: URL?

    /// Static fallback for cold-miss when caller passes nil processing (defensive;
    /// EngineInference always provides processing so this path is unreachable in practice).
    static let defaultResize: CGSize = .init(width: 1024, height: 1024)

    /// VLM image resize dimensions — fallback for callers that pass nil
    /// for the `processing` parameter.
    var vlmImageResize: CGSize = .init(width: 1024, height: 1024)

    /// Default configuration
    static let `default`: SessionPoolConfig = .init()
}


    // MARK: - Pooled Session Entry

    /// Metadata wrapper around a ChatSession with LRU tracking.
    ///
    /// ``@unchecked Sendable``: this struct lives exclusively inside
    /// ``MLXSessionPool`` actor — all reads and mutations are actor-isolated,
    /// so cross-thread access never occurs. The `ChatSession` itself is not
    /// formally Sendable but is only accessed via the actor.
    ///
    /// KV cache state is managed entirely by ChatSession internally —
    /// we only track access time for TTL/LRU eviction.
    struct PooledChatSession: @unchecked Sendable {
        /// The underlying MLX chat session (holds KV cache)
        let session: ChatSession

        /// Timestamp of last access
        var lastAccessedAt: ContinuousClock.Instant
    }

    // MARK: - Session Pool Actor

    /// Actor-owned pool of ChatSession instances keyed by
    /// (modelId, conversationId). Handles TTL expiry + LRU eviction.
    ///
    /// KV cache persistence is handled by ChatSession itself via
    /// `saveCache(to:)` and `loadPromptCache(url:)`.
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
                "MLXSessionPool initialized: maxSessions=\(config.maxSessions), ttl=\(config.sessionTTLSeconds)s",
            )
        }

        // MARK: - Acquire / Create

        /// Acquire a ChatSession for the given (model, conversation) key.
        ///
        /// If a pooled session exists and is within TTL, it is returned and removed
        /// from the pool (borrow pattern). The caller must release() after inference.
        ///
        /// If no pooled session exists (or it expired), a new session is created.
        ///
        /// - Parameters:
        ///   - instructions: System prompt via ChatSession's `instructions:` parameter
        ///   - processing: VLM resize config. Aligned across all inference paths
        ///     to avoid inconsistent per-image token counts.
        func acquire(
            from modelContainer: MLXLMCommon.ModelContainer,
            modelId: String,
            conversationId: String,
            genParams: MLXLMCommon.GenerateParameters,
            speculativeDecoding: MLXLMCommon.SpeculativeDecodingConfig? = nil,
            instructions: String? = nil,
            processing: MLXLMCommon.UserInput.Processing? = nil,
        ) async -> (pooled: PooledChatSession, isHit: Bool) {
            // 1. Expire stale sessions
            await evictExpired()

            // 2. Build pool key
            let key = poolKey(modelId: modelId, conversationId: conversationId)

            // 3. Try hit
            if let pooled = pool[key] {
                pool[key] = nil
                hitCount += 1
                totalAcquireAttempts += 1
                logHitRateIfNeeded()
                logger.debug("Session pool HIT: \(key)")
                return (pooled, isHit: true)
            }

            // 4. Miss — create fresh session
            let freshSession = ChatSession(
                modelContainer,
                instructions: instructions,
                speculativeDecoding: speculativeDecoding,
                generateParameters: genParams,
                processing: processing ?? .init(resize: config.vlmImageResize),
            )
            let freshPooled = PooledChatSession(
                session: freshSession,
                lastAccessedAt: ContinuousClock.now,
            )
            missCount += 1
            totalAcquireAttempts += 1
            logHitRateIfNeeded()
            logger.debug("Session pool MISS: \(key)")
            return (freshPooled, isHit: false)
        }

        /// Return a session back to the pool after inference completes.
        func release(
            pooled: PooledChatSession,
            modelId: String,
            conversationId: String,
        ) async {
            let key = poolKey(modelId: modelId, conversationId: conversationId)
            // Clear tools + toolDispatch to prevent cross-session tool leakage.
            // Without this, a pooled session reused by a different request could
            // carry over tool specs and dispatch closures from the previous caller.
            pooled.session.tools = nil
            pooled.session.toolDispatch = nil
            pool[key] = pooled

            // LRU eviction if pool exceeds max
            if pool.count > config.maxSessions {
                await evictLRU()
            }
        }

        // MARK: - Eviction

        /// Remove expired sessions based on TTL.
        private func evictExpired() async {
            let now = ContinuousClock.now
            let ttl = Duration.seconds(config.sessionTTLSeconds)
            let before = pool.count
            let keysToRemove: [String] = pool.compactMap { key, entry in
                let expired = entry.lastAccessedAt.duration(to: now) >= ttl
                return expired ? key : nil
            }
            for key in keysToRemove {
                pool.removeValue(forKey: key)
                logger.debug("Evicted expired session: \(key)")
            }
            let removed = before - pool.count
            if removed > 0 {
                logger.info("Expired \(removed) session(s) from pool (\(pool.count) remain)")
            }
        }

        /// Remove the least-recently-used session when pool exceeds max capacity.
        private func evictLRU() async {
            guard let oldestItem = pool.min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt }) else {
                return
            }
            let oldestKey = oldestItem.key
            pool.removeValue(forKey: oldestKey)
            logger.info("LRU evicted: \(oldestKey) (pool: \(pool.count))")
        }

        // MARK: - Inspection

        /// Current pool size
        var pooledCount: Int {
            pool.count
        }

        /// Pool size and hit-rate snapshot for metrics
        func stats() -> (count: Int, hitRate: Double) {
            let total = hitCount + missCount
            let rate = total > 0 ? Double(hitCount) / Double(total) * 100.0 : 0.0
            return (count: pool.count, hitRate: rate)
        }

        /// Force-clear the pool (e.g. during shutdown or model unload)
        /// Does NOT delete on-disk cache files.
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

