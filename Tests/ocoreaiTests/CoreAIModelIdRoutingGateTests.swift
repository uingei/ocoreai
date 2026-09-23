// CoreAI gate: a single-slash model id (the `/v1/models` canonical shape —
// `org/name`, exactly like an MLX id) must resolve to the CoreAI local dir
// under ModelStore.root when it carries a real `.aimodel` asset, instead of
// being mis-routed to the MLX path whose load fails (the dir has main.mlirb +
// main.hash, not safetensors) → live 503 "Engine unavailable".
//
// Regression: live-verified on 2026-09-24 — `Qwen2.5-1.5B-CoreAI/qwen2_5_...`
// ready in /v1/models (disk discovery passed), 503 on the chat call
// (EnginePool CoreAI gate `localPath.hasPrefix("/")` refused it).

import Foundation
import Testing

@testable import ocoreai

@Suite("CoreAI gate — model id resolution (single-slash canonical shape)")
struct CoreAIModelIdRoutingGateTests {
    // Per-run isolated ModelStore.root (ModelStoreTests convention: point
    // OCOREAI_MODELS_DIR at a temp dir, restore on scope exit).
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ocoreai-coreai-gate-tests-\(UUID().uuidString)")

    private func setup() throws {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("OCOREAI_MODELS_DIR", root.path, 1)
    }

    private func tearDown() {
        unsetenv("OCOREAI_MODELS_DIR")
        try? FileManager.default.removeItem(at: root)
    }

    private func makeCoreAIBundle(relPath: String) throws -> URL {
        let dir = root.appendingPathComponent(relPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Shape ModelStore.discoverReady enumerates — `<leaf>.aimodel/` as a
        // DIRECT child of the dir (the real .aimodel bundle).
        let leaf = (relPath as NSString).lastPathComponent
        let asset = dir.appendingPathComponent("\(leaf).aimodel", isDirectory: true)
        try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: asset.appendingPathComponent("main.hash"))
        return dir
    }

    @Test("single-slash id with a local CoreAI asset resolves to the rooted dir")
    func singleSlashWithAssetResolves() throws {
        try setup()
        defer { tearDown() }
        let org = "Qwen2.5-1.5B-CoreAI"
        let name = "qwen2_5_1_5b_instruct_4bit_weights_8bit_kv_cache_dynamic"
        try makeCoreAIBundle(relPath: "\(org)/\(name)")

        // Single slash — the /v1/models canonical id shape.
        let expected = root.appendingPathComponent("\(org)/\(name)").path
        let resolved = localCoreAIModelDir(for: "\(org)/\(name)")
        #expect(
            resolved == expected,
            "coreAI-local single-slash id must resolve under ModelStore.root (got: \(String(describing: resolved)))"
        )
    }

    @Test("multi-segment root-relative id also resolves")
    func multiSegmentResolves() throws {
        try setup()
        defer { tearDown() }
        try makeCoreAIBundle(relPath: "Org2/sub/qwen_bundle2")

        let expected = root.appendingPathComponent("Org2/sub/qwen_bundle2").path
        #expect(
            localCoreAIModelDir(for: "Org2/sub/qwen_bundle2") == expected,
            "deeper root-relative ids resolve the same way")
    }

    @Test("single-slash id WITHOUT a local CoreAI asset is rejected")
    func singleSlashWithoutAssetRejected() throws {
        try setup()
        defer { tearDown() }
        // No bundle created for this org/name:
        #expect(
            localCoreAIModelDir(for: "some-hub-org/gemma-4-e2b-it-4bit") == nil,
            "a hub-shaped id with no local .aimodel dir must not enter the gate")
    }

    @Test("hub-prefixed ids are rejected even when a same-named rooted dir holds an asset")
    func hubPrefixRejected() throws {
        try setup()
        defer { tearDown() }
        let org = "Qwen2.5-1.5B-CoreAI"
        let name = "qwen_bundle"
        try makeCoreAIBundle(relPath: "\(org)/\(name)")

        #expect(
            localCoreAIModelDir(for: "hf:\(org)/\(name)") == nil,
            "hf: ids are hub downloads — never CoreAI-local")
        #expect(
            localCoreAIModelDir(for: "mscope:\(org)/\(name)") == nil,
            "mscope: ids are hub downloads — never CoreAI-local")
    }

    @Test("empty and bare-name ids are rejected")
    func emptyOrBareRejected() throws {
        try setup()
        defer { tearDown() }
        #expect(localCoreAIModelDir(for: "") == nil)
        #expect(localCoreAIModelDir(for: "bare-name-no-slash") == nil)
    }

    @Test("absolute-path id still resolves (old behavior preserved)")
    func absolutePathStillResolves() throws {
        try setup()
        defer { tearDown() }
        let org = "Qwen2.5-1.5B-CoreAI"
        let name = "qwen_bundle_abs"
        let dir = try makeCoreAIBundle(relPath: "\(org)/\(name)")

        // Absolute path — the shape that worked before the fix must keep working.
        #expect(localCoreAIModelDir(for: dir.path) == dir.path)
    }

    @Test(
        "CoreAI-local fallback URL(fileURLWithPath: modelId) is invalid — resolvedRoot is authoritative (proves the 2nd-layer bug + fix contract)"
    )
    func coreAILocalFallbackIsInvalidUrl() throws {
        try setup()
        defer { tearDown() }
        let modelId = "Qwen2.5-1.5B-CoreAI/qwen2_5_1_5b_instruct_4bit_weights_8bit_kv_cache_dynamic"
        let dir = try makeCoreAIBundle(relPath: modelId)

        // CoreAI-local id is not MS/HF hub shape → readyWeightsDir is nil.
        #expect(
            MLXModelLoader.readyWeightsDir(for: modelId) == nil,
            "CoreAI root-relative id is not MS/HF hub shape — readyWeightsDir nil")

        // The old EnginePool L700 fallback `?? URL(fileURLWithPath: modelId)` then
        // produces a RELATIVE path (resolved against CWD, not the real bundle under
        // OCOREAI_MODELS_DIR) — not a real dir.
        let oldFallback = URL(fileURLWithPath: modelId)
        var isDir: ObjCBool = false
        let oldFallbackLooksReal =
            FileManager.default.fileExists(atPath: oldFallback.path, isDirectory: &isDir)
            && isDir.boolValue
        #expect(
            !oldFallbackLooksReal,
            "the OLD fallback URL(fileURLWithPath: coreAI-local-id) is not a real dir")
        #expect(
            !ModelStore.hasCoreAIAsset(at: oldFallback),
            "hasCoreAIAsset at OLD fallback is false (why dispatch/warmup said 'has no .aimodel')")

        // The authoritative resolution (localCoreAIModelDir) finds the real bundle
        // root where the .aimodel asset lives — the fix's modelURL.
        let resolvedRoot = localCoreAIModelDir(for: modelId)
        #expect(
            resolvedRoot == dir.path,
            "localCoreAIModelDir returns the bundle root")
        #expect(
            ModelStore.hasCoreAIAsset(at: URL(fileURLWithPath: resolvedRoot!)),
            "hasCoreAIAsset at resolved root is true (ANE gate / warmup pass)")
    }
}
