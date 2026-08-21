// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// #176 alignment — user-facing `repetition_penalty` / `repetition_penalty_window`
// wire fields (upstream coreai-models 5660fc6 `--repetition-penalty` and
// `--repetition-penalty-window` flags, `LLMRunnerMain.swift:119`).
//
// These tests cover the JSON decoding contract of `ChatCompletionRequest` and
// the PATCH body (`ModelSamplingPatch`) that feed the request > runtime-default
// cascade in ChatHandler. The sampler-level behavior (sign-aware divide/multiply,
// dedup, window scoping) is covered by RepetitionPenaltyProcessorTests.swift
// (#if canImport(CoreAI)).

import Foundation
import Testing

@testable import ocoreai

private func decodeRepetitionPenalty(_ json: String) throws -> ChatCompletionRequest {
    try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
}

@Suite("RepetitionPenalty wire (#176 alignment with coreai-models 5660fc6)")
struct RepetitionPenaltyWireTests {

    @Test("repetition_penalty decodes into the request body")
    func decodesPenalty() throws {
        let req = try decodeRepetitionPenalty(
            #"""
            {"model": "m", "messages": [{"role": "user", "content": "hi"}],
             "repetition_penalty": 1.3}
            """#)
        #expect(req.repetitionPenalty == 1.3)
        #expect(req.repetitionPenaltyWindow == nil)
    }

    @Test("repetition_penalty_window decodes alongside the penalty")
    func decodesWindow() throws {
        let req = try decodeRepetitionPenalty(
            #"""
            {"model": "m", "messages": [{"role": "user", "content": "hi"}],
             "repetition_penalty": 1.2, "repetition_penalty_window": 8}
            """#)
        #expect(req.repetitionPenalty == 1.2)
        #expect(req.repetitionPenaltyWindow == 8)
    }

    @Test("absent repetition_penalty decodes as nil (not-set), not 0")
    func absentIsNil() throws {
        let req = try decodeRepetitionPenalty(
            #"""
            {"model": "m", "messages": [{"role": "user", "content": "hi"}]}
            """#)
        #expect(req.repetitionPenalty == nil)
        #expect(req.repetitionPenaltyWindow == nil)
        // 0 is a legal value, so it must round-trip exactly — no 0-sentinel
        #expect(
            try decodeRepetitionPenalty(
                #"""
                {"model": "m", "messages": [], "repetition_penalty": 0}
                """#
            ).repetitionPenalty == 0)
    }

    @Test("integer-typed value decodes (numeric tolerance)")
    func decodesInteger() throws {
        let req = try decodeRepetitionPenalty(
            #"""
            {"model": "m", "messages": [{"role": "user", "content": "hi"}],
             "repetition_penalty": 2}
            """#)
        #expect(req.repetitionPenalty == 2.0)
    }

    @Test("PATCH body carries both fields into ModelSamplingConfig")
    func patchToConfig() throws {
        let json = #"{"repetition_penalty": 1.5, "repetition_penalty_window": 12}"#
        let patch = try JSONDecoder().decode(ModelSamplingPatch.self, from: Data(json.utf8))
        let config = patch.toConfig()
        #expect(config.repetitionPenalty == 1.5)
        #expect(config.repetitionPenaltyWindow == 12)
        // presence/frequency unaffected
        #expect(config.presencePenalty == 0)
        #expect(config.frequencyPenalty == 0)
    }

    @Test("PATCH body without repetition_penalty leaves the config field unset")
    func patchAbsentLeavesNil() throws {
        let patch = try JSONDecoder().decode(
            ModelSamplingPatch.self, from: Data(#"{"temperature": 0.5}"#.utf8))
        let config = patch.toConfig()
        #expect(config.temperature == 0.5)
        #expect(config.repetitionPenalty == nil)
        #expect(config.repetitionPenaltyWindow == nil)
    }

    @Test("isDefault recognizes an all-nil repetition config")
    func isDefaultRespectsNewFields() {
        var custom = ModelSamplingConfig.default
        #expect(custom.isDefault)
        custom.repetitionPenalty = 1.2
        #expect(!custom.isDefault)
        custom.repetitionPenalty = nil
        custom.repetitionPenaltyWindow = 4
        #expect(!custom.isDefault)
    }

    @Test("GET response echo round-trips both fields")
    func getResponseEcho() throws {
        var config = ModelSamplingConfig.default
        config.repetitionPenalty = 1.4
        config.repetitionPenaltyWindow = 6
        let data = try JSONEncoder().encode(ModelSamplingResponse(config: config))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"repetition_penalty\":1.4"))
        #expect(json.contains("\"repetition_penalty_window\":6"))
    }
}
