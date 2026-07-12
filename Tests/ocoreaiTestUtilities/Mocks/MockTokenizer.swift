// Copyright © 2026 uingei@163.com.
/// MockTokenizer.swift — Protocol-level tokenizer mock for unit tests.
///
/// Tests coverage: Round-trip encode/decode, chat template, special tokens, batch ops.
///
/// Design: ASCII→UTF8 byte encoding ensures deterministic token IDs regardless of
/// underlying tokenizer variant (GPT2 vs Llama vs Mistral). Mock only implements
/// the interface paths that ocoreai's codebase actually calls.
///
/// Source: coreai-models TestUtilities pattern (references/coreai-models/swift/Tests/TestUtilities/Utilities.swift)

import Foundation

struct MockTokenizer: @unchecked Sendable {
    let bosTokenId: Int?
    let eosTokenId: Int?
    let unknownTokenId: Int?
    let vocabSize: Int

    init(
        bosTokenId: Int? = 1,
        eosTokenId: Int? = 2,
        unknownTokenId: Int? = 0,
        vocabSize: Int = 32000
    ) {
        self.bosTokenId = bosTokenId
        self.eosTokenId = eosTokenId
        self.unknownTokenId = unknownTokenId
        self.vocabSize = vocabSize
    }

    // MARK: - Encoding

    /// Encode text to token IDs via UTF-8 bytes.
    ///
    /// Deterministic: same input always produces same token IDs across models.
    /// Special tokens (BOS/EOS) can be injected via ``addSpecialTokens``.
    func encode(_ text: String, addSpecialTokens: Bool = false) -> [Int] {
        var tokens = Array(text.utf8).map { Int($0) }
        if addSpecialTokens {
            if let bos = bosTokenId {
                tokens.insert(bos, at: 0)
            }
            if let eos = eosTokenId {
                tokens.append(eos)
            }
        }
        return tokens
    }

    // MARK: - Decoding

    /// Decode token IDs back to string via UTF-8 bytes.
    ///
    /// Round-trips with ``encode(_:addSpecialTokens:)`` when skipSpecialTokens matches.
    func decode(_ tokens: [Int], skipSpecialTokens: Bool = true) -> String {
        var filtered = tokens
        if skipSpecialTokens {
            let special = [bosTokenId, eosTokenId, unknownTokenId].compactMap { $0 }
            filtered = tokens.filter { !special.contains($0) && $0 >= 0 && $0 <= 127 }
        }
        let bytes = filtered.compactMap { ($0 >= 0 && $0 <= 255) ? UInt8($0) : nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Chat Template

    /// Apply a chat template to messages.
    ///
    /// Concatenates all content strings with space separators, then encodes.
    /// This is a simplified model sufficient for testing request/response round-trips.
    func applyChatTemplate(messages: [[String: String]]) -> [Int] {
        let combined = messages.compactMap { $0["content"] ?? $0["text"] }
            .joined(separator: " ")
        return encode(combined, addSpecialTokens: true)
    }

    // MARK: - Chat Template (dict with role/content keys)

    /// Apply a chat template to structured messages.
    func applyChatTemplate(messages: [[String: Any]]) -> [Int] {
        let combined = messages.compactMap {
            ($0["content"] ?? $0["text"]) as? String
        }.joined(separator: " ")
        return encode(combined, addSpecialTokens: true)
    }

    // MARK: - Properties

    var bosToken: String? { "<bos>" }
    var eosToken: String? { "<eos>" }
    var unkToken: String? { "<unk>" }

    /// Check if a token ID is special.
    func isSpecial(_ tokenId: Int) -> Bool {
        [bosTokenId, eosTokenId, unknownTokenId].compactMap({ $0 }).contains(tokenId)
    }

    /// Tokenize to string tokens (intermediate representation).
    func tokenize(_ text: String) -> [String] {
        text.utf8.map { String(decoding: [$0], as: UTF8.self) }
    }
}
