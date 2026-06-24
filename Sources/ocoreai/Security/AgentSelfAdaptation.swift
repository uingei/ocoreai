// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AgentSelfAdaptation — Core coordinator for proactive self-adjustment
///
/// Architecture:
///   ┌─────────────────────┐
///   │ SelfAdaptationActor │  ← actor-isolated coordinator
///   │                     │
///   │  SystemHealth       │  ← multi-dimensional health score
///   │  AdaptiveThreshold  │  ← EMA-based self-learning thresholds
///   │  FailureLibrary     │  ← pattern memory & prevention rules
///   └─────────────────────┘
///
/// Integration points:
///   1. ChatHandler queries health status BEFORE inference (pre-inference gate)
///   2. SelfCorrectionPipeline feeds correction results back AFTER inference
///   3. Thresholds auto-adjust based on correction success rate (EMA)
///
/// Zero overhead when disabled — single Bool check, no allocations.

import Foundation
import Logging

// MARK: - Health Models

struct HealthDimension: Codable, Sendable {
    var name: String
    var score: Double
    var weight: Double
    var weightedScore: Double { score * weight }
}

struct SystemHealth: Codable, Sendable {
    var overallScore: Double
    var dimensions: [HealthDimension]
    var lastUpdated: Int64
    var trend: TrendDirection

    enum TrendDirection: String, Codable, Sendable {
        case improving, stable, degrading
    }

    var isHealthy: Bool { overallScore >= SelfAdaptationConfig.healthyThreshold }
    var needsAttention: Bool { overallScore < SelfAdaptationConfig.warningThreshold }

    static func initial() -> SystemHealth {
        SystemHealth(
            overallScore: 0.8,
            dimensions: [],
            lastUpdated: Int64(Date().timeIntervalSince1970),
            trend: .stable
        )
    }
}

// MARK: - Config

struct SelfAdaptationConfig: Codable, Sendable {
    static let healthyThreshold: Double = 0.7
    static let warningThreshold: Double = 0.4
    static let historyDepth = 20
    static let emAlpha = 0.15
    static let failureThreshold = 0.6
    static let maxPreventionRules = 30
    static let evalInterval: TimeInterval = 300
}

// MARK: - Actor

