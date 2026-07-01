// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MCP Stdio Client — 通过 stdio 管道连接外部 MCP server 子进程。
///
/// 生命周期的每一步都经过 actor mailbox，确保并发安全。
/// 子进程通过 Foundation.Process + Pipe 管理，
/// 读写侧与 ``MCPStdioTransport`` 管道模式对接。
import Foundation
import Logging

/// 外部 MCP server 的连接状态
enum MCPClientConnectionStatus: String, Codable {
	case disconnected
	case connecting
	case connected
	case error
}

/// 外部 MCP server 客户端：启动子进程、发送/接收 JSON-RPC。
actor MCPStdioClient {
	/// 端点配置
	let endpoint: MCPEndpoint
	/// 当前连接状态
	private(set) var status: MCPClientConnectionStatus = .disconnected
	/// 子进程句柄
	private var process: Process?
	/// 传输层（管道模式）
	private let transport: MCPStdioTransport
	/// 日志
	private let log: Logger
	/// 最后错误
	private var lastError: String?
	/// jsonrpc 请求 id 计数器
	private var nextID: Int = 0

	// MARK: - 初始化

	init(
		endpoint: MCPEndpoint,
		transport: MCPStdioTransport,
		log: Logger = Logger(label: "ocoreai.mcp.client"),
	) {
		self.endpoint = endpoint
		self.transport = transport
		self.log = log
	}

	// MARK: - 连接管理

	/// 连接到外部 MCP server（启动子进程）。
	/// - Throws: 启动失败或初始化超时。
	func connect() async throws {
		guard process == nil else {
			log.warning("Already connected to '\(endpoint.name)'")
			return
		}

		status = .connecting
		lastError = nil

		do {
			let stdinPipe = Pipe()
			let stdoutPipe = Pipe()
			let proc = try launchProcess(stdin: stdinPipe, stdout: stdoutPipe)
			process = proc

			// 配置传输层使用管道模式
			await transport.configurePipeMode(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)

			log.info("Launched MCP client for '\(endpoint.name)' (pid: \(proc.processIdentifier))")

			// 发送 initialize 请求
			try await sendInitialize()

			status = .connected
			log.info("Connected to '\(endpoint.name)'")
		} catch {
			status = .error
			lastError = error.localizedDescription
			log.error("Failed to connect to '\(endpoint.name)': \(error)")
			await cleanup()
			throw error
		}
	}

	/// 断开连接（终止子进程）。
	func disconnect() async {
		log.info("Disconnecting from '\(endpoint.name)'")
		await cleanup()
	}

	// MARK: - JSON-RPC 交互

	/// 发送 JSON-RPC 请求并等待响应。
	/// - Parameters:
	///   - method: JSON-RPC 方法名
	///   - params: 请求参数字典
	/// - Returns: 响应 JSON 字符串。
	/// - Throws: 协议错误或超时。
	func request(_ method: String, params: [String: Any]?) async throws -> String {
		guard status == .connected else {
			throw MCPClientError.notConnected(endpoint.name)
		}

		let id = nextID
		nextID += 1
		var req: [String: Any] = [
			"jsonrpc": "2.0",
			"method": method,
			"id": id,
		]
		if let params {
			req["params"] = params
		}

		// 发送
		let reqJSON = try serializeJSON(req)
		_ = await transport.writeDirect(reqJSON)

		// 等待响应（15 秒超时）
		return try await withTimeout(seconds: 15) {
			try await self.waitForResponse()
		}
	}

	/// 超时包装器：并发执行操作与定时器，取先完成者。
	private func withTimeout(seconds: Double, operation: @Sendable @escaping () async throws -> String) async throws -> String {
		try await withThrowingTaskGroup(of: Result<String, Error>.self) { group in
			group.addTask {
				do {
					return try await .success(operation())
				} catch {
					return .failure(error)
				}
			}
			group.addTask {
				try? await Task.sleep(for: .seconds(seconds))
				return .failure(MCPClientError.timeout(self.endpoint.name))
			}

			for try await result in group {
				group.cancelAll()
				switch result {
				case let .success(value): return value
				case let .failure(error): throw error
				}
			}
			throw MCPClientError.timeout(self.endpoint.name)
		}
	}

	/// 列出外部 server 提供的工具。
	func listTools() async throws -> [[String: Any]] {
		let response = try await request("tools/list", params: [:])
		return parseToolsListResponse(response)
	}

	/// 列出外部 server 提供的工具（返回原始 JSON 字符串，Sendable-safe）。
	func listToolsRaw() async throws -> String {
		try await request("tools/list", params: [:])
	}

	/// 调用外部 server 上的工具。
	/// - Returns: 工具执行结果内容数组。
	func callTool(_ name: String, arguments: [String: Any]) async throws -> [[String: String]] {
		let params: [String: Any] = ["name": name, "arguments": arguments]
		let response = try await request("tools/call", params: params)
		return parseToolCallResponse(response)
	}

	// MARK: - 状态查询

	/// 返回当前状态摘要。
	func statusSummary() -> [String: String] {
		[
			"name": endpoint.name,
			"status": status.rawValue,
			"command": endpoint.stdioCommand,
			"lastError": lastError ?? "(none)",
		]
	}

	// MARK: - 内部方法

	/// 启动子进程。
	private func launchProcess(
		stdin: Pipe,
		stdout: Pipe,
	) throws -> Process {
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		proc.arguments = [endpoint.stdioCommand] + endpoint.stdioArgs

		proc.standardInput = stdin
		proc.standardOutput = stdout
		// stderr 重定向到 /dev/null，由 Process 内部管理
		proc.standardError = nil

		try proc.run()
		return proc
	}

	/// 发送 MCP initialize 请求。
	private func sendInitialize() async throws {
		_ = try await request("initialize", params: [
			"protocolVersion": "2024-11-05",
			"capabilities": ["roots": ["listChanged": true]],
			"clientInfo": [
				"name": "ocoreai-mcp-bridge",
				"version": "0.7.0",
			],
		])
		// 发送 initialized notification（忽略响应）
		let notifJSON = try serializeJSON(["jsonrpc": "2.0", "method": "notifications/initialized"])
		_ = await transport.writeDirect(notifJSON)
	}

	/// 等待从管道读取一行 JSON-RPC 响应。
	private func waitForResponse() async throws -> String {
		let deadline = ContinuousClock.now + .milliseconds(15000)
		while ContinuousClock.now < deadline {
			guard let line = await transport.readLine(), !line.isEmpty else {
				try await Task.sleep(for: .milliseconds(100))
				continue
			}
			// 检查是否是 JSON-RPC 错误响应
			if let data = line.data(using: .utf8),
			   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			   let error = obj["error"] as? [String: Any]
			{
				let msg = error["message"] as? String ?? "Unknown error"
				throw MCPClientError.protocolError(msg)
			}
			return line
		}
		throw MCPClientError.timeout(endpoint.name)
	}

	/// 清理子进程与传输层。
	private func cleanup() async {
		cleanupProcess()
		await transport.close() // Actor close() handles pipe cleanup internally
		status = .disconnected
		process = nil
	}

	/// 安全终止子进程。
	private func cleanupProcess() {
		guard let proc = process else { return }
		if proc.isRunning {
			proc.terminate()
		}
		process = nil
	}

	// MARK: - JSON 工具方法

	private func serializeJSON(_ obj: [String: Any]) throws -> String {
		let data = try JSONSerialization.data(withJSONObject: obj, options: .sortedKeys)
		return String(decoding: data, as: UTF8.self)
	}

	/// 解析 tools/list 响应体。
	private func parseToolsListResponse(_ json: String) -> [[String: Any]] {
		guard let data = json.data(using: .utf8),
		      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let result = obj["result"] as? [String: Any],
		      let list = result["tools"] as? [[String: Any]]
		else {
			return []
		}
		return list
	}

	/// 解析 tools/call 响应体（Sendable 兼容）。
	private func parseToolCallResponse(_ json: String) -> [[String: String]] {
		guard let data = json.data(using: .utf8),
		      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let result = obj["result"] as? [String: Any],
		      let content = result["content"] as? [[String: Any]]
		else {
			return [["type": "text", "text": "Failed to parse response"]]
		}
		// 转换为 [String: String] 保证 Sendable
		return content.map { block -> [String: String] in
			var result: [String: String] = [:]
			for (key, value) in block {
				result[key] = String(describing: value)
			}
			return result
		}
	}
}

/// 外部 MCP 客户端错误
enum MCPClientError: Error, LocalizedError {
	case notConnected(String)
	case timeout(String)
	case protocolError(String)

	var errorDescription: String? {
		switch self {
		case let .notConnected(name):
			"MCP client for '\(name)' is not connected"
		case let .timeout(name):
			"Request timed out for MCP client '\(name)'"
		case let .protocolError(detail):
			"MCP protocol error: \(detail)"
		}
	}
}
