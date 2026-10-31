// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// LoRABatchGeometryTests.swift — a LoRA `batch_size` below 1 is a refusal, never a trap.
///
/// Upstream cuts a batch as `(index ..< min(index + batchSize, count))` (`LoraTrain.swift:43-45`)
/// and validates nothing: a negative inverts the range and Swift's `Range` precondition traps, 0
/// yields an empty batch and `precondition(maxLength >= 2)` at `:49` traps. Either one kills the
/// server mid-request on `POST /v1/models/evaluate` and `POST /v1/models/train`.
///
/// The engine call itself needs weights, which this cache does not hold, so what is proven here is
/// the two things that do not: the decision (exact values, both sides of each bound) and its
/// placement — every face must ask before it resolves a model, read off the file rather than from
/// a claim about it. The live half ships in `scripts/probes/23-lora-seam-honesty.sh`.

import Foundation
import Testing

@testable import ocoreai

@Suite("LoRA batch geometry: the decision")
struct LoRABatchGeometryDecisionTests {

    @Test(
        "a batch of fewer than one is refused at both bounds, and a real batch is not",
        arguments: [(0, true), (-1, true), (-1024, true), (1, false), (4, false), (4096, false)])
    func batchSize(value: Int, refused: Bool) {
        let violation = LoRABatchGeometry.firstViolation(batchSize: value)
        #expect((violation != nil) == refused)
        if refused {
            #expect(violation?.field == "batch_size")
            #expect(violation?.arrived == value)
        }
    }

    @Test(
        "0 means no cap and stays legal; a negative cap is refused",
        arguments: [(0, false), (1, false), (99, false), (-1, true), (-7, true)])
    func cap(value: Int, refused: Bool) {
        let violation = LoRABatchGeometry.firstViolation(batchSize: 4, maxBatches: value)
        #expect((violation != nil) == refused)
        if refused {
            #expect(violation?.field == "max_batches")
            #expect(violation?.arrived == value)
        }
    }

    @Test("the batch is asked before the cap, so the fatal value is the one reported")
    func fatalValueWins() {
        let violation = LoRABatchGeometry.firstViolation(batchSize: 0, maxBatches: -1)
        #expect(violation?.rule == .batchSize)
    }

    @Test("a nested request names the path the client wrote")
    func fieldLabelTravels() {
        let violation = LoRABatchGeometry.firstViolation(
            batchSize: 0, batchSizeField: "hyperparams.batch_size")
        #expect(violation?.field == "hyperparams.batch_size")
        #expect(
            LoRABatchGeometry.message(for: violation!)
                == "hyperparams.batch_size must be >= 1; 0 builds an empty or inverted batch range "
                + "inside the engine and takes the process with it.")
    }

    @Test("the cap wording names the silent answer, not a range")
    func capWording() {
        let violation = LoRABatchGeometry.Violation(rule: .cap, field: "max_batches", arrived: -3)
        #expect(
            LoRABatchGeometry.message(for: violation)
                == "max_batches must be 0 for no cap, or a positive count; -3 would silently score "
                + "one batch.")
    }
}

@Suite("LoRA batch geometry: both wire faces guard, before they load")
struct LoRABatchGeometrySurfaceTests {

    private static let handler = "Sources/ocoreai/Handlers/LLMLifecycleHandler.swift"

    private struct Missing: Error, CustomStringConvertible {
        let what: String
        var description: String { "could not find \(what) walking up from \(#filePath)" }
    }

    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        while dir.path != "/" {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Sources/ocoreai").path),
                FileManager.default.fileExists(atPath: dir.appendingPathComponent("Tests").path)
            {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw Missing(what: "repo root (Sources/ocoreai + Tests)")
    }

    /// Comment-aware code lines: prose may name a forbidden shape in order to forbid it.
    private static func codeLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter {
            line in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            return !(trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*"))
        }
    }

    /// Every zero-tolerance count self-proves its own pattern first (invariant 1): a scan that
    /// stopped matching would report a clean tree, which is the failure it exists to catch.
    @Test("both LoRA faces guard the geometry, and neither resolves a model to do it")
    static func facesGuardBeforeLoading() throws {
        let patterns = ["LoRABatchGeometry.firstViolation(", "enginePool.mlxContainer(modelId:"]
        let selfProof = [
            "if let v = LoRABatchGeometry.firstViolation(batchSize: b) {",
            "let c = try await enginePool.mlxContainer(modelId: id)",
        ]
        for pattern in patterns {
            #expect(
                selfProof.contains { $0.contains(pattern) },
                "the instrument cannot see its own pattern — \(pattern)")
        }

        let root = try repoRoot()
        let handlerLines = codeLines(
            try String(
                contentsOf: root.appendingPathComponent(handler), encoding: .utf8))
        let guards = handlerLines.indices.filter {
            handlerLines[$0].contains("LoRABatchGeometry.firstViolation(")
        }
        let loads = handlerLines.indices.filter {
            handlerLines[$0].contains("enginePool.mlxContainer(modelId:")
        }

        // Two faces (train, evaluate), one guard each, and exactly two model resolutions in the
        // file: a third face added without a guard, or a guard moved after the load, trips this.
        #expect(guards.count == 2, "found \(guards.count) geometry guards, expected one per face")
        #expect(loads.count == 2, "found \(loads.count) model resolutions, expected one per face")
        for (guard_, load) in zip(guards, loads) {
            #expect(
                guard_ < load,
                "a face resolves its model before refusing a bad batch_size — \(handler):\(guard_)")
        }
    }
}
