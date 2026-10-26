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
    /// 端点支持的最高 MCP spec 版本（initialize 时声明，server 选不晚于此的版本）。
    ///
    /// **2025-06-18** 为本 client 的消费能力边界：
    /// - form-mode elicitation（`elicitation/create`）于该版本引入（spec 原文
    ///   "newly introduced in this version"；codex legacy 基线同为 V_2025_06_18）；
    /// - URL-mode elicitation（2025-11-25+）/ message limits（2026-07-28）
    ///   为后续版本新增面，本 client 未消费，故不声明该两版本。
    static let supportedProtocolVersion = "2025-06-18"
    /// initialize 协商结果：server 回选定的 protocolVersion（`nil` = 响应格式异常）。
    private(set) var negotiatedProtocolVersion: String?
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
    /// 入站请求（server→client）应答：返回要写回的响应行，`nil` = 不应答
    /// （notification / 无法应答）。接入后 `waitForResponse` 把带 method 的行
    /// 全部先路由至此——无此路由层时，elicit 行会被误当
    /// tools/call 响应消费（elicitation server 挂死 / 调用返回错乱垃圾）。
    private let incomingRequestHandler: (@Sendable (String) async -> String?)?
    /// 已应答的入站请求计数（按 method）——精确值测试断言面（elicit→1、ping→1）。
    private(set) var inboundResponses: [String: Int] = [:]

    /// 本次连接生效的两条预算，构造时一次定稿（来源 = endpoint 覆盖 → bridge config →
    /// ``MCPTimeouts`` 硬默认）。这是本仓唯一决定"外部 server 能等多久"的地方——旧写法把
    /// `15` 抄在两处，且 config 里那个 knob 无人读取。
    private let budgets: MCPRPCBudgets

    /// 子进程 stderr 的有界尾部（诊断证据的存放处）。写侧是 ``startStderrDrain`` 起的
    /// drain 线程，读侧是本 actor：同一个对象，所以"报出去的死因"和"收到的死因"
    /// 不可能分叉（AGENTS.md：一个决定一个家）。
    private let stderrTail = MCPStderrTail()

    // MARK: - 初始化

    init(
        endpoint: MCPEndpoint,
        transport: MCPStdioTransport,
        log: Logger = Logger(label: "ocoreai.mcp.client"),
        incomingRequestHandler: (@Sendable (String) async -> String?)? = nil,
        configStartupTimeout: TimeInterval? = nil,
        configToolTimeout: TimeInterval? = nil,
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.log = log
        self.incomingRequestHandler = incomingRequestHandler
        self.budgets = MCPRPCBudgets.resolve(
            endpointStartup: endpoint.startupTimeoutSeconds,
            endpointTool: endpoint.toolTimeoutSeconds,
            configStartup: configStartupTimeout,
            configTool: configToolTimeout)
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
    func request(
        _ method: String, params: [String: Any]?, phase: MCPRPCPhase = .tool
    ) async throws -> String {
        // 断连/错误状态 → 直接抛错（不重试 — 对齐 codex: reconnect_failed_startup 后保持断开）
        if status != .connected {
            throw MCPClientError.notConnected(endpoint.name, stderr: stderrTail.snapshot())
        }
        // 子进程意外退出检测（status==.connected 但 process 已死）→ 自动重连
        #if os(macOS)
        if let process = process, !process.isRunning {
            try await reconnectOrFail()
        }
        #endif
        let id = nextID
        nextID += 1
        return try await sendRPC(
            id: id, method: method, params: params, timeout: timeout(for: phase))
    }

    /// 一次请求用哪条预算：握手/发现走 startup，工具调用走 tool。
    /// 判据写在类型上，调用点就不必各自记一个数（AGENTS.md：一个决定一个家）。
    private func timeout(for phase: MCPRPCPhase) -> TimeInterval {
        switch phase {
        case .startup: budgets.startupSeconds
        case .tool: budgets.toolSeconds
        }
    }

    /// 不走状态守卫的原始 RPC（内部握手 initialize 用 — 此时 status 尚未 .connected）。
    private func sendRPC(
        id: Int, method: String, params: [String: Any]?, timeout: TimeInterval
    ) async throws -> String {
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
        return try await withTimeout(seconds: timeout) {
            try await self.waitForResponse(timeout: timeout)
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
                return .failure(
                    MCPClientError.timeout(
                        self.endpoint.name, seconds, stderr: self.stderrTail.snapshot()))
            }

            for try await result in group {
                group.cancelAll()
                switch result {
                case .success(let value): return value
                case .failure(let error): throw error
                }
            }
            throw MCPClientError.timeout(self.endpoint.name, seconds, stderr: stderrTail.snapshot())
        }
    }

    /// 列出外部 server 提供的工具。
    func listTools() async throws -> [[String: Any]] {
        let response = try await request("tools/list", params: [:], phase: .startup)
        return parseToolsListResponse(response)
    }

    /// 列出外部 server 提供的工具（返回原始 JSON 字符串，Sendable-safe）。
    func listToolsRaw() async throws -> String {
        try await request("tools/list", params: [:], phase: .startup)
    }

    /// 调用外部 server 上的工具。\
    /// - Returns: 工具执行结果内容数组。
    func callTool(_ name: String, arguments: [String: Any]) async throws -> [[String: String]] {
        let params: [String: Any] = ["name": name, "arguments": arguments]
        let response = try await request("tools/call", params: params)
        return parseToolCallResponse(response)
    }

    // MARK: - 状态查询

    /// 生效预算的跨 actor 出口：actor 的存储属性不可被外部直接引用，把出口收敛成一个
    /// 方法，判据与读数就还是同一个家（测试与 bridge 日志都从这里读）。
    func budget() -> MCPRPCBudgets { budgets }

    /// 返回当前状态摘要。
    func statusSummary() -> [String: String] {
        [
            "name": endpoint.name,
            "status": status.rawValue,
            "command": endpoint.stdioCommand,
            "lastError": lastError ?? "(none)",
            // 公布生效预算：超时是会改变调用方行为的量，只写在代码里就等于没写
            // （AGENTS.md：写进值里的效果要有读这个值的门）。
            "startupTimeout": MCPTimeouts.describe(budgets.startupSeconds),
            "toolTimeout": MCPTimeouts.describe(budgets.toolSeconds),
        ]
    }

    // MARK: - 内部方法

    /// 启动子进程。
    #if os(macOS)
    private func launchProcess(
        stdin: Pipe,
        stdout: Pipe,
        stderr: Pipe,
    ) throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [endpoint.stdioCommand] + endpoint.stdioArgs

        proc.standardInput = stdin
        proc.standardOutput = stdout
        // stderr 交给 drain 线程收进有界尾部。旧写法 `= nil` 让 Foundation 把子进程
        // stderr 接到 /dev/null：启动即崩的 server 只剩一句 "exited with status N"，
        // 而那几行 stderr 正是死因（ModuleNotFoundError / MODULE_NOT_FOUND / bind 冲突）。
        proc.standardError = stderr

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
        let resp = try await sendRPC(
            id: 0, method: "initialize",
            params: [
                "protocolVersion": Self.supportedProtocolVersion,
                "capabilities": [
                    "roots": ["listChanged": true],
                    // MCP spec (2025-06-18, client/elicitation): Clients that support
                    // elicitation MUST declare the elicitation capability during
                    // initialization.
                    "elicitation": [:] as [String: Any],
                ],
                "clientInfo": [
                    "name": "ocoreai-mcp-bridge",
                    // The bridge IS the app — peer-visible identity must match
                    // the artifact on disk, never a frozen literal.
                    "version": AppInfo.shortVersion,
                ],
            ],
            timeout: budgets.startupSeconds)
        // 消费协商结果：server 回选定的 protocolVersion（旧实现直接丢弃）。
        self.negotiatedProtocolVersion =
            Self.parsedProtocolVersion(from: resp)
        // 发送 initialized notification（忽略响应）
        let notifJSON = try serializeJSON(["jsonrpc": "2.0", "method": "notifications/initialized"])
        _ = await transport.writeDirect(notifJSON)
    }

    /// 从 initialize 响应里提取 negotiated `protocolVersion`（`{"result":{"protocolVersion":...}}`）。
    static func parsedProtocolVersion(from responseJSON: String) -> String? {
        guard
            let data = responseJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = obj["result"] as? [String: Any]
        else { return nil }
        return result["protocolVersion"] as? String
    }

    /// 等待从管道读取一行 JSON-RPC **响应**（入站请求先应答并丢弃，继续等）。
    ///
    /// 每次循环迭代都检测：
    /// - `Task.isCancelled`：外层 withTimeout 的 cancelAll() 生效 → 立即退出，不空转。
    /// - 死进程：子进程已退出 → 管道已 EOF，读回 nil 无意义，直接判错交上层重连。
    /// - **入站请求**（带 method）：路由给 `incomingRequestHandler` 应答后继续等——
    ///   MCP stdio 是双向通道，elicitation server 会在 tools/call 响应之前
    ///   发 `elicit`/`ping` 请求（codex `555b82afa9` user-verification）。
    ///   旧缺陷：无应答面 → 这些行要么被误当响应返回（调用结果错乱），
    ///   要么 server 永久等待（挂死）。
    private func waitForResponse(timeout: TimeInterval) async throws -> String {
        // 这里**不再**自带一条死线：死线唯一的主人是调用方 sendRPC 的 withTimeout
        // （第二个家会让 config 无论填什么都白填）。循环能收口靠两点：
        // `transport.readLine()` 单次有界等待 ≤50ms（MCPStdioTransport.readLine 契约），
        // 且每轮开头查 Task.isCancelled —— 外层 cancelAll 生效即退出。
        while true {
            if Task.isCancelled {
                throw MCPClientError.timeout(endpoint.name, timeout, stderr: stderrTail.snapshot())
            }
            // 死进程守卫：子进程已退出 → 管道已 EOF，读取会永久阻塞。
            #if os(macOS)
            if let proc = process, !proc.isRunning {
                throw MCPClientError.childExited(
                    proc.terminationStatus, stderr: await stderrEvidence())
            }
            #endif
            guard let line = await transport.readLine(), !line.isEmpty else {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            // 入站请求（server→client，带 method）：应答并丢弃，不返回给调用方。
            if let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let method = obj["method"] as? String
            {
                if let handler = incomingRequestHandler {
                    if let response = await handler(line) {
                        _ = await transport.writeDirect(response)
                        inboundResponses[method, default: 0] += 1
                        log.info("Responded to inbound '\(method)' from '\(endpoint.name)'")
                    }
                } else {
                    log.warning("Dropping unhandled inbound '\(method)' from '\(endpoint.name)'")
                }
                continue
            }
            // 检查是否是 JSON-RPC 错误响应
            if let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let error = obj["error"] as? [String: Any]
            {
                let msg = error["message"] as? String ?? "Unknown error"
                throw MCPClientError.protocolError(msg, stderr: stderrTail.snapshot())
            }
            return line
        }
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

    /// 起一条 drain 收 stderr：写进 ``MCPStderrTail``，并逐行落日志（codex
    /// `executor_process_transport.rs:465-487` 两件事都做——日志是给现场的，尾部是给
    /// 这一次调用方的拒绝文案的）。
    ///
    /// 用阻塞 `read(2)` 而不是 `FileHandle.read(upToCount:)`：后者在本机 macOS 27 beta 上
    /// 实测 13–23s/行（``MCPStdioTransport`` 头部记着同一条实测，stdout 侧早已改原始 fd）。
    /// 线程生命周期由管道决定：孩子退出 ⇒ 写端关闭 ⇒ `read` 回 0 ⇒ 线程自己收口；闭包
    /// **强持有** `Pipe`，所以线程在读的时候 fd 不可能被 Foundation 的 deinit 提前关掉。
    /// 不做手动 `close`：`Pipe` 释放时关 fd，手动再关一次会误伤已复用的 fd 号。
    private func startStderrDrain(_ pipe: Pipe) {
        let tail = stderrTail
        let log = self.log
        let program = endpoint.stdioCommand
        // `.userInitiated`, not `.utility`: the drain's output is the sentence a caller reads
        // at the moment of failure, and at utility QoS a loaded host starved it past the whole
        // evidence window (measured 10-26, full suite: 150 ms after a child's exit the tail
        // held 0 lines and had not reached EOF -- the block had not started). The bytes are
        // not lost, they sit in the pipe; only the diagnosis was late.
        DispatchQueue.global(qos: .userInitiated).async {
            let fd = pipe.fileHandleForReading.fileDescriptor
            guard fd >= 0 else {
                _ = tail.finish()
                return
            }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    for line in tail.append(Data(buffer[0 ..< n])) {
                        log.info("MCP server stderr (\(program)): \(line)")
                    }
                    continue
                }
                if n < 0, errno == EINTR { continue }
                break  // n == 0：EOF（孩子退出/关掉 stderr）；其余错误同样按结束处理
            }
            if let last = tail.finish() {
                log.info("MCP server stderr (\(program)): \(last)")
            }
        }
    }

    /// 取证据。已有证据、或管道已 EOF（确实没写过）→ 立刻返回，不白等；只有"孩子刚死、
    /// 最后几行可能还压在管道里"这一种情况会轮询，上限 40×25ms=1s（读侧要到 EOF 才收
    /// 剩下字节；探针量的是秒级，这点窗口不改变任何预算）。
    ///
    /// 刻意写成**次数**而不是 `ContinuousClock.now + …`：本文件的门
    /// （`MCPTimeoutDeliveryTests.scanFloors`）规定"响应等待只能有一条死线，且归调用方"。
    /// 这不是响应等待而是一次有界收尾轮询——写成次数既不去撞那条规则，也不会哪天被读成
    /// 第二个预算家（同一个文件里出现第二条绝对死线，正是那个 gate 存在的理由）。
    private func stderrEvidence() async -> String? {
        if let early = stderrTail.snapshot() { return early }
        if stderrTail.isEnded() { return nil }
        // 1 s of 25 ms looks, not 150 ms: the first look is free when the tail already has
        // bytes, and the ceiling exists for the one case the probe caught -- a drain block the
        // scheduler had not started 150 ms after the child died. Counted, not clocked, so this
        // stays a bounded clean-up poll and never reads as a second response deadline
        // (`MCPTimeoutDeliveryTests.scanFloors` owns that rule).
        for _ in 0 ..< 40 {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(25))
            if stderrTail.isEnded() || stderrTail.snapshot() != nil { break }
        }
        return stderrTail.snapshot()
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
            let stderrPipe = Pipe()
            // 新一个孩子 = 新账：上一轮的死因不得混进这一轮的诊断。
            stderrTail.reset()
            let proc = try launchProcess(stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe)
            process = proc
            startStderrDrain(stderrPipe)
            await transport.configurePipeMode(stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
            try await sendInitialize()
            status = .connected
            log.info("Connected to '\(endpoint.name)' (pid: \(proc.processIdentifier))")
        } catch {
            process = nil
            status = .error
            // 类型与证据都要留：旧写法把 .childExited / .timeout 一律压成 .protocolError，
            // 上层从此分不出"崩了"与"没答"，而死因也被丢在 /dev/null 里。
            let enriched: MCPClientError
            if let mcp = error as? MCPClientError {
                enriched = mcp.withStderr(await stderrEvidence())
            } else {
                enriched = MCPClientError.protocolError(
                    error.localizedDescription, stderr: await stderrEvidence())
            }
            lastError = enriched.localizedDescription
            log.error("Connection failed for '\(endpoint.name)': \(enriched)")
            throw enriched
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
            // 重连失败也要带证据：新孩子的 stderr 就是"为什么叫不醒"的答案。
            throw MCPClientError.notConnected(endpoint.name, stderr: await stderrEvidence())
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

    /// 入站请求应答计数（按 method）——精确值测试断言面（elicit→1、ping→1）。
    func testInboundResponses() -> [String: Int] { inboundResponses }

    /// 子进程 stderr 尾部快照（测试断言面：证据是否真被收下、是否被截断）。
    func testStderrTail() -> String? { stderrTail.snapshot() }

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
    /// 委托 `MCPBridge.parseToolCallJSON` — structuredContent 优先级链（codex 基准）单一真源。
    private func parseToolCallResponse(_ json: String) -> [[String: String]] {
        return MCPBridge.parseToolCallJSON(json)
    }
}

