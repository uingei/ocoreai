// oCoreAI — TokenHistory contract parity with coreai-models upstream.
// Upstream provenance (BSD-3-clause, Apple), coreai-models
// swift/Tests/LanguageModelsTests/UnifiedGenerationAPITests.swift —
// `@Suite("TokenHistory")` (8 tests). This file ports that suite verbatim
// onto the ocoreai in-tree `TokenHistory` (CoreAIEngine.swift L358), so the
// shared prefix-caching contract is pinned in-tree, not only upstream.
//
// Same algorithm, different fast path (documented parity):
//   upstream: memcmp fast path + element-wise divergence scan.
//   ocoreai :  element-wise scan ("safe equivalent", no force-unwrapped
//              buffer pointers) — CoreAIEngine.swift L366-369.
// Surface parity: ocoreai adds `isEmpty` + `trim(maxCapacity:)` (production
// bounds; upstream has neither). `private(set) tokens` keeps the same
// access as upstream, asserted here via @testable.
//
// Gated `#if canImport(CoreAI)`: `TokenHistory` lives in CoreAIEngine.swift
// which is CoreAI-gated (macOS 14/15 / macOS 26 Xcode-26.6 tier has no
// CoreAI framework). On the macOS 27 tier (CI xcode-27 leg) these 8 tests
// actually run. Same convention as Pip5PrefixClampTests (L28).
#if canImport(CoreAI)
import Foundation
import Testing

@testable import ocoreai

@Suite("TokenHistory contract parity (upstream coreai-models @Suite) — 8 exact-value tests")
struct TokenHistoryUpstreamContractTests {

    // 1 — upstream: "resolve with empty history returns all tokens as new"
    @Test("resolve with empty history returns all tokens as new")
    func resolveEmptyHistory() {
        let history = TokenHistory()
        let input: [Int32] = [1, 2, 3, 4, 5]
        let (commonPrefix, newTokens) = history.resolve(input: input)
        #expect(commonPrefix == 0)
        #expect(Array(newTokens) == [1, 2, 3, 4, 5])
    }

    // 2 — upstream: "resolve with exact match returns no new tokens"
    @Test("resolve with exact match returns no new tokens")
    func resolveExactMatch() {
        var history = TokenHistory()
        history.append(contentsOf: [1, 2, 3][...])
        let input: [Int32] = [1, 2, 3]
        let (commonPrefix, newTokens) = history.resolve(input: input)
        #expect(commonPrefix == 3)
        #expect(Array(newTokens) == [])
    }

    // 3 — upstream: "resolve with prefix match returns only new tokens"
    @Test("resolve with prefix match returns only new tokens")
    func resolvePrefixMatch() {
        var history = TokenHistory()
        history.append(contentsOf: [1, 2, 3][...])
        let input: [Int32] = [1, 2, 3, 4, 5]
        let (commonPrefix, newTokens) = history.resolve(input: input)
        #expect(commonPrefix == 3)
        #expect(Array(newTokens) == [4, 5])
    }

    // 4 — upstream: "resolve with divergence finds divergence point"
    @Test("resolve with divergence finds divergence point")
    func resolveDivergence() {
        var history = TokenHistory()
        history.append(contentsOf: [1, 2, 3, 4, 5][...])
        let input: [Int32] = [1, 2, 99, 100]
        let (commonPrefix, newTokens) = history.resolve(input: input)
        #expect(commonPrefix == 2)
        #expect(Array(newTokens) == [99, 100])
    }

    // 5 — upstream: "resolve with shorter input than history"
    @Test("resolve with shorter input than history")
    func resolveShorterInput() {
        var history = TokenHistory()
        history.append(contentsOf: [1, 2, 3, 4, 5][...])
        let input: [Int32] = [1, 2, 3]
        let (commonPrefix, newTokens) = history.resolve(input: input)
        #expect(commonPrefix == 3)
        #expect(Array(newTokens) == [])
    }

    // 6 — upstream: "resolve with completely different input"
    @Test("resolve with completely different input")
    func resolveCompleteDivergence() {
        var history = TokenHistory()
        history.append(contentsOf: [1, 2, 3][...])
        let input: [Int32] = [99, 98, 97]
        let (commonPrefix, newTokens) = history.resolve(input: input)
        #expect(commonPrefix == 0)
        #expect(Array(newTokens) == [99, 98, 97])
    }

    // 7 — upstream: "append and truncate lifecycle"
    @Test("append and truncate lifecycle")
    func appendAndTruncate() {
        var history = TokenHistory()
        history.append(42)
        history.append(contentsOf: [1, 2, 3][...])
        #expect(history.count == 4)
        history.truncate(to: 2)
        #expect(history.count == 2)
        #expect(history.tokens == [42, 1])
        history.truncate(to: 2)  // no-op (same as upstream expectation)
        #expect(history.count == 2)
        history.clear()
        #expect(history.count == 0)
    }

    // 8 — upstream: "resolve with empty input returns 0 common prefix"
    @Test("resolve with empty input returns 0 common prefix")
    func resolveEmptyInput() {
        var history = TokenHistory()
        history.append(contentsOf: [1, 2, 3][...])
        let input: [Int32] = []
        let (commonPrefix, newTokens) = history.resolve(input: input)
        #expect(commonPrefix == 0)
        #expect(Array(newTokens) == [])
    }

    // ocoreai surface additions (beyond upstream — not parity gaps):
    // `isEmpty` + `trim(maxCapacity:)` pin the extra contract.
    @Test("ocoreai addition: trim bounds growth and preserves tail")
    func trimBoundsGrowth() {
        var history = TokenHistory()
        history.append(contentsOf: [1, 2, 3, 4, 5, 6, 7][...])
        history.trim(maxCapacity: 3)
        #expect(history.count == 3)
        #expect(history.tokens == [5, 6, 7])  // tail kept
        #expect(history.isEmpty == false)
    }

    @Test("ocoreai addition: trim is a no-op at/below capacity")
    func trimNoOpAtCapacity() {
        var history = TokenHistory()
        history.append(contentsOf: [1, 2][...])
        history.trim(maxCapacity: 3)
        #expect(history.tokens == [1, 2])
        #expect(history.isEmpty == false)
    }
}
#endif
