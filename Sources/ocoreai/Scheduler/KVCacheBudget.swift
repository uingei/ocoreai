// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! KVCacheBudget.swift — the scheduler's token→byte math, in one place and non-trapping.
//!
//! Two call sites used to multiply independently — `AdmissionGate.estimatedCost` and
//! `SchedulerActor.dispatch` — each with its own `KBPerToken = 1024` kept "aligned" by a
//! comment (a second truth waiting to drift), and each converting an `Int` token count with
//! `UInt64(...)`. That conversion *traps* on a negative.
//!
//! Measured 10-17: `{"max_tokens":-5}` on `/v1/chat/completions` produced
//! `Trace/BPT trap: 5` inside `SchedulerActor.dispatch()` — the process died, the client got
//! an empty reply, and every other conversation on the box went with it. A trap is not a
//! refusal: no status, no `error_code`, no remediation, and nothing left running to serve the
//! next request. So the domain rule lives at the wire (`ChatCompletionRequest.numericDomainError`,
//! which names the offending field and the accepted range), and this file is the floor beneath
//! it: a caller bug anywhere else costs a rounding on a reservation, never the server.
//!
//! The floor is `max(0, tokens)` rather than a precondition on purpose — production code here
//! asserts structural invariants only (AGENTS.md § Error Handling), and "some caller somewhere
//! passed a negative" is not structural.
import Foundation

enum KVCacheBudget {
    /// Fallback price of one KV token, in bytes, for a model this process has never priced.
    ///
    /// Single home for the constant both the admission gate and the dispatcher carry. It is a
    /// *floor for the unknown*, not a claim about any model: the measured price on the default
    /// checkpoint is 10,475 B/token (`KVCachePriceLedger`, probe 35), 10× this number, because
    /// KV bytes follow layers × kv heads × head dim × dtype with sliding windows and KV sharing
    /// on top — none of which a weight-quantization heuristic can see. Where a real price
    /// exists the gate uses it (`AdmissionGate.effectiveBytesPerToken`); where it does not,
    /// the decision says `fallback`.
    static let bytesPerToken: UInt64 = 1024

    /// KV-cache bytes for `tokens` at the fallback price, with a non-trapping floor at zero.
    static func bytes(_ tokens: Int) -> UInt64 {
        bytes(tokens, bytesPerToken: bytesPerToken)
    }

    /// KV-cache bytes for `tokens` at a measured price, floored at zero tokens and at the
    /// fallback price per token: a zero or negative price would admit anything, which is the
    /// failure this file exists to prevent.
    static func bytes(_ tokens: Int, bytesPerToken price: UInt64) -> UInt64 {
        UInt64(Swift.max(0, tokens)) * Swift.max(price, bytesPerToken)
    }
}
