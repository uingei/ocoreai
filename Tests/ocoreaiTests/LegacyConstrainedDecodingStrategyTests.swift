import Foundation
import Testing
import Tokenizers

@testable import ocoreai

#if canImport(CoreAI)

// #248 (coreai-models 3e172fb) — absorption test.
//
// Pins the engine-agnostic constrained-decoding loop (`ConstrainedDecodingStrategy`)
// against a mock `InferenceEngine` that mirrors the `CoreAIStaticShapeEngine`
// capability contract (`supportsLogits = true`, per-step `InferenceOutput` with
// `logits`), and a mock `Tokenizers.Tokenizer` (upstream coreai-models
// `MockTokenizer` byte-encoding shape).
//
// Contract under test (per-step): `generate(includeLogits: true) → output.logits`
// → xgrammar `applyMask` → `CompositeSampler.sample` → `session.acceptToken` →
// `inputTokens.append` (prefix reuse) → next step.
//
// Determinism: bias is `'5'` (id 53) against a `{"type":"integer"}` schema.
// In xgrammar's integer grammar `'5'` is a valid next token at every step of a
// (possibly empty so far) digit run, so the first `maxTokens` steps succeed and
// the loop terminates only on the token budget — exercising the full per-step
// contract, not the early-termination path.
//
// Modeled on `CoreAILiveGenerateTests` (gate `#if canImport(CoreAI)` +
// `#available` per function) because swift-testing's `@Suite`/`@Test` macros
// cannot be combined with `@available` on the struct/function declaration.

// MARK: - Test config

@available(macOS 27.0, iOS 27.0, *)
private struct TestConfig: Codable, Sendable {
    var maxContextLength: Int { 2048 }
    var prefillChunkSize: Int { 512 }
    var chunkThreshold: Int { 256 }
}

@available(macOS 27.0, iOS 27.0, *)
extension TestConfig: InferenceConfiguration {}

// MARK: - Mock engine (`supportsLogits = true`, one token per `generate` call)

/// Yields a single `InferenceOutput` per `generate()`:
/// `logits[i] = 0` for the bias token, `-infinity` elsewhere (greedy argmax →
/// bias when unmasked; `-infinity` everywhere else when the mask excludes the
/// bias). Mirrors `CoreAIStaticShapeEngine`'s `generate` → `next()` shape.
@available(macOS 27.0, iOS 27.0, *)
private final class MockLogitsEngine: InferenceEngine, @unchecked Sendable {
    // @unchecked Sendable: `bias`/`vocabSize` are let-initialized before use.
    typealias TokenId = Int32
    typealias Config = TestConfig

    let bias: Int32
    let vocabSize: Int

    init(bias: Int32, vocabSize: Int) {
        self.bias = bias
        self.vocabSize = vocabSize
    }

    var supportsLogits: Bool { true }
    var lastPrefixHitCount: Int { 0 }
    var processedTokenCount: Int { 0 }
    var isBusy: Bool { false }
    var config: TestConfig { TestConfig() }

    func reset() async throws {}
    func reset(to tokenIndex: Int) async throws {}
    func warmup(queryLength: Int, sampling: SamplingConfiguration?) async throws {}
    func cancel() async throws {}

    func generate(
        with input: [Int32],
        samplingConfiguration: SamplingConfiguration,
        inferenceOptions: InferenceOptions
    ) async throws -> OneTokenSequence {
        OneTokenSequence(
            bias: bias, vocabSize: vocabSize, includeLogits: inferenceOptions.includeLogits)
    }
}

/// One token per sequence: `next()` returns the bias/logits output once, then nil.
@available(macOS 27.0, iOS 27.0, *)
private final class OneTokenSequence: InferenceOutputSequence, @unchecked Sendable {
    // @unchecked Sendable: `consumed` is touched sequentially by one consumer.
    private let bias: Int32
    private let vocabSize: Int
    private let includeLogits: Bool
    private let store = StopReasonBox()
    var consumed = false

    init(bias: Int32, vocabSize: Int, includeLogits: Bool) {
        self.bias = bias
        self.vocabSize = vocabSize
        self.includeLogits = includeLogits
    }

    var stopReason: InferenceStopReason? { store.reason }
    func setStopReason(_ reason: InferenceStopReason) { store.set(reason) }

