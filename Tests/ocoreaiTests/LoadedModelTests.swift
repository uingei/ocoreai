// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// LoadedModelTests.swift — Per-model lifecycle unit tests
///
/// Coverage: CAS inference lock, atomic session counting, warmup once-guarantee,
/// spec decoding config builder, metadata immutability, cleanup, and
/// Sendable conformance via cross-actor access.

import Atomics
import Foundation
import Logging
import MLXGuidedGeneration
import MLXLMCommon
import Testing
import ocoreaiTestUtilities

@testable import ocoreai

// MARK: - Helpers

func makeModelConfig(
    name: String = "test-model", vocabSize: Int = 32_000,
    maxContextLength: Int = 131_072
) -> ModelConfig {
    ModelConfig(
        name: name,
        function: "default",
        vocabSize: vocabSize,
        maxContextLength: maxContextLength,
        chunkThreshold: 8,
        prefillChunkSize: 4096
    )
}

func makeLoadedModel(config: ModelConfig = makeModelConfig()) -> LoadedModel {
    let data = Data("{}".utf8)
    return LoadedModel(
        configData: data,
        modelURL: URL(fileURLWithPath: "/tmp/test-model"),
        modelConfig: config,
        logger: Logger(label: "test")
    )
}

// MARK: - Metadata

@Suite("LoadedModel Metadata")
struct MetadataTests {
    @Test("config preserved after construction")
    func configPreserved() {
        let cfg = makeModelConfig(vocabSize: 128_256, maxContextLength: 262_144)
        let model = makeLoadedModel(config: cfg)
        #expect(model.modelConfig.vocabSize == 128_256)
        #expect(model.modelConfig.maxContextLength == 262_144)
        #expect(model.modelConfig.function == "default")
    }

    @Test("metadata immutable — same instance always returns same values")
    func immutableFields() {
        let model = makeLoadedModel()
        let firstVocab = model.modelConfig.vocabSize
        let firstCtx = model.modelConfig.maxContextLength
        // Trigger session ops to prove immutability under mutation
        model.acquireSession()
        model.releaseSession()
        #expect(model.modelConfig.vocabSize == firstVocab)
        #expect(model.modelConfig.maxContextLength == firstCtx)
    }

    @Test("configData and modelURL preserved")
    func rawDataPreserved() {
        let data = Data("{\"test\":true}".utf8)
        let cfg = makeModelConfig()
        let model = LoadedModel(
            configData: data,
            modelURL: URL(fileURLWithPath: "/models/test"),
            modelConfig: cfg,
            logger: Logger(label: "test")
        )
        #expect(model.configData == data)
        #expect(model.modelURL.path == "/models/test")
    }
}

// MARK: - Session Counting

@Suite("LoadedModel Session Counting")
struct SessionCountTests {
    @Test("new model starts with zero sessions")
    func zeroSessions() {
        let model = makeLoadedModel()
        #expect(model.activeSessions == 0)
    }

    @Test("acquire increments session count")
    func acquireIncrements() {
        let model = makeLoadedModel()
        model.acquireSession()
        #expect(model.activeSessions == 1)
        model.acquireSession()
        #expect(model.activeSessions == 2)
    }

    @Test("release decrements session count")
    func releaseDecrements() {
        let model = makeLoadedModel()
        model.acquireSession()
        model.acquireSession()
        model.releaseSession()
        #expect(model.activeSessions == 1)
        model.releaseSession()
        #expect(model.activeSessions == 0)
    }

    @Test("rapid acquire/release maintains counter accuracy")
    func rapidCycle() {
        let model = makeLoadedModel()
        for _ in 0 ..< 100 {
            model.acquireSession()
        }
        #expect(model.activeSessions == 100)
        for _ in 0 ..< 100 {
            model.releaseSession()
        }
        #expect(model.activeSessions == 0)
    }

    @Test("mixed acquire/release order preserves count")
    func mixedOrder() {
        let model = makeLoadedModel()
        model.acquireSession()  // 1
        model.acquireSession()  // 2
        model.releaseSession()  // 1
        model.acquireSession()  // 2
        model.releaseSession()  // 1
        model.releaseSession()  // 0
        model.acquireSession()  // 1
        #expect(model.activeSessions == 1)
    }
}

// MARK: - Inference Contention Guard

