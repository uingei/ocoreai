// Copyright © 2026 uingei.
// Licensed under MIT.
/// ToolHistoryPairingTests.swift. The request-boundary pairing walk, both wire faces,
/// pinned to the shape sglang ships (`serving_chat.py:300-330`, read at reference HEAD
/// 11-16): a result must answer a call of the run opened immediately before it, nothing
/// may cut into an unanswered run, and a run left open at the END is legal, that is the
/// "answer this call" request, and sglang's own walker allows it.
///
/// Why the stakes: unpaired tool traffic was measured live 11-16 answering HTTP 200 on
/// this server while the prompt silently dropped the result (orphan) or labelled it
/// `unknown` (mismatch). A 200 over lost content. The walk runs on each face's RAW
/// request DTO before any conversion, so the Anthropic face is checked before its
/// converter folds a `tool_result` back to text and the break disappears.
///
/// Fixtures are wire JSON, not hand-built DTOs: the decode path is part of what breaks.

import Foundation
import Testing

@testable import ocoreai

// ── OpenAI-face wire fixtures ────────────────────────────────────────────────

/// `[...]` from already-serialised entries.
private func hist(_ entries: String...) -> String {
    "[" + entries.joined(separator: ",") + "]"
}

private func msg(_ role: String, _ content: String) -> String {
    #"{"role":"\#(role)","content":"\#(content)"}"#
}

/// An assistant turn declaring exactly these call ids.
private func asst(_ ids: [String]) -> String {
    let objects = ids.map {
        #"{"id":"\#($0)","type":"function","function":{"name":"f","arguments":"{}"}}"#
    }.joined(separator: ",")
    return #"{"role":"assistant","tool_calls":["# + objects + "]}"
}

private func tool(_ id: String) -> String {
    #"{"role":"tool","tool_call_id":"\#(id)","content":"result-\#(id)"}"#
}

private let toolNoID = #"{"role":"tool","content":"result-x"}"#

// ── Anthropic-face wire fixtures (written inline; block JSON is its own shape) ──

/// One expectation: wire history, and the violation it must produce (`nil` = accepted).
private struct PairingCase: Sendable {
    let name: String
    let json: String
    let expected: ToolHistory.Violation.Kind?
    /// Index the refusal must name, when there is a violation.
    let at: Int?
}

private func expect(_ c: PairingCase, found: ToolHistory.Violation?) throws {
    switch c.expected {
    case .none:
        #expect(found == nil, "\(c.name): expected acceptance, got \(String(describing: found))")
    case .some(let kind):
        let violation = try #require(found, "\(c.name): expected \(kind), got acceptance")
        #expect(violation.kind == kind, "\(c.name): wrong kind \(violation.kind)")
        #expect(violation.messageIndex == c.at, "\(c.name): wrong index \(violation.messageIndex)")
    }
}

private let ORPHANED = ToolHistory.Violation.Kind.orphaned
private let MISMATCHED = ToolHistory.Violation.Kind.mismatched
private let UNANSWERED = ToolHistory.Violation.Kind.unanswered

struct ToolHistoryPairingTests {

