// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HubConfigFetcher.swift — Fetch remote model config.json with TTL cache
///
/// HuggingFace: https://huggingface.co/{repo}/resolve/main/config.json
/// ModelScope:  https://www.modelscope.cn/api/v1/models/{repo}/revision/master
///
/// TTL: 24h in-memory cache (LRU eviction at 512 entries).
/// Omlx alignment: _config_cache with same TTL/eviction pattern.
///
/// Also provides parameter count estimation from config fields:
///   params ≈ hidden_size * num_hidden_layers * 4 * vocab_size (MoE)
///          ≈ hidden_size * num_hidden_layers * 3 * vocab_size (dense)
/// Rough but good enough for UI display without loading the model.

import Foundation
import Logging

/// Lightweight, non-actor helper for fetching remote config.json.
enum HubConfigFetcher {
	/// Resolve ModelScope base URL from env or default.
	/// Shared with ModelScopeDownloader and ModelScopeSearchClient.
	nonisolated static func modelScopeEndpoint() -> String {
		ProcessInfo.processInfo.environment["MODELSCOPE_ENDPOINT"]
			?? "https://www.modelscope.cn"
	}

	// MARK: - TTL Cache (24h, LRU 512)

	/// Cache entry for parsed config data.
	struct CacheEntry: @unchecked Sendable {
		let vocabSize: Int
		let maxContextLength: Int
		let hiddenSize: Int?
		let numHiddenLayers: Int?
		let numKeyHeadGroups: Int?
		let intermediateSize: Int?
		let ropeScaling: String?
		let fetchedAt: ContinuousClock.Instant
	}

	/// In-memory TTL cache for config lookups.
	private static let _cache = CacheStore<CacheEntry>(ttl: 24 * 3600, capacity: 512)

	/// LRU + TTL store for lightweight cache entries.
	private final class CacheStore<T: Sendable>: @unchecked Sendable {
		private let lock = NSLock()
		private var entries: [String: (value: T, access: ContinuousClock.Instant)] = [:]
		private let ttlDuration: Duration
		private let capacity: Int

		init(ttl: TimeInterval, capacity: Int) {
			self.ttlDuration = Duration.seconds(ttl)
			self.capacity = capacity
		}

		func get(_ key: String) -> T? {
			lock.lock(); defer { lock.unlock() }
			guard let item = entries[key],
			      item.access.duration(to: ContinuousClock.now) < ttlDuration else {
				entries.removeValue(forKey: key)
				return nil
			}
			entries[key] = (value: item.value, access: ContinuousClock.now)
			return item.value
		}

		func set(_ key: String, value: T) {
			lock.lock(); defer { lock.unlock() }
			// Evict stale + oldest if at capacity
			let now = ContinuousClock.now
			if entries.count >= capacity {
				let stale = entries.filter { $0.value.access.duration(to: now) > ttlDuration }
				if stale.isEmpty, let oldest = entries.min(by: { $0.value.access < $1.value.access }) {
					entries.removeValue(forKey: oldest.key)
				} else {
					entries = entries.filter { $0.value.access.duration(to: now) <= ttlDuration }
				}
			}
			entries[key] = (value: value, access: now)
		}
	}
	/// Fetch config.json from HuggingFace Hub and parse vocab_size + max_context_length.
	///
	/// Checks TTL cache before fetching. Cache key includes provider.
	///
	/// - Parameters:
	///   - repoId: e.g. "mlx-community/Qwen3.5-4B-OptiQ-4bit"
	///   - logger: For diagnostic output
	/// - Returns: Parsed (vocabSize, maxContextLength) or nil on failure
	static func fetchHuggingFaceConfig(repoId: String, logger: Logger) async -> (vocabSize: Int, maxContextLength: Int)? {
		let cacheKey = "hf:\(repoId)"
		if let cached = _cache.get(cacheKey) {
			logger.debug("Config cache hit for \(repoId)")
			return (cached.vocabSize, cached.maxContextLength)
		}
		guard let url = URL(string: "https://huggingface.co/\(repoId)/resolve/main/config.json") else {
			logger.warning("Invalid HF config URL for \(repoId)")
			return nil
		}
		return await fetchConfig(url: url, repoId: cacheKey, logger: logger)
	}

	/// Fetch config.json from ModelScope Hub and parse vocab_size + max_context_length.
	///
	/// Uses `/api/v1/models/{id}/repo?FilePath=config.json` — same as omlx's
	/// `_fetch_model_config()`, which returns raw JSON directly.
	/// Endpoint is configurable via MODELSCOPE_ENDPOINT env var.
	/// Checks TTL cache before fetching.
	static func fetchModelScopeConfig(repoId: String, token: String? = nil, logger: Logger) async -> (vocabSize: Int, maxContextLength: Int)? {
		let cacheKey = "ms:\(repoId)"
		if let cached = _cache.get(cacheKey) {
			logger.debug("Config cache hit for \(repoId)")
			return (cached.vocabSize, cached.maxContextLength)
		}
		let encoded = repoId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? repoId
		// ModelScope default revision is "master", not "main".
		// Using "main" returns Code=200 but Files=null → config pre-fetch fails silently.
		let endpoint = modelScopeEndpoint()
		guard let url = URL(string: "\(endpoint)/api/v1/models/\(encoded)/repo?FilePath=config.json&Revision=master") else {
			logger.warning("Invalid ModelScope config URL for \(repoId)")
			return nil
		}
		return await fetchConfig(url: url, repoId: cacheKey, token: token, logger: logger)
	}

