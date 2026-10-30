// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! ToolProseLedger.swift — whether a checkpoint's own chat template already declares tools.
//!
//! ### Why this exists (AGENTS.md invariant 2 + policy 3, measured 10-20 by probe 16)
//! A declared tool used to reach the model twice: this server appended
//! `Available tools:\n## Tool: <name>\nDescription: …` to the system message
//! (`Handlers/MessageBuilder.swift` Phase 5), *and* upstream fed the same `ChatSession.tools`
//! into `tokenizer.applyChatTemplate(messages:tools:)` (mlx-swift-lm
//! `Libraries/MLXVLM/Models/Gemma4.swift:2235`), whose template renders every entry as
//! `<|tool>declaration<tool|>` inside the system turn. vllm and sglang have one seam — the
//! schema goes into the template and nowhere else (`entrypoints/openai/chat_utils.py`,
//! `srt/entrypoints/openai/protocol.py`) — so the second copy is ours.
//!
//! The cost is not stylistic. On `mlx-community/gemma-4-e2b-it-4bit` (temp 0, probe 16) one
//! declared tool grew the *delivered* `usage.prompt_tokens` by 116 while this server's own
//! tokenizer attributed 65 to the prose it wrote; a second tool added 52 again, so the
//! duplication is per-entry rather than a one-off template overhead.
//!
//! ### Why the answer is per checkpoint, never per family
//! Whether dropping our prose leaves the model with a declaration at all is a fact about the
//! checkpoint's template, not about its architecture: a template that ignores the `tools`
//! variable sees only our prose, and skipping then would silently un-declare every tool.
//! So the ledger records a *measured* answer — render the same one-message feed twice, with
//! and without a probe tool, and see whether the token count grows — following the
//! evidence-shaped discipline of ``VideoDeliveryLedger``: a config key that implies
//! capability is exactly the kind of claim this repo refuses to publish.
//!
//! ### Honest direction
//! Unmeasured means inject: today's behaviour, unchanged, with the log line saying it was
//! never measured. Skipping the prose is only ever allowed on a measurement that says the
//! template renders tools, and the measurement is dropped when the model unloads, because the
//! answer belongs to weights that are no longer here.

/// What this server may do with its own `## Tool:` prose for one model.
///
/// Closed vocabulary — a publisher must never invent a fourth value.
enum ToolProseMode: String, Encodable, Equatable, Sendable, CaseIterable {
    /// Measured: this checkpoint renders `tools` itself, so the prose would be a copy.
    case skippedTemplateRenders

    /// Measured: this checkpoint's template ignores `tools`, so the prose is the declaration.
    case injectedTemplateIgnores

    /// Never measured (model not loaded here, or its template refused the probe feed).
    case injectedUnmeasured

    /// The only rule the assembly may consult.
    var injectsProse: Bool {
        self != .skippedTemplateRenders
    }

    /// The one sentence both narrators print — load time (`declaredTools` nil) and every turn
    /// that declares tools. Wording on the mode, not at the call sites, because two
    /// publishers that each assemble their own sentence drift into two truths, and probes
    /// that grep one shape silently stop matching the other.
    /// - Parameter proseBlocks: how many `## Tool:` blocks this turn actually wrote. On the
    ///   line because the system message grows for other reasons too — the action directive
    ///   `SystemPromptBuilder` adds whenever a turn has tools is ~215 chars and names nothing
    ///   — so a probe that reads growth alone cannot tell a duplicate declaration from
    ///   ordinary prompt text. This number can.
    func logLine(modelId: String, declaredTools: Int? = nil, proseBlocks: Int? = nil) -> String {
        var line = "Tool prose \(rawValue) for \(modelId)"
        if let declaredTools {
            line += " with \(declaredTools) declared tool(s)"
        }
        if let proseBlocks {
            line += ", \(proseBlocks) ## Tool: block(s) written"
        }
        return "\(line) — \(reasonPhrase)"
    }

    /// Why this mode, in the words the log publishes. On the ledger, not at the call site,
    /// so two publishers cannot drift into two explanations of one decision.
    var reasonPhrase: String {
        switch self {
        case .skippedTemplateRenders:
            "this checkpoint's chat template renders tools itself (measured: a probe tool grew the rendered prompt), so the ## Tool: prose would be a second copy of the same declaration"
        case .injectedTemplateIgnores:
            "this checkpoint's chat template ignores the tools variable (measured), so the ## Tool: prose is the only declaration the model can see"
        case .injectedUnmeasured:
            "not measured for this model in this process (not loaded, or its template rejected the probe feed) — keeping the ## Tool: prose"
        }
    }

    /// The measurement behind the mode, without the action attached: `nil` means this
    /// process never measured it, which is a different fact from "measured: it ignores".
    var measuredTemplateRendersTools: Bool? {
        switch self {
        case .skippedTemplateRenders: true
        case .injectedTemplateIgnores: false
        case .injectedUnmeasured: nil
        }
    }
}

// MARK: - Wire line

