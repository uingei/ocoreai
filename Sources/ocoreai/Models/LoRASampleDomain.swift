// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! LoRASampleDomain.swift — the wire rule for LoRA dataset samples: a sample that encodes
//! to fewer than two tokens is a refusal, never a crash.
//!
//! ### Why this exists (AGENTS.md: no wire value may own the process)
//! LoRA predicts every token from the ones before it, so a batch whose longest sample is a
//! single token has nothing to predict: upstream shapes its targets at `maxLength - 1`, i.e.
//! zero, and mlx traps deep inside the core — the same family as `{"max_tokens":-5}` taking
//! the whole box down on 10-17. mlx-swift-lm #683 (upstream `bb0d5b0`, 10-20) added a
//! pre-flight to `LoRATrain.train`; `LoRATrain.evaluate` is still unguarded at that
//! revision, and ocoreai puts **both** on the wire (`POST /v1/models/train`,
//! `POST /v1/models/evaluate`). So the rule lives at our seam, and covers both faces.
//!
//! ### One home
//! The decision (what count is acceptable, and what the client is told) is here. The two
//! faces differ only in how they report it: the train face streams an SSE `type:"error"`
//! chunk because its response is a stream, the eval face answers
//! `AppError.invalidParameter` so the body carries `error.param` naming the exact element.
//!
//! ### Measured, not assumed
//! The token count comes from the caller's tokenizer — the same `Tokenizer` the batch
//! iterator will use — never from `TokenEstimate`: a heuristic must not decide whether an
//! accepted request survives its own engine (invariant 2: the surface promises what the
//! engine delivers).

enum LoRASampleDomain {

    /// A sample needs one token to read and one to predict.
    static let minimumTokensPerSample = 2

    struct Violation: Equatable {
        /// Where the sample came from, in the wire's own key words (`dataset`,
        /// `trainingData`, `validationData`), so the refusal points at a field the client sent.
        let dataset: String
        let index: Int
        let tokenCount: Int
    }

    /// The first unusable sample, or nil when every sample can be trained on.
    static func firstViolation(
        dataset: [String], label: String, tokenCount: (String) -> Int
    ) -> Violation? {
        for (index, text) in dataset.enumerated() {
            let count = tokenCount(text)
            if count < minimumTokensPerSample {
                return Violation(dataset: label, index: index, tokenCount: count)
            }
        }
        return nil
    }

    /// Names the field, the position, what arrived, and what to send instead.
    static func message(for violation: Violation) -> String {
        let field = "\(violation.dataset)[\(violation.index)]"
        let noun = violation.tokenCount == 1 ? "token" : "tokens"
        let arrived = "encodes to \(violation.tokenCount) \(noun)"
        let need = "each sample needs >= \(minimumTokensPerSample)"
        return "\(field) \(arrived); \(need) — one to read, one to predict."
    }
}
