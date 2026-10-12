// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ContextWindowPolicy — the single honest source for "how many tokens does this
/// model's window hold", and where that number came from.
///
/// ### Why this exists (proven gap, 2026-10-12)
/// ocoreai already READS the window: `ModelStore.contextLength(weightsDir:)`
/// parses `max_context_length` → `max_position_embeddings` → `n_ctx` (top level,
/// then `text_config`) and `/v1/models` publishes it as `contextLength`, and the
/// models page formats it via `ModelID.contextString` ("131K"). Locally proven on
/// `~/.ocoreai/models/mlx-community/gemma-4-e2b-it-4bit/config.json`:
/// `text_config.max_position_embeddings = 131072`.
///
/// What ocoreai never did was USE that number. Every budget consumer — the chat
/// watermark (`ChatView.contextWatermark`), the model-facing `get_context_remaining`
/// tool (`ContextStatusStore`), auto-compaction and the 400 wall
/// (`ChatHandler` Phase 3.5 / `DirectInferenceClient.enforceContextWindow`) — gates
/// on ONE value: `EnginePool.getSamplingConfig(modelId:).maxContextWindow`, which is
/// `nil` until a human issues an HTTP `PATCH {"max_context_window": N}`.
/// There was no UI that set it (grep `maxContextWindow` in `Sources/ocoreai/UI/` was
/// 0 hits before the Params-sheet card landed — see "Where this is surfaced" below).
/// So out of the box, on a 131072-token model, the truthful answers were
/// "unknown": the meter stayed hidden, the agent was told it had
/// "unknown tokens left", compaction never fired, and an oversized prompt walked
/// straight into the engine instead of a clean wall.
///
/// ### First principles
/// 1. The context window is a PROPERTY OF THE MODEL, not a user preference. The app
///    must default to the truth it already read, and only deviate on an explicit
///    human override. (LM Studio / Bionic behave this way: the window is inherited
///    from the model card and shown, not requested — observed product behaviour,
///    not re-verified against their documentation in this session.)
/// 2. Provenance must survive the resolution. A number the user set and a number the
///    model declared are different claims, so provenance travels with the value on
///    `ResolvedContextWindow.source` and is logged at the wall
///    (`ChatHandler.swift:434` message + `:439` `windowSource` metadata).
///    Where this is surfaced to a human (landed 10-12): the Params sheet renders
///    `"131K · from model"` vs `"32K · set by you"`
///    (`ModelParamsView.swift:333`, resolved via `ModelManager.swift:452` →
///    `EnginePool.effectiveContextWindow`, so GUI and engine read ONE parser) and
///    the chat watermark carries the same label (`ChatView.swift:690`).
///    STILL open: `/v1/models` publishes only the bare declared number
///    (`contextLength`, `ChatCompletionsRouter.swift:176`), so an HTTP client
///    cannot tell auto-detected from hand-configured — stated as open rather than
///    claimed as done.
/// 3. Unknown stays unknown. A model with no parsable window reports `nil`, never a
///    fabricated default (codex `unknown` path; the existing honesty contract).
///
/// ### Decision status — partially taken; the RAM clamp is still OWNER'S CALL
/// CHANGELOG (09-28 session-watermark entry) explicitly reserved this behaviour:
/// "从本地 config.json `max_position_embeddings` 自动解窗口 = 独立产品决策（连带
/// 默认 400 墙 + 规则压缩 blast radius），未静默做, 留拍板." Inheriting the
/// declared window ARMS two surfaces that were inert while the cap was `nil`:
/// rule compaction and the HTTP 400 wall at `ChatHandler.swift:452`. There is no
/// memory-based clamp between the model's declared window and what this machine can
/// actually hold (`Scheduler/` budgets admissions in MB — `AdmissionGate.swift:131`
/// — and never sizes the window), so a 131072-token prompt is now reachable where
/// it previously was not. The resolution itself IS wired into the request path in
/// this tree and is now visible and adjustable by a human (Params sheet + watermark),
/// so a user can lower the cap before an oversized prompt ever reaches the engine.
/// What remains the OWNER'S CALL is the sizing policy on top of it: whether the app
/// should ALSO clamp an inherited window to what this machine can hold. That number
/// is deliberately not invented here — see CHANGELOG 10-12 (有效上下文窗口).
///
/// ### Upstream reference
/// Mirrors `mlx-swift-lm` `KVCacheLayerStatus.CapacitySource`
/// (`.modelDefined` = architecture declares the bound, `.requested` = caller asked
/// for it, `.unbounded` = no bound) — the same provenance axis, applied one level up
/// to the session window instead of the per-layer cache bound. Vocabulary reused
/// deliberately: `modelDefined` / `requested`.
import Foundation