/// Per-model tool-prose disposition, published on
/// `GET /v1/models/:model/kv-cache` as `toolProse`.
///
/// Why a row here at all: whether a turn carries one declaration of a tool or two is a fact
/// about the checkpoint that a client cannot otherwise see, and `## Tool:` prose costs real
/// context (measured 10-20 by probe 16: +116 delivered prompt tokens for the first declared
/// tool on gemma-4-e2b-it-4bit, +52 for the second). Before this row the only place the
/// answer existed was a log line — invisible to an HTTP client, and uncorroborable against
/// the engine's own decision.
struct ToolProseObservation: Encodable, Equatable, Sendable {
    /// `skipped_template_renders` | `injected_template_ignores` | `injected_unmeasured`.
    ///
    /// snake_case for the wire, while the log line prints ``ToolProseMode/rawValue``
    /// (camelCase). Two renderings of one value, both derived here rather than typed out at
    /// a call site — so probe 16 can require the wire and the log to say the same thing in
    /// their own vocabularies, and a drift between them fails instead of going unnoticed.
    let mode: String
    /// The measurement alone, so a caller can tell "renders" from "we never checked"
    /// instead of reading `injected_unmeasured` as if it were a measured negative.
    let templateRendersTools: Bool?
    /// Why this mode — the ledger's own sentence, so the wire and the log never explain
    /// one decision with two different reasons.
    let reason: String

    private enum CodingKeys: String, CodingKey {
        case mode, templateRendersTools, reason
    }

    /// Hand-written so `templateRendersTools` is present and `null` when unmeasured. The
    /// synthesized conformance calls `encodeIfPresent` for optionals and drops the key
    /// outright, which would leave a client choosing between "the engine never measured this"
    /// and "this build forgot to publish it" — the same ambiguity this repo refuses on the
    /// decode side (`AnthropicMessageRequest.stream`, 10-13).
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        if let templateRendersTools {
            try container.encode(templateRendersTools, forKey: .templateRendersTools)
        } else {
            try container.encodeNil(forKey: .templateRendersTools)
        }
        try container.encode(reason, forKey: .reason)
    }
}

extension ToolProseMode {
    /// The wire spelling of this mode. Derived, never stored: a fourth value cannot be
    /// invented at a publisher because there is nowhere on this type to put it.
    var wireMode: String {
        switch self {
        case .skippedTemplateRenders: "skipped_template_renders"
        case .injectedTemplateIgnores: "injected_template_ignores"
        case .injectedUnmeasured: "injected_unmeasured"
        }
    }

    /// The wire line for this mode, built in one place.
    var observation: ToolProseObservation {
        ToolProseObservation(
            mode: wireMode,
            templateRendersTools: measuredTemplateRendersTools,
            reason: reasonPhrase)
    }
}

/// The decision, as a pure function of the one fact that decides it.
///
/// Separate from the ledger so the gate can pin the truth table without a model, a tokenizer,
/// or a Metal device.
enum ToolProseRule {
    /// `nil` is not "false": an unmeasured checkpoint keeps the existing behaviour rather
    /// than silently un-declaring its tools on the strength of a render that never ran.
    static func decide(templateRendersTools: Bool?) -> ToolProseMode {
        switch templateRendersTools {
        case .some(true): .skippedTemplateRenders
        case .some(false): .injectedTemplateIgnores
        case .none: .injectedUnmeasured
        }
    }
}

/// Per-model record of that measurement, keyed by model id.
///
/// A shared actor (the `SteerQueue`/`PerceptionEngine` shape) because the fact is produced at
/// model-load time in `EnginePool` and consumed at message-assembly time in `MessageBuilder`;
/// threading it through four handler call sites would give the rule one home and four callers
/// that can forget it. `forget(modelId:)` runs on unload, so a claim never outlives its
/// weights.
actor ToolProseLedger {
    static let shared = ToolProseLedger()

    private(set) var modes: [String: ToolProseMode] = [:]

    /// Records what the checkpoint did when handed a tool, and returns the mode the caller
    /// should log. Re-measuring the same model replaces the answer (reload = new weights).
    @discardableResult
    func record(modelId: String, templateRendersTools: Bool?) -> ToolProseMode {
        let mode = ToolProseRule.decide(templateRendersTools: templateRendersTools)
        modes[modelId] = mode
        return mode
    }

    /// What the assembly may assume about this model. Unknown is `injectedUnmeasured`:
    /// the default is the behaviour that existed before this ledger, not a guess.
    func mode(modelId: String) -> ToolProseMode {
        modes[modelId] ?? .injectedUnmeasured
    }

    /// The measured fact alone, or nil when this process never measured the model — for
    /// surfaces that must distinguish "renders" from "we do not know" rather than flatten
    /// both into a default.
    func templateRendersTools(modelId: String) -> Bool? {
        modes[modelId]?.measuredTemplateRendersTools
    }

    /// The wire line for `GET /v1/models/:model/kv-cache`. An unmeasured model reports
    /// `injected_unmeasured` with `templateRendersTools: null` — the row degrades to "not
    /// measured here", never to a capability claim.
    func observation(modelId: String) -> ToolProseObservation {
        (modes[modelId] ?? .injectedUnmeasured).observation
    }

    func forget(modelId: String) {
        modes[modelId] = nil
    }

    func removeAll() {
        modes.removeAll()
    }
}
