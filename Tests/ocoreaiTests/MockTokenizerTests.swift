// Copyright © 2026 uingei@163.com.
/// MockTokenizerTests.swift — Round-trip verification for MockTokenizer
///
/// Coverage: encode/decode determinism, special token handling, chat template, vocab bounds
/// Rationale: MockTokenizer is the foundation of every other mock. It must be
/// proven deterministic before other test suites depend on it.

import Testing
@testable import ocoreaiTestUtilities

@Suite("MockTokenizer round-trip")
struct MockTokenizerTests {
    @Test("ASCII encode then decode is identity")
    func asciiRoundTrip() {
        let tokenizer = MockTokenizer()
        let input = "hello world"
        let tokens = tokenizer.encode(input)
        let output = tokenizer.decode(tokens)
        #expect(output == input)
    }

    @Test("Empty string round-trips")
    func emptyRoundTrip() {
        let tokenizer = MockTokenizer()
        #expect(tokenizer.decode(tokenizer.encode("")) == "")
    }

    @Test("Encode is deterministic")
    func deterministic() {
        let tokenizer = MockTokenizer()
        let tokens1 = tokenizer.encode("deterministic")
        let tokens2 = tokenizer.encode("deterministic")
        #expect(tokens1 == tokens2)
    }

    @Test("Special tokens have correct IDs")
    func specialTokenIds() {
        let tokenizer = MockTokenizer()
        #expect(tokenizer.bosTokenId == 1)
        #expect(tokenizer.eosTokenId == 2)
        #expect(tokenizer.unknownTokenId == 0)
    }

    @Test("BOS added with addSpecialTokens")
    func bosAddedWhenRequested() {
        let tokenizer = MockTokenizer()
        let tokens = tokenizer.encode("hi", addSpecialTokens: true)
        #expect(tokens.first == 1)  // BOS
    }

    @Test("isSpecial identifies known tokens")
    func isSpecial() {
        let tokenizer = MockTokenizer()
        #expect(tokenizer.isSpecial(0) == true)
        #expect(tokenizer.isSpecial(1) == true)
        #expect(tokenizer.isSpecial(2) == true)
        #expect(tokenizer.isSpecial(99) == false)
    }

    @Test("Chat template produces tokens")
    func chatTemplate() {
        let tokenizer = MockTokenizer()
        let messages: [[String: String]] = [
            ["role": "user", "content": "hello"],
        ]
        let tokens = tokenizer.applyChatTemplate(messages: messages)
        #expect(!tokens.isEmpty)
        #expect(tokens.first == 1)  // BOS prefix
    }

    @Test("Tokenize splits into characters")
    func tokenize() {
        let tokenizer = MockTokenizer()
        let parts = tokenizer.tokenize("hi")
        #expect(parts.count == 2)
        #expect(parts[0] == "h")
        #expect(parts[1] == "i")
    }

    @Test("Mixed content round-trip")
    func mixedRoundTrip() {
        let tokenizer = MockTokenizer()
        let input = "Hello world with spaces"
        let output = tokenizer.decode(tokenizer.encode(input))
        #expect(output == input)
    }
}
