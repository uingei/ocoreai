// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ThinkingBudget — adaptive token budget allocator for "三思而后行" behavior.
///
/// Bridges ComplexityAnalyzer scores → system prompt scaffolding injection.
/// Zero overhead path: simple queries skip scaffolding entirely.

import Foundation

/// Thinking budget manager — actor-isolated for Swift 6 Sendable compliance.
actor ThinkingBudget {
	// MARK: - Configuration

	/// Budget multiplier based on consecutive high-quality outputs (adaptive).
	/// Range: 0.5 (conservative) – 2.0 (aggressive)
	private var multiplier: [String: Double] = [:]

	/// Default multiplier for new sessions.
	private let defaultMultiplier: Double = 1.0

	/// Max consecutive quality threshold to bump budget up.
	private let bumpThreshold: Int = 3

	/// Max consecutive low-quality threshold to reduce budget.
	private let reduceThreshold: Int = 2

	// MARK: - Quality Tracking

	/// Per-session quality history (1.0 = good, 0.0 = poor).
	private var qualityHistory: [String: [Double]] = [:]
}

// MARK: - Public API

extension ThinkingBudget {
	/// Get scaffolding text for a given complexity score and context.
	///
	/// Reads the calibrated multiplier and adjusts scaffold depth:
	/// - multiplier ≥ 1.5 → upgrade band one level (simple→medium, medium→complex)
	/// - multiplier ≤ 0.7 → downgrade band one level (complex→medium, medium→simple)
	/// - multiplier in (0.7, 1.5) → use score.band as-is
	///
	/// Selects scaffold by `taskType` first (code/math/json/comparison get
	/// domain-specific reasoning protocols), falls back to generic protocol for
	/// general/analysis tasks.
	///
	/// - Parameters:
	///   - score: Complexity score from ``ComplexityAnalyzer``
	///   - sessionId: Session identifier for adaptive budget tracking
	/// - Returns: System prompt scaffolding segment, or empty string for simple queries
	func scaffolding(for score: ComplexityScore, sessionId: String) -> String {
		let m = currentMultiplier(for: sessionId)
		let adjustedBand: ComplexityBand
		if m >= 1.5 {
			// Adaptive upgrade — session has consistently high quality
			switch score.band {
			case .simple: adjustedBand = .medium
			case .medium: adjustedBand = .complex
			case .complex: adjustedBand = .complex
			}
		} else if m <= 0.7 {
			// Adaptive downgrade — session has consistently low quality
			switch score.band {
			case .simple: adjustedBand = .simple
			case .medium: adjustedBand = .simple
			case .complex: adjustedBand = .medium
			}
		} else {
			adjustedBand = score.band
		}

		switch adjustedBand {
		case .simple:
			// Precision tasks still get a minimal check even in simple band
			switch score.taskType {
			case .code:
				return "Before writing code: identify edge cases, then verify the code compiles mentally."
			case .math:
				return "For calculations: show each step, then verify by substitution."
			case .json:
				return "For structured output: ensure all required fields are present and types are correct."
			default:
				return "" // zero overhead — direct answer only
			}
		case .medium:
			return mediumScaffold(for: score.taskType)
		case .complex:
			return complexScaffold(for: score.taskType)
		}
	}

	/// Record feedback quality for adaptive calibration.
	///
	/// - Parameter quality: 0.0 (poor) – 1.0 (excellent) for this session
	/// Call after user feedback, task completion, or self-correction trigger.
	func recordQuality(_ quality: Double, for sessionId: String) {
		var history = qualityHistory[sessionId] ?? []
		history.append(min(1.0, max(0.0, quality)))
		if history.count > 20 { history.removeFirst() }
		qualityHistory[sessionId] = history

		let recent = history.suffix(5)
		let avg = recent.reduce(0) { $0 + $1 } / Double(recent.count)

		var current = multiplier[sessionId] ?? defaultMultiplier
		if avg > 0.8, current < 2.0 {
			current = min(2.0, current + 0.2) // bump for consistency
		} else if avg < 0.4, current > 0.5 {
			current = max(0.5, current - 0.15) // reduce for poor quality
		}
		multiplier[sessionId] = current
	}

	/// Get current budget multiplier for a session.
	func currentMultiplier(for sessionId: String) -> Double {
		multiplier[sessionId] ?? defaultMultiplier
	}
}

// MARK: - Scaffold Content (Task-aware)

extension ThinkingBudget {
	/// Medium-complexity scaffold — selects domain-specific protocol.
	private func mediumScaffold(for taskType: TaskType) -> String {
		switch taskType {
		case .code:
			return mediumCodeScaffold
		case .math:
			return mediumMathScaffold
		case .json:
			return mediumJsonScaffold
		case .comparison:
			return mediumComparisonScaffold
		case .analysis, .general:
			return mediumGeneralScaffold
		case .factual, .casual:
			return ""
		}
	}

	/// Complex-complexity scaffold — selects domain-specific deep protocol.
	private func complexScaffold(for taskType: TaskType) -> String {
		switch taskType {
		case .code:
			return complexCodeScaffold
		case .math:
			return complexMathScaffold
		case .json:
			return complexJsonScaffold
		case .comparison:
			return complexComparisonScaffold
		case .analysis, .general:
			return complexGeneralScaffold
		case .factual, .casual:
			return mediumGeneralScaffold // lightweight reasoning for unexpected complexity
		}
	}

	// MARK: - General

	private var mediumGeneralScaffold: String {
		"""
		## Reasoning Protocol
		Before responding:
		1. PERCEIVE: Restate the core intent in one sentence.
		2. REASON: Outline your approach and key assumptions.
		3. ACT: Execute with clear structure.

		If the user's question is straightforward, answer directly without these sections.
		"""
	}

