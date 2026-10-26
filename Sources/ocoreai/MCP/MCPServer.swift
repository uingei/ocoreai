// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MCP Server — JSON-RPC 2.0 server exposing ToolRegistry tools.
/// Protocol: MCP v2025-06-18 (initialize, tools/list, tools/call, ping).
import Foundation
import Logging

/// Untyped JSON value wrapper.
private struct JVal: Codable {
    var value: Any
    init(_ v: Any) {
        value = v
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            value = b
        } else if let i = try? c.decode(Int.self) {
            value = i
        } else if let d = try? c.decode(Double.self) {
            value = d
        } else if let s = try? c.decode(String.self) {
            value = s
        } else if let a = try? c.decode([JVal].self) {
            value = a.map(\.value)
        } else if let o = try? c.decode([String: JVal].self) {
            value = o.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let x as Bool: try c.encode(x)
        case let x as Int: try c.encode(x)
        case let x as Double: try c.encode(x)
        case let x as String: try c.encode(x)
        case let x as [Any]: try c.encode(x.map { JVal($0) })
        case let x as [String: Any]: try c.encode(x.mapValues { JVal($0) })
        default: try c.encodeNil()
        }
    }
}

/// JSON-RPC 2.0 request.
///
/// `id` and `params` are untyped JSON on the wire, so they are untyped here. Two live defects
/// this closes, both measured on this host at HEAD before the change:
///   • `id` was `String?`, and the synthesized `Decodable` therefore *required* a string.
///     `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}` — the shape the Python and
///     TypeScript MCP SDKs and Claude Desktop send, since §4.1 allows String, Number or Null —
///     came back `-32700 Parse error`. A spec-legal client could not complete one handshake.
///   • `paramsData` had no `CodingKey` for the wire key `params`, so **every** request decoded
///     with params == nil, and `tools/call` answered `{"result":{}}` — a success-shaped empty
///     body — instead of running the tool or refusing. Callers cannot distinguish "no arguments"
///     from "we dropped your arguments", which is invariant 2 in the worst direction.
/// Same class as the pinned-wire-DTO rule in AGENTS.md, applied to a field the spec leaves open:
/// pinning one JSON type is a refusal the surface never documented.
private struct JsonRpcReq: Decodable {
    let jsonrpc: String
    let method: String
    let id: JVal?
    let paramsJSON: JVal?

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, method, id
        case paramsJSON = "params"
    }

    var params: [String: Any]? {
        paramsJSON?.value as? [String: Any]
    }
}

/// JSON-RPC error codes.
private enum RpcErr: Int {
    case parse = -32700
    case invalid = -32600
    case noMethod = -32601
    case badParams = -32602
    case internalServerError = -32603
    var code: Int {
        rawValue
    }

    var msg: String {
        switch self {
        case .parse: "Parse error"
        case .invalid: "Invalid Request"
        case .noMethod: "Method not found"
        case .badParams: "Invalid params"
        case .internalServerError: "Internal error"
        }
    }
}

