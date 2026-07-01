// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AdaptiveThresholdTests.swift — Verify EMA-based threshold calibration
/// and failure pattern learning logic.

import XCTest
@testable import ocoreai

final class AdaptiveThresholdTests: XCTestCase {
	// MARK: - Basic Init & Threshold Access

	func testInitialThreshold() throws {
		let at = AdaptiveThreshold(baseThreshold: 0.9)
		XCTAssertEqual(at.baseThreshold, 0.9)
		XCTAssertEqual(at.getThreshold(for: "unknown"), 0.9)
	}

	func testDefaultThreshold() throws {
		let at = AdaptiveThreshold()
		XCTAssertEqual(at.baseThreshold, 0.85)
		XCTAssertEqual(at.getThreshold(for: "any-model"), 0.85)
	}

	// MARK: - Observation History

	func testObservationAppends() throws {
		var at = AdaptiveThreshold()
		at.addObservation(success: true, iterations: 1, context: "test")
		XCTAssertEqual(at.correctionHistory.count, 1)
	}

	func testObservationCappedAt500() throws {
		var at = AdaptiveThreshold()
		for i in 0..<600 {
			at.addObservation(
				success: i % 2 == 0,
				iterations: 1,
				context: "ctx-\\(i)"
			)
		}
		XCTAssertLessThanOrEqual(at.correctionHistory.count, 500)
	}

	// MARK: - Calibration Logic

	func testCalibrationOn50thObservation() throws {
		// Every 50 observations triggers calibration
		var at = AdaptiveThreshold(alpha: 0.15, baseThreshold: 0.85)

		// Feed 50 high-success observations (should nudge up)
		for _ in 0..<50 {
			at.addObservation(success: true, iterations: 1, context: "easy")
		}
		// After calibration, threshold should be higher than 0.85
		XCTAssertGreaterThan(at.baseThreshold, 0.85)
		XCTAssertLessThanOrEqual(at.baseThreshold, 0.95)
	}

	func testCalibrationClampedAt05() throws {
		var at = AdaptiveThreshold(baseThreshold: 0.52)
		// Feed 50 low-success observations → threshold drops
		for _ in 0..<50 {
			at.addObservation(success: false, iterations: 5, context: "fail")
		}
		XCTAssertGreaterThanOrEqual(at.baseThreshold, 0.5)
	}

	func testCalibrationClampedAt095() throws {
		var at = AdaptiveThreshold(baseThreshold: 0.94)
		// Feed 50 high-success observations → threshold rises
		for _ in 0..<50 {
			at.addObservation(success: true, iterations: 1, context: "easy")
		}
		XCTAssertLessThanOrEqual(at.baseThreshold, 0.95)
	}

	func testNoChangeWhenMixed() throws {
		var at = AdaptiveThreshold(baseThreshold: 0.8)
		let initial = at.baseThreshold
		// ~50% success rate → no adjustment
		for i in 0..<50 {
			at.addObservation(success: i % 2 == 0, iterations: 2, context: "mixed")
		}
		XCTAssertEqual(at.baseThreshold, initial)
	}

	// MARK: - Stats

	func testStatsInitial() throws {
		let at = AdaptiveThreshold()
		let stats = at.getStats()
		XCTAssertEqual(stats.threshold, 0.85)
		XCTAssertEqual(stats.observations, 0)
		XCTAssertEqual(stats.recentSuccessRate, 0.8) // default when empty
	}

	func testStatsReflectsObservations() throws {
		var at = AdaptiveThreshold()
		for _ in 0..<10 {
			at.addObservation(success: true, iterations: 1, context: "ok")
		}
		let stats = at.getStats()
		XCTAssertEqual(stats.observations, 10)
		XCTAssertEqual(stats.recentSuccessRate, 1.0)
	}

	// MARK: - Model-specific Overrides

	func testModelSpecificThreshold() throws {
		var at = AdaptiveThreshold(baseThreshold: 0.85)
		// Simulate model-specific threshold via calibration
		// Feed enough observations to trigger calibration ≥2 times
		for _ in 0..<150 {
			at.addObservation(success: true, iterations: 1, context: "easy")
		}
		XCTAssertGreaterThan(at.baseThreshold, 0.85)
		// Model without override falls back to base
		let modelThreshold = at.getThreshold(for: "specific-model")
		XCTAssertGreaterThan(modelThreshold, 0.85)
	}
}

