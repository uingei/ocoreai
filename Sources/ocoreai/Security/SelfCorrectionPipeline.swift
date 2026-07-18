// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SelfCorrectionPipeline — Three-phase self-correction with memory persistence
///
/// Architecture:
///   Phase 1: Rule-based critique (IntentExtractor + NaturalLanguageClassifier)
///   Phase 2: LLM self-critique via reflection prompt injection
///   Phase 3: Dynamic context rewriter (system prompt override + few-shot)
///
/// Convergence: max_iteration = 3 hard limit. On convergence, correction trace
/// serialized as MemoryEvent (六要素) for long-term recall.
///
/// Zero token overhead on first pass — only activates when confidence < 0.85
/// or domain mismatch detected.

import Foundation
import Logging

// MARK: - Models

/// Correction phase identifier
enum CorrectionPhase: String, Codable {
	case phase1RuleBased
	case phase2Reflection
	case phase3ContextRewrite
	case converged
	case failed
}

/// Track the correction path through the pipeline
struct CorrectionTrace: Codable {
	let originalPrompt: String
	let modelResponse: String
	let phasesAttempted: [CorrectionPhase]
	let finalPhase: CorrectionPhase
	let iterations: Int
	let converged: Bool
	let timestamp: Int64

	/// Memory event representation for persistence
	func toMemoryEvent(sessionId: Int64) -> MemoryEvent {
		MemoryEvent(
			sessionId: sessionId,
			context: "self_correction",
			entities: phasesAttempted.map(\.rawValue),
			cause: originalPrompt.prefix(100).description,
			process: "Phases: " + phasesAttempted.map(\.rawValue).joined(separator: "->"),
			result: (converged ? "converged in " : "failed after ") + String(iterations) + " iterations",
			resolution: converged ? .resolved : (iterations > 1 ? .workaround : .unresolved),
			memoryType: .pattern,
			confidence: converged ? 0.9 : max(0.3, 1.0 - Double(iterations) * 0.15),
			tags: ["self-correction", String(iterations), converged ? "converged" : "failed"],
		)
	}
}

/// Phase 1 result from rule-based critique
struct RuleCritiqueResult {
	/// Whether the response passes rule-based checks
	let passes: Bool
	/// Confidence score from classifier
	let confidence: Double
	/// Issues detected (for Phase 2 prompt injection)
	let issues: [String]
	/// Domain classification if available
	let domain: String?
}

// MARK: - Pipeline

/// Self-correction pipeline with three convergence phases.
///
/// - Phase 1: Rule-based critique using existing IntentExtractor + NaturalLanguageClassifier
///   + SentimentAnalyzer. Threshold ≥ 0.85 → bypass correction entirely.
/// - Phase 2: LLM self-critique via reflection system prompt injection.
///   Model evaluates its own output against criteria.
/// - Phase 3: Dynamic context rewriter — rewrites systemPrompt or injects few-shot examples.
struct SelfCorrectionPipeline {
	/// Hard iteration limit — prevents infinite loops
	static let maxIterations = 3

	/// Confidence threshold for Phase 1 bypass
	static let bypassThreshold: Double = 0.85

	// MARK: - Dependencies

	private let intentExtractor = IntentExtractor()
	private let classifier = NaturalLanguageClassifier()
	private let sentimentAnalyzer = SentimentAnalyzer()

	// MARK: - Execution

