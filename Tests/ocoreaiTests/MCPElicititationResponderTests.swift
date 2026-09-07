// MCPElicititationResponderTests.swift — 09-07 MCP server 入站请求应答（Red→Green）
//
// 缺陷（代码即文档）：MCP stdio 是**双向** JSON-RPC 通道。旧的
// `MCPStdioClient.waitForResponse()` 只认第一行 JSON-RPC——外部 elicitation
// server 发来的**入站请求**（`elicit` user-verification / `ping`）没有
// method 匹配层，被两种错误消费：
//   1. 被当作自己请求的响应返回 → server 永远拿不到 accept/decline，
//      工具调用挂死（MCP elicitation spec：server 可无限等待）；
//   2. 无 result 的入站请求 → 误抛 protocolError 中断调用。
// 上游参照：codex `555b82afa9` "Add opt-in MCP user-verification transport"
// —— verification 请求路由 approval surface，**不静默 cancel**；
// response 形状 `{"action":"accept"|"decline", "content":{...}}`。
//
// 纪律：Python stdio stub 驱动**生产同路**
// （`MCPBridge.connectEndpoint` → `routeToolCall` → `MCPStdioClient` →
// `waitForResponse` 的入站请求分流），断言精确值：
//   - elicit 应答 = **accept**（policy `.auto` broker 语义：不问放行）；
//   - ping 应答 = **非 nil 的 `{}`**（MCP spec 空 result）；
//   - client 侧计数 elicit→1、ping→1（精确值，非 >0）。
// 旧的无应答面实现在 `.auto` 下：`tools/call` 返回的响应行里根本没有
// `elicit_result=` 字段（server 因收不到 accept 挂死）→ 超时 30s 失败。

import Foundation
import Logging
import Testing

@testable import ocoreai

// MARK: - Stub server（elicit / ping 应答后才回 tools/call 结果）

