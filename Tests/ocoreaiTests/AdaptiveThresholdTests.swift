// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AdaptiveThresholdTests.swift — Verify EMA-based threshold calibration
/// and failure pattern learning logic.

import Testing
import Foundation
@testable import ocoreai

@Suite("AdaptiveThreshold")
struct AdaptiveThresholdTests {
	// MARK: - Basic Init & Threshold Access

	@Test("initialThreshold")
	func initialThreshold() throws {
		let at = AdaptiveThreshold(baseThreshold: 0.9)
		#expect(at.baseThreshold == 0.9)
		#expect(at.getThreshold(for: "unknown") == 0.9)
	}

	@Test("defaultThreshold")
	func defaultThreshold() throws {
		let at = AdaptiveThreshold()
		#expect(at.baseThreshold == 0.85)
		#expect(at.getThreshold(for: "any-model") == 0.85)
	}

	// MARK: - Observation History

	@Test("observationAppends")
	func observationAppends() throws {
		var at = AdaptiveThreshold()
		at.addObservation(success: true, iterations: 1, context: "test")
		#expect(at.correctionHistory.count == 1)
	}

	@Test("observationCappedAt500")
	func observationCappedAt500() throws {
		var at = AdaptiveThreshold()
		for i in 0..<600 {
			at.addObservation(
				success: i % 2 == 0,
				iterations: 1,
				context: "ctx-\(i)"
			)
		}
		#expect(at.correctionHistory.count <= 500)
	}

	// MARK: - Calibration Logic

	@Test("calibrationOn50thObservation")
	func calibrationOn50thObservation() throws {
		var at = AdaptiveThreshold(alpha: 0.15, baseThreshold: 0.85)
		for _ in 0..<50 {
			at.addObservation(success: true, iterations: 1, context: "easy")
		}
		#expect(at.baseThreshold > 0.85)
		#expect(at.baseThreshold <= 0.95)
	}

	@Test("calibrationClampedAt05")
	func calibrationClampedAt05() throws {
		var at = AdaptiveThreshold(baseThreshold: 0.52)
		for _ in 0..<50 {
			at.addObservation(success: false, iterations: 5, context: "fail")
		}
		#expect(at.baseThreshold >= 0.5)
	}

	@Test("calibrationClampedAt095")
	func calibrationClampedAt095() throws {
		var at = AdaptiveThreshold(baseThreshold: 0.94)
		for _ in 0..<50 {
			at.addObservation(success: true, iterations: 1, context: "easy")
		}
		#expect(at.baseThreshold <= 0.95)
	}

	@Test("noChangeWhenMixed")
	func noChangeWhenMixed() throws {
		var at = AdaptiveThreshold(baseThreshold: 0.8)
		let initial = at.baseThreshold
		for i in 0..<50 {
			at.addObservation(success: i % 2 == 0, iterations: 2, context: "mixed")
		}
		#expect(at.baseThreshold == initial)
	}

	// MARK: - Stats

	@Test("statsInitial")
	func statsInitial() throws {
		let at = AdaptiveThreshold()
		let stats = at.getStats()
		#expect(stats.threshold == 0.85)
		#expect(stats.observations == 0)
		#expect(stats.recentSuccessRate == 0.8)
	}

	@Test("statsReflectsObservations")
	func statsReflectsObservations() throws {
		var at = AdaptiveThreshold()
		for _ in 0..<10 {
			at.addObservation(success: true, iterations: 1, context: "ok")
		}
		let stats = at.getStats()
		#expect(stats.observations == 10)
		#expect(stats.recentSuccessRate == 1.0)
	}

	// MARK: - Model-specific Overrides

	@Test("modelSpecificThreshold")
	func modelSpecificThreshold() throws {
		var at = AdaptiveThreshold(baseThreshold: 0.85)
		for _ in 0..<150 {
			at.addObservation(success: true, iterations: 1, context: "easy")
		}
		#expect(at.baseThreshold > 0.85)
		let modelThreshold = at.getThreshold(for: "specific-model")
		#expect(modelThreshold > 0.85)
	}
}

// MARK: - FailurePatternLibrary

extension AdaptiveThresholdTests {
	@Test("learnFailureNewPattern")
	func learnFailureNewPattern() throws {
		var lib = FailurePatternLibrary()
		lib.learnFailure(modelId: "m1", context: "ctx-a", iterationCount: 3)
		#expect(lib.patterns.count == 1)
		let pattern = try #require(lib.patterns["m1-ctx-a"])
		#expect(pattern.occurrenceCount == 1)
		#expect(pattern.iterationCount == 3)
	}

	@Test("learnFailureIncrements")
	func learnFailureIncrements() throws {
		var lib = FailurePatternLibrary()
		lib.learnFailure(modelId: "m1", context: "ctx-a", iterationCount: 3)
		lib.learnFailure(modelId: "m1", context: "ctx-a", iterationCount: 5)
		let pattern = try #require(lib.patterns["m1-ctx-a"])
		#expect(pattern.occurrenceCount == 2)
		#expect(pattern.iterationCount == 5)
	}

	@Test("ruleGenerationThreshold")
	func ruleGenerationThreshold() throws {
		var lib = FailurePatternLibrary()
		lib.learnFailure(modelId: "m1", context: "ctx-a", iterationCount: 2)
		lib.learnFailure(modelId: "m1", context: "ctx-a", iterationCount: 2)
		#expect(lib.getPreventionRules(for: "m1").isEmpty)

		lib.learnFailure(modelId: "m1", context: "ctx-a", iterationCount: 2)
		#expect(!lib.getPreventionRules(for: "m1").isEmpty)
	}

	@Test("rulePriorityCritical")
	func rulePriorityCritical() throws {
		var lib = FailurePatternLibrary()
		for _ in 0..<5 {
			lib.learnFailure(modelId: "m2", context: "heavy", iterationCount: 2)
		}
		let rules = lib.getPreventionRules(for: "m2")
		#expect(rules.contains { $0.priority == .critical })
	}

	@Test("rulePriorityModerate")
	func rulePriorityModerate() throws {
		var lib = FailurePatternLibrary()
		lib.learnFailure(modelId: "m3", context: "light", iterationCount: 2)
		lib.learnFailure(modelId: "m3", context: "light", iterationCount: 2)
		lib.learnFailure(modelId: "m3", context: "light", iterationCount: 2)
		let rules = lib.getPreventionRules(for: "m3")
		#expect(rules.contains { $0.priority == .moderate })
	}

	@Test("modelFiltering")
	func modelFiltering() throws {
		var lib = FailurePatternLibrary()
		for _ in 0..<3 {
			lib.learnFailure(modelId: "m1", context: "a", iterationCount: 2)
			lib.learnFailure(modelId: "m2", context: "b", iterationCount: 2)
		}
		#expect(lib.getPreventionRules(for: "m1").count == 1)
		#expect(lib.getPreventionRules(for: "m2").count == 1)
		#expect(lib.getPreventionRules(for: "m3").isEmpty)
	}

	@Test("confidenceCappedAt10")
	func confidenceCappedAt10() throws {
		var lib = FailurePatternLibrary()
		for _ in 0..<10 {
			lib.learnFailure(modelId: "m4", context: "repeated", iterationCount: 1)
		}
		let rules = lib.getPreventionRules(for: "m4")
		#expect(rules.allSatisfy { $0.confidence <= 1.0 })
	}
}
