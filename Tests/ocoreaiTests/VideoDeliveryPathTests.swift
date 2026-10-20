// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! VideoDeliveryPathTests.swift — where the video claim may be made, and where it may not.
//!
//! `VideoDeliveryDisclosureTests` pins what the ledger says once it is fed. This file pins
//! *who feeds it*, because that placement was the defect: the record sat inside
//! `releasePoolSlotWithAssistant`, which is a no-op whenever there is no pooled session —
//! the degraded CPU lane (`poolRef = nil`) and a pool-disabled engine (`sessionPool = nil`)
//! both run without one, and both still hand every frame to the processor. So an answered
//! video turn there published `not_observed`: invariant 2 violated in the direction of
//! silence, invisible to every test that only exercised the pooled path.
//!
//! The comments in this file's own subject used to claim the leak was elsewhere — on the
//! guided-gen / MTP early releases. Reading those branches instead of inferring them says
//! otherwise: their guards require every message to carry no video, so media cannot enter
//! them. That verdict is pinned here too, so if media ever is admitted to either path,
//! this gate goes red and whoever opens it re-examines the seam rather than inheriting a
//! stale note.

import Foundation
import Testing

@testable import ocoreai

@Suite("Video delivery seam — one home, on the completion path, never behind the pool")
struct VideoDeliveryPathTests {

    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 10 {
            let manifest = dir.appendingPathComponent("Package.swift")
            let sources = dir.appendingPathComponent("Sources/ocoreai")
            if FileManager.default.fileExists(atPath: manifest.path),
                FileManager.default.fileExists(atPath: sources.path)
            {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        struct Missing: Error, CustomStringConvertible {
            var description: String { "no repo root above \(#filePath)" }
        }
        throw Missing()
    }

    private static func source(_ relative: String) throws -> String {
        let url = try repoRoot().appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every Swift file under `Sources/ocoreai`, so "exactly one record site" is a claim
    /// about the tree rather than about the one file someone thought to open.
    private static func allSources() throws -> [(path: String, text: String)] {
        let root = try repoRoot().appendingPathComponent("Sources/ocoreai")
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            struct Unreadable: Error, CustomStringConvertible {
                var description: String { "cannot enumerate Sources/ocoreai" }
            }
            throw Unreadable()
        }
        var found: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            found.append((url.path, text))
        }
        return found
    }

    /// The body of a function declared at 12-space indentation, sliced to its closing brace.
    private static func body(of declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        guard
            let end = source.range(
                of: "\n            }", range: start.upperBound ..< source.endIndex)
        else { return nil }
        return String(source[start.lowerBound ..< end.upperBound])
    }

    @Test("the tree holds exactly one place that may record a video delivery")
    static func recordHasExactlyOneHome() throws {
        let files = try allSources()
        // Premise floor: a scan that stopped matching would find nothing and pass.
        #expect(
            files.count > 150, "scanned only \(files.count) Swift files — the tree read is broken")

        let hits = files.flatMap { file in
            file.text.components(separatedBy: "videoDeliveries.record(").dropFirst().map { _ in
                file.path
            }
        }
        #expect(
            hits.count == 1,
            "videoDeliveries.record( appears \(hits.count) times across \(hits): a second record site means two places deciding what the surface claims"
        )
        #expect(hits.first?.hasSuffix("Engine/EngineInference.swift") == true, "\(hits)")
    }

    @Test("that one home is the helper, and it guards its own premise")
    static func recordSitsInItsOwnHelper() throws {
        let inference = try source("Sources/ocoreai/Engine/EngineInference.swift")
        #expect(
            inference.count > 100_000,
            "EngineInference.swift read looks truncated (\(inference.count) chars)")
        guard let helper = body(of: "func recordVideoDelivery(promptTokens: Int?) {", in: inference)
        else {
            Issue.record("no recordVideoDelivery helper — the record is back inline")
            return
        }
        #expect(
            helper.contains("videoDeliveries.record("), "the helper no longer records: \(helper)")
        #expect(
            helper.contains("guard videoInputCount > 0 else { return }"),
            "the helper no longer refuses to record a turn that carried no frames")
    }

    @Test("the pooled release carries no claim — both pool-free lanes would lose it")
    static func claimIsNotGatedOnThePool() throws {
        let inference = try source("Sources/ocoreai/Engine/EngineInference.swift")
        // Premises: both lanes really can run without a pool, in this file and its owner.
        #expect(
            inference.contains("poolRef = nil"),
            "the CPU lane no longer drops the pool — if that changed, this gate needs re-reading, not re-pinning"
        )
        let pool = try source("Sources/ocoreai/Engine/EnginePool.swift")
        #expect(
            pool.contains("sessionPool = nil"),
            "a pool-disabled engine is no longer reachable — same re-read note as above")

        guard let release = body(of: "func releasePoolSlotWithAssistant(", in: inference) else {
            Issue.record("releasePoolSlotWithAssistant is gone — this gate's subject moved")
            return
        }
        #expect(release.contains("pool.release("), "slice is not the release helper: \(release)")
        #expect(
            !release.contains("videoDeliveries.record("),
            "the video claim is back inside the pooled release: the unpooled lane would under-report again"
        )
    }

    @Test("the record runs once, after the release, on the path that did not throw")
    static func recordRunsOnTheCompletionPath() throws {
        let inference = try source("Sources/ocoreai/Engine/EngineInference.swift")
        let call = "recordVideoDelivery(promptTokens: stdPromptTokenCount)"
        #expect(
            inference.components(separatedBy: call).count - 1 == 1,
            "expected exactly one call site of \(call)")
        guard let callRange = inference.range(of: call) else { return }
        guard let releaseRange = inference.range(of: "releasePoolSlotWithAssistant(assistantKey")
        else {
            Issue.record("the completion path no longer releases with the assistant message")
            return
        }
        guard
            let catchRange = inference.range(
                of: "RAII: guarantee pool slot release on any inference exception.",
                options: .backwards)
        else {
            Issue.record("the RAII catch is gone — the error path this call must stay off of moved")
            return
        }
        #expect(
            callRange.lowerBound > releaseRange.lowerBound
                && callRange.lowerBound > catchRange.lowerBound,
            "the record moved ahead of the release/error path — it could then fire for a turn that never completed"
        )
    }

    @Test("guided-gen and MTP cannot carry video, so they are not leaks")
    static func mediaCannotEnterGuidedOrMTP() throws {
        let inference = try source("Sources/ocoreai/Engine/EngineInference.swift")
        #expect(
            inference.components(separatedBy: ".videos.isEmpty").count - 1 >= 2,
            "fewer than two media guards in the routing body — a branch that used to exclude media now accepts it"
        )
        for marker in [
            "if let schema = options.grammarSchema,",
            "else if self.mtpDrafterContainer != nil,",
        ] {
            guard let range = inference.range(of: marker) else {
                Issue.record("routing guard \(marker) moved — re-read which paths can carry media")
                continue
            }
            let tail = inference[range.lowerBound...]
            let window = String(tail.prefix(600))
            #expect(
                window.contains(".videos.isEmpty"),
                "\(marker) no longer excludes video in its guard: the path can now deliver frames, so the record seam needs re-examining"
            )
        }
    }

    @Test("the log line that reports the claim exists once, beside the record")
    static func logLineIsSingleSourced() throws {
        let inference = try source("Sources/ocoreai/Engine/EngineInference.swift")
        let marker = "/v1/models now reports video_input=delivered"
        #expect(
            inference.components(separatedBy: marker).count - 1 == 1,
            "the video claim is logged from more than one place — two places, two wordings")
    }
}
