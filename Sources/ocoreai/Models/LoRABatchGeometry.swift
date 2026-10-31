// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! LoRABatchGeometry.swift — the wire rule for LoRA batch geometry: a client integer below 1
//! never reaches the batch iterator.
//!
//! ### Why this exists (AGENTS.md: no wire value may own the process)
//! Upstream cuts a batch as `(index ..< min(index + batchSize, count))` (`LoraTrain.swift:43-45`)
//! and validates nothing about `batchSize`. A negative value inverts that range's bounds and the
//! `Range` precondition traps; 0 yields an empty batch, so `maxLength` is 0 and
//! `precondition(maxLength >= 2)` at `:49` traps. Either way the process dies mid-request, on both
//! `POST /v1/models/evaluate` and `POST /v1/models/train`, from an ordinary JSON integer — the same
//! family as the 1-token sample (`LoRASampleDomain`) and `{"max_tokens":-5}` on 10-17.
//!
//! `max_batches` is refused for a quieter reason that still costs a caller an answer: upstream reads
//! it as `batchCount != 0 && iteration + 1 >= batchCount` (`:237-239`), so a negative scores exactly
//! one batch and reports no error — and `EvalSummary.measured` treats only a positive as a cap, so a
//! negative would make the body claim batches the run skipped. 0 stays legal and means "no cap",
//! which is upstream's meaning and the documented default.
//!
//! ### One home
//! The rule and its wording are here; each face reports them the only way its response can — the
//! eval face answers `AppError.invalidParameter` so the body carries `error.param`, the train face
//! streams a `type:"error"` chunk. Both ask before loading a model: a request this cheap to refuse
//! must not cost a model load first.

enum LoRABatchGeometry {

    /// The smallest batch that yields a batch.
    static let minimumBatchSize = 1

    /// Which of the two numbers failed, so the wording can name the consequence rather than a range.
    enum Rule: Equatable {
        case batchSize
        case cap
    }

    struct Violation: Equatable {
        let rule: Rule
        /// The key as the client wrote it, so the refusal points at a field they sent.
        let field: String
        /// The value that arrived, quoted rather than described.
        let arrived: Int
    }

    /// The first unusable geometry, in the order the engine consumes it.
    ///
    /// `maxBatches` is nil for a face with no cap on the wire (`/v1/models/train` bounds its
    /// validation pass with `validation_batches`, which is a different promise).
    static func firstViolation(
        batchSize: Int,
        batchSizeField: String = "batch_size",
        maxBatches: Int? = nil,
        maxBatchesField: String = "max_batches"
    ) -> Violation? {
        if batchSize < minimumBatchSize {
            return Violation(rule: .batchSize, field: batchSizeField, arrived: batchSize)
        }
        if let maxBatches, maxBatches < 0 {
            return Violation(rule: .cap, field: maxBatchesField, arrived: maxBatches)
        }
        return nil
    }

    /// Names the key, quotes what arrived, and says what to send instead.
    static func message(for violation: Violation) -> String {
        switch violation.rule {
        case .batchSize:
            return
                "\(violation.field) must be >= \(minimumBatchSize); \(violation.arrived) builds an empty or inverted batch range inside the engine and takes the process with it."
        case .cap:
            return
                "\(violation.field) must be 0 for no cap, or a positive count; \(violation.arrived) would silently score one batch."
        }
    }
}
