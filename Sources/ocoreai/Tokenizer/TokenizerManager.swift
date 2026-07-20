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
/// - `tokenizer.decode(tokens:)` → `String`
/// - `streamingDetokenizer()` → per-token text chunk output for SSE
///
/// ### Architecture:
/// - ``TokenizerManager`` actor: per-model tokenizer registry
/// - ``DirectTokenizer``: wraps swift-transformers ``Tokenizer`` + prewarm
/// - ``StreamingDetokenizer``: streaming detokenization with prefix preservation

#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI

	import Foundation
	import Transformers

	// MARK: - StreamingDetokenizer Wrapper

	/// Wraps swift-transformers ``StreamingDetokenizer`` for incremental per-token text output.
	///
	/// Each N tokens, outputs a text chunk via ``consume(_:)``.
	/// Maintains internal state of processed token IDs.
	///
	/// ``@unchecked Sendable``: `_stream` (swift-transformers object) holds an internal C pointer
	/// that the compiler cannot verify as thread-safe. In practice, this instance lives exclusively
	/// on `LoadedModel`'s CAS-guarded inference actor and is never shared across concurrency contexts.
	/// `@unchecked Sendable` satisfies the Swift requirement without unsafe wrapping.
	final class StreamingDetokenizer: @unchecked Sendable {
		private let _tokenizer: any Tokenizer
		private var _ids: [Int] = []
		private var _stream: StreamingAdapter?

		init(tokenizer: any Tokenizer) {
			_tokenizer = tokenizer
		}

		func consume(_ token: Int32) throws -> String? {
			let id = Int(token)
			_ids.append(id)

			if let stream = _stream {
				return try stream.consume(id) ?? nil
			}

			// First token: initialize the StreamingDetokenizer from Transformers
			if _ids.count == 1 {
				_stream = try StreamingAdapter(tokenizer: _tokenizer, ids: [id])
			}

			// Return empty string for the first token
			return ""
		}

		func reset(initialTokenIds ids: [Int32]) {
			_ids = ids.map(Int.init)
			_stream = nil
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
				modelFolder: tokenizerURL, hub: nil,
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

		/// Remove a single tokenizer from the registry (hot-switch support).
		/// - Parameter modelId: The model whose tokenizer should be removed
		/// - Returns: `true` if a tokenizer existed and was removed
		@discardableResult
		func removeTokenizer(for modelId: String) -> Bool {
			guard tokenizers.removeValue(forKey: modelId) != nil else { return false }
			return true
		}

		/// Clear all tokenizers from the registry.
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
			name = modelId
			_tokenizer = tokenizer
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

		init(tokenizer: any Tokenizer, ids: [Int]) throws {
			let stream = tokenizer.streamingDetokenizer()
			_consume = { count in
				Result { try stream.consume(count) }
			}
			_ = try stream.consume(ids[0])
			for id in ids.dropFirst() {
				let _ = try self._consume(id).get { error in throw error }
			}
		}

		func consume(_ id: Int) throws -> String? {
			switch _consume(id) {
			case .success(let value): return value
			case .failure(let error): throw error
			}
		}
	}

#endif
