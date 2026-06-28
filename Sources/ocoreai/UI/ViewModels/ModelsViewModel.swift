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
	let tokenizer: String
	var paramsCustomized: Bool = false /// Whether this model has non-default sampling params

	init(id: String, maxContext: Int = 0, tokenizer: String = "", paramsCustomized: Bool = false) {
		self.id = id
		self.maxContext = maxContext
		self.tokenizer = tokenizer
		self.paramsCustomized = paramsCustomized
	}

	static func fromListModels(_ entry: [String: String]) -> ModelID {
		ModelID(
			id: entry["id"] ?? "unknown",
			maxContext: Int(entry["max_context_length"] ?? "0") ?? 0,
			tokenizer: entry["tokenizer"] ?? "",
		)
	}
}