@Suite("LoadedModel Inference Contention")
struct InferenceGuardTests {
    @Test("first CAS acquire succeeds")
    func firstAcquire() {
        let model = makeLoadedModel()
        #expect(model.tryAcquireInference() == true)
    }

    @Test("second concurrent acquire fails while first holds")
    func contentionBlocksSecond() {
        let model = makeLoadedModel()
        #expect(model.tryAcquireInference() == true)
        #expect(model.tryAcquireInference() == false)
    }

    @Test("release allows re-acquire")
    func releaseAllowsReacquire() {
        let model = makeLoadedModel()
        #expect(model.tryAcquireInference() == true)
        model.releaseInference()
        #expect(model.tryAcquireInference() == true)
    }

    @Test("acquire/release cycle — 10 iterations")
    func cycles() {
        let model = makeLoadedModel()
        for _ in 0 ..< 10 {
            #expect(model.tryAcquireInference() == true)
            model.releaseInference()
        }
    }

    @Test("inference guard is independent of session count")
    func independentOfSession() {
        let model = makeLoadedModel()
        model.acquireSession()
        model.acquireSession()
        #expect(model.activeSessions == 2)
        // Inference guard is separate CAS
        #expect(model.tryAcquireInference() == true)
        #expect(model.tryAcquireInference() == false)
        model.releaseInference()
        #expect(model.tryAcquireInference() == true)
    }
}

// MARK: - Cleanup

@Suite("LoadedModel Cleanup")
struct CleanupTests {
    @Test("cleanup resets session count to zero")
    func resetsSessionCount() {
        let model = makeLoadedModel()
        model.acquireSession()
        model.acquireSession()
        model.acquireSession()
        #expect(model.activeSessions == 3)
        model.cleanup()
        #expect(model.activeSessions == 0)
    }

    @Test("cleanup after cleanup is idempotent")
    func idempotentCleanup() {
        let model = makeLoadedModel()
        model.acquireSession()
        model.cleanup()
        model.cleanup()
        #expect(model.activeSessions == 0)
    }

    @Test("cleanup does not affect inference guard")
    func cleanupDoesNotAffectGuard() {
        let model = makeLoadedModel()
        #expect(model.tryAcquireInference() == true)
        model.cleanup()
        // Guard still held
        #expect(model.tryAcquireInference() == false)
        model.releaseInference()
    }
}

// MARK: - Warmup Guard (CAS once)

@Suite("LoadedModel Warmup")
struct WarmupTests {
    @Test("prewarm runs at least once without error")
    func prewarmCompletes() async throws {
        let model = makeLoadedModel()
        // In stub mode (no coreai/mlx), prewarm is a no-op log — should not throw
        try await model.prewarmIfNeeded(4)
    }

    @Test("failed warmup trip is observable as prewarmFullySucceeded == false")
    func degradedPrewarmIsObservable() async throws {
        let model = makeLoadedModel()
        // Pre-warmup state: no failure observed yet.
        #expect(model.prewarmFullySucceeded == true)
        // Stub environment: no mlxModelHandle → warmup trip early-returns
        // without running. The trip did NOT complete, so the honest flag
        // must be false — the exact "Missing hash file" case the
        // "first request will be fast" log must not claim for.
        try await model.prewarmIfNeeded(4)
        #expect(model.prewarmFullySucceeded == false)
        // Idempotent under repeated calls (CAS-guarded).
        try await model.prewarmIfNeeded(4)
        #expect(model.prewarmFullySucceeded == false)
    }

    @Test("prewarm can be called multiple times without error")
    func prewarmIdempotent() async throws {
        let model = makeLoadedModel()
        try await model.prewarmIfNeeded(4)
        try await model.prewarmIfNeeded(4)
        try await model.prewarmIfNeeded(4)
    }
}

// MARK: - Speculative Decoding Config

@Suite("LoadedModel Speculative Decoding")
struct SpecDecodingTests {
    @Test("default spec decoding config disabled")
    func defaultConfigEnabled() {
        let cfg = SpecDecodingConfig()
        #expect(cfg.enabled == false)
        #expect(cfg.mode == "traditional")
        #expect(cfg.numDraftTokens == 5)
    }

    @Test("spec decoding disabled returns nil from createSpeculativeConfig")
    func disabledReturnsNil() {
        let model = makeLoadedModel()
        model.setSpecDecodingConfig(.init(enabled: false))
        // No MLX handle set, so always nil in stub mode — but config is stored
        #expect(model.createSpeculativeConfig() == nil)
    }

