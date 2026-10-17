// MediaLifetimeTests.swift — the rule: inline media bytes live as long as a live session
// cites them, and no longer.
//
// Why this suite exists (measured 10-16, `scripts/probes/08-video-honesty.sh`): a clip
// posted to `/v1/chat/completions` as a `data:` URL was written to a temp file, handed to
// the model as `.url(...)`, and deleted when the request ended. The transcript the model
// received kept that path, and upstream re-feeds the transcript on every later turn
// (`ChatSession.swift:1131`), so turn two of the conversation — even a plain text
// follow-up — failed with `500 … The operation could not be completed`, permanently, while
// the same clip posted as a `file://` URL worked and was recalled. The fix moved the bytes
// into a spool whose lifetime is the session's; these tests pin the mechanics of that
// lifetime, because every one of them is a way the original defect could come back:
//
//   • bytes landing outside the spool → nothing owns them, and whoever sweeps deletes them;
//   • a re-post that writes a second copy → the transcript cites one file and the pool
//     tracks another;
//   • a sweep that reaches a file a live session still cites → the 500 is back;
//   • a sweep that ignores idleness or the byte budget → the disk grows without bound.
//
// Scope note: the end-to-end consequence (a video turn followed by a text turn must not
// 500) needs a real model, so it is pinned by probe 08, not here. What this suite can pin
// without Metal is the ownership arithmetic, which is where the bug actually lived.

import Foundation
import Testing

@testable import ocoreai

private func makeScratchDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ocoreai-media-tests-\(name)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func age(_ url: URL, seconds: TimeInterval) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -seconds)], ofItemAtPath: url.path)
}

