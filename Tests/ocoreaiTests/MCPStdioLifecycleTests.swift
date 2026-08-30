// Copyright © 2026 uingei@163.com.
/// MCP Stdio client lifecycle tests — reconnect on unexpected child exit.
///
/// Uses a Python stdio stub (python3 mcp_stub.py) as the MCP server.
/// The stub responds to initialize / tools/list / tools/call with minimal
/// valid JSON-RPC responses, then keeps reading stdin.
import Foundation
import Testing
import ocoreaiTestUtilities

@testable import ocoreai

// MARK: - Fixture: Python MCP stdio stub

/// Writes the stub server to a temp path and returns the file URL.
/// Python 3 stdio JSON-RPC: reads line, responds via print(..., end="") to
/// avoid Swift's multi-line string turning `\n` into a real newline mid-source.
private func writeMCPStubServer() throws -> URL {
    let stub = """
        import sys, json

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
                out({"jsonrpc":"2.0","id":msg.get("id"),
                     "result":{"protocolVersion":"2024-11-05",
                               "capabilities":{"tools":{}},
                               "serverInfo":{"name":"ocoreai-test-stub","version":"0.1"}}})
            elif method.startswith("notifications/"):
                pass
            elif method == "tools/list":
                out({"jsonrpc":"2.0","id":msg.get("id"),"result":{"tools":[]}})
            elif method == "tools/call":
                out({"jsonrpc":"2.0","id":msg.get("id"),"result":{"content":[{"type":"text","text":"ok"}]}})
            else:
                out({"jsonrpc":"2.0","id":msg.get("id"),"result":{}})
        """
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp_stub_\(UUID().uuidString).py")
    try stub.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// Polls testChildRunning() until it returns false or timeout.
private func waitForChildExit(
    client: MCPStdioClient,
    timeout: TimeInterval = 5.0
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !(await client.testChildRunning()) { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return !(await client.testChildRunning())
}

// MARK: - Tests

@Suite("MCP — Stdio Client Lifecycle")
struct MCPStdioLifecycleTests {
    private static func makeEndpoint() throws -> MCPEndpoint {
        MCPEndpoint(
            name: "ocoreai-test",
            stdioCommand: "python3",
            stdioArgs: [try writeMCPStubServer().path],
            capabilities: ["tools"]
        )
    }

    #if os(macOS)

    @Test("connect → status == .connected AND child process running")
    func connectSuccess() async throws {
        let ep = try Self.makeEndpoint()
        let transport = MCPStdioTransport()
        let client = MCPStdioClient(endpoint: ep, transport: transport)
        try await client.connect()
        #expect(await client.status == .connected)
        #expect(await client.testChildRunning())
        #expect(await client.testLastError() == nil)
        await client.disconnect()
    }

    @Test("child exit → childExitStatus captured, status remains .connected (not yet reconciled)")
    func childExitStatusCaptured() async throws {
        let ep = try Self.makeEndpoint()
        let transport = MCPStdioTransport()
        let client = MCPStdioClient(endpoint: ep, transport: transport)
        try await client.connect()
        #expect(await client.testChildRunning())

        // Kill child (simulate unexpected crash)
        await client.testTerminateChild()
        _ = await waitForChildExit(client: client)

        // Status still .connected until request() reconciles it
        #expect(await client.status == .connected)
        #expect(!(await client.testChildRunning()))
        await client.disconnect()
    }

    @Test("reconnect: after child exit + request(), new process has different PID")
    func reconnectAfterChildExit() async throws {
        let ep = try Self.makeEndpoint()
        let transport = MCPStdioTransport()
        let client = MCPStdioClient(endpoint: ep, transport: transport)
        try await client.connect()
        #expect(await client.testChildRunning())
        let oldPid = await client.testChildPID()
        #expect(oldPid > 0)

        // Kill child
        await client.testTerminateChild()
        _ = await waitForChildExit(client: client)

        // Next request triggers detection → automatic reconnect
        // listToolsRaw() returns a String (Sendable) → safe across actor boundary
        let raw = try await client.listToolsRaw()
        #expect(raw.contains("\"tools\""))
        #expect(await client.status == .connected)
        #expect(await client.testChildRunning())

        let newPid = await client.testChildPID()
        #expect(newPid > 0)
        #expect(newPid != oldPid, "Reconnected process must have a different PID")
        await client.disconnect()
    }

    @Test("manual disconnect → next request throws notConnected, no auto-reconnect")
    func manualDisconnectBlocksReconnect() async throws {
        let ep = try Self.makeEndpoint()
        let transport = MCPStdioTransport()
        let client = MCPStdioClient(endpoint: ep, transport: transport)
        try await client.connect()
        #expect(await client.status == .connected)

        // Manual disconnect
        await client.disconnect()
        #expect(await client.status == .disconnected)
        #expect(!(await client.testChildRunning()))

        // Subsequent request must throw notConnected
        do {
            _ = try await client.listToolsRaw()
            Issue.record("Expected notConnected error, got success")
        } catch let e as MCPClientError {
            #expect(e.isNotConnected())
        }
    }

    #endif
}

// MARK: - MCPClientError helpers (for test assertions)

extension MCPClientError {
    /// Pattern-match helper for precise test assertions.
    func isNotConnected() -> Bool {
        if case .notConnected = self { return true }
        return false
    }
    func isTimeout() -> Bool {
        if case .timeout = self { return true }
        return false
    }
    func isChildExited() -> Bool {
        if case .childExited = self { return true }
        return false
    }
}