	// MARK: - Parameter Count Estimation

	/// Estimate total trainable parameters from a cached config entry.
	///
	/// Uses the standard approximation:
	///   Dense:  2 * d_model * d_feed * n_layers + d_model * vocab_size * 2
	///   MoE:   2 * d_model * d_feed * num_experts * n_layers + d_model * vocab_size * 2
	///
	/// Returns human-readable string (e.g. "7.2B").
	nonisolated static func estimatedParamCount(from entry: CacheEntry) -> String? {
		guard let h = entry.hiddenSize, let l = entry.numHiddenLayers,
		      let i = entry.intermediateSize else { return nil }
		let vocabSize = entry.vocabSize
		// Rough dense param count: 2 * d_model * d_ff * n_layers (attn+ffn)
		// + 2 * d_model * vocab_size (lm_head + embedding)
		// + ropeScaling / expert-based models multiply further — we note ~ for estimation
		var total: Double = Double(h) * Double(i) * 2 * Double(l)
		total += Double(h) * Double(vocabSize) * 2
		return formatParamCount(Int64(total + 0.5))
	}

	/// Format raw parameter count → "7.2B", "110M", "123.4K"
	nonisolated static func formatParamCount(_ count: Int64) -> String {
		let d = Double(count)
		if d >= 1_000_000_000 {
			return String(format: "%.1fB", d / 1_000_000_000)
		}
		if d >= 1_000_000 {
			return String(format: "%.0fM", d / 1_000_000)
		}
		if d >= 1_000 {
			return String(format: "%.1fK", d / 1_000)
		}
		return "\(count)"
	}

	// MARK: - Internal

	/// Common fetch + parse logic. ModelScope wraps config in a JSON structure, HF returns raw JSON.
	private nonisolated static func fetchConfig(
		url: URL,
		repoId: String,
		token: String? = nil,
		logger: Logger,
	) async -> (vocabSize: Int, maxContextLength: Int)? {
		do {
			var request = URLRequest(url: url)
			request.timeoutInterval = 10
			if let token {
				request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
			}
			let (data, response) = try await URLSession.shared.data(for: request)

			guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
				logger.warning("Config fetch failed for \(repoId): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
				return nil
			}

			guard let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
				logger.warning("Config parse failed for \(repoId)")
				return nil
			}

			// Helper: resolve numeric field from config or text_config
			func resolveInt(key: String) -> Int? {
				// Try top-level
				if let v = config[key] as? Int { return v }
				if let v = config[key] as? Int64 { return Int(v) }
				if let v = config[key] as? NSNumber { return v.intValue }
				// Try text_config (Qwen3.5 multimodal)
				if let tc = config["text_config"] as? [String: Any] {
					if let v = tc[key] as? Int { return v }
					if let v = tc[key] as? Int64 { return Int(v) }
					if let v = tc[key] as? NSNumber { return v.intValue }
				}
				return nil
			}

			let vocabSize = resolveInt(key: "vocab_size") ?? 151_936
			let maxContextLength = resolveInt(key: "max_context_length")
				?? resolveInt(key: "max_position_embeddings")
				?? resolveInt(key: "n_ctx") ?? 131_072
			let hiddenSize = resolveInt(key: "hidden_size") ?? resolveInt(key: "d_model")
			let numHiddenLayers = resolveInt(key: "num_hidden_layers") ?? resolveInt(key: "n_layer")
			let numKeyHeadGroups = resolveInt(key: "num_key_value_heads")
			let intermediateSize = resolveInt(key: "intermediate_size") ?? resolveInt(key: "d_ff")
			let ropeScaling = config["rope_scaling"] as? String

			// Cache the full entry
			let entry = CacheEntry(
				vocabSize: vocabSize,
				maxContextLength: maxContextLength,
				hiddenSize: hiddenSize,
				numHiddenLayers: numHiddenLayers,
				numKeyHeadGroups: numKeyHeadGroups,
				intermediateSize: intermediateSize,
				ropeScaling: ropeScaling,
				fetchedAt: ContinuousClock.now,
			)
			_cache.set(repoId, value: entry)

			// Log with param estimate if available
			if let est = estimatedParamCount(from: entry) {
				logger.info("Remote config for \(repoId): vocab=\(vocabSize), ctx=\(maxContextLength), ~\(est) params")
			} else {
				logger.info("Remote config for \(repoId): vocab=\(vocabSize), ctx=\(maxContextLength)")
			}
			return (vocabSize, maxContextLength)

		} catch {
			logger.warning("Config fetch error for \(repoId): \(error.localizedDescription)")
			return nil
		}
	}
}
