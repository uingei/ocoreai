// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// Reasoning-effort wire injection (2026-08-23).
//
// Qwen3.8 (and future hybrid models) read a chat-template kwarg called
// `reasoning_effort` with a codex-aligned word table
// (xhigh/medium/low — a subset of codex `ReasoningEffort`). The upstream
// library (mlx-swift-lm) provides no first-class parameter for it, and its
// `ReasoningPromptStrategy.additionalContext(forThinkingEnabled:)` only
// carries the binary thinking flag. This helper injects the caller's raw
// value into the jinja template context — wire-not-brain:
//
//   - no local enum, no local word-table mapping, no local default;
//   - the model chat template is the single source of truth for accepted
//     values (Qwen3.8 validates and raises on anything it does not support,
//     e.g. `max`/`ultra`/`light`);
//   - `enable_thinking=false` keeps the template from reading the kwarg at
//     all, so the injection is inert on off-toggle thinking;
//   - when the model gains first-class support upstream, this injection
//     point collapses into the upstream parameter (absorb, do not fork).

import Foundation

enum ReasoningEffortWire {
    /// Chat-template kwarg name consumed by model templates.
    static let key = "reasoning_effort"

    /// Merge the raw effort value into an existing template context.
    ///
    /// - Parameters:
    ///   - base: the existing context (e.g. `["enable_thinking": true]`) or
    ///     nil when no context exists yet.
    ///   - rawValue: the caller's raw value (codex words). Injected verbatim;
    ///     the model template validates it.
    /// - Returns: the merged context. Returns `base` unchanged when
    ///   rawValue is absent/empty, so `nil` stays `nil` (no behavior
    ///   change for thinking-off / no-effort traffic).
    static func context(
        _ base: [String: any Sendable]?, rawValue: String?
    ) -> [String: any Sendable]? {
        guard
            let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return base
        }
        var ctx = base ?? [:]
        ctx[key] = raw
        return ctx
    }
}