/// 外部 MCP 客户端错误
enum MCPClientError: Error, LocalizedError {
    /// 未连接。`stderr` = 最近一次连接尝试里子进程自己留下的证据（nil = 确实没有）。
    case notConnected(String, stderr: String?)
    /// 超时：带上**生效的那条预算**，因为"多久算超时"是调用方需要知道的契约量，
    /// 只报"timed out"会让人去查一个代码里根本不存在的默认值（旧文案就是这样）。
    case timeout(String, TimeInterval, stderr: String?)
    case protocolError(String, stderr: String?)
    /// 子进程已退出（termination status 携带）——上层据此区分"重连/放弃"。
    case childExited(Int32, stderr: String?)
    case platformNotSupported

    // 无证据的同名构造：绝大多数站点确实拿不到 stderr，在每个调用点写 `nil` 只是噪声，
    // 而"带证据"的那几个点必须显式写出来——它们正是这套诊断的意义所在。
    static func notConnected(_ name: String) -> MCPClientError { .notConnected(name, stderr: nil) }
    static func timeout(_ name: String, _ seconds: TimeInterval) -> MCPClientError {
        .timeout(name, seconds, stderr: nil)
    }
    static func protocolError(_ detail: String) -> MCPClientError {
        .protocolError(detail, stderr: nil)
    }
    static func childExited(_ status: Int32) -> MCPClientError { .childExited(status, stderr: nil) }

