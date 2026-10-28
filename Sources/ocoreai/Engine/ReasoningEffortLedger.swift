// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! ReasoningEffortLedger.swift — whether a checkpoint's own chat template reads the
//! `reasoning_effort` kwarg, measured by rendering it.
//!
//! ### Why this exists (AGENTS.md invariant 2)
//! A caller can ask for thinking control on the wire (`reasoning_effort: "high"`), and this
//! server forwards the word verbatim into the template context — `ReasoningEffortWire` holds
//! no enum and no word table on purpose, so the checkpoint is the only thing that can say
//! whether the word means anything. For the two checkpoints on this host the honest answer is
//! that it does not: neither `chat_template.jinja` names the variable, so the injected kwarg
//! cannot reach the model, and the turn still answers 200 as if thinking control had been
//! applied. Qwen3.8 sits on the other side of the same fact and raises inside jinja for a word
//! it does not accept (`ModelParamsView.swift:399`). Both faces of one unmeasured claim.
//!
//! ### Why measured by rendering, not by grepping the template
//! A template may read the kwarg through an included partial, a macro, or a default that
//! echoes it; a config key or a grep is exactly the "implies capability" claim this repo
//! refuses to publish (see `ToolProseLedger`'s rationale). So the probe hands the checkpoint
//! its own `applyChatTemplate` twice and compares what comes back.
//!
//! ### The asymmetry that decides the failure direction
//! A refusal costs a caller a turn they asked for; a silent no-op costs them an answer they
//! believed they controlled. So the probe only ever refuses on a *measured* negative, and every
//! ambiguous outcome — a template that throws on the toolless feed, a tokenizer that cannot be
//! built, a sentinel render that fails for an unrelated reason — lands on `notObserved`, which
//! keeps today's pass-through behaviour and says it was never measured.

/// What this server may claim about `reasoning_effort` for one model.
///
/// Closed vocabulary — a publisher must never invent a fourth value.
enum ReasoningEffortMode: String, Equatable, Sendable, CaseIterable {
    /// Measured: the kwarg reached the template (it changed the render, or evaluating the
    /// sentinel raised — either way the checkpoint looked at it).
    case honored

    /// Measured: the render is identical with and without the kwarg, so nothing in this
    /// checkpoint can see the caller's word.
    case templateIgnores

    /// Never measured (model not loaded here, or the probe feed could not render).
    case notObserved

    /// The wire spelling, derived here so no publisher can coin a fourth word.
    var wireMode: String {
        switch self {
        case .honored: "honored"
        case .templateIgnores: "template_ignores"
        case .notObserved: "not_observed"
        }
    }

    /// The measurement alone, or nil when this process never measured the model.
    var measuredTemplateReadsKwarg: Bool? {
        switch self {
        case .honored: true
        case .templateIgnores: false
        case .notObserved: nil
        }
    }

    /// The one sentence every narrator prints — the refusal, the log line, the `/v1/models`
    /// reason — because two publishers that each word one decision drift into two truths.
    var reasonPhrase: String {
        switch self {
        case .honored:
            "this checkpoint's chat template read the kwarg (measured: the probe value changed the rendered prompt, or evaluating it raised)"
        case .templateIgnores:
            "this checkpoint's chat template does not read the kwarg (measured: the rendered prompt is identical with and without it)"
        case .notObserved:
            "this process never rendered this checkpoint with the kwarg, so nothing is claimed either way"
        }
    }
}

/// The decision, as a pure function of the two inputs that decide it.
///
/// Separate from the ledger so the gate can pin the truth table without a model, a tokenizer
/// or a Metal device.
enum ReasoningEffortRule {
    /// A caller that asked for nothing is never refused, whatever the measurement says; a
    /// caller that asked gets a refusal only on a measured negative.
    static func refuse(callerValue: String?, mode: ReasoningEffortMode) -> Bool {
        guard let raw = callerValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return false
        }
        return mode == .templateIgnores
    }
}

/// Per-model record of that measurement, keyed by model id.
///
/// Held as a plain value inside `EnginePool` (an actor), not a `shared` global: the fact is a
/// property of weights the pool owns, so an unload drops the claim together with them — the
/// same authority call `videoDeliveries` and `toolCallDeliveries` make, and the reason
/// `/v1/models` can publish `not_observed` honestly instead of a stale `template_ignores`.
struct ReasoningEffortLedger {
    private(set) var modes: [String: ReasoningEffortMode] = [:]

    /// Records what the checkpoint did when handed the kwarg; re-measuring replaces the
    /// answer (a reload may be different weights under the same id).
    @discardableResult
    mutating func record(modelId: String, templateReadsKwarg: Bool?) -> ReasoningEffortMode {
        let mode: ReasoningEffortMode
        switch templateReadsKwarg {
        case .some(true): mode = .honored
        case .some(false): mode = .templateIgnores
        case .none: mode = .notObserved
        }
        modes[modelId] = mode
        return mode
    }

    /// Unknown is `notObserved`: the default is today's pass-through, not a guess.
    func mode(modelId: String) -> ReasoningEffortMode {
        modes[modelId] ?? .notObserved
    }

    mutating func forget(modelId: String) {
        modes[modelId] = nil
    }
}