	private var complexGeneralScaffold: String {
		"""
		## Deep Reasoning Protocol (三思而后行)
		Before responding, follow this internal checklist:

		1. PERCEIVE:
		   - Restate the user's actual need (not just their words)
		   - Identify implicit assumptions or hidden constraints
		   - Flag any ambiguities worth clarifying

		2. REASON:
		   - Consider at least 2 alternative approaches
		   - Select the best and justify why
		   - Note potential pitfalls of the chosen approach
		   - Identify what "good enough" looks like vs "over-engineered"

		3. ACT:
		   - Execute with clear section structure
		   - Quantify claims where possible (numbers > adjectives)
		   - If uncertain, label explicitly as SPECULATIVE

		4. SELF-CHECK (brief):
		   - Does the answer address what was actually asked?
		   - Are there contradictions or unstated assumptions?
		   - Is the level of detail proportional to the question?

		When a simple direct answer suffices, skip this scaffold and answer directly.
		"""
	}

	// MARK: - Code

	private var mediumCodeScaffold: String {
		"""
		## Code Protocol
		Before writing code:
		1. UNDERSTAND: Identify the input/output contract and edge cases.
		2. DESIGN: Choose the simplest correct approach. Consider time/space complexity.
		3. WRITE: Clear, readable code with appropriate error handling.
		4. VERIFY: Quick mental trace through one normal + one edge case.

		For small changes, just write the code directly.
		"""
	}

	private var complexCodeScaffold: String {
		"""
		## Code Protocol (深度代码审查)
		Before writing code, apply this checklist:

		1. UNDERSTAND:
		   - What is the exact input/output contract?
		   - What edge cases could break this? (nil, empty, large input, concurrent access)
		   - Are there type-safety or Sendable implications?

		2. DESIGN:
		   - Simpler approach vs more robust approach — which is appropriate?
		   - What error handling is needed? Fail fast or graceful degradation?
		   - Are dependencies minimal and well-scoped?

		3. WRITE:
		   - Correctness first, then readability, then performance
		   - Name things clearly — the name is the primary documentation
		   - No dead code, no unused variables

		4. SELF-CHECK (mandatory):
		   - Trace through: does it work for the happy path?
		   - Trace through: does it fail gracefully on error input?
		   - Are there race conditions or state mutation issues?
		   - Would a code review flag anything here?

		If the change is trivial (≤5 lines), just write it.
		"""
	}

	// MARK: - Math

	private var mediumMathScaffold: String {
		"""
		## Calculation Protocol
		1. Identify what needs to be calculated and the units involved.
		2. Show each step — don't skip intermediate results.
		3. After getting a result, verify by:
		   - Checking units make sense
		   - Estimating mentally to sanity-check the magnitude
		"""
	}

	private var complexMathScaffold: String {
		"""
		## Calculation Protocol (验算)
		For mathematical problems, follow rigorously:

		1. PARSE:
		   - Restate the problem in your own words
		   - List known values and what you need to find
		   - Note any constraints or assumptions

		2. SOLVE:
		   - Derive formulas before plugging in numbers
		   - Show every intermediate step — never skip steps
		   - Keep track of units throughout

		3. VERIFY (non-negotiable):
		   - Plug answer back into original equation
		   - Check: does the answer have reasonable magnitude?
		   - Are the units correct?
		   - Does it satisfy all constraints?

		4. LABEL UNCERTAINTY:
		   - If any step uses approximation, say so
		   - Range estimates are better than precise wrong answers

		Skip this for trivial arithmetic (e.g. 2+2).
		"""
	}

	// MARK: - JSON/Structured

	private var mediumJsonScaffold: String {
		"""
		## Structured Output Protocol
		1. Identify the required schema/fields.
		2. Build the structure ensuring all required keys exist.
		3. Validate: correct types, no trailing commas, proper nesting.
		"""
	}

	private var complexJsonScaffold: String {
		"""
		## Structured Output Protocol (严格验证)
		For structured output, precision is mandatory:

		1. SCHEMA:
		   - List all required fields and their types
		   - Note nested structures and array expectations
		   - Identify optional vs required fields

		2. CONSTRUCT:
		   - Build innermost structures first, then nest outward
		   - Ensure string values are properly escaped
		   - Numbers are numbers (not strings), booleans are booleans

		3. VALIDATE (before outputting):
		   - Every required field present?
		   - No trailing commas?
		   - Proper bracket/brace matching?
		   - Types match the schema?
		   - Would a JSON parser accept this?

		Output valid JSON only — no markdown wrapping unless explicitly requested.
		"""
	}

	// MARK: - Comparison

	private var mediumComparisonScaffold: String {
		"""
		## Comparison Protocol
		1. Identify the dimensions to compare (at least 3).
		2. For each dimension, evaluate both options objectively.
		3. Summarize in a clear structure (table or bullet points).
		4. Give a recommendation with justification.
		"""
	}

	private var complexComparisonScaffold: String {
		"""
		## Comparison Protocol (多维分析)
		For fair comparisons:

		1. FRAME:
		   - What is the user actually deciding between?
		   - What criteria matter most for their context?
		   - Are there trade-offs that can't be resolved objectively?

		2. EVALUATE:
		   - Compare across multiple dimensions (≥3)
		   - Use concrete evidence, not opinions
		   - Acknowledge strengths AND weaknesses of each option
		   - Avoid false equivalence — if one is clearly better, say so

		3. SYNTHESIZE:
		   - Present in a structured comparison (table preferred)
		   - Give a clear recommendation based on the user's stated goals
		   - Note when the answer depends on unstated preferences

		4. SELF-CHECK:
		   - Is this comparison fair or biased?
		   - Did I cherry-pick dimensions?
		   - Are claims backed by facts vs hand-wavy assertions?
		"""
	}
}
