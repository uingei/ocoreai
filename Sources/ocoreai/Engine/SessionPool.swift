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

	/// Directory for on-disk KV cache files (nil = auto-derive)
	var cacheDirectory: URL?

	/// Default configuration
	static let `default`: SessionPoolConfig = .init()
}

#if mlx

	import MLXLLM
	import MLXLMCommon

	// MARK: - Pooled Session Entry

	/// Metadata wrapper around a ChatSession with LRU tracking.
	struct PooledChatSession: @unchecked Sendable {
		/// The underlying MLX chat session (holds KV cache)
		let session: ChatSession

		/// Timestamp of last access
		var lastAccessedAt: ContinuousClock.Instant

		/// Number of messages already baked into this session's KV cache.
		var messageCount: Int

		/// On-disk cache file URL for this session (nil if never persisted).
		var cacheFileURL: URL?
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

		init(config: SessionPoolConfig, logger: Logger, cacheDirectory _: URL? = nil) {
			self.config = config
			self.logger = logger

			// Derive cache directory from config or default — cross-platform
			cacheDirectory = config.cacheDirectory ?? {
				guard let supportURL = FileManager.default.urls(
					for: .applicationSupportDirectory, in: .userDomainMask,
				).first?.appendingPathComponent("ocoreai/cache") else {
					fatalError("[MLXSessionPool] applicationSupportDirectory not available")
				}
				return supportURL.appendingPathComponent("kvcache")
			}()

			// Ensure directory exists
			try? FileManager.default.createDirectory(
				at: cacheDirectory, withIntermediateDirectories: true,
			)

			logger.info(
				"MLXSessionPool initialized: maxSessions=\(config.maxSessions), ttl=\(config.sessionTTLSeconds)s, persist=\(config.persistCache)",
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
		func acquire(
			from modelContainer: MLXLMCommon.ModelContainer,
			modelId: String,
			conversationId: String,
			genParams: MLXLMCommon.GenerateParameters,
		) async -> (pooled: PooledChatSession, isHit: Bool) {
			// 1. Expire stale sessions (with on-disk save)
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

			// 4. Miss — try restore from disk first
			let cacheURL = cacheFileURL(key: key)
			if let (restoredSession, restoredTokenCount) = Self.restoreCachedSession(
				modelContainer, cacheURL: cacheURL, genParams: genParams, logger: logger,
			) {
				// Disk restore gives us a ChatSession with baked-in KV cache.
				// Message count restored from cache metadata — callers can compute delta
				// correctly instead of re-prefilling the entire context.
				let freshPooled = PooledChatSession(
					session: restoredSession,
					lastAccessedAt: ContinuousClock.now,
					messageCount: restoredTokenCount,
					cacheFileURL: cacheURL,
				)
				missCount += 1
				totalAcquireAttempts += 1
				logHitRateIfNeeded()
				logger.info("Session cache RESTORED from disk: \(key) (tokens: \(restoredTokenCount))")
				return (freshPooled, isHit: false)
			}

			// 5. Cold miss — create fresh session
			let freshSession = ChatSession(
				modelContainer,
				generateParameters: genParams,
			)
			let cacheFile = cacheFileURL(key: key)
			let freshPooled = PooledChatSession(
				session: freshSession,
				lastAccessedAt: ContinuousClock.now,
				messageCount: 0,
				cacheFileURL: cacheFile,
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
			processedMessageCount: Int,
		) async {
			let key = poolKey(modelId: modelId, conversationId: conversationId)
			var session = pooled
			session.messageCount = processedMessageCount
			pool[key] = session

			// LRU eviction if pool exceeds max
			if pool.count > config.maxSessions {
				await evictLRU()
			}
		}

		// MARK: - Eviction with on-disk persistence

		private func evictExpired() async {
			let now = ContinuousClock.now
			let ttl = Duration.seconds(config.sessionTTLSeconds)
			let before = pool.count
			let persistFlag = config.persistCache
			let keysToRemove: [(key: String, entry: PooledChatSession)] = pool.compactMap { key, entry in
				let expired = entry.lastAccessedAt.duration(to: now) >= ttl
				return expired ? (key, entry) : nil
			}

			for (key, entry) in keysToRemove {
				if persistFlag, let cacheURL = entry.cacheFileURL {
					let cachePath = cacheURL.lastPathComponent
					do {
						try await entry.session.saveCache(to: cacheURL)
						logger.debug("Saved KV cache: \(cachePath)")
					} catch {
						logger.warning("Failed to save KV cache: \(error.localizedDescription)")
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

		private func evictLRU() async {
			guard let oldestItem = pool.min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt }) else {
				return
			}
			let oldestKey = oldestItem.key
			let entry = oldestItem.value
			// 先从 pool 移��，再做保存——缩短 actor 占用窗口
			pool.removeValue(forKey: oldestKey)
			if config.persistCache, let cacheURL = entry.cacheFileURL {
				let cachePath = cacheURL.lastPathComponent
				do {
					try await entry.session.saveCache(to: cacheURL)
					logger.debug("Saved KV cache (LRU): \(cachePath)")
				} catch {
					logger.warning("Failed to save KV cache (LRU): \(error.localizedDescription)")
				}
			}
			logger.info("LRU evicted: \(oldestKey) (pool: \(pool.count))")
		}

		// MARK: - On-disk KV cache I/O

		/// Restore a ChatSession from on-disk KV cache.
		/// Returns (ChatSession, restoredTokenCount) on success, nil otherwise.
		private static func restoreCachedSession(
			_ modelContainer: MLXLMCommon.ModelContainer,
			cacheURL: URL,
			genParams: MLXLMCommon.GenerateParameters,
			logger: Logger,
		) -> (session: ChatSession, tokenCount: Int)? {
			guard FileManager.default.fileExists(atPath: cacheURL.path) else {
				return nil
			}
			do {
				let (caches, _) = try MLXLMCommon.loadPromptCache(url: cacheURL)
				guard !caches.isEmpty else { return nil }
				// Recover token count from cache offset — accurate record of how many
				// tokens were prefill-ed into this cached KV state.
				let restoredTokenCount = caches.first?.offset ?? 0
				logger.info("Restoring KV cache from: \(cacheURL.lastPathComponent) (tokens: \(restoredTokenCount))")
				let restoredSession = ChatSession(
					modelContainer,
					cache: caches,
					generateParameters: genParams,
				)
				return (restoredSession, restoredTokenCount)
			} catch {
				logger.warning("Cache restore failed (\(cacheURL.lastPathComponent)): \(error.localizedDescription)")
				return nil
			}
		}

		/// Cache file path for a pool key
		private func cacheFileURL(key: String) -> URL {
			// Sanitize key to avoid URL-unfriendly chars
			let safeKey = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
			return cacheDirectory.appendingPathComponent(safeKey + ".mlx")
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

#endif // mlx
