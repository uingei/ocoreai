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

import CoreGraphics
import Foundation
import Logging
import MLXLLM
import MLXLMCommon

// MARK: - Configuration (trait-agnostic)

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
    var persistCacheMaxBytes: UInt64 = 1_073_741_824  // 1 GiB

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

// MARK: - Pooled Session Entry

/// Lightweight message identity for prefix match without carrying full text.
/// (role, content truncated to first 64 chars for hash).
struct MessageHistoryKey: Hashable, Sendable {
    let role: String
    /// Hash of the content prefix — enough to detect content changes without storing
    /// full text. Full prefix match relies on (role, content_hash) equality.
    let contentHash: Int
    static func from(_ msg: Chat.Message) -> Self {
        Self(role: msg.role.rawValue, contentHash: "\(msg.content)".hashValue)
    }
}

/// Metadata wrapper around a ChatSession with LRU tracking and message history
/// for prompt prefix-level cache reuse decisions.
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

    /// On-disk cache file URL for this session (nil if never persisted).
    var cacheFileURL: URL?

    /// Rendered message history keys for prefix matching.
    /// Each entry corresponds to a role+content pair that contributed tokens to the KV cache.
    /// On acquire, we compare new messages against this to find the longest common prefix.
    var messageHistory: [MessageHistoryKey] = []
}

/// Result of acquiring a session, with prefix match details.
struct AcquireResult {
    /// The pooled session (or fresh session on miss)
    let pooled: PooledChatSession

    /// Whether a prefixed cache was found (partial or full match).
    /// When false, this is a cold start — caller must pass full history.
    let isHit: Bool

    /// Number of messages that already match the cached prefix.
    /// Caller should only pass messages[divergenceIndex...] to avoid redundant prefill.
    /// - 0: no cached prefix (cold miss)
    /// - < messages.count: partial prefix match (pass suffix)
    /// - == messages.count: full match (only new messages needed, but pool hit means nothing new yet)
    let divergenceIndex: Int
}

// MARK: - Session Pool Actor

