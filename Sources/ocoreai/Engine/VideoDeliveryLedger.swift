// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! VideoDeliveryLedger.swift — what this process has *seen* a model do with video.
//!
//! `ModelObject` published nothing about video, and probe 08 measured why that is a
//! defect rather than a virtue: on `mlx-community/gemma-4-e2b-it-4bit` a clip posted as
//! a data: URL was answered correctly (`Red`/`Blue`, prompt 712 → 856 = +144 real video
//! tokens), yet `/v1/models` said nothing. Not overclaiming is necessary but not
//! sufficient — a client choosing between two local models cannot learn from the discovery
//! surface that this one sees video at all (AGENTS.md invariant 2: the surface states what
//! the engine delivered, in both directions).
//!
//! So the disclosure is evidence-shaped, following `PrefixReuseLedger`: the value is a
//! closed vocabulary keyed by what was measured *in this process*, never a guess read off
//! a config key. `processor_class` would happily tell a client that `Gemma4Processor`
//! takes `input.videos` while `Gemma4UnifiedProcessor` does not, but that is a claim
//! about a class, not about this server; until a turn carrying video completes against a
//! model here, the honest answer is `not_observed`.
//!
//! Only one seam may record: the point where a turn both carried frames and completed on
//! the standard ChatSession path (`releasePoolSlotWithAssistant`, EngineInference.swift),
//! with upstream's own `promptTokenCount` as the evidence number. Turns that end on the
//! guided-gen / MTP early release do not extend pooled history either, so they leave the
//! counter alone — an under-claim on those paths, which is the honest direction; the
//! inverse is the defect this file exists to kill.

/// One model's measured video history in this process.
struct VideoDeliveryRecord: Encodable, Equatable, Sendable {
    /// Completed turns that carried at least one video part into the model.
    var turns: Int = 0
    /// Total video parts across those turns (a turn may carry several clips).
    var items: Int = 0
    /// Prompt tokens of the most recent such turn, when the engine reported usage —
    /// the number a client can compare against its own media-free baseline.
    var lastTurnPromptTokens: Int?

    /// The sentence a discovery surface publishes beside a `delivered` claim. Lives on
    /// the record so every publisher quotes the same wording instead of re-assembling
    /// it and drifting (the ledger's own `evidence(modelId:)` delegates to this).
    var evidenceLine: String {
        var line = "delivered in \(turns) completed turn(s), \(items) video part(s)"
        if let tokens = lastTurnPromptTokens {
            line += ", last prompt_tokens \(tokens)"
        }
        return line + " on this server"
    }
}

/// Per-model video disclosure, keyed by model id.
///
/// Deliberately a value type held in `EnginePool`'s actor isolation (like
/// ``PrefixReuseLedger``): no globals, and an unload drops the claim with the weights.
struct VideoDeliveryLedger: Sendable {
    /// Closed vocabulary — the wire must never invent a fourth value.
    static let statusDelivered = "delivered"
    static let statusNotObserved = "not_observed"

    private(set) var deliveries: [String: VideoDeliveryRecord] = [:]

    mutating func record(modelId: String, items: Int, promptTokens: Int? = nil) {
        guard items > 0 else { return }
        var entry = deliveries[modelId] ?? VideoDeliveryRecord()
        entry.turns += 1
        entry.items += items
        if let promptTokens {
            entry.lastTurnPromptTokens = promptTokens
        }
        deliveries[modelId] = entry
    }

    func record(modelId: String) -> VideoDeliveryRecord? {
        deliveries[modelId]
    }

    /// What the surface may say about this model. `delivered` is a measured fact;
    /// `not_observed` means only that no video turn has completed here yet — it is not
    /// a statement that the model cannot see video.
    func status(modelId: String) -> String {
        (deliveries[modelId]?.turns ?? 0) > 0 ? Self.statusDelivered : Self.statusNotObserved
    }

    /// Evidence line for the discovery surface: how the claim was earned.
    func evidence(modelId: String) -> String? {
        guard let entry = deliveries[modelId], entry.turns > 0 else { return nil }
        return entry.evidenceLine
    }

    mutating func forget(modelId: String) {
        deliveries[modelId] = nil
    }

    mutating func removeAll() {
        deliveries.removeAll()
    }
}
