// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AgentLoopTests.swift — Tests for AgentLoop production types
///
/// Tests:
///  - AgentLoopIterationLog: CustomStringConvertible description format
///
/// Note: AgentLoopResult is a plain struct with stored properties only —
/// testing default values requires no unit tests (Swift guarantees them).
/// Full AgentLoop integration is tested via MessageBuilderTests.

import Testing
import Foundation
@testable import ocoreai
import ocoreaiTestUtilities

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
