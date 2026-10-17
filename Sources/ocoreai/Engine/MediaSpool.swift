// MediaSpool.swift — where the bytes behind a `data:` media URL live, and for how long.
//
// ### The defect this closes (measured 10-16, `scripts/probes/08-video-honesty.sh`)
// AVFoundation cannot read a `data:` URL, so video and audio arriving inline are written
// to a file and handed to the model as `.url(fileURL)`. That file used to be deleted
// when the *request* ended. But a conversation's transcript is not request-scoped:
// upstream `ChatSession` keeps the message it was given — with the resolved URL inside it
// — and re-feeds that whole transcript to `processor.prepare` on **every later turn**
// (`ChatSession.swift:1131`: `templateMessages = leadingMessages +
// currentConversation.messages`). So the next turn opened a file that no longer existed,
// AVFoundation threw, and the client got `500 {"message":"Generation failed: Inference
// failed: The operation could not be completed"}`.
//
// Measured on this host, same model (`gemma-4-e2b-it-4bit`), same clip bytes:
//   • clip as a `data:` URL  → turn 1 `200` "Red" (+79 prompt tokens: frames arrived);
//     turn 2, a plain text follow-up in the same session → `500`, and every turn after
//     it `500` — the session was permanently poisoned by its own transcript.
//   • the same clip as a persistent `file://` URL → turn 1 `200` "Blue", turn 2 `200`
//     "Blue" (the model recalled the clip it had been shown), turn 3 `200` "Red".
// Same bytes, different URL scheme, opposite outcomes. The difference was only whether
// the file the transcript cited still existed.
//
// ### The rule, therefore
// **Media bytes live exactly as long as a live pooled session cites them** — not one
// turn longer (the pool releases them the moment the session that named them is gone)
// and not one turn shorter (which is what poisoned the conversation above). Two backstops
// cover what the pool cannot see: an idle TTL, for files orphaned by a killed process,
// and a byte budget, because frames are not small.
//
// Files are content-addressed (the same durable FNV-1a the conversation ledger uses, plus
// the byte count) so a clip re-posted across turns resolves to one file instead of one
// per turn, and a shared file is only deleted when no live session still cites it.

import Foundation

// The identity algorithm the conversation ledger and KV snapshots already use, applied
// to bytes instead of text. Declared here as an extension so there is still exactly one
// FNV-1a in the engine.
extension DurableHash {
    static func fnv1a64(_ bytes: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x1_0000_0001_b3
        }
        return hash
    }
}

enum MediaSpool {
    /// Whether `url` sits directly inside `directory`.
    ///
    /// Path spelling every comparison and pin key uses.
    ///
    /// `FileManager.temporaryDirectory` hands back `/var/folders/…`, which is a symlink to
    /// `/private/var/folders/…`, and a directory listing resolves it. Keying pins by one
    /// spelling and comparing against the other makes every check miss — which, for a
    /// pin, means "delete the bytes a request is reading". One canonical form, everywhere.
    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// Whether a name is one this spool wrote: `<16 hex>-<bytes>.<ext>`.
    ///
    /// Both collectors check it, so neither can delete anything it did not create —
    /// a foreign file in the same directory is not ours to touch, whatever a caller's
    /// list says.
    static func isSpoolName(_ url: URL) -> Bool {
        url.lastPathComponent.wholeMatch(of: /^\p{HexDigit}{16}-[0-9]+\.[A-Za-z0-9]+$/) != nil
    }

    /// Compared as path *strings*, not `URL == URL`: `deletingLastPathComponent()` puts
    /// the directory placeholder back (`…/media/`), so a URL-to-URL comparison is false
    /// for a file spool that is otherwise identical — and a containment guard that is
    /// always false deletes nothing at all. That is not a hypothetical: it is exactly how
    /// the first cut of this file silently released nothing (caught by
    /// `MediaLifetimeTests`, not by the live probe, which only ever sees bytes that stayed).
    static func isInside(_ url: URL, _ directory: URL) -> Bool {
        canonicalPath(url.deletingLastPathComponent()) == canonicalPath(directory)
    }

