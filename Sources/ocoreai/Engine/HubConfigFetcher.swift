// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HubConfigFetcher.swift — Fetch remote model config.json before download
///
/// HuggingFace: https://huggingface.co/{repo}/resolve/main/config.json
/// ModelScope:  https://www.modelscope.cn/api/v1/models/{repo}/revision/master
///
/// Returns resolved ModelConfig or falls back to safe defaults.

import Foundation
import Logging

/// Lightweight, non-actor helper for fetching remote config.json.
enum HubConfigFetcher {
	/// Fetch config.json from HuggingFace Hub and parse vocab_size + max_context_length.
	///
	/// - Parameters:
	///   - repoId: e.g. "mlx-community/Qwen3.5-4B-OptiQ-4bit"
	///   - logger: For diagnostic output
	/// - Returns: Parsed (vocabSize, maxContextLength) or nil on failure
	static func fetchHuggingFaceConfig(repoId: String, logger: Logger) async -> (vocabSize: Int, maxContextLength: Int)? {
		guard let url = URL(string: "https://huggingface.co/\(repoId)/resolve/main/config.json") else {
			logger.warning("Invalid HF config URL for \(repoId)")
			return nil
		}
		return await fetchConfig(url: url, repoId: repoId, logger: logger)
	}

	/// Fetch config.json from ModelScope Hub and parse vocab_size + max_context_length.
	///
	/// Uses `/api/v1/models/{id}/repo?FilePath=config.json` — same as omlx's
	/// `_fetch_model_config()`, which returns raw JSON directly.
	static func fetchModelScopeConfig(repoId: String, logger: Logger) async -> (vocabSize: Int, maxContextLength: Int)? {
		let encoded = repoId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? repoId
		// omlx reference: _fetch_model_config() uses /repo?FilePath=config.json&Revision=master
		guard let url = URL(string: "https://www.modelscope.cn/api/v1/models/\(encoded)/repo?FilePath=config.json&Revision=master") else {
			logger.warning("Invalid ModelScope config URL for \(repoId)")
			return nil
		}
		return await fetchConfig(url: url, repoId: repoId, logger: logger)
	}

	// MARK: - Internal

	/// Common fetch + parse logic. ModelScope wraps config in a JSON structure, HF returns raw JSON.
	private nonisolated static func fetchConfig(
		url: URL,
		repoId: String,
		logger: Logger,
	) async -> (vocabSize: Int, maxContextLength: Int)? {
		do {
			var request = URLRequest(url: url)
			request.timeoutInterval = 10
			let (data, response) = try await URLSession.shared.data(for: request)

			guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
				logger.warning("Config fetch failed for \(repoId): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
				return nil
			}
			
			guard let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
				logger.warning("Config parse failed for \(repoId)")
				return nil
			}
			
			// Extract vocab_size — try top-level first, then text_config (Qwen3.5 multimodal), then fallback
			var vocabSize: Int? = nil
			if let v = config["vocab_size"] as? Int { vocabSize = v }
			if vocabSize == nil, let v = config["vocab_size"] as? Int64 { vocabSize = Int(v) }
			if vocabSize == nil, let textConfig = config["text_config"] as? [String: Any],
			   let v = textConfig["vocab_size"] as? Int { vocabSize = v }
			if vocabSize == nil, let textConfig = config["text_config"] as? [String: Any],
			   let v = textConfig["vocab_size"] as? Int64 { vocabSize = Int(v) }
			if vocabSize == nil, let textConfig = config["text_config"] as? [String: Any],
			   let v = textConfig["vocab_size"] as? NSNumber { vocabSize = v.intValue }
			let finalVocabSize = vocabSize ?? 151_936

			// Extract max_context_length — try top-level, then text_config, then fallback
			var maxContextLength: Int? = nil
			for key in ["max_context_length", "max_position_embeddings", "n_ctx"] {
				if let v = config[key] as? Int { maxContextLength = v; break }
				if let v = config[key] as? Int64 { maxContextLength = Int(v); break }
				if let v = config[key] as? NSNumber { maxContextLength = v.intValue; break }
			}
			if maxContextLength == nil, let textConfig = config["text_config"] as? [String: Any] {
				for key in ["max_context_length", "max_position_embeddings", "n_ctx"] {
					if let v = textConfig[key] as? Int { maxContextLength = v; break }
					if let v = textConfig[key] as? Int64 { maxContextLength = Int(v); break }
					if let v = textConfig[key] as? NSNumber { maxContextLength = v.intValue; break }
				}
			}
			let finalMaxContextLength = maxContextLength ?? 131_072
			
			logger.info("Remote config for \(repoId): vocab=\(finalVocabSize), ctx=\(finalMaxContextLength)")
			return (finalVocabSize, finalMaxContextLength)
			
		} catch {
			logger.warning("Config fetch error for \(repoId): \(error.localizedDescription)")
			return nil
		}
	}
}
