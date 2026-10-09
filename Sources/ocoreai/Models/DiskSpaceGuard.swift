import Foundation
import HuggingFace

/// Pre-download disk-space guard (roadmap line 6: lifecycle integrity).
///
/// First-principles failure this closes: a 40GB download on a nearly-full
/// volume fills the disk mid-transfer — the user gets a corrupt partial model,
/// the engine dies on load, and macOS itself destabilizes (a full boot volume
/// is worse than any failed download). The guard asks ONE honest question
/// before bytes flow: can this fit?
///
/// Requirement is tiered — accurate first, conservative second, never-blocking
/// third (the per-file download guards stay as the backstop):
///   1. measured: file sizes from repo metadata / HEAD, on the ACTIVE
///      endpoint (honors the HF_ENDPOINT mirror lever — mirror blobs are
///      byte-identical, so sizes carry over), minus bytes already cached;
///   2. unknown: allow through. The guard only blocks on honest numbers;
///      a missing size is never fabricated into a failure.
///
/// Headroom = 2 GB minimum OR 5% of free, whichever is larger — macOS needs
/// swap/snapshot breathing room independent of the model.
enum DiskSpaceGuard {
    /// Headroom kept free on the volume beyond the download itself.
    static func requiredHeadroom(freeBytes: Int64) -> Int64 {
        max(2_000_000_000, freeBytes / 20)
    }

    /// Pure decision — pinned by tests, no IO. Unknown sides never block.
    static func decision(freeBytes: Int64?, requiredBytes: Int64?) -> Bool {
        guard let free = freeBytes, let need = requiredBytes else { return true }
        return free - need >= requiredHeadroom(freeBytes: free)
    }

    /// Free bytes on the volume hosting `path` (nil when unreadable).
    static func freeBytes(onVolumeHosting path: URL) -> Int64? {
        do {
            let vals = try FileManager.default.attributesOfFileSystem(forPath: path.path)
            return (vals[.systemFreeSize] as? NSNumber)?.int64Value
        } catch {
            return nil
        }
    }

    /// Bytes still to fetch = remote total (matched globs) minus local cache.
    /// Any unknown file size, or no matched files, → nil (unknown, allow).
    static func requiredBytes(remoteTotal: Int64?, cachedBytes: Int64) -> Int64? {
        guard let total = remoteTotal else { return nil }
        return max(total - max(cachedBytes, 0), 0)
    }

    /// Local bytes already present for this repo (credit toward the ask).
    static func cachedBytes(in dir: URL, patterns: [String]) -> Int64 {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var total: Int64 = 0
        for name in entries where matchesGlob(name, patterns: patterns) {
            if let attrs = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path) {
                total += (attrs[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }

    static func matchesGlob(_ name: String, patterns: [String]) -> Bool {
        patterns.contains { glob in
            if glob.hasPrefix("*.") { return name.hasSuffix(String(glob.dropFirst(1))) }
            return name == glob
        }
    }

    /// Measured remote total via the HF SDK model metadata (siblings[].size,
    /// verified present in the pinned swift-huggingface). ANY gap (siblings
    /// nil, or a matched file without size) voids the whole measurement —
    /// never under-report a 40GB repo from partial data.
    static func measuredRemoteBytes(
        hub: HubClient,
        repoId: String,
        revision: String?,
        patterns: [String]
    ) async -> Int64? {
        guard let repo = Repo.ID(rawValue: repoId) else { return nil }
        do {
            // nil revision → server default (main) — same semantics as the
            // download call sites (`revision ?? "main"`).
            let model = try await hub.getModel(repo, revision: revision)
            guard let siblings = model.siblings, !siblings.isEmpty else { return nil }
            var total: Int64 = 0
            var matched = 0
            for s in siblings where matchesGlob(s.relativeFilename, patterns: patterns) {
                matched += 1
                guard let size = s.size.map(Int64.init) else { return nil }
                total += size
            }
            return matched == 0 ? nil : total
        } catch {
            return nil
        }
    }

    /// The full guard for the HF path: metadata total − cache, vs free−
    /// headroom. Blocks ONLY when both sides are honest numbers.
    static func ensureFits(
        hub: HubClient,
        repoId: String,
        revision: String?,
        patterns: [String],
        cacheDir: URL
    ) async throws {
        let remote = await measuredRemoteBytes(
            hub: hub, repoId: repoId, revision: revision, patterns: patterns)
        let required = requiredBytes(
            remoteTotal: remote, cachedBytes: cachedBytes(in: cacheDir, patterns: patterns))
        let free = freeBytes(onVolumeHosting: cacheDir)
        guard decision(freeBytes: free, requiredBytes: required) else {
            throw DownloaderError.insufficientDiskSpace(
                repoId: repoId,
                requiredBytes: required ?? 0,
                freeBytes: free ?? 0)
        }
    }
}