/// Actor-owned pool of ChatSession instances keyed by
/// (modelId, conversationId). Handles TTL expiry + LRU eviction + on-disk KV cache.
actor MLXSessionPool {
    // MARK: - State

    private let config: SessionPoolConfig
    private let logger: Logger
    private var pool: [String: PooledChatSession] = [:]

    // On-disk KV cache storage
    private let cacheDirectory: URL

    // Hit-rate metrics
    private var hitCount = 0
    private var missCount = 0
    private var totalAcquireAttempts = 0

    // MARK: - Initialization

    init(config: SessionPoolConfig, logger: Logger, cacheDirectory argCacheDir: URL? = nil) {
        self.config = config
        self.logger = logger

        // Derive cache directory from config or default — cross-platform
        cacheDirectory =
            argCacheDir ?? config.cacheDirectory
            ?? {
                let dir: URL
                if let supportURL = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask,
                ).first?.appendingPathComponent("ocoreai/cache") {
                    dir = supportURL
                } else {
                    dir = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ocoreai/cache")
                }
                return dir.appendingPathComponent("kvcache")
            }()

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true,
        )

        logger.info(
            """
            MLXSessionPool initialized: maxSessions=\(config.maxSessions), \
            ttl=\(config.sessionTTLSeconds)s, persist=\(config.persistCache)
            """
        )
    }

    // MARK: - Acquire / Create

    /// Acquire a ChatSession for the given (model, conversation) key.
    ///
    /// If a pooled session exists and is within TTL, it is returned and removed
    /// from the pool (borrow pattern). The caller must release() after inference.
    ///
    /// If no pooled session exists (or it expired), the pool attempts to restore
    /// from on-disk KV cache. If that fails, a new session is created.
    ///
    /// Prompt prefix match (`prefixMessages`) is checked against the session's
    /// ``PooledChatSession/messageHistory`` to find the longest common message
    /// prefix.  The caller should only ``prefixMessages[divergenceIndex...]``
    /// to ``ChatSession`` — the cached KV context already represents the
    /// matched portion.
    ///
    /// - Note: On cold miss, `prefixMessages` is recorded into the session's
    ///   history so the next turn can benefit from prefix matching.  The caller
    ///   should pass the same messages that go to ``ChatSession``.
    ///
    /// - Parameters:
    ///   - prefixMessages: Rendered messages for this turn, used for prefix matching.
    ///     Pass nil if the caller only needs a session-level hit/miss.
    ///   - instructions: System prompt via ChatSession's `instructions:` parameter
    ///   - processing: VLM resize config. Aligned across all inference paths
    ///     to avoid inconsistent per-image token counts.
    ///   - prefixMessages: Rendered message keys for this turn, used for prefix matching.
    ///     Convert `[Chat.Message]` to `[MessageHistoryKey]` before calling across actor boundary.
    func acquire(
        from modelContainer: MLXLMCommon.ModelContainer,
        modelId: String,
        conversationId: String,
        genParams: MLXLMCommon.GenerateParameters,
        speculativeDecoding: MLXLMCommon.SpeculativeDecodingConfig? = nil,
        instructions: String? = nil,
        processing: MLXLMCommon.UserInput.Processing? = nil,
        prefixMessages: [MessageHistoryKey]? = nil,
    ) async -> AcquireResult {
        // 1. Expire stale sessions
        await evictExpired()

        // 2. Build pool key
        let key = poolKey(modelId: modelId, conversationId: conversationId)

        // 3. Try hit — with prefix match
        if let pooled = pool[key] {
            pool[key] = nil
            hitCount += 1
            totalAcquireAttempts += 1
            logHitRateIfNeeded()

            let divergence: Int
            if let prefix = prefixMessages {
                divergence = longestCommonPrefixCount(
                    history: pooled.messageHistory,
                    prefix: prefix
                )
            } else {
                divergence = 0
            }

            logger.debug(
                "Session pool HIT: \(key), divergence=\(divergence)/\(prefixMessages?.count ?? 0)")
            return AcquireResult(
                pooled: pooled,
                isHit: divergence > 0,
                divergenceIndex: divergence
            )
        }

        // 4. Pool miss — try restore from disk first (fallback path)
        let cacheURL = cacheFileURL(key: key)
        if config.persistCache,
            let restored = restoreCachedSession(
                from: modelContainer,
                cacheURL: cacheURL,
                genParams: genParams,
                speculativeDecoding: speculativeDecoding,
                processing: processing
            )
        {
            let diskPooled = PooledChatSession(
                session: restored,
                lastAccessedAt: ContinuousClock.now,
                cacheFileURL: cacheURL,
                messageHistory: []
            )
            missCount += 1
            totalAcquireAttempts += 1
            logHitRateIfNeeded()
            logger.info("Session RESTORED from disk cache: \(key)")
            // Disk restore loses transcript → no prefix match available
            return AcquireResult(
                pooled: diskPooled,
                isHit: false,
                divergenceIndex: 0
            )
        }

        // 5. Cold miss — create fresh session with instructions + processing
        // components: custom logitProcessorFactory for grammar-constrained decoding.
        // Penalty enforcement is automatic via GenerateParameters.processor().
        let freshSession = ChatSession(
            modelContainer,
            instructions: instructions,
            speculativeDecoding: speculativeDecoding,
            generateParameters: genParams,
            components: .init(),
            processing: processing ?? .init(resize: config.vlmImageResize),
        )
        let cacheFile = cacheFileURL(key: key)
        let freshPooled = PooledChatSession(
            session: freshSession,
            lastAccessedAt: ContinuousClock.now,
            cacheFileURL: cacheFile,
            messageHistory: []
        )
        missCount += 1
        totalAcquireAttempts += 1
        logHitRateIfNeeded()
        logger.debug("Session pool MISS: \(key)")
        return AcquireResult(
            pooled: freshPooled,
            isHit: false,
            divergenceIndex: 0
        )
    }

    /// Return a session back to the pool after inference completes.
    ///
    /// - Parameters:
    ///   - pooled: session to return
    ///   - modelId: model identifier
    ///   - conversationId: conversation identifier
    ///   - assistantMessage: Lightweight key of the assistant response appended to the conversation,
    ///     used to extend the message history for prefix matching on the next turn.
    ///     Convert the assistant `Chat.Message` to `MessageHistoryKey` before calling across actor boundary.
    ///     Pass nil for guided gen / tool paths or when generation was cancelled.
    func release(
        pooled: PooledChatSession,
        modelId: String,
        conversationId: String,
        assistantMessage: MessageHistoryKey? = nil,
    ) async {
        let key = poolKey(modelId: modelId, conversationId: conversationId)
        // Clear tools + toolDispatch + additionalContext to prevent cross-session leakage.
        // Without this, a pooled session reused by a different request could carry over
        // tool specs, dispatch closures, or reasoning context from the previous caller.
        pooled.session.tools = nil
        pooled.session.toolDispatch = nil
        pooled.session.additionalContext = nil
        // synchronize KV cache before returning to pool — ensures any async GPU
        // cache operations from the last stream are flushed. Without this, a
        // reused pooled session could serve stale cache state.
        await pooled.session.synchronize()

        // Extend message history with the assistant response for prefix matching
        // on the next turn. Without the assistant turn, the history would diverge
        // from the KV cache ledger on every round.
        var entryToPool = pooled
        if let assistantMessage {
            entryToPool.messageHistory.append(assistantMessage)
        }

        pool[key] = entryToPool

        // LRU eviction if pool exceeds max
        if pool.count > config.maxSessions {
            await evictLRU()
        }
    }

    // MARK: - Memory Pressure Response

    /// React to system-level memory pressure by aggressively evicting pooled sessions.
    ///
    /// Called from HardwareRouter's pressure callback in EnginePool.
    ///
    /// - Parameters:
    ///   - level: 0-3 pressure level from HardwareRouter.
    ///     Level 2+ (serious) → evict sessions older than aggressiveTTL.
    ///     Level 3 (critical) → evict all sessions immediately.
    ///   - trigger: "thermal" or "memory" pressure source for observability.
    func onMemoryPressure(level: Int, trigger: String) async {
        guard level >= 2 else {
            return  // nominal/fair — no action
        }

        let now = ContinuousClock.now
        let before = pool.count
        let persistFlag = config.persistCache

        if level >= 3 {
            // Critical: flush everything to disk and clear pool
            logger.warning(
                "Critical \(trigger) pressure (level 3) — flushing entire session pool (\(before) sessions)"
            )
            let allEntries = pool.map { ($0.key, $0.value) }
            pool.removeAll()
            for (key, entry) in allEntries {
                if persistFlag {
                    enforceDiskBudget()
                }
                if persistFlag, let cacheURL = entry.cacheFileURL {
                    let cachePath = cacheURL.lastPathComponent
                    let log = self.logger
                    _ = Task.detached(priority: .utility) { [entry, log, cachePath] in
                        do {
                            try await entry.session.saveCache(to: cacheURL)
                            log.debug("Saved KV cache (pressure flush): \(cachePath)")
                        } catch {
                            log.warning(
                                "Failed to save KV cache (pressure): \(error.localizedDescription)")
                        }
                    }
                }
            }
        } else {
            // Serious (level 2): aggressive TTL — evict anything older than 60s
            let aggressiveTTL = Duration.seconds(60)
            let entriesToRemove: [(key: String, entry: PooledChatSession)] = pool.compactMap {
                key, entry in
                let expired = entry.lastAccessedAt.duration(to: now) >= aggressiveTTL
                return expired ? (key, entry) : nil
            }
            logger.warning(
                "Serious \(trigger) pressure (level 2) — aggressive eviction (\(entriesToRemove.count) sessions >60s)"
            )
            for (key, entry) in entriesToRemove {
                if persistFlag {
                    enforceDiskBudget()
                }
                if persistFlag, let cacheURL = entry.cacheFileURL {
                    let cachePath = cacheURL.lastPathComponent
                    let log = self.logger
                    _ = Task.detached(priority: .utility) { [entry, log, cachePath] in
                        do {
                            try await entry.session.saveCache(to: cacheURL)
                            log.debug("Saved KV cache (pressure): \(cachePath)")
                        } catch {
                            log.warning(
                                "Failed to save KV cache (pressure): \(error.localizedDescription)")
                        }
                    }
                }
                pool.removeValue(forKey: key)
            }
        }
        let removed = before - pool.count
        if removed > 0 {
            logger.info("Pressure evicted \(removed) session(s) (\(pool.count) remain)")
        }
    }

    // MARK: - Eviction with on-disk persistence

    /// Remove expired sessions based on TTL, persisting their KV cache to disk before eviction.
    private func evictExpired() async {
        let now = ContinuousClock.now
        let ttl = Duration.seconds(config.sessionTTLSeconds)
        let before = pool.count
        let persistFlag = config.persistCache
        let entriesToRemove: [(key: String, entry: PooledChatSession)] = pool.compactMap {
            key, entry in
            let expired = entry.lastAccessedAt.duration(to: now) >= ttl
            return expired ? (key, entry) : nil
        }

        for (key, entry) in entriesToRemove {
            // Enforce disk budget before persisting to prevent unbounded growth
            if persistFlag {
                enforceDiskBudget()
            }
            // Persist to disk in a detached Task so saveCache (which can be slow
            // for large KV caches) does not block the actor mailbox.
            if persistFlag, let cacheURL = entry.cacheFileURL {
                let cachePath = cacheURL.lastPathComponent
                let log = self.logger
                _ = Task.detached(priority: .utility) { [entry, log, cachePath] in
                    do {
                        try await entry.session.saveCache(to: cacheURL)
                        log.debug("Saved KV cache: \(cachePath)")
                    } catch {
                        log.warning("Failed to save KV cache: \(error.localizedDescription)")
                    }
                }
            }
            logger.debug("Evicted expired session: \(key)")
            pool.removeValue(forKey: key)
        }
        let removed = before - pool.count
        if removed > 0 {
            logger.info("Expired \(removed) session(s) from pool (\(pool.count) remain)")
        }
    }

    /// Remove the least-recently-used session when pool exceeds max capacity,
    /// persisting its KV cache to disk before eviction.
    private func evictLRU() async {
        guard let oldestItem = pool.min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt })
        else {
            return
        }
        let oldestKey = oldestItem.key
        let entry = oldestItem.value
        // Remove from pool first to shrink actor mailbox window
        pool.removeValue(forKey: oldestKey)
        // Enforce disk budget before persisting to prevent unbounded growth
        if config.persistCache {
            enforceDiskBudget()
        }
        // Persist to disk in a detached Task so saveCache (which can be slow
        // for large KV caches) does not block the actor mailbox.
        if config.persistCache, let cacheURL = entry.cacheFileURL {
            let cachePath = cacheURL.lastPathComponent
            let log = self.logger
            _ = Task.detached(priority: .utility) { [entry, log, cachePath] in
                do {
                    try await entry.session.saveCache(to: cacheURL)
                    log.debug("Saved KV cache (LRU): \(cachePath)")
                } catch {
                    log.warning("Failed to save KV cache (LRU): \(error.localizedDescription)")
                }
            }
        }
        logger.info("LRU evicted: \(oldestKey) (pool: \(pool.count))")
    }

    // MARK: - On-disk KV cache I/O

    /// Restore a ChatSession from on-disk KV cache.
    /// Per upstream L319-322: restore from a pre-built cache that already encodes
    /// a system prompt — pass `instructions: nil` to avoid duplicate tokenization.
    ///
    /// Returns true on success, false if disk cache not found or restore failed.
    private func restoreCachedSession(
        from modelContainer: MLXLMCommon.ModelContainer,
        cacheURL: URL,
        genParams: MLXLMCommon.GenerateParameters,
        speculativeDecoding: MLXLMCommon.SpeculativeDecodingConfig?,
        processing: MLXLMCommon.UserInput.Processing?,
    ) -> ChatSession? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return nil
        }
        do {
            // Use loadPromptCacheSnapshot to keep model state alongside KV cache.
            // Upstream 5c1d95a: models like Qwen-VL store continuation anchors in
            // LMOutput.State; without the state key the next turn would continue
            // from position 0 instead of the cached prefix, silently corrupting output.
            let snapshot = try MLXLMCommon.loadPromptCacheSnapshot(url: cacheURL)
            guard !snapshot.cache.isEmpty else { return nil }
            let restoredTokenCount = snapshot.cache.first?.offset ?? 0
            logger.info(
                "Restoring KV cache snapshot: \(cacheURL.lastPathComponent) tokens=\(restoredTokenCount) state=\(snapshot.state != nil)"
            )
            return ChatSession(
                modelContainer,
                instructions: nil,  // snapshot cache already encodes system prompt
                promptCache: snapshot,
                speculativeDecoding: speculativeDecoding,
                generateParameters: genParams,
                components: .init(),
                processing: processing ?? .init(resize: config.vlmImageResize),
            )
        } catch {
            logger.warning(
                "Cache restore failed (\(cacheURL.lastPathComponent)): \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Cache file path for a pool key
    private func cacheFileURL(key: String) -> URL {
        // Sanitize key to avoid URL-unfriendly chars
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cacheDirectory.appendingPathComponent(safeKey + ".mlx")
    }

    // MARK: - Disk Budget

    /// Total size of all on-disk KV cache files (bytes).
    private func diskCacheTotalBytes() -> UInt64 {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: cacheDirectory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
            )
        else {
            return 0
        }
        var total: UInt64 = 0
        for url in urls {
            if let attrs = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) {
                total += UInt64(attrs.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Evict oldest on-disk cache files until total usage is at or below budget.
    /// Used before persisting a new cache to prevent unbounded disk growth.
    private func enforceDiskBudget() {
        let budget = config.persistCacheMaxBytes
        guard budget > 0 else { return }  // 0 = no cap
        let current: UInt64 = diskCacheTotalBytes()
        guard current > budget else { return }  // already under budget

        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: cacheDirectory, includingPropertiesForKeys: [.contentAccessDateKey]
            )
        else {
            return
        }

        // Sort by last access date (oldest first) to evict LRU
        let sorted = urls.sorted {
            let da =
                (try? $0.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate)
                ?? .distantPast
            let db =
                (try? $1.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate)
                ?? .distantPast
            return da < db
        }

        for url in sorted {
            guard diskCacheTotalBytes() > budget else { break }
            do {
                try FileManager.default.removeItem(at: url)
                logger.debug("Pruned cache file to enforce budget: \(url.lastPathComponent)")
            } catch {
                logger.warning("Failed to prune cache file: \(error.localizedDescription)")
            }
        }
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

    /// Compute the longest common prefix between the session's message history
    /// and the incoming prompt messages.
    ///
    /// Returns the number of messages that match at the start of both sequences.
    /// A mismatch at any position means the KV cache represents a different
    /// context and the caller must prefill from that divergence point.
    private func longestCommonPrefixCount(
        history: [MessageHistoryKey],
        prefix: [MessageHistoryKey]
    ) -> Int {
        let minCount = Swift.min(history.count, prefix.count)
        for i in 0 ..< minCount where history[i] != prefix[i] {
            return i
        }
        return minCount
    }

    private func poolKey(modelId: String, conversationId convId: String) -> String {
        "\(modelId):\(convId)"
    }

    private func logHitRateIfNeeded() {
        guard totalAcquireAttempts % config.metricsLogInterval == 0,
            totalAcquireAttempts > 0
        else { return }
        let total = hitCount + missCount
        let rate = total > 0 ? Double(hitCount) / Double(total) * 100.0 : 0.0
        logger.info(
            "Session pool stats after \(total) acquires: \(pool.count) pooled, hit rate \(String(format: "%.1f%%", rate))",
        )
    }
}
