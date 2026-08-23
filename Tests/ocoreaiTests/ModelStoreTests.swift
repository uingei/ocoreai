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

@Suite("ModelStore: 就绪模型目录", .serialized)
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
        _ = try Self.file(
            at: rootURL.appendingPathComponent("huggingface/models--org--ready/blobs/abc.weight"))
        let newSnap = try Self.file(
            at:
                rootURL
                .appendingPathComponent("huggingface")
                .appendingPathComponent("models--org--ready")
                .appendingPathComponent("snapshots")
                .appendingPathComponent("main")
                .appendingPathComponent("model.safetensors"))
        _ = newSnap

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

        // master ready(规范平铺,omlx 对齐)
        let master = try Self.file(
            at:
                rootURL
                .appendingPathComponent("org/a/model.safetensors"))
        // main ready(遗留三级:msRoot/modelscope/org/b/main)
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
        _ = try touch("org/ms1/model.safetensors")  // 规范平铺(omlx 对齐)
        _ = try touch("modelscope/legacy-ms/m1/master/model.safetensors")  // 遗留三级
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
        #expect(ids.contains("mscope:org/ms1"), "MS flat ready model missing: \(ids)")
        #expect(ids.contains("mscope:legacy-ms/m1"), "MS legacy ready model missing: \(ids)")
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

        // 规范平铺写入(root/org/del,omlx 对齐)+ 遗留三级(msRoot/modelscope/org/del/…)
        _ = try Self.file(
            at:
                rootURL
                .appendingPathComponent("org/del/model.safetensors"))
        _ = try Self.file(
            at:
                rootURL
                .appendingPathComponent("modelscope/org/del/master/model.safetensors"))
        _ = try Self.file(
            at:
                home
                .appendingPathComponent(
                    ".cache/huggingface/hub/models--org--del/snapshots/main/model.safetensors"))

        let msFlat =
            home
            .appendingPathComponent("Library/Caches/ocoreai-modelstore-tests")
            .appendingPathComponent("ms/ns/repoX")
        _ = try Self.file(at: msFlat.appendingPathComponent("master/model.safetensors"))

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

        // MS 删除:规范平铺 org/repoY + 遗留三级 modelscope/org/repoY 一次清净(同一 repoId)
        _ = try Self.file(
            at:
                rootURL
                .appendingPathComponent("org/repoY/model.safetensors"))
        _ = try Self.file(
            at:
                rootURL
                .appendingPathComponent("modelscope/org/repoY/master/model.safetensors"))
        try ModelStore.removeReady(repoId: "org/repoY", source: "modelScope")
        let dbgTree = { () -> String in
            var lines: [String] = []
            if let e = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil) {
                while let u = e.nextObject() as? URL { lines.append(u.path) }
            }
            return lines.joined(separator: "\n")
        }()
        #expect(
            !fm.fileExists(atPath: rootURL.appendingPathComponent("org/repoY").path),
            "flat removed. root=\(ModelStore.root.path) msRepoDir=\(ModelStore.msRepoDir("org/repoY").path) msBases=\(ModelStore.msBases().map(\.path))\nREMAIN:\n\(dbgTree)"
        )
        #expect(
            !fm.fileExists(
                atPath:
                    rootURL
                    .appendingPathComponent("modelscope/org/repoY").path))

        try? fm.removeItem(at: msFlat)
        try? fm.removeItem(at: rootURL)
    }

    // MARK: - MS 平铺规范布局(omlx 对齐)

    @Test("msRepoDir is flat root/<org>/<name>; msReadyDir honors valid safetensors")
    func msFlatLayout() throws {
        let rootURL = Self.tmpRoot.appendingPathComponent("msflat")
        setenv("OCOREAI_MODELS_DIR", rootURL.path, 1)
        defer { unsetenv("OCOREAI_MODELS_DIR") }

        let dir = ModelStore.msRepoDir("org/name")
        let fm = FileManager.default
        #expect(
            dir.path == rootURL.appendingPathComponent("org/name").path,
            "flat repo dir, no provider/rev layer")
        #expect(
            ModelStore.msRepoDir("a/b/c").path == rootURL.appendingPathComponent("a/b/c").path,
            "3-segment id flattens, no provider/rev injection")
        #expect(ModelStore.msReadyDir("org/name") == nil, "empty repo not ready")

        _ = try Self.file(at: dir.appendingPathComponent("model.safetensors"))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path))
        let gotR = ModelStore.msReadyDir("org/name")
        let fileList: [String] =
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.map(
                \.lastPathComponent) ?? []
        #expect(
            gotR != nil && gotR!.path == dir.path,
            "flat ready = repo dir (path identity). hasValid=\(ModelStore.hasValidSafetensors(in: dir)) gotR=\(gotR?.path ?? "nil") dir=\(dir.path) list=\(fileList)"
        )

        // 遗留三级(root/modelscope/leg/x/main)仍可读 — omlx 对齐后新布局优先、旧布局兜底
        let legacyReady = try Self.file(
            at:
                rootURL
                .appendingPathComponent("modelscope/leg/x/main/model.safetensors"))
        #expect(
            ModelStore.msReadyDir("leg/x") == legacyReady.deletingLastPathComponent(),
            "legacy three-level base still resolved")

        try? fm.removeItem(at: rootURL)
    }
}
