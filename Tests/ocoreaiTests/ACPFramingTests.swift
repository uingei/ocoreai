// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// ACPFramingTests. The pure half of the Agent Client Protocol face: the token table that decides
// `ocoreai acp`, the newline-delimited codec, and the stop-reason table. The live half (a real
// subprocess answering initialize and streaming a turn) is scripts/probes/62-acp-stdio.sh, because
// stdout purity is a property of the running process, not of this file.
//
// Exact values throughout, and every rejection is asserted by the code and the word it names:
// a client that gets a bare -32602 cannot fix its request.
import Foundation
import Testing

@testable import ocoreai

struct ACPModeTests {

    @Test("acp alone runs; a help token answers; anything else is refused before boot")
    func tokenTable() {
        let run = ACPMode.request(for: ["ocoreai", "acp"])
        #expect(run == .run)
        #expect(
            ACPMode.request(for: ["/Applications/ocoreai.app/Contents/MacOS/ocoreai", "acp"])
                == .run)
        for token in ["--help", "-h", "help"] {
            let asked = ACPMode.request(for: ["ocoreai", "acp", token])
            #expect(asked == .help, "token \(token) must print usage, not boot an agent")
        }
        let refused = ACPMode.request(for: ["ocoreai", "acp", "--port", "9090"])
        #expect(refused == .refused(unrecognized: ["--port", "9090"]))
    }

    @Test("a leading flag never skips past to acp, and another subcommand is not ours")
    func otherInvocationsUnchanged() {
        #expect(ACPMode.request(for: ["ocoreai", "--help", "acp"]) == .notACP)
        #expect(ACPMode.request(for: ["ocoreai", "serve"]) == .notACP)
        #expect(ACPMode.request(for: ["ocoreai"]) == .notACP)
        // A near-miss token is the GUI branch, unchanged, exactly as `serve` rules it.
        #expect(ACPMode.request(for: ["ocoreai", "acp2"]) == .notACP)
    }

    @Test("usage names the version spoken and the registry limit, without over-promising")
    func usageTextHonest() {
        let usage = ACPMode.usageText()
        #expect(usage.contains("session/prompt"))
        #expect(usage.contains("Registry"))
        #expect(!usage.contains("session/load: supported"))
    }
}

