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
	/// Score bands:
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
		let taskType = classifyTaskType(input)
		let intentScore = scoreIntent(from: taskType)
		let historyScore = scoreHistory(messageCount)
		let contextBoost = scoreContextLength(input)

		let composite = compositeScore(
			length: lengthScore,
			intent: intentScore,
			history: historyScore,
			contextBoost: contextBoost,
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
			taskType: taskType,
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

	/// Classify and return the task type from the raw input.
	/// External caller for downstream scaffold / parameter selection.
	func getTaskType(for input: String) -> TaskType {
		classifyTaskType(input)
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

	/// Intent score derived from task type — precision tasks get higher scores.
	/// Code/math/json are inherently error-prone → should trigger more reasoning.
	private func scoreIntent(from taskType: TaskType) -> Double {
		switch taskType {
		case .code: 0.85
		case .math: 0.80
		case .json: 0.70
		case .comparison: 0.60
		case .analysis: 0.55
		case .factual: 0.30
		case .casual: 0.15
		case .general: 0.40
		}
	}

	/// Context-length boost — long inputs (>2k chars) push score up because
	/// they indicate documents, PR discussions, or multi-document analysis
	/// that benefit from structured reasoning.
	/// Returns 0.0–0.25 additive boost.
	private func scoreContextLength(_ input: String) -> Double {
		let chars = Double(input.utf8.count)
		guard chars > 2000 else { return 0 }
		// Logarithmic scale: 2k→~0.05, 10k→~0.15, 50k→~0.25
		let raw = log2(chars / 2000) * 0.1
		return min(0.25, raw)
	}

	/// Classify the input into a task type for downstream scaffold selection.
	///
	/// Priority: code > math > json > comparison > analysis > factual > casual.
	/// Code/math/json always trigger enhanced reasoning because they require
	/// precision (self-consistency, verification loops).
	private func classifyTaskType(_ input: String) -> TaskType {
		let lower = input.lowercased()
		let hasCodeFence = lower.contains("```")
		let lineCount = lower.components(separatedBy: "\n").count

		// Code detection — strongest signal
		let codeSignals: [String] = [
			"```.swift", "```.py", "```.js", "```.ts", "```.java", "```.c", "```.cpp",
			"```.kotlin", "```.go", "```.rs", "```.rb", "```.php",
			"```json", "```yaml", "```toml", "```xml", "```html", "```sql", "```bash",
			"```python", "```javascript", "```typescript", "```markdown",
			"write code", "实现", "implement", "function", "class ",
			"def ", "func ", "fn ", "method", "endpoint", "api",
			"bug", "fix this", "报错", "error:", "traceback", "crash",
			"refactor", "重构", "optimize", "优化",
		]
		if hasCodeFence || codeSignals.contains(where: { lower.contains($0) }) {
			return .code
		}

		// Math detection
		let mathSignals: [String] = [
			"calculate", "计算", "how many", "多少个", "what is 2",
			"probability", "概率", "equation", "公式", "derivative", "导数", "integral", "积分",
			"prove", "证明", "theorem", "不等式",
		]
		if mathSignals.contains(where: { lower.contains($0) }) {
			return .math
		}

		// JSON/structured output detection
		let jsonSignals: [String] = ["json", "json格式", "array", "object", "格式化为",
		                             "output format", "schema", "structured"]
		if jsonSignals.contains(where: { lower.contains($0) }) {
			return .json
		}

		// Comparison/analysis detection
		let comparisonSignals: [String] = [
			"compare", "比较", "difference", "区别", "vs", "versus", "对比",
			"trade-off", "权衡", "which is better", "哪个更好",
		]
		if comparisonSignals.contains(where: { lower.contains($0) }) {
			return .comparison
		}

		// Deep analysis detection
		let analysisSignals: [String] = [
			"analyze", "分析", "explain", "解释", "why", "为什么", "how", "如何",
			"evaluate", "评估", "review", "design", "设计", "architecture", "架构",
			"step by step", "步骤", "summarize", "总结", "plan", "计划",
		]
		if analysisSignals.contains(where: { lower.contains($0) }) || lineCount > 5 {
			return .analysis
		}

		// Factual/definition
		let factualSignals: [String] = [
			"what is", "是什么", "who is", "是谁", "define", "定义",
			"when was", "什么时候", "how does", "怎么做",
		]
		if factualSignals.contains(where: { lower.contains($0) }) {
			return .factual
		}

		// Casual/greeting
		let casualSignals: [String] = [
			"hello", "hi", "你好", "yes", "no", "ok", "好",
			"list", "列表", "show me", "给我看",
		]
		if casualSignals.contains(where: { lower.contains($0) }) {
			return .casual
		}

		return .general
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
	/// Weighted composite score with intent as dominant factor + context boost.
	private func compositeScore(
		length: Double,
		intent: Double,
		history: Double,
		contextBoost: Double,
	) -> Double {
		// Weights: intent 45%, length 30%, history 25%
		let wLength = 0.30
		let wIntent = 0.45
		let wHistory = 0.25

		let w1 = length * wLength
		let w2 = intent * wIntent
		let w3 = history * wHistory
		// Base + context boost, clamped to [0, 1]
		let total = w1 + w2 + w3 + contextBoost
		return min(1.0, max(0.0, (total * 1000).rounded() / 1000))
	}
}

// MARK: - Data Types

/// Task type classification — used for scaffold selection and parameter tuning.
enum TaskType: String, Codable, Sendable {
	/// Code generation, debugging, refactoring
	case code
	/// Math, calculation, proof
	case math
	/// JSON/structured output
	case json
	/// Comparison/evaluation between options
	case comparison
	/// Deep analysis, explanation, architecture
	case analysis
	/// Factual lookup, definitions
	case factual
	/// Greetings, simple commands
	case casual
	/// Uncategorized general purpose
	case general
}

/// Complexity analysis result with breakdown by dimension.
struct ComplexityScore: Sendable {
	/// Composite score (0.0 = trivial, 1.0 = complex reasoning)
	let composite: Double

	/// Per-dimension breakdown
	let length: Double
	let intent: Double
	let history: Double

	/// Resolved action band
	let band: ComplexityBand

	/// Detected task type — drives scaffold and parameter selection
	let taskType: TaskType

	/// Thinking budget in tokens for this score band.
	/// Precision tasks (code/math/json) always get a minimum budget.
	var thinkingBudgetTokens: Int {
		// Override: precision tasks always need at least some reasoning
		if [.code, .math, .json].contains(taskType) {
			return max(512, baseBudget)
		}
		return baseBudget
	}

	private var baseBudget: Int {
		switch band {
		case .simple: 0
		case .medium: 1024
		case .complex: 4096
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
