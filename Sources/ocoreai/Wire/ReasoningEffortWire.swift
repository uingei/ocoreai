// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// Reasoning-effort wire injection.
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

    /// A value no template can mistake for a request: it is not a word from any effort
    /// table, so a template that *reads* the kwarg must react to it (render differently, or
    /// raise on validation) and a template that ignores it cannot. Naming a legal word here
    /// would make the probe depend on the word table this file deliberately does not own.
    static let probeValue = "__ocoreai_probe__"

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

    /// Refuse a demand this checkpoint measurably cannot honor, naming both exits.
    ///
    /// Shaped after codex's `unsupported_code_mode_warning` (`core/src/session/
    /// code_mode_warning.rs:6-24`): the config knob the model does not advertise, the
    /// evidence for that, then what to do — disable the knob or pick a model that advertises
    /// it. Ours refuses rather than warns because a demanded word that reaches no template is
    /// a turn spent under a belief, not a cosmetic loss.
    ///
    /// - Returns: the refusal, or nil when there is nothing to refuse — no value asked, or a
    ///   mode that never measured (`notObserved` keeps the pass-through: invariant 2 says an
    ///   unmeasured fact is not a false one).
    static func refusal(
        modelId: String, requestedValue: String?, mode: ReasoningEffortMode
    ) -> AppError? {
        guard ReasoningEffortRule.refuse(callerValue: requestedValue, mode: mode) else {
            return nil
        }
        return .invalidRequest(
            "'\(modelId)' cannot honor reasoning_effort=\"\(requestedValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")\": "
                + "\(mode.reasonPhrase), so the word is dropped before generation — the turn would answer "
                + "under a thinking-control setting this checkpoint never sees. "
                + "Omit reasoning_effort for this model, or pick one whose /v1/models row reports "
                + "reasoningEffort=\"honored\"."
        )
    }

    /// The load-time log line for one measurement — the ledger's own sentence, so the wire
    /// and the log cannot explain one decision with two different reasons.
    static func logLine(modelId: String, mode: ReasoningEffortMode) -> String {
        "Reasoning effort \(mode.rawValue) for \(modelId) — \(mode.reasonPhrase)"
    }
}