// MARK: - Provenance

/// Where a resolved context window came from.
enum ContextWindowSource: String, Sendable, Hashable {
    /// A human set it (`PATCH max_context_window` / the Params sheet override).
    case requested
    /// The model declared it (`config.json`, via `ModelStore.contextLength`).
    case modelDefined
    /// Nothing declares a window — report no number rather than invent one.
    case unknown
}

// MARK: - Resolved window

/// A context window plus the claim that justifies it.
struct ResolvedContextWindow: Sendable, Hashable {
    /// Tokens available to prompt + completion. `nil` = genuinely unknown.
    let tokens: Int?
    let source: ContextWindowSource

    /// What the model itself declares, kept even when an override wins, so a UI can
    /// say "you set 32K; the model declares 131K" instead of hiding the difference.
    /// `nil` when nothing was declared for this model.
    let declared: Int?

    /// `declared` defaults to `nil` so a caller that only has the resolved number
    /// (an engine reply, a test fixture) can build one without inventing a claim
    /// about what the model said.
    init(tokens: Int?, source: ContextWindowSource, declared: Int? = nil) {
        self.tokens = tokens
        self.source = source
        self.declared = declared
    }

    /// Tokens as an `Int` when known, `0` when unknown — for consumers that need a
    /// single numeric surface (e.g. `ModelID.maxContext`, whose `contextString`
    /// already renders 0 as "no badge").
    var tokensOrZero: Int { tokens ?? 0 }

    var isKnown: Bool { tokens != nil }
}

// MARK: - Policy

enum ContextWindowPolicy {
    /// Resolve the effective window: explicit override wins, else the model's own
    /// declaration, else unknown.
    ///
    /// Non-positive values are treated as absent: `0`/negative cannot come from a
    /// real `config.json` (`ModelStore.contextLength` filters `> 0`) and a
    /// `PATCH {"max_context_window": 0}` is a client bug, not a zero-token model —
    /// honouring it would silently disable every budget surface.
    ///
    /// - Parameters:
    ///   - override: `ModelSamplingConfig.maxContextWindow` for this model, if set.
    ///   - declared: `ModelStore.contextLength` for this model's weights, if parsable.
    static func resolve(override: Int?, declared: Int?) -> ResolvedContextWindow {
        if let override, override > 0 {
            return ResolvedContextWindow(tokens: override, source: .requested, declared: declared)
        }
        if let declared, declared > 0 {
            return ResolvedContextWindow(
                tokens: declared, source: .modelDefined, declared: declared)
        }
        return ResolvedContextWindow(tokens: nil, source: .unknown, declared: nil)
    }

