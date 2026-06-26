// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// NaturalLanguageClassifier.swift — Lightweight ticket/classification engine
///
/// Classifies user messages into categories: support, complaint, inquiry, refund, feedback.
/// Uses keyword matching + confidence scoring. Falls back to LLM when confidence < 0.7.

import Foundation

/// Classification categories for support tickets.
enum TicketCategory: String, Codable {
	case support // Technical support request
	case complaint // Customer complaint
	case inquiry // General inquiry
	case refund // Refund/cancellation request
	case feedback // Product feedback/suggestion
	case other // Unclassified
}

/// Classification result with confidence score.
struct ClassificationResult: Codable {
	let category: TicketCategory
	let confidence: Double
	let keywords: [String]
	let fallback: Bool

	/// High-confidence result (≥ 0.7 threshold).
	var isHighConfidence: Bool {
		confidence >= 0.7
	}
}

/// Lightweight NLP classifier — rule-based, no ML model dependency.
struct NaturalLanguageClassifier {
	private let categoryKeywords: [TicketCategory: [String]]

	/// Create classifier with built-in keyword maps.
	init() {
		categoryKeywords = [
			.support: ["help", "fix", "bug", "error", "crash", "issue", "problem",
			           "support", "troubleshoot", "broken", "not working", "can't",
			           "无法", "帮助", "问题", "错误", "故障", "崩溃"],
			.complaint: ["unacceptable", "disappointed", "frustrated", "terrible",
			             "worst", "annoying", "angry", "rude", "awful", "horrible",
			             "不满", "讨厌", "差劲", "最差", "愤怒", "投诉", "糟糕"],
			.inquiry: ["how", "what", "when", "where", "why", "can", "do",
			           "available", "pricing", "price", "cost", "feature",
			           "询问", "价格", "功能", "什么时候", "哪里", "怎么"],
			.refund: ["refund", "return", "cancel", "money back", "charge",
			          "billing", "overcharge", "receipt", "invoice",
			          "退款", "退货", "取消", "退费", "账单", "费用"],
			.feedback: ["suggestion", "improve", "better", "could", "wish",
			            "should", "recommend", "idea", "hope",
			            "建议", "改进", "希望", "应该", "推荐", "想法", "反馈"],
		]
	}

	/// Classify a text message into a ticket category.
	/// - Parameter text: The message to classify
	/// - Returns: Classification result with confidence score
	func classify(_ text: String) -> ClassificationResult {
		let lowerText = text.lowercased()
		var scores: [TicketCategory: (score: Double, keywords: [String])] = [:]

		for (category, keywords) in categoryKeywords {
			var matchedKeywords: [String] = []
			var matchCount = 0

			for keyword in keywords {
				if lowerText.contains(keyword.lowercased()) {
					matchedKeywords.append(keyword)
					matchCount += 1
				}
			}

			if matchCount > 0 {
				// Confidence based on keyword density and count
				let density = Double(matchCount) / Double(lowerText.split(separator: " ").count)
				let rawScore = min(density * 5.0 + Double(matchCount) * 0.15, 1.0)
				scores[category] = (rawScore, matchedKeywords)
			}
		}

		// Find the highest scoring category
		guard let best = scores.max(by: { $0.value.score < $1.value.score }) else {
			return ClassificationResult(
				category: .other,
				confidence: 0.0,
				keywords: [],
				fallback: false,
			)
		}

		let confidence = best.value.score
		let isLowConfidence = confidence < 0.7

		return ClassificationResult(
			category: best.key,
			confidence: confidence,
			keywords: best.value.keywords,
			fallback: isLowConfidence,
		)
	}

	/// Batch classify multiple messages.
	func classify(_ messages: [String]) -> [ClassificationResult] {
		messages.map { classify($0) }
	}
}