    fileprivate static let openAITable: [PairingCase] = [
        PairingCase(
            name: "orphan: result with no open run",
            json: hist(msg("user", "hi"), tool("a")),
            expected: ORPHANED, at: 1),
        PairingCase(
            name: "mismatch: id answers no open call",
            json: hist(msg("user", "hi"), asst(["a"]), tool("b")),
            expected: MISMATCHED, at: 2),
        PairingCase(
            name: "unanswered: user message cuts into the run",
            json: hist(asst(["a"]), msg("user", "now what")),
            expected: UNANSWERED, at: 1),
        PairingCase(
            name: "unanswered: a second run cuts off the first",
            json: hist(asst(["a"]), asst(["b"]), tool("b")),
            expected: UNANSWERED, at: 1),
        PairingCase(
            name: "trailing unanswered is legal (answer-this-call shape)",
            json: hist(msg("user", "hi"), asst(["a"])),
            expected: nil, at: nil),
        PairingCase(
            name: "clean multi-call loop",
            json: hist(
                msg("user", "hi"), asst(["a", "b"]), tool("a"), tool("b"), msg("user", "thanks")),
            expected: nil, at: nil),
        PairingCase(
            name: "answers out of call order are fine",
            json: hist(asst(["a", "b"]), tool("b"), tool("a"), msg("user", "ok")),
            expected: nil, at: nil),
        PairingCase(
            name: "duplicate result mismatches",
            json: hist(asst(["a"]), tool("a"), tool("a")),
            expected: MISMATCHED, at: 2),
        PairingCase(
            name: "new run after a drained run is fine",
            json: hist(asst(["a"]), tool("a"), asst(["b"]), tool("b")),
            expected: nil, at: nil),
        PairingCase(
            name: "result without an id cannot answer",
            json: hist(asst(["a"]), toolNoID),
            expected: MISMATCHED, at: 1),
    ]

    @Test("OpenAI-face pairing table")
    func openAIFace() throws {
        // Floor the traversal itself (AGENTS.md § Testing Quality): a table that lost
        // rows through a bad merge would otherwise pass every assertion vacuously.
        #expect(Self.openAITable.count >= 10, "table lost rows: \(Self.openAITable.count)")
        for c in Self.openAITable {
            let messages = try JSONDecoder().decode([Message].self, from: Data(c.json.utf8))
            try expect(c, found: ToolHistory.pairingViolation(in: messages))
        }
    }

    fileprivate static let anthropicTable: [PairingCase] = [
        PairingCase(
            name: "clean use/result pair",
            json:
                #"[{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"w","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}]"#,
            expected: nil, at: nil),
        PairingCase(
            name: "multi use answered in one result message",
            json:
                #"[{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"w","input":{}},{"type":"tool_use","id":"t2","name":"w","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a"},{"type":"tool_result","tool_use_id":"t2","content":"b"}]}]"#,
            expected: nil, at: nil),
        PairingCase(
            name: "orphan result",
            json:
                #"[{"role":"user","content":[{"type":"tool_result","tool_use_id":"tx","content":"x"}]}]"#,
            expected: ORPHANED, at: 0),
        PairingCase(
            name: "result against an undeclared id",
            json:
                #"[{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"w","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"x"}]}]"#,
            expected: MISMATCHED, at: 1),
        PairingCase(
            name: "prose cuts into an unanswered run",
            json:
                #"[{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"w","input":{}}]},{"role":"user","content":[{"type":"text","text":"hello?"}]}]"#,
            expected: UNANSWERED, at: 1),
        PairingCase(
            name: "partially answered run then prose",
            json:
                #"[{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"w","input":{}},{"type":"tool_use","id":"t2","name":"w","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a"}]},{"role":"user","content":[{"type":"text","text":"and?"}]}]"#,
            expected: UNANSWERED, at: 2),
        PairingCase(
            name: "trailing tool_use is legal",
            json:
                #"[{"role":"user","content":"weather?"},{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"w","input":{}}]}]"#,
            expected: nil, at: nil),
        PairingCase(
            name: "result without tool_use_id cannot answer",
            json:
                #"[{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"w","input":{}}]},{"role":"user","content":[{"type":"tool_result","content":"x"}]}]"#,
            expected: MISMATCHED, at: 1),
        PairingCase(
            name: "an id-less tool_use declares nothing to answer",
            json:
                #"[{"role":"assistant","content":[{"type":"tool_use","name":"w","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"tx","content":"x"}]}]"#,
            expected: ORPHANED, at: 1),
    ]

    @Test("Anthropic-face pairing table")
    func anthropicFace() throws {
        #expect(Self.anthropicTable.count >= 9, "table lost rows: \(Self.anthropicTable.count)")
        for c in Self.anthropicTable {
            let messages = try JSONDecoder().decode(
                [AnthropicMessage].self, from: Data(c.json.utf8))
            try expect(c, found: ToolHistory.pairingViolation(in: messages))
        }
    }
}
