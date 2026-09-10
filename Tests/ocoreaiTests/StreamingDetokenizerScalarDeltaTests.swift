// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// `StreamingDetokenizer` (CoreAI path, `#if canImport(CoreAI)`) — exact-value
// test for mlx-swift-lm `#613` / `4c3d793` "Emit only the new scalars when a
// token extends the previous character".
//
// Bug it guards against: a `Character`-level `commonPrefix` is wrong in two
// directions. A `Character` is a grapheme cluster; a variation selector joins
// the *previous* cluster (`🏳` + `️` → one cluster `🏳️`), so:
//   - old code on  (flag, VS):  new="🏳️" is 1 cluster, old="🏳" is 1 cluster,
//     different → commonPrefix length 0 → emits "🏳️" (flag + VS) instead of
//     just the VS. Consumer sees `🏳` repeated.
//   - old code on (a, é):      new="é" shares a Character ("é" starts with "a"
//     under canonical equivalence) with old="a"? No — but for real token
//     streams the mismatch *blanks out* a legitimate delta (commonPrefix
//     matched a Character that was actually re-encoded).
// #613 uses scalar-level prefix so the emitted delta is exactly the scalars
// the new segment added, in every direction.
//
// Assertion style: exact scalar arrays via `#expect ==` (gold standard).

#if canImport(CoreAI)

import Foundation
import Testing
import Tokenizers

@testable import ocoreai

/// Fake `Tokenizers.Tokenizer` whose `decode(tokens:)` rebuilds exact scalars
/// from token IDs. Token IDs are the Unicode scalar values; one special id
/// (98) maps to `"🏳"` (one cluster, scalars `[0x1F3F3]`). This mirrors the
/// shape upstream's `SplitMultibyteTokenizer` has in
/// `Tests/MLXLMTests/StreamingDetokenizerTests.swift` (their `case 60` is
/// the variation selector; here it is id 60 = U+FE0F).
private final class ExtendedClusterTokenizer: Tokenizers.Tokenizer, @unchecked Sendable {
    // id → token string
    private let idToToken: [Int: String]
    private let tokenToId: [String: Int]

    init() {
        let base: [Int: String] = [
            60: "\u{FE0F}",  // VARIATION SELECTOR-16
            91: "a",
            92: "\u{E9}",  // "é" precomposed: one Character, one scalar
            98: "\u{1F3F3}",  // "🏳": one Character (grapheme cluster)
        ]
        idToToken = base
        tokenToId = Dictionary(uniqueKeysWithValues: base.map { ($1, $0) })
    }

    private func scalarString(_ s: Unicode.Scalar) -> String { String(s) }

    var bosToken: String? { nil }
    var bosTokenId: Int? { nil }
    var eosToken: String? { nil }
    var eosTokenId: Int? { nil }
    var unknownToken: String? { nil }
    var unknownTokenId: Int? { nil }
    var fuseUnknownTokens: Bool { false }

    func tokenize(text: String) -> [String] {
        text.unicodeScalars.map { scalarString($0) }
    }