private func fileSize(_ url: URL) -> UInt64 {
    UInt64(
        max(
            0,
            (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0))
}

@Suite("MediaSpool — content-addressed spooling")
struct MediaSpoolingTests {
    @Test("bytes are written intact, under the spool directory, with the asked-for extension")
    func writesIntactUnderSpool() throws {
        let dir = try makeScratchDir("write")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data((0 ..< 4096).map { UInt8($0 % 251) })

        guard let url = MediaSpool.spool(bytes, fileExtension: "mp4", in: dir) else {
            Issue.record("spool returned nil for 4096 bytes")
            return
        }
        #expect(MediaSpool.isInside(url, dir))
        #expect(url.pathExtension == "mp4")
        #expect((try? Data(contentsOf: url)) == bytes)
        // Content-addressed: the name states the digest and the length, so a collision
        // between different payloads has to disagree in both.
        #expect(url.lastPathComponent.contains("-\(bytes.count)."))
    }

    @Test("re-posting identical bytes resolves to ONE file (a replay cites what the pool tracks)")
    func identicalBytesShareOneFile() throws {
        let dir = try makeScratchDir("dedupe")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = Data("a solid red frame, twice".utf8)

        guard let first = MediaSpool.spool(clip, fileExtension: "mp4", in: dir),
            let second = MediaSpool.spool(clip, fileExtension: "mp4", in: dir)
        else {
            Issue.record("spool returned nil")
            return
        }
        #expect(first == second)
        #expect(MediaSpool.totalBytes(in: dir) == fileSize(first))
    }

    @Test("different bytes get different files; empty bytes are refused, not written")
    func differentBytesDiffer() throws {
        let dir = try makeScratchDir("distinct")
        defer { try? FileManager.default.removeItem(at: dir) }

        let red = MediaSpool.spool(Data("red frames".utf8), fileExtension: "mp4", in: dir)
        let blue = MediaSpool.spool(Data("blue frames".utf8), fileExtension: "mp4", in: dir)
        #expect(red != nil && blue != nil)
        #expect(red != blue)
        #expect(MediaSpool.spool(Data(), fileExtension: "mp4", in: dir) == nil)
        // An empty payload must not leave a zero-byte stub behind for a sweep to trip on.
        #expect(MediaSpool.totalBytes(in: dir) == fileSize(red!) + fileSize(blue!))
    }
}

@Suite("MediaSpool — release, sharing, and sweep")
struct MediaCollectionTests {
    @Test("a file no live session cites is deleted; one another session cites is kept")
    func discardHonoursSharedCitations() throws {
        let dir = try makeScratchDir("shared")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = Data("the same clip in two conversations".utf8)
        let unique = Data("a clip only one conversation has".utf8)
        let shared = MediaSpool.spool(clip, fileExtension: "mp4", in: dir)!
        let owned = MediaSpool.spool(unique, fileExtension: "mp4", in: dir)!

        // Session A cites both, session B cites the shared one. A leaves → only A's
        // exclusive file goes; B still reads the shared clip.
        MediaSpool.discard([shared, owned], keeping: [shared], in: dir)
        #expect(FileManager.default.fileExists(atPath: shared.path))
        #expect(!FileManager.default.fileExists(atPath: owned.path))

        // Now B leaves too, with nothing live left — the shared file goes.
        MediaSpool.discard([shared], keeping: [], in: dir)
        #expect(!FileManager.default.fileExists(atPath: shared.path))
    }

    @Test("discard cannot reach files the spool did not write")
    func discardStaysInsideTheSpool() throws {
        let dir = try makeScratchDir("contain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let spooled = MediaSpool.spool(Data("frames".utf8), fileExtension: "mp4", in: dir)!
        let neighbour = dir.appendingPathComponent("somebody-elses-clip.mp4")
        try Data("not ours".utf8).write(to: neighbour)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai-outside-\(UUID().uuidString.prefix(8)).mp4")
        try Data("definitely not ours".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        MediaSpool.discard([spooled, neighbour, outside], keeping: [], in: dir)
        #expect(!FileManager.default.fileExists(atPath: spooled.path))
        #expect(FileManager.default.fileExists(atPath: neighbour.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("sweep collects idle files and spares anything re-touched by session activity")
    func sweepUsesIdleTime() throws {
        let dir = try makeScratchDir("idle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = MediaSpool.spool(
            Data("a clip nobody asks about".utf8), fileExtension: "mp4", in: dir)!
        let active = MediaSpool.spool(
            Data("a clip a live session keeps using".utf8), fileExtension: "mp4", in: dir)!
        // Both backdated past the TTL; only the active one is then re-touched, the way a
        // turn re-touches everything its conversation cites.
        try age(stale, seconds: 3_000)
        try age(active, seconds: 3_000)
        MediaSpool.touch([active], in: dir)
        let staleBytes = fileSize(stale)

        let report = MediaSpool.sweep(
            policy: .init(idleTTL: .seconds(60), maxBytes: 0), in: dir)
        #expect(report.removedIdle == 1)
        #expect(report.removedOverBudget == 0)
        // Measured before the sweep: a deleted file reports no allocation size after.
        #expect(report.bytesFreed == staleBytes)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: active.path))
    }

    @Test("over budget, least-recently-cited files go first and only as far as needed")
    func sweepEnforcesBudgetLRU() throws {
        let dir = try makeScratchDir("budget")
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(repeating: 0x5a, count: 64 * 1024)
        var urls: [URL] = []
        for index in 0 ..< 4 {
            // Distinct content → distinct files, oldest first by touch order.
            let url = MediaSpool.spool(
                payload + Data([UInt8(index)]), fileExtension: "mp4", in: dir)!
            try age(url, seconds: TimeInterval(400 - index * 100))
            urls.append(url)
        }
        let each = fileSize(urls[0])
        let budget = each * 2 + each / 2

        let report = MediaSpool.sweep(
            policy: .init(idleTTL: .seconds(86_400), maxBytes: budget), in: dir)
        #expect(report.removedIdle == 0)
        #expect(report.removedOverBudget == 2)
        #expect(!FileManager.default.fileExists(atPath: urls[0].path))
        #expect(!FileManager.default.fileExists(atPath: urls[1].path))
        #expect(FileManager.default.fileExists(atPath: urls[2].path))
        #expect(FileManager.default.fileExists(atPath: urls[3].path))
        #expect(MediaSpool.totalBytes(in: dir) <= budget)
        #expect(report.bytesFreed == each * 2)
    }

    @Test("a spool dir spelled with a trailing slash still releases bytes (vacuous-guard family)")
    func trailingSlashDirectoryStillReleases() throws {
        let dir = try makeScratchDir("slash")
        defer { try? FileManager.default.removeItem(at: dir) }
        // The spelling a config or env var produces (`/path/to/media/`). Comparing URLs
        // instead of paths makes the containment guard always false, and a guard that
        // never matches releases nothing — a disk leak that reads as working code.
        let spelled = URL(fileURLWithPath: dir.path + "/")
        let url = MediaSpool.spool(
            Data("bytes that must be collectable".utf8),
            fileExtension: "mp4", in: spelled)!
        #expect(MediaSpool.isInside(url, dir))
        #expect(MediaSpool.isInside(url, spelled))
        MediaSpool.discard([url], keeping: [], in: spelled)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // And the guard must still say no to a file that is genuinely elsewhere.
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai-elsewhere-\(UUID().uuidString.prefix(8)).mp4")
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        #expect(!MediaSpool.isInside(elsewhere, dir))
    }

    @Test("a pin holds across both spellings of a symlinked spool path")
    func pinSurvivesSymlinkSpelling() throws {
        let dir = try makeScratchDir("symlink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = MediaSpool.spool(
            Data("pinned across spellings".utf8),
            fileExtension: "mp4", in: dir)!
        // On macOS the temp dir is /var/folders/… while a directory listing reports
        // /private/var/folders/…. Pin by one spelling and consult by the other: a key
        // mismatch reads as "nobody is using this" and the collector deletes bytes that a
        // request is in the middle of handing to the model.
        let canonical = URL(fileURLWithPath: MediaSpool.canonicalPath(url))
        MediaSpool.pin([url])
        #expect(MediaSpool.pins.holds(canonical))
        MediaSpool.unpin([canonical])
        #expect(!MediaSpool.pins.holds(url))
        #expect(MediaSpool.isInside(url, dir))
        // Foreign names are not collectable, whatever directory they sit in.
        #expect(!MediaSpool.isSpoolName(dir.appendingPathComponent("stranger.txt")))
        #expect(MediaSpool.isSpoolName(url))
    }

    @Test("a sweep only ever names files with the spool's own shape")
    func sweepIgnoresForeignFiles() throws {
        let dir = try makeScratchDir("shape")
        defer { try? FileManager.default.removeItem(at: dir) }
        let spooled = MediaSpool.spool(Data("frames".utf8), fileExtension: "mp4", in: dir)!
        try age(spooled, seconds: 100_000)
        let foreign = ["notes.txt", "ocoreai_video_DEADBEEF.mp4", "partial-download.part"]
        for name in foreign {
            try Data("foreign".utf8).write(to: dir.appendingPathComponent(name))
        }

        let report = MediaSpool.sweep(
            policy: .init(idleTTL: .seconds(1), maxBytes: 1), in: dir)
        #expect(report.removedTotal == 1)
        #expect(!FileManager.default.fileExists(atPath: spooled.path))
        for name in foreign {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        }
    }

    @Test("touch never creates a file, so a stale citation cannot be resurrected as fresh")
    func touchDoesNotCreate() throws {
        let dir = try makeScratchDir("touch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ghost = dir.appendingPathComponent(
            "0000000000000000-1.mp4")
        MediaSpool.touch([ghost], in: dir)
        #expect(!FileManager.default.fileExists(atPath: ghost.path))
    }

    @Test("a request holding the bytes beats both the pool's discard and the sweeper")
    func pinsBeatBothCollectors() throws {
        let dir = try makeScratchDir("pin")
        defer { try? FileManager.default.removeItem(at: dir) }
        let inFlight = MediaSpool.spool(
            Data("frames a request is reading now".utf8),
            fileExtension: "mp4", in: dir)!
        let orphan = MediaSpool.spool(
            Data("frames nobody is reading".utf8),
            fileExtension: "mp4", in: dir)!
        try age(orphan, seconds: 3_000)
        try age(inFlight, seconds: 3_000)  // old by the clock, but pinned

        MediaSpool.pin([inFlight])
        // The pool discarding a diverged conversation names both files: only the
        // unclaimed one goes.
        MediaSpool.discard([inFlight, orphan], keeping: [], in: dir)
        #expect(FileManager.default.fileExists(atPath: inFlight.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))

        // A sweep that finds the pinned file past its idle TTL must skip it — the request
        // that spooled it may still be handing it to the processor.
        let report = MediaSpool.sweep(
            policy: .init(idleTTL: .seconds(60), maxBytes: 0), in: dir)
        #expect(report.removedIdle == 0)
        #expect(FileManager.default.fileExists(atPath: inFlight.path))

        // Once the request unpins, the same sweep collects it.
        MediaSpool.unpin([inFlight])
        let after = MediaSpool.sweep(
            policy: .init(idleTTL: .seconds(60), maxBytes: 0), in: dir)
        #expect(after.removedIdle == 1)
        #expect(!FileManager.default.fileExists(atPath: inFlight.path))
    }

    @Test("identical bytes pinned by two requests need both references released")
    func pinsAreRefcounted() throws {
        let dir = try makeScratchDir("refcount")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = Data("one clip, two conversations".utf8)
        let shared = MediaSpool.spool(clip, fileExtension: "mp4", in: dir)!
        #expect(shared == MediaSpool.spool(clip, fileExtension: "mp4", in: dir))

        MediaSpool.pin([shared])
        MediaSpool.pin([shared])
        MediaSpool.unpin([shared])
        #expect(MediaSpool.pins.holds(shared))
        MediaSpool.discard([shared], keeping: [], in: dir)
        #expect(FileManager.default.fileExists(atPath: shared.path))

        MediaSpool.unpin([shared])
        #expect(!MediaSpool.pins.holds(shared))
        MediaSpool.discard([shared], keeping: [], in: dir)
        #expect(!FileManager.default.fileExists(atPath: shared.path))
        // Unpinning more than pinning must not underflow into a negative reference.
        MediaSpool.unpin([shared])
        #expect(!MediaSpool.pins.holds(shared))
    }
}

@Suite("SessionPoolConfig — the media policy cannot undercut the session it serves")
struct MediaPolicyFloorTests {
    @Test("idle TTL is floored above the session TTL, so media outlives its session by design")
    func idleTTLFloorsAboveSessionTTL() {
        // A media TTL shorter than the session TTL would delete bytes a conversation that
        // is still inside its own TTL cites — the 10-16 defect, expressed as a config.
        let sloppy = SessionPoolConfig(sessionTTLSeconds: 600, mediaIdleTTLSeconds: 1)
        #expect(sloppy.mediaPolicy.idleTTL == .seconds(660))

        let generous = SessionPoolConfig(sessionTTLSeconds: 600, mediaIdleTTLSeconds: 7_200)
        #expect(generous.mediaPolicy.idleTTL == .seconds(7_200))
        #expect(generous.mediaPolicy.maxBytes == generous.mediaMaxBytes)
    }

    @Test("defaults keep media long-lived and the disk capped")
    func defaultsAreSane() {
        let config = SessionPoolConfig.default
        #expect(config.mediaMaxBytes == 512 * 1024 * 1024)
        #expect(config.mediaPolicy.idleTTL >= .seconds(Int64(config.sessionTTLSeconds) + 60))
    }
}
