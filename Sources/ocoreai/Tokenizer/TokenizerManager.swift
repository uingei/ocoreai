// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// TokenizerManager.swift — Rust-backed tokenizer via swift-transformers (v1.3.3)
//
/// Multi-tokenizer registry (per-model) managed as an actor for thread-safe access.
///
/// Wraps swift-transformers ``AutoTokenizer`` — the same Rust-backed tokenizer
/// engine that powers the entire HuggingFace ecosystem.
///
/// ### API:
/// - `tokenizer.applyChatTemplate(messages:)` → `[Int]`
/// - `tokenizer.decode(tokens:)` → `String`
///
/// ### Architecture:
/// - ``TokenizerManager`` actor: per-model tokenizer registry
/// - ``DirectTokenizer``: wraps swift-transformers ``Tokenizer`` + prewarm
/// - ``StreamingDetokenizer``: streaming detokenization with prefix preservation

#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI

	import Foundation
	import Hub
	import Tokenizers

	// MARK: - StreamingDetokenizer Wrapper

	/// Manual streaming detokenizer — swift-transformers v1.3 dropped
	/// ``streamingDetokenizer()`` so we build it ourselves: incremental decode
	/// on each new token, returning only the delta (new text) since last call.
	///
	/// ``@unchecked Sendable``: lives exclusively on `LoadedModel`'s
	/// CAS-guarded inference path and is never shared across contexts.
	final class StreamingDetokenizer: @unchecked Sendable {
		private let _tokenizer: any Tokenizer
		private var _ids: [Int] = []
		private var _lastText = ""

		init(tokenizer: any Tokenizer) {
			_tokenizer = tokenizer
		}

		/// Feed one token and return the new text delta.
		func consume(_ token: Int32) throws -> String? {
			let id = Int(token)
			_ids.append(id)

			// Full decode is the only reliable way — we diff the result
			let fullText = _tokenizer.decode(tokens: _ids)
			// Return the delta since last call and update the baseline
			let delta = String(fullText.dropFirst(_lastText.count))
			_lastText = fullText
			return delta.isEmpty ? "" : delta
		}

		func reset(initialTokenIds ids: [Int32]) {
			_ids = ids.map(Int.init)
			_lastText = ""
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
				modelFolder: tokenizerURL,
				hubApi: HubApi.shared,
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
			return _tokenizer.decode(tokens: ids)
		}

		func streamingDetokenizer() -> StreamingDetokenizer {
			StreamingDetokenizer(tokenizer: _tokenizer)
		}

		func countTokens(messages: [[String: String]]) async throws -> Int {
			let tokenIds = try await tokenize(messages: messages)
			return tokenIds.count
		}

		/// Warm up tokenizer with minimal chat template to ensure internal init completes.
		func prewarm() async throws {
			let warmupIds = try _tokenizer.applyChatTemplate(messages: [["role": "user", "content": "Hello"]])
			_ = _tokenizer.decode(tokens: warmupIds)
		}
	}

#endif