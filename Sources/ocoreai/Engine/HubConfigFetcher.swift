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
	/// - Parameters:
	///   - repoId: e.g. "Qwen/Qwen2.5-7B-Instruct"
	///   - logger: For diagnostic output
	/// - Returns: Parsed (vocabSize, maxContextLength) or nil on failure
	static func fetchModelScopeConfig(repoId: String, logger: Logger) async -> (vocabSize: Int, maxContextLength: Int)? {
		let encoded = repoId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? repoId
		guard let url = URL(string: "https://www.modelscope.cn/api/v1/models/\(encoded)/files?filename=config.json") else {
			logger.warning("Invalid ModelScope config URL for \(repoId)")
			return nil
		}
		return await fetchConfig(url: url, repoId: repoId, logger: logger, isModelScope: true)
	}

	// MARK: - Internal

	/// Common fetch + parse logic. ModelScope wraps config in a JSON structure, HF returns raw JSON.
	private nonisolated static func fetchConfig(
		url: URL,
		repoId: String,
		logger: Logger,
		isModelScope: Bool = false,
	) async -> (vocabSize: Int, maxContextLength: Int)? {
		do {
			var request = URLRequest(url: url)
			request.timeoutInterval = 10
			let (data, response) = try await URLSession.shared.data(for: request)
			
			guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
				logger.warning("Config fetch failed for \(repoId): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
				return nil
			}
			
			// ModelScope API returns a wrapper object; HF returns raw config.json
			var configData = data
			if isModelScope {
				if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
				   let files = json["files"] as? [[String: Any]],
				   let firstFile = files.first,
				   let content = firstFile["content"] as? String {
					// ModelScope returns base64-encoded content
					if let decoded = Data(base64Encoded: content) {
						configData = decoded
					}
				}
			}
			
			guard let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
				logger.warning("Config parse failed for \(repoId)")
				return nil
			}
			
			// Extract vocab_size — try Int, then Int64, fallback
			var vocabSize = config["vocab_size"] as? Int ?? 151_936
			if vocabSize == 151_936 {
				if let big = config["vocab_size"] as? Int64 {
					vocabSize = Int(big)
				}
			}

			// Extract max_context_length — try multiple key names, fallback
			var maxContextLength = config["max_context_length"] as? Int
				?? config["max_position_embeddings"] as? Int
				?? config["n_ctx"] as? Int
				?? 131_072
			if maxContextLength == 131_072 {
				if let big = config["max_context_length"] as? Int64 {
					maxContextLength = Int(big)
				} else if let big = config["max_position_embeddings"] as? Int64 {
					maxContextLength = Int(big)
				}
			}
			
			logger.info("Remote config for \(repoId): vocab=\(vocabSize), ctx=\(maxContextLength)")
			return (vocabSize, maxContextLength)
			
		} catch {
			logger.warning("Config fetch error for \(repoId): \(error.localizedDescription)")
			return nil
		}
	}
}
