// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// ACPFramingTests. The pure half of the Agent Client Protocol face: the token table that decides
// `ocoreai acp`, the newline-delimited codec, the stop-reason table, the permission wire (ACP's
// agent→client methods are requests a client answers by echoing an id), and the initialize
// negotiation. The live half (a real subprocess answering initialize and streaming a turn) is
// scripts/probes/62-acp-stdio.sh, because stdout purity is a property of the running process,
// not of this file.
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

/// The permission wire: ACP's `session/request_permission` is a REQUEST — a client answers only
/// a message carrying an id, echoing that id back (v1 tool-calls doc; `RequestPermissionResponse`
/// in the v1 schema). A notification would park the tool call with nothing to answer it.
struct ACPPermissionWireTests {

    @Test("the permission request carries the id, the option kinds, and its echo decodes")
    func permissionRequestIsAnswerable() throws {
        let row = PendingApproval(
            toolName: "write_file", arguments: "{\"path\":\"x\"}", snippet: "x",
            reason: "destructive tool call")
        let params = ACPAgent.permissionRequestParams(sessionId: "acp-1", row: row)
        let lineData = ACPFraming.request(
            id: .number(100_000), method: "session/request_permission", params: params)
        let text = try #require(String(data: lineData, encoding: .utf8))
        let object = try #require(jsonObject(lineData))
        #expect(object["id"] as? Int == 100_000)
        #expect(object["method"] as? String == "session/request_permission")
        let body = try #require(object["params"] as? [String: Any])
        #expect(body["sessionId"] as? String == "acp-1")
        let toolCall = try #require(body["toolCall"] as? [String: Any])
        #expect((toolCall["toolCallId"] as? String)?.isEmpty == false)
        let options = try #require(body["options"] as? [[String: Any]])
        #expect(
            options.map { $0["kind"] as? String } == ["allow_once", "allow_always", "reject_once"],
            "three of the schema's four PermissionOptionKind words, in offer order")
        // The line we send is a request: the client's answer shape never matches it.
        #expect(ACPFraming.decodeResponse(line: text) == nil)
        // Its echo decodes into exactly the outcome the agent maps to a broker decision.
        let echo =
            #"{"jsonrpc":"2.0","id":100000,"result":{"outcome":{"outcome":"selected","optionId":"allow-once"}}}"#
        let answer = try #require(ACPFraming.decodeResponse(line: echo))
        #expect(answer.id == .number(100_000))
        let decoded = try #require(
            answer.resultJSON.flatMap {
                try? JSONDecoder().decode(ACPPermissionResult.self, from: $0)
            })
        #expect(decoded.outcome.outcome == "selected")
        #expect(decoded.outcome.optionId == "allow-once")
    }

    /// The one link the codec round trip cannot reach: that the parked continuation is keyed by
    /// exactly the number written on the wire, and that no un-advertised `notice` update remains
    /// (v1 sends notices only to clients that advertised `session.notices`; this build reads none).
    @Test("the parked continuation is keyed by the wire id, and no notice update remains")
    func permissionIdBindingAndNoNotice() throws {
        let acp = try RepoSourceScan.source("Sources/ocoreai/ACP/ACPAgent.swift")
        // Floors: the seams exist before anything counts.
        #expect(acp.contains("func askClientAbout"))
        #expect(acp.contains("permissionContinuations[requestID] = continuation"))
        #expect(acp.contains("id: .number(requestID)"))
        #expect(try RepoSourceScan.count(#""session/request_permission""#, in: acp) == 1)
        #expect(!acp.contains(#""notice""#))
        let framing = try RepoSourceScan.source("Sources/ocoreai/ACP/ACPFraming.swift")
        #expect(try RepoSourceScan.count(#"static func request\("#, in: framing) == 1)
    }
}

/// v1 initialization is a negotiation: on a version we do not speak we MUST answer with the
/// latest one we support, and the client closes the connection itself (initialization doc).
/// Sessions stay closed until a handshake the client actually accepts arrives.
@MainActor
struct ACPNegotiationTests {

    /// Every agent write lands on the agent's own MainActor, so this box is actor-confined.
    @MainActor
    private final class Capture {
        var lines: [Data] = []
    }

    @Test("a foreign version gets our version as a result, sessions until an accepted handshake")
    func negotiation() throws {
        let capture = Capture()
        let agent = ACPAgent { capture.lines.append($0) }
        agent.becomeReady()
        agent.receive(
            #"{"jsonrpc":"2.0","id":6,"method":"initialize","params":{"protocolVersion":2}}"#)
        let answerLine = try #require(capture.lines.last)
        let answer = try #require(jsonObject(answerLine))
        #expect(answer["error"] == nil, "negotiation is answered, never refused")
        let result = try #require(answer["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? Int == ACPMode.protocolVersion)

        // A client that stays after a declined negotiation gets no session, and the refusal
        // names both versions so the editor can show why.
        agent.receive(
            #"{"jsonrpc":"2.0","id":7,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}"#
        )
        let refusedLine = try #require(capture.lines.last)
        let refused = try #require(jsonObject(refusedLine))
        let body = try #require(refused["error"] as? [String: Any])
        #expect(body["code"] as? Int == ACPFraming.invalidRequestCode)
        let words = try #require(body["message"] as? String)
        #expect(words.contains("session/new"))
        #expect(words.contains("protocolVersion 1"))
        #expect(words.contains("2"))

        // The accepted handshake answers, and a prompt for a session that was never opened is
        // refused by name, without ever touching the process-global workspace anchor.
        agent.receive(
            #"{"jsonrpc":"2.0","id":8,"method":"initialize","params":{"protocolVersion":1}}"#)
        let acceptedLine = try #require(capture.lines.last)
        let accepted = try #require(jsonObject(acceptedLine))
        #expect(accepted["error"] == nil)
        agent.receive(
            #"{"jsonrpc":"2.0","id":9,"method":"session/prompt","params":{"sessionId":"never-opened","prompt":[]}}"#
        )
        let orphanLine = try #require(capture.lines.last)
        let orphan = try #require(jsonObject(orphanLine))
        let orphanBody = try #require(orphan["error"] as? [String: Any])
        #expect(orphanBody["code"] as? Int == ACPFraming.invalidParamsCode)
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
