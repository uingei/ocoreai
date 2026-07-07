// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MCP Bridge — 双向 MCP client + server 组合。
///
/// 职责：
/// - 本地 ToolRegistry 是工具调用的第一优先级（零跳数）
/// - 未命中本地 registry 时 fan-out 到外部 MCP server
/// - 工具调用结果 LRU 缓存（MCPCallCache），减少重复调用
/// - 外部 server 生命周期管理：connect/disconnect/status
///
/// 并发模型：actor 隔离，所有状态变更经 mailbox。

import CryptoKit
import Foundation
import Logging

// MARK: - 外部 Endpoint

/// MCP endpoint 描述外部 server 的连接信息。
public struct MCPEndpoint: Codable, Sendable {
	/// Server 名称（唯一标识）
	public let name: String

	/// stdio 命令路径（如 "npx", "uvx", "python"）
	public let stdioCommand: String

	/// 命令行参数
	public let stdioArgs: [String]

	/// Server 能力列表（如 ["tools", "resources"]）
	public let capabilities: [String]

	public init(
		name: String,
		stdioCommand: String,
		stdioArgs: [String] = [],
		capabilities: [String] = ["tools"],
	) {
		self.name = name
		self.stdioCommand = stdioCommand
		self.stdioArgs = stdioArgs
		self.capabilities = capabilities
	}
}

// MARK: - Endpoint Status enum

public extension MCPEndpoint {
	/// Server 连接状态
	enum Status: String, Codable, Sendable {
		case disconnected
		case connecting
		case connected
		case errored
	}
}

// MARK: - Endpoint 连接状态

/// 运行中 endpoint 的状态封装。
private struct EndpointHandle {
	/// Endpoint 配置
	let endpoint: MCPEndpoint

	/// 当前连接状态
	var status: MCPEndpoint.Status

	/// Server 初始化能力（initialize 后填充）
	var serverCapabilities: [String: String]

	/// 最后一次错误信息
	var lastError: String?

	/// 连接时间
	var connectedAt: Date?

	init(endpoint: MCPEndpoint, status: MCPEndpoint.Status = .disconnected) {
		self.endpoint = endpoint
		self.status = status
		serverCapabilities = [:]
		lastError = nil
		connectedAt = nil
	}
}

// MARK: - Bridge 配置

/// MCP Bridge 配置。
public struct MCPBridgeConfig: Sendable {
	/// 是否启用工具调用缓存
	public var callCacheEnabled: Bool

	/// 缓存最大条目数
	public var callCacheMaxEntries: Int

	/// 缓存 TTL（秒）
	public var callCacheTTLSeconds: TimeInterval

	/// 外部 server 响应超时（秒）
	public var serverTimeoutSeconds: TimeInterval

	/// Fan-out 策略：并行还是串行
	public var fanOutStrategy: MCPEndpoint.FanOutStrategy

	/// 默认配置
	public static let `default`: MCPBridgeConfig = .init()

	public init(
		callCacheEnabled: Bool = true,
		callCacheMaxEntries: Int = 256,
		callCacheTTLSeconds: TimeInterval = 60,
		serverTimeoutSeconds: TimeInterval = 10,
		fanOutStrategy: MCPEndpoint.FanOutStrategy = .parallel,
	) {
		self.callCacheEnabled = callCacheEnabled
		self.callCacheMaxEntries = callCacheMaxEntries
		self.callCacheTTLSeconds = callCacheTTLSeconds
		self.serverTimeoutSeconds = serverTimeoutSeconds
		self.fanOutStrategy = fanOutStrategy
	}
}

public extension MCPEndpoint {
	/// Fan-out 策略
	enum FanOutStrategy: String, Sendable {
		/// 并行请求所有外部 server（P95 更快，但并发开销大）
		case parallel
		/// 串行请求外部 server（节省资源，P95 较慢）
		case serial
		/// 顺序请求直到有一个返回结果
		case firstResponse
	}
}

// MARK: - MCPBridge Actor

