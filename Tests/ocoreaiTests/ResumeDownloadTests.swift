// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Resume semantics tests — interrupted downloads survive (roadmap line 2).
///
/// Pins the decision surface of ModelScopeDownloader's resume machinery:
///   - deterministic temp names (the UUID temps made resume impossible);
///   - shouldResume identity gates (never splice on doubt);
///   - resumeDisposition 206 vs 200 vs error;
///   - age-gated stale sweep (fresh temps are state, stale temps are junk);
///   - real-FS state machine: byte accumulation across attempt boundaries,
///     cancel discards, success promotes and cleans the sidecar.
///
/// No network — the bytes are simulated against the real file system.

import Foundation
import Testing

@testable import ocoreai

@Suite("Resume — deterministic temp identity")
struct ResumeTempNamingTests {
    @Test("temp name is deterministic per repo path")
    func deterministic() {
        let cache = URL(fileURLWithPath: "/tmp/cache")
        let a = ModelScopeDownloader.resumeTempURL(
            for: "weights/model-00001.safetensors", in: cache)
        let b = ModelScopeDownloader.resumeTempURL(
            for: "weights/model-00001.safetensors", in: cache)
        #expect(a == b)  // a new process computes the SAME path
        #expect(a.lastPathComponent.hasPrefix(".download-"))
        // '/' flattened — temp lives in exactly ONE canonical directory.
        #expect(!a.lastPathComponent.contains("/"))
    }

    @Test("different paths → different temps; meta is temp + .meta")
    func distinctPaths() {
        let cache = URL(fileURLWithPath: "/tmp/cache")
        let t1 = ModelScopeDownloader.resumeTempURL(for: "a.bin", in: cache)
        let t2 = ModelScopeDownloader.resumeTempURL(for: "b.bin", in: cache)
        #expect(t1 != t2)
        let m = ModelScopeDownloader.resumeMetaURL(for: "a.bin", in: cache)
        #expect(m == URL(string: t1.absoluteString + ".meta"))
    }
}

@Suite("Resume — identity gates (never splice on doubt)")
struct ResumeGateTests {
    typealias Meta = ModelScopeDownloader.ResumeMeta

    @Test("no temp bytes → fresh download")
    func noBytes() {
        #expect(
            !ModelScopeDownloader.shouldResume(
                tempBytes: 0, expectedSize: 1000,
                meta: Meta(revision: "main", etag: "e", lastModified: nil),
                currentRevision: "main"))
    }

    @Test("missing meta → fresh (identity unknown)")
    func missingMeta() {
        #expect(
            !ModelScopeDownloader.shouldResume(
                tempBytes: 500, expectedSize: 1000, meta: nil, currentRevision: "main"))
    }

    @Test("revision changed → fresh (never splice versions)")
    func revisionChanged() {
        #expect(
            !ModelScopeDownloader.shouldResume(
                tempBytes: 500, expectedSize: 1000,
                meta: Meta(revision: "old-rev", etag: nil, lastModified: nil),
                currentRevision: "main"))
    }

    @Test("temp >= manifest size → fresh (verify-and-replace, not resume)")
    func oversizedTemp() {
        #expect(
            !ModelScopeDownloader.shouldResume(
                tempBytes: 1000, expectedSize: 1000,
                meta: Meta(revision: "main", etag: nil, lastModified: nil),
                currentRevision: "main"))
        #expect(
            !ModelScopeDownloader.shouldResume(
                tempBytes: 1001, expectedSize: 1000,
                meta: Meta(revision: "main", etag: nil, lastModified: nil),
                currentRevision: "main"))
    }

    @Test("plausible partial + matching revision → resume")
    func plausiblePartialResumes() {
        #expect(
            ModelScopeDownloader.shouldResume(
                tempBytes: 500, expectedSize: 1000,
                meta: Meta(revision: "main", etag: "abc", lastModified: nil),
                currentRevision: "main"))
        // unknown remote size: temp bytes + identity are enough
        #expect(
            ModelScopeDownloader.shouldResume(
                tempBytes: 500, expectedSize: nil,
                meta: Meta(revision: "main", etag: nil, lastModified: "ts"),
                currentRevision: "main"))
    }
}