    /// 这条诊断携带的 stderr 证据（`nil` = 确实没有，不编一段"大概是因为"）。
    var stderrEvidence: String? {
        switch self {
        case .notConnected(_, let tail), .protocolError(_, let tail): return tail
        case .timeout(_, _, let tail), .childExited(_, let tail): return tail
        case .platformNotSupported:
            return nil
        }
    }

    /// 把证据折进诊断——唯一落点。已有证据就不覆盖：同一死因说两遍等于没说
    /// （`attemptConnection` 会把内层已带证据的错误再包一次，靠这里挡住重复）。
    func withStderr(_ tail: String?) -> MCPClientError {
        guard let tail, !tail.isEmpty else { return self }
        switch self {
        case .notConnected(let name, let existing):
            return .notConnected(name, stderr: existing ?? tail)
        case .timeout(let name, let seconds, let existing):
            return .timeout(name, seconds, stderr: existing ?? tail)
        case .protocolError(let detail, let existing):
            return .protocolError(detail, stderr: existing ?? tail)
        case .childExited(let status, let existing):
            return .childExited(status, stderr: existing ?? tail)
        case .platformNotSupported: return self
        }
    }

    /// 结论本身（不含证据）——这些文案的唯一落点，别再抄第二份。
    var headline: String {
        switch self {
        case .notConnected(let name, _):
            "MCP client for '\(name)' is not connected"
        case .timeout(let name, let seconds, _):
            "MCP server '\(name)' did not answer within \(MCPTimeouts.describe(seconds))"
        case .protocolError(let detail, _):
            "MCP protocol error: \(detail)"
        case .childExited(let code, _):
            "MCP server process exited with status \(code)"
        case .platformNotSupported:
            "MCP stdio subprocess is not supported on this platform"
        }
    }