    func encode(text: String) -> [Int] {
        text.unicodeScalars.compactMap { tokenToId[scalarString($0)] }
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { encode(text: text) }

    func callAsFunction(_ text: String, addSpecialTokens: Bool) -> [Int] {
        encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokens: [Int]) -> String {
        tokens.compactMap { idToToken[$0] }.joined()
    }

    func decode(tokens: [Int], skipSpecialTokens: Bool) -> String {
        decode(tokens: tokens)
    }

    func convertTokenToId(_ token: String) -> Int? { tokenToId[token] }

    func convertIdToToken(_ id: Int) -> String? { idToToken[id] }

    // Chat-template surface — the SUT (`StreamingDetokenizer`) never calls
    // these; satisfy the protocol requirement minimally (throw). Required
    // overloads: 4-arg / tools / additionalContext / chatTemplate / String /
    // full-control (the 7-arg with additionalContext has a protocol default).
    func applyChatTemplate(messages: [Tokenizers.Message]) throws -> [Int] {
        throw Tokenizers.TokenizerError.chatTemplate("not implemented for test tokenizer")
    }

    func applyChatTemplate(messages: [Tokenizers.Message], tools: [Tokenizers.ToolSpec]?) throws
        -> [Int]
    {
        try applyChatTemplate(messages: messages)
    }

    func applyChatTemplate(
        messages: [Tokenizers.Message],
        tools: [Tokenizers.ToolSpec]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try applyChatTemplate(messages: messages, tools: tools)
    }

    func applyChatTemplate(
        messages: [Tokenizers.Message],
        chatTemplate: Tokenizers.ChatTemplateArgument
    ) throws -> [Int] {
        try applyChatTemplate(messages: messages)
    }

    func applyChatTemplate(messages: [Tokenizers.Message], chatTemplate: String) throws -> [Int] {
        try applyChatTemplate(messages: messages)
    }

    func applyChatTemplate(
        messages: [Tokenizers.Message],
        chatTemplate: Tokenizers.ChatTemplateArgument?,
        addGenerationPrompt: Bool,
        truncation: Bool,
        maxLength: Int?,
        tools: [Tokenizers.ToolSpec]?
    ) throws -> [Int] {
        try applyChatTemplate(messages: messages)
    }

    func applyChatTemplate(
        messages: [Tokenizers.Message],
        chatTemplate: Tokenizers.ChatTemplateArgument?,
        addGenerationPrompt: Bool,
        truncation: Bool,
        maxLength: Int?,
        tools: [Tokenizers.ToolSpec]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try applyChatTemplate(messages: messages)
    }
}

@Suite("StreamingDetokenizer #613 scalar-delta")
final class StreamingDetokenizerScalarDeltaTests {
    private func scalars(_ text: String) -> [UInt32] {
        text.unicodeScalars.map { $0.value }
    }

    /// #613 exact case (flag + variation selector): token 98 = `"🏳"` then
    /// token 60 = `U+FE0F`. Pre-#613 the emitted tail for step 2 was `"🏳️"`
    /// (the whole merged cluster — flag duplicated). Post-#613 the emitted
    /// tail for step 2 is exactly `[U+FE0F]`.
    @Test("extending variation selector emits exactly the new scalar")
    func extendingVSExact() throws {
        let detok = StreamingDetokenizer(tokenizer: ExtendedClusterTokenizer())
        let step1 = try detok.consume(98)
        let step2 = try detok.consume(60)

        #expect(scalars(step1 ?? "") == [0x1F3F3])
        #expect(scalars(step2 ?? "") == [0xFE0F])
        #expect(scalars((step1 ?? "") + (step2 ?? "")) == [0x1F3F3, 0xFE0F])
    }

    /// #613 direction 2 (a token that *merges* into the previous cluster):
    /// step 1 `"a"`, step 2 a precomposed `é`. The emitted tail for step 2
    /// must be exactly `[0xE9]` — the new scalar(s) the token added — not a
    /// blank (old code: `commonPrefix` matched a Character it shouldn't have)
    /// and not a re-emit of the previous character.
    @Test("precomposed accented emission is exactly the new scalar")
    func precomposedAccentExact() throws {
        let detok = StreamingDetokenizer(tokenizer: ExtendedClusterTokenizer())
        let step1 = try detok.consume(91)  // "a"
        let step2 = try detok.consume(92)  // "é"   → new segment = "aé"
        #expect(scalars(step1 ?? "") == [0x61])
        #expect(scalars(step2 ?? "") == [0xE9])
    }

    /// Regression: a plain new token after a prior token still emits only its
    /// own scalar (baseline; the #613 rewrite must not break the normal path).
    @Test("plain-token delta is exact")
    func plainTokenExact() throws {
        let detok = StreamingDetokenizer(tokenizer: ExtendedClusterTokenizer())
        let s1 = try detok.consume(91)
        let s2 = try detok.consume(60)
        #expect(scalars(s1 ?? "") == [0x61])
        #expect(scalars(s2 ?? "") == [0xFE0F])
    }

    /// #613 invariant: no *blank* (empty-string) emission for a step that
    /// *does* add new scalars to the segment. Blank = a legitimate delta was
    /// dropped. (Pre-#613 blanking happens when Character-level `commonPrefix`
    /// miscounts the divergence; scalar-level prefix counts exactly.)
    @Test("no blank emission when the token adds scalars")
    func noBlankWhenExtending() throws {
        let detok = StreamingDetokenizer(tokenizer: ExtendedClusterTokenizer())
        _ = try detok.consume(98)  // 🏳
        let ext = try detok.consume(60)
        #expect((ext ?? "").isEmpty == false)
        #expect(scalars(ext ?? "") == [0xFE0F])
    }
}
#endif
