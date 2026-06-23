// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// TokenizerManager — Rust-backed tokenizer via swift-transformers
///
/// DEFENSIVE: Multi-protocol tokenization abstraction. Currently only wraps one
/// backend (swift-transformers). Retained for easy multi-provider swap once
/// CoreAI ships native tokenizer integration or we add a fallback provider.
/// See ROADMAP.md.
///
/// ### API:
/// - `tokenizer.applyChatTemplate(messages:)` → `[Int32]`
/// - `tokenizer.decode(tokenIds:)` → `String`
/// - `streamingDetokenizer()` → per-token text chunk output for SSE
///
/// ### Architecture:
/// - ``TokenizerProvider`` protocol: abstracted interface for multiple tokenizer backends
/// - ``TokenizerManager`` actor: multi-tokenizer registry (per-model)
/// - ``DirectTokenizer``: wraps swift-transformers concrete Tokenizer
/// - ``StreamingDetokenizer``: streaming detokenization with prefix preservation

#if coreai

import Transformers
import Foundation

// MARK: - TokenizerProvider Protocol

/// Abstract interface for tokenizer backends.
///
/// Concretely implemented by ``DirectTokenizer`` wrapping swift-transformers.
protocol TokenizerProvider: Sendable {
    /// Tokenizer identifier (model name)
    var name: String { get }

    /// Tokenize messages using chat template (messages → token IDs)
    ///
    /// - Parameter messages: Array of message dicts with role/content keys
    /// - Returns: Token ID array
    func tokenize(messages: [[String: String]]) async throws -> [Int32]

    /// Detokenize token IDs back to text (full detokenization)
    ///
    /// - Parameter tokenIds: Token ID array
    /// - Returns: Decoded text string
    func detokenize(tokenIds: [Int32]) async throws -> String

    /// Create a streaming detokenizer for incremental per-token output (SSE)
    ///
    /// - Returns: New ``StreamingDetokenizer`` instance
    func streamingDetokenizer() -> StreamingDetokenizer

    /// Count tokens in a message list
    ///
    /// - Parameter messages: Array of message dicts
    /// - Returns: Token count
    func countTokens(messages: [[String: String]]) async throws -> Int

    /// Pre-warm tokenizer cache (block until internal init completes)
    func prewarm() async throws
}

// MARK: - StreamingDetokenizer Wrapper

/// Wraps swift-transformers StreamingDetokenizer for incremental per-token text output.
///
/// Each N tokens, outputs a text chunk via ``consume(_:)``.
/// Maintains internal state of processed token IDs.
final class StreamingDetokenizer: @unchecked Sendable {
    /// Underlying swift-transformers tokenizer reference
    private let _tokenizer: any Tokenizer

    /// Accumulated token IDs
    private var _ids: [Int] = []

    /// Internal streaming detokenizer protocol adapter
    private var _stream: StreamingDetokenizerProtocol?

    /// Internal adapter protocol for streaming detokenization
    private protocol StreamingDetokenizerProtocol {
        /// Consume a token ID and return new text delta (if any)
        func consume(_ tokenId: Int) throws -> String?
    }

    /// Initialize with a swift-transformers tokenizer.
    ///
    /// - Parameter tokenizer: Underlying tokenizer instance
    init(tokenizer: any Tokenizer) {
        self._tokenizer = tokenizer
    }

    /// Consume a token ID and return new text output (if any).
    ///
    /// - Parameter tokenId: Token to consume
    /// - Returns: New text delta string, or nil if no output yet
    /// - Throws: Error if detokenization fails
    func consume(_ tokenId: Int32) throws -> String? {
        _ids.append(Int(tokenId))

        // Use internal streaming detokenizer
        if _stream == nil {
            _stream = _makeStream()
        }

        return try _stream?.consume(Int(tokenId))
    }

    /// Reset the stream with initial token IDs (called at new session start).
    ///
    /// - Parameter initialTokenIds: Initial prompt token IDs to preload
    func reset(initialTokenIds: [Int32]) {
        _ids = initialTokenIds.map(Int.init)
        _stream = _makeStream(with: _ids)
    }

    /// Current accumulated token IDs
    var currentTokenIds: [Int32] {
        _ids.map(Int32.init)
    }

    /// Create a fresh streaming detokenizer (no initial tokens)
    private func _makeStream() -> StreamingDetokenizerProtocol {
        _wrapStreaming(_tokenizer.streamingDetokenizer())
    }

    /// Create a streaming detokenizer preloaded with initial token IDs
    private func _makeStream(with initialIds: [Int]) -> StreamingDetokenizerProtocol {
        _wrapStreaming(_tokenizer.streamingDetokenizer(initialTokenIds: initialIds))
    }
}

// MARK: - TokenizerManager

