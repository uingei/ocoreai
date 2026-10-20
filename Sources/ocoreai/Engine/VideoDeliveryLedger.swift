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
//! One seam may record: ``recordVideoDelivery`` at the normal completion of an inference
//! body, with upstream's own `promptTokenCount` as the evidence number. Two things worth
//! stating, because both were written down wrong here once (10-20, re-read against the
//! code rather than inferred from the shape of the pipeline):
//!
//!   • The lane matters. This used to record *inside* the pooled release, which is a
//!     no-op when there is no pool — the degraded CPU lane and a pool-disabled engine
//!     both run without one, and both still hand every frame to the processor. An answered
//!     video turn there published `not_observed`; probe 17 now boots a server on that lane
//!     and fails if the disclosure goes missing again.
//!   • Guided-gen and MTP are not leaks. Their branch guards require every message to
//!     carry no images, audio or video, so a turn with frames never enters them (a grammar
//!     request with media falls through to ChatSession with the constraint dropped). The
//!     earlier note here claimed those paths under-reported; they cannot carry video.
//!
//! What stays deliberately unrecorded: a turn that carried frames but produced no
//! assistant text at all. `delivered` means a turn that both took frames and answered, and
//! a turn with no answer is the honest direction to under-claim. The inverse — claiming
//! more than the engine delivered — is the defect this file exists to kill.

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

    /// Server-wide summary across every model this process has seen deliver video — the
    /// shape a surface that is not per-model (`GET /v1/capabilities`) has to publish.
    ///
    /// The wording lives here, on the ledger, for the same reason `evidence(modelId:)`
    /// does: two publishers that each assemble their own sentence drift into two truths.
    /// The aggregate counts *models* separately from turns and parts, because "one model
    /// saw three clips" and "three models saw one clip each" are different facts for a
    /// client choosing where to send a video.
    func aggregate() -> VideoDeliveryAggregate {
        Self.aggregate(deliveries)
    }

    /// Aggregate over a snapshot, so a publisher that already took one (the router took
    /// one for `/v1/models`) reuses this wording instead of recounting somewhere else.
    static func aggregate(_ deliveries: [String: VideoDeliveryRecord]) -> VideoDeliveryAggregate {
        var summary = VideoDeliveryAggregate()
        for entry in deliveries.values where entry.turns > 0 {
            summary.models += 1
            summary.turns += entry.turns
            summary.items += entry.items
        }
        return summary
    }
}

/// Cross-model video evidence for a server-wide surface.
struct VideoDeliveryAggregate: Equatable, Sendable {
    /// How many distinct models delivered video here.
    var models: Int = 0
    /// Completed video-carrying turns across those models.
    var turns: Int = 0
    /// Video parts across those turns.
    var items: Int = 0

    /// Nothing observed yet — the honest negative, not a claim of inability.
    var isEmpty: Bool { models == 0 }

    /// The sentence the aggregate publishes beside a `delivered` claim.
    var evidenceLine: String {
        "delivered across \(models) model(s) in \(turns) completed turn(s), \(items) video part(s)"
            + " on this server"
    }
}