/// Decodes one outgoing line back to a dictionary, so an assertion reads as the wire the client
/// parses rather than as a Swift object graph.
private func jsonObject(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

struct ACPFramingTests {

    // MARK: Read side

    @Test("a request line decodes its id, method and params together")
    func decodeRequest() {
        let line = #"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":1}}"#
        let decoded = ACPFraming.decode(line: line)
        guard case .success(let message) = decoded else {
            Issue.record("expected success, got \(decoded)")
            return
        }
        #expect(message.id == .number(7))
        #expect(message.method == "initialize")
        let params = message.params(as: ACPInitializeParams.self)
        #expect(params?.protocolVersion == 1)
    }

    @Test("a text id stays text, and a notification carries no id")
    func idKinds() {
        let text = #"{"jsonrpc":"2.0","id":"abc","method":"session/new","params":{}}"#
        let decodedText = ACPFraming.decode(line: text)
        guard case .success(let message) = decodedText else {
            Issue.record("a text id must decode")
            return
        }
        #expect(message.id == .text("abc"))

        let notice = #"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s"}}"#
        let decodedNotice = ACPFraming.decode(line: notice)
        guard case .success(let cancel) = decodedNotice else {
            Issue.record("a notification must decode")
            return
        }
        #expect(cancel.id == nil)
        #expect(cancel.method == "session/cancel")
    }

    @Test("four unreadable shapes are named, never dropped")
    func unreadable() {
        #expect(ACPFraming.decode(line: "not json") == .failure(.notJSON))
        #expect(ACPFraming.decode(line: "") == .failure(.notJSON))
        #expect(ACPFraming.decode(line: "[1,2]") == .failure(.notAnObject))
        #expect(ACPFraming.decode(line: #"{"jsonrpc":"2.0","id":1}"#) == .failure(.missingMethod))
        // An id we cannot echo back is a response the client can never match.
        #expect(
            ACPFraming.decode(line: #"{"jsonrpc":"2.0","id":true,"method":"x"}"#)
                == .failure(
                    .unsupportedID))
    }

    @Test("lines split on the first newline, and a partial message waits for the rest")
    func framing() {
        var buffer = Data(#"{"a":1}"#.utf8)
        #expect(ACPFraming.completeLine(from: &buffer) == nil)
        #expect(String(data: buffer, encoding: .utf8) == #"{"a":1}"#)

        buffer.append(Data("\n{\"b\":2}\n{\"c\":3".utf8))
        // One call, one message: a line-by-line reader must never see two at once.
        #expect(ACPFraming.completeLine(from: &buffer) == #"{"a":1}"#)
        #expect(ACPFraming.completeLine(from: &buffer) == #"{"b":2}"#)
        #expect(ACPFraming.completeLine(from: &buffer) == nil)

        var crlf = Data("{}\r\n".utf8)
        #expect(ACPFraming.completeLine(from: &crlf) == "{}")
    }

    @Test("a line answering our own request is told apart from a method call")
    func responseVersusRequest() {
        let response =
            #"{"jsonrpc":"2.0","id":9,"result":{"outcome":{"outcome":"selected","optionId":"allow-once"}}}"#
        let decoded = ACPFraming.decodeResponse(line: response)
        #expect(decoded?.id == .number(9))
        let payload = decoded?.resultJSON.flatMap {
            try? JSONDecoder().decode(ACPPermissionResult.self, from: $0)
        }
        #expect(payload?.outcome.outcome == "selected")
        #expect(payload?.outcome.optionId == "allow-once")

        let error = #"{"jsonrpc":"2.0","id":9,"error":{"code":-32603,"message":"nope"}}"#
        #expect(ACPFraming.decodeResponse(line: error)?.errorCode == -32603)

        let request = #"{"jsonrpc":"2.0","id":9,"method":"initialize","params":{}}"#
        #expect(ACPFraming.decodeResponse(line: request) == nil)
    }

    // MARK: Write side

    @Test("every outgoing line is one JSON object terminated by exactly one newline")
    func outgoingLines() {
        let result = ACPFraming.response(
            id: .number(1), result: ACPNewSessionResult(sessionId: "acp-1"))
        let text = String(data: result, encoding: .utf8) ?? ""
        #expect(text.hasSuffix("}\n"))
        #expect(text.filter { $0 == "\n" }.count == 1)
        let object = jsonObject(result)
        #expect(object?["jsonrpc"] as? String == "2.0")
        #expect(object?["id"] as? Int == 1)
        let body = object?["result"] as? [String: Any]
        #expect(body?["sessionId"] as? String == "acp-1")

        let notice = ACPFraming.notification(
            method: "session/update",
            params: ["sessionId": "s", "update": ["sessionUpdate": "agent_message_chunk"]])
        let noticeObject = jsonObject(notice)
        #expect(noticeObject?["method"] as? String == "session/update")
        #expect(noticeObject?["id"] == nil)

        let failure = ACPFraming.error(id: nil, code: -32700, message: "unreadable")
        let failureObject = jsonObject(failure)
        #expect(failureObject?["id"] is NSNull)
        let errorBody = failureObject?["error"] as? [String: Any]
        #expect(errorBody?["code"] as? Int == -32700)
        #expect(errorBody?["message"] as? String == "unreadable")
    }

    @Test("the initialize result carries the promises this build can keep")
    func initializeResultShape() {
        let payload = ACPInitializeResult(
            protocolVersion: ACPMode.protocolVersion,
            agentCapabilities: ACPAgentCapabilities(
                loadSession: false,
                promptCapabilities: ACPPromptCapabilities(
                    image: false, audio: false, embeddedContext: true)),
            agentInfo: ACPImplementation(name: "ocoreai", title: "ocoreai", version: "9.9.9"),
            authMethods: [])
        let line = ACPFraming.response(id: .number(0), result: payload)
        let result = jsonObject(line)?["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? Int == 1)
        #expect(result?["authMethods"] as? [String] == [])
        let caps = result?["agentCapabilities"] as? [String: Any]
        #expect(caps?["loadSession"] as? Bool == false)
        let prompts = caps?["promptCapabilities"] as? [String: Any]
        #expect(prompts?["image"] as? Bool == false)
        #expect(prompts?["audio"] as? Bool == false)
        #expect(prompts?["embeddedContext"] as? Bool == true)
    }
}

struct ACPStopReasonTests {

    /// Our lane says `stop | length | cancelled | error`; ACP says five other words. A turn that
    /// reported an error is answered as a JSON-RPC error, so `error` never reaches this table.
    @Test(arguments: [
        ("stop", false, "end_turn"),
        ("length", false, "max_tokens"),
        ("cancelled", false, "cancelled"),
        ("stop", true, "cancelled"),
        ("length", true, "cancelled"),
        ("anything-unseen", false, "end_turn"),
    ])
    func table(ours: String, cancelled: Bool, expected: String) {
        let mapped = ACPStopReason.map(ours, cancelled: cancelled)
        #expect(mapped == expected)
    }
}
