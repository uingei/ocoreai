// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! SamplingDomain.swift — every wire's bounded numeric knobs, checked in one place.
//!
//! Why this exists (measured 10-17): `{"max_tokens":-5}` on `/v1/chat/completions` was
//! accepted, sailed into ``SchedulerActor/dispatch()``, and `UInt64(tokenBudget)` trapped
//! there — `EXC_BREAKPOINT (SIGTRAP)`. The process died, the client got an empty reply, and
//! every other conversation on the box died with it. A trap is not a refusal: no status, no
//! `error_code`, no remediation, and nothing left running to serve the next request.
//!
//! So every numeric knob a spec bounds is checked where a wire value first becomes an
//! internal count, budget, or sampler parameter, and an out-of-domain value comes back 400
//! naming the field, the accepted range and what was sent. ``KVCacheBudget`` is the floor
//! beneath this (a caller bug anywhere else costs a rounding on a reservation, never the
//! server); this file is the refusal the client can read.
//!
//! Shape and wording follow vllm, the reference serving stack for both wires here:
//! `SamplingParams._verify_args` (vllm/sampling_params.py:630-712) renders
//! ``<field> must be in <range>, got <value>``, and its validation handler publishes the
//! offending field as `param` in the JSON body
//! (vllm/entrypoints/serve/exception_handling/handlers/validation.py:171-186).
//!
//! One checker, three forwarders (`ChatCompletionRequest`, `CompletionRequest`,
//! `AnthropicMessageRequest`): the wires differ in their *ranges*, not in the shape of the
//! check, so ranges are parameters and the rule is stated once — three copies of a bounds
//! list is a second and third truth waiting to drift.
import Foundation

/// One request's bounded numeric knobs, normalized so every wire shares ``SamplingDomain``.
///
/// Absent (`nil`) means "not sent", which is always in domain — the engine applies its own
/// default. Values are widened to `Double` because the DTOs mix `Float` and `Double` for
/// the same conceptual knob; comparing at the wider type keeps one rule.
struct SamplingKnobs: Sendable {
    /// A named integer knob that must be at least 1 (engine window sizes, step sizes).
    struct Count: Sendable {
        let field: String
        let value: Int
    }

    /// Output-token ceiling, if sent.
    var maxTokens: Int?
    /// Wire name to blame when ``maxTokens`` is out of domain — OpenAI has two spellings
    /// (`max_completion_tokens` wins where both are sent) and the message must name the one
    /// the client actually used.
    var maxTokensField: String = "max_tokens"

    /// `n`, if sent. ``nMaximum`` is nil when the endpoint honours any `n >= 1`
    /// (`/v1/completions` generates `n` passes sequentially) and 1 where one request returns
    /// exactly one choice (chat) — refusing beats accepting and under-delivering
    /// (AGENTS.md invariant 2).
    var n: Int?
    var nMaximum: Int? = nil

    var temperature: Double?
    /// The range this wire's spec publishes for `temperature` — OpenAI `0...2`, Anthropic `0...1`.
    var temperatureRange: ClosedRange<Double> = 0 ... 2

    var topP: Double?
    var topK: Int?
    /// 0 = "no top-k filter" on both wires, which is what this engine does with it
    /// (`CompositeSampler.swift:138` applies the filter only when `topK > 0`), so 0 is in
    /// domain and only a negative is not (vllm/sampling_params.py:677-681, same semantics).
    var topKMinimum: Int = 0
    var minP: Double?
    var frequencyPenalty: Double?
    var presencePenalty: Double?
    var repetitionPenalty: Double?
    var seed: Int64?
    /// Non-negative-by-spec integer knobs, listed rather than typed one-by-one so a wire can
    /// expose more of them without a new rule here.
    var counts: [Count] = []
}

/// One rejected knob: the wire path to put in `error.param`, the value as sent, and the
/// human-readable line.
struct SamplingViolation: Sendable {
    let param: String
    let value: String
    let message: String
}

enum SamplingDomain {
    /// Renders a number without a spurious `.0` (2 not 2.0), so a range reads the way the
    /// spec writes it.
    private static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int(value))
            : String(value)
    }

    private static func violation(
        _ param: String, _ value: Double, _ requirement: String
    ) -> SamplingViolation {
        let shown = number(value)
        return SamplingViolation(
            param: param, value: shown, message: "\(param) must be \(requirement), got \(shown).")
    }

    /// The first out-of-domain knob, or nil when every knob is in domain.
    static func firstViolation(_ knobs: SamplingKnobs) -> SamplingViolation? {
        if let out = knobs.maxTokens, out < 1 {
            return SamplingViolation(
                param: knobs.maxTokensField,
                value: String(out),
                message: "\(knobs.maxTokensField) must be at least 1, got \(out). "
                    + "Omit it to use the model default.")
        }
        if let n = knobs.n {
            if n < 1 {
                return SamplingViolation(
                    param: "n", value: String(n), message: "n must be at least 1, got \(n).")
            }
            if let max = knobs.nMaximum, n > max {
                return SamplingViolation(
                    param: "n",
                    value: String(n),
                    message: "n must be at most \(max), got \(n). This endpoint returns exactly "
                        + "one choice per request — send one request per completion wanted.")
            }
        }
        if let temperature = knobs.temperature,
            !knobs.temperatureRange.contains(temperature)
        {
            return violation(
                "temperature", temperature,
                "in [\(number(knobs.temperatureRange.lowerBound)), "
                    + "\(number(knobs.temperatureRange.upperBound))]")
        }
        if let topP = knobs.topP, topP <= 0 || topP > 1 {
            return violation("top_p", topP, "in (0, 1]")
        }
        if let topK = knobs.topK, topK < knobs.topKMinimum {
            return SamplingViolation(
                param: "top_k",
                value: String(topK),
                message: "top_k must be \(knobs.topKMinimum) (disable), or at least 1, got \(topK)."
            )
        }
        if let minP = knobs.minP, minP < 0 || minP > 1 {
            return violation("min_p", minP, "in [0, 1]")
        }
        for (field, value) in [
            ("frequency_penalty", knobs.frequencyPenalty),
            ("presence_penalty", knobs.presencePenalty),
        ] {
            if let value, value < -2 || value > 2 {
                return violation(field, value, "in [-2, 2]")
            }
        }
        if let penalty = knobs.repetitionPenalty, penalty <= 0 {
            return violation("repetition_penalty", penalty, "greater than zero (1.0 = no penalty)")
        }
        if let seed = knobs.seed, seed < 0 {
            return SamplingViolation(
                param: "seed",
                value: String(seed),
                message: "seed must be a non-negative integer, got \(seed).")
        }
        for count in knobs.counts where count.value < 1 {
            return SamplingViolation(
                param: count.field,
                value: String(count.value),
                message: "\(count.field) must be at least 1, got \(count.value).")
        }
        return nil
    }
}
