// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Tokenizer backend truth — the shipping build must actually tokenize.
///
/// Why this exists (proven 2026-10-12 on macOS 26): `Tokenizer/TokenizerManager.swift`
/// was gated `#if canImport(CoreAI)`, but its real dependency is swift-transformers.
/// CoreAI is absent on macOS 26 while `Tokenizers` is present, so the no-op stub in
/// `Models/InferenceStubs.swift` was compiled instead: `registerTokenizer` silently
/// succeeded, `getTokenizer` returned nil for every model, `POST /v1/count-tokens`
/// answered 404 for the exact id `GET /v1/models` listed as ready, and every token
/// count (usage + the context-window wall) fell back to a bytes/3-4 heuristic.
/// 20 test files were `#if canImport(CoreAI)`-gated, so nothing on the macOS 26
/// gate could see it.

import Foundation
import Testing

@testable import ocoreai

@Suite("Tokenizer backend — real, and provably not the stub")
struct TokenizerBackendTruthTests {

    @Test("swift-transformers is linked in this build")
    func realBackendLinked() {
        // If a future gate change drops the real registry again, this fails on the
        // delivery platform instead of silently degrading token counts.
        #expect(TokenizerManager.isRealTokenizerBackend)
    }

    @Test("registration does real work — a nonexistent path must fail loudly")
    func registrationIsNotANoOp() async throws {
        // The stub's `registerTokenizer(for:tokenizerPath:)` is `{}` — it accepts
        // anything. Throwing here is positive proof the real backend is compiled in.
        let manager = TokenizerManager()
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no_such_tok_dir_\(UUID().uuidString.prefix(8))")
        var threw = false
        do {
            try await manager.registerTokenizer(for: "probe/model", tokenizerPath: bogus.path)
        } catch {
            threw = true
        }
        #expect(threw, "registerTokenizer accepted a nonexistent path — stub backend compiled in")
        #expect(await manager.getTokenizer(for: "probe/model") == nil)
    }

    @Test("real tokenizer produces exact token ids from an on-disk vocab")
    func realTokenizeExactIds() async throws {
        // Hermetic fixture: a minimal WordPiece tokenizer, no network, no model.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tok_fixture_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tokenizerJSON = """
            {
              "version": "1.0",
              "truncation": null,
              "padding": null,
              "added_tokens": [
                {"id": 0, "special": true, "content": "[PAD]", "single_word": false,
                 "lstrip": false, "rstrip": false, "normalized": false},
                {"id": 1, "special": true, "content": "[UNK]", "single_word": false,
                 "lstrip": false, "rstrip": false, "normalized": false}
              ],
              "normalizer": null,
              "pre_tokenizer": {"type": "Whitespace"},
              "post_processor": null,
              "decoder": null,
              "model": {
                "type": "WordPiece",
                "vocab": {"[PAD]": 0, "[UNK]": 1, "hello": 2, "world": 3},
                "unk_token": "[UNK]",
                "continuing_subword_prefix": "##",
                "max_input_chars_per_word": 100
              }
            }
            """
        try tokenizerJSON.write(
            to: dir.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
        // `tokenizer_class` + `chat_template` are both required by
        // swift-transformers (missingTokenizerClassInConfig / missingChatTemplate
        // otherwise) — same two keys every real checkpoint ships.
        let tokenizerConfig = """
            {
              "tokenizer_class": "BertTokenizer",
              "model_max_length": 32,
              "chat_template": "{% for message in messages %}{{ message['content'] }}{% endfor %}"
            }
            """
        try tokenizerConfig.write(
            to: dir.appendingPathComponent("tokenizer_config.json"), atomically: true,
            encoding: .utf8)

        let manager = TokenizerManager()
        try await manager.registerTokenizer(for: "fixture/tiny", tokenizerPath: dir.path)
        guard let tok = await manager.getTokenizer(for: "fixture/tiny") else {
            Issue.record("registered a valid tokenizer but lookup returned nil")
            return
        }
        let ids = try await tok.tokenize(
            messages: [["role": "user", "content": "hello world"]])
        // Exact-value contract (gold standard, not `count > N`). The template
        // emits message content verbatim, and the fixture vocab is
        // [PAD]=0 [UNK]=1 hello=2 world=3 — so "hello world" MUST be [2, 3].
        // Any [UNK] here means the vocab never loaded.
        #expect(ids == [2, 3], "expected exact ids [2, 3], got \(ids)")
        let text = try await tok.detokenize(tokenIds: ids)
        #expect(text.contains("hello"))
        #expect(text.contains("world"))
    }
}
