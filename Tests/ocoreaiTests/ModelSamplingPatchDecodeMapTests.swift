// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// Regression suite for the "storage + toConfig present but CodingKeys case
// missing" decode-map bug class in ModelSamplingPatch. The same silent-nil
// class that #176's repetition_penalty(_window) hit (fixed ccee9da), which a
// self-negation scan then found was also affecting 5 pre-existing PATCH keys
// (fixed 2f0070e).
//
// Bug class: a stored var on ModelSamplingPatch + a toConfig() merge + a
// downstream consumer all exist, but the JSON key is missing from the
// CodingKeys enum → JSONDecoder never maps it → the field decodes as nil
// silently (no compile error). These tests pin the key→property mapping for
// the whole penalty / context / prefill / kv family so the class cannot
// regress without a red test.
//
// Wire key names taken verbatim from the authoritative
// ModelSamplingConfig.CodingKeys (OpenAIModels.swift:872-885).

import Foundation
import Testing

@testable import ocoreai

@Suite("ModelSamplingPatch decode-map (#176 bug class — silent-nil CodingKeys)")
struct ModelSamplingPatchDecodeMapTests {

    private func patch(_ json: String) throws -> ModelSamplingPatch {
        try JSONDecoder().decode(ModelSamplingPatch.self, from: Data(json.utf8))
    }

    @Test("prefill_step_size (legacy key) decodes → prefill.stepSize")
    func prefillStepSize() throws {
        // toConfig merges the flat legacy key into the prefill struct (L929-932).
        let p = try patch(#"{"prefill_step_size": 16}"#)
        #expect(p.prefillStepSize == 16)
        #expect(p.toConfig().prefill.stepSize == 16)
        // Baseline: absent → nil, chunking untouched (.balanced).
        let absent = try patch(#"{}"#)
        #expect(absent.prefillStepSize == nil)
        #expect(absent.toConfig().prefill.stepSize == nil)
        #expect(absent.toConfig().prefill.chunking == .balanced)
    }

    @Test("max_kv_size decodes → maxKVSize (enables RotatingKVCache)")
    func maxKVSize() throws {
        let p = try patch(#"{"max_kv_size": 512}"#)
        #expect(p.maxKVSize == 512)
        #expect(p.toConfig().maxKVSize == 512)
        #expect(try patch(#"{}"#).maxKVSize == nil)
    }

    /// The stored value outlives the request, so an out-of-domain one is a state, not a bad
    /// turn: measured 11-28, `{"max_kv_size":0}` was accepted here and every later turn for that
    /// model then failed the KV-cache plan. One rule with the chat wires, one sentence.
    @Test(
        "max_kv_size keeps the chat wires' domain rule on this face",
        arguments: [0, -3]
    )
    func maxKVSizeDomain(sent: Int) throws {
        let error = try patch(#"{"max_kv_size": \#(sent)}"#).numericDomainError()
        guard case .some(.invalidParameter(let param, let message, let value)) = error else {
            Issue.record("max_kv_size \(sent) must be refused by name")
            return
        }
        #expect(param == "max_kv_size")
        #expect(value == String(sent))
        #expect(message == "max_kv_size must be at least 1, got \(sent).")
    }

    @Test("an absent or in-domain max_kv_size meets no refusal")
    func maxKVSizeDomainAccepts() throws {
        // The sibling integer knobs were each stored as 0 against a live serve on 11-28 and the
        // next turn answered, so this face still accepts them; that line is what this asserts.
        let accepted = [
            #"{}"#,
            #"{"max_kv_size": 1}"#,
            #"{"prefill_step_size":0,"repetition_context_size":0,"repetition_penalty_window":0,"#
                + #""presence_context_size":0,"frequency_context_size":0,"max_context_window":0}"#,
        ]
        for json in accepted {
            if let refusal = try patch(json).numericDomainError() {
                Issue.record("\(json) must be accepted, got: \(refusal)")
            }
        }
    }

    @Test("repetition_context_size decodes → repetitionContextSize")
    func repetitionContextSize() throws {
        let p = try patch(#"{"repetition_context_size": 40}"#)
        #expect(p.repetitionContextSize == 40)
        #expect(p.toConfig().repetitionContextSize == 40)
        #expect(try patch(#"{}"#).toConfig().repetitionContextSize == 20, "default baseline holds")
    }

    @Test("presence_context_size decodes → presenceContextSize")
    func presenceContextSize() throws {
        let p = try patch(#"{"presence_context_size": 8}"#)
        #expect(p.presenceContextSize == 8)
        #expect(p.toConfig().presenceContextSize == 8)
        #expect(try patch(#"{}"#).toConfig().presenceContextSize == 20)
    }

    @Test("frequency_context_size decodes → frequencyContextSize")
    func frequencyContextSize() throws {
        let p = try patch(#"{"frequency_context_size": 40}"#)
        #expect(p.frequencyContextSize == 40)
        #expect(p.toConfig().frequencyContextSize == 40)
        #expect(try patch(#"{}"#).toConfig().frequencyContextSize == 20)
    }

    @Test("all 5 gap keys in one PATCH body decode independently (no cross-talk)")
    func allFiveToGETher() throws {
        let p = try patch(
            #"{"prefill_step_size": 16, "max_kv_size": 512,"#
                + #" "repetition_context_size": 40, "#
                + #" "presence_context_size": 8,"#
                + #" "frequency_context_size": 40}"#
        )
        #expect(p.prefillStepSize == 16)
        #expect(p.maxKVSize == 512)
        #expect(p.repetitionContextSize == 40)
        #expect(p.presenceContextSize == 8)
        #expect(p.frequencyContextSize == 40)

        let config = p.toConfig()
        #expect(config.prefill.stepSize == 16)
        #expect(config.maxKVSize == 512)
        #expect(config.repetitionContextSize == 40)
        #expect(config.presenceContextSize == 8)
        #expect(config.frequencyContextSize == 40)

        // The #176 penalty pair still decodes alongside (no regression on the
        // primary path these were bolted onto).
        let withPenalty = try patch(
            #"{"repetition_penalty": 1.5, "repetition_penalty_window": 12,"#
                + #" "max_kv_size": 512}"#
        )
        #expect(withPenalty.repetitionPenalty == 1.5)
        #expect(withPenalty.repetitionPenaltyWindow == 12)
        #expect(withPenalty.maxKVSize == 512)
    }
}
