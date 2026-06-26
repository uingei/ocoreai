// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ComplexityAnalyzer — input complexity scorer for adaptive thinking budget.
///
/// Three-dimension scoring (signal range 0.0–1.0):
/// ┌─────────────────────────────────────────────────────────────┐
/// │ 1. Length score       — token budget relative cost          │
/// │ 2. Intent score       — query class (fact vs. reasoning)    │
/// │ 3. History score      — conversation context depth          │
/// └─────────────────────────────────────────────────────────────┘

import Foundation

/// Complexity analyzer is actor-isolated for Swift 6 Sendable compliance.
actor ComplexityAnalyzer {
	// MARK: - Internal State

	/// Per-session complexity history (used by AdaptiveStrategy).
	private var sessionScores: [String: [Double]] = [:]

	/// Global moving average score — stabilizes across cold-start.
	private var globalScore: Double = 0.5
	private var scoreCount: Int = 0

	/// Score decay factor (EMA α = 0.3 → recent inputs weighted heavier).
	private let decayAlpha: Double = 0.3
}

// MARK: - Public API

extension ComplexityAnalyzer {
	/// Analyze input complexity and return a composite score 0.0–1.0.
	///
	/// - Parameters:
	///   - input: Raw user message text
	///   - messageCount: Number of messages in current session
	///   - sessionId: Session identifier for per-user adaptive tracking
	/// - Returns: Normalized complexity score
	///
	/// ### Score bands:
	/// | Band    | Score Range  | Action                           |
	/// |---------|-------------|----------------------------------|
	/// | Simple  |  0.0 – 0.33 | Direct answer, no thinking chain |
	/// | Medium  |  0.34 – 0.66 | Standard reasoning scaffold      |
	/// | Complex |  0.67 – 1.0 | Deep reasoning + multi-step verify|
	func analyze(
		input: String,
		messageCount: Int,
		sessionId: String,
	) -> ComplexityScore {
		let lengthScore = scoreLength(input)
		let intentScore = scoreIntent(input)
		let historyScore = scoreHistory(messageCount)

		let composite = compositeScore(
			length: lengthScore,
			intent: intentScore,
			history: historyScore,
		)

		// Update tracking state
		let sessionKey = "session_\(sessionId)"
		var scores = sessionScores[sessionKey] ?? []
		scores.append(composite)
		if scores.count > 50 { scores.removeFirst() } // cap per-session history
		sessionScores[sessionKey] = scores

		scoreCount += 1
		globalScore = (1 - decayAlpha) * globalScore + decayAlpha * composite

		return ComplexityScore(
			composite: composite,
			length: lengthScore,
			intent: intentScore,
			history: historyScore,
			band: ComplexityBand.for(score: composite),
		)
	}

	/// Get the per-session moving complexity baseline for adaptive calibration.
	func sessionBaseline(sessionId: String) -> Double? {
		let scores = sessionScores["session_\(sessionId)"]
		guard let scores, !scores.isEmpty else { return nil }
		return scores.suffix(10).reduce(0) { $0 + $1 } / Double(scores.suffix(10).count)
	}

	/// Get the global complexity baseline across all sessions.
	func globalBaseline() -> Double {
		globalScore
	}
}

// MARK: - Dimension Scorers

extension ComplexityAnalyzer {
	/// Length score — token budget as proxy for input cost.
	///  < 30 tokens  → ~0.0 (trivial)
	///   30–150     → ~0.3 (moderate)
	///  > 150       → ~0.7+ (detailed)
	private func scoreLength(_ input: String) -> Double {
		let approxTokens = Double(input.count) / 4.0 // rough char-to-token heuristic
		// Sigmoid: center at 80 tokens, steep=0.05
		let center: Double = 80
		let steepness = 0.05
		return 1.0 / (1.0 + exp(-(approxTokens - center) * steepness))
	}

	/// Intent score — classify by keyword/heuristic patterns.
	/// Low: factual lookup, yes/no, simple commands
	/// High: multi-step reasoning, code, analysis, comparison
	private func scoreIntent(_ input: String) -> Double {
		let lower = input.lowercased()

		// High-complexity signals
		let highSignals: [String] = [
			"analyze", "分析", "compare", "比较", "explain", "解释",
			"why", "为什么", "how", "如何", "implement", "实现",
			"debug", "debugging", "设计", "architecture", "架构",
			"step by step", "步骤", "summarize", "总结",
			"evaluate", "评估", "refactor", "重构",
			"what if", "假设", "plan", "计划",
			"write a", "写一个", "create", "创建",
			"difference between", "区别", "trade-off", "权衡",
		]

		// Low-complexity signals
		let lowSignals: [String] = [
			"hello", "hi", "你好", "what is", "是什么",
			"who is", "是谁", "what time", "几点",
			"yes", "no", "ok", "好", "确认",
			"list", "列表", "show me", "给我看",
		]

		var score = 0.5 // neutral prior

		for signal in highSignals {
			if lower.contains(signal) { score += 0.08; break }
		}
		for signal in lowSignals {
			if lower.contains(signal) { score -= 0.15; break }
		}

		// Multi-line / structured input → higher complexity
		if lower.contains("\n") {
			score += 0.1
		}

		// Code snippets → higher complexity
		if lower.contains("```") {
			score += 0.15
		}

		return max(0.0, min(1.0, score))
	}

	/// History score — deeper conversations tend to need more context.
	/// 0 messages → 0.0 (cold start)
	/// 1–20 → 0.2–0.5
	/// 20+ → 0.6+ (rich context, more reasoning needed)
	private func scoreHistory(_ messageCount: Int) -> Double {
		// Sigmoid curve: center at 20 messages
		let center: Double = 20
		let steepness = 0.1
		return 1.0 / (1.0 + exp(-(Double(messageCount) - center) * steepness))
	}
}

// MARK: - Composite Weighting

extension ComplexityAnalyzer {
	/// Weighted composite score with intent as dominant factor.
	private func compositeScore(
		length: Double,
		intent: Double,
		history: Double,
	) -> Double {
		// Weights: intent 45%, length 30%, history 25%
		let wLength = 0.30
		let wIntent = 0.45
		let wHistory = 0.25

		let w1 = length * wLength
		let w2 = intent * wIntent
		let w3 = history * wHistory
		let total = w1 + w2 + w3
		return (total * 1000).rounded() / 1000
	}
}

// MARK: - Data Types

/// Complexity analysis result with breakdown by dimension.
struct ComplexityScore {
	/// Composite score (0.0 = trivial, 1.0 = complex reasoning)
	let composite: Double

	/// Per-dimension breakdown
	let length: Double
	let intent: Double
	let history: Double

	/// Resolved action band
	let band: ComplexityBand

	/// Thinking budget in tokens for this score band.
	var thinkingBudgetTokens: Int {
		switch band {
		case .simple: 0 // direct answer
		case .medium: 1024 // standard reasoning scaffold
		case .complex: 4096 // deep reasoning + verification
		}
	}
}

/// Complexity classification band.
enum ComplexityBand: String {
	/// Direct answer — no reasoning scaffold injected.
	case simple
	/// Standard reasoning — moderate thinking scaffold.
	case medium
	/// Deep reasoning — full thinking chain + multi-step verification.
	case complex

	static func `for`(score: Double) -> ComplexityBand {
		if score < 0.34 {
			.simple
		} else if score < 0.67 {
			.medium
		} else {
			.complex
		}
	}
}