    @Test("numDraftTokens clamped to 1-16")
    func draftTokensClamped() {
        let low = SpecDecodingConfig(numDraftTokens: 0)
        #expect(low.numDraftTokens == 1)
        let high = SpecDecodingConfig(numDraftTokens: 100)
        #expect(high.numDraftTokens == 16)
        let mid = SpecDecodingConfig(numDraftTokens: 7)
        #expect(mid.numDraftTokens == 7)
    }

    @Test("memory policy defaults to recommendedWorkingSet")
    func memoryPolicyDefault() {
        let cfg = SpecDecodingConfig()
        #expect(cfg.memoryPolicy == "recommendedWorkingSet")
    }

    @Test("memory policy can be nil")
    func memoryPolicyOptional() {
        let cfg = SpecDecodingConfig(memoryPolicy: nil)
        #expect(cfg.memoryPolicy == nil)
    }
}

// MARK: - Cross-Actor Sendable Safety

@Suite("LoadedModel Sendable Safety")
struct SendableSafetyTests {
    @Test("model can be accessed from actor without isolation error")
    func actorAccess() async {
        let model = makeLoadedModel()
        model.acquireSession()

        @MainActor func mainAccess(m: LoadedModel) -> Int {
            m.activeSessions
        }

        // Verify cross-actor read does not crash
        let count = await mainAccess(m: model)
        #expect(count == 1)
    }

    @Test("concurrent session ops from TaskGroup do not crash")
    func concurrentAccess() async {
        let model = makeLoadedModel()
        // One task = one session's lifetime: acquire → hold → release.
        // Tasks still overlap (the point: cross-task atomicity must hold),
        // but each release pairs with its own completed acquire. The
        // global-unordered variant (all 20 releases allowed to land before
        // any acquire) is NOT a valid model: `releaseSession` is clamped at
        // zero by P0 design to survive unmatched releases on error paths,
        // so a dropped decrement there is intentional — not a race to assert
        // against.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    model.acquireSession()
                    model.releaseSession()
                }
            }
        }
        // Every pair completed — counter must be zero
        #expect(model.activeSessions == 0)
    }
}

// MARK: - Constraint template cache (upstream #732 freshMatcher adoption)

/// One token per character: the fast-forward detokenization path validates
/// 1:1 against this mapping, and tests read token IDs as character indexes.
private let grammarTestVocab: [String] = [
    "{", "}", "\"", ":", ",",
    "a", "b", "c", "d", "e", "i", "j", "m", "n", "o", "p", "q", "r", "s",
    "t", "u", "y", "2", "4",
    "<eos>",
]

/// Minimal `MLXLMCommon.Tokenizer` for grammar tests: one token per char,
/// so the grammar's fast-forward path round-trips through `encode`.
private struct GrammarTestTokenizer: MLXLMCommon.Tokenizer {
    private let tokenToID: [String: Int]
    private let idToToken: [String]

    init(vocab: [String]) {
        idToToken = vocab
        tokenToID = Dictionary(uniqueKeysWithValues: vocab.enumerated().map { ($1, $0) })
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        text.map { tokenToID[String($0)] ?? 0 }
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.compactMap { id in
            (id >= 0 && id < idToToken.count) ? idToToken[id] : nil
        }.joined()
    }

    func convertTokenToId(_ token: String) -> Int? { tokenToID[token] }

    func convertIdToToken(_ id: Int) -> String? {
        (id >= 0 && id < idToToken.count) ? idToToken[id] : nil
    }

    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}

@Suite("LoadedModel constraint template cache (upstream #732 freshMatcher)")
struct ConstraintTemplateCacheTests {
    /// Both schemas stay inside `grammarTestVocab` (one token per char).
    private static let objectSchema =
        #"{"type":"object","properties":{"n":{"type":"number"}},"required":["n"]}"#
    private static let arraySchema = #"{"type":"array","items":{"type":"number"}}"#

    private static func matcher(
        _ model: LoadedModel, schema: String, fastForward: Bool
    ) throws -> GrammarConstraint {
        let tokenizer = try GrammarTokenizer(
            vocab: grammarTestVocab, vocabType: .raw,
            eosTokenId: Int32(grammarTestVocab.count - 1))
        return try model.getOrCreateConstraint(
            grammarTokenizer: tokenizer,
            hostTokenizer: GrammarTestTokenizer(vocab: grammarTestVocab),
            jsonSchema: schema,
            fastForward: fastForward)
    }

