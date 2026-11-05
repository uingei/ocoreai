// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! ModelWaitFaceHonestyTests — the Models page renders a wait the store measured, whoever began
//! it, and only the transfer lane may open/close that measurement.
//!
//! Two premises, both from reading shipped code and both false before this suite existed:
//! ① `ModelResultRow` gated its ring on `ModelManager.downloadingModelId`, which records the
//!   window that BEGAN a fetch — so during a boot prewarm (the exact user the failure banner
//!   routes to this page) gigabytes landed while the row showed an enabled `Download` button and
//!   no wait; the store had the bytes the whole time.
//! ② `ModelManager._downloadAndLoad` called `finish` on its way out. When its `pool.acquire`
//!   times out at the 120 s wait window behind a 794 s cold fetch, that `finish` evicted the
//!   prewarm's LIVE row — the ring went blank mid-transfer and `/v1/models`' `loadProgress`
//!   (which reads the same store) reported `downloading:false` for a fetch still landing bytes.
//! The store is seeded through an isolated `init(forTesting:)` instance, never `.shared` —
//! process-global state is leased, never set (§ Testing Quality); the scan finds the repo root
//! by searching and floors its own hit counts.

import Foundation
import Testing

@testable import ocoreai

@Suite("Model wait face — a wait is what the store measured")
struct ModelWaitFaceHonestyTests {

    private let id = "mlx-community/Test-4bit"

    private func seededStore(completed: Int64, total: Int64) -> OcoreaiDownloadProgress {
        let store = OcoreaiDownloadProgress(forTesting: ())
        store.start(modelId: id)
        store.updateBytes(completed: completed, total: total, for: id)
        return store
    }

    @Test("a prewarm's wait renders with its measured bytes, stoppable=false (no window task)")
    func prewarmWaitIsVisible() {
        let store = seededStore(completed: 1_073_741_824, total: 4_294_967_296)
        let face = ModelWaitFace.resolve(
            modelId: id, ownedModelId: "", hasOwnedTask: false, store: store)
        guard case .downloading(let progress, let stoppable) = face else {
            Issue.record("an active store row must render as .downloading, got \(face)")
            return
        }
        #expect(progress.completedBytes == 1_073_741_824)
        #expect(progress.totalBytes == 4_294_967_296)
        #expect(progress.fraction == 0.25)
        #expect(progress.startedAt != nil, "the row clocked its start; the stats row earns it")
        #expect(!stoppable, "this window did not begin the fetch — it may watch, not stop")
    }

