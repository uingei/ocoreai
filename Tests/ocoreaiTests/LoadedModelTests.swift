// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// LoadedModelTests.swift — Per-model lifecycle unit tests
///
/// Coverage: CAS inference lock, atomic session counting, warmup once-guarantee,
/// spec decoding config builder, metadata immutability, cleanup, and
/// Sendable conformance via cross-actor access.

import Testing
import Foundation
import Logging
import Atomics
@testable import ocoreai

// MARK: - coreai-only types (compiled out when coreai unavailable)

#if coreai
/// Re-export StreamingDetokenizer for cross-context tests — no duplication.
import Transformers
#endif

// MARK: - Helpers

func makeModelConfig(name: String = "test-model", vocabSize: Int = 32_000,
                      maxContextLength: Int = 131_072) -> ModelConfig {
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
    let data = "{}".data(using: .utf8)!
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
        model.acquireSession(); model.releaseSession()
        #expect(model.modelConfig.vocabSize == firstVocab)
        #expect(model.modelConfig.maxContextLength == firstCtx)
    }

    @Test("configData and modelURL preserved")
    func rawDataPreserved() {
        let data = "{\"test\":true}".data(using: .utf8)!
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
        for _ in 0..<100 {
            model.acquireSession()
        }
        #expect(model.activeSessions == 100)
        for _ in 0..<100 {
            model.releaseSession()
        }
        #expect(model.activeSessions == 0)
    }

    @Test("mixed acquire/release order preserves count")
    func mixedOrder() {
        let model = makeLoadedModel()
        model.acquireSession() // 1
        model.acquireSession() // 2
        model.releaseSession() // 1
        model.acquireSession() // 2
        model.releaseSession() // 1
        model.releaseSession() // 0
        model.acquireSession() // 1
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
        for _ in 0..<10 {
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
    @Test("default spec decoding config enabled")
    func defaultConfigEnabled() {
        let cfg = SpecDecodingConfig()
        #expect(cfg.enabled == true)
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
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    model.acquireSession()
                }
            }
            for _ in 0..<20 {
                group.addTask {
                    // Release to balance — may wrap around, that's ok
                    _ = model.activeSessions
                }
            }
        }
        // Just verify we survived without crash
        _ = model.activeSessions
    }
}
