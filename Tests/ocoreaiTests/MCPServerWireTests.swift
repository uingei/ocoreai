// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// The `/mcp` surface, measured against the two specs it claims (JSON-RPC 2.0 + MCP
/// v2025-06-18). Everything here was a live failure on this host at HEAD, obtained by booting
/// `serve` and posting spec-legal requests — not inferred:
///   • `{"jsonrpc":"2.0","id":1,...}` → `-32700 Parse error`. `id` was typed `String?`, and the
///     synthesized Decodable therefore *required* a string, while §4.1 allows String, Number or
///     Null. The Python/TypeScript MCP SDKs send integers, so a standard client could not complete
///     a single handshake with a surface the endpoint catalog advertises.
///   • `params` had no CodingKey (`paramsData` matched nothing on the wire), so every request
///     arrived with params == nil and `tools/call` answered `{"result":{}}` — success-shaped,
///     empty, indistinguishable from "the tool ran and returned nothing".
///   • `tools/list` published `{"inputSchema":{"properties":{}}}` for all 39 tools: every tool
///     described as taking no arguments, descriptions dropped.
///
/// These are the invariant-2 direction: the surface advertised more than it delivered, and did it
/// silently. The gate therefore checks the *answer*, not the struct.
import Foundation
import Logging
import Testing

@testable import ocoreai

@Suite("MCPServer wire: spec-legal requests get answers, and refusals name the field")
struct MCPServerWireTests {

    private func makeServer() async -> MCPServer {
        let registry = ToolRegistry(log: Logger(label: "test.mcpserver"))
        try? await registry.register(
            ToolEntry(
                name: "probe_echo", toolset: "test",
                schema: ToolSchema(
                    parameters: [
                        "text": ToolParameter(type: .string, description: "Text to echo back"),
                        "shout": ToolParameter(type: .boolean, description: "Uppercase it"),
                    ], required: ["text"]),
                handler: { args in
                    let dict =
                        (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any]
                    return "echo:\(dict?["text"] as? String ?? "nil")"
                }))
        return MCPServer(
            registry: registry, transport: MCPStdioTransport(),
            log: Logger(label: "test.mcpserver.rpc"))
    }