    /// Locate a user override for `modelId` in a per-model config table, matching
    /// BOTH id spellings: the Params sheet and `PATCH` may address a model by its
    /// bare canonical id (`org/repo`) while the pool key carries an `hf:`/`mscope:`
    /// prefix, or the reverse. Matching only one spelling turns one override into
    /// two silently different configs — the same id-space tearing that
    /// `ModelManager.mergeLocalModels` fixes for the models list.
    ///
    /// Lookup order is deterministic and documented: the id exactly as given, then
    /// its canonical form (`ModelStore.normalizeModelId`), then each prefixed form.
    /// A bare id can address two hubs at once (`hf:org/repo` and `mscope:org/repo`
    /// are different models); the first hit in that order wins rather than leaving
    /// the caller with an unanswerable tie, and `ModelOverridePrecedenceTests`
    /// pins the choice so a future reorder is a deliberate, reviewed change.
    static func overrideTokens<T>(
        in overrides: [String: T], for modelId: String, extract: (T) -> Int?
    ) -> Int? {
        for key in candidateKeys(for: modelId) {
            if let hit = overrides[key].flatMap(extract) { return hit }
        }
        return nil
    }

    /// The id spellings a config table may be keyed by, in lookup order.
    ///
    /// The prefix vocabulary mirrors what `ModelStore.normalizeModelId` strips
    /// (`ModelStore.swift:96-101`: `hf:` / `huggingface:` / `mscope:`;
    /// `ModelIdentity.swift:6` records that this set is duplicated across the
    /// repo). Used here for LOOKUP only — never to mint an id, which stays the
    /// job of `ModelIdentity.prefixedId`.
    static func candidateKeys(for modelId: String) -> [String] {
        let canonical = ModelStore.normalizeModelId(modelId)
        var keys = [modelId]
        if canonical != modelId { keys.append(canonical) }
        for prefix in ["hf:", "huggingface:", "mscope:"] {
            let prefixed = prefix + canonical
            if !keys.contains(prefixed) { keys.append(prefixed) }
        }
        return keys
    }

    // MARK: - Human-facing surface (Params sheet / watermark)

    /// Token count rendered the way the models page already renders it
    /// (`ModelID.contextString`: 131072 -> "131K"), so one number never looks like
    /// two different numbers depending on which screen reads it.
    static func shortTokens(_ tokens: Int) -> String {
        tokens >= 1_000 ? "\(tokens / 1_000)K" : "\(tokens)"
    }

    /// Where the displayed number came from, in words a human can read. `nil` when
    /// the window is unknown — the surfaces that hide the number hide the caption
    /// too, rather than captioning a budget that does not exist.
    static func provenanceLabel(for resolved: ResolvedContextWindow) -> String? {
        switch resolved.source {
        case .modelDefined: return StringKey.contextWindowFromModel.l
        case .requested: return StringKey.contextWindowSetManually.l
        case .unknown: return nil
        }
    }

    /// Parse a window a human typed into the Params sheet: `32768`, `32k`, `1M`
    /// (case-insensitive), thousands separators tolerated.
    ///
    /// Empty, unparseable, and non-positive input all return `nil`, which means
    /// *inherit from the model* — never "zero tokens". Honouring `0` would turn
    /// every budget surface off while looking like a configured cap.
    ///
    /// Overflowing input returns `nil` — a window that cannot be represented cannot
    /// be honoured, and trapping here would be a crash. The boundary is exactly
    /// Int64: `999999999999m` (≈1.05e18) still fits and is honoured as typed,
    /// while `9999999999999m` (≈1.05e19) does not fit and is refused. Whether a
    /// huge-but-representable window should additionally be clamped to what this
    /// machine can hold is a separate, undecided sizing question (see this file's
    /// decision status) — it is NOT silently decided here.
    static func parseOverride(_ text: String) -> Int? {
        let cleaned =
            text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty else { return nil }
        var multiplier = 1
        var digits = cleaned
        if cleaned.hasSuffix("k") {
            multiplier = 1_024
            digits = String(cleaned.dropLast())
        } else if cleaned.hasSuffix("m") {
            multiplier = 1_024 * 1_024
            digits = String(cleaned.dropLast())
        }
        guard
            let value = Int(digits.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0
        else { return nil }
        let scaled = value.multipliedReportingOverflow(by: multiplier)
        guard !scaled.overflow, scaled.partialValue > 0 else { return nil }
        return scaled.partialValue
    }
}
