// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DiskSpaceGuard tests — the pre-download disk guard (roadmap line 6).
///
/// The guard's promise is *honesty*, pinned here in both directions:
///   - blocks ONLY when numbers are known and insufficient (no false blocks);
///   - unknown (nil size / unreadable volume) NEVER blocks (no fabricated fail);
///   - cache credit subtracts what's already local (resumable downloads
///     must not be blocked twice for the same bytes).
///
/// All pure-function surface — no network, no real volume dependency except
/// a temp directory for cachedBytes.

import Foundation
import Testing

@testable import ocoreai

@Suite("DiskSpaceGuard — decision honesty")
struct DiskSpaceGuardDecisionTests {
    @Test("unknown required never blocks (nil size is not a lie-block)")
    func unknownRequiredAllows() {
        #expect(DiskSpaceGuard.decision(freeBytes: 1_000, requiredBytes: nil) == true)
    }

    @Test("unknown free never blocks (unreadable volume is not a lie-block)")
    func unknownFreeAllows() {
        #expect(DiskSpaceGuard.decision(freeBytes: nil, requiredBytes: 40_000_000_000) == true)
    }

    @Test("both unknown allows")
    func bothUnknownAllows() {
        #expect(DiskSpaceGuard.decision(freeBytes: nil, requiredBytes: nil) == true)
    }

    @Test("comfortable free allows")
    func comfortableAllows() {
        // 100 GB free, 40 GB needed — headroom max(2e9, 5e9)=5e9; 60e9 left ≥ 5e9.
        let free: Int64 = 100_000_000_000
        #expect(DiskSpaceGuard.decision(freeBytes: free, requiredBytes: 40_000_000_000) == true)
    }

    @Test("tight volume blocks when remainder under headroom")
    func tightBlocks() {
        // 10 GB free, 9.5 GB needed → 0.5e9 remainder < 2e9 headroom → block.
        let free: Int64 = 10_000_000_000
        #expect(DiskSpaceGuard.decision(freeBytes: free, requiredBytes: 9_500_000_000) == false)
    }

    @Test("boundary: remainder exactly at headroom allows")
    func boundaryAllows() {
        // headroom = max(2e9, free/20). free=10e9 → headroom=2e9.
        // required 8e9 → remainder exactly 2e9 → allow (>= comparison).
        let free: Int64 = 10_000_000_000
        #expect(DiskSpaceGuard.decision(freeBytes: free, requiredBytes: 8_000_000_000) == true)
        // one byte over the line → block.
        #expect(DiskSpaceGuard.decision(freeBytes: free, requiredBytes: 8_000_000_001) == false)
    }

    @Test("large volumes use 5% headroom, not the 2GB floor")
    func largeVolumeHeadroom() {
        // free = 1 TB → headroom = 50 GB (exceeds 2 GB floor).
        let free: Int64 = 1_000_000_000_000
        #expect(DiskSpaceGuard.requiredHeadroom(freeBytes: free) == 50_000_000_000)
        // required 960 GB → remainder 40 GB < 50 GB headroom → block.
        #expect(DiskSpaceGuard.decision(freeBytes: free, requiredBytes: 960_000_000_000) == false)
    }

    @Test("small volumes use the 2GB floor")
    func smallVolumeHeadroom() {
        // free = 20 GB → free/20 = 1 GB < floor → headroom = 2 GB.
        let free: Int64 = 20_000_000_000
        #expect(DiskSpaceGuard.requiredHeadroom(freeBytes: free) == 2_000_000_000)
    }
}

@Suite("DiskSpaceGuard — requirement math")
struct DiskSpaceGuardRequirementTests {
    @Test("unknown remote total → unknown requirement (allow)")
    func unknownTotalUnknownRequired() {
        #expect(DiskSpaceGuard.requiredBytes(remoteTotal: nil, cachedBytes: 999) == nil)
    }

    @Test("cache credit subtracts")
    func cacheCreditSubtracts() {
        // 40 GB repo, 15 GB already cached → ask for 25 GB.
        #expect(
            DiskSpaceGuard.requiredBytes(remoteTotal: 40_000_000_000, cachedBytes: 15_000_000_000)
                == 25_000_000_000)
    }

    @Test("cache credit floors at zero (over-cached never negative)")
    func cacheCreditFloorsZero() {
        #expect(DiskSpaceGuard.requiredBytes(remoteTotal: 100, cachedBytes: 500) == 0)
        #expect(DiskSpaceGuard.requiredBytes(remoteTotal: 100, cachedBytes: -50) == 100)
    }

    @Test("fully cached repo asks for zero")
    func fullyCachedAsksZero() {
        #expect(DiskSpaceGuard.requiredBytes(remoteTotal: 500, cachedBytes: 500) == 0)
        // zero requirement never blocks even a nearly-full volume.
        #expect(DiskSpaceGuard.decision(freeBytes: 3_000_000_000, requiredBytes: 0) == true)
    }
}

@Suite("DiskSpaceGuard — glob matching (cache credit correctness)")
struct DiskSpaceGuardGlobTests {
    @Test("*.safetensors matches shard names")
    func safetensorsGlob() {
        #expect(
            DiskSpaceGuard.matchesGlob(
                "model-00001-of-00002.safetensors", patterns: ["*.safetensors"]))
        #expect(DiskSpaceGuard.matchesGlob("model.safetensors", patterns: ["*.safetensors"]))
        #expect(!DiskSpaceGuard.matchesGlob("config.json", patterns: ["*.safetensors"]))
    }

    @Test("exact-name patterns match verbatim")
    func exactPatterns() {
        #expect(DiskSpaceGuard.matchesGlob("config.json", patterns: ["config.json"]))
        #expect(!DiskSpaceGuard.matchesGlob("config.json.bak", patterns: ["config.json"]))
    }

    @Test("any-of multiple patterns")
    func multiPattern() {
        let pats = ["*.safetensors", "*.gguf"]
        #expect(DiskSpaceGuard.matchesGlob("x.gguf", patterns: pats))
        #expect(DiskSpaceGuard.matchesGlob("y.safetensors", patterns: pats))
        #expect(!DiskSpaceGuard.matchesGlob("z.bin", patterns: pats))
    }
}