/// Python stdio stub：
/// - `initialize` → 2024-11-05 握手
/// - `tools/list` → 单个工具 `elicit_gate`
/// - `tools/call` → **先**发 `elicit` 入站请求（form 形态，requestedSchema）
///   + `ping` 入站请求，**等两条应答都收到**才返回最终 tools/call 结果，
///   应答 shape 原样回显在结果文本（`elicit_result=...|ping_result=...`）
///   → 接受/拒绝 / 空 result 精确断言面。
///
/// 旧缺陷（无应答面 client）在此 stub 下必挂死：
/// elicit 行被 `waitForResponse` 当成 tools/call 响应消费 → server 等不到
/// accept，最终结果永不产出。这是**行为**断言（非接口）：若 client 未
/// 正确应答两条入站请求，tools/call 就无返回。
private func writeElicitationStub() throws -> URL {
    let code = #"""
        #!/usr/bin/env python3
        import sys, json, threading

        TOOLS = [{"name": "elicit_gate",
                  "description": "gated by elicitation",
                  "inputSchema": {"type": "object", "properties": {}}}]
        def out(o):
            sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
        replies = {"elicit": None, "ping": None}
        pending = None  # tools/call 的 id + 参数
        def read_line():
            try:
                l = sys.stdin.readline()
            except Exception:
                return None
            return l.strip() if l else None
        # 主循环：逐行处理 stdin 的 client 消息
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue
            method = msg.get("method", "")
            mid = msg.get("id")
            if method == "initialize":
                out({"jsonrpc": "2.0", "id": mid,
                     "result": {"protocolVersion": "2024-11-05",
                                "capabilities": {"tools": {}},
                                "serverInfo": {"name": "elicit-stub", "version": "0.1"}}})
            elif method.startswith("notifications/"):
                pass
            elif method == "tools/list":
                out({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
            elif method == "tools/call":
                pending = mid
                # server→client 入站请求（MCP elicitation spec §elicit）
                out({"jsonrpc": "2.0", "id": 100, "method": "elicit",
                     "params": {"message": "Confirm action?",
                                "requestedSchema": {
                                    "type": "object",
                                    "properties": {"confirmed": {"type": "boolean"}},
                                    "required": ["confirmed"]}}})
                # 同批再发 ping（MCP 健康探测）
                out({"jsonrpc": "2.0", "id": 101, "method": "ping"})
                # 等两条应答都到，回最终 tools/call 结果（应答 shape 原样回显）
                for _ in range(60):
                    rl = read_line()
                    if rl is None:
                        break
                    try:
                        m2 = json.loads(rl)
                    except Exception:
                        continue
                    r = m2.get("result")
                    if m2.get("id") == 100:
                        replies["elicit"] = r if r is not None else "<absent>"
                    elif m2.get("id") == 101:
                        replies["ping"] = r if r is not None else "<absent>"
                    if replies["elicit"] is not None and replies["ping"] is not None:
                        break
                def compact(o):
                    return json.dumps(o, sort_keys=True, separators=(",", ":"))
                out({"jsonrpc": "2.0", "id": pending,
                     "result": {"content": [
                         {"type": "text",
                          "text": "elicit_result=%s|ping_result=%s" % (
                              compact(replies.get("elicit")),
                              compact(replies.get("ping")))}]}})
            else:
                out({"jsonrpc": "2.0", "id": mid, "result": {}})
        """#

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp_elicit_stub_\(UUID().uuidString).py")
    try code.write(to: url, atomically: true, encoding: .utf8)
    return url
}

// MARK: - 结果字段提取

/// 从 `elicit_result=...|ping_result=...` 格式文本里提取 `field=...` 字段值。
private func extractField(_ text: String, _ field: String) -> String {
    for part in text.components(separatedBy: "|") {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\(field)=") {
            return String(trimmed.dropFirst(field.count + 1))
        }
    }
    return ""
}

// MARK: - Suite

@Suite("MCP Server Inbound Requests (elicit / ping)")
struct MCPElicititationResponderTests {
    @MainActor
    private static func makeBridge(policy: ApprovalPolicy) async throws -> MCPBridge {
        let broker = ApprovalBroker(policy: policy)
        let registry = ToolRegistry(approvalBroker: broker, log: Logger(label: "test.elicit"))
        let bridge = MCPBridge(toolRegistry: registry, transport: MCPStdioTransport())
        try await bridge.connectEndpoint(
            name: "mcp-elicit",
            command: "python3",
            args: [try writeElicitationStub().path],
            capabilities: ["tools"],
        )
        return bridge
    }

    /// 有界超时（Testing 无内建 per-test timeout，`30s` 足够覆盖 stub 正常往返）。
    ///
    /// 语义精确：`op` 先于 deadline 完成（成功/失败）→ 原值/原错上抛；
    /// `op` 未能在 deadline 内完成 → 抛 `TimeoutExceeded`（**挂死断言**）。
    /// 非逃逸 `op` 参数先装入本地 `@Sendable` 闭包（合法捕获+调用），再入 task-group。
    static func withTimeout<T: Sendable>(
        seconds: Double,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: Result<T, Error>.self) { group in
            group.addTask {
                do { return .success(try await op()) } catch { return .failure(error) }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return .failure(TimeoutExceeded())
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            switch result {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }
    }

    struct TimeoutExceeded: Error, Sendable {}

    @Test("elicit 入站请求 → accept（policy .auto 语义：不问放行，调用完成不挂死）")
    func elicitRequestAnsweredAccept() async throws {
        let bridge = try await Self.makeBridge(policy: .auto)
        defer { Task { await bridge.disconnectEndpoint(name: "mcp-elicit") } }

        let result = try await Self.withTimeout(seconds: 30) {
            () -> String in try await bridge.routeToolCall("elicit_gate", arguments: "{}")
        }

        #expect(
            result.contains("elicit_result="),
            "结果缺 elicit 应答字段: \(result)")
        let elicitResp = extractField(result, "elicit_result")
        // 精确 shape: {"action":"accept"}（bridge `inboundResponseJSON` 输出，无空格）
        #expect(
            elicitResp.contains("\"action\":\"accept\""),
            "elicit 应答非 accept: \(elicitResp)")
        // ping 应答: {} 空 result（MCP spec 无数据）
        let pingResp = extractField(result, "ping_result")
        #expect(pingResp == "{}", "ping 应答应为空 result {}, 实际: \(pingResp)")
        // 无挂死（挂死 = 超时，已被 withTimeout 捕获）
    }

    @Test("policy .never → 外呼在工具级审批门即被拒——tools/call 不发、server 不发 elicit（两层门语义边界）")
    func neverPolicyBlocksAtToolGate() async throws {
        // `.never`：`securityGate(forExternalTool:)` → broker 立即 `.denied("auto-denied")`
        // → throw → `routeToolCall` re-throw → server 完全无感知，elicit 入站请求根本没机会发出。
        // 锁定"工具级门先于 elicit 入站请求"的两层门边界（elicitation 门在更下游）。
        let bridge = try await Self.makeBridge(policy: .never)
        defer { await bridge.disconnectEndpoint(name: "mcp-elicit") }

        do {
            _ = try await Self.withTimeout(seconds: 30) {
                () -> String in try await bridge.routeToolCall("elicit_gate", arguments: "{}")
            }
            #expect(false, ".never 下外呼应在工具级审批门被拒，不应成功返回")
        } catch {
            // 精确 reason（broker .never 裁决的 "auto-denied"）
            #expect(
                "\(error)".lowercased().contains("denied"),
                "期望含 approval denied, 实际: \(error)")
        }

        // 关键断言：server 完全没收到任何 tools/call（未到达），更无入站请求需应答
        let stats = await bridge.testClientElicitationStats(name: "mcp-elicit")
        #expect(
            stats.elicitationCount == 0 && stats.pongCount == 0,
            ".never 下 tools/call 未发出，无入站请求可被应答: \(stats)")
    }

    @Test("elicit 入站请求 → decline（hook 拒绝 elicit gate，server 拿到 decline 应答并完成）")
    func elicitDeclinedByHook() async throws {
        // `.auto` broker：工具级门自动放行 → tools/call 到 server → server 发 elicit 入站请求
        // → `respondInboundRequest` → elicitation gate → hook `.deny` → decline wire 应答
        // （`{"action":"decline"}`）→ server 拿到 decline 应答，继续返回最终 tools/call 结果。
        // 锁住 elicitation 门的 broker 拒绝路径 + 入站请求应答行的 wire 形状（精确值断言面）。
        let broker = ApprovalBroker(policy: .auto)
        let registry = ToolRegistry(
            hooks: [
                Hook.pre(matcher: ToolMatcher("mcp_elicit[mcp-elicit]")) { _ in
                    .deny(reason: "elicitation explicitly declined by policy hook")
                }
            ],
            approvalBroker: broker, log: Logger(label: "test.elicit.decline")
        )
        let bridge = MCPBridge(toolRegistry: registry, transport: MCPStdioTransport())
        try await bridge.connectEndpoint(
            name: "mcp-elicit", command: "python3",
            args: [try writeElicitationStub().path], capabilities: ["tools"])
        defer { await bridge.disconnectEndpoint(name: "mcp-elicit") }

        // 调用应当**完成**（不挂死）——elicitation 被拒绝，但 server 拿到应答后继续完成
        let result = try await Self.withTimeout(seconds: 30) {
            () -> String in try await bridge.routeToolCall("elicit_gate", arguments: "{}")
        }
        #expect(result.contains("elicit_result="), "结果缺 elicit_result: \(result)")
        let elicitResp = extractField(result, "elicit_result")
        // 精确 wire shape: {"action":"decline"}（hook 拒绝 elicitation gate → decline 应答）
        #expect(
            elicitResp.contains("\"action\":\"decline\""),
            "elicit 应答应为 decline（hook 拒绝 elicitation gate），实际: \(elicitResp)")
        // ping 仍应被应答为 {} 空 result（elicitation 拒绝不影响其他入站请求应答）
        let pingResp = extractField(result, "ping_result")
        #expect(pingResp == "{}", "ping 应答应为空 result {}, 实际: \(pingResp)")
        let stats = await bridge.testClientElicitationStats(name: "mcp-elicit")
        #expect(stats.elicitationCount == 1, "elicit 应答计数(decline 也算应答): \(stats)")
        #expect(stats.pongCount == 1, "ping 应答计数: \(stats)")
    }

    @Test("client 侧计数精确值：elicit 应答 1 条 + ping 应答 1 条")
    func clientCountsElicitationAndPong() async throws {
        let bridge = try await Self.makeBridge(policy: .auto)
        defer { Task { await bridge.disconnectEndpoint(name: "mcp-elicit") } }
        _ = try? await Self.withTimeout(seconds: 30) {
            () -> String in try await bridge.routeToolCall("elicit_gate", arguments: "{}")
        }

        let stats = await bridge.testClientElicitationStats(name: "mcp-elicit")
        #expect(stats.elicitationCount == 1, "elicit 应答计数: \(stats.elicitationCount)")
        #expect(stats.pongCount == 1, "ping 应答计数: \(stats.pongCount)")
    }
}
