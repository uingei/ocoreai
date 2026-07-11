// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ThinkingTelemetry — post-inference quality signal emitter for ThinkingBudget calibration.
///
/// Problem: ThinkingBudget.recordQuality() is defined but never called — the
/// adaptive budget multiplier never deviates from 1.0, making the adaptive
/// thinking-scaffold system a no-op.
///
/// This module sits between the inference completion point and ThinkingBudget,
/// computing a heuristic quality score from observable inference signals:
///   - Complexity vs actual output (did the model engage with the task?)
///   - Iteration count / tool usage (multi-turn tool calls = higher engagement)
///   - Finish reason (stop vs max_tokens vs timeout)
///   - Error state (error = 0.0 quality)
///
/// The quality signal is recorded per-session, enabling adaptive calibration
/// of the thinking budget multiplier for future requests in the same session.
///
/// Design: Stateless pure function — no actors, no mutable state.
/// Call once at the end of the inference pipeline (stream or non-stream).

import Logging

// MARK: - Quality Signal

/// Inference result signals used to compute a quality heuristic.
struct ThinkingQualityInput {
    /// Complexity analyzer score (0.0 = simple, 1.0 = complex)
    let complexity: Double
    
    /// Normalized output length signal (0.0 = very short, 1.0 = substantial)
    /// Caller should pass outputTokens / maxTokens as a rough proxy.
    let outputLength: Double
    
    /// Number of agent loop iterations (1 = single inference, >1 = multi-turn)
    let iterationCount: Int
    
    /// Number of tool calls executed across all iterations (0 = text-only)
    let toolCallCount: Int
    
    /// How inference terminated
    let finishReason: String
}

/// Post-inference quality signal emitter.
///
/// Computes a heuristic quality score (0.0–1.0) from inference signals
/// and dispatches it to ``ThinkingBudget`` for adaptive calibration.
///
/// ### Integration points:
/// - ChatHandler nonStream (L560): after agentResult + self-correction
/// - ChatHandler stream (L898): after self-correction task
/// - DirectInferenceClient.stream (L280): after streaming loop
/// - DirectInferenceClient.complete (L420): after agentResult or tokenStream
enum ThinkingTelemetry {
    
    /// Log a quality signal for a session.
    ///
    /// Call this at the end of an inference pipeline (stream or non-stream)
    /// to close the ThinkingBudget calibration loop.
    ///
    /// - Parameters:
    ///   - input: Observable inference signals (or use convenience overloads below)
    ///   - sessionId: Session identifier for per-user adaptive tracking
    ///   - budget: ``ThinkingBudget`` actor instance
    @discardableResult
    static func signal(
        input: ThinkingQualityInput,
        sessionId: String,
        budget: ThinkingBudget
    ) async -> Double {
        let quality = await computeQuality(input)
        await budget.recordQuality(quality, for: sessionId)
        return quality
    }
    