    @Test("the window that owns the task gets Stop; a prefixed row id still finds the row")
    func ownerGetsStopThroughNormalizedKey() {
        // The store keys on the prefix-stripped id (MLXBridge strips `mscope:`/`hf:`); a row
        // holding `mscope:…` that failed to normalize would find nothing and render silence.
        let store = seededStore(completed: 1_000, total: 4_000)
        let face = ModelWaitFace.resolve(
            modelId: "mscope:\(id)", ownedModelId: id, hasOwnedTask: true, store: store)
        #expect(
            face == .downloading(progress: store.progress(for: id)!, stoppable: true),
            "exact face: the store snapshot verbatim, owned → stoppable")
    }

    @Test("owned wait with no bytes measured yet is a spinner, not a bar")
    func waitWithoutBytes() {
        let store = OcoreaiDownloadProgress(forTesting: ())
        let face = ModelWaitFace.resolve(
            modelId: id, ownedModelId: id, hasOwnedTask: true, store: store)
        #expect(face == .loadingWithoutBytes(stoppable: true))
        // A task owned for ANOTHER model must not make this row claim a wait.
        let other = ModelWaitFace.resolve(
            modelId: id, ownedModelId: "someone/else", hasOwnedTask: true, store: store)
        #expect(other == .idle)
    }

    @Test("idle before the fetch and after it ends — the wait dies with the transfer, not a poller")
    func idleAtBothEnds() {
        let store = seededStore(completed: 4_000, total: 4_000)
        #expect(
            ModelWaitFace.resolve(
                modelId: id, ownedModelId: "", hasOwnedTask: false, store: store
            ).isLive)
        store.finish(modelId: id, success: true)
        let after = ModelWaitFace.resolve(
            modelId: id, ownedModelId: "", hasOwnedTask: false, store: store)
        #expect(after == .idle)
        #expect(!after.isLive)
    }

    @Test("hasActiveDownloads answers only while a row is live")
    func hasActiveTracksLiveness() {
        let store = OcoreaiDownloadProgress(forTesting: ())
        #expect(!store.hasActiveDownloads())
        store.start(modelId: id)
        #expect(store.hasActiveDownloads())
        store.updateBytes(completed: 1, total: 2, for: id)
        #expect(store.hasActiveDownloads())
        store.finish(modelId: id, success: false)
        #expect(!store.hasActiveDownloads())
    }

    @Test("a disk-backed load renders from the pool's own state field, which ModelID keeps")
    func poolStateSurvivesTheParse() {
        // A load whose weights are on disk opens no store row and no window task — the face is
        // `.idle` for it by construction, so the card asks the pool instead, through this parse.
        let loading = ModelID.fromListModels(["id": id, "state": "loading"])
        #expect(
            loading.isPoolLoading, "state=loading must survive into presentation, not be discarded")
        #expect(!ModelID.fromListModels(["id": id, "state": "ready"]).isPoolLoading)
        #expect(!ModelID.fromListModels(["id": id]).isPoolLoading, "absent state is not a wait")
    }

    // MARK: - Lifecycle ownership scan

    private enum ScanError: Error { case rootNotFound }

    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let marker = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: marker.path),
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("Sources").path)
            {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw ScanError.rootNotFound
    }

    /// Doc comments cite these selectors by name (the store's own header teaches the protocol);
    /// a scan that counts prose would name files that touch nothing.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let t = line.trimmingCharacters(in: CharacterSet.whitespaces)
                return !t.hasPrefix("//") && !t.hasPrefix("*")
            }
            .joined(separator: "\n")
    }

    @Test(
        "only the transfer lane opens/closes progress rows — a waiter's finish evicts the owner's bytes"
    )
    func transferLaneOwnsLifecycle() throws {
        let root = try Self.repoRoot()
        let sources = root.appendingPathComponent("Sources")
        guard
            let enumerator = FileManager.default.enumerator(
                at: sources, includingPropertiesForKeys: nil)
        else { throw ScanError.rootNotFound }

        let bridge = "Sources/ocoreai/Engine/MLXBridge.swift"
        let manager = "Sources/ocoreai/UI/ViewModels/ModelManager.swift"
        var starts: [String: Int] = [:]
        var finishes: [String: Int] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let text = Self.codeOnly(raw)
            let s = text.components(separatedBy: ".start(modelId:").count - 1
            let f = text.components(separatedBy: ".finish(modelId:").count - 1
            if s > 0 { starts[rel] = s }
            if f > 0 { finishes[rel] = f }
        }

        // Floors: if the patterns stop matching anything, "no offenders" is vacuously true —
        // the failure mode this repo keeps tripping over (§ Testing Quality).
        let total = starts.values.reduce(0, +) + finishes.values.reduce(0, +)
        #expect(
            total >= 6,
            "the lifecycle scan still sees the two lanes' open/close sites (floor 6, measured \(total))"
        )

        // Opens: exactly the two hub lanes in MLXBridge (ModelScope, HuggingFace).
        #expect(
            starts == [bridge: 2],
            "only MLXBridge's two hub lanes may open a progress row; measured \(starts)")
        // Closes: the same lane, plus exactly one UI voice — `deleteModel`, where deleting the
        // model moots the row. A second UI close is a waiter evicting an owner (premise ②).
        #expect(
            Set(finishes.keys) == [bridge, manager],
            "progress rows close only in the transfer lane and deleteModel; measured \(finishes)")
        #expect(
            finishes[manager] == 1,
            "ModelManager keeps exactly the deleteModel close (measured \(finishes[manager] ?? 0))")
    }
}
