// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! MCPTimeoutDeliveryTests.swift — an external MCP server's response budget must be the
//! budget this server publishes, in behaviour and on the wire.
//!
//! ### Why these tests exist (10-21)
//! `MCPBridgeConfig` carried a documented timeout knob ("外部 server 响应超时（秒）", default 10)
//! with zero consumers; the number actually in force was the literal `15`, written twice in
//! `MCPStdioClient` (an outer `withTimeout(seconds: 15)` and a second absolute deadline inside
//! the very wait it wrapped). `MCPEndpointTests` asserted that knob's storage round-tripped, so
//! the suite was green on a value no code read: the gate read the storage, not the behaviour,
//! and could not go red (AGENTS.md invariant 1). Every case below therefore asserts either a
//! measured elapsed time against a live child, or the JSON a client is actually handed.
//!
//! ### The numbers are pinned as literals, not as `MCPTimeouts.startupDefault`
//! A test written `== MCPTimeouts.startupDefault` follows a wrong constant. 30 / 300 are the
//! contract, from codex `codex-mcp/src/rmcp_client.rs:110-111` (`DEFAULT_STARTUP_TIMEOUT` /
//! `DEFAULT_TOOL_TIMEOUT`).

import Foundation
import Logging
import Testing

@testable import ocoreai

