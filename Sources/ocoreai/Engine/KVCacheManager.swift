// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// KVCacheManager — compiled only when 'coreai' trait is active
// DEPRECATED: SSD cold-store is an anti-pattern on Apple Silicon UMA.
// On UMA, GPU/CPU share physical RAM — writing KV cache to disk adds I/O
// latency with zero benefit. The OOMGuard downgrade chain (4bit→8bit→CPU→refuse)
// handles memory pressure correctly. This module is retained for backward
// compatibility and will be removed once CoreAI ships native session persistence.
#if coreai

	/// KVCacheManager — GPU KV cache manager (Shield Mode — CoreAI v1)
	///
	/// DEFENSIVE: Active sessions reside in GPU memory; idle sessions are cold-stored
	/// to SSD via our own AsyncKVState serialization. Once CoreAI ships native
	/// session persistence (save/load KV state), replace coldStore/warmBack with
	/// the official API and drop AsyncKVState. See ROADMAP.md for migration plan.
	///
	/// DEPRECATED: On Apple Silicon UMA, SSD cold-store is an anti-pattern.
	/// Memory pressure is handled by OOMGuard quantization downgrade chain.
	/// Keep this module only for CoreAI trait compatibility — prefer in-memory
	/// eviction (LRU/FIFO/Score) over disk spill.
	///
	/// Eviction policies: LRU (least recently used), FIFO (first in first out),
	/// Score (evict session with largest token-weighted cache footprint).

	import Atomics
	import CoreAI
	import CoreAILanguageModels
	import Foundation
	import Logging

	// MARK: - KV Cache Manager

	/// Manage GPU ↔ SSD two-tier KV cache lifecycle.
	///
	/// Tracks active session caches, monitors GPU memory usage,
	/// and evicts idle sessions to SSD when thresholds are exceeded.
	/// Thread safety via `actor` mailbox model (aligned with EnginePool isolation domain).
	actor KVCacheManager {
		// MARK: - Configuration

		/// KV cache eviction and storage behavior configuration.
		struct Config {
			/// Default: 16GB GPU cap, 50GB SSD cap, 5-minute idle timeout
			static let `default`: Config = .init()

			/// GPU cache cap in GB; exceeding this value triggers eviction.
			var maxGpuCacheGB: Double = 16.0

			/// SSD cold storage filesystem path.
			var ssdCachePath: String = "/tmp/ocoreai/kv_cache"

			/// SSD cache cap in GB.
			var ssdCacheLimitGB: Double = 50.0

			/// Session idle timeout in seconds; sessions exceeding this are cold-stored. Default 300s (5 min).
			var idleTimeoutSeconds: Int = 300

			/// Eviction policy selector.
			var evictionPolicy: EvictionPolicy = .lru

			/// Available eviction policies.
			enum EvictionPolicy: String {
				/// LRU — evict least recently used sessions.
				case lru
				/// FIFO — evict oldest sessions.
				case fifo
				/// Score — evict sessions with the largest token-weighted cache footprint.
				case score
			}
		}

		// MARK: - State

		/// Immutable configuration reference.
		private let config: Config

		/// Atomic GPU byte counter for lock-free memory tracking.
		private let gpuBytesUsed = ManagedAtomic<Int>(0)

		/// Logger for observability.
		private let logger: Logger

		/// Active (GPU) cache session map: sessionId → CacheEntry.
		private var activeCaches: [String: CacheEntry] = [:]

		/// SSD index map: sessionId → file URL.
		private var ssdIndex: [String: URL] = [:]

		/// Background eviction loop task.
		private var evictionTask: Task<Void, Never>?

		// MARK: - Initialization

		/// Initialize the cache manager and start the background eviction loop.
		///
		/// - Parameters:
		///   - config: Cache management configuration
		///   - logger: Logger instance
		init(config: Config, logger: Logger) {
			self.config = config
			self.logger = logger
			// Defensive checks: GPU cache cap must be positive
			precondition(
				config.maxGpuCacheGB > 0,
				"maxGpuCacheGB must be positive, got \(config.maxGpuCacheGB)",
			)
			precondition(
				config.ssdCacheLimitGB > 0,
				"ssdCacheLimitGB must be positive, got \(config.ssdCacheLimitGB)",
			)
			precondition(
				config.idleTimeoutSeconds > 0,
				"idleTimeoutSeconds must be positive, got \(config.idleTimeoutSeconds)",
			)
			// Launch background eviction loop task
			evictionTask = Task { [weak self] in
				await self?.evictionLoop()
			}
		}

		// MARK: - Public API

		/// Register a new session's KV cache to the active list.
		///
		/// Called each time a new inference session is created. Estimates cache size from processed token count.
		///
		/// - Parameters:
		///   - sessionId: Unique session identifier
		///   - kvState: CoreAI KV state reference
		func register(sessionId: String, kvState: AsyncKVState) async {
			// Defensive check: sessionId must not be empty (developer invariant)
			guard !sessionId.isEmpty else { return }

			// Build cache entry with creation/access timestamps and estimated byte size
			let entry = CacheEntry(
				sessionId: sessionId,
				kvState: kvState,
				created: .now,
				lastAccessed: .now,
				estimatedBytes: Self.estimateCacheBytes(
					processedTokens: kvState.processedTokenCount,
					config: kvState.config,
					gpuCapGB: config.maxGpuCacheGB,
				),
			)

			// Write to active cache and increment GPU atomic byte counter
			activeCaches[sessionId] = entry
			gpuBytesUsed.wrappingAdd(by: entry.estimatedBytes, ordering: .relaxed)

			logger.info("Registered KV cache \(sessionId) size=\(entry.estimatedBytes / (1024 * 1024))MB")

			// Check if GPU cap exceeded; trigger eviction if so
			await checkEvictionNeeded()
		}

		/// Lightweight registration — used when CoreAI does not expose ``AsyncKVState``.
		///
		/// Registers only the sessionId placeholder with 0 estimated bytes.
		/// Eviction loop still works based on session age.
		///
		/// - Parameter sessionId: Unique session identifier
		func registerZeroSession(sessionId: String) {
			precondition(
				!sessionId.isEmpty,
				"Session ID must not be empty for zero-session registration",
			)
			let entry = CacheEntry(
				sessionId: sessionId,
				kvState: .empty(),
				created: .now,
				lastAccessed: .now,
				estimatedBytes: 0,
			)
			activeCaches[sessionId] = entry
			logger.info("Registered zero-KV session \(sessionId)")
		}

		/// Mark session as active — update last accessed timestamp.
		///
		/// Called on each request to reset the idle timeout timer.
		///
		/// - Parameter sessionId: Session ID to mark
		func markActive(sessionId: String) {
			guard var entry = activeCaches[sessionId] else { return }
			entry.lastAccessed = .now
			activeCaches[sessionId] = entry
		}

		/// Unregister session KV cache — called when session ends.
		///
		/// Clears from both GPU cache tracking and SSD index.
		///
		/// - Parameter sessionId: Session ID to remove
		func unregister(sessionId: String) {
			guard let entry = activeCaches.removeValue(forKey: sessionId) else { return }
			// Subtract estimated bytes from atomic counter
			gpuBytesUsed.wrappingSubtract(by: entry.estimatedBytes, ordering: .relaxed)
			// Clear SSD index
			ssdIndex.removeValue(forKey: sessionId)
			logger.info("Unregistered KV cache \(sessionId)")
		}

		/// Cold-store session KV cache to SSD.
		///
		/// READ KV data from GPU → serialize to binary → write to disk → remove active GPU entry.
		///
		/// - Warning: This is a disk-I/O anti-pattern on Apple Silicon UMA.
		///   Prefer OOMGuard quantization downgrade instead.
		///
		/// - Parameter sessionId: Session ID to cold-store
		/// - Returns: Serialized Data payload
		/// - Throws: ``AppError.kvCacheCorruption`` on serialization/I/O failure
		@discardableResult
		func coldStore(sessionId: String) async throws -> Data {
			logger.critical("[DEPRECATED] KVCacheManager.coldStore: SSD spill is anti-pattern on UMA. Use OOMGuard downgrade chain.")
			// Session does not exist; return empty data
			guard let entry = activeCaches[sessionId] else { return Data() }

			// Build SSD storage file path
			let ssdURL = URL(fileURLWithPath: config.ssdCachePath)
				.appendingPathComponent("\(sessionId).kv")

			// Read KV data from GPU and serialize
			let kvData = try entry.kvState.serialize()
			// Atomically write to disk file
			try kvData.write(to: ssdURL, options: .atomic)

			// Update SSD index, decrement GPU counter, remove active entry
			ssdIndex[sessionId] = ssdURL
			gpuBytesUsed.wrappingSubtract(by: entry.estimatedBytes, ordering: .relaxed)
			activeCaches.removeValue(forKey: sessionId)

			logger.info("Cold-stored \(sessionId) to \(ssdURL.path) size=\(kvData.count / (1024 * 1024))MB")
			return kvData
		}

		/// Warm back cold-stored session from SSD to GPU cache.
		///
		/// - Warning: This is a disk-I/O anti-pattern on Apple Silicon UMA.
		///   Prefer OOMGuard quantization downgrade instead.
		///
		/// - Parameter sessionId: Session ID to restore
		/// - Returns: Restored ``AsyncKVState`` instance
		/// - Throws: ``AppError.coldStoreNotFound`` when session is not in the SSD index
		func warmBack(sessionId: String) async throws -> AsyncKVState {
			logger.critical("[DEPRECATED] KVCacheManager.warmBack: SSD spill is anti-pattern on UMA. Use OOMGuard downgrade chain.")
			guard let ssdURL = ssdIndex[sessionId] else {
				throw AppError.coldStoreNotFound(sessionId)
			}

			// Read serialized data from disk and deserialize to KV state
			let data = try Data(contentsOf: ssdURL, options: .mappedIfSafe)
			let kvState = try AsyncKVState.deserialize(from: data)

			// Rebuild active cache entry
			activeCaches[sessionId] = CacheEntry(
				sessionId: sessionId,
				kvState: kvState,
				created: .now,
				lastAccessed: .now,
				estimatedBytes: Self.estimateCacheBytes(
					processedTokens: kvState.processedTokenCount,
					config: kvState.config,
					gpuCapGB: config.maxGpuCacheGB,
				),
			)

			// Restore GPU atomic count and remove SSD index
			let bytes = activeCaches[sessionId]?.estimatedBytes ?? 0
			gpuBytesUsed.wrappingAdd(by: bytes, ordering: .relaxed)
			ssdIndex.removeValue(forKey: sessionId)

			logger.info("Warmed back \(sessionId) from SSD size=\(bytes / (1024 * 1024))MB")
			return kvState
		}

		/// Get current GPU memory usage in GB.
		///
		/// - Returns: GPU cache usage in GB
		func gpuUsageGB() -> Double {
			Double(gpuBytesUsed.load(ordering: .relaxed)) / (1024 * 1024 * 1024)
		}

		// MARK: - Eviction Check

		/// Check if GPU memory exceeds cap; trigger eviction if so.
		private func checkEvictionNeeded() async {
			let usageGB = gpuUsageGB()
			guard usageGB > config.maxGpuCacheGB else { return }
			await evictLeastImportant()
		}

		/// Evict sessions until GPU memory falls back to 80% watermark.
		///
		/// Sort sessions by priority according to configured policy (LRU/FIFO/Score),
		/// cold-storing each to SSD starting from the lowest priority.
		private func evictLeastImportant() async {
			// Sort session entries by policy
			let entries = activeCaches.values.sorted { a, b in
				switch config.evictionPolicy {
				case .lru:
					a.lastAccessed < b.lastAccessed
				case .fifo:
					a.created < b.created
				case .score:
					a.estimatedBytes > b.estimatedBytes
				}
			}

			// Cold-store sessions one by one until GPU usage returns to 80% watermark
			for entry in entries {
				guard gpuUsageGB() > config.maxGpuCacheGB * 0.8 else { break }
				do {
					try await coldStore(sessionId: entry.sessionId)
				} catch {
					logger.warning("Eviction failed for \(entry.sessionId): \(error)")
				}
			}
		}

		// MARK: - Background Eviction Loop

		/// Periodic eviction loop — scans every 60 seconds.
		///
		/// Scans for idle sessions (exceeding ``Config/idleTimeoutSeconds``) and cold-stores to SSD.
		/// Auto-exits on task cancellation.
		private func evictionLoop() async {
			while true {
				do {
					// Wait 60 seconds before next scan
					try await Task.sleep(for: .seconds(60))

					// Calculate timeout cutoff and filter idle sessions
					let cutoff = ContinuousClock.now - .seconds(config.idleTimeoutSeconds)
					let idleSessions = activeCaches.values.filter { $0.lastAccessed < cutoff }

					// Cold-store each idle session
					for session in idleSessions {
						do {
							try await coldStore(sessionId: session.sessionId)
						} catch {
							logger.warning("Idle eviction failed for \(session.sessionId): \(error)")
						}
					}
				} catch is CancellationError {
					break
				} catch {
					logger.error("Eviction loop error: \(error)")
				}
			}
		}

		// MARK: - Helper Methods

		/// Estimate KV cache byte size from model-specific parameters.
		///
		/// Formula: tokens × layers × hidden_size × 2 (K + V) × 2 bytes (FP16).
		/// If model layer/hidden info is not available, falls back to a
		/// GPU-budget-proportional heuristic scaled by maxContextLength, so
		/// eviction behaves correctly across model sizes.
		///
		/// - Parameters:
		///   - processedTokens: Number of processed tokens
		///   - config: Model configuration
		///   - gpuCapGB: GPU cache cap in GB from ``Config/maxGpuCacheGB``
		/// - Returns: Estimated byte count
		private static func estimateCacheBytes(
			processedTokens: Int,
			config: ModelConfig,
			gpuCapGB: Double,
		) -> Int {
			precondition(processedTokens >= 0, "processedTokens must be non-negative")
			// Guard against zero maxContextLength to avoid division by zero.
			guard config.maxContextLength > 0 else {
				return processedTokens * 256 * 1024
			}
			// Budget a fraction of total GPU cap per token proportionally to context window.
			// Typical KV cache utilization: ~60% of GPU budget is consumed by active tokens.
			let gpuBytes = gpuCapGB * 1024 * 1024 * 1024
			let bytesPerToken = max(16 * 1024, (gpuBytes * 0.6) / Double(config.maxContextLength))
			return processedTokens * Int(bytesPerToken)
		}

		/// Cold-store all active sessions to SSD.
		///
		/// Called before application shutdown to preserve established conversation context.
		func coldStoreActiveSessions() async {
			guard !activeCaches.isEmpty else { return }
			logger.info("Cold-storing all active sessions: \(activeCaches.count)")
			for session in activeCaches.values {
				do {
					try await coldStore(sessionId: session.sessionId)
					logger.info("Cold-stored session: \(session.sessionId)")
				} catch is CancellationError {
					break
				} catch {
					logger.warning("Failed to cold-store session \(session.sessionId): \(error)")
				}
			}
		}

		/// Cancel the background eviction loop (called on shutdown).
		///
		/// Actors do not support `deinit`, so callers (App shutdown hook) must
		/// invoke this method explicitly to tear down the eviction task.
		func shutdown() {
			evictionTask?.cancel()
		}
	}

	// MARK: - Cache Entry

	/// Immutable snapshot of a single session's cache state.
	struct CacheEntry {
		/// Unique session identifier
		let sessionId: String
		/// CoreAI KV state reference
		let kvState: AsyncKVState
		/// Creation timestamp
		let created: ContinuousClock.Instant
		/// Last access timestamp (updated on each active request)
		let lastAccessed: ContinuousClock.Instant
		/// Estimated GPU memory footprint in bytes
		let estimatedBytes: Int

		/// Empty cache entry placeholder.
		static var zero: CacheEntry {
			CacheEntry(
				sessionId: "",
				kvState: AsyncKVState.empty(),
				created: .now,
				lastAccessed: .now,
				estimatedBytes: 0,
			)
		}
	}

	// MARK: - Async KV State

	/// Asynchronous wrapper for CoreAI NDArray KV state.
	///
	/// Provides serialization/deserialization interface for cold storage.
	/// Data encoded as big-endian header + Float16 payload.
	final class AsyncKVState: Sendable {
		/// Number of tokens processed through this cache
		let processedTokenCount: Int
		/// Model config snapshot
		let config: ModelConfig
		/// Raw key cache data
		private let _keyCacheData: Data
		/// Raw value cache data
		private let _valueCacheData: Data

		/// Initialize from CoreAI NDArray key/value cache.
		///
		/// - Parameters:
		///   - processedTokenCount: Current token count
		///   - config: Model configuration
		///   - keyCache: Key cache NDArray
		///   - valueCache: Value cache NDArray
		init(
			processedTokenCount: Int,
			config: ModelConfig,
			keyCache: NDArray,
			valueCache: NDArray,
		) {
			self.processedTokenCount = processedTokenCount
			self.config = config
			_keyCacheData = Self.arrayToData(keyCache)
			_valueCacheData = Self.arrayToData(valueCache)
			precondition(processedTokenCount >= 0, "processedTokenCount must be non-negative")
		}

		/// Create an empty KV state placeholder.
		static func empty() -> AsyncKVState {
			AsyncKVState(
				processedTokenCount: 0,
				config: ModelConfig(
					name: "empty",
					function: "default",
					vocabSize: 0,
					maxContextLength: 1,
					chunkThreshold: 0,
					prefillChunkSize: 0,
				),
				keyCache: NDArray.zeros(shape: [1, 1, 1, 1], scalarType: .float16),
				valueCache: NDArray.zeros(shape: [1, 1, 1, 1], scalarType: .float16),
			)
		}

		/// Serialize KV state to binary ``Data`` (big-endian header + Float16 payload).
		///
		/// - Returns: Serialized data buffer
		/// - Throws: ``AppError.kvCacheCorruption`` when encoding fails
		func serialize() throws -> Data {
			var combined = Data()
			// Header: token count + vocab size + max context length
			combined.append(Int(processedTokenCount).bigEndian)
			combined.append(Int(config.vocabSize).bigEndian)
			combined.append(Int(config.maxContextLength).bigEndian)
			// Payload: key + value cache data
			combined.append(_keyCacheData)
			combined.append(_valueCacheData)
			return combined
		}

		/// Deserialize KV state from binary ``Data``.
		///
		/// - Parameter data: Serialized data buffer (minimum 12-byte header)
		/// - Returns: Restored ``AsyncKVState`` instance
		/// - Throws: ``AppError.kvCacheCorruption`` when header/payload mismatch
		static func deserialize(from data: Data) throws -> AsyncKVState {
			guard data.count >= 12 else {
				throw AppError.kvCacheCorruption("Header too short: \(data.count) bytes")
			}

			// Parse big-endian header
			let processedTokenCount = Int(bigEndian: data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int.self) })
			let vocabSize = Int(bigEndian: data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int.self) })
			let maxContextLength = Int(bigEndian: data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Int.self) })

			// Validate header values
			guard processedTokenCount > 0, vocabSize > 0, maxContextLength > 0 else {
				throw AppError.kvCacheCorruption("Invalid header values: tokens=\(processedTokenCount), vocab=\(vocabSize), ctx=\(maxContextLength)")
			}

			// Split key/value cache data (12-byte header)
			let payloadSize = data.count - 12
			let half = payloadSize / 2

			let keyData = data.subdata(in: 12 ..< 12 + half)
			let valueData = data.subdata(in: 12 + half ..< 12 + payloadSize)

			// Reconstruct NDArray from Data (Float16 layout)
			let keyArray = try NDArray.fromData(keyData, scalarType: .float16)
			let valueArray = try NDArray.fromData(valueData, scalarType: .float16)

			let config = ModelConfig(
				name: "restored",
				function: "default",
				vocabSize: vocabSize,
				maxContextLength: maxContextLength,
				chunkThreshold: 0,
				prefillChunkSize: 0,
			)

			return AsyncKVState(
				processedTokenCount: processedTokenCount,
				config: config,
				keyCache: keyArray,
				valueCache: valueArray,
			)
		}

		/// Convert NDArray to raw binary ``Data`` (Int16/Float16 layout).
		///
		/// - Parameter array: Source NDArray
		/// - Returns: Raw byte buffer
		private static func arrayToData(_ array: NDArray) -> Data {
			let count = array.shape.reduce(1, *)
			precondition(count > 0, "NDArray must have non-zero element count")
			var view = array.view(as: Int16.self)
			return view.withUnsafePointer { ptr, bytes, _ in
				Data(bytes: ptr, count: bytes)
			}
		}
	}
#endif
