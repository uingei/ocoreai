// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation

/// A protocol abstracting time measurement for testability.
///
/// In production, use the default `ContinuousClock`. In tests, inject a `MockClock`.
public protocol TimingClock: Sendable {
    /// Returns the current instant.
    var now: ContinuousClock.Instant { get }
}

extension ContinuousClock: TimingClock {}

/// Performance metrics tracking for LLM inference
///
/// This class serves as a facade that:
/// 1. Pulls timing data from StatsStorage (populated by ProfileSpans)
/// 2. Keeps token count tracking (not duplicated in StatsStorage)
/// 3. Tracks overall timing for total duration calculation
@MainActor
@available(macOS 27.0, iOS 27.0, *)
public final class PerformanceMetrics {
    private let clock: any TimingClock
    private var startInstant: ContinuousClock.Instant?
    private var endInstant: ContinuousClock.Instant?

    public private(set) var promptTokenCount: Int = 0
    public private(set) var generatedTokenCount: Int = 0

    /// The shared PerformanceMetrics instance for production use.
    public static let shared = PerformanceMetrics()

    /// Creates a new PerformanceMetrics instance with the default system clock.
    public convenience init() {
        self.init(clock: ContinuousClock())
    }

    /// Creates a new PerformanceMetrics instance with a custom clock.
    ///
    /// Use this initializer in tests to inject a mock clock for deterministic time control.
    ///
    /// - Parameter clock: The clock to use for time measurement.
    public init(clock: any TimingClock) {
        self.clock = clock
    }

    // MARK: - Overall Timing (only thing still tracked locally)

    public func startOverallTiming() {
        startInstant = clock.now
    }

    public func endOverallTiming() {
        endInstant = clock.now
    }

    // MARK: - Token Counting

    /// Total number of prompt and generated tokens.
    public var totalTokenCount: Int {
        promptTokenCount + generatedTokenCount
    }

    /// Records the number of tokens in the prompt.
    public func recordPromptTokens(_ count: Int) {
        promptTokenCount = count
    }

    /// Records the number of tokens produced during generation.
    public func recordGeneratedTokens(_ count: Int) {
        generatedTokenCount = count
    }

    // MARK: - Computed Metrics (from StatsStorage)

    public var modelLoadTime: Double {
        StatsStorage.shared.stats(for: .modelLoad)?.totalSeconds ?? 0
    }

    /// Time spent loading tokenizer files
    public var tokenizerLoadTime: Double {
        StatsStorage.shared.stats(for: .tokenizerLoad)?.totalSeconds ?? 0
    }

    /// Time until tokenizer is ready (includes tokenization/Jinja template compilation)
    public var tokenizerReadyTime: Double {
        let tokenizerLoad = StatsStorage.shared.stats(for: .tokenizerLoad)?.totalSeconds ?? 0
        let tokenization = StatsStorage.shared.stats(for: .tokenization)?.totalSeconds ?? 0
        return tokenizerLoad + tokenization
    }

    /// Time spent warming up the engine (kernel compilation)
    public var warmupTime: Double {
        StatsStorage.shared.stats(for: .warmup)?.totalSeconds ?? 0
    }

    public var promptProcessingTime: Double {
        StatsStorage.shared.stats(for: .prompt)?.totalSeconds ?? 0
    }

    public var generationTime: Double {
        StatsStorage.shared.stats(for: .extend)?.totalSeconds ?? 0
    }

    public var totalTime: Double {
        guard let start = startInstant else { return 0 }
        let endToUse = endInstant ?? clock.now
        return (endToUse - start).inSeconds
    }

    /// Prompt throughput in tokens per second (first token latency)
    public var promptThroughput: Double {
        guard promptProcessingTime > 0 && promptTokenCount > 0 else { return 0 }
        return Double(promptTokenCount) / promptProcessingTime
    }

    /// Generation throughput in tokens per second (extend throughput)
    public var generationThroughput: Double {
        guard generationTime > 0 && generatedTokenCount > 0 else { return 0 }
        return Double(generatedTokenCount) / generationTime
    }

    /// Overall throughput in tokens per second
    public var overallThroughput: Double {
        guard totalTime > 0 && totalTokenCount > 0 else { return 0 }
        return Double(totalTokenCount) / totalTime
    }

    // MARK: - Lifecycle

    public func reset() {
        startInstant = nil
        endInstant = nil
        promptTokenCount = 0
        generatedTokenCount = 0
        // Also reset StatsStorage since this is a full reset
        StatsStorage.shared.reset()
    }
}

// MARK: - Duration Extension for Time

/// Upstream coreai-models CoreAIShared/Runtime/Duration+Time.swift declares
/// `Duration.inSeconds` as `package`-scoped, so ocoreai (a separate module)
/// cannot import it. Mirror the exact upstream semantics here.
extension Duration {
    /// Duration in seconds as a `Double` (seconds + attoseconds / 1e18).
    var inSeconds: Double {
        let (secs, attoseconds) = components
        return Double(secs) + Double(attoseconds) / 1e18
    }
}
