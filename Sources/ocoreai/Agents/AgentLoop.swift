// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Agent loop result types.
///
/// The agent-loop runner (enum AgentLoop + AgentLoopConfig) has been removed —
/// it had zero callers after the engine's iteration loop moved into
/// DirectInferenceClient. Only the result value types remain, consumed by
/// ThinkingTelemetry (quality-signal extraction) and observed by tests.

import Foundation

// MARK: - Result

/// Agent loop result after all iterations complete.
struct AgentLoopResult {
    /// Final text content (assistant response or tool-call marker).
    var text: String = ""

    /// Tool calls if the loop terminated with tool calls on the last iteration.
    var toolCalls: [ToolCall]? = nil

    /// How many inference runs were performed inside the loop.
    var iterationCount: Int = 0

    /// Per-iteration breakdown.
    var iters: [AgentLoopIterationLog] = []

    /// Final finish reason string.
    var finishReason: String = "stop"

    /// Total output tokens spent by inference (not including tool-execution overhead).
    var totalTokens: Int = 0
}

/// Single iteration log entry for observability.
struct AgentLoopIterationLog: CustomStringConvertible {
    let iteration: Int
    let tok: Int
    let toolN: Int
    let ms: Double
    let tag: String

    var description: String { "iter-\(iteration) tok=\(tok) tools=\(toolN) ms=\(Int(ms)) \(tag)" }
}
