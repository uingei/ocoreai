// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation
import Testing

@testable import ocoreai

#if os(macOS)

// MARK: - Mock Clock for Testing

/// A mock clock that allows controlling time in tests.
///
/// `@unchecked Sendable`: the only stored property is a value-type `Instant`
/// mutated exclusively on the main actor by tests.
final class MockClock: TimingClock, @unchecked Sendable {
    private var currentInstant: ContinuousClock.Instant

    init() {
        self.currentInstant = ContinuousClock.now
    }

    var now: ContinuousClock.Instant {
        currentInstant
    }

    /// Advances time by the specified duration.
    func advance(by duration: Duration) {
        currentInstant = currentInstant.advanced(by: duration)
    }
}

// `PerformanceMetrics`, `StatsStorage`, `InstrumentsProfiler` are
// `@available(macOS 27.0, *)` — but the Swift Testing macros `@Suite`/`@Test`
// REFUSE to expand on a type or function that is itself marked `@available`
// ("Attribute 'Suite' cannot be applied to this structure because it has been
// marked '@available'"). So the suite and every test stay deployment-floor
// available, and each test body narrows availability with a leading
// `guard #available` before touching any 27-only type.
// On macOS < 27 the guard trips (test is a no-op); on macOS 27+ it falls
// through to the real assertions.
@Suite("PerformanceMetrics", .serialized)
@MainActor
struct PerformanceMetricsTests {
    @Test("Reset clears all timing and token counts")
    func resetClearsMetrics() {
        guard #available(macOS 27.0, *) else { return }

        let metrics = PerformanceMetrics.shared
        metrics.reset()

        metrics.startOverallTiming()
        metrics.recordPromptTokens(100)
        metrics.recordGeneratedTokens(50)
        metrics.reset()

        #expect(metrics.totalTime == 0)
        #expect(metrics.generatedTokenCount == 0)
        #expect(metrics.modelLoadTime == 0)
    }

    @Test("Throughput returns zero when time is zero")
    func zeroTimeReturnsZeroThroughput() {
        guard #available(macOS 27.0, *) else { return }

        let metrics = PerformanceMetrics.shared
        metrics.reset()

        metrics.recordPromptTokens(100)
        metrics.recordGeneratedTokens(50)

        #expect(metrics.promptThroughput == 0)
        #expect(metrics.generationThroughput == 0)
    }

    @Test("Mock clock enables deterministic overall timing tests")
    func mockClockDeterministicTiming() {
        guard #available(macOS 27.0, *) else { return }

        let mockClock = MockClock()
        let metrics = PerformanceMetrics(clock: mockClock)

        metrics.startOverallTiming()
        mockClock.advance(by: .seconds(2))
        metrics.endOverallTiming()

        // Exactly 2 seconds because we control the clock
        #expect(metrics.totalTime == 2.0)
    }

    @Test("ProfileSpan populates StatsStorage and PerformanceMetrics can read it")
    func profileSpanPopulatesStatsStorage() {
        guard #available(macOS 27.0, *) else { return }

        // Create isolated storage and profiler for this test
        let storage = StatsStorage(forTesting: ())

        // Use ProfileSpan to record model load timing
        var span = InstrumentsProfiler.beginModelLoad(name: "test-model")
        // Small delay to ensure measurable time
        Thread.sleep(forTimeInterval: 0.01)  // 10ms
        span.end(storingInto: storage)

        // Check the stats directly on the isolated storage
        let stats = storage.stats(for: .modelLoad)
        #expect(stats != nil)
        #expect((stats?.totalSeconds ?? 0) > 0)
        #expect((stats?.totalSeconds ?? 0) >= 0.01)
        #expect((stats?.totalSeconds ?? 1) < 1.0)  // Sanity check
    }

    @Test("Generation throughput calculated from ProfileSpan data")
    func generationThroughputFromProfileSpan() {
        guard #available(macOS 27.0, *) else { return }

        // Create isolated storage and profiler for this test
        let storage = StatsStorage(forTesting: ())

        // Simulate extend spans (generation)
        for step in 0 ..< 10 {
            var span = InstrumentsProfiler.beginExtend(step: step)
            Thread.sleep(forTimeInterval: 0.001)  // 1ms per token
            span.end(storingInto: storage)
        }

        // Check stats directly on isolated storage
        let stats = storage.stats(for: .extend)
        #expect(stats != nil)
        #expect(stats?.count == 10)
        #expect((stats?.totalSeconds ?? 0) > 0)
    }
}

#endif
