// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelStore (就绪模型目录) — unit tests
///
/// Coverage:
/// - repo encoding/decoding (HubCache-compatible `models--<ns>--<name>`)
/// - 就绪判定: valid / zero-byte / missing safetensors
/// - hubReadyDir: new-root snapshots layout + legacy home-cache fallback
/// - msReadyDir: master/main revision resolution
/// - discoverReady: mixed HF + MS + local tree, dedup
/// - removeReady: removal across new + legacy roots
///
/// M7: omlx 对齐"就绪模型目录"层 — omlx 对应物 `~/.omlx/models`(settings.py:44/232)。

import Foundation
import Testing

@testable import ocoreai

@Suite("ModelStore: 就绪模型目录")
struct ModelStoreTests {

    // MARK: - helpers

    @discardableResult
    private static func file(at url: URL, contents: Data = Data([1, 2, 3])) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        return url
    }

    private static var tmpRoot: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ocoreai-modelstore-tests-\(UUID().uuidString.prefix(8))")
    }

    // MARK: - repo encoding

    @Test("encodeHubRepo matches HubCache models-- convention")
    func encodeMatchesHubCache() {
        #expect(ModelStore.encodeHubRepo("org/name") == "models--org--name")
        #expect(ModelStore.encodeHubRepo("a/b/c") == "models--a--b--c")
        #expect(ModelStore.encodeHubRepo("org/name.v2") == "models--org--name.v2")
    }

    @Test("encode/decode roundtrip preserves repo id")
    func roundtrip() {
        // Domain contract: hub repo ids are 2-segment (owner/repo) — same as
        // huggingface_hub's python `--` cache encoding. No deeper nesting exists,
        // so decode only needs to split on the first `--`.
        let samples = ["org/name", "org/x--weird", "ns/model.final"]
        for s in samples {
            let encoded = ModelStore.encodeHubRepo(s)
            #expect(
                ModelStore.decodeHubRepo(encoded).flatMap { "\($0.namespace)/\($0.name)" } == s,
                "roundtrip failed for \(s)")
        }
        #expect(ModelStore.decodeHubRepo("not--encoded") == nil)
        #expect(ModelStore.decodeHubRepo("models--") == nil)
    }

    // MARK: - 就绪判定

    @Test("hasValidSafetensors: valid file accepted, zero-byte rejected, missing dir false")
    func validSafetensors() throws {
        let root = Self.tmpRoot
        let fm = FileManager.default

        // valid
        let good = try Self.file(
            at: root.appendingPathComponent("hf/models--org--good/snapshots/main/model.safetensors")
        )
        #expect(ModelStore.hasValidSafetensors(in: good.deletingLastPathComponent()))

        // zero-byte = incomplete download → not ready
        let zeroDir = root.appendingPathComponent("hf/models--org--zero/snapshots/main")
        let zeroFile = zeroDir.appendingPathComponent("model.safetensors")
        try fm.createDirectory(at: zeroDir, withIntermediateDirectories: true)
        try Data().write(to: zeroFile)
        #expect(!ModelStore.hasValidSafetensors(in: zeroDir))

        // missing dir
        #expect(!ModelStore.hasValidSafetensors(in: root.appendingPathComponent("nope")))

        try? fm.removeItem(at: root)
    }

    // MARK: - hubReadyDir

    @Test("hubReadyDir resolves new-root snapshot, then legacy home cache")
    func hubReadyDirResolution() throws {
        let rootURL = Self.tmpRoot.appendingPathComponent("root")
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // New root: blobs + snapshots/main (python-compatible layout)
        let newBlob = try Self.file(
            at:
                rootURL
                .appendingPathComponent("huggingface")
                .appendingPathComponent("models--org--ready")
                .appendingPathComponent("blobs")
                .appendingPathComponent("abc.weight"))
        let newSnap = try Self.file(
            at:
                rootURL
                .appendingPathComponent("huggingface")
                .appendingPathComponent("models--org--ready")
                .appendingPathComponent("snapshots")
                .appendingPathComponent("main")
                .appendingPathComponent("model.safetensors"))
        _ = (newBlob, newSnap)

        // env redirect → root points at our tmp tree
        setenv("OCOREAI_MODELS_DIR", rootURL.path, 1)
        defer { unsetenv("OCOREAI_MODELS_DIR") }

        #expect(
            // /var ↔ /private/var macOS symlink — compare standardized paths
            ModelStore.hubReadyDir("org/ready")?.standardizedFileURL.path
                == newSnap.deletingLastPathComponent().standardizedFileURL.path,
            "expected snapshots/main to be the ready dir")

        // Legacy layout A only (no new root copy) → still found
        let legacyA =
            home
            .appendingPathComponent(".cache")
            .appendingPathComponent("huggingface")
            .appendingPathComponent("hub")
            .appendingPathComponent("models--other--legacy")
            .appendingPathComponent("snapshots")
            .appendingPathComponent("main")
            .appendingPathComponent("model.safetensors")
        try Self.file(at: legacyA)
        #expect(ModelStore.hubReadyDir("other/legacy") != nil)

        // Missing repo → nil
        #expect(ModelStore.hubReadyDir("org/missing") == nil)

        // cleanup (only legacy dir we created — never touch other users' caches)
        try? fm.removeItem(at: legacyA.deletingLastPathComponent())
        try? fm.removeItem(at: rootURL)
    }

    // MARK: - msReadyDir

    @Test("msReadyDir resolves master revision first, main second")
    func msReadyDirResolution() throws {
        let rootURL = Self.tmpRoot.appendingPathComponent("root")
        let fm = FileManager.default

        // master ready
        let master = try Self.file(
            at:
                rootURL
                .appendingPathComponent("modelscope/org/a/master/model.safetensors"))
        // main ready (different repo)
        let main = try Self.file(
            at:
                rootURL
                .appendingPathComponent("modelscope/org/b/main/model.safetensors"))
        _ = (master, main)

        setenv("OCOREAI_MODELS_DIR", rootURL.path, 1)
        defer { unsetenv("OCOREAI_MODELS_DIR") }

        #expect(ModelStore.msReadyDir("org/a") == master.deletingLastPathComponent())
        #expect(ModelStore.msReadyDir("org/b") == main.deletingLastPathComponent())
        #expect(ModelStore.msReadyDir("org/c") == nil)

        try? fm.removeItem(at: rootURL)
    }

    // MARK: - discoverReady

    @Test("discoverReady finds HF + MS + local models, deduped by id")
    func discoverReady() throws {
        let rootURL = Self.tmpRoot.appendingPathComponent("root")
        let fm = FileManager.default

        func touch(_ rel: String) throws -> URL {
            let url = rootURL.appendingPathComponent(rel)
            return try Self.file(at: url)
        }

        _ = try touch("huggingface/models--ns--hf1/snapshots/main/model.safetensors")
        _ = try touch("modelscope/ns/ms1/master/model.safetensors")
        _ = try touch("local/mylocal/model.safetensors")
        // incomplete (zero bytes) must NOT be discovered
        let brokenDir =
            rootURL
            .appendingPathComponent("huggingface/models--ns--broken/snapshots/main")
        let broken = brokenDir.appendingPathComponent("weights.safetensors")
        try FileManager.default.createDirectory(at: brokenDir, withIntermediateDirectories: true)
        try Data().write(to: broken)

        setenv("OCOREAI_MODELS_DIR", rootURL.path, 1)
        defer { unsetenv("OCOREAI_MODELS_DIR") }

        let ready = ModelStore.discoverReady()
        let ids = Set(ready.map(\.id))

        #expect(ids.contains("hf:ns/hf1"), "HF ready model missing: \(ids)")
        #expect(ids.contains("mscope:ns/ms1"), "MS ready model missing: \(ids)")
        #expect(
            ids.contains(where: { $0.hasSuffix("local/mylocal") }),
            "local ready model missing: \(ids)")
        #expect(!ids.contains("hf:ns/broken"), "incomplete model must not be ready: \(ids)")

        // all ready models resolve to an existing weights dir
        for m in ready where m.id != "hf:ns/broken" {
            #expect(fm.fileExists(atPath: m.weightsDir.path), "\(m.id) weights missing")
        }

        try? fm.removeItem(at: rootURL)
    }

    // MARK: - removeReady

    @Test("removeReady deletes new root + legacy location for both providers")
    func removeReady() throws {
        let rootURL = Self.tmpRoot.appendingPathComponent("root")
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        _ = try Self.file(
            at:
                rootURL
                .appendingPathComponent(
                    "huggingface/models--org--del/snapshots/main/model.safetensors"))
        try Self.file(
            at:
                home
                .appendingPathComponent(
                    ".cache/huggingface/hub/models--org--del/snapshots/main/model.safetensors"))

        let msRepo =
            home
            .appendingPathComponent("Library/Caches/ocoreai-modelstore-tests")
            .appendingPathComponent("ms/ns/repoX")
        _ = try Self.file(at: msRepo.appendingPathComponent("master/model.safetensors"))

        setenv("OCOREAI_MODELS_DIR", rootURL.path, 1)
        defer { unsetenv("OCOREAI_MODELS_DIR") }

        try ModelStore.removeReady(repoId: "org/del", source: "huggingFace")
        #expect(
            !fm.fileExists(
                atPath:
                    rootURL
                    .appendingPathComponent("huggingface/models--org--del").path))
        #expect(
            !fm.fileExists(
                atPath:
                    home
                    .appendingPathComponent(".cache/huggingface/hub/models--org--del").path))

        // MS removal via a base under our tmp root (msBases = msRoot first)
        _ = try Self.file(
            at:
                rootURL
                .appendingPathComponent("modelscope/ns/repoY/master/model.safetensors"))
        try ModelStore.removeReady(repoId: "ns/repoY", source: "modelScope")
        #expect(
            !fm.fileExists(
                atPath:
                    rootURL
                    .appendingPathComponent("modelscope/ns/repoY").path))

        try? fm.removeItem(at: msRepo)
        try? fm.removeItem(at: rootURL)
    }
}
