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
        return MCPServer(registry: registry, transport: MCPStdioTransport(),
                        log: Logger(label: "test.mcpserver.rpc"))
    }

    private func json(_ s: String?) -> [String: Any]? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// JSON-RPC §4.1: the responder returns the *same* identifier, so a number in must not come
    /// back as a string — clients match on it.
    @Test("numeric id is accepted and echoed as a number")
    func numericIdRoundTrips() async {
        let server = await makeServer()
        let out = json(await server.dispatch(
            #"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{}}"#))
        #expect(out?["error"] == nil, "spec-legal numeric id was refused: \(String(describing: out?["error"]))")
        #expect(out?["jsonrpc"] as? String == "2.0")
        let id = out?["id"]
        #expect(id is Int || id is Double, "id came back as \(type(of: id as Any)) — must stay a number")
        // Compare as a number: JSON carries no int/float distinction for a client, and the
        // requirement is "the same identifier, still numeric" — not a particular spelling.
        #expect((id as? NSNumber)?.intValue == 7, "id changed value on the way out: \(String(describing: id))")
    }

    @Test("string id still round-trips (no regression on the shape that used to work)")
    func stringIdRoundTrips() async {
        let server = await makeServer()
        let out = json(await server.dispatch(
            #"{"jsonrpc":"2.0","id":"abc","method":"ping","params":{}}"#))
        #expect(out?["error"] == nil)
        #expect(out?["id"] as? String == "abc")
    }

    @Test("params decode: tools/call with a real name executes instead of answering {}")
    func paramsActuallyDecode() async {
        let server = await makeServer()
        _ = await server.dispatch(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let out = json(await server.dispatch(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"probe_echo","arguments":{"text":"hi"}}}"#
        ))
        guard let result = out?["result"] as? [String: Any] else {
            Issue.record("no result: \(String(describing: out))")
            return
        }
        // The pre-fix answer was exactly `["result":{}]`: present, empty, and indistinguishable
        // from success. Anything that still looks like that fails here.
        let content = result["content"] as? [[String: Any]]
        #expect(content?.count ?? 0 > 0, "tools/call returned an empty result — params were dropped again")
        let text = content?.first?["text"] as? String ?? ""
        #expect(text.contains("hi"), "the arguments never reached the handler: \(text)")
        #expect(result["isError"] as? Bool == false)
    }

    @Test("a call without `name` is refused by name, not answered with an empty result")
    func missingNameIsNamedRefusal() async {
        let server = await makeServer()
        _ = await server.dispatch(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let out = json(await server.dispatch(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"arguments":{}}}"#))
        let err = out?["error"] as? [String: Any]
        #expect(err != nil, "malformed params must not look like success")
        #expect(err?["code"] as? Int == -32602, "expected -32602, got \(String(describing: err?["code"]))")
        #expect((err?["message"] as? String)?.contains("name") == true,
            "the refusal must name the field: \(String(describing: err?["message"]))")
    }

    @Test("tools/list describes the tools: properties, descriptions, required")
    func listPublishesRealSchemas() async {
        let server = await makeServer()
        _ = await server.dispatch(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let out = json(await server.dispatch(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#))
        guard let tools = (out?["result"] as? [String: Any])?["tools"] as? [[String: Any]],
            let tool = tools.first(where: { $0["name"] as? String == "probe_echo" })
        else {
            Issue.record("tools/list did not publish probe_echo: \(String(describing: out))")
            return
        }
        let schema = tool["inputSchema"] as? [String: Any]
        let props = schema?["properties"] as? [String: Any]
        #expect(props?.count == 2, "inputSchema.properties=\(String(describing: props)) — 参数面被抹平就是这份")
        let text = props?["text"] as? [String: Any]
        #expect(text?["type"] as? String == "string")
        #expect((text?["description"] as? String)?.contains("echo") == true, "description dropped")
        #expect(schema?["required"] as? [String] == ["text"], "required: \(String(describing: schema?["required"]))")
        #expect((tool["description"] as? String)?.isEmpty == false, "tool-level description dropped")
    }

    @Test("before initialize the answer says so, instead of returning an empty list")
    func uninitializedIsStated() async {
        let server = await makeServer()
        let out = json(await server.dispatch(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#))
        let err = out?["error"] as? [String: Any]
        #expect(err != nil, "an empty tools/list reads as \"this server has no tools\"")
        #expect((err?["message"] as? String)?.lowercased().contains("initialize") == true,
            "the refusal should name the missing step: \(String(describing: err?["message"]))")
    }
}
