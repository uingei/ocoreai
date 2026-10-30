// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Download-integrity tests — the bytes that land must be the bytes the hub described.
///
/// Pins the post-download verdict in `verifyDownloadedFiles`: what a mirror that serves the
/// right number of wrong bytes costs, what a cache hit costs, and what still catches a
/// truncation when an endpoint declares no digest. The digests are computed here, from the
/// bytes, so no expectation is copied from the code under test.
///
/// Filesystem-only: a temp dir, real bytes, no network, no sleep.

import CryptoKit
import Foundation
import Testing

@testable import ocoreai

/// A path under the temp dir that no other test can be holding.
private func scratchPath(_ tag: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ocoreai-\(tag)-\(UUID().uuidString)")
}

/// SHA-256 as the hub writes it — the oracle, one shot over the whole buffer.
private func oracleSHA256(_ bytes: Data) -> String {
    Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined()
}

@Suite("Download integrity — declared digest beats declared size")
struct DownloadIntegrityTests {
    private let cache: URL
    private let downloader = ModelScopeDownloader(token: nil)

    init() throws {
        cache = scratchPath("integrity")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    private func write(_ name: String, _ bytes: Data) throws {
        try bytes.write(to: cache.appendingPathComponent(name))
    }

    private func entry(_ path: String, size: Int64?, sha256: String?)
        -> ModelScopeDownloader.FileInfo
    {
        ModelScopeDownloader.FileInfo(path: path, size: size, type: "blob", sha256: sha256)
    }

    // MARK: - The hole this closes

    @Test("right size, wrong bytes: the digest refuses what the size compare accepted")
    func rightSizeWrongBytesIsRefused() async throws {
        let onDisk = Data("good".utf8)
        let served = Data("evil".utf8)  // same byte count, different content
        try write("model.safetensors", onDisk)
        let declared = oracleSHA256(served)

        let failures = await downloader.verifyDownloadedFiles(
            [entry("model.safetensors", size: Int64(served.count), sha256: declared)],
            cacheDir: cache,
            downloadedNow: ["model.safetensors"])

        #expect(failures.count == 1)
        #expect(failures.first?.path == "model.safetensors")
        let cause = failures.first?.cause ?? ""
        #expect(cause.contains("SHA-256 mismatch"))
        #expect(cause.contains(declared))
        #expect(cause.contains(oracleSHA256(onDisk)))
    }

    @Test("the digest the hub declared for these exact bytes is accepted")
    func matchingDigestIsAccepted() async throws {
        let onDisk = Data("evil".utf8)
        try write("model.safetensors", onDisk)

        let failures = await downloader.verifyDownloadedFiles(
            [entry("model.safetensors", size: Int64(onDisk.count), sha256: oracleSHA256(onDisk))],
            cacheDir: cache,
            downloadedNow: ["model.safetensors"])

        #expect(failures.isEmpty)
    }

    // MARK: - The fallback that must stay alive

    @Test("no declared digest still catches a short file by size")
    func sizeOnlyFallbackCatchesTruncation() async throws {
        try write("model.safetensors", Data(repeating: 7, count: 4))

        let failures = await downloader.verifyDownloadedFiles(
            [entry("model.safetensors", size: 9_999, sha256: nil)],
            cacheDir: cache,
            downloadedNow: ["model.safetensors"])

        #expect(failures.count == 1)
        let cause = failures.first?.cause ?? ""
        #expect(cause.contains("local size 4"))
        #expect(cause.contains("9999"))
    }

    @Test("no declared digest and the declared size is not a failure")
    func sizeOnlyFallbackAcceptsTheDeclaredSize() async throws {
        try write("model.safetensors", Data(repeating: 7, count: 4))

        let failures = await downloader.verifyDownloadedFiles(
            [entry("model.safetensors", size: 4, sha256: nil)],
            cacheDir: cache,
            downloadedNow: ["model.safetensors"])

        #expect(failures.isEmpty)
    }

    // MARK: - Where the hashing stops

    @Test("a cache hit is trusted as found — no re-hash, no refusal")
    func cacheHitIsNotRehashed() async throws {
        let onDisk = Data("good".utf8)
        try write("model.safetensors", onDisk)

        let failures = await downloader.verifyDownloadedFiles(
            [
                entry(
                    "model.safetensors", size: Int64(onDisk.count),
                    sha256: oracleSHA256(Data("evil".utf8)))
            ],
            cacheDir: cache,
            downloadedNow: [])

        #expect(failures.isEmpty)
    }

    @Test("a file the download never delivered names that cause, not a size mismatch")
    func absentFileNamesItsOwnCause() async {
        let failures = await downloader.verifyDownloadedFiles(
            [entry("model.safetensors", size: 4, sha256: oracleSHA256(Data("evil".utf8)))],
            cacheDir: cache,
            downloadedNow: ["model.safetensors"])

        #expect(failures.count == 1)
        let cause = failures.first?.cause ?? ""
        #expect(cause.contains("not in the cache"))
        #expect(!cause.contains("size"))
    }

    // MARK: - What the wire reads

    @Test("distinct causes are reported, repeats collapse, and the tail is counted")
    func reasonDedupesAndCountsCauses() {
        let one = ModelScopeDownloader.IntegrityFailure(path: "a", cause: "alpha")
        let same = ModelScopeDownloader.IntegrityFailure(path: "b", cause: "alpha")
        #expect(ModelScopeDownloader.integrityReason([one, same]) == "alpha")

        let two = ModelScopeDownloader.IntegrityFailure(path: "c", cause: "beta")
        #expect(ModelScopeDownloader.integrityReason([one, two]) == "alpha; beta")

        let three = ModelScopeDownloader.IntegrityFailure(path: "d", cause: "gamma")
        #expect(
            ModelScopeDownloader.integrityReason([one, two, three])
                == "alpha; beta (+1 further causes)")
    }
}

@Suite("Integrity digest — streaming over real bytes")
struct IntegrityDigestTests {

    @Test("published SHA-256 vectors, byte-exact lowercase hex")
    func publishedVectors() throws {
        let tmp = scratchPath("vector")
        try Data("abc".utf8).write(to: tmp)
        #expect(
            IntegrityDigest.sha256(of: tmp)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        try Data().write(to: tmp)
        #expect(
            IntegrityDigest.sha256(of: tmp)
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("a file larger than the read chunk hashes like the whole buffer")
    func multiChunkStreamMatchesOneShot() throws {
        // 200 KiB crosses the 64 KiB chunk boundary three times: an off-by-one chunk
        // boundary, a dropped tail, or a re-read all land on a different digest.
        let blob = Data(repeating: 0x41, count: 200 * 1024)
        let tmp = scratchPath("stream")
        try blob.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(IntegrityDigest.sha256(of: tmp) == oracleSHA256(blob))
    }

    @Test("bytes that cannot be read are nil, not a verdict of corruption")
    func unreadableFileIsNil() {
        let missing = scratchPath("absent")
        #expect(IntegrityDigest.sha256(of: missing) == nil)
    }
}
