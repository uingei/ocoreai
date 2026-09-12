// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// Wire-contract completeness for `prompt_tokens_details.cached_tokens` (09-12).
//
// Root defect fixed: the `Usage` DTO declared `cachedPromptTokens` →
// `prompt_tokens_details.cached_tokens` (OpenAIModels.swift `PromptTokensDetails`)
// but NO producer ever populated it — the value was silently always-omitted even
// though the OpenAI field is industry-standard (vllm
// `entrypoints/openai/protocol.py` `prompt_tokens_details.cached_tokens`; sglang
// `serving_completions.py` uses the same shape).
//
// Real source (consume, don't estimate): upstream `GenerateCompletionInfo
// .cachedPromptTokenCount` (mlx-swift-lm pinned 604fae7, Evaluate.swift:2512 —
// `ChatSession` attributes it from its KV-cache reuse decision; `0` = whole
// prompt prefilled, i.e. a KNOWN "no reuse" value, not "unknown").
//
// Asserted here with exact values, per the test-quality rule (精确断言):
//   * `cachedTokens` present with the exact wire value,
//   * absent when the leg produced no value (nil → whole object omitted),
//   * exact `0` when the upstream says no cache reuse,
//   * combined with `completion_tokens_details.reasoning_tokens` coexistence.

import Foundation
import Testing

@testable import ocoreai

// MARK: - Helpers

private func usageDict(_ usage: Usage) throws -> [String: Any] {
    let data = try JSONEncoder().encode(usage)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

// MARK: - Exact-value wire assertions

@Suite("Usage: prompt_tokens_details.cached_tokens wire contract")
struct PromptTokensDetailsCachedWireTests {

    @Test("cachedTokens == 2048 encodes under prompt_tokens_details.cached_tokens (exact)")
    func encodesCachedTokensExactly() throws {
        let root = try usageDict(Usage(input: 2500, output: 42, cachedPromptTokens: 2048))

        // prompt_tokens_details must be present with the exact cached value.
        let details = root["prompt_tokens_details"] as? [String: Any]
        #expect(details != nil, "prompt_tokens_details must be present when a value is set")
        #expect(
            details?["cached_tokens"] as? Int == 2048,
            "cached_tokens must be exactly 2048, got \(String(describing: details?["cached_tokens"]))"
        )

        // Siblings unchanged — cached_tokens is a detail, not a prompt_tokens override.
        #expect(root["prompt_tokens"] as? Int == 2500)
        #expect(root["completion_tokens"] as? Int == 42)
        #expect(root["total_tokens"] as? Int == 2542)
    }

    @Test("cachedTokens == 0 encodes (known 'no reuse' is a value, not an omission)")
    func encodesCachedTokensZero() throws {
        // Upstream reports 0 when the whole prompt was prefilled (no cache reuse).
        // This is a KNOWN fact and should appear on the wire, not be elided.
        let root = try usageDict(Usage(input: 512, output: 7, cachedPromptTokens: 0))

        let details = root["prompt_tokens_details"] as? [String: Any]
        #expect(
            details != nil,
            "0 cache reuse is a known value — prompt_tokens_details should be present")
        #expect(
            details?["cached_tokens"] as? Int == 0,
            "cached_tokens must be exactly 0")
    }

    @Test("nil cachedPromptTokens omits prompt_tokens_details entirely (leg produced no value)")
    func omitsWhenNil() throws {
        let root = try usageDict(Usage(input: 100, output: 10))

        #expect(
            root["prompt_tokens_details"] == nil,
            "no value → whole prompt_tokens_details object omitted, got \(String(describing: root["prompt_tokens_details"]))"
        )
        #expect(root["prompt_tokens"] as? Int == 100)
        #expect(root["total_tokens"] as? Int == 110)
    }

    @Test("cachedTokens coexists with reasoning_tokens (two details objects, exact values)")
    func coexistsWithReasoning() throws {
        let root = try usageDict(
            Usage(input: 5000, output: 1200, cachedPromptTokens: 4900, reasoningTokens: 800))

        let prompt = root["prompt_tokens_details"] as? [String: Any]
        let completion = root["completion_tokens_details"] as? [String: Any]

        #expect(prompt?["cached_tokens"] as? Int == 4900)
        #expect(completion?["reasoning_tokens"] as? Int == 800)
        #expect(root["prompt_tokens"] as? Int == 5000)
        #expect(root["completion_tokens"] as? Int == 1200)
        #expect(root["total_tokens"] as? Int == 6200)
    }

    @Test("reasoningTokens == 0 omits completion_tokens_details (no-op leg), keeps prompt details")
    func dropsZeroReasoningKeepsCached() throws {
        // reasoning_tokens 0 = the leg produced no reasoning → object omitted,
        // but a non-zero cached_tokens still must encode.
        let root = try usageDict(
            Usage(input: 300, output: 50, cachedPromptTokens: 200, reasoningTokens: 0))

        let prompt = root["prompt_tokens_details"] as? [String: Any]
        #expect(prompt?["cached_tokens"] as? Int == 200)
        #expect(
            root["completion_tokens_details"] == nil,
            "reasoning_tokens 0 → completion_tokens_details omitted")
    }
}