// MARK: - FailurePatternLibrary Tests

extension AdaptiveThresholdTests {
	func testLearnFailureNewPattern() throws {
		var lib = FailurePatternLibrary()
		lib.learnFailure(modelId: "m1", context: "ctx-a", iterationCount: 3)

		XCTAssertEqual(lib.patterns.count, 1)
		let pattern = lib.patterns["m1-ctx-a"]
		XCTAssertNotNil(pattern)
		XCTAssertEqual(pattern?.occurrenceCount, 1)
		XCTAssertEqual(pattern?.iterationCount, 3)
	}

	func testLearnFailureIncrements() throws {
		var lib = FailurePatternLibrary()
		lib.learnFailure(modelId: "m1", context: "ctx-a", iterationCount: 3)
		lib.learnFailure(modelId: "m1", context: "ctx-a", iterationCount: 5)

		let pattern = lib.patterns["m1-ctx-a"]
		XCTAssertEqual(pattern?.occurrenceCount, 2)
		XCTAssertEqual(pattern?.iterationCount, 5) // max of 3 and 5
	}

	func testRuleGenerationThreshold() throws {
		var lib = FailurePatternLibrary()
		// Need occurrenceCount >= 3 to generate rule
		lib.learnFailure(modelId: "m1", context: "ctx-a", iterationCount: 2)
		lib.learnFailure(modelId: "m1", context: "ctx-a", iterationCount: 2)
		// Only 2 occurrences, no rule yet (ruleGenerationThreshold = 3)

		let rules = lib.getPreventionRules(for: "m1")
		// After 2 occurrences, no rule should exist yet
		XCTAssertTrue(rules.isEmpty)

		lib.learnFailure(modelId: "m1", context: "ctx-a", iterationCount: 2)
		// 3 occurrences → rule generated
		let rules2 = lib.getPreventionRules(for: "m1")
		XCTAssertFalse(rules2.isEmpty)
	}

	func testRulePriorityCritical() throws {
		var lib = FailurePatternLibrary()
		// 5+ occurrences → critical priority
		for _ in 0..<5 {
			lib.learnFailure(modelId: "m2", context: "heavy", iterationCount: 2)
		}
		let rules = lib.getPreventionRules(for: "m2")
		XCTAssertTrue(rules.contains { $0.priority == .critical })
	}

	func testRulePriorityModerate() throws {
		var lib = FailurePatternLibrary()
		// 3-4 occurrences → moderate priority
		lib.learnFailure(modelId: "m3", context: "light", iterationCount: 2)
		lib.learnFailure(modelId: "m3", context: "light", iterationCount: 2)
		lib.learnFailure(modelId: "m3", context: "light", iterationCount: 2)

		let rules = lib.getPreventionRules(for: "m3")
		XCTAssertTrue(rules.contains { $0.priority == .moderate })
	}

	func testModelFiltering() throws {
		var lib = FailurePatternLibrary()
		lib.learnFailure(modelId: "m1", context: "a", iterationCount: 2)
		lib.learnFailure(modelId: "m1", context: "a", iterationCount: 2)
		lib.learnFailure(modelId: "m1", context: "a", iterationCount: 2)
		lib.learnFailure(modelId: "m2", context: "b", iterationCount: 2)
		lib.learnFailure(modelId: "m2", context: "b", iterationCount: 2)
		lib.learnFailure(modelId: "m2", context: "b", iterationCount: 2)
		lib.learnFailure(modelId: "m2", context: "b", iterationCount: 2)

		let rules1 = lib.getPreventionRules(for: "m1")
		XCTAssertEqual(rules1.count, 1)

		let rules2 = lib.getPreventionRules(for: "m2")
		XCTAssertEqual(rules2.count, 1)

		XCTAssertTrue(lib.getPreventionRules(for: "m3").isEmpty)
	}

	func testConfidenceCappedAt10() throws {
		var lib = FailurePatternLibrary()
		// 10+ occurrences → confidence = min(n/10, 1.0) = 1.0
		for _ in 0..<10 {
			lib.learnFailure(modelId: "m4", context: "repeated", iterationCount: 1)
		}
		let rules = lib.getPreventionRules(for: "m4")
		XCTAssertTrue(rules.allSatisfy { $0.confidence <= 1.0 })
	}
}
