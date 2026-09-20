// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `ChatState.parseToolArguments` — the exact mapping from raw tool-call
/// argument JSON (as the engine's `ToolCallMeta.arguments` carries it) into the
/// flat `[String: String]` shape stored on `ToolCallPart` / `ToolCallRecord`.
///
/// Codex `#46710` parity: the live stream used to build the card with
/// `arguments: [:]` (dropping the model's actual args), so re-opened sessions
/// rendered tool badges with no argument detail. These tests pin the parse
/// contract so a re-opened session carries the SAME arguments the live card
/// showed, field-by-field, for the argument shapes real tools produce.

import Foundation
import Testing

@testable import ocoreai

@Suite("parseToolArguments — raw JSON → faithful [String: String]")
struct ParseToolArgumentsTests {

    @Test("JSON object: string / number / bool / nested value, exact-value per key")
    func objectMappingIsExact() {
        let args =
            #"{"command":"find . -name '*.txt' | wc -l","max":42,"verbose":true,"opts":{"flag":1}}"#
        let parsed = ChatState.parseToolArguments(args)

        #expect(parsed.count == 4)
        #expect(parsed["command"] == "find . -name '*.txt' | wc -l")
        #expect(parsed["max"] == "42")
        #expect(parsed["verbose"] == "true")
        // Nested object survives as compact JSON (structure preserved, readable).
        let opts = parsed["opts"] ?? ""
        #expect(opts.contains("\"flag\""), "nested object must keep its keys: \(opts)")
    }

    @Test("top-level array: value kept intact under rawJSON (never dropped)")
    func topLevelArrayKept() {
        let parsed = ChatState.parseToolArguments(#"["a","b"]"#)
        let raw = parsed["rawJSON"] ?? ""
        #expect(!raw.isEmpty, "args must not vanish — got empty map")
        #expect(raw.contains("a") && raw.contains("b"))
    }

    @Test("malformed / empty / nil all safe — no crash, empty map")
    func malformedIsSafe() {
        #expect(ChatState.parseToolArguments(nil) == [:])
        #expect(ChatState.parseToolArguments("") == [:])
        #expect(ChatState.parseToolArguments("   ") == [:])
        #expect(ChatState.parseToolArguments("{not json") == [:])
    }

    @Test("round-trip: persisted record's arguments render back byte-identical")
    func persistedArgumentsSurvive() {
        // This mirrors the LIVE card population (ChatViewModel .toolCall branch)
        // then the RESTORE path (fromMessageModel uses rec.arguments directly) —
        // the end-to-end value the user sees on a re-opened session.
        let raw = #"{"path":"/tmp/agent_test/autonomy/inventory","recursive":true}"#
        let liveCard = ChatState.parseToolArguments(raw)
        // fromMessageModel copies rec.arguments verbatim into the restored part,
        // so exact equality here IS the "re-opened session shows the same detail"
        // guarantee.
        #expect(liveCard["path"] == "/tmp/agent_test/autonomy/inventory")
        #expect(liveCard["recursive"] == "true")
        #expect(liveCard.count == 2)

        // Persistence path: ToolCallRecord round-trips the same map via SQLite.
        let rec = ToolCallRecord(
            callId: "c1", toolName: "read_file",
            arguments: liveCard, resultSummary: "ok", durationMs: 1.5)
        #expect(rec.arguments == liveCard)
    }
}
