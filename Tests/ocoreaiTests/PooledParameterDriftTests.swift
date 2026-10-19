// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PooledParameterDriftTests.swift — a reused pooled session must carry *this* turn's
/// sampling knobs, not the ones it was created with.
///
/// Sampling does not travel with the call in mlx-swift-lm: `ChatSession` stores
/// `generateParameters` (`ChatSession.swift:370`) and `streamMap` captures that property in
/// its task capture list (`:986-990`). A pooled session handed back untouched therefore
/// answers the next turn under the previous turn's knobs.
///
/// Measured 10-19 before this fix (`mlx-community/gemma-4-e2b-it-4bit`, temp 0, two turns
/// on one session): a `response_format: json_object` turn at `max_tokens=64` left 64
/// behind, and the following plain turn asked for 8 and spent 64 (`finish_reason=length`,
/// 370 characters cut mid-sentence) while the same log said `wireMaxTokens=8` and
/// `Generation budget: maxTokens=8`. Behaviour lives in probe 14 §7; these tests pin the
/// field set the refresh covers and the site that performs it, so a narrowed comparison or
/// a deleted assignment goes red here instead of shipping as "budget ignored sometimes".

import Foundation
import MLXLMCommon
import Testing

@testable import ocoreai

@Suite("Pooled session — per-turn generation parameters")
struct PooledParameterDriftTests {

    /// Every knob ``MLXSessionPool/staleSamplingFields(before:after:)`` claims to compare.
    ///
    /// The helper's own premise, stated here so a dropped comparison cannot pass
    /// vacuously: delete a field from the helper and the full-surface case below goes red.
    private static let trackedFields: [String] = [
        "maxTokens", "temperature", "topP", "topK", "minP", "seed", "logProbabilities",
        "repetitionPenalty", "repetitionContextSize",
        "presencePenalty", "presenceContextSize",
        "frequencyPenalty", "frequencyContextSize",
        "prefillStepSize", "toolCallPolicy",
    ]

    /// Parameters with every tracked knob set to a distinct, non-default value.
    private static func surface(_ s: Int) -> GenerateParameters {
        var p = GenerateParameters()
        p.maxTokens = 8 + s
        p.temperature = Float(0.1 * Double(s + 1))
        p.topP = Float(0.5) + Float(s)
        p.topK = 40 + s
        p.minP = Float(0.05) + Float(s)
        p.seed = UInt64(1000 + s)
        p.logProbabilities = s
        p.repetitionPenalty = Float(1.1) + Float(s)
        p.repetitionContextSize = 512 + s
        p.presencePenalty = Float(0.2) + Float(s)
        p.presenceContextSize = 256 + s
        p.frequencyPenalty = Float(0.3) + Float(s)
        p.frequencyContextSize = 128 + s
        p.prefill.stepSize = 512 + s
        p.toolCallPolicy = s == 0 ? ToolCallPolicy() : ToolCallPolicy(validation: .strict)
        return p
    }

    @Test("the whole tracked surface is compared, by name and in order")
    func fullSurfaceReportsEveryField() {
        let drift = MLXSessionPool.staleSamplingFields(
            before: Self.surface(0), after: Self.surface(1))
        #expect(drift == Self.trackedFields)
        // Floor: a helper that stopped comparing most knobs cannot pass this suite.
        #expect(drift.count >= 15)
    }

    @Test("identical parameters drift on nothing")
    func identicalParametersReportNothing() {
        let drift = MLXSessionPool.staleSamplingFields(
            before: Self.surface(2), after: Self.surface(2))
        #expect(drift.isEmpty)
    }

    @Test("the measured leak: max_tokens 64 → 8 is named, and only it")
    func measuredBudgetLeakIsNamed() {
        var stored = GenerateParameters()
        stored.maxTokens = 64
        stored.temperature = 0
        var incoming = GenerateParameters()
        incoming.maxTokens = 8
        incoming.temperature = 0
        #expect(
            MLXSessionPool.staleSamplingFields(before: stored, after: incoming) == ["maxTokens"])
    }

    @Test("greedy is a knob: temperature 0 → 1.2 is named without max_tokens moving")
    func temperatureAloneIsNamed() {
        var stored = GenerateParameters()
        stored.maxTokens = 8
        stored.temperature = 0
        var incoming = GenerateParameters()
        incoming.maxTokens = 8
        incoming.temperature = 1.2
        #expect(
            MLXSessionPool.staleSamplingFields(before: stored, after: incoming) == ["temperature"])
    }

    @Test("cache-affecting fields are excluded — upstream reconciles those itself")
    func cacheFieldsAreNotClaimedAsDrift() {
        var stored = GenerateParameters()
        stored.maxKVSize = 4096
        stored.kvBits = 8
        stored.kvGroupSize = 64
        stored.quantizedKVStart = 0
        stored.kvScheme = "uniform"
        var incoming = GenerateParameters()
        incoming.maxKVSize = 2048
        incoming.kvBits = 4
        incoming.kvGroupSize = 32
        incoming.quantizedKVStart = 512
        incoming.kvScheme = "quantizedKV"
        #expect(MLXSessionPool.staleSamplingFields(before: stored, after: incoming).isEmpty)
    }

    // MARK: — the refresh is wired, not just computable

    /// Source of the pool, found by walking up (never by fixed path hops — three
    /// "passing" scan assertions in this repo were really ENOENT).
    private static func sessionPoolSource() throws -> String {
        let relative = "Sources/ocoreai/Engine/SessionPool.swift"
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 6 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw MissingRepoFile(path: "\(dir.path)/\(relative)")
    }

    struct MissingRepoFile: Error, CustomStringConvertible {
        let path: String
        var description: String { "no repo file at \(path) (walked up from \(#filePath))" }
    }

    @Test("acquire hands back this turn's parameters — the assignment and its log site")
    func refreshIsWiredAtAcquire() throws {
        let source = try Self.sessionPoolSource()
        // Floor the scan's own premise: if either pattern stopped matching, the counts
        // below would read 0 and "exactly one" would be indistinguishable from "no file".
        #expect(source.contains("static func staleSamplingFields("))
        #expect(source.contains("func acquire("))
        let assignment = try NSRegularExpression(
            pattern: #"pooled\.session\.generateParameters\s*=\s*genParams"#)
        let calls = try NSRegularExpression(
            pattern: #"staleSamplingFields\(\s*before: pooled\.session\.generateParameters"#)
        let range = NSRange(source.startIndex..., in: source)
        let assignments = assignment.matches(in: source, range: range).count
        let driftCalls = calls.matches(in: source, range: range).count
        // Exactly one home for the decision: one assignment, one drift call.
        #expect(assignments == 1)
        #expect(driftCalls == 1)
        // And it sits in `acquire`, where a pooled session is handed out. A call site in
        // an unreachable helper would satisfy the counts above and prove nothing, so match
        // on position, not on the whole file.
        let acquireStart = try #require(source.range(of: "func acquire("))
        let acquireBody = source[acquireStart.lowerBound...]
        #expect(acquireBody.contains("pooled.session.generateParameters = genParams"))
        #expect(acquireBody.contains("overriddenFields.joined(separator: \",\")"))
    }
}
