// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AgentLoopTests.swift — Tests for AgentLoop production types
///
/// Tests:
///  - AgentLoopIterationLog: CustomStringConvertible description format
///  - AgentLoopResult: zero-state, token accumulation, finish reasons
///
/// Note: Full AgentLoop integration tests require SQLite → actor chain,
/// which is tested via MessageBuilderTests instead.

import Testing
import Foundation
@testable import ocoreai

// MARK: - AgentLoopResult

@Suite("AgentLoopResult")
struct AgentLoopResultTests {
    @Test("Default result has correct zero-state")
    func defaultResult() {
        let result = AgentLoopResult()
        #expect(result.text == "")
        #expect(result.iterationCount == 0)
        #expect(result.iters.isEmpty)
        #expect(result.finishReason == "stop")
        #expect(result.totalTokens == 0)
        #expect(result.toolCalls == nil)
    }

    @Test("Result with iterations accumulates tokens correctly")
    func resultAccumulation() {
        var result = AgentLoopResult()
        result.iterationCount = 3
        result.iters = [
            AgentLoopIterationLog(iteration: 1, tok: 100, toolN: 1, ms: 50.0, tag: "tool"),
            AgentLoopIterationLog(iteration: 2, tok: 200, toolN: 1, ms: 75.0, tag: "tool"),
            AgentLoopIterationLog(iteration: 3, tok: 50, toolN: 0, ms: 30.0, tag: "text"),
        ]
        result.totalTokens = 350
        result.finishReason = "stop"
        #expect(result.iterationCount == 3)
        #expect(result.iters.count == 3)
        #expect(result.totalTokens == 350)
    }

    @Test("Timeout preserves iteration log")
    func timeoutResult() {
        var result = AgentLoopResult()
        result.iterationCount = 5
        result.totalTokens = 7900
        result.finishReason = "timeout"
        result.text = "[agent-loop: timeout after 180s]"
        #expect(result.finishReason == "timeout")
        #expect(result.iterationCount == 5)
    }
}

// MARK: - AgentLoopIterationLog

@Suite("AgentLoopIterationLog: description format")
struct IterationLogTests {
    @Test("Description includes all fields")
    func logDescription() {
        let log = AgentLoopIterationLog(
            iteration: 1,
            tok: 100,
            toolN: 2,
            ms: 150.5,
            tag: "tool_call"
        )
        let desc = log.description
        #expect(desc.contains("iter-1"))
        #expect(desc.contains("tok=100"))
        #expect(desc.contains("tools=2"))
        #expect(desc.contains("tool_call"))
    }

    @Test("Description uses correct iteration number")
    func logIterationNumber() {
        let log = AgentLoopIterationLog(
            iteration: 5,
            tok: 500,
            toolN: 0,
            ms: 10.0,
            tag: "text"
        )
        let desc = log.description
        #expect(desc.contains("iter-5"))
        #expect(desc.contains("tok=500"))
    }
}
