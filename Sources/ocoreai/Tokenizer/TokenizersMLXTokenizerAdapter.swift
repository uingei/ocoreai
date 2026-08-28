// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// TokenizersMLXTokenizerAdapter.swift
//
/// Bridge: swift-transformers ``Tokenizer`` → ``MLXLMCommon.Tokenizer``.
///
/// The CoreAI inference path owns a swift-transformers (Rust-backed)
/// tokenizer via ``TokenizerManager``/``DirectTokenizer``; it has no
/// ``MLXLanguageModel`` and therefore no `MLXLMCommon.Tokenizer`. Guided
/// generation on `MLXGuidedGeneration.GrammarConstraint` needs an
/// `MLXLMCommon.Tokenizer` to build a `GrammarTokenizer` (vocab extraction
/// via `TokenizerVocabExtractor.extractForGrammar` only calls
/// `convertIdToToken`). This adapter satisfies that minimal interface with
/// pure delegation — no MLX tensor types, no MLXLM model dependency.
///
/// Conformance notes (verified against `MLXLMCommon/Tokenizer.swift`):
/// - `encode` / `decode` / `convertTokenToId` / `convertIdToToken`:
///   required, delegated 1:1 to the wrapped swift-transformers tokenizer.
/// - `applyChatTemplate` (3-arg form): required on
///   `MLXLMCommon.Tokenizer`, delegated to the swift-transformers
///   1-arg form. The 1/2-arg overloads have defaults on
///   `MLXLMCommon.Tokenizer` that funnel to this 3-arg method.
/// - `grammarTokenizer` (3-arg) is the only form the CoreAI
///   grammar bootstrap path calls, and `fastForward` is disabled,
///   so the adapter's `applyChatTemplate` is never reached at
///   runtime; conformance is for protocol completeness.
///
/// `@unchecked Sendable`: the inner `any Tokenizers.Tokenizer` is
/// held by reference and owned by the ``TokenizerManager`` actor;
/// this adapter is read-only.
///
/// Verified against: `MLXLMCommon/Tokenizer.swift`
/// (protocol `Tokenizer` + `NaiveStreamingDetokenizer`),
/// `swift-transformers/Sources/Tokenizers/Tokenizer.swift:220-330`
/// (protocol `Tokenizer` members incl. `Message` typealias),
/// `MLXGuidedGeneration/XGrammarBridge.swift` (`GrammarTokenizer`,
/// `GrammarConstraint`), `MLXGuidedGeneration/TokenizerVocabExtractor.swift`
/// (`extractForGrammar` → `vocabType`, `GrammarVocab`).

#if canImport(CoreAI)

import Foundation
import MLXLMCommon
import Tokenizers

@preconcurrency
/// All stored fields are immutable `let` set in `init` (no mutation after
/// creation), so Sendability reduces to the wrapped `base` tokenizer's
/// Sendability (swift-transformers `Tokenizer` protocol — thread-safe by
/// design; we never cache mutable state here).
final class TokenizersMLXTokenizerAdapter: MLXLMCommon.Tokenizer, @unchecked Sendable {
    private let base: any Tokenizers.Tokenizer
    private let _bosToken: String?
    private let _eosToken: String?
    private let _unknownToken: String?

    init(base: any Tokenizers.Tokenizer) {
        self.base = base
        self._bosToken = base.bosToken
        self._eosToken = base.eosToken
        self._unknownToken = base.unknownToken
    }

    // MARK: MLXLMCommon.Tokenizer conformance
    //
    // Each required member maps 1:1 to the swift-transformers
    // `Tokenizer` protocol. Signature differences are purely
    // naming (snake_case vs camelCase) — verified by reading
    // both protocol definitions.

    /// Encodes text. `addSpecialTokens` is passed through to the
    /// swift-transformers tokenizer. CoreAI bootstrap path only
    /// uses the vocabulary side of this protocol (per
    /// `TokenizerVocabExtractor.extractForGrammar`), so this
    /// method is never called on this path — its signature
    /// exists for protocol conformance.
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        base.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        base.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        base.convertIdToToken(id)
    }

    var bosToken: String? { _bosToken }
    var eosToken: String? { _eosToken }
    var unknownToken: String? { _unknownToken }

    /// 3-argument `applyChatTemplate` — required by
    /// `MLXLMCommon.Tokenizer`. In the CoreAI path `fastForward`
    /// is `false`, so the host tokenizer is only used for
    /// vocabulary extraction, never for chat-template rendering.
    /// Delegates to the swift-transformers 1-arg form
    /// (ignoring `tools` and `additionalContext`).
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try base.applyChatTemplate(messages: messages)
    }
}

#endif