/// MCP Bridge actor — 管理本地 + 外部 server 的工具路由。
actor MCPBridge {
	// MARK: - 状态

	/// 工具注册表引用 — 用于将外部 MCP 工具注册到全局 ToolRegistry
	private let toolRegistry: ToolRegistry

	/// 本地工具服务器
	private let server: MCPServer

	/// 工具调用缓存
	private let callCache: MCPCallCache

	/// Bridge 配置
	private let config: MCPBridgeConfig

	/// 外部 endpoint 管理
	private var endpointHandles: [String: EndpointHandle] = [:]

	/// 外部 MCP Stdio 客户端集合
	private var externalClients: [String: MCPStdioClient] = [:]

	/// 日志器
	private let log: Logger

	// MARK: - 初始化

	/// 初始化 MCP Bridge。
	init(
		toolRegistry: ToolRegistry,
		transport: MCPStdioTransport,
		endpoints: [MCPEndpoint] = [],
		bridgeConfig: MCPBridgeConfig = .default,
		log: Logger = Logger(label: "ocoreai.mcp.bridge"),
	) {
		self.toolRegistry = toolRegistry
		server = MCPServer(registry: toolRegistry, transport: transport, log: log)
		callCache = MCPCallCache(
			maxEntries: bridgeConfig.callCacheMaxEntries,
			ttlSeconds: bridgeConfig.callCacheTTLSeconds,
		)
		config = bridgeConfig
		self.log = log

		// 预注册初始端点
		for ep in endpoints {
			endpointHandles[ep.name] = EndpointHandle(endpoint: ep)
		}

		log.info("MCPBridge initialized: local registry + \(endpoints.count) external endpoints, cache=\(bridgeConfig.callCacheEnabled)")
	}

	// MARK: - 消息处理

	/// 处理一行输入消息（来自 stdio client）。
	func handleLine(_ line: String) async -> String? {
		guard !line.isEmpty else { return nil }
		let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }

		// 尝试解析为 Bridge 管理命令
		if let cmdResponse = await handleBridgeCommand(trimmed) {
			return cmdResponse
		}

		// 转发到本地 MCP server
		return await server.dispatch(trimmed)
	}

	/// 处理 Bridge 管理命令（内部路由）
	private func handleBridgeCommand(_ line: String) async -> String? {
		guard let data = line.data(using: .utf8),
		      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let method = obj["method"] as? String
		else {
			return nil
		}

		// 非 bridge 命令直接返回 nil 让其继续到 MCPServer
		guard method.hasPrefix("$bridge/") else { return nil }

		let reqID = obj["id"] as Any?

		switch method {
		case "$bridge/endpoint/list":
			return jsonResult(listEndpoints(), id: reqID)
		case "$bridge/endpoint/connect":
			guard let params = obj["params"] as? [String: Any],
			      let name = params["name"] as? String,
			      let command = params["command"] as? String
			else {
				return jsonError("Missing required params: name, command", code: -32602, id: reqID)
			}
			let args = params["args"] as? [String] ?? []
			let caps = params["capabilities"] as? [String] ?? []
			do {
				try await connectEndpoint(name: name, command: command, args: args, capabilities: caps)
				return jsonResult(["endpoint": name, "status": "connected"], id: reqID)
			} catch {
				return jsonError("Connect failed: \(error.localizedDescription)", code: -32603, id: reqID)
			}
		case "$bridge/endpoint/disconnect":
			guard let params = obj["params"] as? [String: Any],
			      let name = params["name"] as? String
			else {
				return jsonError("Missing required param: name", code: -32602, id: reqID)
			}
			await disconnectEndpoint(name: name)
			return jsonResult(["endpoint": name, "status": "disconnected"], id: reqID)
		case "$bridge/status":
			return jsonResult(bridgeStatus(), id: reqID)
		case "$bridge/cache/clear":
			await callCache.clear()
			return jsonResult(["cache": "cleared"], id: reqID)
		case "$bridge/cache/status":
			return await jsonResult(callCache.status(), id: reqID)
		default:
			return nil
		}
	}

	// MARK: - 工具路由

	/// 路由工具调用请求到合适的处理者。
	func routeToolCall(_ toolName: String, arguments: String) async throws -> String {
		// 1. Cache check
		if config.callCacheEnabled {
			let cacheKey = cacheKey(for: toolName, args: arguments)
			if let cached = await callCache.get(cacheKey) {
				log.debug("Cache hit: \(toolName)")
				return cached
			}
		}

		// 2. 本地 ToolRegistry — 通过 dispatch 发送 tools/call 请求
		do {
			let result = try await callLocalTool(toolName, arguments: arguments)
			if config.callCacheEnabled {
				let cacheKey = cacheKey(for: toolName, args: arguments)
				await callCache.set(cacheKey, value: result)
			}
			return result
		} catch {
			log.debug("Local registry miss: \(toolName)")
		}

		// 3. Fan-out 到外部 MCP servers
		do {
			let externalResult = try await routeToExternalServers(toolName, arguments: arguments)
			if config.callCacheEnabled {
				let cacheKey = cacheKey(for: toolName, args: arguments)
				await callCache.set(cacheKey, value: externalResult)
			}
			return externalResult
		} catch {
			log.warning("Tool routing failed for \(toolName): \(error.localizedDescription)")
			throw MCPBridgeError.routingFailed(toolName, reason: error.localizedDescription)
		}
	}

	/// 调用本地工具（通过 MCPServer dispatch）。
	private func callLocalTool(_ toolName: String, arguments: String) async throws -> String {
		guard !toolName.isEmpty else {
			throw MCPBridgeError.routingFailed(toolName, reason: "Empty tool name")
		}

		// 构造 JSON-RPC 请求
		let params: [String: Any] = if let data = arguments.data(using: .utf8),
		                               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		{
			["name": toolName, "arguments": parsed]
		} else {
			["name": toolName, "arguments": [:]]
		}

		let jsonRpcReq: [String: Any] = [
			"jsonrpc": "2.0",
			"method": "tools/call",
			"id": "local-bridge",
			"params": params,
		]

		guard let reqJSON = try? JSONSerialization.data(withJSONObject: jsonRpcReq, options: .sortedKeys),
		      let reqStr = String(data: reqJSON, encoding: .utf8)
		else {
			throw MCPBridgeError.routingFailed(toolName, reason: "Failed to serialize tool call request")
		}

		guard let response = await server.dispatch(reqStr),
		      let respData = response.data(using: .utf8),
		      let respObj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
		      let result = respObj["result"] as? [String: Any],
		      let contents = result["content"] as? [[String: Any]]
		else {
			throw MCPBridgeError.routingFailed(toolName, reason: "Local tool not found or execution failed")
		}

		// 提取文本内容
		var texts: [String] = []
		for content in contents {
			if let text = content["text"] as? String {
				texts.append(text)
			}
		}

		// 检查是否是错误响应
		if (result["isError"] as? Bool) == true {
			throw MCPBridgeError.routingFailed(toolName, reason: texts.joined(separator: "\n"))
		}

		guard !texts.isEmpty else {
			throw MCPBridgeError.routingFailed(toolName, reason: "No text content in response")
		}

		return texts.joined(separator: "\n")
	}

	/// 路由到外部 MCP servers。
	private func routeToExternalServers(
		_ toolName: String,
		arguments: String,
	) async throws -> String {
		// 查找已连接且支持 tools 能力的 external clients
		let clientNames = endpointHandles.values
			.filter { $0.status == .connected && $0.endpoint.capabilities.contains("tools") }
			.map(\.endpoint.name)

		guard !clientNames.isEmpty else {
			throw MCPBridgeError.noServerAvailable(toolName)
		}

		// 解析 arguments JSON
		let argsDict: [String: Any] = if let data = arguments.data(using: .utf8),
		                                 let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		{
			parsed
		} else {
			[:]
		}

		switch config.fanOutStrategy {
		case .parallel:
			return try await routeParallel(toolName, arguments: argsDict, names: clientNames)
		case .serial:
			return try await routeSerial(toolName, arguments: argsDict, names: clientNames)
		case .firstResponse:
			return try await routeFirstResponse(toolName, arguments: argsDict, names: clientNames)
		}
	}

	/// 并行 fan-out：同时发给所有外部 server，取第一个成功结果。
	private func routeParallel(
		_ toolName: String,
		arguments: [String: Any],
		names: [String],
	) async throws -> String {
		let resolvedClients = [(String, MCPStdioClient)](names.compactMap { name in
			let client = self.externalClients[name]
			return client.map { (name, $0) }
		})

		let argsJson = try? JSONSerialization.data(withJSONObject: arguments, options: [])
		let argsJsonStr = argsJson.map { String(decoding: $0, as: UTF8.self) } ?? "{}"

		return try await withThrowingTaskGroup(of: String.self) { group in
			for (_, client) in resolvedClients {
				group.addTask { @Sendable [weak self] in
					guard let s = self else { throw MCPBridgeError.externalProcessNotManaged }
					return try await s.forwardToolCall(to: client, tool: toolName, args: argsJsonStr)
				}
			}

			for try await result in group {
				return result
			}

			// All tasks returned without throwing (should not happen in practice).
			throw MCPBridgeError.allExternalServersFailed(toolName)
		}
	}

	/// 串行 fan-out：按顺序尝试每个 server。
	private func routeSerial(
		_ toolName: String,
		arguments: [String: Any],
		names: [String],
	) async throws -> String {
		let argsJson = try? JSONSerialization.data(withJSONObject: arguments, options: [])
		let argsJsonStr = argsJson.map { String(decoding: $0, as: UTF8.self) } ?? "{}"

		var lastError: Error?

		for clientName in names {
			guard let client = externalClients[clientName] else { continue }
			do {
				let result = try await forwardToolCall(to: client, tool: toolName, args: argsJsonStr)
				log.info("External tool call success: \(toolName) → \(clientName)")
				return result
			} catch {
				lastError = error
				log.warning("External tool failed \(toolName) → \(clientName): \(error)")
			}
		}

		throw lastError ?? MCPBridgeError.allExternalServersFailed(toolName)
	}

	/// 首次响应 fan-out（与串行相同，但只返回第一个结果）。
	private func routeFirstResponse(
		_ toolName: String,
		arguments: [String: Any],
		names: [String],
	) async throws -> String {
		try await routeSerial(toolName, arguments: arguments, names: names)
	}

	/// 向指定客户端转发工具调用，合并内容块为字符串。
	private func forwardToolCall(
		to client: MCPStdioClient,
		tool: String,
		args jsonStr: String,
	) async throws -> String {
		var argsDict: [String: Any] = [:]
		if let data = jsonStr.data(using: .utf8),
		   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		{
			argsDict = parsed
		}

		let contentBlocks = try await client.callTool(tool, arguments: argsDict)
		var texts: [String] = []
		for block in contentBlocks {
			if let text = block["text"] {
				texts.append(text)
			} else if let type = block["type"] {
				texts.append("[\(type)]")
			}
		}
		guard !texts.isEmpty else {
			throw MCPClientError.protocolError("No text content in tool response")
		}
		return texts.joined(separator: "\n---\n")
	}

	// MARK: - Endpoint 管理

	/// Discover tools from an MCP endpoint and register them to the global ToolRegistry.
	/// Tools are tagged with `mcpSource` so they can be batch-unregistered on disconnect.
	private func discoverAndRegisterTools(client: MCPStdioClient, source: String) async throws {
		// Use raw JSON to avoid Sendable boundary issue with [[String: Any]] across actors
		let rawJSON = try await client.listToolsRaw()

		// Parse on MCPBridge side (same actor context)
		guard let data = rawJSON.data(using: .utf8),
			  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let result = obj["result"] as? [String: Any],
			  let tools = result["tools"] as? [[String: Any]]
		else {
			log.info("Endpoint \(source) has no tools to discover")
			return
		}

		guard !tools.isEmpty else {
			log.info("Endpoint \(source) has no tools to discover")
			return
		}

		for toolInfo in tools {
			let toolName = (toolInfo["name"] as? String) ?? ""
			guard !toolName.isEmpty else { continue }

			// Build schema from MCP inputSchema
			let inputSchema = toolInfo["inputSchema"] as? [String: Any] ?? [:]
			let properties = inputSchema["properties"] as? [String: [String: Any]] ?? [:]

			var parameters: [String: ParameterType] = [:]
			for (paramName, paramInfo) in properties {
				let typeString = (paramInfo["type"] as? String)?.lowercased() ?? "string"
				let paramType: ParameterType
				switch typeString {
				case "string": paramType = .string
				case "number", "integer": paramType = .integer
				case "boolean": paramType = .boolean
				case "array": paramType = .array
				default: paramType = .string
				}
				parameters[paramName] = paramType
			}

			let schema = ToolSchema(parameters: parameters)

			// Handler forwards calls to the MCP client via the bridge
			let handler: @Sendable (String) async throws -> String = { arguments in
				let results = try await self.forwardToolCall(name: toolName, arguments: arguments, source: source)
				let texts = results.compactMap { $0["text"] }
				guard !texts.isEmpty else { return "(no content)" }
				return texts.joined(separator: "\n")
			}

			let entry = ToolEntry(
				name: toolName,
				toolset: "mcp:\(source)",
				schema: schema,
				handler: handler,
				mcpSource: source,
			)

			try await toolRegistry.register(entry)
			log.info("Registered MCP tool: \(toolName) [mcp:\(source)]")
		}

		log.info("Discovered \(tools.count) tools from endpoint \(source)")
	}

	/// Forward a tool call to the MCP client for the given source endpoint.
	/// Called from outside the MCPBridge actor (e.g., ToolRegistry handler dispatch).
	private func forwardToolCall(name: String, arguments: String, source: String) async throws -> [[String: String]] {
		guard let client = externalClients[source] else {
			throw MCPBridgeError.noServerAvailable(source)
		}

		// Parse arguments JSON
		let argsData = arguments.data(using: .utf8)
		let argsMap: [String: Any]
		if let data = argsData,
		   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
			argsMap = parsed
		} else {
			argsMap = [:]
		}

		let results = try await client.callTool(name, arguments: argsMap)
		return results
	}

	/// 连接外部 MCP endpoint（启动子进程 + initialize + discover tools）。
	func connectEndpoint(
		name: String,
		command: String,
		args: [String],
		capabilities: [String],
	) async throws {
		let ep = MCPEndpoint(
			name: name,
			stdioCommand: command,
			stdioArgs: args,
			capabilities: capabilities,
		)

		var handle = EndpointHandle(endpoint: ep, status: .connecting)
		endpointHandles[name] = handle

		do {
			let transport = MCPStdioTransport(log: Logger(label: "ocoreai.mcp.client.\(name)"))
			let client = MCPStdioClient(endpoint: ep, transport: transport, log: log)
			try await client.connect()

			handle.status = .connected
			handle.connectedAt = Date()
			endpointHandles[name] = handle
			externalClients[name] = client

			log.info("Endpoint \(name) connected: \(command) \(args.joined(separator: " "))")

			// Discover tools from this endpoint and register them to ToolRegistry
			try await discoverAndRegisterTools(client: client, source: name)
		} catch {
			handle.status = .errored
			handle.lastError = error.localizedDescription
			endpointHandles[name] = handle
			log.error("Connect endpoint \(name) failed: \(error)")
			throw error
		}
	}

	/// 断开外部 MCP endpoint。
	func disconnectEndpoint(name: String) async {
		// Unregister tools from this MCP source before disconnecting
		await toolRegistry.unregisterToolsFromSource(name)

		if let client = externalClients[name] {
			Task { @Sendable in
				await client.disconnect()
			}
		}
		externalClients.removeValue(forKey: name)

		if var handle = endpointHandles[name] {
			handle.status = .disconnected
			endpointHandles[name] = handle
		}

		log.info("Endpoint \(name) disconnected")
	}

	/// 移除 endpoint。
	func removeEndpoint(name: String) async {
		await disconnectEndpoint(name: name)
		endpointHandles.removeValue(forKey: name)
		log.info("Endpoint \(name) removed")
	}

	// MARK: - 状态查询

	/// Bridge 状态。
	private func bridgeStatus() -> [String: Any] {
		var connected = 0
		for handle in endpointHandles.values where handle.status == .connected {
			connected += 1
		}

		return [
			"server": "ocoreai-mcp",
			"version": "0.7.0",
			"endpoints": endpointHandles.count,
			"connectedEndpoints": connected,
			"cacheEnabled": config.callCacheEnabled,
		]
	}

	/// 列出已注册的远程端点。
	func listEndpoints() -> [[String: Any]] {
		endpointHandles.values.map { handle in
			[
				"name": handle.endpoint.name,
				"command": handle.endpoint.stdioCommand,
				"args": handle.endpoint.stdioArgs,
				"capabilities": handle.endpoint.capabilities,
				"status": handle.status.rawValue,
				"lastError": handle.lastError as Any,
			]
		}
	}

	/// Sendable endpoint summary for cross-actor use.
	struct MCPEndpointSummaryItem: Codable, Identifiable {
		var id: String {
			name
		}

		let name: String
		let command: String
		let status: String
	}

	func listEndpointSummaries() -> [MCPEndpointSummaryItem] {
		endpointHandles.values.map { handle in
			MCPEndpointSummaryItem(
				name: handle.endpoint.name,
				command: handle.endpoint.stdioCommand,
				status: handle.status.rawValue,
			)
		}
	}

	// MARK: - 缓存

	/// 清空缓存。
	func clearCache() async {
		await callCache.clear()
	}

	// MARK: - JSON 辅助

	/// 构造 JSON-RPC 响应消息。
	private func jsonResult(_ body: Any) -> String {
		jsonResult(body, id: nil)
	}

	/// 带请求 id 的 JSON-RPC 响应。
	private func jsonResult(_ body: Any, id: Any?) -> String {
		var dict: [String: Any] = ["jsonrpc": "2.0", "result": body]
		if let id { dict["id"] = id }
		guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
		else {
			log.error("Failed to serialize JSON-RPC result for id: \(id ?? "nil")")
			return jsonError("Internal serialization error", code: -32603, id: id)
		}
		return String(decoding: data, as: UTF8.self)
	}

	/// 构造 JSON-RPC 错误消息。
	private func jsonError(_ message: String, code: Int) -> String {
		jsonError(message, code: code, id: nil)
	}

	private func jsonError(_ message: String, code: Int, id: Any?) -> String {
		let errorObj: [String: Any] = ["code": code, "message": message]
		var dict: [String: Any] = ["jsonrpc": "2.0", "error": errorObj]
		if let id { dict["id"] = id }
		guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .sortedKeys)
		else {
			log.error("Failed to serialize JSON-RPC error for id: \(id ?? "nil")")
			// Fallback: guaranteed-serializable error response
			return #"{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error"}}"#
		}
		return String(decoding: data, as: UTF8.self)
	}

	// MARK: - Cache key

	/// 生成工具调用缓存 key。
	private func cacheKey(for toolName: String, args: String) -> String {
		let hash = Insecure.MD5.hash(data: args.data(using: .utf8) ?? Data())
		let hashStr = hash.map { String(format: "%02x", $0) }.joined()
		return "\(toolName):\(hashStr)"
	}

	// MARK: - Shutdown

	/// 优雅关闭所有资源。
	func shutdown() {
		for epName in Array(endpointHandles.keys) {
			if externalClients[epName] != nil {
				log.info("Closing external endpoint: \(epName)")
			}
		}
		externalClients.removeAll()
		endpointHandles.removeAll()
		log.info("MCPBridge shutdown complete")
	}
}

// MARK: - Bridge 错误类型

/// MCP Bridge 错误类型。
public enum MCPBridgeError: Error, Sendable {
	case routingFailed(String, reason: String)
	case noServerAvailable(String)
	case allExternalServersFailed(String)
	case externalProcessNotManaged

	var localizedDescription: String {
		switch self {
		case let .routingFailed(tool, reason):
			"Tool '\(tool)' routing failed: \(reason)"
		case let .noServerAvailable(tool):
			"No MCP server available for tool '\(tool)'"
		case let .allExternalServersFailed(tool):
			"All external servers failed for tool '\(tool)'"
		case .externalProcessNotManaged:
			"External process management not yet integrated"
		}
	}
}

// MARK: - Date extension

private extension Date {
	var iso8601String: String {
		let formatter = ISO8601DateFormatter()
		return formatter.string(from: self)
	}
}
