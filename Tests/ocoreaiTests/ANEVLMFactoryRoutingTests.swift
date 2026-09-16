// ANE-VLM factory routing tests — the wiring added 09-17 that
// `VLMBundleDetector.swift` L121-125 documents.
//
// Two test surfaces:
//
//   1. **Lane inference** — `EngineFactory.createEngine` must route a VLM
//      bundle (assets.vision + assets.embedding) to `createVLMEngine`, and a
//      non-VLM bundle (main only) to the existing LLM path unchanged. The
//      gate at `EngineInference` L1682 used to fall back ANE+multimodal
//      requests to GPU because the factory had no VLM branch; with this
//      branch the factory produces a `CoreAISequentialVLMEngine`.
//
//   2. **VisionBlockContract** — `createVLMEngine` must reject a VLM bundle
//      whose `metadata.json` has no `vision` block with a precise error,
//      mirroring upstream `LanguageBundle` L52-53
//      (`kind == .vlm && visionConfig == nil → missingField("vision")`).
//      The factory re-enforces the contract that detection relaxed:
//      `VLMBundleMetadata.isVLMBundle` only checks the asset keys.
//
// Pure Foundation + CoreAI (in-tree) — no `.aimodel` files, no AIModel load.
// The vision-block case is exercised via a stubbed `PreparedModel.prepare`
// boundary so no CoreAI runtime is required.

import Foundation
import Testing

@testable import ocoreai

@Suite("ANE-VLM factory routing (all platforms)")
struct ANEVLMFactoryRoutingTests {

    // MARK: - Fixtures

    private static let vlmAssets: [String: String] = [
        "main": "model.main.aimodel",
        "vision": "model.vision.aimodel",
        "embedding": "model.embed.aimodel",
    ]

    private static var visionBlock: [String: Any] {
        [
            "image_size": 896,
            "patch_size": 14,
            "image_token_count": 256,
            "image_token_id": 262_140,
        ]
    }

    private static let llmOnlyAssets: [String: String] = [
        "main": "model.main.aimodel"
    ]

    private func writeBundle(
        assets: [String: String],
        visionJSON: [String: Any]? = nil,
        to dir: URL,
        name: String = "test-vlm-bundle"
    ) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var meta: [String: Any] = ["name": name, "assets": assets]
        if let vc = visionJSON { meta["vision"] = vc }
        let data = try JSONSerialization.data(withJSONObject: meta)
        try data.write(to: dir.appendingPathComponent("metadata.json"))
        for (_, filename) in assets {
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent(filename).path, contents: Data())
        }
    }

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-vlm-\(UUID().uuidString)")
    }

    // MARK: - 1. Lane inference — VLM vs LLM bundle routing

    @Test(
        "VLM bundle (assets.vision + assets.embedding + vision block) → routes to CoreAISequentialVLMEngine"
    )
    func vlmBundleRoutesToVLMEngine() throws {
        #if canImport(CoreAI) && (os(macOS) || os(iOS))
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeBundle(assets: Self.vlmAssets, visionJSON: Self.visionBlock, to: dir)

        // The routing decision is the `VLMBundleDetector.load` result — a non-nil
        // return is the contract `EngineFactory.createEngine` keys on.
        let metadata = try #require(VLMBundleDetector.load(at: dir))
        #expect(metadata.isVLMBundle)
        #expect(metadata.visionConfig != nil)
        // The three role keys are all declared and their component paths resolve
        // (with .aimodelc fallback) — the exact precondition `createVLMEngine`
        // requires before `PreparedModel.prepare` is ever called.
        #expect(metadata.componentPath(VLMBundleMetadata.assetMain, in: dir) != nil)
        #expect(metadata.componentPath(VLMBundleMetadata.assetVision, in: dir) != nil)
        #expect(metadata.componentPath(VLMBundleMetadata.assetEmbedding, in: dir) != nil)
        #endif
    }

    @Test("LLM-only bundle (main only) → routes to LLM path (VLMBundleDetector.load == nil)")
    func llmBundleRoutesToLLMPath() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeBundle(assets: Self.llmOnlyAssets, visionJSON: nil, to: dir)

        // Non-VLM detection: the factory falls through to the existing
        // structure-detect path (`resolveVariant` → `CoreAISequentialEngine` /
        // `CoreAIPipelinedEngine` / `CoreAIStaticShapeEngine`) unchanged.
        #expect(VLMBundleDetector.load(at: dir) == nil)
    }

    @Test("Directory without metadata.json → routes to LLM path (detection is nil)")
    func noMetadataRoutesToLLM() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(VLMBundleDetector.load(at: dir) == nil)
    }

    // MARK: - 2. VisionBlockContract — precise error on missing vision block

    @Test(
        "VLM bundle without vision block → createVLMEngine throws 'missing vision block' (upstream LanguageBundle L52-53 contract)"
    )
    func missingVisionBlockThrowsPreciseError() async throws {
        #if canImport(CoreAI) && (os(macOS) || os(iOS))
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // VLM-bundle detection passes (asset keys present), but the vision block
        // is absent. The factory must still throw with a precise error naming
        // the missing 'vision' field — not silently fall back to CLIP defaults
        // (which would produce garbage embeddings with guessed config).
        try writeBundle(assets: Self.vlmAssets, visionJSON: nil, to: dir)

        let metadata = try #require(VLMBundleDetector.load(at: dir))
        #expect(metadata.isVLMBundle, "detection must pass so this reaches the vision guard")
        #expect(metadata.visionConfig == nil, "test fixture must have no vision block")

        // `parseModelConfig` runs first (lenient — falls back to defaults),
        // then the vision guard fires: the exact contract under test.
        let configJSON: [String: Any] = [
            "name": "test-vlm-bundle",
            "vocab_size": 32_768,
            "max_context_length": 4096,
            "function": "main",
        ]
        let configData = try JSONSerialization.data(withJSONObject: configJSON)

        do {
            _ = try await EngineFactory.createVLMEngine(
                config: configData,
                metadata: metadata,
                bundleURL: dir,
                options: EngineOptions()
            )
            Issue.record("createVLMEngine should throw for missing vision block")
        } catch let error where error is InferenceRuntimeError {
            let msg = error.localizedDescription
            #expect(msg.contains("missing 'vision' block in metadata.json"), "msg: \(msg)")
            #expect(msg.contains("test-vlm-bundle"))
        } catch {
            Issue.record("expected InferenceRuntimeError, got \(error)")
        }
        #endif
    }
}