/// stdio MCP stub: answers the handshake, then sleeps `argv[1]` seconds before `tools/call`.
private func writeSlowToolServer() throws -> URL {
    let stub = """
        import sys, json, time

        sleep_s = float(sys.argv[1]) if len(sys.argv) > 1 else 0.0

        def out(obj):
            print(json.dumps(obj))
            sys.stdout.flush()

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue
            method = msg.get("method", "")
            if method == "initialize":
                out({"jsonrpc": "2.0", "id": msg.get("id"),
                     "result": {"protocolVersion": "2024-11-05",
                                "capabilities": {"tools": {}},
                                "serverInfo": {"name": "ocoreai-slow-stub", "version": "0.1"}}})
            elif method.startswith("notifications/"):
                pass
            elif method == "tools/list":
                out({"jsonrpc": "2.0", "id": msg.get("id"),
                     "result": {"tools": [{"name": "slow_tool",
                                           "description": "sleeps then answers",
                                           "inputSchema": {"type": "object",
                                                           "properties": {}}}]}})
            elif method == "tools/call":
                time.sleep(sleep_s)
                out({"jsonrpc": "2.0", "id": msg.get("id"),
                     "result": {"content": [{"type": "text", "text": "arrived"}]}})
            else:
                out({"jsonrpc": "2.0", "id": msg.get("id"), "result": {}})
        """
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp_slow_stub_\(UUID().uuidString).py")
    try stub.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func makeTimeoutBridge(_ config: MCPBridgeConfig = .default) -> MCPBridge {
    MCPBridge(
        toolRegistry: ToolRegistry(log: Logger(label: "test.mcp.timeout")),
        transport: MCPStdioTransport(),
        bridgeConfig: config,
        log: Logger(label: "test.mcp.timeout.bridge")
    )
}

@Suite("MCP timeout delivery")
struct MCPTimeoutDeliveryTests {

    // MARK: - The budget a client actually carries

    @Test("no override → the published defaults 30s / 300s, not the old hardcoded 15")
    func defaultsReachTheClient() async throws {
        let ep = MCPEndpoint(name: "pins", stdioCommand: "/usr/bin/true")
        let budget = await MCPStdioClient(endpoint: ep, transport: MCPStdioTransport()).budget()
        #expect(budget.startupSeconds == 30, "codex DEFAULT_STARTUP_TIMEOUT")
        #expect(budget.toolSeconds == 300, "codex DEFAULT_TOOL_TIMEOUT")
    }

    @Test("bridge config is delivered to the client, not just stored")
    func bridgeConfigReachesTheClient() async throws {
        let ep = MCPEndpoint(name: "cfg", stdioCommand: "/usr/bin/true")
        let budget = await MCPStdioClient(
            endpoint: ep, transport: MCPStdioTransport(),
            configStartupTimeout: 7, configToolTimeout: 11
        ).budget()
        #expect(budget.startupSeconds == 7, "config must reach the engine, not just the struct")
        #expect(budget.toolSeconds == 11)
    }

    @Test("per-endpoint override wins over bridge config")
    func endpointOverrideWins() async throws {
        let ep = MCPEndpoint(
            name: "ovr", stdioCommand: "/usr/bin/true",
            startupTimeoutSeconds: 3, toolTimeoutSeconds: 4)
        let budget = await MCPStdioClient(
            endpoint: ep, transport: MCPStdioTransport(),
            configStartupTimeout: 7, configToolTimeout: 11
        ).budget()
        #expect(budget.startupSeconds == 3)
        #expect(budget.toolSeconds == 4)
    }

    @Test("an out-of-range value cannot install a deadline in the past")
    func consumerFloorsPathologicalValues() async throws {
        // The wire refuses these by name; this is the second net, so a value that reached the
        // client some other way still cannot produce a negative or unbounded deadline.
        let low = MCPEndpoint(
            name: "low", stdioCommand: "/usr/bin/true", toolTimeoutSeconds: -5)
        let floored = await MCPStdioClient(endpoint: low, transport: MCPStdioTransport()).budget()
        #expect(floored.toolSeconds == 1, "floored at allowedRange.lowerBound")

        let high = MCPEndpoint(
            name: "high", stdioCommand: "/usr/bin/true", toolTimeoutSeconds: 100_000)
        let capped = await MCPStdioClient(endpoint: high, transport: MCPStdioTransport()).budget()
        #expect(capped.toolSeconds == 600, "capped at allowedRange.upperBound")
    }

    // MARK: - Measured behaviour against a live child

    @Test("a call over the budget is cut at the budget, and the error names the seconds")
    func slowCallCutAtBudget() async throws {
        let stub = try writeSlowToolServer()
        let ep = MCPEndpoint(
            name: "slow-1s", stdioCommand: "python3", stdioArgs: [stub.path, "3"],
            toolTimeoutSeconds: 1)
        let client = MCPStdioClient(endpoint: ep, transport: MCPStdioTransport())
        try await client.connect()
        defer { Task { await client.disconnect() } }

        let started = Date()
        do {
            _ = try await client.callTool("slow_tool", arguments: [:])
            Issue.record("expected a timeout: the stub sleeps 3s on a 1s budget")
            return
        } catch let error as MCPClientError {
            guard case .timeout(let name, let seconds, _) = error else {
                Issue.record("expected .timeout, got \(error)")
                return
            }
            let elapsed = Date().timeIntervalSince(started)
            #expect(name == "slow-1s")
            #expect(seconds == 1, "the bound in the message is the bound that was set")
            #expect(elapsed >= 0.9 && elapsed < 2.5, "cut at 1s, measured \(elapsed)s")
            #expect(
                error.localizedDescription.contains("did not answer within 1s"),
                "the caller is told which bound fired: \(error.localizedDescription)")
            // 这个 stub 一声不吭 ⇒ 文案必须和加 stderr 采集之前逐字相同：
            // 没有证据就不许出现"stderr"字样（invariant 2 的反面——不许编证据）。
            #expect(
                !error.localizedDescription.contains("stderr"),
                "a silent child must not gain invented evidence: \(error.localizedDescription)")
        }
    }

    @Test("the same stub answers inside the default budget — widening did not shorten anything")
    func sameStubAnswersInsideDefaultBudget() async throws {
        let stub = try writeSlowToolServer()
        let ep = MCPEndpoint(
            name: "slow-default", stdioCommand: "python3", stdioArgs: [stub.path, "3"])
        let client = MCPStdioClient(endpoint: ep, transport: MCPStdioTransport())
        try await client.connect()
        defer { Task { await client.disconnect() } }

        let started = Date()
        let result = try await client.callTool("slow_tool", arguments: [:])
        let elapsed = Date().timeIntervalSince(started)
        #expect(result.first?["text"] == "arrived")
        #expect(
            elapsed >= 2.9 && elapsed < 12.0,
            "answered after its own 3s sleep, measured \(elapsed)s")
    }

    // MARK: - What the wire publishes

    @Test("bridge status publishes the budgets in force")
    func statusPublishesBudgets() async throws {
        let bridge = makeTimeoutBridge(
            MCPBridgeConfig(startupTimeoutSeconds: 9, toolTimeoutSeconds: 21))
        let payload = try Self.resultObject(
            try #require(
                await bridge.handleLine(
                    #"{"jsonrpc":"2.0","id":1,"method":"$bridge/status"}"#)))
        #expect(payload["startupTimeoutSeconds"] as? Double == 9)
        #expect(payload["toolTimeoutSeconds"] as? Double == 21)
    }

    @Test("endpoint list publishes each endpoint's effective budget")
    func endpointListPublishesEffectiveBudget() async throws {
        let stub = try writeSlowToolServer()
        let bridge = makeTimeoutBridge(
            MCPBridgeConfig(startupTimeoutSeconds: 9, toolTimeoutSeconds: 21))
        try await bridge.connectEndpoint(
            name: "listed", command: "python3", args: [stub.path, "0"], capabilities: ["tools"],
            startupTimeoutSeconds: 12)
        defer { Task { await bridge.disconnectEndpoint(name: "listed") } }

        let rows = try Self.resultRows(
            try #require(
                await bridge.handleLine(
                    #"{"jsonrpc":"2.0","id":2,"method":"$bridge/endpoint/list"}"#)))
        let row = try #require(rows.first, "no endpoint row")
        #expect(row["name"] as? String == "listed")
        // Read back from the client that was actually built, not from the params the caller
        // sent: publishing the request would let a dropped override keep looking honoured.
        #expect(row["startupTimeoutSeconds"] as? Double == 12, "the override is what got published")
        #expect(row["toolTimeoutSeconds"] as? Double == 21, "absent override → config default")
    }

    // MARK: - Wire refusals: a bad number is an answer, not a hang

    @Test("out-of-domain budget → -32602 naming field + range + value, and no endpoint added")
    func outOfDomainRefusedOnTheWire() async throws {
        for sent in ["0", "-5", "3601"] {
            let bridge = makeTimeoutBridge()
            let response = try Self.jsonObject(
                try #require(
                    await bridge.handleLine(
                        #"{"jsonrpc":"2.0","id":3,"method":"$bridge/endpoint/connect","params":{"name":"bad-\#(sent)","command":"python3","args":[],"tool_timeout_sec":\#(sent)}}"#
                    )))
            let error = try #require(response["error"] as? [String: Any], "no error for \(sent)")
            let message = (error["message"] as? String) ?? ""
            #expect(error["code"] as? Int == -32602, "\(sent) → \(message)")
            #expect(message.contains("tool_timeout_sec"), "field named: \(message)")
            #expect(message.contains("1s and 600s"), "range stated: \(message)")
            #expect(message.contains(sent), "value echoed: \(message)")

            let rows = try Self.resultRows(
                try #require(
                    await bridge.handleLine(
                        #"{"jsonrpc":"2.0","id":4,"method":"$bridge/endpoint/list"}"#)))
            #expect(
                rows.isEmpty, "a refused connect must not leave a half-built endpoint behind")
        }
    }

    @Test("a non-numeric budget is refused by name, not treated as absent")
    func nonNumericRefusedOnTheWire() async throws {
        let bridge = makeTimeoutBridge()
        let response = try Self.jsonObject(
            try #require(
                await bridge.handleLine(
                    #"{"jsonrpc":"2.0","id":5,"method":"$bridge/endpoint/connect","params":{"name":"nope","command":"python3","args":[],"startup_timeout_sec":"fast"}}"#
                )))
        let message = ((response["error"] as? [String: Any])?["message"] as? String) ?? ""
        #expect((response["error"] as? [String: Any])?["code"] as? Int == -32602)
        #expect(message.contains("startup_timeout_sec"), "field named: \(message)")
        #expect(message.contains("fast"), "what arrived is echoed: \(message)")
    }

    @Test("an absent budget is not a refusal — the config default is used and published")
    func absentBudgetUsesConfig() async throws {
        let stub = try writeSlowToolServer()
        let bridge = makeTimeoutBridge(
            MCPBridgeConfig(startupTimeoutSeconds: 9, toolTimeoutSeconds: 21))
        try await bridge.connectEndpoint(
            name: "plain", command: "python3", args: [stub.path, "0"], capabilities: ["tools"])
        defer { Task { await bridge.disconnectEndpoint(name: "plain") } }

        let rows = try Self.resultRows(
            try #require(
                await bridge.handleLine(
                    #"{"jsonrpc":"2.0","id":6,"method":"$bridge/endpoint/list"}"#)))
        let row = try #require(rows.first)
        #expect(row["toolTimeoutSeconds"] as? Double == 21)
    }

    // MARK: - Scan floors: the old shape must not come back

    @Test("one home for the numbers; the unread knob stays deleted")
    func scanFloors() throws {
        let root = try Self.repoRoot()
        let client = Self.codeOnly(
            try Self.read("Sources/ocoreai/MCP/MCPStdioClient.swift", in: root))
        let bridge = Self.codeOnly(
            try Self.read("Sources/ocoreai/MCP/MCPBridge.swift", in: root))
        let timeouts = Self.codeOnly(
            try Self.read("Sources/ocoreai/MCP/MCPTimeouts.swift", in: root))

        // Floor the premises first: a scan whose pattern stopped matching passes vacuously.
        #expect(
            client.contains("withTimeout(seconds: timeout)"),
            "scan premise broken: the budget is no longer threaded to the wait")
        #expect(
            bridge.contains("config.startupTimeoutSeconds"),
            "scan premise broken: the bridge no longer reads its own config")
        #expect(
            bridge.contains("handle.appliedBudget"),
            "ledger regressed to publishing what the client asked for instead of what the engine applied"
        )
        #expect(
            client.contains("MCPRPCBudgets.resolve("),
            "resolution forked: the client stopped using the single resolution point")

        // The literals that used to be the only truth are gone from the consumer.
        #expect(!client.contains("seconds: 15"), "hardcoded outer deadline is back")
        #expect(!client.contains("milliseconds(15000)"), "hardcoded inner deadline is back")
        #expect(
            !client.contains("ContinuousClock.now + "),
            "waitForResponse grew a second deadline — the caller owns the one deadline")

        // Both numbers are declared exactly once, in one file, and nowhere else. Match the
        // whole declaration line: a bare "= 30" also matches "= 300", which read as a second
        // home on the first run of this gate (a scan that mis-matches is worse than none).
        #expect(Self.occurrences(of: "TimeInterval = 30\n", in: timeouts) == 1)
        #expect(Self.occurrences(of: "TimeInterval = 300\n", in: timeouts) == 1)
        #expect(
            !client.contains("TimeInterval = 30") && !client.contains("TimeInterval = 300"),
            "defaults redefined in the consumer")
    }

    // MARK: - helpers

    /// 只留代码行：一条解释"为什么不能这样写"的注释不是那个写法本身。
    /// 若注释也算命中，后来的维护者只会把注释删掉——门反而教会人销毁理由。
    /// 与 AGENTS.md 里 claim 扫描同一口径（`grep -vE ':[0-9]+: *(//|/\*|\*)'`）。
    /// 只剥整行注释，行尾注释保留：`x = 15 // 旧值` 仍然是代码里的那个 15。
    static func codeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("/*")
                    && !trimmed.hasPrefix("*")
            }
            .joined(separator: "\n")
    }

    private static func jsonObject(_ line: String) throws -> [String: Any] {
        let data = try #require(line.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data)
        return try #require(parsed as? [String: Any], "not a JSON object: \(line.prefix(160))")
    }

    /// Unwrap the JSON-RPC envelope — assertions read what a client reads, never an
    /// internal struct, so a published field cannot be "fixed" in code and stay absent on the wire.
    private static func resultObject(_ line: String) throws -> [String: Any] {
        let inner = try jsonObject(line)["result"]
        return try #require(inner as? [String: Any], "result is not an object: \(line.prefix(160))")
    }

    private static func resultRows(_ line: String) throws -> [[String: Any]] {
        let inner = try jsonObject(line)["result"]
        return try #require(
            inner as? [[String: Any]], "result is not an array: \(line.prefix(160))")
    }

    /// Find the repo root by searching, never by fixed `deletingLastPathComponent()` hops.
    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path)
            {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func read(_ relative: String, in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        needle.isEmpty ? 0 : haystack.components(separatedBy: needle).count - 1
    }
}
