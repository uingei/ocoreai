// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! ToolCallDeliveryLedger.swift — what this process has *seen* a model do with tools.
//!
//! A client that posts `tools[]` and gets back a paragraph of markdown prose instead of
//! `tool_calls` has its agent loop dead on arrival, and until now nothing on any
//! discovery surface said so: `/v1/models` reported video (`VideoDeliveryLedger`) and
//! prefix reuse (`PrefixReuseLedger`) but said nothing about the one capability a coding
//! agent is judged on. Measured 10-18 on `mlx-community/gemma-4-e2b-it-4bit`: a request
//! declaring `get_weather` answered with a fenced JSON block naming the tool, while
//! `finish_reason` said `stop` — prose where a call belonged.
//!
//! So this is evidence-shaped, following the two ledgers above: the value is a closed
//! vocabulary keyed by what a completed turn in *this* process did, never a capability
//! read off an architecture name. `not_observed` means only that no tool-declaring turn
//! has run here yet — it is not a verdict on whether the model can call functions.
//!
//! `prose_only` is deliberately narrow. Small models mention tool names in ordinary
//! sentences all the time, and a surface that called that a dialect failure would
//! over-claim in the other direction. A turn counts as prose-only only when the answer
//! carries call *shape* — a declared tool name together with the key vocabulary of a
//! call object (`name`/`arguments`/`parameters`/`tool_name`/`params`) — and nothing
//! parsed. That is a fact about the bytes we served, not a guess about intent.

/// What one tool-declaring turn produced.
enum ToolCallTurnOutcome: String, Sendable, Equatable {
    /// The turn came back as structured `tool_calls` the client can execute.
    case parsed
    /// No call parsed, but the answer text carries a declared tool name inside
    /// call-shaped JSON — the client's agent loop would read it as an answer.
    case proseOnly
    /// Tools were declared and the model answered without any call shape — ordinary
    /// behaviour for a question that needs no tool, so it is evidence of neither.
    case noCall
}

/// One model's measured tool-call history in this process.
struct ToolCallDeliveryRecord: Encodable, Equatable, Sendable {
    /// Completed turns that declared at least one tool to the model.
    var declaredTurns: Int = 0
    /// Turns delivered as structured `tool_calls`.
    var parsedTurns: Int = 0
    /// Turns where the call stayed in the prose (see ``ToolCallTurnOutcome``).
    var proseTurns: Int = 0
    /// Tool names that actually came back in `tool_calls` (deduplicated).
    var calledNames: [String] = []

    /// The sentence a discovery surface publishes beside the status, so the claim
    /// ships with how it was earned. Lives on the record because two publishers that
    /// each assemble their own wording drift into two truths.
    var evidenceLine: String {
        if parsedTurns > 0 {
            var line =
                "delivered \(parsedTurns) structured tool_call turn(s) in \(declaredTurns) "
                + "tool-declaring turn(s)"
            if !calledNames.isEmpty {
                line += ", called: \(calledNames.sorted().joined(separator: ", "))"
            }
            return line + " on this server"
        }
        if proseTurns > 0 {
            return
                "no structured tool_calls in \(declaredTurns) tool-declaring turn(s); "
                + "\(proseTurns) of them answered in prose carrying a declared tool name "
                + "on this server"
        }
        return "\(declaredTurns) tool-declaring turn(s), none produced a tool call on this server"
    }
}

/// Per-model tool-call disclosure, keyed by model id.
///
/// A value type held under `EnginePool`'s actor isolation (like
/// ``VideoDeliveryLedger``/``PrefixReuseLedger``): no globals, and an unload drops the
/// claim together with the weights.
struct ToolCallDeliveryLedger: Sendable {
    /// Closed vocabulary — the wire must never invent a fourth value.
    static let statusParsed = "parsed"
    static let statusProseOnly = "prose_only"
    static let statusNotObserved = "not_observed"

    /// Key vocabulary of a call object: keys a model writes when it is *writing a
    /// call*, as opposed to mentioning a tool in a sentence.
    static let callShapeKeys: [String] = [
        "\"name\"", "\"arguments\"", "\"parameters\"", "\"tool_name\"", "\"params\"",
    ]

    private(set) var deliveries: [String: ToolCallDeliveryRecord] = [:]

