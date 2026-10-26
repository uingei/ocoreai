// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `required` is a JSON Schema set, and the registry synthesized it as `Array(parameters.keys)` —
/// the iteration order of a Swift `Dictionary`, picked by Swift from a per-process hash seed. Same
/// request, two boots, different prompt bytes: the 10-23(8) skill-block defect reaching the prompt
/// through the MCP door. This suite pins that both live exits (`ToolRegistry.toToolSpecs`,
/// `ToolEntry.toToolDef`) synthesize it name-sorted, and — the premise the fix stands on — that a
/// server omitting `required` really does arrive as `nil` rather than being silently treated as
/// "all optional". A third translation lived in `MCPTools`, which nobody ever instantiated; it is
/// deleted, and the outbound face publishes from the same home (`MCPServerWireTests` covers it).
///
/// The exit tests fail ~23/24 processes before the fix (a 4-key dictionary happens to land in
/// alphabetical order once in 24), and pass deterministically after it. Cross-process proof is
/// `scripts/probes/33-mcp-required-byte-determinism.sh`, which is the only instrument that can see
/// a per-process seed at all; these tests are what make the rule fail in CI the day someone
/// reintroduces a raw `.keys`.
///
/// What is deliberately NOT sorted: a `required` the caller or server declared. That order came
/// from the request, so it is already request-determined (Test E).
import Foundation
import Logging
import Testing

@testable import ocoreai

/// Four names whose alphabetical order is far from any insertion order, so an unsorted
/// dictionary exit cannot pass the assertions by coincidence of how they were written.
private let alphabetical = ["alpha", "bravo", "charlie", "delta"]

private func writeNoRequiredServer() throws -> URL {
    let stub = """
        import sys, json

        def out(obj):
            print(json.dumps(obj))
            sys.stdout.flush()

        # `mcp_noreq` declares NO `required` key at all — the MCP-legal shape that makes our
        # registry synthesize one. `mcp_subset` declares a real subset, to prove passthrough order
        # survives untouched.
        TOOLS = [
            {"name": "mcp_noreq",
             "description": "no required declared",
             "inputSchema": {"type": "object",
                             "properties": {"delta": {"type": "string"},
                                           "charlie": {"type": "string"},
                                           "alpha": {"type": "string"},
                                           "bravo": {"type": "string"}}}},
            {"name": "mcp_subset",
             "description": "declared subset, unusual order",
             "inputSchema": {"type": "object",
                             "properties": {"zeta": {"type": "string"},
                                           "alpha": {"type": "string"}},
                             "required": ["zeta", "alpha"]}},
        ]

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
                               "serverInfo": {"name": "ocoreai-required-stub", "version": "0.1"}}})
            elif method.startswith("notifications/"):
                pass
            elif method == "tools/list":
                out({"jsonrpc": "2.0", "id": msg.get("id"), "result": {"tools": TOOLS}})
            elif method == "tools/call":
                out({"jsonrpc": "2.0", "id": msg.get("id"),
                     "result": {"content": [{"type": "text", "text": "ok"}]}})
            else:
                out({"jsonrpc": "2.0", "id": msg.get("id"), "result": {}})
        """
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp_required_stub_\(UUID().uuidString).py")
    try stub.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Suite("Synthesized `required` is sorted, never dictionary order")
struct ToolRequiredOrderDeterminismTests {

    /// Production path: connect a stdio server → discover → register (the same route a real MCP
    /// server takes; a hand-built ToolEntry would only prove the writer, not the door).
    private static func connect() async throws -> (MCPBridge, ToolRegistry, URL) {
        let registry = ToolRegistry(log: Logger(label: "test.reqorder"))
        let bridge = MCPBridge(toolRegistry: registry, transport: MCPStdioTransport())
        let path = try writeNoRequiredServer()
        try await bridge.connectEndpoint(
            name: "mcp-reqorder", command: "python3", args: [path.path], capabilities: ["tools"])
        return (bridge, registry, path)
    }

    private func wireRequired(_ specs: [[String: any Sendable]], _ tool: String) -> [String]? {
        let match = specs.first {
            ($0["function"] as? [String: any Sendable])?["name"] as? String == tool
        }
        guard
            let function = match?["function"] as? [String: any Sendable],
            let params = function["parameters"] as? [String: any Sendable]
        else { return nil }
        return params["required"] as? [String]
    }

    @Test("premise: a server that omits `required` arrives as nil, not as all-optional")
    func omittedRequiredArrivesAsNil() async throws {
        let (bridge, registry, path) = try await Self.connect()
        defer {
            Task { await bridge.disconnectEndpoint(name: "mcp-reqorder") }
            try? FileManager.default.removeItem(at: path)
        }
        guard let entry = await registry.lookup("mcp_noreq") else {
            Issue.record("mcp_noreq 未注册 — 前提不成立, 后面的排序断言会是空转")
            return
        }
        #expect(
            entry.schema.required == nil,
            "服务端已省略 required, 注册表却读出了 \(String(describing: entry.schema.required))")
        // Floor the premise: with fewer than two parameters there is no order to get wrong, and a
        // gate that has nothing to discriminate passes vacuously.
        #expect(
            entry.schema.parameters.count == 4,
            "参数集只有 \(entry.schema.parameters.count) 个, 不足以区分字典序与名序")
    }

    @Test("exit 1 — ToolRegistry.toToolSpecs synthesizes `required` in name order")
    func registrySpecsSortSynthesizedRequired() async throws {
        let (bridge, registry, path) = try await Self.connect()
        defer {
            Task { await bridge.disconnectEndpoint(name: "mcp-reqorder") }
            try? FileManager.default.removeItem(at: path)
        }
        let got = wireRequired(await registry.toToolSpecs(), "mcp_noreq")
        #expect(
            got == alphabetical,
            "toToolSpecs required=\(String(describing: got)) — 期望按名排序; 这是进 prompt 的那一份")
    }

    @Test("exit 2 — ToolEntry.toToolDef synthesizes `required` in name order")
    func toolDefSynthesizesSortedRequired() {
        let entry = ToolEntry(
            name: "local_noreq", toolset: "test",
            schema: ToolSchema(
                parameters: [
                    "delta": ToolParameter(type: .string, description: "d"),
                    "charlie": ToolParameter(type: .string, description: "c"),
                    "alpha": ToolParameter(type: .string, description: "a"),
                    "bravo": ToolParameter(type: .string, description: "b"),
                ]),
            handler: { _ in "" })
        let got = entry.toToolDef().function.parameters?["required"]?.value as? [String]
        #expect(got == alphabetical, "toToolDef required=\(String(describing: got))")
    }

    @Test("a declared subset is passed through in the caller's own order (only synthesis sorts)")
    func declaredSubsetKeepsCallerOrder() async throws {
        let (bridge, registry, path) = try await Self.connect()
        defer {
            Task { await bridge.disconnectEndpoint(name: "mcp-reqorder") }
            try? FileManager.default.removeItem(at: path)
        }
        let got = wireRequired(await registry.toToolSpecs(), "mcp_subset")
        #expect(got == ["zeta", "alpha"], "调用方写的顺序属于请求本身, 不该被我们改写: \(String(describing: got))")
    }
}