    /// 结论 + 证据：没有 stderr 时与过去的文案逐字相同（追加，不改写）。
    var errorDescription: String? {
        guard let tail = stderrEvidence, !tail.isEmpty else { return headline }
        return "\(headline) — stderr: \(tail)"
    }
}

/// 一条外部 MCP 连接生效的响应预算（秒）。
///
/// Sendable + 一个出口方法：actor 的存储属性跨 actor 读不到，把"读生效值"收敛成
/// 一个类型，公布面、日志和测试读的就是引擎真正用的那两个数，而不是第二份抄件。
struct MCPRPCBudgets: Sendable, Equatable {
    let startupSeconds: TimeInterval
    let toolSeconds: TimeInterval

    /// **唯一**的预算解析点：client 用它装配自己，bridge 的 ledger 在还没连上时用它公布
    /// "将要生效的那两个数"。两处读的是同一条规则，门面就不可能报一个引擎没用的数。
    ///
    /// 越界的 wire 值已经在 `$bridge/endpoint/connect` 被拒（命名字段+区间+原值）；这里再
    /// 钳进 allowedRange，是让"调用方的一个 bug"只损失一次取整而不是买一次挂死。
    static func resolve(
        endpointStartup: TimeInterval?,
        endpointTool: TimeInterval?,
        configStartup: TimeInterval?,
        configTool: TimeInterval?
    ) -> MCPRPCBudgets {
        MCPRPCBudgets(
            startupSeconds: MCPTimeouts.clamped(
                endpointStartup ?? configStartup ?? MCPTimeouts.startupDefault),
            toolSeconds: MCPTimeouts.clamped(
                endpointTool ?? configTool ?? MCPTimeouts.toolDefault))
    }

    /// 一行可读形态，供日志用（`Logger.Message` 不吃跨行的字面量拼接）。
    var logWord: String {
        "startupTimeout=\(MCPTimeouts.describe(startupSeconds)) toolTimeout=\(MCPTimeouts.describe(toolSeconds))"
    }
}

/// 一次 JSON-RPC 走哪条响应预算。判据写成类型，两个数各有一个家。
enum MCPRPCPhase {
    /// 握手与发现：`initialize`、`tools/list`。
    case startup
    /// 任务本身：`tools/call`。
    case tool
}