    @Test("the template is stored once and reused across requests")
    func templateStoredOnce() throws {
        let model = makeLoadedModel()
        let first = try Self.matcher(model, schema: Self.objectSchema, fastForward: true)
        let second = try Self.matcher(model, schema: Self.objectSchema, fastForward: true)
        // Pre-fix shape: clone() throws on lm's vendored xgrammar v0.1.30
        // (no Fork), the template was evicted, and every request recompiled.
        #expect(model._constraintTemplates.count == 1)
        #expect(first !== second)
        _ = try Self.matcher(model, schema: Self.objectSchema, fastForward: true)
        #expect(model._constraintTemplates.count == 1)
    }

    @Test("distinct schemas keep distinct templates")
    func distinctSchemasDistinctTemplates() throws {
        let model = makeLoadedModel()
        _ = try Self.matcher(model, schema: Self.objectSchema, fastForward: true)
        _ = try Self.matcher(model, schema: Self.arraySchema, fastForward: true)
        #expect(model._constraintTemplates.count == 2)
    }

    @Test("every matcher starts at the grammar's initial state")
    func matchersStartFresh() throws {
        let model = makeLoadedModel()
        let a = try Self.matcher(model, schema: Self.objectSchema, fastForward: true)
        let b = try Self.matcher(model, schema: Self.objectSchema, fastForward: true)
        let maskA = try a.computeMask()
        let maskB = try b.computeMask()
        #expect(maskA.isTerminated == false)
        #expect(maskA.mask == maskB.mask)
    }

    @Test("advancing one matcher does not move the other")
    func matchersAreIndependent() throws {
        let model = makeLoadedModel()
        let a = try Self.matcher(model, schema: Self.objectSchema, fastForward: true)
        let b = try Self.matcher(model, schema: Self.objectSchema, fastForward: true)
        let maskBefore = try b.computeMask()
        _ = try a.commitToken(0)  // grammarTestVocab[0] == "{"
        let maskAfter = try b.computeMask()
        #expect(maskAfter.mask == maskBefore.mask)
        #expect(maskAfter.isTerminated == maskBefore.isTerminated)
    }

    /// Token ids a mask admits, in vocab order — the observable a sampler acts on.
    ///
    /// This suite asserts closure through the mask rather than through
    /// `isTerminated`, because measured on lm's vendored xgrammar v0.1.30 (pin
    /// `4ab267996`, byte-identical to the pin this was first measured at) a completed JSON value
    /// leaves `isTerminated` false while the
    /// mask admits exactly `<eos>`: the flag reports an empty rule stack, the mask
    /// reports "nothing but EOS is admissible", and only the second is a promise a
    /// sampler can keep. `ConstrainedGenerationSession.isTerminated` ORs the flag
    /// with `allTokensBlocked` for the same reason.
    private static func allowedTokens(_ result: MaskResult) -> [Int] {
        result.mask.enumerated().flatMap { word, bits in
            (0 ..< 32).compactMap { bit in
                guard bits & (1 << bit) != 0 else { return nil }
                let id = word * 32 + bit
                return id < grammarTestVocab.count ? id : nil
            }
        }
    }

    @Test("a cached template still closes a valid JSON value")
    func validJsonClosesTheGrammar() throws {
        let model = makeLoadedModel()
        // `{"n":42}` — each char is one token of grammarTestVocab. Both faces of
        // the cache run: the miss compiles and stores, the hit hands out a matcher
        // over the stored template, and a stub or spent matcher fails the second.
        let sequence = ["{", "\"", "n", "\"", ":", "4", "2", "}"]
        let eos = grammarTestVocab.count - 1
        for request in 1 ... 2 {
            let constraint = try Self.matcher(model, schema: Self.objectSchema, fastForward: false)
            for ch in sequence {
                guard let id = grammarTestVocab.firstIndex(of: ch) else {
                    Issue.record("test vocab lost \(ch)")
                    return
                }
                _ = try constraint.commitToken(Int32(id))
            }
            let allowed = Self.allowedTokens(try constraint.computeMask())
            let names = allowed.map { grammarTestVocab[$0] }
            #expect(
                allowed == [eos],
                "request \(request) after the closing brace: only EOS may follow, got \(names)")
        }
    }
}
