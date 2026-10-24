// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! Regression gate: a dispatched tool's measured outcome must reach the wire, on both
//! compatibility faces, in both stream and non-stream modes.
//!
//! Why this exists (AGENTS.md invariant 2 + § Endpoint Promises "accept-then-deliver needs an
//! executable delivery seam"): three handlers carried the comment "the wire already has the
//! `function_call_output` equivalent, no extra SSE field needed" while the native loop kept its
//! tool result entirely in-process. Measured live 10-24 on `mlx-community/gemma-4-e2b-it-4bit`:
//! a `/v1/chat/completions` turn whose `sleep` ran 9402 ms carried no tool record at all, and a
//! follow-up request in the same session answered "I do not have access to any previous tool
//! output" — so a client could neither see the dispatch nor re-send it. `ToolResultMeta` existed
//! and stopped at the GUI.
//!
//! What the field is *for*: `duration_ms` is the wall time measured around the real dispatch, so
//! a timing claim ("the wait ended early when input arrived") is verifiable without asking the
//! model to echo it. `scripts/probes/21-sleep-steer-wake.sh` reads it for exactly that.

import Foundation
import Testing

@testable import ocoreai

private func meta(
    _ id: String, _ name: String, _ summary: String, _ ms: Double, failure: String? = nil
) -> ToolResultMeta {
    ToolResultMeta(id: id, name: name, resultSummary: summary, durationMs: ms, failure: failure)
}

private func jsonObject(_ value: Encodable) -> [String: Any] {
    let data = try! JSONEncoder().encode(AnyEncodable(value))
    return (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
}

private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { _encode = wrapped.encode }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }
}

@Suite("ocoreai.tool_results: the measured tool outcome reaches the wire")
struct ToolResultWireDeliveryTests {
    @Test("a successful dispatch is ok:true with its measured duration, verbatim")
    func successCarriesMeasuredDuration() {
        let record = OcoreaiToolRecord.from(meta("c1", "sleep", "Wall time: 9.4024 seconds", 9402.5))
        #expect(record.id == "c1")
        #expect(record.name == "sleep")
        #expect(record.ok == true)
        #expect(record.durationMs == 9402.5)
        #expect(record.summary == "Wall time: 9.4024 seconds")
        #expect(record.failure == nil)
    }

    @Test("a denied or failed dispatch never looks like a success")
    func failureIsNeverSilent() {
        let record = OcoreaiToolRecord.from(
            meta("c2", "shell", "denied", 12.0, failure: "approval required"))
        #expect(record.ok == false)
        #expect(record.failure == "approval required")
        #expect(record.durationMs == 12.0)
    }

    @Test("the summary is redacted at the exit, not only on the model-facing copy")
    func summaryIsRedactedAtTheWire() {
        let secret = "sk-" + String(repeating: "a", count: 24)
        let record = OcoreaiToolRecord.from(meta("c3", "read_file", "key \(secret)", 3.0))
        #expect(record.summary.contains(secret) == false)
        #expect(record.summary.contains(SecretRedactor.redacted) == true)
    }

    @Test("OpenAI non-stream: snake_case keys under the ocoreai namespace")
    func openAIResponseEncodesSnakeCase() throws {
        let completion = ChatCompletion(
            id: "chatcmpl-x", created: 1, model: "m",
            choices: [
                CompletionChoice(message: AssistantMessage(content: "done"), finishReason: "stop")
            ],
            usage: Usage(input: 10, output: 2),
            ocoreai: OcoreaiTurn(toolResults: [
                OcoreaiToolRecord.from(meta("c1", "sleep", "Wall time: 1.0000 seconds", 1000.25))
            ]))
        let json = jsonObject(completion)
        let turn = try #require(json["ocoreai"] as? [String: Any])
        let results = try #require(turn["tool_results"] as? [[String: Any]])
        #expect(results.count == 1)
        #expect(results[0]["name"] as? String == "sleep")
        #expect(results[0]["ok"] as? Bool == true)
        #expect(results[0]["duration_ms"] as? Double == 1000.25)
        #expect(results[0]["durationMs"] == nil, "the extension keeps the snake_case house style")
    }

    @Test("absence means nothing was dispatched — on every face and both modes")
    func absentWhenNoToolRan() throws {
        #expect(jsonObject(
            ChatCompletionChunk(id: "c", created: 1, model: "m",
                choices: [ChunkChoice(delta: ChatDelta(content: "hi"), finishReason: nil)])
        )["ocoreai"] == nil)
        #expect(jsonObject(
            AnthropicStreamEvent.messageDelta(stopReason: "end_turn", outputTokens: 7)
        )["ocoreai"] == nil)
    }

    @Test("OpenAI stream and Anthropic stream each carry it on the terminal event")
    func streamFacesCarryIt() throws {
        let turn = OcoreaiTurn(toolResults: [
            OcoreaiToolRecord.from(meta("c9", "clock.sleep", "Sleep interrupted", 2458.0))
        ])
        let chunk = jsonObject(
            ChatCompletionChunk(id: "c", created: 1, model: "m",
                choices: [ChunkChoice(delta: ChatDelta(content: nil), finishReason: "stop")],
                ocoreai: turn))
        let chunkResults = try #require((chunk["ocoreai"] as? [String: Any])?["tool_results"] as? [[String: Any]])
        #expect(chunkResults[0]["duration_ms"] as? Double == 2458.0)
        #expect(chunkResults[0]["ok"] as? Bool == true)

        let delta = jsonObject(
            AnthropicStreamEvent.messageDelta(stopReason: "end_turn", outputTokens: 9, ocoreai: turn))
        #expect(delta["type"] as? String == "message_delta")
        let deltaResults = try #require((delta["ocoreai"] as? [String: Any])?["tool_results"] as? [[String: Any]])
        #expect(deltaResults[0]["name"] as? String == "clock.sleep")
    }

    /// The scan floors its own hit count (invariant 1): four assembly sites is the shipped
    /// contract — two faces x two modes. One fewer means a face lost its delivery seam while
    /// still being quoted as carrying it.
    @Test("four assembly sites exist, one per face per mode")
    func assemblySitesAreFour() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/", !FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("Package.swift").path)
        {
            dir = dir.deletingLastPathComponent()
        }
        let handlers = ["Sources/ocoreai/Handlers/ChatHandler.swift",
                        "Sources/ocoreai/Handlers/AnthropicMessagesHandler.swift"]
        var sites = 0
        var bindings = 0
        for relative in handlers {
            let url = dir.appendingPathComponent(relative)
            let text = try String(contentsOf: url, encoding: .utf8)
            sites += text.components(separatedBy: "OcoreaiTurn(toolResults:").count - 1
            bindings += text.components(separatedBy: "case .toolResult(let meta)").count - 1
        }
        #expect(sites == 4, "OpenAI stream + non-stream, Anthropic stream + non-stream")
        #expect(bindings == 4, "each of the four modes must bind the event it publishes")
    }
}