	/// Run self-correction pipeline on a model response.
	///
	/// If Phase 1 passes (confidence ≥ 0.85), returns (response, 0, .converged).
	/// Otherwise iterates through Phase 2/3 with maxIterations ceiling.
	///
	/// - Parameters:
	///   - prompt: Original user prompt
	///   - response: Current model output
	///   - sessionId: Session ID for memory persistence
	///   - generate: Closure that produces a new response with given system prompt override
	///   - logger: Structured logger
	///   - persistMemory: Closure to persist MemoryEvent (optional)
	///   - maxPhases: Maximum phases to attempt (1 = Phase 1 rule-based only; 3 = full pipeline).
	///     SSE path should pass 1 to avoid calling generate() on an already-sent stream.
	/// - Returns: (finalResponse, iterations, finalPhase, trace)
	func evaluate(
		prompt: String,
		response: String,
		sessionId: Int64,
		generate: @Sendable (String?, [String]?) async throws -> String,
		logger: Logger,
		persistMemory: @Sendable (MemoryEvent) async -> Void = { _ in },
		maxPhases: Int = SelfCorrectionPipeline.maxIterations,
	) async throws -> (finalResponse: String, iterations: Int, finalPhase: CorrectionPhase, trace: CorrectionTrace) {
		// Phase 1: Rule-based critique — zero token cost
		let phase1Result = phase1RuleBasedCritique(prompt: prompt, response: response)

		if phase1Result.confidence >= SelfCorrectionPipeline.bypassThreshold {
			logger.info("Self-correction: Phase 1 bypass (confidence=\(phase1Result.confidence))")
			let trace = CorrectionTrace(
				originalPrompt: prompt,
				modelResponse: response,
				phasesAttempted: [],
				finalPhase: .converged,
				iterations: 0,
				converged: true,
				timestamp: Int64(Date().timeIntervalSince1970 * 1_000_000),
			)
			await persistMemory(trace.toMemoryEvent(sessionId: sessionId))
			return (response, 0, .converged, trace)
		}

		logger.info("Self-correction: Phase 1 failed (confidence=\(phase1Result.confidence)), entering correction loop")

		// SSE path (maxPhases == 1): skip correction loop — stream already sent,
		// generate closure is no-op. Record Phase 1 trace and return.
		if maxPhases <= 1 {
			logger.info("Self-correction: maxPhases == 1, recording Phase 1 trace only (no regeneration)")
			let trace = CorrectionTrace(
				originalPrompt: prompt,
				modelResponse: response,
				phasesAttempted: [],
				finalPhase: .converged,
				iterations: 0,
				converged: true,
				timestamp: Int64(Date().timeIntervalSince1970 * 1_000_000),
			)
			await persistMemory(trace.toMemoryEvent(sessionId: sessionId))
			return (response, 0, .converged, trace)
		}

		// Correction loop: Phase 2 → Phase 3
		var currentResponse = response
		var phasesAttempted: [CorrectionPhase] = []

		for iteration in 1 ... SelfCorrectionPipeline.maxIterations {
			// Phase 2: LLM self-critique reflection
			var reflectedPrompt: String? = phase2ReflectionPrompt(
				originalPrompt: prompt,
				previousResponse: currentResponse,
				issues: phase1Result.issues,
			)
			phasesAttempted.append(.phase2Reflection)

			currentResponse = try await generate(reflectedPrompt, nil)

			// Re-check with Phase 1 rules
			let reCheck = phase1RuleBasedCritique(prompt: prompt, response: currentResponse)
			if reCheck.confidence >= SelfCorrectionPipeline.bypassThreshold {
				phasesAttempted.append(.converged)
				logger.info("Self-correction: converged at iteration \(iteration)")
				let trace = CorrectionTrace(
					originalPrompt: prompt,
					modelResponse: currentResponse,
					phasesAttempted: phasesAttempted,
					finalPhase: .converged,
					iterations: iteration,
					converged: true,
					timestamp: Int64(Date().timeIntervalSince1970 * 1_000_000),
				)
				await persistMemory(trace.toMemoryEvent(sessionId: sessionId))
				return (currentResponse, iteration, .converged, trace)
			}

			// Phase 3: Context rewriter — only if not converged and iteration < max
			if iteration < SelfCorrectionPipeline.maxIterations {
				phasesAttempted.append(.phase3ContextRewrite)
				let (rewrittenSystem, examples) = phase3ContextRewrite(
					prompt: prompt,
					response: currentResponse,
				)
				reflectedPrompt = rewrittenSystem
				currentResponse = try await generate(reflectedPrompt, examples)

				let finalCheck = phase1RuleBasedCritique(prompt: prompt, response: currentResponse)
				if finalCheck.confidence >= SelfCorrectionPipeline.bypassThreshold {
					phasesAttempted.append(.converged)
					logger.info("Self-correction: converged after context rewrite at iteration \(iteration)")
					let trace = CorrectionTrace(
						originalPrompt: prompt,
						modelResponse: currentResponse,
						phasesAttempted: phasesAttempted,
						finalPhase: .converged,
						iterations: iteration,
						converged: true,
						timestamp: Int64(Date().timeIntervalSince1970 * 1_000_000),
					)
					await persistMemory(trace.toMemoryEvent(sessionId: sessionId))
					return (currentResponse, iteration, .converged, trace)
				}
			}
		}

		// Failed after max iterations
		let trace = CorrectionTrace(
			originalPrompt: prompt,
			modelResponse: currentResponse,
			phasesAttempted: phasesAttempted,
			finalPhase: .failed,
			iterations: SelfCorrectionPipeline.maxIterations,
			converged: false,
			timestamp: Int64(Date().timeIntervalSince1970 * 1_000_000),
		)
		await persistMemory(trace.toMemoryEvent(sessionId: sessionId))
		logger.warning("Self-correction: failed after \(trace.iterations) iterations")
		return (currentResponse, SelfCorrectionPipeline.maxIterations, .failed, trace)
	}

	// MARK: - Phase 1: Rule-Based Critique