actor AgentSelfAdaptationActor {
    private let logger: Logger
    private var isEnabled: Bool
    private var health: SystemHealth
    private var healthHistory: [Double] = []

    private var adaptiveThreshold: AdaptiveThreshold
    private var failureLibrary: FailurePatternLibrary
    private var modelConfigurations: [String: ModelHealthProfile] = [:]

    private struct ModelHealthProfile: Codable, Sendable {
        var correctionSuccessRate: Double
        var correctionAttempts: Int
        var avgIterations: Double
        var degradationScore: Double
    }

    // MARK: - Factory

    static func create(
        enabled: Bool = true,
        initialHealth: Double = 0.8,
        log: Logger = Logger(label: "ocoreai.adaptation")
    ) -> AgentSelfAdaptationActor {
        AgentSelfAdaptationActor(enabled: enabled, healthScore: initialHealth, log: log)
    }

    static func disabled(
        log: Logger = Logger(label: "ocoreai.adaptation")
    ) -> AgentSelfAdaptationActor {
        AgentSelfAdaptationActor(enabled: false, healthScore: 1.0, log: log)
    }

    init(enabled: Bool, healthScore: Double, log: Logger = Logger(label: "ocoreai.adaptation")) {
        self.isEnabled = enabled
        self.logger = log
        self.health = SystemHealth.initial()
        self.health.overallScore = healthScore
        self.adaptiveThreshold = AdaptiveThreshold()
        self.failureLibrary = FailurePatternLibrary()
    }

    // MARK: - Pre-Inference Checks

    func preInferenceCheck(modelId: String) -> InferenceRecommendation {
        guard isEnabled else { return .proceed }

        let modelProfile = modelConfigurations[modelId]
        let isModelStressed = (modelProfile?.degradationScore ?? 1.0) > SelfAdaptationConfig.warningThreshold

        let recommendation: InferenceRecommendation
        if health.overallScore >= SelfAdaptationConfig.healthyThreshold && !isModelStressed {
            recommendation = .proceed
        } else if health.overallScore >= SelfAdaptationConfig.warningThreshold {
            recommendation = .proceedWithCaution
        } else if health.overallScore >= 0.25 {
            recommendation = .reduceQuality
        } else {
            recommendation = .deferRequest
        }

        _ = failureLibrary.getPreventionRules(for: modelId)

        logger.debug(
            "\(InferenceRecommendation.recommendationLogLabel[recommendation] ?? "?") Pre-inference check [model=\(modelId)] health=\(health.overallScore) recommendation=\(recommendation.rawValue)"
        )

        return recommendation
    }

    /// Get prevention rules to apply before inference for this model.
    func getPreventions(for modelId: String) -> [PreventionRule] {
        guard isEnabled else { return [] }
        return failureLibrary.getPreventionRules(for: modelId)
    }

    // MARK: - Post-Inference Feedback

    func reportCorrection(
        modelId: String,
        converged: Bool,
        iterations: Int,
        context: String
    ) {
        guard isEnabled else { return }

        var profile = modelConfigurations[modelId] ?? ModelHealthProfile(
            correctionSuccessRate: 0.8,
            correctionAttempts: 0,
            avgIterations: 1.0,
            degradationScore: 0.0
        )

        profile.correctionAttempts += 1

        let target = converged ? 1.0 : 0.0
        profile.correctionSuccessRate =
            profile.correctionSuccessRate * (1 - SelfAdaptationConfig.emAlpha) + target * SelfAdaptationConfig.emAlpha

        profile.avgIterations =
            profile.avgIterations * (1 - SelfAdaptationConfig.emAlpha) + Double(iterations) * SelfAdaptationConfig.emAlpha

        if !converged {
            profile.degradationScore = min(1.0, profile.degradationScore + 0.05)
        } else {
            profile.degradationScore = max(0.0, profile.degradationScore - 0.02)
        }

        modelConfigurations[modelId] = profile

        // Feed to adaptive threshold system
        adaptiveThreshold.addObservation(success: converged, iterations: iterations, context: context)

        // If failed, try to extract failure pattern
        if !converged && iterations >= SelfCorrectionPipeline.maxIterations {
            failureLibrary.learnFailure(modelId: modelId, context: context, iterationCount: iterations)
        }

        updateHealthFromModel(modelId: modelId)
    }

    // MARK: - Dynamic Threshold Queries

    func getAdaptiveThreshold(modelId: String) -> Double {
        guard isEnabled else { return 0.85 }
        return adaptiveThreshold.getThreshold(for: modelId)
    }

    func getMaxIterations(modelId: String) -> Int {
        guard isEnabled else { return SelfCorrectionPipeline.maxIterations }
        let profile = modelConfigurations[modelId]
        let degradation = profile?.degradationScore ?? 0.0

        if degradation < 0.2 { return 4 }
        if degradation > 0.7 { return 2 }
        return SelfCorrectionPipeline.maxIterations
    }

    // MARK: - System Health

    func getHealth() -> SystemHealth { health }
    func getHealthHistory() -> [Double] {
        Array(healthHistory.suffix(SelfAdaptationConfig.historyDepth))
    }

    func reportStressEvent(type: StressEventType, severity: Double) {
        guard isEnabled else { return }
        let impact = severity * 0.1
        health.overallScore = max(0.0, health.overallScore - impact)
        healthHistory.append(health.overallScore)

        logger.warning(
            "\(InferenceRecommendation.recommendationLogLabel[.proceed] ?? "?") Stress event [type=\(type.rawValue)] severity=\(severity) health=\(health.overallScore)"
        )
    }

    func periodicEvaluation() {
        guard isEnabled else { return }
        let stressCount = healthHistory.filter { $0 < SelfAdaptationConfig.warningThreshold }.count
        if stressCount < healthHistory.count / 2 {
            health.overallScore = min(1.0, health.overallScore + 0.01)
        }

        let recent = healthHistory.suffix(5)
        if recent.count >= 2, let first = recent.first, let last = recent.last {
            let diff = last - first
            if diff > 0.03 { health.trend = .improving }
            else if diff < -0.03 { health.trend = .degrading }
            else { health.trend = .stable }
        }

        health.lastUpdated = Int64(Date().timeIntervalSince1970)
        healthHistory.append(health.overallScore)
        if healthHistory.count > SelfAdaptationConfig.historyDepth {
            healthHistory.removeFirst(healthHistory.count - SelfAdaptationConfig.historyDepth)
        }
    }

    private func updateHealthFromModel(modelId: String) {
        guard let profile = modelConfigurations[modelId] else { return }
        let modelImpact = profile.correctionSuccessRate * 0.3
        health.overallScore = health.overallScore * 0.9 + modelImpact
        healthHistory.append(health.overallScore)
        if healthHistory.count > SelfAdaptationConfig.historyDepth {
            healthHistory.removeFirst(healthHistory.count - SelfAdaptationConfig.historyDepth)
        }
    }
}

// MARK: - Enums

enum InferenceRecommendation: String, Sendable {
    case proceed
    case proceedWithCaution
    case reduceQuality
    case deferRequest

    static var recommendationLogLabel: [InferenceRecommendation: String] {
        [.proceed: "▶", .proceedWithCaution: "⚠", .reduceQuality: "▼", .deferRequest: "■"]
    }
}

enum StressEventType: String, Sendable {
    case oomDowngrade
    case highLatency
    case correctionFailed
    case tokenizerError
    case memoryPressure
    case userFeedback
}