    /// JSON-RPC §4.1: the responder returns the *same* identifier, so a number in must not come
    /// back as a string — clients match on it.
    @Test("numeric id is accepted and echoed as a number")
    func numericIdRoundTrips() async {
        let server = await makeServer()
        let out = json(
            await server.dispatch(
                #"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{}}"#))
        #expect(
            out?["error"] == nil,
            "spec-legal numeric id was refused: \(String(describing: out?["error"]))")
        #expect(out?["jsonrpc"] as? String == "2.0")
        let id = out?["id"]
        #expect(
            id is Int || id is Double, "id came back as \(type(of: id as Any)) — must stay a number"
        )
        // Compare as a number: JSON carries no int/float distinction for a client, and the
        // requirement is "the same identifier, still numeric" — not a particular spelling.
        #expect(
            (id as? NSNumber)?.intValue == 7,
            "id changed value on the way out: \(String(describing: id))")
    }

    @Test("string id still round-trips (no regression on the shape that used to work)")
    func stringIdRoundTrips() async {
        let server = await makeServer()
        let out = json(
            await server.dispatch(
                #"{"jsonrpc":"2.0","id":"abc","method":"ping","params":{}}"#))
        #expect(out?["error"] == nil)
        #expect(out?["id"] as? String == "abc")
    }

    @Test("params decode: tools/call with a real name executes instead of answering {}")
    func paramsActuallyDecode() async {
        let server = await makeServer()
        _ = await server.dispatch(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let out = json(
            await server.dispatch(
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"probe_echo","arguments":{"text":"hi"}}}"#
            ))
        guard let result = out?["result"] as? [String: Any] else {
            Issue.record("no result: \(String(describing: out))")
            return
        }
        // The pre-fix answer was exactly `["result":{}]`: present, empty, and indistinguishable
        // from success. Anything that still looks like that fails here.
        let content = result["content"] as? [[String: Any]]
        #expect(
            content?.count ?? 0 > 0,
            "tools/call returned an empty result — params were dropped again")
        let text = content?.first?["text"] as? String ?? ""
        #expect(text.contains("hi"), "the arguments never reached the handler: \(text)")
        #expect(result["isError"] as? Bool == false)
    }

    @Test("a call without `name` is refused by name, not answered with an empty result")
    func missingNameIsNamedRefusal() async {
        let server = await makeServer()
        _ = await server.dispatch(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let out = json(
            await server.dispatch(
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"arguments":{}}}"#))
        let err = out?["error"] as? [String: Any]
        #expect(err != nil, "malformed params must not look like success")
        #expect(
            err?["code"] as? Int == -32602,
            "expected -32602, got \(String(describing: err?["code"]))")
        #expect(
            (err?["message"] as? String)?.contains("name") == true,
            "the refusal must name the field: \(String(describing: err?["message"]))")
    }

    @Test("tools/list describes the tools: properties, descriptions, required")
    func listPublishesRealSchemas() async {
        let server = await makeServer()
        _ = await server.dispatch(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let out = json(
            await server.dispatch(
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#))
        guard let tools = (out?["result"] as? [String: Any])?["tools"] as? [[String: Any]],
            let tool = tools.first(where: { $0["name"] as? String == "probe_echo" })
        else {
            Issue.record("tools/list did not publish probe_echo: \(String(describing: out))")
            return
        }
        let schema = tool["inputSchema"] as? [String: Any]
        let props = schema?["properties"] as? [String: Any]
        #expect(
            props?.count == 2, "inputSchema.properties=\(String(describing: props)) — 参数面被抹平就是这份")
        let text = props?["text"] as? [String: Any]
        #expect(text?["type"] as? String == "string")
        #expect((text?["description"] as? String)?.contains("echo") == true, "description dropped")
        #expect(
            schema?["required"] as? [String] == ["text"],
            "required: \(String(describing: schema?["required"]))")
        #expect(
            (tool["description"] as? String)?.isEmpty == false, "tool-level description dropped")
    }

    @Test("before initialize the answer says so, instead of returning an empty list")
    func uninitializedIsStated() async {
        let server = await makeServer()
        let out = json(
            await server.dispatch(
                #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#))
        let err = out?["error"] as? [String: Any]
        #expect(err != nil, "an empty tools/list reads as \"this server has no tools\"")
        #expect(
            (err?["message"] as? String)?.lowercased().contains("initialize") == true,
            "the refusal should name the missing step: \(String(describing: err?["message"]))")
    }
}

/// A JSON-RPC answer is only a verdict once it is read: the assertion is on the *body* the client
/// gets, not on the struct that produced it. Shared by both suites in this file.
private func json(_ s: String?) -> [String: Any]? {
    guard let s, let d = s.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
}

// MARK: - 通道声明：答不了审批的面，不许把请求挂到 broker 上

/// 实测（10-31，真 `serve` + `curl`，默认 `interactive` 策略）：`POST /mcp` 上
/// `tools/call write_file` 十二秒不返回（`curl -m 12` → status=000），文件也没写。原因不在工具，
/// 在通道没报自己：`.ask` 一路 park 到 `ApprovalBroker`，等的是本机 GUI 的一张审批卡，而 wire
/// 消费者永远拿不到答案。chat/completions/anthropic 三条线都传 `headless: true` 并在门上
/// fail-closed 拒绝（codex `codex-rs/exec/src/lib.rs:566`），这条线漏了。
///
/// 修复只把「这条通道能不能有人答」从入口带到门上，所以两条面都得可证：wire 面即刻拒绝且
/// broker 空行；bridge 自己的本地派发仍然挂起等人裁决 —— 一刀切关掉审批是把一个 bug 换成另一个。
/// 挂住的 dispatch 会把裸 `await` 一起挂住，因此响应经有界读取：park 必须是红色，不是挂死。
@Suite("MCPServer wire: a channel that cannot answer must not park on the broker")
struct MCPServerHeadlessGateTests {

    /// 被执行的次数。拒绝的判据是「没跑」，不是抄来的原因串。
    private actor Runs {
        private(set) var count = 0
        func add() { count += 1 }
    }