@Suite("DiskSpaceGuard — cachedBytes on a real temp dir")
struct DiskSpaceGuardCachedBytesTests {
    @Test("sums only glob-matched files; empty dir → 0")
    func sumsMatchedFiles() throws {
        let dir = try temporaryDirectory()
        let fm = FileManager.default
        try "x".write(
            to: dir.appendingPathComponent("a.safetensors"), atomically: true, encoding: .utf8)
        try "yy".write(
            to: dir.appendingPathComponent("b.safetensors"), atomically: true, encoding: .utf8)
        try "zzz".write(to: dir.appendingPathComponent("c.gguf"), atomically: true, encoding: .utf8)

        let matched = DiskSpaceGuard.cachedBytes(in: dir, patterns: ["*.safetensors"])
        #expect(matched == 3)  // 1 + 2 bytes of the two matched files
        let gguf = DiskSpaceGuard.cachedBytes(in: dir, patterns: ["*.gguf"])
        #expect(gguf == 3)
        let none = DiskSpaceGuard.cachedBytes(in: dir, patterns: ["*.bin"])
        #expect(none == 0)

        let empty = dir.appendingPathComponent("nested-missing")
        #expect(DiskSpaceGuard.cachedBytes(in: empty, patterns: ["*.safetensors"]) == 0)
        try? fm.removeItem(at: dir)
    }

    @Test("freeBytes on the temp home volume is readable and positive")
    func freeBytesReadable() throws {
        let dir = try temporaryDirectory()
        let free = DiskSpaceGuard.freeBytes(onVolumeHosting: dir)
        #expect(free != nil)
        #expect((free ?? 0) > 0)
        try? FileManager.default.removeItem(at: dir)
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiskSpaceGuardTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("DiskSpaceGuard — SDK matching:[] = whole repo (no silent hole)")
struct DiskSpaceGuardWholeRepoTests {
    @Test("empty patterns matches every file")
    func emptyPatternsMatchAll() {
        // ReadyHubDownloader's main handler path passes matching: [] —
        // "whole repo". The guard MUST size every file, not no-match its
        // way into a silent allow-through.
        #expect(DiskSpaceGuard.matchesGlob("anything.bin", patterns: []))
        #expect(DiskSpaceGuard.matchesGlob("config.json", patterns: []))
        #expect(DiskSpaceGuard.matchesGlob("no-extension", patterns: []))
    }

    @Test("non-empty patterns keep exact-glob semantics")
    func nonEmptyUnchanged() {
        #expect(DiskSpaceGuard.matchesGlob("x.gguf", patterns: ["*.gguf"]))
        #expect(!DiskSpaceGuard.matchesGlob("x.safetensors", patterns: ["*.gguf"]))
    }

    @Test("flat layout: top-level files counted exactly once")
    func flatNoDoubleCount() throws {
        let dir = try temporaryDirectory()
        let fm = FileManager.default
        try "1234".write(
            to: dir.appendingPathComponent("a.safetensors"), atomically: true, encoding: .utf8)
        try "56789".write(
            to: dir.appendingPathComponent("b.safetensors"), atomically: true, encoding: .utf8)

        // Whole-repo credit = 9 bytes, once.
        #expect(DiskSpaceGuard.cachedBytes(in: dir, patterns: []) == 9)
        // Exact-ext pattern flat semantics unchanged.
        #expect(DiskSpaceGuard.cachedBytes(in: dir, patterns: ["*.safetensors"]) == 9)
        try? fm.removeItem(at: dir)
    }

    @Test("legacy HubCache layout: recursive blob credit, whole-repo only")
    func legacyRecursiveCredit() throws {
        let dir = try temporaryDirectory()
        let fm = FileManager.default
        // hubRoot/<org>/<repo>/blobs/<hash> layout, plus sibling repos.
        let blobs = dir.appendingPathComponent("org").appendingPathComponent("repo")
            .appendingPathComponent("blobs")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try "abcdef".write(
            to: blobs.appendingPathComponent("deadbeef"), atomically: true, encoding: .utf8)
        try "xyz".write(
            to: dir.appendingPathComponent("loose.gguf"), atomically: true, encoding: .utf8)

        // Whole-repo semantics: recursive blob (6) + loose top-level (3).
        #expect(DiskSpaceGuard.cachedBytes(in: dir, patterns: []) == 9)
        // Exact-ext pattern → flat semantics only (no recursion into dirs).
        #expect(DiskSpaceGuard.cachedBytes(in: dir, patterns: ["*.gguf"]) == 3)
        try? fm.removeItem(at: dir)
    }

    @Test("whole-repo credit earns zero-ask on fully cached repo")
    func fullyCachedWholeRepoAsksZero() throws {
        let dir = try temporaryDirectory()
        let fm = FileManager.default
        try "cached".write(
            to: dir.appendingPathComponent("model.safetensors"), atomically: true, encoding: .utf8)
        let cached = DiskSpaceGuard.cachedBytes(in: dir, patterns: [])
        #expect(DiskSpaceGuard.requiredBytes(remoteTotal: 6, cachedBytes: cached) == 0)
        try? fm.removeItem(at: dir)
    }
}