	/// Phase 1 critique using existing security modules — zero token cost.
	///
	/// Checks:
	///   1. Intent alignment — does response match user intent?
	///   2. Sentiment check — is response unnecessarily negative?
	///   3. Classification confidence — is the domain matched?
	///
	/// - Returns: Confidence score 0.0–1.0 and detected issues
	private func phase1RuleBasedCritique(prompt: String, response: String) -> RuleCritiqueResult {
		var issueList: [String] = []
		var confidenceSum = 0.0
		var checkCount = 0

		// Check 1: Intent alignment
		let intent = intentExtractor.extract(from: prompt)
		if intent.confidence > 0.7 {
			checkCount += 1
			confidenceSum += intent.confidence
			if intent.confidence < 0.5 {
				issueList.append("Low intent confidence (" + String(format: "%.2f", intent.confidence) + ")")
			}
		}

		// Check 2: Sentiment analysis on response
		let sentiment = sentimentAnalyzer.analyze(response)
		checkCount += 1
		// Weight: positive sentiment = good, negative = potential issue
		let sentimentScore = max(0.0, (sentiment.compound + 1.0) / 2.0)
		confidenceSum += sentimentScore
		if sentiment.isHighRisk {
			issueList.append("High-risk sentiment detected in response")
		}

		// Check 3: Domain classification
		let classification = classifier.classify(prompt)
		checkCount += 1
		confidenceSum += classification.confidence
		if classification.fallback {
			issueList.append("Uncertain domain classification")
		}

		let avgConfidence = checkCount > 0 ? confidenceSum / Double(checkCount) : 1.0

		return RuleCritiqueResult(
			passes: avgConfidence >= SelfCorrectionPipeline.bypassThreshold,
			confidence: avgConfidence,
			issues: issueList,
			domain: classification.category.rawValue,
		)
	}

	// MARK: - Phase 2: Reflection Prompt

	/// Generate a self-critique reflection prompt.
	///
	/// Injects criteria for the model to evaluate its own output,
	/// including issues detected in Phase 1.
	///
	/// - Returns: Modified system prompt to replace original
	private func phase2ReflectionPrompt(
		originalPrompt: String,
		previousResponse: String,
		issues: [String],
	) -> String {
		let issueList = issues.isEmpty
			? "No specific issues detected, but confidence was below threshold."
			: issues.joined(separator: "\n")

		return "SYSTEM: You are about to respond to a user request. Before answering, please self-critique.\n\n" +
			"ORIGINAL REQUEST: \(originalPrompt)\n\n" +
			"PREVIOUS RESPONSE (for reference): \(previousResponse)\n\n" +
			"CRITIQUE ISSUES TO ADDRESS:\n\(issueList)\n\n" +
			"SELF-REFLECTION INSTRUCTIONS:\n" +
			"1. Review the original request and your previous response\n" +
			"2. Identify any issues: incomplete, inaccurate, biased, or off-topic content\n" +
			"3. Address the specific critique issues listed above\n" +
			"4. If your previous response was good, improve it further\n" +
			"5. If you were wrong, acknowledge and correct yourself\n\n" +
			"Provide your improved response directly. Do not include the self-critique text."
	}

	// MARK: - Phase 3: Context Rewriter

	/// Dynamic context rewrite with few-shot examples.
	///
	/// Adjusts system prompt based on detected issues and provides
	/// concrete examples of the expected behavior.
	///
	/// - Returns: (rewrittenSystemPrompt, fewShotExamples)
	private func phase3ContextRewrite(
		prompt: String,
		response: String,
	) -> (systemPrompt: String, examples: [String]?) {
		let sentiment = sentimentAnalyzer.analyze(response)
		let intent = intentExtractor.extract(from: prompt)

		var directiveChanges: [String] = []

		// Adjust tone based on sentiment
		if sentiment.polarity == .veryNegative || sentiment.polarity == .negative {
			directiveChanges.append("Ensure your response maintains a positive, helpful tone")
		}

		// Reinforce intent matching
		if intent.confidence < 0.6 {
			directiveChanges.append("Focus directly on the user intent: " + intent.action.rawValue)
		}

		// Add specificity directive
		if response.count < 50 {
			directiveChanges.append("Provide a more detailed and comprehensive response")
		}

		let customSystem = "SYSTEM (ENHANCED):\n" + directiveChanges.joined(separator: "\n") + "\nRespond directly and helpfully."

		// Generate targeted few-shot examples based on intent
		let examples: [String]? = intent.action.examplesForCorrection(intentAction: intent.action)

		return (customSystem, examples)
	}
}

// MARK: - Intent Example Database

extension IntentAction {
	/// Return few-shot examples for the given intent type.
	/// These guide the model toward the expected response pattern.
	func examplesForCorrection(intentAction _: IntentAction) -> [String]? {
		switch self {
		case .askQuestion:
			[
				"Q: What is the capital of France? -> A: The capital of France is Paris.",
				"Q: How does photosynthesis work? -> A: Photosynthesis is the process by which plants convert sunlight into energy through chlorophyll...",
			]
		case .performAction:
			[
				"User: Create a new project -> Assistant: I've created a new project with the following structure:",
				"User: Run the build -> Assistant: Build completed successfully in 2.3s",
			]
		case .getAnalysis:
			[
				"User: Analyze this data -> Assistant: Based on the data provided, here are the key findings:",
				"User: Summarize the report -> Assistant: Key summary points:",
			]
		default:
			nil
		}
	}
}