    struct Iterator: AsyncIteratorProtocol {
        let seq: OneTokenSequence
        mutating func next() async throws -> InferenceOutput? {
            if seq.consumed { return nil }
            seq.consumed = true
            let logits: [LogitsScalarType] = .init(repeating: -.infinity, count: seq.vocabSize)
            var masked = logits
            masked[Int(seq.bias)] = 0.0
            return InferenceOutput(tokenId: seq.bias, logits: seq.includeLogits ? masked : nil)
        }
    }
    func makeAsyncIterator() -> Iterator { .init(seq: self) }
}

@available(macOS 27.0, iOS 27.0, *)
private final class StopReasonBox: @unchecked Sendable {
    private var _reason: InferenceStopReason?
    var reason: InferenceStopReason? { _reason }
    func set(_ r: InferenceStopReason) { _reason = r }
}

// MARK: - Engine with `supportsLogits = false` (no per-step logits)

@available(macOS 27.0, iOS 27.0, *)
private final class NoLogitsEngine: InferenceEngine, @unchecked Sendable {
    // @unchecked Sendable: stateless.
    typealias TokenId = Int32
    typealias Config = TestConfig

    var supportsLogits: Bool { false }
    var lastPrefixHitCount: Int { 0 }
    var processedTokenCount: Int { 0 }
    var isBusy: Bool { false }
    var config: TestConfig { TestConfig() }

    func reset() async throws {}
    func reset(to tokenIndex: Int) async throws {}
    func warmup(queryLength: Int, sampling: SamplingConfiguration?) async throws {}
    func cancel() async throws {}

    func generate(
        with input: [Int32],
        samplingConfiguration: SamplingConfiguration,
        inferenceOptions: InferenceOptions
    ) async throws -> OneTokenSequence {
        OneTokenSequence(bias: 0, vocabSize: 1, includeLogits: false)
    }
}

// MARK: - Mock tokenizer (byte vocabulary, upstream `MockTokenizer` shape)

@available(macOS 27.0, iOS 27.0, *)
private struct MockByteTokenizer: Tokenizers.Tokenizer, Sendable {
    let vocabSize: Int
    init(vocabSize: Int = 256) { self.vocabSize = vocabSize }

    var bosToken: String? { nil }
    var bosTokenId: Int? { nil }
    var eosToken: String? { nil }
    var eosTokenId: Int? { nil }
    var unknownToken: String? { "<unk>" }
    var unknownTokenId: Int? { 0 }
    var hasChatTemplate: Bool { false }

    func encode(text: String) -> [Int] {
        Array(text.utf8).map { Int($0) }.filter { $0 < vocabSize }
    }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { encode(text: text) }
    func callAsFunction(_ text: String, addSpecialTokens: Bool) -> [Int] { encode(text: text) }

    func decode(tokens: [Int]) -> String {
        String(
            decoding: tokens.filter { (0 ..< vocabSize).contains($0) }.map {
                UInt8(truncatingIfNeeded: $0)
            }, as: UTF8.self)
    }
    func decode(tokens: [Int], skipSpecialTokens: Bool) -> String { decode(tokens: tokens) }

    func tokenize(text: String) -> [String] {
        Array(text.utf8).map { String(decoding: [$0], as: UTF8.self) }
    }
    func convertTokenToId(_ token: String) -> Int? {
        guard let first = token.unicodeScalars.first else { return nil }
        let code = Int(first.value)
        return (0 ..< vocabSize).contains(code) ? code : nil
    }
    func convertTokensToIds(_ tokens: [String]) -> [Int?] { tokens.map { convertTokenToId($0) } }
    func convertIdToToken(_ id: Int) -> String? {
        guard (0 ..< vocabSize).contains(id) else { return nil }
        return String(decoding: [UInt8(id)], as: UTF8.self)
    }
    func convertIdsToTokens(_ ids: [Int]) -> [String?] { ids.map { convertIdToToken($0) } }

