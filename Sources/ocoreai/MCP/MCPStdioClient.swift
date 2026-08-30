// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MCP Stdio Client — 通过 stdio 管道连接外部 MCP server 子进程。
///
/// 生命周期的每一步都经过 actor mailbox，确保并发安全。
/// 子进程通过 Foundation.Process + Pipe 管理，
/// 读写侧与 ``MCPStdioTransport`` 管道模式对接。
///
/// Note: MCP stdio subprocess is macOS-only (Process unavailable on iOS).
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
    #if os(macOS)
    /// 子进程句柄
    private var process: Process?
    #else
    /// iOS: no Process support — connection always fails
    private var processHandle: Int?
    #endif
    /// 传输层（管道模式）
    private let transport: MCPStdioTransport
    /// 日志
    private let log: Logger
    /// 最后错误
    private var lastError: String?
    /// jsonrpc 请求 id 计数器
    private var nextID: Int = 0
    /// 手动 disconnect 标记：true 时 request() 不自动重连，保持断开。
    /// 子进程意外退出时此值为 false → request() 自动重连（对齐 codex reconnect_failed_startup）。
    private var manualDisconnect: Bool = false
    /// 成功重连次数（精确值断言）：reconnectOrFail() 成功时 +=1，
    /// connect()（首次/手动重连）成功时重置 0；失败不计入。
    private(set) var reconnectionAttempts: Int = 0
    /// 子进程最近一次退出信号号（SIGTERM=15 等）；正常退出时为退出码本身。精确值测试锚点。
    private(set) var childExitStatus: Int32?

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
        #if os(iOS)
        throw MCPClientError.platformNotSupported
        #endif

        #if os(macOS)
        guard process == nil else {
            log.warning("Already connected to '\(endpoint.name)'")
            return
        }
        // 手动重连 / 首次连接：清除 disconnect 标记 + 重置重连计数后统一走 attemptConnection。
        manualDisconnect = false
        reconnectionAttempts = 0
        try await attemptConnection()
        #endif
    }

    /// 断开连接（终止子进程）。\
    func disconnect() async {
        log.info("Disconnecting from '\(endpoint.name)'")
        manualDisconnect = true
        await cleanup()
    }

    // MARK: - JSON-RPC 交互

    /// 发送 JSON-RPC 请求并等待响应（带状态/断连守卫）。\
    /// - Parameters:
    ///   - method: JSON-RPC 方法名\
    ///   - params: 请求参数字典\
    /// - Returns: 响应 JSON 字符串。\
    /// - Throws: 协议错误或超时。\
    func request(_ method: String, params: [String: Any]?) async throws -> String {
        // 断连/错误状态 → 直接抛错（不重试 — 对齐 codex: reconnect_failed_startup 后保持断开）
        if status != .connected {
            throw MCPClientError.notConnected(endpoint.name)
        }
        // 子进程意外退出检测（status==.connected 但 process 已死）→ 自动重连
        #if os(macOS)
        if let process = process, !process.isRunning {
            try await reconnectOrFail()
        }
        #endif
        let id = nextID
        nextID += 1
        return try await sendRPC(id: id, method: method, params: params)
    }

    /// 不走状态守卫的原始 RPC（内部握手 initialize 用 — 此时 status 尚未 .connected）。
    private func sendRPC(id: Int, method: String, params: [String: Any]?) async throws -> String {
        var req: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "id": id,
        ]
        if let params {
            req["params"] = params
        }
        let reqJSON = try serializeJSON(req)
        _ = await transport.writeDirect(reqJSON)
        return try await withTimeout(seconds: 15) {
            try await self.waitForResponse()
        }
    }

    /// 超时包装器：并发执行操作与定时器，取先完成者。
    private func withTimeout(
        seconds: Double, operation: @Sendable @escaping () async throws -> String
    ) async throws -> String {
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
                case .success(let value): return value
                case .failure(let error): throw error
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

    /// 调用外部 server 上的工具。\
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
    #if os(macOS)
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

        // 子进程退出 → 精确值捕获 termination status（重连检测锚点）
        proc.terminationHandler = { [weak self] proc in
            self?.onChildExit(proc)
        }

        try proc.run()
        return proc
    }
    #endif

    /// 发送 MCP initialize 请求。
    private func sendInitialize() async throws {
        _ = try await sendRPC(
            id: 0, method: "initialize",
            params: [
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
    ///
    /// 每次循环迭代都检测：
    /// - `Task.isCancelled`：外层 withTimeout 的 cancelAll() 生效 → 立即退出，不空转。
    /// - 死进程：子进程已退出 → 管道已 EOF，读回 nil 无意义，直接判错交上层重连。
    private func waitForResponse() async throws -> String {
        let deadline = ContinuousClock.now + .milliseconds(15000)
        while ContinuousClock.now < deadline {
            if Task.isCancelled {
                throw MCPClientError.timeout(endpoint.name)
            }
            // 死进程守卫：子进程已退出 → 管道已 EOF，读取会永久阻塞。
            #if os(macOS)
            if let proc = process, !proc.isRunning {
                throw MCPClientError.childExited(proc.terminationStatus)
            }
            #endif
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
        await transport.close()  // Actor close() handles pipe cleanup internally
        status = .disconnected
        #if os(macOS)
        process = nil
        #else
        processHandle = nil
        #endif
    }

    // MARK: - 子进程生命周期（重连检测 + 自动恢复）

    /// termination handler：子进程退出时调用（由 Process 在内部线程调度，
    /// 通过 Task 跳回 actor 隔离域）。
    /// - 手动 disconnect 后：仅记录状态，不触发重连。
    /// - 意外退出：status 保持 `.connected`（等待下次 request() 检测 + 重连），
    ///   捕获 termination status 供精确值测试。
    /// Process iOS 不可用 → 调用方 launchProcess 亦 os(macOS)，此处同门控。
    #if os(macOS)
    nonisolated private func onChildExit(_ proc: Process) {
        let code: Int32 = proc.terminationStatus
        let signal: Int32 = proc.terminationReason == .uncaughtSignal ? proc.terminationStatus : 0
        // 跳回 actor 域更新状态
        Task {
            await self.applyChildExit(status: code, signal: signal)
        }
    }
    #endif

    private func applyChildExit(status: Int32, signal: Int32) {
        self.childExitStatus = signal != 0 ? signal : status
        // status 不变（.connected → 下次 request() 检测 process.isRunning==false）
        // reconnectionAttempts 不在此处递增 — 由 reconnectOrFail() 每次尝试递增、
        // attemptConnection() 成功后重置，防止意外退出路径误计。
    }

    /// 从意外退出状态恢复连接。
    /// 成功 → `.connected`；失败 → `.error`（后续 request() 直接抛错，不重试 —
    /// 对齐 codex rmcp_client reconnect_failed_startup 语义）。
    private func connectViaPipeline() async throws {
        #if os(macOS)
        try await attemptConnection()
        #else
        throw MCPClientError.platformNotSupported
        #endif
    }

    /// 执行一次完整的连接尝试（启动子进程 + initialize）。
    /// 成功 → `.connected` + 重置 reconnectionAttempts；失败 → `.error`。
    private func attemptConnection() async throws {
        #if os(macOS)
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
            await transport.configurePipeMode(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
            try await sendInitialize()
            status = .connected
            log.info("Connected to '\(endpoint.name)' (pid: \(proc.processIdentifier))")
        } catch {
            process = nil
            status = .error
            lastError = error.localizedDescription
            log.error("Connection failed for '\(endpoint.name)': \(error)")
            throw MCPClientError.protocolError(error.localizedDescription)
        }
        #else
        throw MCPClientError.platformNotSupported
        #endif
    }

    func reconnectOrFail() async throws {
        #if os(macOS)
        // 子进程已退出 — cleanup 后重连
        if let proc = process {
            _ = proc.terminationStatus  // 确保 terminationStatus 已同步
            // 若子进程还在（极端竞态）→ SIGKILL 确保不再卡管道
            if proc.isRunning { proc.interrupt() }
            process = nil
            await transport.close()
        }
        status = .disconnected
        do {
            try await connectViaPipeline()
            reconnectionAttempts += 1  // 仅成功重连计数
        } catch {
            status = .error
            throw MCPClientError.notConnected(endpoint.name)
        }
        #else
        throw MCPClientError.platformNotSupported
        #endif
    }

    // MARK: - Test hooks（精确值测试驱动重连路径，模拟子进程意外崩溃）

    /// 终止子进程（模拟意外崩溃），不触发 cleanup — 保留 process 句柄 +
    /// status==.connected，使下次 request() 能命中检测路径并自动重连。
    func testTerminateChild() {
        #if os(macOS)
        process?.terminate()
        #endif
    }

    /// 子进程是否仍在运行（测试轮询锚点）。
    func testChildRunning() -> Bool {
        #if os(macOS)
        return process?.isRunning ?? false
        #else
        return false
        #endif
    }

    /// 子进程 PID（测试断言新旧进程不同）。
    func testChildPID() -> Int32 {
        #if os(macOS)
        return process?.processIdentifier ?? -1
        #else
        return -1
        #endif
    }

    /// 最后一次错误描述（测试断言精确值）。
    func testLastError() -> String? { lastError }

    /// 安全终止子进程。
    private func cleanupProcess() {
        #if os(macOS)
        guard let proc = process else { return }
        if proc.isRunning {
            proc.terminate()
        }
        #endif
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
    /// 子进程已退出（termination status 携带）——上层据此区分"重连/放弃"。
    case childExited(Int32)
    case platformNotSupported

    var errorDescription: String? {
        switch self {
        case .notConnected(let name):
            "MCP client for '\(name)' is not connected"
        case .timeout(let name):
            "Request timed out for MCP client '\(name)'"
        case .protocolError(let detail):
            "MCP protocol error: \(detail)"
        case .childExited(let code):
            "MCP server process exited with status \(code)"
        case .platformNotSupported:
            "MCP stdio subprocess is not supported on this platform"
        }
    }
}
