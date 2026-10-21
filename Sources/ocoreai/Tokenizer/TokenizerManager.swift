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

// GATE: this file needs swift-transformers (`Tokenizers` + `Hub`) and nothing
// else, so the gate is `canImport(Tokenizers)` — the dependency it actually has.
// It used to be `canImport(CoreAI)`, which is a DIFFERENT axis (Apple CoreAI,
// macOS 27 SDK only). `Tokenizers` is an unconditional SPM product of this
// target (Package.swift:97) while `CoreAI` is absent on the macOS 26 delivery
// platform, so the old gate compiled this file OUT on every shipping machine and
// silently substituted the no-op stub in `Models/InferenceStubs.swift`
// (`registerTokenizer` = `{}`, `getTokenizer` = nil).
// Live consequence (proven 2026-10-12 on macOS 26, default model loaded and
// ready): `POST /v1/count-tokens` answered 404 "Model ... not found" for the
// exact id `GET /v1/models` lists as ready; chat fell back to the bytes/3-4
// heuristic, so `usage.prompt_tokens` and the context-window wall ran on
// estimated counts; and EnginePool still logged "Tokenizer registered ...
// context wall on real token counts" after the no-op register — a success claim
// with no substrate. 20 test files are `#if canImport(CoreAI)`-gated, which is
// why the CLT gate never caught it: two gates that mean different things were
// conflated.
#if canImport(Tokenizers)

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

        // Full decode is the only reliable way — we diff the result.
        let fullText = _tokenizer.decode(tokens: _ids)

        // DIFF by common prefix, not character count.
        // Character-count diff (`dropFirst(_lastText.count)`) assumes decode() is
        // append-only, but SentencePiece decoding is not: appending a token can
        // rewrite earlier whitespace (e.g. Gemma: decode([newline, "  ", ","])
        // collapses a space). Character-count diff then computes dropFirst(0) and
        // silently drops the newly decoded character, including structural JSON
        // commas, which corrupts guided-generation output.
        //
        // The prefix is measured in Unicode scalars, not `Character`s. A
        // `Character` is a grapheme cluster, and a token routinely appends a
        // combining scalar to the cluster the previous token ended: a
        // variation selector (`🏳` then U+FE0F), a zero-width joiner, a
        // combining accent (`e` then U+0301). Compared as `Character`s the
        // old text's last cluster no longer equals the merged cluster, so a
        // cluster-level prefix stops one cluster early and the whole merged
        // cluster is emitted a second time — the consumer receives `🏳🏳️`,
        // `eé`. Scalars compare exactly (no canonical equivalence), and the
        // emitted tail is precisely the scalars the new token added.
        //
        // Upstream fixes: mlx-swift-lm 45693f6 (P1, cluster→count) + #613
        // (`4c3d793`, Character→scalar prefix). ocoreai's CoreAI path is a
        // local reimplementation of this function, so it must stay in step.
        let common = zip(fullText.unicodeScalars, _lastText.unicodeScalars)
            .prefix { $0 == $1 }.count
        let delta = String(fullText.unicodeScalars.dropFirst(common))
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

    /// Honest capability flag: this build links swift-transformers, so a model
    /// that registers successfully gets REAL token counts. The stub variant in
    /// `Models/InferenceStubs.swift` answers `false`; consumers (log line,
    /// `/v1/capabilities`, tests) read this instead of inferring from silence.
    static var isRealTokenizerBackend: Bool { true }

    /// Register a tokenizer loaded from a local directory path.
    func registerTokenizer(for modelId: String, tokenizerPath: String) async throws {
        // throw instead of precondition (already throws method)
        guard !modelId.isEmpty else {
            throw AppError.invalidRequest("modelId must not be empty")
        }
        guard !tokenizerPath.isEmpty else {
            throw AppError.invalidRequest("tokenizerPath must not be empty")
        }

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
        // throw instead of precondition (already throws method)
        guard !modelId.isEmpty else {
            throw AppError.invalidRequest("modelId must not be empty")
        }
        guard !hubId.isEmpty else {
            throw AppError.invalidRequest("hubId must not be empty")
        }

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
    private let _tokenizer: any Tokenizers.Tokenizer
    var underlying: any Tokenizers.Tokenizer { _tokenizer }

    init(modelId: String, tokenizer: any Tokenizer) {
        // default name instead of precondition (tokenizer must not release-crash)
        name = modelId.isEmpty ? "tokenizer" : modelId
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

    /// Tokens of one raw string, **without** chat-template framing.
    ///
    /// ``countTokens(messages:)`` renders the chat template, so sizing a single message
    /// through it charges that message for the conversation's markup (BOS, role wrappers,
    /// end-of-turn). A persisted message row needs its own size, which is what `encode` with
    /// no special tokens answers.
    func countContentTokens(text: String) async throws -> Int {
        _tokenizer.encode(text: text, addSpecialTokens: false).count
    }

    /// Warm up tokenizer with minimal chat template to ensure internal init completes.
    func prewarm() async throws {
        let warmupIds = try _tokenizer.applyChatTemplate(messages: [
            ["role": "user", "content": "Hello"]
        ])
        _ = _tokenizer.decode(tokens: warmupIds)
    }
}

#endif