/// MCP Server actor.
actor MCPServer {
    private let registry: ToolRegistry
    private let transport: MCPStdioTransport
    private let log: Logger
    private var ready = false

    init(
        registry: ToolRegistry, transport: MCPStdioTransport,
        log: Logger = Logger(label: "ocoreai.mcp")
    ) {
        self.registry = registry
        self.transport = transport
        self.log = log
    }

    /// Dispatch one JSON-RPC message string, returns response string or nil for notifications.
    func dispatch(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8) else {
            return err(.parse, id: nil)
        }
        guard let req = try? JSONDecoder().decode(JsonRpcReq.self, from: data) else {
            log.warning("Failed to parse JSON-RPC request: \(line.prefix(120))")
            return err(.parse, id: nil)
        }
        guard req.jsonrpc == "2.0" else { return err(.invalid, id: req.id) }

        // Methods that carry work need the handshake and need their params; both refusals name the
        // field or the step, because "Invalid params" alone leaves the caller guessing (and a
        // silent empty result leaves them guessing wrong).
        switch req.method {
        case "initialize":
            return res(doInit(req.params), id: req.id)
        case "tools/list":
            guard ready else {
                return err(
                    .invalid, id: req.id, detail: "not initialized — send `initialize` first")
            }
            return res(await doList(), id: req.id)
        case "tools/call":
            guard ready else {
                return err(
                    .invalid, id: req.id, detail: "not initialized — send `initialize` first")
            }
            guard let params = req.params else {
                return err(.badParams, id: req.id, detail: "tools/call needs a params object")
            }
            guard let name = params["name"] as? String, !name.isEmpty else {
                return err(.badParams, id: req.id, detail: "missing required field `name`")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return res(await doCall(name: name, arguments: arguments), id: req.id)
        case "ping":
            return res(JVal([String: String]()), id: req.id)
        case "$/cancel": return nil
        default: return err(.noMethod, id: req.id)
        }
    }

    // MARK: - Methods

    private func doInit(_: [String: Any]?) -> JVal {
        ready = true
        return JVal([
            "protocolVersion": "2025-06-18",
            "serverInfo": ["name": "ocoreai", "version": AppInfo.shortVersion],
            "capabilities": ["tools": ["listChanged": true]],
        ])
    }

    /// The list must describe the tools. Measured at HEAD this published
    /// `{"inputSchema":{"properties":{},"type":"object"}}` for all 39 tools: every tool presented
    /// as taking no arguments and carrying no description, so a client that trusted it generated
    /// argument-less calls and nothing could succeed — while the surface kept advertising `/mcp`.
    /// `ToolEntry.toToolDef()` is the one home that already renders the faithful JSON Schema
    /// (nested `properties`, `items`, and the name-sorted synthesized `required`), so publish that
    /// instead of a second, thinner translation of the same registry.
    /// Foundation's `JSONSerialization` raises an Objective-C exception for a value it cannot
    /// represent, and `try?` does not catch ObjC exceptions — measured: the test process aborted
    /// with `libc++abi: terminating due to uncaught exception of type NSException` rather than
    /// failing a case. `AnyCodable` is such a value (it is Codable, not a Foundation JSON type),
    /// so anything built by `toToolDef()` must travel through its own Codable conformance and come
    /// back as plain Foundation objects before it joins a response dictionary.
    private func plainJSON<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func doList() async -> JVal {
        var list: [[String: Any]] = []
        for name in await registry.listTools() {
            guard let entry = await registry.lookup(name) else { continue }
            let def = entry.toToolDef()
            let schema =
                def.function.parameters.flatMap(plainJSON)
                ?? ["type": "object", "properties": [String: Any]()]
            var tool: [String: Any] = [
                "name": name,
                "inputSchema": schema,
            ]
            if let description = def.function.description, !description.isEmpty {
                tool["description"] = description
            }
            list.append(tool)
        }
        log.info("tools/list published \(list.count) tools with schemas")
        return JVal(["tools": list])
    }

    private func doCall(name: String, arguments args: [String: Any]) async -> JVal {
        let j =
            (try? JSONSerialization.data(withJSONObject: args)).flatMap {
                String(decoding: $0, as: UTF8.self)
            } ?? "{}"
        do {
            let r = try await registry.call(name, arguments: j)
            return JVal(["content": [["type": "text", "text": r]], "isError": false])
        } catch {
            return JVal([
                "content": [["type": "text", "text": error.localizedDescription]], "isError": true,
            ])
        }
    }

    // MARK: - Encode

    private func res(_ v: JVal, id: JVal?) -> String {
        enc(["result": v.value], id: id)
    }

    /// `detail` names what the client got wrong. An error that says only "Invalid params" makes a
    /// caller guess; the refusal must be as specific as the check that produced it.
    private func err(_ e: RpcErr, id: JVal?, detail: String? = nil) -> String {
        enc(
            ["error": ["code": e.code, "message": detail.map { "\(e.msg): \($0)" } ?? e.msg]],
            id: id)
    }

    private func enc(_ body: [String: Any], id: JVal?) -> String {
        var d: [String: Any] = ["jsonrpc": "2.0"]
        d.merge(body, uniquingKeysWith: { $1 })
        // Echo the id in the type the client sent it: §4.1 requires the responder to return the
        // same identifier, so answering the number 1 with the string "1" is a different id.
        if let id { d["id"] = id.value }
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: .sortedKeys) else {
            log.error(
                "Failed to serialize JSON-RPC response for id: \(String(describing: id?.value))")
            return err(.internalServerError, id: id)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
