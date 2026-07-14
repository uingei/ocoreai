// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// IntentExtractor.swift — Intent recognition from user messages
///
/// Extracts user intent: action type, target entity, urgency level.
/// Lightweight pattern matching, no ML model dependency required.

import Foundation

/// Action types the user wants to perform.
enum IntentAction: String, Codable {
	case askQuestion // Ask about something
	case performAction // Execute an action (run, do, create)
	case searchData // Search for data/info
	case modifyData // Edit/update/delete data
	case getAnalysis // Request analysis or summary
	case configure // Configuration change
	case monitor // Status check / monitoring
	case other
}

/// Urgency level of the intent.
enum IntentUrgency: String, Codable {
	case low // Routine, can wait
	case medium // Normal priority
	case high // Needs attention soon
	case urgent // Immediate attention required
}

/// Extracted intent from a user message.
struct ExtractedIntent: Codable {
	let action: IntentAction
	let target: String?
	let urgency: IntentUrgency
	let keywords: [String]
	let confidence: Double
}

/// Lightweight intent extractor — pattern-based recognition.
struct IntentExtractor {
	private let actionPatterns: [(action: IntentAction, patterns: [String])]
	private let urgencyPatterns: [(urgency: IntentUrgency, patterns: [String])]

	/// Create extractor with built-in patterns.
	init() {
		actionPatterns = [
			(.askQuestion, ["what", "how", "why", "when", "who", "where", "is", "can", "do",
			                "请问", "如何", "什么", "为什么", "可以", "有没有"]),
			(.performAction, ["run", "execute", "do", "create", "start", "install",
			                  "运行", "执行", "创建", "开始", "安装", "打开"]),
			(.searchData, ["search", "find", "look", "search for", "browse",
			               "搜索", "查找", "找", "浏览", "查"]),
			(.modifyData, ["edit", "update", "change", "modify", "delete", "remove",
			               "修改", "删除", "更新", "改", "移除"]),
			(.getAnalysis, ["analyze", "summary", "summarize", "report", "compare",
			                "分析", "总结", "报告", "对比", "汇总"]),
			(.configure, ["config", "setting", "change setting", "enable", "disable",
			              "配置", "设置", "启用", "禁用"]),
			(.monitor, ["status", "check", "monitor", "watch", "health",
			            "状态", "检查", "监控", "健康"]),
		]

		urgencyPatterns = [
			(.urgent, ["urgent", "emergency", "immediately", "right now", "asap",
			           "紧急", "立刻", "马上", "立即", "马上处理"]),
			(.high, ["asap", "quickly", "soon", "important", "critical",
			         "尽快", "重要", "关键", "优先"]),
			(.medium, ["when you can", "when possible", "no rush",
			           "有空时", "方便时"]),
		]
	}

	/// Extract intent from a user message.
	/// - Parameter text: The message to analyze
	/// - Returns: Extracted intent with action, target, and urgency
	func extract(from text: String) -> ExtractedIntent {
		let lowerText = text.lowercased()
		var matchedKeywords: [String] = []
		var actionScores: [IntentAction: Double] = [:]

		// Score each action type
		for (actionType, patterns) in actionPatterns {
			var score = 0.0
			for pattern in patterns {
				if lowerText.contains(pattern) {
					score += 1.0
					matchedKeywords.append(pattern)
				}
			}
			if score > 0 {
				actionScores[actionType] = score
			}
		}

		// Determine dominant action
		let dominantAction: IntentAction = if let highest = actionScores.max(by: { $0.value < $1.value }) {
			highest.key
		} else {
			// Default: treat as question if no clear action
			lowerText.hasSuffix("?") || text.hasSuffix("?")
				? .askQuestion : .other
		}

		// Determine urgency — always keep the highest level found
		var urgency: IntentUrgency = .medium
		for (urgencyType, patterns) in urgencyPatterns {
			for pattern in patterns {
				if lowerText.contains(pattern) {
					matchedKeywords.append(pattern)
					// Upgrade only: .urgent > .high > .medium > .low
					if urgencyType == .urgent ||
					   (urgencyType == .high && urgency != .urgent) ||
					   (urgencyType == .medium && urgency == .medium) {
						urgency = urgencyType
					}
				}
			}
		}

		// Extract target entity (simplified: grab noun phrase after action verb)
		let target = extractTarget(from: text, action: dominantAction)

		// Confidence based on match density
		let wordCount = max(Double(lowerText.split(separator: " ").count), 1.0)
		let confidence = min(Double(matchedKeywords.count) / wordCount * 3.0, 1.0)

		return ExtractedIntent(
			action: dominantAction,
			target: target,
			urgency: urgency,
			keywords: matchedKeywords,
			confidence: max(confidence, 0.1),
		)
	}

	/// Extract target entity from text based on action type.
	private func extractTarget(from text: String, action _: IntentAction) -> String? {
		let lowerText = text.lowercased()

		// Try to find a noun phrase after common action verbs
		let targets = [
			"search", "find", "look for", "analyze", "create", "edit", "check",
			"搜索", "查找", "分析", "创建", "修改", "检查",
		]

		for target in targets {
			if let range = lowerText.range(of: target) {
				let afterTarget = lowerText[range.upperBound...]
				let trimmed = String(afterTarget).trimmingCharacters(in: .whitespaces)

				if let commaRange = trimmed.range(of: ",") {
					return String(trimmed[..<commaRange.lowerBound]).trimmingCharacters(in: .whitespaces)
				}

				// Otherwise take first 5 words as target
				let firstWords = trimmed.split(separator: " ", maxSplits: 5).map(String.init).joined(separator: " ")
				return firstWords.isEmpty ? nil : firstWords
			}
		}

		return nil
	}
}
