// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SelfCorrectionPipelineTests.swift — Three-phase self-correction pipeline
///
/// Coverage: Phase 1 bypass, CorrectionTrace serialization, memory event conversion,
/// rule critique result, and config defaults.

import Testing
import Foundation
import Logging
@testable import ocoreai

@Suite("SelfCorrectionPipeline Configuration")
struct PipelineConfigTests {
    @Test("max iterations is 3")
    func maxIterations() {
        #expect(SelfCorrectionPipeline.maxIterations == 3)
    }

    @Test("bypass threshold is 0.85")
    func bypassThreshold() {
        #expect(SelfCorrectionPipeline.bypassThreshold == 0.85)
    }
}

@Suite("SelfCorrectionPipeline Configuration")
struct PipelineBypassTests {
    @Test("bypassThreshold config value is 0.85")
    func bypassThresholdValue() {
        #expect(SelfCorrectionPipeline.bypassThreshold == 0.85)
    }
}

@Suite("CorrectionTrace Models")
struct CorrectionTraceTests {
    @Test("correction phases have correct raw values")
    func phaseRawValues() {
        #expect(CorrectionPhase.phase1RuleBased.rawValue == "phase1RuleBased")
        #expect(CorrectionPhase.phase2Reflection.rawValue == "phase2Reflection")
        #expect(CorrectionPhase.phase3ContextRewrite.rawValue == "phase3ContextRewrite")
        #expect(CorrectionPhase.converged.rawValue == "converged")
        #expect(CorrectionPhase.failed.rawValue == "failed")
    }

    @Test("trace to memory event preserves data")
    func toMemoryEvent() {
        let trace = CorrectionTrace(
            originalPrompt: "test prompt here",
            modelResponse: "test response",
            phasesAttempted: [.phase1RuleBased, .phase2Reflection],
            finalPhase: .converged,
            iterations: 2,
            converged: true,
            timestamp: 1234567890
        )
        let event = trace.toMemoryEvent(sessionId: 99)
        #expect(event.sessionId == 99)
        #expect(event.context == "self_correction")
        #expect(event.memoryType == .pattern)
        #expect(event.resolution == .resolved)
        #expect(event.tags.contains("self-correction"))
        #expect(event.tags.contains("converged"))
    }

    @Test("trace to memory event — failed resolution")
    func toMemoryEventFailed() {
        let trace = CorrectionTrace(
            originalPrompt: "test",
            modelResponse: "bad response",
            phasesAttempted: [.phase1RuleBased, .phase2Reflection, .phase3ContextRewrite],
            finalPhase: .failed,
            iterations: 3,
            converged: false,
            timestamp: 999
        )
        let event = trace.toMemoryEvent(sessionId: 1)
        #expect(event.resolution == .workaround)
    }

    @Test("rule critique result structure")
    func ruleCritiqueResult() {
        let result = RuleCritiqueResult(
            passes: true,
            confidence: 0.9,
            issues: [],
            domain: "math"
        )
        #expect(result.passes)
        #expect(result.confidence == 0.9)
        #expect(result.issues.isEmpty)
        #expect(result.domain == "math")
    }
}