    /// Bytes a request is handing to the model right now.
    ///
    /// Why a pin rather than an ordering fix at each call site: the spool write happens
    /// when the wire message is converted, while the decisions that delete files happen
    /// later and elsewhere — a diverged conversation discarded during ``acquire``, an LRU
    /// or pressure eviction, a sweep. Any one of them can run between "this turn spooled
    /// its clip" and "this turn's processor opened it", and when they do, the turn dies
    /// with an AVFoundation error over bytes it wrote itself. Measured 10-16 with the
    /// first cut of this file: a conversation that re-posted a clip lost it to the
    /// discard of its own previous pool entry, and the turn 500'd. Making "a request is
    /// using these bytes" an explicit fact every collector consults is what removes the
    /// whole ordering hazard, instead of a comment telling the next contributor to be careful.
    ///
    /// Refcounted by path, because two conversations posting identical bytes resolve to the
    /// same content-addressed file and must each release their own reference.
    ///
    /// `@unchecked Sendable` justification: all mutation of ``counts`` happens inside
    /// ``lock``; the only externally observable effect of the state is whether a delete is
    /// skipped, and no reference to the dictionary escapes the class.
    final class Pins: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func add(_ urls: [URL]) {
            guard !urls.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            for url in urls { counts[MediaSpool.canonicalPath(url), default: 0] += 1 }
        }

        func remove(_ urls: [URL]) {
            guard !urls.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            for url in urls {
                let path = MediaSpool.canonicalPath(url)
                guard let count = counts[path] else { continue }
                if count > 1 { counts[path] = count - 1 } else { counts[path] = nil }
            }
        }

