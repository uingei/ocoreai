// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Download-plan tests — what a dry-run answers, and what it must refuse to answer.
///
/// The dry-run publishes bytes-to-fetch before bytes flow, so its promise is the same one
/// the pre-flight guard owns: a number only when something measured it. Everything here is a
/// pure or filesystem-only surface — no network, no fixed sleep, and no assertion that
/// merely checks a call did not throw.

import Foundation
import HuggingFace
import MLXHuggingFace
import Testing

@testable import ocoreai

private struct DiscloseError: Error, CustomStringConvertible {
    let text: String
    init(_ text: String) { self.text = text }
    var description: String { text }
}

private func planTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DownloadPlanTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeModelFiles(in root: URL, strayOnly: Bool = false) throws -> URL {
    let dir = root.appendingPathComponent("org/name", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if strayOnly {
        try String(repeating: "x", count: 5).write(
            to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return dir
    }
    try String(repeating: "a", count: 10).write(
        to: dir.appendingPathComponent("model.safetensors"), atomically: true, encoding: .utf8)
    try String(repeating: "b", count: 2).write(
        to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    try String(repeating: "c", count: 3).write(
        to: dir.appendingPathComponent("chat_template.jinja"), atomically: true,
        encoding: .utf8)
    return dir
}

@Suite("DownloadPlan — a dry-run reports only what it measured")
struct DownloadPlanTests {

    // ---- verdict: the reportable direction of honesty ----

    @Test("unknown required bytes is reported as unknown, not as a fit")
    func verdictUnknownRequiredIsNil() {
        #expect(DiskSpaceGuard.verdict(freeBytes: 100_000_000_000, requiredBytes: nil) == nil)
    }

    @Test("unknown free bytes is reported as unknown, not as a fit")
    func verdictUnknownFreeIsNil() {
        #expect(DiskSpaceGuard.verdict(freeBytes: nil, requiredBytes: 40_000_000_000) == nil)
    }

    @Test("comfortable volume reports a fit")
    func verdictComfortableFits() {
        // 100 GB free, 40 GB needed; headroom max(2e9, 5e9) = 5e9; 60e9 left >= 5e9.
        #expect(
            DiskSpaceGuard.verdict(freeBytes: 100_000_000_000, requiredBytes: 40_000_000_000)
                == true)
    }

    @Test("a hole bigger than free minus headroom reports no fit")
    func verdictTooBigDoesNotFit() {
        // 100 GB free, 99 GB needed; headroom 5e9; 1e9 left < 5e9.
        #expect(
            DiskSpaceGuard.verdict(freeBytes: 100_000_000_000, requiredBytes: 99_000_000_000)
                == false)
    }

    @Test("a nil verdict and a blocking decision disagree on purpose")
    func verdictAndDecisionDifferOnSilence() {
        // The guard must not block on silence; the plan must not claim on silence.
        #expect(DiskSpaceGuard.decision(freeBytes: 1_000, requiredBytes: nil) == true)
        #expect(DiskSpaceGuard.verdict(freeBytes: 1_000, requiredBytes: nil) == nil)
    }

    // ---- presence: what may stand for a complete model ----

    @Test("an empty pattern list certifies nothing")
    func emptyPatternsAreNeverSatisfied() throws {
        let root = try planTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try writeModelFiles(in: root)
        // `matching: []` means "the whole repo" to swift-huggingface. Returning true here
        // let any existing directory stand for a fetched model.
        #expect(
            ReadyHubDownloader(hub: try HubClient(), flatRoot: root)
                .allPatternsSatisfied([], in: dir) == false)
    }

    @Test("one stray file is not a model")
    func strayFileIsNotSatisfied() throws {
        let root = try planTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try writeModelFiles(in: root, strayOnly: true)
        #expect(
            ReadyHubDownloader(hub: try HubClient(), flatRoot: root)
                .allPatternsSatisfied(ModelStore.modelDownloadPatterns, in: dir) == false)
    }

    @Test("every required glob present is satisfied")
    func completeSetIsSatisfied() throws {
        let root = try planTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try writeModelFiles(in: root)
        #expect(
            ReadyHubDownloader(hub: try HubClient(), flatRoot: root)
                .allPatternsSatisfied(ModelStore.modelDownloadPatterns, in: dir) == true)
    }

    @Test("a subdirectory in the model dir does not end the search")
    func subdirectoryDoesNotTruncateTheWalk() throws {
        let root = try planTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try writeModelFiles(in: root)
        // The subdir is created last, so an enumerator that returns entries in creation order
        // yields it after the required files; the walk has to skip it either way. This is a
        // regression guard for a walk that stopped at the first non-regular entry.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("snapshots", isDirectory: true),
            withIntermediateDirectories: true)
        #expect(
            ReadyHubDownloader(hub: try HubClient(), flatRoot: root)
                .allPatternsSatisfied(ModelStore.modelDownloadPatterns, in: dir) == true)
    }

    @Test("a directory that does not exist is not satisfied")
    func missingDirIsNotSatisfied() throws {
        let root = try planTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("org/absent", isDirectory: true)
        #expect(
            ReadyHubDownloader(hub: try HubClient(), flatRoot: root)
                .allPatternsSatisfied(ModelStore.modelDownloadPatterns, in: dir) == false)
    }

    // ---- plan assembly ----

    @Test("a model already on disk plans zero bytes and quotes exact cached bytes")
    func locallySatisfiedPlansZero() async throws {
        let root = try planTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeModelFiles(in: root)
        let plan = try await ReadyHubDownloader(hub: try HubClient(), flatRoot: root).plan(
            id: "org/name", revision: nil, useLatest: false)
        #expect(plan.model == "org/name")
        #expect(plan.provider == "hf")
        #expect(plan.requiredBytes == 0)
        #expect(plan.cachedBytes == 15)
        #expect(plan.wouldFit == true)
        #expect(plan.basis == "locallySatisfied")
    }

    @Test("a repository id the SDK rejects is refused, not planned")
    func invalidRepoIdThrows() async throws {
        let root = try planTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = try HubClient()
        await #expect(throws: HuggingFaceDownloaderError.self) {
            _ = try await ReadyHubDownloader(hub: hub, flatRoot: root).plan(
                id: "not-a-repo", revision: nil, useLatest: false)
        }
    }

    @Test("matched totals credit only the files already local")
    func matchedTotalsCreditCache() {
        let entries = [
            ModelScopeDownloader.FileInfo(path: "a.safetensors", size: 100, type: "file"),
            ModelScopeDownloader.FileInfo(path: "b.safetensors", size: 200, type: "file"),
            ModelScopeDownloader.FileInfo(path: "config.json", size: 50, type: "file"),
        ]
        let totals = ModelScopeDownloader.matchedTotals(
            entries, existingFilenames: ["a.safetensors", "config.json"])
        #expect(totals.remoteTotal == 350)
        #expect(totals.cachedBytes == 150)
    }

    @Test("one sizeless entry makes the remote total unknown, never a guess")
    func sizelessEntryLeavesRemoteUnknown() {
        let entries = [
            ModelScopeDownloader.FileInfo(path: "a.safetensors", size: 100, type: "file"),
            ModelScopeDownloader.FileInfo(path: "b.safetensors", size: nil, type: "file"),
            ModelScopeDownloader.FileInfo(path: "config.json", size: 50, type: "file"),
        ]
        let totals = ModelScopeDownloader.matchedTotals(
            entries, existingFilenames: ["a.safetensors", "config.json"])
        #expect(totals.remoteTotal == nil)
        #expect(totals.cachedBytes == 150)
    }

    // ---- wire shape ----

    @Test("a plan event carries the plan and names its own type")
    func planEventEncodesItsOwnKind() throws {
        let event = DownloadSSEEvent.plan(
            "hf:org/name",
            plan: DownloadPlan(
                model: "org/name", provider: "hf", requiredBytes: 42, remoteTotalBytes: 4_096,
                cachedBytes: 4_054, freeBytes: 999, wouldFit: true, basis: "measured"))
        let data = try JSONEncoder().encode(event)
        let back = try JSONDecoder().decode(DownloadSSEEvent.self, from: data)
        #expect(back.eventType == "plan")
        #expect(back.plan?.requiredBytes == 42)
        #expect(back.plan?.remoteTotalBytes == 4_096)
        #expect(back.plan?.cachedBytes == 4_054)
        #expect(back.plan?.basis == "measured")
    }

    @Test("a progress event carries no plan key at all")
    func progressEventOmitsPlanKey() throws {
        let event = DownloadSSEEvent.progress(
            "hf:org/name", percentage: 10, totalBytes: 100, transferredBytes: 10, eta: 5)
        let json =
            String(
                data: try JSONEncoder().encode(event), encoding: .utf8) ?? ""
        #expect(!json.contains("\"plan\""))
        #expect(event.plan == nil)
    }
}
// ---- the call site keeps the one home ----

