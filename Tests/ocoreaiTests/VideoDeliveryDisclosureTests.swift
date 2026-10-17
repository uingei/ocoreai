// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! VideoDeliveryDisclosureTests.swift — the video line on `/v1/models` may only say what
//! this process measured, and must say it once it is true.
//!
//! Probe 08 measured that `mlx-community/gemma-4-e2b-it-4bit` sees video (red clip →
//! "Red", blue clip → "Blue", prompt 712 → 856) while `/v1/models` published nothing about
//! video. Invariant 2 cuts both ways: the surface may not claim more than the engine
//! delivered, and it may not withhold what the engine delivered. These tests pin the
//! ledger's exact values, the closed vocabulary, per-model isolation, and that the wire key
//! names match what the live probe reads — so the disclosure cannot drift silent again.

import Foundation
import Testing

@testable import ocoreai

@Suite("Video delivery disclosure — measured only, and stated once earned")
struct VideoDeliveryDisclosureTests {

    private static func repoFile(_ relative: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        struct Missing: Error, CustomStringConvertible {
            var path: String
            var description: String { "no repo file at \(path)" }
        }
        throw Missing(path: relative)
    }

    @Test("an unmeasured model reads not_observed, never a guess")
    func unmeasuredIsNotObserved() {
        var ledger = VideoDeliveryLedger()
        #expect(ledger.status(modelId: "mlx-community/Some-VLM") == "not_observed")
        #expect(ledger.record(modelId: "mlx-community/Some-VLM") == nil)
        #expect(ledger.evidence(modelId: "mlx-community/Some-VLM") == nil)
    }

    @Test("recording accumulates exact turn and item counts")
    func accumulationIsExact() {
        var ledger = VideoDeliveryLedger()
        ledger.record(modelId: "m", items: 2, promptTokens: 856)
        var entry = ledger.record(modelId: "m")
        #expect(entry?.turns == 1)
        #expect(entry?.items == 2)
        #expect(entry?.lastTurnPromptTokens == 856)

        ledger.record(modelId: "m", items: 1)
        entry = ledger.record(modelId: "m")
        #expect(entry?.turns == 2)
        #expect(entry?.items == 3)
        // A turn that reported no usage must not erase the last number it did report.
        #expect(entry?.lastTurnPromptTokens == 856)
        #expect(ledger.status(modelId: "m") == "delivered")
    }

    @Test("zero items records nothing — no phantom delivery from an empty parts array")
    func zeroItemsIsNoOp() {
        var ledger = VideoDeliveryLedger()
        ledger.record(modelId: "m", items: 0, promptTokens: 1234)
        #expect(ledger.record(modelId: "m") == nil)
        #expect(ledger.status(modelId: "m") == "not_observed")
    }

    @Test("the claim is per-model and does not leak across ids")
    func claimsArePerModel() {
        var ledger = VideoDeliveryLedger()
        ledger.record(modelId: "sees-video", items: 2)
        #expect(ledger.status(modelId: "sees-video") == "delivered")
        #expect(ledger.status(modelId: "text-only") == "not_observed")
        #expect(ledger.deliveries.count == 1)
    }

    @Test("unloading the model drops the claim with the weights")
    func forgetClearsTheClaim() {
        var ledger = VideoDeliveryLedger()
        ledger.record(modelId: "m", items: 1, promptTokens: 900)
        #expect(ledger.status(modelId: "m") == "delivered")
        ledger.forget(modelId: "m")
        #expect(ledger.status(modelId: "m") == "not_observed")
        #expect(ledger.evidence(modelId: "m") == nil)
    }

