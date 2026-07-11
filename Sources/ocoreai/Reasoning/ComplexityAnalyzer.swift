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
import NaturalLanguage

// MARK: - Semantic Intent Detector

/// NLContextualEmbedding-powered semantic fallback classifier.
///
/// When keyword-based classification returns `.general`, this detector computes
/// cosine similarity between the input and pre-defined task-type anchor phrases,
/// then returns the highest-scoring TaskType above a confidence threshold.
///
/// API reality (macOS 14.0+ verified via SDK headers):
/// - init?(language:) — failable, no contextLength param
/// - embeddingResultForString(_:language:error:) → NLContextualEmbeddingResult
///   returns per-subword vectors; we mean-pool into a single [Float] per text
/// - hasAvailableAssets / requestAssets() for model asset downloads
///
/// Owned by the `ComplexityAnalyzer` actor — all state is immutable after init,
/// so no cross-actor hops needed.
class SemanticIntentDetector {
	/// Anchor texts representative of each TaskType — used to build reference
	/// embeddings against which user input is compared via cosine similarity.
	private static let anchors: [(TaskType, String)] = [
		(.code, "Write a function that processes API responses and handles errors in the application code"),
		(.math, "Calculate the probability and solve the mathematical equation with integration"),
		(.json, "Return the result as a JSON object with a structured schema and formatted array"),
		(.comparison, "Compare these two approaches and explain the trade-offs versus the other option"),
		(.analysis, "Analyze the architecture and explain why this design works with step by step reasoning"),
		(.factual, "What is the definition and who was the first person to discover this fact"),
		(.casual, "Hello there, just saying hi and having a casual conversation"),
	]

	/// Minimum cosine similarity to override a .general result.
	/// 0.50 is conservative — moderate similarity is enough for high-level intent.
	private static let confidenceThreshold: Double = 0.50

	/// Pre-computed reference embeddings keyed by TaskType.
	private let anchorEmbeddings: [TaskType: [Float]]

	/// The embedding model used for scoring.
	private let model: NLContextualEmbedding

	/// Attempt to initialize with NLContextualEmbedding.
	/// Returns nil if the system does not support contextual embeddings.
	init?() {
		// Step 1: Discover English-language embedding models on device
		let criteria: [NLContextualEmbeddingKey: Any] = [
			.languages: [NLLanguage.english],
		]
		let models = NLContextualEmbedding.contextualEmbeddings(forValues: criteria)
		guard !models.isEmpty else {
			return nil
		}
		// Step 2: Pick the first (best available) model
		let model = models.first!
		// Step 3: Load assets (load() can throw)
		try? model.load()
		self.model = model
		self.anchorEmbeddings = Self.computeAnchors(using: model)
	}

	/// Extract a mean-pooled [Float] from NLContextualEmbeddingResult.
	///
	/// NLContextualEmbedding produces per-subword vectors. We average all
	/// subword vectors into a single vector representing the whole string.
	private static func meanPoolEmbedding(
		_ result: NLContextualEmbeddingResult
	) -> [Float]? {
		var vectors: [[Float]] = []

		// enumerateTokenVectors(in range: Range<String.Index>, using block: ([Double], Range<String.Index>) -> Bool)
		result.enumerateTokenVectors(in: result.string.startIndex..<result.string.endIndex) { vector, _ in
			vectors.append(vector.map { Float($0) })
			return false // process all tokens
		}

		guard !vectors.isEmpty else { return nil }

		// Use the first vector's length as the canonical dimension
		let dim = vectors[0].count
		var pooled = [Float](repeating: 0, count: dim)

		for vec in vectors {
			guard vec.count == dim else { continue }
			for i in 0..<dim {
				pooled[i] += vec[i]
			}
		}

		pooled = pooled.map { $0 / Float(vectors.count) }
		return pooled
	}

	/// Pre-compute anchor embeddings for all TaskTypes.
	private static func computeAnchors(
		using model: NLContextualEmbedding
	) -> [TaskType: [Float]] {
		var dict: [TaskType: [Float]] = [:]
		for (taskType, anchorText) in anchors {
			let result = try? model.embeddingResult(for: anchorText, language: NLLanguage.english)
			if let result, let pooled = Self.meanPoolEmbedding(result) {
				dict[taskType] = pooled
			}
		}
		return dict
	}

	/// Classify input text by comparing against anchor embeddings via cosine similarity.
	/// Returns the best-matching TaskType if confidence exceeds the threshold,
	/// otherwise returns nil (meaning the input is truly ambiguous).
	func classify(_ input: String) -> TaskType? {
		guard
			let result = try? model.embeddingResult(for: input, language: NLLanguage.english),
			let inputEmbedding = Self.meanPoolEmbedding(result)
		else { return nil }

		var bestScore: Double = -1
		var bestType: TaskType = .general

		for (taskType, anchor) in anchorEmbeddings {
			let sim = cosineSimilarity(inputEmbedding, anchor)
			if sim > bestScore {
				bestScore = sim
				bestType = taskType
			}
		}

		return bestScore >= Self.confidenceThreshold ? bestType : nil
	}

	/// Cosine similarity between two equal-length float vectors.
	private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
		let len = min(a.count, b.count)
		guard len > 0 else { return 0 }

		var dot: Float = 0
		var magA: Float = 0
		var magB: Float = 0

		for i in 0..<len {
			dot += a[i] * b[i]
			magA += a[i] * a[i]
			magB += b[i] * b[i]
		}

		guard magA > 0, magB > 0 else { return 0 }
		return Double(dot / (sqrt(magA) * sqrt(magB)))
	}
}

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

	/// Semantic fallback classifier — initialized lazily on first .general result.
	private var _semanticDetector: SemanticIntentDetector?
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
	/// Two-phase classification:
	/// 1. Keyword matching (fast, zero-download overhead)
	/// 2. NLContextualEmbedding semantic fallback when keywords return .general
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

		// ── Phase 2: semantic fallback ──
		// Keyword matching couldn't resolve a type — try NLContextualEmbedding
		// cosine-similarity against task-type anchors.
		if let detector = _semanticDetector {
			if let semanticType = detector.classify(input) {
				return semanticType
			}
		}
		// Lazy-init detector on first .general result so we tolerate envs
		// where NLContextualEmbedding is unavailable or initialization fails.
		if let detector = SemanticIntentDetector() {
			_semanticDetector = detector
			return detector.classify(input) ?? .general
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
