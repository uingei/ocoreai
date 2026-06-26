// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MCP Server — JSON-RPC 2.0 server exposing ToolRegistry tools.
/// Protocol: MCP v2024-11-05 (initialize, tools/list, tools/call, ping).
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
		if let b = try? c.decode(Bool.self) { value = b }
		else if let i = try? c.decode(Int.self) { value = i }
		else if let d = try? c.decode(Double.self) { value = d }
		else if let s = try? c.decode(String.self) { value = s }
		else if let a = try? c.decode([JVal].self) { value = a.map(\.value) }
		else if let o = try? c.decode([String: JVal].self) { value = o.mapValues { $0.value } }
		else { value = NSNull() }
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
private struct JsonRpcReq: Decodable {
	let jsonrpc: String
	let method: String
	let id: String?
	let paramsData: String?
	var params: [String: Any]? {
		guard let d = paramsData, let data = d.data(using: .utf8) else { return nil }
		return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
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

	init(registry: ToolRegistry, transport: MCPStdioTransport, log: Logger = Logger(label: "ocoreai.mcp")) {
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
			return err(.parse, id: nil)
		}
		guard req.jsonrpc == "2.0" else { return err(.invalid, id: req.id) }

		let ok: JVal?
		switch req.method {
		case "initialize": ok = doInit(req.params)
		case "tools/list": ok = await doList()
		case "tools/call": ok = await doCall(req.params)
		case "ping": ok = JVal([String: String]())
		case "$/cancel": return nil
		default: return err(.noMethod, id: req.id)
		}
		return ok.map { res($0, id: req.id) }
	}

	// MARK: - Methods

	private func doInit(_: [String: Any]?) -> JVal {
		ready = true
		return JVal([
			"protocolVersion": "2024-11-05",
			"serverInfo": ["name": "ocoreai", "version": "0.7.0"],
			"capabilities": ["tools": ["listChanged": true]],
		])
	}

	private func doList() async -> JVal {
		guard ready else { return JVal([String: String]()) }
		var list: [[String: Any]] = []
		for n in await registry.listTools() {
			if await registry.schema(for: n) != nil {
				list.append(["name": n, "inputSchema": ["type": "object", "properties": [String: Any]()]])
			}
		}
		return JVal(["tools": list])
	}

	private func doCall(_ p: [String: Any]?) async -> JVal {
		guard ready else { return JVal([String: String]()) }
		guard let name = p?["name"] as? String else { return JVal([String: String]()) }
		let args = p?["arguments"] as? [String: Any] ?? [:]
		let j = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(decoding: $0, as: UTF8.self) } ?? "{}"
		do {
			let r = try await registry.call(name, arguments: j)
			return JVal(["content": [["type": "text", "text": r]], "isError": false])
		} catch {
			return JVal(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
		}
	}

	// MARK: - Encode

	private func res(_ v: JVal, id: String?) -> String {
		enc(["result": v.value], id: id)
	}

	private func err(_ e: RpcErr, id: String?) -> String {
		enc(["error": ["code": e.code, "message": e.msg]], id: id)
	}

	private func enc(_ body: [String: Any], id: String?) -> String {
		var d: [String: Any] = ["jsonrpc": "2.0"]
		d.merge(body, uniquingKeysWith: { $1 })
		if let id { d["id"] = id }
		guard let data = try? JSONSerialization.data(withJSONObject: d, options: .sortedKeys) else { return "{}" }
		return String(decoding: data, as: UTF8.self)
	}
}
