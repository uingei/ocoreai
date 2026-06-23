// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// TimingHooks.swift — Per-request performance metrics tracking
///
/// ### Purpose:
/// Signpost-style timing hooks aligned with Apple Instruments profiler conventions.
/// Tracks per-inference-request: latency, throughput, TTFB.
///
/// ### Design:
/// - Pure Swift, no Instruments dependency
/// - Thread-unsafe — intended for single-request lifecycle on ``@MainActor``
/// - Metrics aggregated via Swift Logging metadata

import Foundation

// MARK: - Per-Request Metrics

/// Single inference request performance metrics collector.
///
/// Created per-request, logged at the end of the inference pipeline.
/// Tracks tokenization, inference, and first-token (TTFB) timing.
///
/// ### Sendable Safety:
/// Marked ``@unchecked Sendable`` because:
/// - Each instance lives within a single ``Task`` (_runInference background task)
/// - Never shared between concurrent executors — passed by-value through actor mailbox
/// - All mutable state (`var` fields) is written/read on the same executor
/// - `ContinuousClock.Instant` is inherently Sendable
/// - No reference to external shared mutable state
final class PerRequestMetrics: @unchecked Sendable {

    // MARK: - Token Counts

    /// Number of prompt (input) tokens processed
    var promptTokenCount: Int = 0

    /// Number of generated (output) tokens produced
    var generatedTokenCount: Int = 0

    /// Total token count (prompt + generated)
    var totalTokenCount: Int { promptTokenCount + generatedTokenCount }

    // MARK: - Timing

    /// Overall request start timer
    private var overallTimer: ContinuousClock.Instant?

    /// Tokenization phase duration (milliseconds)
    var tokenizationMs: Double = 0

    /// Inference phase duration (milliseconds)
    var inferenceMs: Double = 0

    /// Time to first byte / first token (milliseconds)
    var firstTokenMs: Double = 0

    /// Overall elapsed time since ``start`` was called
    var overallMs: Double {
        guard let start = overallTimer else { return 0 }
        let d = start.duration(to: ContinuousClock.now)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    // MARK: - Throughput

    /// Prompt processing throughput (tokens per second)
    var promptThroughput: Double {
        guard inferenceMs > 0, promptTokenCount > 0 else { return 0 }
        return Double(promptTokenCount) / (inferenceMs / 1000.0)
    }

    /// Generation throughput (tokens per second)
    var generationThroughput: Double {
        guard inferenceMs > 0, generatedTokenCount > 0 else { return 0 }
        return Double(generatedTokenCount) / (inferenceMs / 1000.0)
    }

    // MARK: - Lifecycle

    /// Start the metrics timer (captures ``ContinuousClock`` snapshot)
    func start() {
        precondition(overallTimer == nil, "PerRequestMetrics.start() called twice — create a new instance per request")
        overallTimer = ContinuousClock.now
    }

    /// Increment the generated token counter (call after each output token)
    func incrementGenerated() {
        generatedTokenCount += 1
    }

    // MARK: - Summary

    /// Format metrics as a human-readable summary string for logging.
    ///
    /// - Parameter modelId: Model identifier for inclusion in the log line
    /// - Returns: Formatted string with model, tokens, latency, throughput
    func summary(modelId: String) -> String {
        let total = overallMs
        return """
        [metrics] model=\(modelId) prompt=\(promptTokenCount) gen=\(generatedTokenCount) \
        total=\(String(format: "%.1f", total))ms \
        ttfb=\(String(format: "%.1f", firstTokenMs))ms \
        throughput=\(String(format: "%.1f", generationThroughput))tok/s
        """
    }
}