// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelMemoryInfo.swift — Extended model metadata with memory footprint tracking
///
/// Extends ModelID with GPU memory usage, parameter count format,
/// quantization info, and VLM-specific metadata.

import Foundation

/// Extended model info with memory footprint for ModelManager.
struct ModelMemoryInfo: Identifiable, Hashable, Sendable {
	let id: String
	let maxContext: Int
	let vocabSize: Int
	let tokenizer: String
	let isVlm: Bool
	var paramsCustomized: Bool = false
	
	// MARK: - Memory footprint
	
	/// Approximate loaded memory in bytes (GPU + KV cache overhead)
	var memoryBytes: UInt64 = 0
	
	/// Estimated parameter count (from model ID heuristics)
	var paramCountString: String = ""
	
	/// Quantization info (e.g. "4-bit", "bf16", "8-bit")
	var quantization: String = ""
	
	// MARK: - VLM metadata
	
	/// Supported modalities for VLM models
	var modalities: [String] = []
	
	// MARK: - Derived
	
	/// Human-readable memory string (e.g. "4.2 GB")
	var memoryString: String {
		guard memoryBytes > 0 else { return "" }
		let gb = Double(memoryBytes) / 1_073_741_824
		return String(format: "%.1f GB", gb)
	}
	
	/// Human-readable context window string
	var contextString: String {
		guard maxContext > 0 else { return "" }
		if maxContext >= 1000 {
			return "\(maxContext / 1000)K"
		}
		return "\(maxContext)"
	}
	
	/// Combined label for UI display
	var displayLabel: String {
		var label = id
		if !contextString.isEmpty {
			label += " (\(contextString))"
		}
		if isVlm {
			label += " 🖼 VLM"
		}
		if !memoryString.isEmpty {
			label += " — \(memoryString)"
		}
		return label
	}
	
	/// Initialize from plain ModelID
	static func fromModelID(_ model: ModelID) -> ModelMemoryInfo {
		ModelMemoryInfo(
			id: model.id,
			maxContext: model.maxContext,
			vocabSize: model.vocabSize,
			tokenizer: model.tokenizer,
			isVlm: model.isVlm,
			paramsCustomized: model.paramsCustomized
		)
	}
	
	/// Initialize from EnginePool list entry
	static func fromListModels(_ entry: [String: String]) -> ModelMemoryInfo {
		ModelMemoryInfo(
			id: entry["id"] ?? "unknown",
			maxContext: Int(entry["max_context_length"] ?? "0") ?? 0,
			vocabSize: Int(entry["vocab_size"] ?? "0") ?? 0,
			tokenizer: entry["tokenizer"] ?? "",
			isVlm: (entry["specialized"] ?? "false") == "true",
			paramsCustomized: (entry["params_customized"] ?? "false") == "true"
		)
	}
	
	/// Infer quantization and param count from model ID string.
	/// Case-insensitive, specific patterns matched first to avoid short patterns
	/// like "7b" matching "70b" or "17b".
	mutating func inferMetadata() {
		let lower = self.id.lowercased()

		// Quantization detection — case-insensitive
		if lower.contains("4bit") || lower.contains("4-bit") {
			quantization = "4-bit"
		} else if lower.contains("8bit") || lower.contains("8-bit") {
			quantization = "8-bit"
		} else if lower.contains("bf16") {
			quantization = "bf16"
		} else if lower.contains("q4f16") {
			quantization = "q4f16"
		}

		// Param count rough estimate from model name
		// Sorted longest-first so "70b" matches before "7b"
		let paramMap: [(String, String)] = [
			("70b", "~70B"),
			("65b", "~65B"),
			("32b", "~32B"),
			("30b", "~30B"),
			("28b", "~28B"),
			("27b", "~27B"),
			("15b", "~15B"),
			("14b", "~14B"),
			("8b", "~8B"),
			("7b", "~7B"),
			("3b", "~3B"),
			("2b", "~2B"),
			("1b", "~1B"),
		]
		if let matched = paramMap.first(where: { lower.contains($0.0) }) {
			paramCountString = matched.1
		}

		// VLM modalities
		if isVlm {
			modalities = ["vision", "language"]
		}
	}
}

extension ModelMemoryInfo {
	static func == (lhs: ModelMemoryInfo, rhs: ModelMemoryInfo) -> Bool {
		lhs.id == rhs.id
	}
	
	func hash(into hasher: inout Hasher) {
		hasher.combine(id)
	}
}
