// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// Wire-contract completeness for `ChatCompletionRequest` (08-23).
//
// Root defect fixed: `init(from:)` declared `CodingKeys` for a set of sampling
// fields (and `reasoningLevel` had none) but never decoded them — they were
// silently dropped even when present on the wire. Now decoded and asserted
// here with exact values, plus the new standard `max_completion_tokens` field
// (upstream coreai-models #187 `ServerAPITypes.swift:15/25`).
//
// JSON payloads are built via `[String: Any]` + `JSONSerialization` so no
// hand-escaped raw-string literals appear in this file (keeps values exact and
// keeps the file free of Swift raw-string edge cases).

import Foundation
import Testing

@testable import ocoreai

// MARK: - Helpers

private func baseMessages() throws -> [Message] {
    let arr: [Any] = [["role": "user", "content": "hi"]]
    let data = try JSONSerialization.data(withJSONObject: arr)
    return try JSONDecoder().decode([Message].self, from: data)
}

/// Decode a `ChatCompletionRequest` from a JSON object dict (exact wire values).
private func decodeRequest(_ extra: [String: Any]) throws -> ChatCompletionRequest {
    var payload: [String: Any] = [
        "model": "m",
        "messages": [["role": "user", "content": "hi"]],
    ]
    for (k, v) in extra { payload[k] = v }
    let data = try JSONSerialization.data(withJSONObject: payload)
    return try JSONDecoder().decode(ChatCompletionRequest.self, from: data)
}

// MARK: - Decodes the previously-dropped optional fields (exact values)

@Suite("ChatCompletionRequest wire completeness")
struct ChatCompletionRequestWireCompletenessTests {

    @Test("minP decodes exactly (was silently dropped before 08-23 fix)")
    func decodesMinP() throws {
        #expect(try decodeRequest(["min_p": 0.05]).minP == 0.05)
    }

    @Test("seed decodes exactly (was silently dropped before 08-23 fix)")
    func decodesSeed() throws {
        #expect(try decodeRequest(["seed": 424242]).seed == 424242)
    }

    @Test("prefill_step_size decodes exactly (was silently dropped)")
    func decodesPrefillStepSize() throws {
        #expect(try decodeRequest(["prefill_step_size": 2048]).prefillStepSize == 2048)
    }

    @Test("max_kv_size decodes exactly (was silently dropped)")
    func decodesMaxKVSize() throws {
        #expect(try decodeRequest(["max_kv_size": 65536]).maxKVSize == 65536)
    }

    @Test("all three context sizes decode with distinct exact values")
    func decodesContextSizes() throws {
        let req = try decodeRequest([
            "repetition_context_size": 32,
            "presence_context_size": 64,
            "frequency_context_size": 128,
        ])
        #expect(req.repetitionContextSize == 32)
        #expect(req.presenceContextSize == 64)
        #expect(req.frequencyContextSize == 128)
    }

    @Test("self_correction decodes (was silently dropped before 08-23 fix)")
    func decodesSelfCorrection() throws {
        #expect(try decodeRequest(["self_correction": true]).selfCorrection == true)
    }

    @Test("stream_options decodes including include_usage (was silently dropped)")
    func decodesStreamOptions() throws {
        let req = try decodeRequest([
            "stream": true,
            "stream_options": ["include_usage": true],
        ])
        #expect(req.stream == true)
        #expect(req.streamOptions?.includeUsage == true)
    }

    @Test("reasoning_level decodes (CodingKeys case added 08-23; field had no key)")
    func decodesReasoningLevel() throws {
        let req = try decodeRequest([
            "reasoning": true,
            "reasoning_level": "deep",
        ])
        #expect(req.reasoning == true)
        #expect(req.reasoningLevel == "deep")
    }

    @Test("max_completion_tokens decodes exactly (new OpenAI standard field)")
    func decodesMaxCompletionTokens() throws {
        #expect(try decodeRequest(["max_completion_tokens": 1234]).maxCompletionTokens == 1234)
    }

    @Test("max_completion_tokens coexists with max_tokens (distinct values kept)")
    func decodesBothMaxFields() throws {
        let req = try decodeRequest([
            "max_tokens": 100,
            "max_completion_tokens": 999,
        ])
        #expect(req.maxTokens == 100)
        #expect(req.maxCompletionTokens == 999)
    }

    @Test("absent optional fields keep their declared defaults")
    func absentKeepsDefaults() throws {
        let req = try decodeRequest([:])
        #expect(req.maxCompletionTokens == nil)
        #expect(req.minP == nil)
        #expect(req.seed == nil)
        #expect(req.prefillStepSize == nil)
        #expect(req.maxKVSize == nil)
        #expect(req.repetitionContextSize == nil)
        #expect(req.presenceContextSize == nil)
        #expect(req.frequencyContextSize == nil)
        #expect(req.selfCorrection != true)  // decodeIfPresent assigns nil on absence (nil never enables the pipeline)
        #expect(req.streamOptions == nil)
        #expect(req.reasoningLevel == nil)
    }

    @Test("max_tokens priority cascade: max_completion_tokens wins when both present")
    func priorityCascade() throws {
        let req = try decodeRequest([
            "max_tokens": 100,
            "max_completion_tokens": 200,
        ])
        // Effective resolution mirrors ChatHandler: maxCompletionTokens ?? maxTokens.
        let effective = req.maxCompletionTokens ?? req.maxTokens
        #expect(effective == 200)

        let reqOnlyMax = try decodeRequest(["max_tokens": 55])
        #expect((reqOnlyMax.maxCompletionTokens ?? reqOnlyMax.maxTokens ?? 0) == 55)
    }
}
