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
    /// Bytes of KV cache per generated/prompt token: 1 KB/token for bits-4 q4_0 weights.
    ///
    /// Single home for the constant both the admission gate and the dispatcher used to carry.
    static let bytesPerToken: UInt64 = 1024

    /// KV-cache bytes for `tokens`, with a non-trapping floor at zero.
    static func bytes(_ tokens: Int) -> UInt64 {
        UInt64(Swift.max(0, tokens)) * bytesPerToken
    }
}
