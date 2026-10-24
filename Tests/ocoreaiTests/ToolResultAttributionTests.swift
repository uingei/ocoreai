// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// A refused tool call must say what was asked, and both generation lanes must publish what they
/// actually did.
///
/// Measured before this suite: `ToolResultMeta(` had exactly one construction site (the std lane),
/// so the MTP loop dispatched every call it collected and published none of them — a GUI tool card
/// under MTP had no real duration, no failure and no summary. And no refusal anywhere carried the
/// arguments that missed, while a native turn echoes no `tool_calls` on the wire at all, so a
/// client could not tell a wrong path from a wrong `oldString` from a call that never left here.
/// Both are invariant-2 defects: the surface reported less than the engine had done.
///
/// Exact values throughout; every scan floors its own premises so a regex that stopped matching
/// fails instead of passing vacuously.

import Foundation
import Testing

@testable import ocoreai

private func attributionRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while root.path != "/",
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
    {
        root.deleteLastPathComponent()
    }
    #expect(root.path != "/", "repo root not found from \(#filePath)")
    return root
}

private func readSource(_ relative: String) throws -> String {
    let url = attributionRoot().appendingPathComponent(relative)
    return try String(contentsOf: url, encoding: .utf8)
}

private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

// MARK: - The digest itself

@Test func digestSortsKeysSoRefusalsDiff() {
    // Unordered dictionary, ordered rendering: two refusals of one call must read identically.
    #expect(ToolResultMeta.argumentsDigest(["b": 2, "a": "x"]) == #"a="x" b=2"#)
}

@Test func digestEscapesNewlinesOntoOneLine() {
    #expect(ToolResultMeta.argumentsDigest(["s": "a\nb"]) == #"s="a\nb""#)
}

@Test func digestNamesNullAndCountsWhatItDropped() {
    #expect(ToolResultMeta.argumentsDigest(["k": NSNull()]) == "k=null")
    let content = String(repeating: "a", count: 130)
    // The rendered value is the quoted form: 132 bytes, capped at 120 ⇒ 12 dropped.
    let capped = ToolResultMeta.argumentsDigest(["path": content], valueLimit: 120)
    #expect(capped == #"path=""# + String(repeating: "a", count: 119) + "…(+12)")
}

@Test func digestKeepsStructuredValuesReadable() throws {
    let digest = ToolResultMeta.argumentsDigest(["n": [1, 2]])
    #expect(digest.hasPrefix("n=[1"), "got \(digest)")
    #expect(digest.contains("2"), "got \(digest)")
}

@Test func digestSurvivesValuesThatAreNotJSONFragments() {
    // Measured: a `null` argument aborted the process — `NSNull` is non-nil, and
    // `withJSONObject` answers it with an Objective-C exception that `try?` cannot catch.
    #expect(ToolResultMeta.argumentsDigest(["k": NSNull()]) == "k=null")
    let odd = ToolResultMeta.argumentsDigest(["k": Date(timeIntervalSince1970: 0)])
    #expect(odd.hasPrefix("k="), "got \(odd)")
    // The gate for the class of bug: the arbitrary-value site asks before it converts.
    let events = (try? readSource("Sources/ocoreai/Engine/EngineEvents.swift")) ?? ""
    #expect(events.contains("JSONSerialization.isValidJSONObject(value),"))
    #expect(events.contains("if value is NSNull { return \"null\" }"))
}

// MARK: - The publisher: one home, both lanes

@Test func publisherCarriesArgumentsOnlyOnFailure() async throws {
    let (stream, continuation) = AsyncThrowingStream<InferenceEvent, Error>.makeStream()
    let started = ContinuousClock.now.advanced(by: .milliseconds(-25))
    ToolResultPublisher.emit(
        continuation, id: "call-ok", name: "read_file", summary: "3 lines",
        failure: nil, startedAt: started, arguments: #"path="a.py""#)
    ToolResultPublisher.emit(
        continuation, id: "call-bad", name: "edit_file", summary: "no match",
        failure: "oldString not found", startedAt: started, arguments: #"old="x" path="a.py""#)
    continuation.finish()

    var published: [ToolResultMeta] = []
    for try await event in stream {
        if case .toolResult(let meta) = event.kind { published.append(meta) }
    }
    #expect(published.count == 2)
    #expect(published[0].id == "call-ok")
    #expect(published[0].failure == nil)
    #expect(published[0].arguments == nil, "success must not carry arguments")
    #expect(published[1].failure == "oldString not found")
    #expect(published[1].arguments == #"old="x" path="a.py""#)
    #expect(published[1].durationMs >= 25, "duration is measured, never declared")
}

@Test func wireOmitsArgsKeyOnSuccess() throws {
    let ok = OcoreaiToolRecord.from(
        ToolResultMeta(
            id: "1", name: "read_file", resultSummary: "3 lines", durationMs: 3,
            failure: nil))
    let bad = OcoreaiToolRecord.from(
        ToolResultMeta(
            id: "2", name: "edit_file", resultSummary: "no match", durationMs: 4,
            failure: "oldString not found", arguments: #"path="a.py""#))

    let okRow = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ok)) as? [String: Any]
    let badRow = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bad)) as? [String: Any]
    #expect(okRow?["args"] == nil, "a successful call must not publish args")
    #expect(badRow?["args"] as? String == #"path="a.py""#)
    #expect(badRow?["ok"] as? Bool == false)
}

// MARK: - Structural pin: the lanes cannot drift apart again

@Test func bothLanesPublishThroughTheOneHome() throws {
    let inference = try readSource("Sources/ocoreai/Engine/EngineInference.swift")
    let events = try readSource("Sources/ocoreai/Engine/EngineEvents.swift")

    // One construction of the meta in all of Sources — inside the publisher.
    #expect(occurrences(of: "ToolResultMeta(", in: inference) == 0)
    #expect(occurrences(of: "ToolResultMeta(", in: events) == 1)
    // Exactly two publishers: the std lane and the MTP lane. A third lane that forgets to publish
    // (or a lane that starts building its own meta) trips this.
    #expect(occurrences(of: "ToolResultPublisher.emit(", in: inference) == 2)
    // The handoff marker is decided once, so no lane can sniff a private literal of its own.
    #expect(occurrences(of: "\"[tool_handoff:", in: inference) == 0)
    #expect(occurrences(of: "\"[tool_handoff:", in: events) == 1)
    // The MTP branch must be the handoff guard, not an unconditional publish.
    #expect(inference.contains("if !ToolResultMeta.isCallerHandoff(result) {"))
}