    private actor ResponseBox {
        private(set) var value: String?
        func store(_ s: String?) { value = s }
    }

    private let callWrite =
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"gate_write","arguments":{}}}"#

    private func makeServer() async -> (server: MCPServer, broker: ApprovalBroker, runs: Runs) {
        let runs = Runs()
        let broker = ApprovalBroker(policy: .interactive)
        let registry = ToolRegistry(
            approvalBroker: broker, log: Logger(label: "test.mcpserver.gate"))
        try? await registry.register(
            ToolEntry(
                name: "gate_write", toolset: "test", schema: ToolSchema(),
                handler: { (_: String) async throws -> String in
                    await runs.add()
                    return "wrote"
                },
                isDestructive: true))
        try? await registry.register(
            ToolEntry(
                name: "gate_read", toolset: "test", schema: ToolSchema(),
                handler: { _ in "read" }))
        let server = MCPServer(
            registry: registry, transport: MCPStdioTransport(),
            log: Logger(label: "test.mcpserver.gate"))
        // 除 initialize 外的方法都要求握手（同一文件上面的既有门）。
        _ = await server.dispatch(#"{"jsonrpc":"2.0","id":0,"method":"initialize"}"#)
        return (server, broker, runs)
    }

    /// 有界取响应：400 × 2 ms 没等到就报 nil —— 那正是修复前的形态。
    private func respond(
        _ server: MCPServer, _ line: String, headless: Bool
    ) async -> String? {
        let box = ResponseBox()
        let work = Task { await box.store(await server.dispatch(line, headless: headless)) }
        for _ in 0 ..< 400 {
            if let seen = await box.value { return seen }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        work.cancel()
        return await box.value
    }

    @Test("wire lane: destructive call is refused at the gate, broker never sees a row")
    func wireRefusesWithoutParking() async throws {
        let (server, broker, runs) = await makeServer()
        let body = json(
            await respond(server, callWrite, headless: true))
        guard let body else {
            #expect(Bool(false), "the wire lane parked: no response inside the bounded window")
            return
        }
        let result = body["result"] as? [String: Any]
        #expect(
            result?["isError"] as? Bool == true,
            "a refusal must arrive as an MCP error result, got \(body)")
        let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        #expect(
            text.contains("headless"),
            "the refusal must name the channel that caused it, got \"\(text)\"")
        #expect(await runs.count == 0, "a refused destructive tool still executed")
        #expect(
            await broker.snapshot().isEmpty,
            "the wire lane parked a prompt nobody on that channel can answer")
    }

    @Test("non-destructive tool over the same wire lane is untouched (no over-fire)")
    func wireStillRunsSafeTool() async throws {
        let (server, broker, _) = await makeServer()
        let body = json(
            await respond(
                server,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"gate_read","arguments":{}}}"#,
                headless: true))
        let result = body?["result"] as? [String: Any]
        #expect(result?["isError"] as? Bool == false, "a safe tool was refused: \(body ?? [:])")
        #expect(
            (result?["content"] as? [[String: Any]])?.first?["text"] as? String == "read",
            "the safe tool did not run")
        #expect(await broker.snapshot().isEmpty)
    }

    @Test("the bridge's own lane still asks a person: row published, approve runs the tool")
    func presentingLaneStillAsks() async throws {
        let (server, broker, runs) = await makeServer()
        let box = ResponseBox()
        let work = Task { await box.store(await server.dispatch(self.callWrite)) }
        var row: PendingApproval?
        for _ in 0 ..< 400 {
            if let first = await broker.snapshot().first {
                row = first
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        guard let row else {
            #expect(
                Bool(false), "the presenting lane never asked — approval was disabled, not threaded"
            )
            return
        }
        #expect(await broker.resolve(id: row.id, decision: .approved))
        for _ in 0 ..< 400 {
            if await box.value != nil { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let result = json(await box.value)?["result"] as? [String: Any]
        let ran = await runs.count
        if result?["isError"] as? Bool != false {
            work.cancel()
        }
        #expect(result?["isError"] as? Bool == false, "an approved call did not run")
        #expect(ran == 1, "the approved tool ran \(ran) times")
    }
}
