// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ToolHookRunner.swift — Lifecycle hooks aligned with codex-rs `HookEventName`.
///
/// Baseline: codex `codex-rs/protocol/src/protocol.rs:1510` defines 11 hook events.
/// This module implements the five ocoreai-relevant ones:
///   PreToolUse / PostToolUse / PreCompact / PostCompact / Stop
///
/// Deliberately NOT implemented (consumer-transparent for ocoreai, per the user
/// "don't pre-build speculative agent-loop abstractions" rule): UserPromptSubmit
/// (handled inline in MessageBuilder), SubagentStart / SubagentStop (delegation is
/// a prohibited architecture by user mandate), SessionStart / SessionEnd (ocoreai
/// has no codex-style cold-session rollout this pass).
///
/// Design discipline (aligned to the ocoreai codebase, NOT a parallel runtime):
/// - Payload arguments is the tool's **JSON string**, exactly what
///   `ToolRegistry.call(arguments: String)` holds at the chokepoint. No parallel
///   `JSONValue` type (would collide with `MLXLMCommon.JSONValue` in files that
///   import both modules).
/// - Verdict is a simple enum: `.allow` / `.deny(reason)` / `.ask(reason)`.
/// - Handlers are `@Sendable (HookContext) async -> HookVerdict` closures — flat,
///   no external command execution, no MCP-server dependency, exactly testable.
///
/// `.ask` semantics: no approval UI surface exists yet, so callers treat `.ask`
/// the same as a soft deny for the *current* call unless they wire an approval
/// prompt. Documented so the gate is a hard boundary until then.

import Foundation

// MARK: - Event

/// Hook events — subset of codex `HookEventName` relevant to ocoreai's real chokepoints.
public enum HookEvent: String, Sendable, CaseIterable, Codable, Hashable {
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"
    case stop = "Stop"
}

// MARK: - Context

/// One hook fire. All value types → trivially `Sendable`, `Equatable` for test asserts.
public struct HookContext: Sendable, Equatable {
    public let event: HookEvent
    /// Tool name for tool events (`nil` for compact/stop events).
    public let toolName: String?
    /// JSON-encoded tool arguments (empty string when none).
    public let arguments: String
    /// Tool result for `PostToolUse` (nil otherwise).
    public let result: String?
    /// Sanitized error message when a tool failed (nil otherwise).
    public let error: String?
    /// Session identity propagated to audit/observability handlers (nil-safe).
    public let sessionId: String?

    public init(
        event: HookEvent,
        toolName: String? = nil,
        arguments: String = "",
        result: String? = nil,
        error: String? = nil,
        sessionId: String? = nil
    ) {
        self.event = event
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.error = error
        self.sessionId = sessionId
    }
}

/// Decision a `PreToolUse` handler returns.
public enum HookVerdict: Sendable, Equatable {
    case allow
    case deny(reason: String)
    case ask(reason: String)

    public var isAllow: Bool {
        if case .allow = self { return true }
        return false
    }
}

// MARK: - Matcher

/// Matches a tool name against a hook matcher expression.
///
/// Grammar (mirrors codex `MatcherGroup`, simplified since ocoreai has no MCP/plugin
/// manifest system and matches by tool name only):
/// - `nil` / `""` / `"*"`     — match every tool
/// - `"a,b,c"`               — comma-separated exact names
/// - `"read_file"`, `"*write"` — `*` as wildcard glob
///
/// Case-sensitive (ocoreai tool names are canonical camelCase).
public struct ToolMatcher: Sendable, Equatable, Codable {
    public let patterns: [String]

    public init(_ patterns: String) {
        let parts =
            patterns
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        self.patterns = parts.filter { !$0.isEmpty }
    }

    public init(patterns: [String]) {
        self.patterns = patterns.filter { !$0.isEmpty }
    }

    public var matchesEverything: Bool {
        patterns.isEmpty || patterns.allSatisfy { $0 == "*" }
    }

    public func matches(_ toolName: String) -> Bool {
        if patterns.isEmpty { return true }
        return patterns.contains { matchOne($0, toolName) }
    }

    private func matchOne(_ pattern: String, _ name: String) -> Bool {
        if pattern == "*" || pattern.isEmpty { return true }
        if !pattern.contains("*") { return pattern == name }
        // Simple glob → anchored regex (NSRegularExpression / ICU dialect).
        // `*` → `.*`; non-alphanumeric chars are escaped with a backslash
        // (so `.` in the pattern is a literal dot, NOT a regex any-char).
        let safe: Set<Character> = ["-", "_"]
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map {
            part -> String in
            var out = ""
            for c in part {
                out += (c.isLetter || c.isNumber || safe.contains(c)) ? String(c) : "\\" + String(c)
            }
            return out
        }
        let regex = "^" + parts.joined(separator: ".*") + "$"
        return name.range(of: regex, options: .regularExpression) != nil
    }
}

// MARK: - Hook