    func applyChatTemplate(messages: [Tokenizers.Message]) throws -> [Int] {
        messages.compactMap { $0["content"] as? String }.joined()
            .utf8.map { Int($0) }.filter { $0 < vocabSize }
    }
    func applyChatTemplate(messages: [Tokenizers.Message], tools: [Tokenizers.ToolSpec]?) throws
        -> [Int]
    {
        try applyChatTemplate(messages: messages)
    }
    func applyChatTemplate(
        messages: [Tokenizers.Message], tools: [Tokenizers.ToolSpec]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try applyChatTemplate(messages: messages)
    }
    func applyChatTemplate(
        messages: [Tokenizers.Message], chatTemplate: Tokenizers.ChatTemplateArgument
    ) throws -> [Int] {
        try applyChatTemplate(messages: messages)
    }
    func applyChatTemplate(messages: [Tokenizers.Message], chatTemplate: String) throws -> [Int] {
        try applyChatTemplate(messages: messages)
    }
    func applyChatTemplate(
        messages: [Tokenizers.Message], chatTemplate: Tokenizers.ChatTemplateArgument?,
        addGenerationPrompt: Bool, truncation: Bool, maxLength: Int?, tools: [Tokenizers.ToolSpec]?
    ) throws -> [Int] {
        try applyChatTemplate(messages: messages)
    }
    func applyChatTemplate(
        messages: [Tokenizers.Message], chatTemplate: Tokenizers.ChatTemplateArgument?,
        addGenerationPrompt: Bool, truncation: Bool, maxLength: Int?,
        tools: [Tokenizers.ToolSpec]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try applyChatTemplate(messages: messages)
    }
}

// MARK: - Tests

@Suite("ConstrainedDecodingStrategy (#248 legacy path)")
struct LegacyConstrainedDecodingStrategyTests {

    @Test(
        "per-step loop: includeLogits → mask → sample → accept → 4 grammar-allowed tokens"
    )
    func drivesEnginePerStep() async throws {
        guard #available(macOS 27.0, iOS 27.0, *) else {
            Issue.record("requires macOS 27 / iOS 27")
            return
        }
        // '5' (53) is a valid next token at every integer-grammar step.
        let schema = #"{"type":"integer"}"#
        let expectedBias: Int32 = 53
        let vocabSize = 256
        let maxTokens = 4

        let engine = MockLogitsEngine(bias: expectedBias, vocabSize: vocabSize)
        let tokenizer = MockByteTokenizer(vocabSize: vocabSize)

        let resultSeq = try await ConstrainedDecodingStrategy(jsonSchema: schema).decode(
            from: .rawText("x"),
            tokenizer: tokenizer,
            inferenceEngine: engine,
            samplingConfiguration: SamplingConfiguration(temperature: 0),
            options: InferenceOptions(maxTokens: maxTokens, includeLogits: true),
            stopSequences: StopSequences(for: tokenizer)
        )

        var tokenIds: [Int32] = []
        for try await result in resultSeq {
            tokenIds.append(result.tokenId)
        }
        #expect(
            tokenIds.count == maxTokens,
            "expected \(maxTokens) constrained tokens, got \(tokenIds.count)")
        #expect(
            tokenIds.allSatisfy { $0 == expectedBias },
            "every step must sample the bias token (mask allows '5' at every integer step)")
    }

    @Test("no-logits engine throws ConstrainedGenerationError.generationFailed on iteration")
    func noLogitsThrows() async throws {
        guard #available(macOS 27.0, iOS 27.0, *) else {
            Issue.record("requires macOS 27 / iOS 27")
            return
        }
        let schema = #"{"type":"integer"}"#
        let engine = NoLogitsEngine()
        let tokenizer = MockByteTokenizer(vocabSize: 256)

        // decode() builds the session eagerly (no engine call); the
        // no-logits failure surfaces on the first iteration step.
        let resultSeq = try await ConstrainedDecodingStrategy(jsonSchema: schema).decode(
            from: .rawText("x"),
            tokenizer: tokenizer,
            inferenceEngine: engine,
            samplingConfiguration: SamplingConfiguration(temperature: 0),
            options: InferenceOptions(maxTokens: 1, includeLogits: true),
            stopSequences: StopSequences(for: tokenizer)
        )

        do {
            for try await _ in resultSeq {}
            Issue.record(
                "Expected ConstrainedGenerationError.generationFailed, iteration returned OK")
        } catch is ConstrainedGenerationError {
            // Expected: the strategy surfaced the no-logits failure.
        }
    }
}

#endif
