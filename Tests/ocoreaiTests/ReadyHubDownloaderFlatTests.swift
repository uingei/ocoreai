// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ReadyHubDownloader M8 tests — flat layout + local-first short-circuit.
///
/// Coverage:
///   - local-ready dir + matching files → returns flat target, NO network
///   - local dir incomplete (missing requested glob) → takes the network path
///   - useLatest == true   → short-circuit bypassed (refresh semantics)
///   - flatRoot == nil     → legacy HubCache path (backward compat preserved)
///   - invalid repo id     → HuggingFaceDownloaderError.invalidRepositoryID
///
/// Network-path tests observe the attempt via the error the Hub client throws
/// (offline / no token) rather than asserting "no call happened", which keeps
/// the tests hermetic: a local-hit test asserts the exact returned URL, which
/// only the short-circuit can produce.

import Foundation
import HuggingFace
import MLXHuggingFace
import Testing

@testable import ocoreai

// MARK: - Helpers

/// Isolated temp root per test (tempdir keeps tests hermetic).
/// `ModelStore.root` reads `OCOREAI_MODELS_DIR` — pointing it at a unique
/// temp dir makes every test independent of real `~/.ocoreai/models`.
@discardableResult
private func freshModelRoot() -> (URL, cleanup: @Sendable () -> Void) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("readyhub-dl-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    setenv("OCOREAI_MODELS_DIR", dir.path, 1)
    return (dir, { try? FileManager.default.removeItem(at: dir) })
}

private func seed(_ dir: URL, names: [String]) {
    for name in names {
        let file = dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data([0x01]))
    }
}

// MARK: - ReadyHubDownloader local-first tests

@Suite("ReadyHubDownloader M8 — flat + local-first")
struct ReadyHubDownloaderFlatTests {

    @Test("local-ready dir returns flat target without network")
    func localReadyShortCircuit() async throws {
        let (root, cleanup) = freshModelRoot()
        defer { cleanup() }

        let flat = root.appendingPathComponent("mlx-community").appendingPathComponent("tiny-model")
        seed(
            flat,
            names: [
                "model.safetensors", "config.json", "tokenizer.json",
                "model-00001-of-00002.safetensors",
            ])

        let dl = ReadyHubDownloader(hub: ModelStore.readyHubClient(), flatRoot: root)

        // `useLatest == false` + all patterns present → short-circuit MUST NOT
        // touch the hub client (offline-safe; no token, no network configured).
        let out = try await dl.download(
            id: "mlx-community/tiny-model",
            revision: nil,
            matching: ["*.safetensors", "*.json"],
            useLatest: false,
            progressHandler: { _ in }
        )
        #expect(
            out.standardized == flat.standardized
                || out.path == flat.path,
            "local hit should be the exact flat dir, got \(out.path) vs \(flat.path)")
    }

    @Test("local dir missing a requested glob takes the network path")
    func incompleteDirGoesToNetwork() async throws {
        let (root, cleanup) = freshModelRoot()
        defer { cleanup() }

        // weights present, but `*.jinja` (a requested pattern) missing
        let flat = root.appendingPathComponent("org").appendingPathComponent("part")
        seed(flat, names: ["model.safetensors", "config.json"])

        let dl = ReadyHubDownloader(hub: ModelStore.readyHubClient(), flatRoot: root)

        do {
            _ = try await dl.download(
                id: "org/part",
                revision: nil,
                matching: ["*.safetensors", "*.jinja"],
                useLatest: false,
                progressHandler: { _ in }
            )
            Issue.record("expected network-path failure (offline), download unexpectedly succeeded")
        } catch {
            // Any error proves the short-circuit was NOT taken — the attempt
            // went through the hub client. (Offline/tokenless → non-200 throw.)
        }
    }

    @Test("useLatest=true bypasses local short-circuit")
    func useLatestBypassesLocalHit() async throws {
        let (root, cleanup) = freshModelRoot()
        defer { cleanup() }

        let flat = root.appendingPathComponent("org").appendingPathComponent("model")
        seed(flat, names: ["model.safetensors", "config.json"])

        let dl = ReadyHubDownloader(hub: ModelStore.readyHubClient(), flatRoot: root)

        do {
            _ = try await dl.download(
                id: "org/model",
                revision: nil,
                matching: ["*.safetensors", "*.json"],
                useLatest: true,
                progressHandler: { _ in }
            )
            Issue.record("expected network-path failure (offline), useLatest should force refresh")
        } catch {
            // refresh semantics: short-circuit skipped → hub call attempted
        }
    }

    @Test("nil flatRoot preserves legacy HubCache path")
    func nilFlatRootUsesLegacy() async throws {
        let (root, cleanup) = freshModelRoot()
        defer { cleanup() }

        let dl = ReadyHubDownloader(hub: ModelStore.readyHubClient(), flatRoot: nil)

        do {
            _ = try await dl.download(
                id: "org/legacy-model",
                revision: "main",
                matching: ["*.safetensors"],
                useLatest: false,
                progressHandler: { _ in }
            )
            Issue.record(
                "expected offline failure via legacy path, download unexpectedly succeeded")
        } catch {
            // legacy path reached the hub client → correct routing (flatRoot nil)
        }
    }

    @Test("invalid repo id throws invalidRepositoryID before any I/O")
    func invalidIdThrows() async throws {
        let (root, cleanup) = freshModelRoot()
        defer { cleanup() }

        let dl = ReadyHubDownloader(hub: ModelStore.readyHubClient(), flatRoot: root)

        do {
            _ = try await dl.download(
                id: "no-slash-at-all",
                revision: nil,
                matching: ["*.safetensors"],
                useLatest: false,
                progressHandler: { _ in }
            )
            Issue.record("expected invalidRepositoryID for a malformed id")
        } catch is HuggingFaceDownloaderError {
            // expected — thrown before any file/network I/O
        } catch {
            Issue.record("expected HuggingFaceDownloaderError, got \(type(of: error))")
        }
    }
}