@Suite("Resume — HTTP disposition")
struct ResumeDispositionTests {
    @Test("206 → append; 200 → truncate-and-restart; else fail")
    func dispositions() {
        #expect(
            ModelScopeDownloader.resumeDisposition(
                statusCode: 206, tempBytes: 400, expectedSize: 1000) == .resume)
        #expect(
            ModelScopeDownloader.resumeDisposition(
                statusCode: 200, tempBytes: 400, expectedSize: 1000) == .fresh)
        #expect(
            ModelScopeDownloader.resumeDisposition(
                statusCode: 302, tempBytes: 400, expectedSize: 1000) == .failed(statusCode: 302))
        // 416 + full temp = complete (promote, never fail); 416 + partial = error
        #expect(
            ModelScopeDownloader.resumeDisposition(
                statusCode: 416, tempBytes: 1000, expectedSize: 1000) == .complete)
        #expect(
            ModelScopeDownloader.resumeDisposition(
                statusCode: 416, tempBytes: 400, expectedSize: 1000) == .failed(statusCode: 416))
        #expect(
            ModelScopeDownloader.resumeDisposition(
                statusCode: 0, tempBytes: 400, expectedSize: 1000) == .failed(statusCode: 0))
    }

    @Test("ModelScope CDN: honored Range arrives as 200 + Content-Range")
    func partialWith200() {
        // Range: bytes=400- answered 200 "bytes 400-999/1000" → resume.
        #expect(
            ModelScopeDownloader.resumeDisposition(
                statusCode: 200, contentRange: "bytes 400-999/1000",
                tempBytes: 400, expectedSize: 1000, requestedOffset: 400) == .resume)
        // Genuine full body (no Content-Range) → truncate & restart.
        #expect(
            ModelScopeDownloader.resumeDisposition(
                statusCode: 200, contentRange: nil,
                tempBytes: 400, expectedSize: 1000, requestedOffset: 400) == .fresh)
        // Range silently restarted at 0 → unverified prefix → fresh.
        #expect(
            ModelScopeDownloader.resumeDisposition(
                statusCode: 200, contentRange: "bytes 0-999/1000",
                tempBytes: 400, expectedSize: 1000, requestedOffset: 400) == .fresh)
        // First attempt (offset 0) + 200 → fresh even if header exists.
        #expect(
            ModelScopeDownloader.resumeDisposition(
                statusCode: 200, contentRange: "bytes 0-999/1000",
                tempBytes: 0, expectedSize: 1000, requestedOffset: 0) == .fresh)
        // Content-Range parsing edge cases.
        #expect(ModelScopeDownloader.contentRangeStart("bytes 400-999/1000") == 400)
        #expect(ModelScopeDownloader.contentRangeStart("BYTES 0-9/10") == 0)
        #expect(ModelScopeDownloader.contentRangeStart("garbage") == nil)
        #expect(ModelScopeDownloader.contentRangeStart(nil) == nil)
    }
}

@Suite("Resume — age-gated sweep")
struct ResumeSweepTests {
    @Test("fresh temp is resumable state; stale temp is junk")
    func ageGate() {
        #expect(!ModelScopeDownloader.shouldPurgeTemp(age: 0))
        #expect(!ModelScopeDownloader.shouldPurgeTemp(age: 3600))  // 1h: keep
        #expect(!ModelScopeDownloader.shouldPurgeTemp(age: 24 * 3600))  // boundary: keep
        #expect(ModelScopeDownloader.shouldPurgeTemp(age: 24 * 3600 + 1))  // past: purge
        #expect(ModelScopeDownloader.shouldPurgeTemp(age: 100, staleAfter: 50))
    }
}

@Suite("Resume — zero-RTT promotion of complete temps")
struct PromoteCompleteTests {
    typealias Meta = ModelScopeDownloader.ResumeMeta

    @Test("temp at manifest size + matching revision → promote, no network")
    func promotes() {
        #expect(
            ModelScopeDownloader.shouldPromoteComplete(
                tempBytes: 1000, expectedSize: 1000,
                meta: Meta(revision: "main", etag: nil, lastModified: nil),
                currentRevision: "main"))
    }

    @Test("never promote on doubt: revision mismatch / unknown size / stale meta")
    func neverOnDoubt() {
        #expect(
            !ModelScopeDownloader.shouldPromoteComplete(
                tempBytes: 1000, expectedSize: 1000,
                meta: Meta(revision: "old", etag: nil, lastModified: nil),
                currentRevision: "main"))
        #expect(
            !ModelScopeDownloader.shouldPromoteComplete(
                tempBytes: 1000, expectedSize: nil,
                meta: Meta(revision: "main", etag: nil, lastModified: nil),
                currentRevision: "main"))
        #expect(
            !ModelScopeDownloader.shouldPromoteComplete(
                tempBytes: 999, expectedSize: 1000,
                meta: Meta(revision: "main", etag: nil, lastModified: nil),
                currentRevision: "main"))
    }
}

