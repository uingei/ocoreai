// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! MCPTimeouts.swift — one home for how long an external MCP server may take to answer.
//!
//! ### What was wrong (found 10-21 by reading the consumers, not the declaration)
//! `MCPBridgeConfig.serverTimeoutSeconds` — documented as "外部 server 响应超时（秒）",
//! default 10 — had **zero consumers**. `git grep serverTimeoutSeconds -- Sources` returned
//! its declaration, its `self.x = x`, and nothing else. What actually bounded an external
//! reply was the literal `15` written twice in `MCPStdioClient`: `withTimeout(seconds: 15)`
//! around `waitForResponse`, and a second absolute deadline
//! (`ContinuousClock.now + .milliseconds(15000)`) inside that same wait. So the config named a
//! knob, `MCPEndpointTests` asserted that knob's storage round-trips
//! (`config.serverTimeoutSeconds == 10` / `== 5`), and the behaviour those two lines describe
//! did not exist — invariant 1's exact failure: no gate could go red, because the value it
//! reads is not the value the code uses.
//!
//! ### Why two budgets, not one
//! `initialize` + first `tools/list` and `tools/call` bound different work: one is a
//! handshake, the other is the task. Bounding both at 15 s meant an external tool doing real
//! work — a browser action, a query, an `npx` server that cold-starts — lost its call at 15 s,
//! while this server's own shell tool is allowed 300 s (`ExecTools.maxTimeoutSeconds`). The
//! same class of agent action had a 20x tighter budget for crossing a pipe. The split and the
//! numbers follow codex `codex-mcp/src/rmcp_client.rs:110-111` (`DEFAULT_STARTUP_TIMEOUT` 30
//! s, `DEFAULT_TOOL_TIMEOUT` 300 s), which carries both per-server
//! (`config/src/mcp_types.rs:272/276` — `startup_timeout_sec`, `tool_timeout_sec`).
//!
//! ### The rule
//! An out-of-domain budget is a refusal naming field + range + value sent — never a silent
//! clamp on the wire, and never a negative deadline, which fires the instant it is computed
//! (AGENTS.md: no wire value may own the process). The consumer additionally floors the value
//! into the allowed range so a caller bug costs a rounding rather than a hang, the same
//! division as `Scheduler/KVCacheBudget.swift`.

import Foundation

/// Both external-MCP response budgets and their accepted domain, in one place.
public enum MCPTimeouts {
    /// `initialize` + initial `tools/list` (codex `DEFAULT_STARTUP_TIMEOUT`).
    public static let startupDefault: TimeInterval = 30
    /// `tools/call` (codex `DEFAULT_TOOL_TIMEOUT`).
    public static let toolDefault: TimeInterval = 300

    /// Accepted span for any explicit budget, from the wire or from `MCPBridgeConfig`.
    public static let allowedRange: ClosedRange<TimeInterval> = 1 ... 600

    /// Resolve one budget, most-specific-wins: per-endpoint override → bridge default →
    /// hard default.
    ///
    /// - Throws: ``MCPTimeoutError/outOfDomain(field:value:)`` when an explicit value lies
    ///   outside ``allowedRange``.
    public static func resolve(
        field: String, explicit: TimeInterval?, fallback: TimeInterval
    ) throws -> TimeInterval {
        guard let explicit else { return fallback }
        guard allowedRange.contains(explicit) else {
            throw MCPTimeoutError.outOfDomain(field: field, value: explicit)
        }
        return explicit
    }

    /// Consumer-side guard: no value, however it arrived, may produce a deadline in the past
    /// or a wait longer than the published ceiling.
    public static func clamped(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, allowedRange.lowerBound), allowedRange.upperBound)
    }

    /// Wire wording for a budget: `30s`, not `30.0s`.
    public static func describe(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() && seconds < 1e15
            ? "\(Int(seconds))s"
            : String(format: "%.1fs", seconds)
    }
}

/// A requested MCP response budget this server will not accept.
enum MCPTimeoutError: Error, LocalizedError, Equatable {
    /// Explicit value outside ``MCPTimeouts.allowedRange`` — refused, not clamped.
    case outOfDomain(field: String, value: TimeInterval)
    /// The key was present but not a number — named with what actually arrived.
    case notANumber(field: String, sent: String)

    var errorDescription: String? {
        switch self {
        case .outOfDomain(let field, let value):
            let range = MCPTimeouts.allowedRange
            return
                "\(field) must be between \(MCPTimeouts.describe(range.lowerBound)) and \(MCPTimeouts.describe(range.upperBound)); sent \(MCPTimeouts.describe(value))"
        case .notANumber(let field, let sent):
            return
                "\(field) must be a number of seconds between \(MCPTimeouts.describe(MCPTimeouts.allowedRange.lowerBound)) and \(MCPTimeouts.describe(MCPTimeouts.allowedRange.upperBound)); sent \(sent)"
        }
    }
}