/// Multi-tokenizer registry managed as an actor for thread-safe access.
///
/// Supports loading tokenizers from local paths or HuggingFace Hub.
actor TokenizerManager {

    // MARK: - State

    /// Registered tokenizers keyed by model ID
    private var tokenizers: [String: any TokenizerProvider] = [:]

    // MARK: - Initialization

    /// Create an empty tokenizer registry.
    init() {}

    // MARK: - Registration

    /// Register a tokenizer loaded from a local directory path.
    ///
    /// - Parameters:
    ///   - modelId: Model identifier for lookup
    ///   - tokenizerPath: Local filesystem path to tokenizer files
    /// - Throws: Error if tokenizer cannot be loaded or prewarmed
    func registerTokenizer(
        for modelId: String,
        tokenizerPath: String
    ) async throws {
        precondition(!modelId.isEmpty, "modelId must not be empty")
        precondition(!tokenizerPath.isEmpty, "tokenizerPath must not be empty")

        let tokenizerURL = URL(fileURLWithPath: tokenizerPath)
        let tokenizer: any Tokenizer = try await AutoTokenizer.from(
            modelFolder: tokenizerURL,
            hub: nil
        )

        let provider = DirectTokenizer(
            modelId: modelId,
            tokenizer: tokenizer
        )

        try await provider.prewarm()
        tokenizers[modelId] = provider
    }

    /// Register a tokenizer downloaded from HuggingFace Hub.
    ///
    /// - Parameters:
    ///   - modelId: Model identifier for lookup
    ///   - hubId: HuggingFace Hub model identifier (e.g. "org/model-name")
    /// - Throws: Error if tokenizer cannot be downloaded or prewarmed
    func registerTokenizerFromHub(
        for modelId: String,
        hubId: String
    ) async throws {
        precondition(!modelId.isEmpty, "modelId must not be empty")
        precondition(!hubId.isEmpty, "hubId must not be empty")

        let tokenizer: any Tokenizer = try await AutoTokenizer.from(
            pretrained: hubId
        )

        let provider = DirectTokenizer(
            modelId: modelId,
            tokenizer: tokenizer
        )

        try await provider.prewarm()
        tokenizers[modelId] = provider
    }

    // MARK: - Lookup

    /// Get a registered tokenizer provider by model ID.
    ///
    /// - Parameter modelId: Model identifier
    /// - Returns: Tokenizer provider, or nil if not registered
    func getTokenizer(for modelId: String) -> (any TokenizerProvider)? {
        tokenizers[modelId]
    }

    // MARK: - Shutdown

    /// Release all registered tokenizers (cleanup on shutdown).
    func shutdown() {
        tokenizers.removeAll()
    }
}

// MARK: - DirectTokenizer

/// Concrete ``TokenizerProvider`` wrapping swift-transformers ``Tokenizer``.
///
/// Delegates all operations to the underlying swift-transformers tokenizer.
final class DirectTokenizer: TokenizerProvider, Sendable {

    /// Model name identifier
    let name: String

    /// Underlying swift-transformers tokenizer
    private let _tokenizer: any Tokenizer

    /// Initialize with model ID and swift-transformers tokenizer.
    ///
    /// - Parameters:
    ///   - modelId: Model identifier
    ///   - tokenizer: swift-transformers tokenizer instance
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

    func prewarm() async throws {
        // Warm up tokenizer with minimal chat template to ensure internal init
        let warmupIds = try _tokenizer.applyChatTemplate(messages: [["role": "user", "content": "Hello"]])
        _ = try _tokenizer.decode(tokenIds: warmupIds)
    }
}

// MARK: - Bridging Layer

/// Extension to wrap swift-transformers StreamingDetokenizer for Sendable compatibility.
///
/// The internal StreamingDetokenizer is a class (not Sendable),
/// so we capture it in a closure-based adapter.

extension StreamingDetokenizer {

    /// Wrap a swift-transformers StreamingDetokenizer in a Sendable adapter.
    ///
    /// - Parameter stream: swift-transformers streaming detokenizer instance
    /// - Returns: Sendable-compatible ``StreamingDetokenizerProtocol`` adapter
    private func _wrapStreaming(
        _ stream: Transformers.StreamingDetokenizer
    ) -> StreamingDetokenizerProtocol {
        _StreamingAdapter(wrapping: stream)
    }
}

/// Internal Sendable adapter wrapping a non-Sendable swift-transformers StreamingDetokenizer.
///
/// Uses closure capture to bridge the Sendable boundary safely.
private final class _StreamingAdapter: StreamingDetokenizerProtocol, Sendable {
    /// Captured consume closure (Result-based for Sendable compatibility)
    private let _consume: @Sendable (Int) -> Result<String?, Error>

    /// Initialize by capturing the stream in a closure.
    ///
    /// - Parameter stream: swift-transformers streaming detokenizer to wrap
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
            /// Wrap downstream tokenizer error into structured AppError
            throw AppError.tokenizationFailed(error.localizedDescription)
        }
    }
}

#endif // coreai