@Suite("Resume — real-FS byte state machine")
struct ResumeFileSystemTests {
    @Test("bytes accumulate across attempt boundaries; success promotes; cancel keeps")
    func stateMachine() throws {
        let fm = FileManager.default
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResumeTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: cache) }

        let path = "weights/model-00001.safetensors"
        let totalSize: Int64 = 1000
        let temp = ModelScopeDownloader.resumeTempURL(for: path, in: cache)
        let meta = ModelScopeDownloader.resumeMetaURL(for: path, in: cache)
        let dest = cache.appendingPathComponent(path)
        // attemptDownload creates dest.parent at its top (createDirectory
        // withIntermediateDirectories) — the simulation must too, promotion
        // into a nested path fails without it.
        try fm.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Attempt 1 dies at 400 bytes (simulated transient failure):
        // bytes stay on disk (the catch keeps non-cancellation failures).
        fm.createFile(atPath: temp.path, contents: Data(repeating: 0xA1, count: 400))
        try #require(temp.lastPathComponent.hasPrefix(".download-"))

        // ...and the sidecar records identity:
        let metaVal = ModelScopeDownloader.ResumeMeta(
            revision: "main", etag: "etag-1", lastModified: nil)
        try JSONEncoder().encode(metaVal).write(to: meta)

        // Attempt 2 (a NEW process) must find the same temp and resume:
        let attrs = try fm.attributesOfItem(atPath: temp.path)
        let tempBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        #expect(tempBytes == 400)
        let loaded = try JSONDecoder().decode(
            ModelScopeDownloader.ResumeMeta.self, from: Data(contentsOf: meta))
        #expect(
            ModelScopeDownloader.shouldResume(
                tempBytes: tempBytes, expectedSize: totalSize,
                meta: loaded, currentRevision: "main"),
            "attempt 2 must resume from 400/1000, not restart from zero")

        // Attempt 2 succeeds: promote temp → dest, sidecar dies.
        fm.appendToFile(temp, Data(repeating: 0xB2, count: 600))
        try fm.moveItem(at: temp, to: dest)
        try fm.removeItem(at: meta)
        let finalAttrs = try fm.attributesOfItem(atPath: dest.path)
        #expect((finalAttrs[.size] as? NSNumber)?.int64Value == totalSize)
        #expect(!fm.fileExists(atPath: temp.path))
        #expect(!fm.fileExists(atPath: meta.path))

        // Cancellation KEEPS resumable state — user intent is "pause";
        // attemptDownload's catch no longer deletes temp on cancel (bytes
        // are a valid prefix; resume continues from offset next attempt).
        fm.createFile(atPath: temp.path, contents: Data(repeating: 0xC3, count: 100))
        try JSONEncoder().encode(metaVal).write(to: meta)  // new attempt re-recorded it
        let cancelError: Error = CancellationError()
        let keepTemp = ModelScopeDownloader.keepTempOnError(cancelError)
        #expect(keepTemp, "cancel must preserve bytes, not restart from zero")
        #expect(fm.fileExists(atPath: temp.path))
        // Resume gate still true after cancel: next attempt continues at 100.
        let loaded2 = try JSONDecoder().decode(
            ModelScopeDownloader.ResumeMeta.self, from: Data(contentsOf: meta))
        #expect(
            ModelScopeDownloader.shouldResume(
                tempBytes: 100, expectedSize: totalSize,
                meta: loaded2, currentRevision: "main"))
    }

    @Test("purgeStaleTempFiles keeps fresh, removes stale + sidecars")
    func stalePurge() async throws {
        let fm = FileManager.default
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResumePurge-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: cache) }

        let fresh = cache.appendingPathComponent(".download-fresh.bin")
        let stale = cache.appendingPathComponent(".download-stale.bin")
        let staleMeta = cache.appendingPathComponent(".download-stale.bin.meta")
        let keep = cache.appendingPathComponent("model.safetensors")
        try Data(repeating: 1, count: 8).write(to: fresh)
        try Data(repeating: 2, count: 8).write(to: stale)
        try Data(repeating: 3, count: 8).write(to: staleMeta)
        try Data(repeating: 4, count: 8).write(to: keep)

        let old = Date().addingTimeInterval(-25 * 3600)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: staleMeta.path)

        let downloader = ModelScopeDownloader(token: nil)
        await downloader.purgeStaleTempFiles(in: cache)

        #expect(fm.fileExists(atPath: fresh.path))  // fresh → resumable state, kept
        #expect(!fm.fileExists(atPath: stale.path))  // stale → junk, purged
        #expect(!fm.fileExists(atPath: staleMeta.path))  // sidecar follows
        #expect(fm.fileExists(atPath: keep.path))  // real model files untouched
    }
}