    mutating func record(modelId: String, outcome: ToolCallTurnOutcome, calledNames: [String] = [])
    {
        var entry = deliveries[modelId] ?? ToolCallDeliveryRecord()
        entry.declaredTurns += 1
        switch outcome {
        case .parsed:
            entry.parsedTurns += 1
            for name in calledNames where !entry.calledNames.contains(name) {
                entry.calledNames.append(name)
            }
        case .proseOnly:
            entry.proseTurns += 1
        case .noCall:
            break
        }
        deliveries[modelId] = entry
    }

    func record(modelId: String) -> ToolCallDeliveryRecord? {
        deliveries[modelId]
    }

    /// What the surface may say about this model.
    ///
    /// `parsed` wins over `prose_only` because one delivered call proves the whole
    /// chain (declaration → model → parser → wire) works; `prose_only` is what a
    /// client needs to know when nothing ever parsed. A model with only `noCall`
    /// turns stays `not_observed`: an answered question proves nothing either way.
    func status(modelId: String) -> String {
        Self.status(of: deliveries[modelId])
    }

    /// Status for a record taken out of a snapshot. The wire layer reads the
    /// dictionary (`/v1/models` takes one snapshot for a whole page), so the
    /// vocabulary is derived here rather than re-spelled at each publisher.
    static func status(of record: ToolCallDeliveryRecord?) -> String {
        guard let record else { return statusNotObserved }
        if record.parsedTurns > 0 { return statusParsed }
        if record.proseTurns > 0 { return statusProseOnly }
        return statusNotObserved
    }

    /// Evidence line for the discovery surface, or nil when there is nothing to back.
    func evidence(modelId: String) -> String? {
        guard let entry = deliveries[modelId], entry.declaredTurns > 0 else { return nil }
        return entry.evidenceLine
    }

    mutating func forget(modelId: String) {
        deliveries[modelId] = nil
    }

    mutating func removeAll() {
        deliveries.removeAll()
    }

    /// Server-wide summary for a surface that is not per-model (`GET /v1/capabilities`).
    /// Models are counted separately from turns: "one model called three times" and
    /// "three models called once" are different facts for a client choosing a backend.
    func aggregate() -> ToolCallDeliveryAggregate {
        Self.aggregate(deliveries)
    }

    /// Aggregate over a snapshot, so a publisher that already took one reuses this
    /// wording instead of recounting somewhere else.
    static func aggregate(_ deliveries: [String: ToolCallDeliveryRecord])
        -> ToolCallDeliveryAggregate
    {
        var summary = ToolCallDeliveryAggregate()
        for entry in deliveries.values where entry.declaredTurns > 0 {
            summary.models += 1
            summary.declaredTurns += entry.declaredTurns
            summary.parsedTurns += entry.parsedTurns
            summary.proseTurns += entry.proseTurns
        }
        return summary
    }

    /// Did a tool-declaring turn deliver a call, keep it in prose, or say nothing?
    ///
    /// `parsed` is decided by the caller (it is a fact about the response we built);
    /// this helper only classifies the prose case, and does so from the two things the
    /// wire actually has: the answer text and the names the client declared.
    static func classifyTurn(text: String, declaredNames: [String]) -> ToolCallTurnOutcome {
        guard !declaredNames.isEmpty else { return .noCall }
        let lowered = text.lowercased()
        guard Self.callShapeKeys.contains(where: { lowered.contains($0) }) else { return .noCall }
        let namesTheCall = declaredNames.filter {
            text.range(of: $0, options: .caseInsensitive) != nil
        }
        return namesTheCall.isEmpty ? .noCall : .proseOnly
    }
}

/// Cross-model tool-call evidence for a server-wide surface.
struct ToolCallDeliveryAggregate: Equatable, Sendable {
    /// How many distinct models had tool-declaring traffic here.
    var models: Int = 0
    /// Tool-declaring turns across those models.
    var declaredTurns: Int = 0
    /// Turns delivered as `tool_calls`.
    var parsedTurns: Int = 0
    /// Turns where the call stayed in prose.
    var proseTurns: Int = 0

    /// Nothing observed yet — the honest negative, not a claim of inability.
    var isEmpty: Bool { models == 0 }

    /// The sentence the aggregate publishes beside the status.
    var evidenceLine: String {
        "delivered \(parsedTurns) structured tool_call turn(s) across \(models) model(s) "
            + "in \(declaredTurns) tool-declaring turn(s), \(proseTurns) left in prose"
            + " on this server"
    }
}