        func holds(_ url: URL) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return counts[MediaSpool.canonicalPath(url)] != nil
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return counts.count
        }
    }

    /// The pin set every collector consults before deleting anything.
    static let pins = Pins()

    /// Mark bytes as in use by a request. Pair with ``unpin(_:)`` in a `defer`.
    static func pin(_ urls: [URL]) { pins.add(urls) }

    /// Release a request's reference; the file becomes collectable once no live session
    /// cites it either.
    static func unpin(_ urls: [URL]) { pins.remove(urls) }

    /// When a spool file may be collected without asking the pool.
    struct Policy: Sendable, Equatable {
        /// Delete files untouched for this long. A live session re-touches its media on
        /// every turn, so this only ever catches files no session is using any more;
        /// it must stay comfortably above the session-pool TTL (600 s idle), or a
        /// long-lived conversation would be asked to read a file it still cites.
        var idleTTL: Duration
        /// total byte budget for the spool directory; over it, least-recently-touched
        /// files go first.
        var maxBytes: UInt64

        static let `default` = Policy(
            idleTTL: .seconds(3600),
            maxBytes: 512 * 1024 * 1024
        )
    }

    /// What one sweep did. Returned rather than logged-only so a test can assert on it.
    struct Sweep: Sendable, Equatable {
        var removedIdle: Int = 0
        var removedOverBudget: Int = 0
        var bytesFreed: UInt64 = 0

        var removedTotal: Int { removedIdle + removedOverBudget }
    }

    /// Where the spool lives: `OCOREAI_MEDIA_SPOOL` wins (the same escape hatch the Metal
    /// library resolution offers, and an escape hatch that loses to a caller is not an
    /// escape hatch), then the caller's `fallback` — the session pool passes the
    /// directory next to its KV cache, so redirecting one redirects both — then
    /// `<Application Support>/ocoreai/cache/media`, then a subdirectory of the temp dir.
    /// A subdirectory, never the temp dir itself: a sweep must only ever be able to
    /// delete files this enum wrote.
    static func directory(fallback: URL? = nil) -> URL {
        if let env = ProcessInfo.processInfo.environment[environmentVariable], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        if let fallback { return fallback }
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            return support.appendingPathComponent("ocoreai/cache/media")
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ocoreai/cache/media")
    }

    /// Name of the environment override, spelled out for the docs and the probes.
    static let environmentVariable = "OCOREAI_MEDIA_SPOOL"

    /// Write bytes into the spool and return a durable file URL.
    ///
    /// Idempotent by content: the same bytes return the same path (and refresh its
    /// idle clock), so a conversation that replays a clip every turn cites one file
    /// rather than accumulating a copy per turn. `nil` means the bytes could not be
    /// written — the caller must then treat the media as *not delivered*, never as
    /// silently ignorable.
    static func spool(
        _ bytes: Data,
        fileExtension: String,
        in directory: URL = MediaSpool.directory()
    ) -> URL? {
        guard !bytes.isEmpty else { return nil }
        let name =
            String(format: "%016llx", DurableHash.fnv1a64(bytes))
            + "-\(bytes.count).\(fileExtension)"
        let url = directory.resolvingSymlinksInPath().appendingPathComponent(name)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            touch([url], in: directory)
            return url
        }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Refresh the idle clock on files a live session is still citing.
    ///
    /// This is what makes the TTL safe: the conversation is active, so everything its
    /// transcript cites stays. Files whose sessions stopped coming back stop being
    /// touched and become sweepable.
    static func touch(_ urls: [URL], in directory: URL = MediaSpool.directory()) {
        guard !urls.isEmpty else { return }
        let now = Date()
        for url in urls where isSpoolName(url) && isInside(url, directory) {
            try? FileManager.default.setAttributes(
                [.modificationDate: now], ofItemAtPath: url.path)
        }
    }

    /// Delete files a session no longer cites — unless a *different* live session
    /// cites them too, which content-addressing makes possible.
    ///
    /// - Parameter keeping: paths still referenced by sessions that remain in the pool.
    static func discard(
        _ urls: [URL],
        keeping: Set<URL>,
        in directory: URL = MediaSpool.directory()
    ) {
        let keep = Set(keeping.map(MediaSpool.canonicalPath))
        var seen = Set<String>()
        for url in urls
        where isSpoolName(url) && isInside(url, directory) && !keep.contains(canonicalPath(url)) {
            guard !pins.holds(url) else { continue }
            guard seen.insert(canonicalPath(url)).inserted else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Collect idle files, then enforce the byte budget (least-recently-touched first).
    ///
    /// Bounded by one directory listing plus one pass per removal, and scoped to files
    /// this enum wrote (the `<hash>-<len>.<ext>` shape), so it cannot reach anything else.
    @discardableResult
    static func sweep(
        policy: Policy = .default,
        in directory: URL = MediaSpool.directory(),
        now: Date = Date()
    ) -> Sweep {
        var sweep = Sweep()
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .totalFileAllocatedSizeKey, .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles]
            )
        else {
            return sweep
        }
        var live: [(url: URL, bytes: UInt64, touched: Date)] = []
        for url in entries where isSpoolName(url) {
            let values =
                (try? url.resourceValues(
                    forKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey]))
            let bytes = UInt64(max(0, values?.totalFileAllocatedSize ?? 0))
            let touched = values?.contentModificationDate ?? .distantPast
            // Idle by the clock, and no request is holding it: collectable. A pinned file
            // stays and stays *out of the budget arithmetic* — it cannot be deleted, so
            // counting it against a budget the sweep cannot meet would only make the next
            // sweep delete live files sooner.
            let idle = now.timeIntervalSince(touched) >= Double(policy.idleTTL.components.seconds)
            if idle && pins.holds(url) { continue }
            if idle {
                if (try? fm.removeItem(at: url)) != nil {
                    sweep.removedIdle += 1
                    sweep.bytesFreed += bytes
                }
                continue
            }
            live.append((url, bytes, touched))
        }
        guard policy.maxBytes > 0 else { return sweep }
        var total = live.reduce(UInt64(0)) { $0 + $1.bytes }
        guard total > policy.maxBytes else { return sweep }
        for entry in live.sorted(by: { $0.touched < $1.touched }) {
            guard total > policy.maxBytes else { break }
            if (try? fm.removeItem(at: entry.url)) != nil {
                total -= entry.bytes
                sweep.removedOverBudget += 1
                sweep.bytesFreed += entry.bytes
            }
        }
        return sweep
    }

    /// Bytes currently held by the spool (what a sweep charged itself against).
    static func totalBytes(in directory: URL = MediaSpool.directory()) -> UInt64 {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return 0
        }
        return entries.reduce(UInt64(0)) { sum, url in
            guard isSpoolName(url) else { return sum }
            let bytes =
                (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0
            return sum + UInt64(max(0, bytes))
        }
    }
}