    @Test("the evidence line states how the claim was earned, exactly")
    func evidenceWordingIsExact() {
        var ledger = VideoDeliveryLedger()
        ledger.record(modelId: "m", items: 3, promptTokens: 856)
        #expect(
            ledger.evidence(modelId: "m")
                == "delivered in 1 completed turn(s), 3 video part(s), last prompt_tokens 856 on this server"
        )
        ledger.record(modelId: "n", items: 1)
        #expect(
            ledger.evidence(modelId: "n")
                == "delivered in 1 completed turn(s), 1 video part(s) on this server")
    }

    @Test("the published vocabulary is closed to two values")
    func vocabularyIsClosed() {
        #expect(VideoDeliveryLedger.statusDelivered == "delivered")
        #expect(VideoDeliveryLedger.statusNotObserved == "not_observed")
        var ledger = VideoDeliveryLedger()
        let before = ledger.status(modelId: "m")
        ledger.record(modelId: "m", items: 1)
        let after = ledger.status(modelId: "m")
        #expect([before, after] == ["not_observed", "delivered"])
    }

    @Test("`/v1/models` publishes both values of the vocabulary, the negative explicitly")
    static func wirePublishesBothVocabularyValues() throws {
        let router = try repoFile("Sources/ocoreai/Router/ChatCompletionsRouter.swift")
        #expect(router.count > 50_000, "router read looks truncated (\(router.count) chars)")
        #expect(
            router.contains("objects[i].videoInput = VideoDeliveryLedger.statusDelivered"),
            "/v1/models no longer publishes the measured `delivered` value")
        #expect(
            router.contains("objects[i].videoInput = VideoDeliveryLedger.statusNotObserved"),
            "the negative stopped being explicit: an absent field is not the same as not_observed")
        #expect(
            router.contains("objects[i].videoEvidence = record.evidenceLine"),
            "videoEvidence dropped — the claim would ship without how it was earned")
        // The sentence is assembled once, on the record. A router that re-wrote it here
        // could say something the ledger never measured.
        #expect(
            !router.contains("completed turn(s)"),
            "the router re-assembles the evidence sentence instead of quoting the record — two wordings, one truth"
        )
        #expect(
            router.contains("await enginePool.videoDeliverySnapshot()"),
            "/v1/models no longer reads the ledger — it would answer not_observed forever")
    }

    @Test("the wire keys follow this object's camelCase, and nil evidence stays absent")
    static func dtoKeyShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let delivered = ModelObject(
            id: "m",
            state: "ready",
            videoInput: VideoDeliveryLedger.statusDelivered,
            videoEvidence: "delivered in 1 completed turn(s), 2 video part(s) on this server")
        let deliveredJSON = String(data: try encoder.encode(delivered), encoding: .utf8) ?? ""
        #expect(
            deliveredJSON.contains("\"videoInput\":\"delivered\""),
            "wire keys wrong: \(deliveredJSON)")
        #expect(
            deliveredJSON.contains("\"videoEvidence\":"),
            "wire keys wrong: \(deliveredJSON)")

        let quiet = ModelObject(id: "m", state: "ready")
        let quietJSON = String(data: try encoder.encode(quiet), encoding: .utf8) ?? ""
        #expect(!quietJSON.contains("videoEvidence"), "nil evidence must not appear: \(quietJSON)")

        // Unload drops the claim with the weights; the router then publishes not_observed.
        let pool = try repoFile("Sources/ocoreai/Engine/EnginePool.swift")
        #expect(pool.count > 20_000, "EnginePool.swift read looks truncated (\(pool.count) chars)")
        #expect(
            pool.contains("videoDeliveries.forget(modelId: modelId)"),
            "unload no longer drops the video claim with the weights")
    }

    @Test("the engine records at the seam where frames and an answer both exist")
    static func recordSiteIsTheSuccessSeam() throws {
        let inference = try repoFile("Sources/ocoreai/Engine/EngineInference.swift")
        #expect(inference.count > 100_000, "EngineInference.swift read looks truncated")
        #expect(
            inference.contains("items: videoInputCount, promptTokens: promptTokens)"),
            "the ledger is no longer fed where a video turn completes — video_input would stay not_observed forever"
        )
        // The prompt size in the evidence line is upstream's own number, never a
        // bytes/4 heuristic dressed up as measurement.
        #expect(
            inference.contains("stdPromptTokenCount = completionInfo.promptTokenCount"),
            "the evidence number is no longer upstream GenerateCompletionInfo.promptTokenCount")
        // Counting happens where the model is handed the clip, not where bytes were spooled:
        // a file:// clip is delivered but never spooled.
        #expect(
            inference.contains(
                "if result.video != nil {\n                            videoInputCount += 1"),
            "video parts are no longer counted at the delivery seam")
    }
}