    /// Compute a heuristic quality score (0.0–1.0) from inference signals.
    ///
    /// Scoring dimensions (weighted):
    ///   1. **Finish reason** (50%): stop=1.0, max_tokens=0.6, others=<0.3
    ///   2. **Complexity engagement** (30%): complex tasks that produced substantial output score higher
    ///   3. **Tool engagement** (20%): tool use on complex tasks indicates productive behavior
    ///
    /// Edge cases:
    ///   - Error/timeout finishes → 0.0
    ///   - Single iteration with no tools → neutral (quality depends on length + finish reason)
    ///   - Multi-turn with tools → positive signal if output is substantial
    private nonisolated static func computeQuality(_ input: ThinkingQualityInput) -> Double {
        // Fail-fast: error/timeout = no quality
        let reason = input.finishReason.lowercased()
        if reason.contains("error") || reason.contains("timeout") || reason.contains("cancelled") {
            return 0.0
        }
        
        // Dimension 1: Finish reason score (50% weight)
        let finishScore: Double = switch input.finishReason.lowercased() {
        case "stop", "complete":
            1.0
        case let s where s.contains("max"):
            0.6  // hit max_tokens — partial output
        default:
            0.2  // unknown reason — conservative
        }
        
        // Dimension 2: Complexity engagement score (30% weight)
        // Complex queries with substantial output = high quality
        // Simple queries with any output = acceptable (don't penalize brevity for simple tasks)
        let complexity: Double = input.complexity
        let outputLength: Double = input.outputLength
        let engagementScore: Double
        
        if complexity > 0.67 {
            // Complex task — output should be substantial
            engagementScore = max(0.3, outputLength)
        } else if complexity > 0.33 {
            // Medium task — moderate output expected
            engagementScore = min(1.0, max(0.3, outputLength * 1.2))
        } else {
            // Simple task — even brief output is acceptable
            engagementScore = min(1.0, max(0.5, outputLength + 0.2))
        }
        
        // Dimension 3: Tool engagement score (20% weight)
        // Tool calls on complex tasks indicate productive multi-turn behavior
        let toolScore: Double
        if input.toolCallCount > 0 && input.iterationCount > 1 {
            // Multi-turn with tools — good signal (cap at 5 tools to avoid bonus farming)
            toolScore = min(1.0, Double(min(input.toolCallCount, 5)) / 5.0)
        } else if input.iterationCount > 5 {
            // Many iterations without tools — possible divergence
            toolScore = 0.3
        } else {
            // Normal single-shot or low iteration
            toolScore = 0.7  // neutral — neither good nor bad
        }
        
        // Weighted composite
        let weighted = finishScore * 0.5 + engagementScore * 0.3 + toolScore * 0.2
        
        // Clamp to [0.0, 1.0], round to 3 decimal places
        return min(1.0, max(0.0, (weighted * 1000).rounded() / 1000))
    }
}

// MARK: - Logger

private let logger = Logger(label: "ThinkingTelemetry")

// MARK: - Convenience: quality signal from AgentLoopResult

extension ThinkingTelemetry {
    /// Convenience: signal from a MessageBuilder context + inference completion signals.
    ///
    /// This is the preferred integration point — it extracts complexity from
    /// ``MessageBuilder`` and requires only the signals available at runtime.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier for per-user adaptive tracking
    ///   - complexity: ComplexityAnalyzer composite score from the request
    ///   - outputTokens: Actual output tokens generated
    ///   - maxTokens: Maximum tokens allocated (for normalization)
    ///   - iterationCount: Agent loop iterations (1 for single inference)
    ///   - toolCallCount: Tool calls across all iterations (0 if no tools)
    ///   - finishReason: Stop reason string
    ///   - budget: ThinkingBudget actor (resolve via OcoreaiEngine.shared.activeThinkingBudget)
    @discardableResult
    static func signal(
        sessionId: String,
        complexity: Double,
        outputTokens: Int,
        maxTokens: Int,
        iterationCount: Int = 1,
        toolCallCount: Int = 0,
        finishReason: String,
        budget: ThinkingBudget
    ) async -> Double {
        let input = ThinkingQualityInput(
            complexity: complexity,
            outputLength: maxTokens > 0 ? Double(outputTokens) / Double(maxTokens) : 0.5,
            iterationCount: iterationCount,
            toolCallCount: toolCallCount,
            finishReason: finishReason
        )
        return await signal(input: input, sessionId: sessionId, budget: budget)
    }
    
    /// Extract quality signals from an ``AgentLoopResult`` and inject into ThinkingBudget.
    @discardableResult
    static func signal(
        result: AgentLoopResult,
        maxTokens: Int,
        complexity: Double,
        sessionId: String,
        budget: ThinkingBudget
    ) async -> Double {
        await signal(
            sessionId: sessionId,
            complexity: complexity,
            outputTokens: result.totalTokens,
            maxTokens: maxTokens,
            iterationCount: result.iterationCount,
            toolCallCount: result.iters.reduce(0) { $0 + $1.toolN },
            finishReason: result.finishReason,
            budget: budget
        )
    }
}
