// oCoreAI — absorbed CoreAIVideoInput tests (unit-testable, no ANE).
// Upstream provenance (BSD-3-clause, Apple), coreai-models HEAD 5716935.

import CoreGraphics
import Foundation
import Testing

@testable import ocoreai

@Suite("CoreAIVideoInput")
struct CoreAIVideoInputTests {
    @Test("FrameSamplingStrategy.uniform exact sample times")
    func uniformExact() {
        let t = FrameSamplingStrategy.uniform(count: 8)
            .sampleTimes(forDuration: 16, videoFrameRate: 30)
        let expect: [Double] = [1, 3, 5, 7, 9, 11, 13, 15]
        #expect(t.count == 8)
        for (x, e) in zip(t, expect) { #expect(abs(x - e) < 1e-6) }
    }

    @Test("FrameSamplingStrategy.fps exact sample times (interval = 1/rate)")
    func fpsExact() {
        let t = FrameSamplingStrategy.fps(rate: 1, maxFrames: 5)
            .sampleTimes(forDuration: 10, videoFrameRate: 30)
        let expect: [Double] = [0.5, 1.5, 2.5, 3.5, 4.5]
        #expect(t.count == 5)
        for (x, e) in zip(t, expect) { #expect(abs(x - e) < 1e-6) }
    }

    @Test("FrameSamplingStrategy bounds: uniform clamps to available frames")
    func uniformClamp() {
        // 30 frames at 2s * 15fps, request 50 -> clamps to 30
        let t = FrameSamplingStrategy.uniform(count: 50)
            .sampleTimes(forDuration: 2, videoFrameRate: 15)
        #expect(t.count == 30)
    }

    @Test("FrameSamplingStrategy rejects non-positive duration")
    func rejectsZeroDuration() {
        #expect(
            FrameSamplingStrategy.uniform(count: 8)
                .sampleTimes(forDuration: 0, videoFrameRate: 30).isEmpty)
        #expect(
            FrameSamplingStrategy.fps(rate: 1, maxFrames: 4)
                .sampleTimes(forDuration: 0, videoFrameRate: 30).isEmpty)
    }

    @Test("FrameSamplingStrategy.withFrameCount preserves variant")
    func withFrameCount() {
        let u = FrameSamplingStrategy.uniform(count: 8).withFrameCount(16)
        if case .uniform(let n) = u {
            #expect(n == 16)
        } else {
            Issue.record("expected .uniform")
        }
        let f = FrameSamplingStrategy.fps(rate: 2, maxFrames: 8).withFrameCount(16)
        if case .fps(let r, let m) = f {
            #expect(r == 2 && m == 16)
        } else {
            Issue.record("expected .fps")
        }
    }
}
