// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! PromptTokenAccountingTests.swift — `prompt_tokens` must be the whole rendered prompt, and
//! `cached_tokens` must be a part of it.
//!
//! ### The defect this locks (measured live 10-21, this host)
//! Three warm turns on `/v1/chat/completions` answered, verbatim:
//!
//! ```
//! "usage": {"prompt_tokens": 30, "completion_tokens": 15, "total_tokens": 45,
//!           "prompt_tokens_details": {"cached_tokens": 949}}
//! ```
//!
//! (the other two legs said `prompt_tokens: 44` and `prompt_tokens: 54` with the same
//! `cached_tokens: 949.)` No test in this repo could see what is wrong with those numbers.
//! `cached_tokens` (949) is bigger than the `prompt_tokens` (30) it claims to break down — up to
//! 31x the whole it belongs to, which OpenAI's field contract makes impossible
//! (`prompt_tokens_details` is a breakdown OF `prompt_tokens`). And by upstream's own sum
//! (`cached + prefilled` = 979) a 979-token prompt reached the client as 30, so the entire reused
//! prefix vanished from anything a client bills or budgets with. Cause: upstream
//! `GenerateCompletionInfo.promptTokenCount` is what the turn *prefilled*, and on a reuse turn
//! that is only the suffix — upstream's total is `totalPromptTokenCount = cached + prefilled`
//! (`Evaluate.swift:2984-2987`), which is what mlx-swift-lm itself emits as input tokens
//! (`MLXLanguageModel.swift:1377`, `:1519`, `:1721`). We published the delta and kept the
//! prefix in a separate field.
//!
//! ### Why exact values, and why the last test
//! Probes 01 and 19 compare the wire's `cached_tokens` against the engine's reuse line, and both
//! stayed green through this — they never asked what `prompt_tokens` was on the same turn. So the
//! assertions below are exact-value, and the final one encodes a real `Usage` and re-reads the
//! JSON, so a regression in field wiring (not just in the arithmetic) goes red.

import Foundation
import Testing

@testable import ocoreai

@Suite("PromptTokenAccounting — prompt_tokens is the rendered prompt")
struct PromptTokenAccountingTests {

    /// Live numbers from the turn quoted above: prefix kept 949, suffix paid 54.
    @Test("warm turn — the reused prefix is added back, not dropped")
    static func warmTurnAddsBackTheReusedPrefix() {
        #expect(
            PromptTokenAccounting.renderedPromptTokens(
                observedPrefilled: 54, cachedPromptTokens: 949, fallback: 763) == 1003)
        // The old behaviour, stated as a value, so a regression names itself.
        #expect(
            PromptTokenAccounting.renderedPromptTokens(
                observedPrefilled: 54, cachedPromptTokens: 949, fallback: 763) != 54)
    }

    /// Probe 19's committed warm turn: `prompt=12 cached=1458` → the prompt was 1470.
    @Test("probe 19's committed warm turn resolves to its real prompt size")
    static func probeNineteenWarmTurn() {
        #expect(
            PromptTokenAccounting.renderedPromptTokens(
                observedPrefilled: 12, cachedPromptTokens: 1458, fallback: 1470) == 1470)
    }

    @Test("cold turn with .info — no reuse, so nothing is added")
    static func coldTurnNoReuse() {
        #expect(
            PromptTokenAccounting.renderedPromptTokens(
                observedPrefilled: 763, cachedPromptTokens: 0, fallback: 999) == 763)
    }

    /// Paths that produce no `GenerateCompletionInfo` at all (guided / FoundationModels / CoreAI)
    /// hand over a pre-flight tokenizer estimate of the WHOLE prompt. There is no suffix here, so
    /// adding a cached count would over-report — the add-back is conditional by design.
    @Test("no .info on this path — keep the estimate, never add a cached count")
    static func pathWithoutInfoKeepsEstimate() {
        #expect(
            PromptTokenAccounting.renderedPromptTokens(
                observedPrefilled: nil, cachedPromptTokens: nil, fallback: 763) == 763)
        // A cached count without a prefilled count cannot happen from one .info, but must not
        // turn an estimate of the whole prompt into a double-counted one.
        #expect(
            PromptTokenAccounting.renderedPromptTokens(
                observedPrefilled: nil, cachedPromptTokens: 949, fallback: 763) == 763)
    }

    @Test("a negative cached count cannot shrink or inflate the prompt")
    static func negativeCachedCountIsFloored() {
        #expect(
            PromptTokenAccounting.renderedPromptTokens(
                observedPrefilled: 500, cachedPromptTokens: -50, fallback: 1) == 500)
    }

    /// The wire invariant the whole family rests on, checked against encoded JSON rather than
    /// against the helper: a field renamed or assembled at the wrong hop fails here.
    @Test("encoded Usage — cached_tokens never exceeds prompt_tokens")
    static func encodedUsageKeepsCachedWithinPrompt() throws {
        let cases: [(prefilled: Int?, cached: Int?, fallback: Int, expectedPrompt: Int)] = [
            (54, 949, 763, 1003),
            (763, 0, 999, 763),
            (nil, nil, 763, 763),
            (12, 1458, 1470, 1470),
        ]
        for c in cases {
            let usage = Usage(
                input: PromptTokenAccounting.renderedPromptTokens(
                    observedPrefilled: c.prefilled, cachedPromptTokens: c.cached,
                    fallback: c.fallback),
                output: 15,
                cachedPromptTokens: c.cached)
            let data = try JSONEncoder().encode(usage)
            let obj = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            let prompt = try #require(obj["prompt_tokens"] as? Int)
            let total = try #require(obj["total_tokens"] as? Int)
            #expect(prompt == c.expectedPrompt, "prompt_tokens wrong for \(c)")
            #expect(total == c.expectedPrompt + 15, "total_tokens wrong for \(c)")
            if let cached = c.cached {
                let details = try #require(obj["prompt_tokens_details"] as? [String: Any])
                let cachedOut = try #require(details["cached_tokens"] as? Int)
                #expect(cachedOut == cached)
                #expect(
                    cachedOut <= prompt,
                    """
                    cached_tokens \(cachedOut) exceeds prompt_tokens \(prompt) — a breakdown \
                    larger than the whole it belongs to
                    """)
            } else {
                #expect(
                    obj["prompt_tokens_details"] == nil,
                    "no cached count observed, so the breakdown object must be absent")
            }
        }
    }
}