/// One registered hook (events + matcher + handler).
///
/// `events` declares which hook events this hook responds to.
/// A `nil` matcher (or `Hook.any`) applies to every tool name.
///
/// Event-filtering (per codex semantics):
/// - `evaluatePreToolUse` only fires hooks whose `events` contains `.preToolUse`
/// - `firePostToolUse` only fires hooks whose `events` contains `.postToolUse`
///
/// This prevents an observation hook (`.postToolUse`) from being called during
/// the veto pass (`.preToolUse`) and vice versa.
public struct Hook: Sendable {
    public let events: Set<HookEvent>
    public let matcher: ToolMatcher?
    public let handler: @Sendable (HookContext) async -> HookVerdict

    public init(
        events: Set<HookEvent> = Set(HookEvent.allCases),
        matcher: ToolMatcher? = nil,
        handler: @Sendable @escaping (HookContext) async -> HookVerdict
    ) {
        self.events = events
        self.matcher = matcher
        self.handler = handler
    }

    /// Hook that responds to all events with no tool-name restriction.
    public static func any(handler: @Sendable @escaping (HookContext) async -> HookVerdict) -> Hook
    {
        .init(matcher: nil, handler: handler)
    }

    /// `PreToolUse`-only hook — fires only during the veto pass.
    public static func pre(
        matcher: ToolMatcher? = nil,
        handler: @Sendable @escaping (HookContext) async -> HookVerdict
    ) -> Hook {
        .init(events: [.preToolUse], matcher: matcher, handler: handler)
    }

    /// `PostToolUse`-only hook — fires only during observation.
    public static func post(
        matcher: ToolMatcher? = nil,
        handler: @Sendable @escaping (HookContext) async -> HookVerdict
    ) -> Hook {
        .init(events: [.postToolUse], matcher: matcher, handler: handler)
    }

    public static func matching(
        _ pattern: String, handler: @Sendable @escaping (HookContext) async -> HookVerdict
    ) -> Hook {
        .init(matcher: ToolMatcher(pattern), handler: handler)
    }
}

// MARK: - Runner

/// Fire hooks for an event and collect `PreToolUse` verdicts.
///
/// Thread-safety: `hooks` is `let` after init → struct is `Sendable`, no locks.
///
/// Matcher application is uniform everywhere: a hook fires only if its matcher
/// (when present) matches the target tool name.
///
/// **Scope (deliberate, per user "禁投机式 API 大构建" rule)** — only the
/// two codex hook events with a real ocoreai chokepoint in this pass are
/// implemented:
///   - ``HookEvent/preToolUse`` → veto at `ToolRegistry.call` (the single
///     chokepoint every LLM tool call routes through)
///   - ``HookEvent/postToolUse`` → observation on both success/failure paths
///
/// Not implemented (consumer-transparent for ocoreai): ``HookEvent/preCompact``,
/// ``HookEvent/postCompact`` (would require a new ChatHandler dependency),
/// ``HookEvent/stop`` (would require an EngineInference change), and the two
/// codex subagent events (delegation is a prohibited architecture by user mandate).
public struct ToolHookRunner: Sendable {
    public let hooks: [Hook]

    public init(hooks: [Hook]) {
        self.hooks = hooks
    }

    public static let empty = ToolHookRunner(hooks: [])

    public var isEmpty: Bool { hooks.isEmpty }

    // MARK: - Tool gating (PreToolUse)

    /// Evaluate `PreToolUse` hooks for a tool call.
    /// - `.deny` on any hook → short-circuit to `.deny`
    /// - `.ask` on any hook (no `.deny`) → short-circuit to first `.ask`
    /// - all `.allow` / no hooks → `.allow`
    public func evaluatePreToolUse(
        toolName: String,
        arguments: String = "",
        sessionId: String? = nil
    ) async -> HookVerdict {
        let ctx = HookContext(
            event: .preToolUse, toolName: toolName,
            arguments: arguments, sessionId: sessionId)
        var pendingAsk: HookVerdict? = nil
        for hook in hooks
        where hook.events.contains(.preToolUse)
            && (hook.matcher.map({ $0.matches(toolName) }) ?? true)
        {
            let verdict = await hook.handler(ctx)
            switch verdict {
            case .allow:
                continue
            case .deny(let reason):
                return .deny(reason: reason)
            case .ask(let reason):
                if pendingAsk == nil { pendingAsk = .ask(reason: reason) }
            }
        }
        return pendingAsk ?? .allow
    }

    // MARK: - Observation (PostToolUse)

    public func firePostToolUse(
        toolName: String,
        arguments: String = "",
        result: String? = nil,
        error: String? = nil,
        sessionId: String? = nil
    ) async {
        let ctx = HookContext(
            event: .postToolUse, toolName: toolName,
            arguments: arguments, result: result, error: error, sessionId: sessionId)
        for hook in hooks
        where hook.events.contains(.postToolUse)
            && (hook.matcher.map({ $0.matches(toolName) }) ?? true)
        {
            _ = await hook.handler(ctx)
        }
    }
}
