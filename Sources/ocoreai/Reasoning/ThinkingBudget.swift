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
    /// - Parameters:
    ///   - score: Complexity score from ``ComplexityAnalyzer``
    ///   - sessionId: Session identifier for adaptive budget tracking
    /// - Returns: System prompt scaffolding segment, or empty string for simple queries
    func scaffolding(for score: ComplexityScore, sessionId: String) -> String {
        switch score.band {
        case .simple:
            return "" // zero overhead — direct answer only
        case .medium:
            return mediumScaffold
        case .complex:
            return complexScaffold
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
        if avg > 0.8 && current < 2.0 {
            current = min(2.0, current + 0.2) // bump for consistency
        } else if avg < 0.4 && current > 0.5 {
            current = max(0.5, current - 0.15) // reduce for poor quality
        }
        multiplier[sessionId] = current
    }

    /// Get current budget multiplier for a session.
    func currentMultiplier(for sessionId: String) -> Double {
        multiplier[sessionId] ?? defaultMultiplier
    }
}

// MARK: - Scaffold Content

extension ThinkingBudget {
    /// Medium-complexity scaffold — standard reasoning chain.
    private var mediumScaffold: String {
        """
    ## Reasoning Protocol
    Before responding:
    1. PERCEIVE: Restate the core intent in one sentence.
    2. REASON: Outline your approach and key assumptions.
    3. ACT: Execute with clear structure.
    
    If the user's question is straightforward, answer directly without these sections.
    """
    }

    /// Complex-complexity scaffold — deep reasoning + verification.
    private var complexScaffold: String {
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
}
