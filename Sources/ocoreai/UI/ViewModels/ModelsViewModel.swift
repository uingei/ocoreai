// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelID — lightweight model identity for EnginePool listing.
///
/// Used by ModelManager and ModelView. The former ModelsState class
/// has been removed (ModelManager provides the same functionality).

import Foundation

/// Simple lightweight model info from EnginePool.
struct ModelID: Identifiable, Hashable {
	let id: String
	let maxContext: Int
	let vocabSize: Int
	let tokenizer: String
	let isVlm: Bool
	var paramsCustomized: Bool = false /// Whether this model has non-default sampling params

	init(id: String, maxContext: Int = 0, vocabSize: Int = 0, tokenizer: String = "", isVlm: Bool = false, paramsCustomized: Bool = false) {
		self.id = id
		self.maxContext = maxContext
		self.vocabSize = vocabSize
		self.tokenizer = tokenizer
		self.isVlm = isVlm
		self.paramsCustomized = paramsCustomized
	}

	static func fromListModels(_ entry: [String: String]) -> ModelID {
		ModelID(
			id: entry["id"] ?? "unknown",
			maxContext: Int(entry["max_context_length"] ?? "0") ?? 0,
			vocabSize: Int(entry["vocab_size"] ?? "0") ?? 0,
			tokenizer: entry["tokenizer"] ?? "",
			isVlm: (entry["specialized"] ?? "false") == "true",
		)
	}

	/// Human-readable context window string (e.g. "8K", "128K")
	var contextString: String {
		guard maxContext > 0 else { return "" }
		if maxContext >= 1000 {
			return "\(maxContext / 1000)K"
		}
		return "\(maxContext)"
	}

	/// Human-readable vocab size string (e.g. "32K", "128K")
	var vocabString: String {
		guard vocabSize > 0 else { return "" }
		if vocabSize >= 1000 {
			return "\(vocabSize / 1000)K"
		}
		return "\(vocabSize)"
	}
}
