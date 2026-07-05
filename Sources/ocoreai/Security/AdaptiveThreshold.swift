// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
import Foundation

// MARK: - AdaptiveThreshold (EMA-based)

struct AdaptiveThreshold {
	private(set) var correctionHistory: [ThresholdObservation]
	private(set) var baseThreshold: Double
	private(set) var modelThresholds: [String: Double]
	private let alpha: Double
	static let calibrationInterval = 50

	struct ThresholdObservation: Codable {
		let success: Bool
		let iterations: Int
		let context: String
		let timestamp: Int64
	}

	init(alpha: Double = 0.15, baseThreshold: Double = 0.85) {
		self.alpha = alpha
		self.baseThreshold = baseThreshold
		modelThresholds = [:]
		correctionHistory = []
	}

	mutating func addObservation(success: Bool, iterations: Int, context: String) {
		let observation = ThresholdObservation(
			success: success,
			iterations: iterations,
			context: context,
			timestamp: Int64(Date().timeIntervalSince1970),
		)
		correctionHistory.append(observation)
		if correctionHistory.count > 500 {
			correctionHistory.removeFirst(correctionHistory.count - 500)
		}
		if correctionHistory.count % AdaptiveThreshold.calibrationInterval == 0 {
			calibrateThreshold()
		}
	}

	func getThreshold(for modelId: String) -> Double {
		modelThresholds[modelId] ?? baseThreshold
	}

	private mutating func calibrateThreshold() {
		let recent = correctionHistory.suffix(100)
		guard !recent.isEmpty else { return }
		let successRate = Double(recent.count(where: { $0.success })) / Double(recent.count)
		let avgIterations = Double(recent.reduce(0) { $0 + $1.iterations }) / Double(recent.count)

		let adjustment: Double = if successRate > 0.9, avgIterations < 1.2 { 0.02 }
		else if successRate < 0.5 { -0.03 }
		else { 0.0 }

		baseThreshold = min(max(baseThreshold + adjustment, 0.5), 0.95)
		for modelId in modelThresholds.keys {
		if let current = modelThresholds[modelId] {
			modelThresholds[modelId] = min(max(current + adjustment * 0.5, 0.5), 0.95)
		}
	}
	}

	func getStats() -> (threshold: Double, observations: Int, recentSuccessRate: Double) {
		let recent = correctionHistory.suffix(50)
		let successRate = if !recent.isEmpty {
			Double(recent.count(where: { $0.success })) / Double(recent.count)
		} else { 0.8 }
		return (baseThreshold, correctionHistory.count, successRate)
	}
}

// MARK: - FailurePatternLibrary

struct FailurePatternLibrary {
	static let ruleGenerationThreshold = 3
	static let patternTTL: Int64 = 7 * 24 * 60 * 60

	struct FailurePattern: Codable {
		var modelId: String
		var contexts: [String]
		var occurrenceCount: Int
		var lastSeen: Int64
		var iterationCount: Int

		var isStale: Bool {
			Int64(Date().timeIntervalSince1970) - lastSeen > FailurePatternLibrary.patternTTL
		}
	}

	private(set) var patterns: [String: FailurePattern]
	private(set) var rules: [PreventionRule]

	init() {
		patterns = [:]; rules = []
	}

	mutating func learnFailure(modelId: String, context: String, iterationCount: Int) {
		let now = Int64(Date().timeIntervalSince1970)
		let key = "\(modelId)-\(context)"
		if var existing = patterns[key] {
			existing.occurrenceCount += 1
			existing.lastSeen = now
			existing.iterationCount = max(existing.iterationCount, iterationCount)
			patterns[key] = existing
		} else {
			patterns[key] = FailurePattern(
				modelId: modelId,
				contexts: [context],
				occurrenceCount: 1,
				lastSeen: now,
				iterationCount: iterationCount,
			)
		}
		regenerateRules()
	}

	func getPreventionRules(for modelId: String) -> [PreventionRule] {
		rules.filter { $0.targetModelId == modelId }
	}

	mutating func pruneStale() {
		let staleKeys = patterns.filter(\.value.isStale).map(\.key)
		for key in staleKeys {
			patterns.removeValue(forKey: key)
		}
	}

	private mutating func regenerateRules() {
		var modelContextCounts: [String: [String: Int]] = [:]
		for (_, pattern) in patterns where !pattern.isStale {
			var counts = modelContextCounts[pattern.modelId, default: [:]]
			for ctx in pattern.contexts {
				counts[ctx, default: 0] += pattern.occurrenceCount
			}
			modelContextCounts[pattern.modelId] = counts
		}
		var newRules: [PreventionRule] = []
		for (modelId, contextCounts) in modelContextCounts {
			for (context, count) in contextCounts where count >= FailurePatternLibrary.ruleGenerationThreshold {
				let priority: PreventionPriority = if count >= 5 { .critical }
				else { .moderate }
				newRules.append(PreventionRule(
					description: "avoid \(context) failures for \(modelId) (\(count)x)",
					targetModelId: modelId,
					context: context,
					priority: priority,
					confidence: min(Double(count) / 10.0, 1.0),
					createdAt: Int64(Date().timeIntervalSince1970),
				))
			}
		}
		rules = newRules
	}
}

// MARK: - PreventionRule

struct PreventionRule: Codable {
	var description: String
	var targetModelId: String
	var context: String
	var priority: PreventionPriority
	var confidence: Double
	var createdAt: Int64
}

enum PreventionPriority: String, Codable {
	case critical, moderate, informational
}