@Test("no download call site asks swift-huggingface for the whole repo by empty pattern")
func noEmptyPatternAtDownloadCallSites() throws {
    let fm = FileManager.default
    var rootURL = URL(fileURLWithPath: #filePath, isDirectory: false)
    while rootURL.lastPathComponent != "ocoreai" {
        rootURL.deleteLastPathComponent()
    }
    let sources = rootURL.appendingPathComponent("Sources", isDirectory: true)
    var offenders: [String] = []
    var sawMatchingArg = 0
    guard
        let it = fm.enumerator(
            at: sources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
    else { throw DiscloseError("no Sources directory under \(rootURL.path)") }
    while let item = it.nextObject() {
        // `while let x = …, cond` would BREAK on the first non-swift entry; a scan that
        // stops early looks like a clean sweep, which is the failure mode this file exists
        // to catch. Skip, do not stop.
        guard let url = item as? URL, url.pathExtension == "swift" else { continue }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for (n, line) in text.split(separator: "\n").enumerated() {
            let body = String(line)
            if body.contains("matching:") {
                sawMatchingArg += 1
                if body.replacingOccurrences(of: " ", with: "").contains("matching:[]"),
                    !body.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                {
                    offenders.append("\(url.lastPathComponent):\(n + 1)")
                }
            }
        }
    }
    // The scan must have seen the argument it is policing, or it proves nothing.
    #expect(sawMatchingArg >= 4, "scan saw only \(sawMatchingArg) `matching:` call sites")
    #expect(offenders == [], "empty pattern list at \(offenders.joined(separator: ", "))")
}
