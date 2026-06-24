// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// TokenizerManager.swift — Rust-backed tokenizer via swift-transformers
//
/// Multi-tokenizer registry (per-model) managed as an actor for thread-safe access.
///
/// Wraps swift-transformers ``AutoTokenizer`` — the same Rust-backed tokenizer
/// engine that powers the entire HuggingFace ecosystem. Zero reinvention needed.
///
/// ### API:
/// - `tokenizer.applyChatTemplate(messages:)` → `[Int]`
/// - `tokenizer.decode(tokenIds:)` → `String`
/// - `streamingDetokenizer()` → per-token text chunk output for SSE
///
/// ### Architecture:
/// - ``TokenizerManager`` actor: per-model tokenizer registry
/// - ``DirectTokenizer``: wraps swift-transformers ``Tokenizer`` + prewarm
/// - ``StreamingDetokenizer``: streaming detokenization with prefix preservation

#if coreai

import Transformers
import Foundation

// MARK: - StreamingDetokenizer Wrapper

/// Wraps swift-transformers ``StreamingDetokenizer`` for incremental per-token text output.
///
/// Each N tokens, outputs a text chunk via ``consume(_:)``.
/// Maintains internal state of processed token IDs.
final class StreamingDetokenizer: @unchecked Sendable {
    private let _tokenizer: any Tokenizer
    private var _ids: [Int] = []
    private var _stream: StreamingAdapter?

    init(tokenizer: any Tokenizer) {
        self._tokenizer = tokenizer
    }

    func consume(_ tokenId: Int32) throws -> String? {
        _ids.append(Int(tokenId))
        if _stream == nil {
            _stream = StreamingAdapter(wrapping: _tokenizer.streamingDetokenizer())
        }
        return try _stream?.consume(Int(tokenId))
    }

    func reset(initialTokenIds: [Int32]) {
        _ids = initialTokenIds.map(Int.init)
        _stream = StreamingAdapter(wrapping: _tokenizer.streamingDetokenizer(initialTokenIds: _ids))
    }

    var currentTokenIds: [Int32] {
        _ids.map(Int32.init)
    }
}

// MARK: - TokenizerManager

/// Multi-tokenizer registry managed as an actor for thread-safe access.
///
/// Supports loading tokenizers from local paths or HuggingFace Hub.
actor TokenizerManager {

    private var tokenizers: [String: DirectTokenizer] = [:]

    init() {}

    /// Register a tokenizer loaded from a local directory path.
    func registerTokenizer(for modelId: String, tokenizerPath: String) async throws {
        precondition(!modelId.isEmpty, "modelId must not be empty")
        precondition(!tokenizerPath.isEmpty, "tokenizerPath must not be empty")

        let tokenizerURL = URL(fileURLWithPath: tokenizerPath)
        let tokenizer: any Tokenizer = try await AutoTokenizer.from(
            modelFolder: tokenizerURL, hub: nil
        )

        let provider = DirectTokenizer(modelId: modelId, tokenizer: tokenizer)
        try await provider.prewarm()
        tokenizers[modelId] = provider
    }

    /// Register a tokenizer downloaded from HuggingFace Hub.
    func registerTokenizerFromHub(for modelId: String, hubId: String) async throws {
        precondition(!modelId.isEmpty, "modelId must not be empty")
        precondition(!hubId.isEmpty, "hubId must not be empty")

        let tokenizer: any Tokenizer = try await AutoTokenizer.from(pretrained: hubId)

        let provider = DirectTokenizer(modelId: modelId, tokenizer: tokenizer)
        try await provider.prewarm()
        tokenizers[modelId] = provider
    }

    /// Get a registered tokenizer by model ID.
    func getTokenizer(for modelId: String) -> DirectTokenizer? {
        tokenizers[modelId]
    }

    /// Release all registered tokenizers (cleanup on shutdown).
    func shutdown() {
        tokenizers.removeAll()
    }
}

// MARK: - DirectTokenizer

/// Concrete tokenizer wrapping swift-transformers ``Tokenizer``.
///
/// Delegates all operations to the underlying swift-transformers tokenizer.
final class DirectTokenizer: Sendable {

    let name: String
    private let _tokenizer: any Tokenizer

    init(modelId: String, tokenizer: any Tokenizer) {
        precondition(!modelId.isEmpty, "DirectTokenizer requires a non-empty modelId")
        self.name = modelId
        self._tokenizer = tokenizer
    }

    func tokenize(messages: [[String: String]]) async throws -> [Int32] {
        let tokenIds = try _tokenizer.applyChatTemplate(messages: messages)
        return tokenIds.map(Int32.init)
    }

    func detokenize(tokenIds: [Int32]) async throws -> String {
        let ids = tokenIds.map(Int.init)
        return try _tokenizer.decode(tokenIds: ids)
    }

    func streamingDetokenizer() -> StreamingDetokenizer {
        StreamingDetokenizer(tokenizer: _tokenizer)
    }

    func countTokens(messages: [[String: String]]) async throws -> Int {
        try tokenize(messages: messages).count
    }

    /// Warm up tokenizer with minimal chat template to ensure internal init completes.
    func prewarm() async throws {
        let warmupIds = try _tokenizer.applyChatTemplate(messages: [["role": "user", "content": "Hello"]])
        _ = try _tokenizer.decode(tokenIds: warmupIds)
    }
}

// MARK: - Sendable Bridging

/// Internal Sendable adapter wrapping a non-Sendable swift-transformers StreamingDetokenizer.
///
/// Uses closure capture to bridge the Sendable boundary safely.
private final class StreamingAdapter: Sendable {
    private let _consume: @Sendable (Int) -> Result<String?, Error>

    init(wrapping stream: Transformers.StreamingDetokenizer) {
        self._consume = { tokenId in
            do {
                let result = try stream.consume(tokenId)
                return .success(result)
            } catch {
                return .failure(error)
            }
        }
    }

    func consume(_ tokenId: Int) throws -> String? {
        switch _consume(tokenId) {
        case .success(let value): return value
        case .failure(let error):
            throw AppError.tokenizationFailed(error.localizedDescription)
        }
    }
}

#endif // coreai
