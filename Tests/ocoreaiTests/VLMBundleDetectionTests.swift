// VLM bundle detection unit tests.
//
// Pure Foundation (no CoreAI import) — runs on ALL macOS/iOS versions.
// Covers `VLMBundleDetector` / `VLMBundleMetadata`:
//   - VLM bundle detection (assets.vision + assets.embedding present)
//   - Non-VLM bundle (single main asset only) → nil
//   - Missing metadata.json → nil
//   - VisionConfig parsing (present + absent)
//   - componentPath .aimodel → .aimodelc compiled-variant fallback
//   - isVLMBundle predicate consistency with load()
//
// Provenance: coreai-models (BSD-3, Apple) absorbed 2026-09-16.
//   Upstream: CoreAIShared/Bundle/ModelBundle.swift + LanguageBundle.swift
//   Upstream pin: coreai-models 7359dbc (origin/main)

import Foundation
import Testing

@testable import ocoreai

@Suite("VLMBundleDetector — VLM bundle detection (all platforms)")
struct VLMBundleDetectionTests {

    // MARK: - Fixtures

    private static let vlmAssets: [String: String] = [
        "main": "model.main.aimodel",
        "vision": "model.vision.aimodel",
        "embedding": "model.embed.aimodel",
    ]

    private static let llmOnlyAssets: [String: String] = [
        "main": "model.main.aimodel"
    ]

    /// Built per-call (not a shared static) — Swift 6: a `static let` of
    /// `[String: Any]` is not concurrency-safe (non-Sendable shared mutable).
    private static func visionConfigJSON() -> [String: Any] {
        [
            "image_size": 896,
            "patch_size": 14,
            "image_token_count": 256,
            "image_token_id": 262140,
        ]
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vlm-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeBundle(
        assets: [String: String],
        visionJSON: [String: Any]?,
        to dir: URL
    ) {
        var meta: [String: Any] = [
            "name": "test-vlm-bundle",
            "assets": assets,
        ]
        if let vc = visionJSON { meta["vision"] = vc }
        let data = try! JSONSerialization.data(withJSONObject: meta)
        try! data.write(to: dir.appendingPathComponent("metadata.json"))
        // Create stub asset files so file-existence checks pass
        for (_, filename) in assets {
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent(filename).path, contents: Data()
            )
        }
    }

    // MARK: - Detection

    @Test("VLM bundle detected when assets.vision AND assets.embedding are present")
    func vlmBundleDetected() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        writeBundle(assets: Self.vlmAssets, visionJSON: Self.visionConfigJSON(), to: dir)

        let metadata = VLMBundleDetector.load(at: dir)
        #expect(metadata != nil)
        #expect(metadata?.isVLMBundle == true)
    }

    @Test("Non-VLM bundle (single main asset, no vision/embedding) → nil")
    func nonVLMBundleReturnsNil() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        writeBundle(assets: Self.llmOnlyAssets, visionJSON: nil, to: dir)

        #expect(VLMBundleDetector.load(at: dir) == nil)
    }

    @Test("Directory without metadata.json → nil")
    func noMetadataFile() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Empty directory — no metadata.json written

        #expect(VLMBundleDetector.load(at: dir) == nil)
        #expect(VLMBundleDetector.isVLMBundle(at: dir) == false)
    }

    // MARK: - VisionConfig

    @Test("visionConfig parsed from metadata when vision block is present")
    func visionConfigParsed() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        writeBundle(assets: Self.vlmAssets, visionJSON: Self.visionConfigJSON(), to: dir)

        let metadata = VLMBundleDetector.load(at: dir)!
        #expect(metadata.visionConfig != nil)
        #expect(metadata.visionConfig?.imageSize == 896)
        #expect(metadata.visionConfig?.patchSize == 14)
        #expect(metadata.visionConfig?.imageTokenCount == 256)
        #expect(metadata.visionConfig?.imageTokenId == 262140)
    }

    @Test("visionConfig nil when metadata has no vision block, isVLMBundle still true")
    func noVisionBlockStillDetected() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        writeBundle(assets: Self.vlmAssets, visionJSON: nil, to: dir)

        let metadata = VLMBundleDetector.load(at: dir)
        #expect(metadata != nil)
        #expect(metadata?.isVLMBundle == true)
        #expect(metadata?.visionConfig == nil)
    }

    // MARK: - componentPath

    @Test("componentPath falls back to .aimodelc compiled variant when .aimodel absent")
    func componentPathCompiledFallback() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        writeBundle(assets: Self.vlmAssets, visionJSON: nil, to: dir)
        let metadata = VLMBundleDetector.load(at: dir)!

        // Simulate coreai-build compile: create .aimodelc, remove .aimodel source
        let visionSrc = dir.appendingPathComponent("model.vision.aimodel")
        let visionCmp = dir.appendingPathComponent("model.vision.aimodelc")
        FileManager.default.createFile(atPath: visionCmp.path, contents: Data())
        try! FileManager.default.removeItem(at: visionSrc)

        let resolved = metadata.componentPath("vision", in: dir)
        #expect(resolved?.lastPathComponent == "model.vision.aimodelc")
    }

    @Test("componentPath returns nil when no variant of the asset file exists")
    func componentPathFileAbsent() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        writeBundle(assets: Self.vlmAssets, visionJSON: nil, to: dir)
        let metadata = VLMBundleDetector.load(at: dir)!

        // Remove the embedding .aimodel → componentPath for it returns nil
        try! FileManager.default.removeItem(
            at: dir.appendingPathComponent("model.embed.aimodel"))

        #expect(metadata.componentPath("embedding", in: dir) == nil)
    }

    @Test("componentPath for undeclared key returns nil")
    func componentPathUndeclaredKey() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        writeBundle(assets: Self.vlmAssets, visionJSON: nil, to: dir)
        let metadata = VLMBundleDetector.load(at: dir)!

        #expect(metadata.componentPath("unknown_asset", in: dir) == nil)
    }

    // MARK: - isVLMBundle predicate

    @Test("isVLMBundle predicate is consistent with load() result")
    func predicateConsistent() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        writeBundle(assets: Self.vlmAssets, visionJSON: nil, to: dir)

        #expect(VLMBundleDetector.isVLMBundle(at: dir) == true)
        #expect(VLMBundleDetector.load(at: dir) != nil)

        // Non-VLM dir → false
        let dir2 = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir2) }
        writeBundle(assets: Self.llmOnlyAssets, visionJSON: nil, to: dir2)

        #expect(VLMBundleDetector.isVLMBundle(at: dir2) == false)
    }

    @Test("VLMBundleMetadata name is preserved from metadata.json")
    func namePreserved() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        writeBundle(assets: Self.vlmAssets, visionJSON: nil, to: dir)

        #expect(VLMBundleDetector.load(at: dir)?.name == "test-vlm-bundle")
    }
}
