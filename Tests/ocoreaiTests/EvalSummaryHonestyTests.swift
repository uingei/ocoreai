// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EvalSummaryHonestyTests.swift — `POST /v1/models/evaluate` may only report what it ran.
///
/// The summary is four fields a client ranks runs by, and three of them were not measurements:
/// `perplexity` carried the raw loss (mean cross-entropy per token in nats —
/// `LoraTrain.swift:242` over the per-position mean at `:199`), so it printed e²·⁰ as `2.0`;
/// `batchesEvaluated` was computed from the dataset while upstream stops at `max_batches`
/// (`LoraTrain.swift:237-239`, 0 meaning no cap), so a capped request reported coverage it had
/// skipped; and `durationSeconds` was the constant 0 for a call that spent real time.
///
/// The engine call itself needs a loaded MLX model, so what is traversed here is the derivation
/// that turned those inputs into the body — exact values, with the cap's boundary on both sides.
/// The live half ships in `scripts/probes/23-lora-seam-honesty.sh`, which reads the identity off
/// the bytes a running server sent.

import Foundation
import Testing

@testable import ocoreai

@Suite("Eval summary: a reported number is a measured one")
struct EvalSummaryHonestyTests {

    /// `measured` with the timing pinned, so each test varies one input.
    private static func summary(
        loss: Float, datasetCount: Int, batchSize: Int, maxBatches: Int
    ) -> EvalSummary {
        EvalSummary.measured(
            loss: loss, datasetCount: datasetCount, batchSize: batchSize, maxBatches: maxBatches,
            durationSeconds: 0)
    }

    @Test(
        "perplexity is exp(mean CE), never the loss under its own name",
        arguments: [
            (loss: Float(0), perplexity: 1.0), (loss: 1, perplexity: 2.718281828459045),
            (loss: 2, perplexity: 7.38905609893065), (loss: -3, perplexity: 0.0497870683678639),
        ])
    func perplexityIdentity(loss: Float, perplexity: Double) {
        let summary = Self.summary(loss: loss, datasetCount: 4, batchSize: 4, maxBatches: 0)
        #expect(abs(Double(summary.perplexity) - perplexity) < 1e-6)
        // The regression this exists for is the pass-through, which is exact for loss 0 and wrong
        // for every other value — so name the identity, do not just note a difference.
        #expect(summary.loss == loss)
    }

    @Test(
        "a capped run reports the batches it ran, not the batches the dataset could fill",
        arguments: [
            // dataset, batch_size, max_batches, batches actually scored
            (10, 4, 0, 3), (10, 4, 1, 1), (10, 4, 2, 2), (10, 4, 99, 3),
            (8, 4, 0, 2), (8, 4, 3, 2), (1, 4, 0, 1), (1, 4, 5, 1),
        ])
    func batchCount(dataset: Int, batchSize: Int, maxBatches: Int, scored: Int) {
        let summary = Self.summary(
            loss: 1, datasetCount: dataset, batchSize: batchSize, maxBatches: maxBatches)
        #expect(summary.batchesEvaluated == scored)
    }

    @Test("durationSeconds carries the measured elapsed time, not a placeholder")
    func durationIsMeasured() {
        let summary = EvalSummary.measured(
            loss: 1, datasetCount: 4, batchSize: 4, maxBatches: 0, durationSeconds: 4.25)
        #expect(summary.durationSeconds == 4.25)
    }

    @Test("the wire keeps every field, so a client reads four and not three")
    func wireKeepsEveryField() throws {
        let data = try JSONEncoder().encode(
            EvalSummary.measured(
                loss: 2, datasetCount: 10, batchSize: 4, maxBatches: 1, durationSeconds: 0.5))
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["loss"] as? Float == 2)
        #expect((root["perplexity"] as? Double).map { abs($0 - 7.38905609893065) < 1e-5 } == true)
        #expect(root["batchesEvaluated"] as? Int == 1)
        #expect(root["durationSeconds"] as? Double == 0.5)
    }
}