extension FileManager {
    /// Append helper mirroring FileHandle.seekToEndOfFile + write in the
    /// resume path (test-visible byte continuity).
    fileprivate func appendToFile(_ url: URL, _ data: Data) {
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(data)
        }
    }
}

@Suite("Progress — BatchBytes funnel (bar honesty)")
struct BatchBytesTests {
    /// Collect onProgress emissions. BatchBytes calls the handler OUTSIDE
    /// its own lock, so a locked box here is enough (no actor hop needed —
    /// the sync handler cannot `await`).
    private actor Recorder {}  // marker: keep actor for Swift 6 isolation checks
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Int64] = []
        func emit(_ d: Int64) {
            lock.lock()
            seen.append(d)
            lock.unlock()
        }
        var last: Int64? {
            lock.lock()
            defer { lock.unlock() }
            return seen.last
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return seen.count
        }
        var isEmpty: Bool { count == 0 }
    }

    @Test("parallel flushes sum across files; monotone per file")
    func sumsAndMonotone() {
        let sink = Sink()
        let batch = ModelScopeDownloader.BatchBytes(total: 1000) { d, _ in
            sink.emit(d)
        }
        batch.report(file: "a", cumulativeBytes: 100)
        batch.report(file: "b", cumulativeBytes: 200)
        batch.report(file: "a", cumulativeBytes: 300)  // a grows +200
        #expect(sink.last == 500)  // total = a(300) + b(200)
        // Lowered report for a (Range-ignored retry truncation) → hold mark
        batch.report(file: "a", cumulativeBytes: 50)
        #expect(sink.last == 500)
        // Only growth past the high-water advances the bar
        batch.report(file: "a", cumulativeBytes: 400)
        #expect(sink.last == 600)
    }

    @Test("bar capped; settle lands exact truth downward")
    func cappedAndSettle() {
        let sink = Sink()
        let batch = ModelScopeDownloader.BatchBytes(total: 500) { d, _ in
            sink.emit(d)
        }
        batch.report(file: "a", cumulativeBytes: 400)
        batch.report(file: "b", cumulativeBytes: 400)  // sum 800
        #expect(sink.last == 500)  // capped at limit
        // Promotion truth lands via settle: temp over-ran the manifest —
        // authoritative downward write, bar recomputes from real sizes.
        batch.settle(file: "a", exactBytes: 100)
        batch.settle(file: "b", exactBytes: 100)
        #expect(sink.last == 200)  // exact books, no inflation
    }

    @Test("zero-progress reports do not spam the handler")
    func noSpam() {
        let sink = Sink()
        let batch = ModelScopeDownloader.BatchBytes(total: 100) { d, _ in
            sink.emit(d)
        }
        batch.report(file: "a", cumulativeBytes: 0)
        batch.report(file: "a", cumulativeBytes: 0)
        #expect(sink.isEmpty)
        batch.report(file: "a", cumulativeBytes: 10)
        #expect(sink.count == 1)
    }

    @Test("accepted flush beats the stall heartbeat")
    func heartbeat() async throws {
        let sink = Sink()
        let batch = ModelScopeDownloader.BatchBytes(total: 100) { d, _ in
            sink.emit(d)
        }
        let t0 = batch.lastProgressAt
        try await Task.sleep(for: .milliseconds(30))
        batch.report(file: "a", cumulativeBytes: 5)
        #expect(batch.lastProgressAt > t0)  // watchdog sees life
    }
}
