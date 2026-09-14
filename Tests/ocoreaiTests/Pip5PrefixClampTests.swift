// oCoreAI — PIP5: pipelined-prefix last-token regression guard.
// Upstream provenance (BSD-3-clause, Apple), coreai-models #237 (62ff88b, fixes #234):
//   "Fix pipelined prefix reuse skipping the last sampled token"
//
// Root cause under test: pipelined decode yields the last sampled token into the
// stream but never feeds it back through the model, so after a turn
// history.count == processedTokenCount + 1. On the next call TokenHistory.resolve
// matches that unprocessed trailing token (prefix = history.count), and a KV-based
// prefill would then place the new tokens one position too far past the true
// KV-valid boundary — corrupting attention for that turn onward.
//
// The clamp under test is the decision at CoreAIPipelinedEngine.generate (the
// `commonPrefix > processedTokenCount` cap + history.truncate + the relocated
// lastPrefixHitCount). It runs against the PRODUCTION TokenHistory.resolve
// (not a MockEngine copy, which is how upstream #237 validates it), so this pins
// the real prefix-cache state this engine carries.

import Foundation
import Testing

@testable import ocoreai

// `TokenHistory` lives in CoreAIEngine.swift, which is `#if canImport(CoreAI)`
// gated (the floor — macOS 14/15 / the macos-26 Xcode-26.6 SDK tier — has no
// CoreAI framework). This suite references it, so it must be excluded there
// too; on the macOS 26/27 tier (CoreAI present) the 5 tests run. Same
// convention as CoreAIVisionConfigTests (wraps whole @Suite in this gate).
#if canImport(CoreAI)
@Suite("Pip5 PrefixClamp — pipelined last-token gap guard (#237/#234)")
struct Pip5PrefixClampTests {

    // Exact mirror of the clamp at CoreAIPipelinedEngine.generate; resolves the
    // next-turn input against the production TokenHistory and returns the reuse
    // decision (capped commonPrefix + the tokens that must be re-prefilled).
    @discardableResult
    private static func decideNextReuse(
        history: inout TokenHistory,
        input: [Int32],
        processedTokenCount: Int
    ) -> (commonPrefix: Int, rePrefillTokens: ArraySlice<Int32>) {
        var (commonPrefix, newTokens) = history.resolve(input: input)
        if commonPrefix > processedTokenCount {
            commonPrefix = processedTokenCount
            newTokens = input[commonPrefix...]
            history.truncate(to: commonPrefix)
        }
        return (commonPrefix, newTokens)
    }

    @Test("pipelined gap: trailing unprocessed token is NOT reuseable (exact values)")
    func gapTrailingTokenExcluded() {
        // Turn 1: prefill [1,2,3]; pipelined decode computes 10,20,30 then
        // yields 40 which is forwarded+appended but never fed through the model.
        var history = TokenHistory()
        history.append(contentsOf: [1, 2, 3][...])
        for t in [10, 20, 30, 40] as [Int32] { history.append(t) }
        let processedAfterTurn1 = 3 + 3  // 40 is the un-fed sampled tail (gap == 1)
        #expect(history.count == processedAfterTurn1 + 1)  // sanity: the gap exists

        // Turn 2 input = full previous sequence (prompt prefix intact) + fresh token.
        // Without the clamp resolve matches 7 incl. unprocessed 40; clamp caps to 6.
        let (p, re) = Self.decideNextReuse(
            history: &history,
            input: [1, 2, 3, 10, 20, 30, 40, 999],
            processedTokenCount: processedAfterTurn1)
        #expect(p == 6)  // capped to KV-valid boundary
        #expect(Array(re) == [40, 999])  // unprocessed tail re-prefilled
        #expect(history.count == 6)  // stale tail truncated
    }

    @Test("no gap (non-pipelined): full prefix reuse is preserved")
    func noGapFullReuse() {
        var history = TokenHistory()
        history.append(contentsOf: [1, 2, 3][...])
        let (p, re) = Self.decideNextReuse(
            history: &history,
            input: [1, 2, 3, 4],
            processedTokenCount: 3)
        #expect(p == 3)  // no over-clamp
        #expect(Array(re) == [4])
        #expect(history.count == 3)
    }

    @Test("divergent prefix: clamp must not exceed the true common prefix")
    func divergentNoFalseReuse() {
        var history = TokenHistory()
        history.append(contentsOf: [1, 2, 3][...])
        for t in [10, 20] as [Int32] { history.append(t) }
        let (p, re) = Self.decideNextReuse(
            history: &history,
            input: [1, 2, 3, 999, 888],  // diverges at index 3
            processedTokenCount: 4)
        #expect(p == 3)  // stops at true divergence
        #expect(Array(re) == [999, 888])
    }

    @Test("gap widens (2 un-fed): clamp still re-prefills both tails")
    func gapWidenedTwoUnfed() {
        var history = TokenHistory()
        history.append(contentsOf: [1, 2][...])
        for t in [10, 20, 30] as [Int32] { history.append(t) }
        let processedAfterTurn1 = 2 + 1  // 30 AND 20 un-fed -> gap 2
        #expect(history.count == processedAfterTurn1 + 2)
        let (p, re) = Self.decideNextReuse(
            history: &history,
            input: [1, 2, 10, 20, 30, 999],
            processedTokenCount: processedAfterTurn1)
        #expect(p == 3)
        #expect(Array(re) == [20, 30, 999])
        #expect(history.count == 3)
    }

    @Test("history already shorter than input: clamp is a no-op (pure extension)")
    func pureExtensionUnaffected() {
        var history = TokenHistory()
        history.append(contentsOf: [1, 2, 3][...])
        let (p, re) = Self.decideNextReuse(
            history: &history,
            input: [1, 2, 3, 4, 5, 6],
            processedTokenCount: 3)
        #expect(p == 3)
        #expect(Array(re).count == 3)
        #expect(history.count == 3)
    }
}
#endif  // canImport(CoreAI)
