// MCPSchemaFidelityTests.swift — 09-06 MCP 参数面形状保真(Red→Green)
//
// 缺陷类(代码即文档): MCP tools/list 的 inputSchema 是 JSON Schema(带
// number/object/array<items>/required 子集),此前 discoverAndRegisterTools 拍平映射:
//   "number" → .integer          (float 字段变 int wire, 模型按整型生成)
//   "object" → .string           (default 兜底, 嵌套结构全丢)
//   array.items → 丢             (wire 裸 array)
//   required 子集 → 压平 all     (可选参数被标必填)
// 与 448b587 "描述静默丢弃" 同一缺陷类 — 注册成功(27 口径可见)但模型拿到的
// 参数面与上游声明不一致。
//
// 纪律: 用仓内已验证的 Python stdio stub 驱动**生产同路**
//       MCPBridge.connectEndpoint → discoverAndRegisterTools → ToolRegistry,
//       不用手写 ToolEntry 样例自证。精确值断言, 禁 count>0 弱断言。

import Foundation
import Logging
import Testing

@testable import ocoreai

#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
import FoundationModels
#endif

/// 富 schema MCP stub: 4 工具覆盖 number / object<嵌套+required> / array<items> / required 子集。
private func writeRichMCPServer() throws -> URL {
    let stub = """
        import sys, json

        def out(obj):
            print(json.dumps(obj))
            sys.stdout.flush()

        TOOLS = [
            {"name": "mcp_number",
             "description": "temp",
             "inputSchema": {"type": "object",
                             "properties": {"x": {"type": "number", "description": "temperature"}},
                             "required": ["x"]}},
            {"name": "mcp_object",
             "description": "filter",
             "inputSchema": {"type": "object",
                             "properties": {"filter": {"type": "object",
                                                        "properties": {"a": {"type": "string"},
                                                                       "b": {"type": "integer"}},
                                                        "required": ["a"]}},
                             "required": ["filter"]}},
            {"name": "mcp_array",
             "description": "ids",
             "inputSchema": {"type": "object",
                             "properties": {"ids": {"type": "array", "items": {"type": "integer"}}},
                             "required": ["ids"]}},
            {"name": "mcp_optional",
             "description": "opt",
             "inputSchema": {"type": "object",
                             "properties": {"a": {"type": "string"},
                                           "b": {"type": "string"}},
                             "required": ["a"]}},
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
                out({"jsonrpc":"2.0","id":msg.get("id"),
                     "result":{"protocolVersion":"2024-11-05",
                               "capabilities":{"tools":{}},
                               "serverInfo":{"name":"ocoreai-fidelity-stub","version":"0.1"}}})
            elif method.startswith("notifications/"):
                pass
            elif method == "tools/list":
                out({"jsonrpc":"2.0","id":msg.get("id"),"result":{"tools":TOOLS}})
            elif method == "tools/call":
                out({"jsonrpc":"2.0","id":msg.get("id"),"result":{"content":[{"type":"text","text":"ok"}]}})
            else:
                out({"jsonrpc":"2.0","id":msg.get("id"),"result":{}})
        """
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp_fidelity_stub_\(UUID().uuidString).py")
    try stub.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Suite("MCP Schema Fidelity")
struct MCPSchemaFidelityTests {
    @MainActor
    private static func makeBridge() async throws -> (MCPBridge, ToolRegistry, String) {
        let registry = ToolRegistry(log: Logger(label: "test.mcpfidelity"))
        let bridge = MCPBridge(
            toolRegistry: registry,
            transport: MCPStdioTransport(),
        )
        let path = try writeRichMCPServer().path
        try await bridge.connectEndpoint(
            name: "mcp-fidelity",
            command: "python3",
            args: [path],
            capabilities: ["tools"],
        )
        return (bridge, registry, path)
    }

    @Test("number 字段保真 .number + wire \"number\"（非 integer）")
    func numberFieldFidelity() async throws {
        let (bridge, registry, _) = try await Self.makeBridge()
        defer { Task { await bridge.disconnectEndpoint(name: "mcp-fidelity") } }

        guard let entry = await registry.lookup("mcp_number") else {
            Issue.record("mcp_number 未注册")
            return
        }
        let x = entry.schema.parameters["x"]
        #expect(x?.type == .number, "number→\(x?.type.rawValue ?? "-") (旧码: .integer)")

        let specs = await registry.toToolSpecs()
        let wire = specs.first(where: {
            ($0["function"] as? [String: any Sendable])?["name"] as? String == "mcp_number"
        })
        guard
            let function = wire?["function"] as? [String: any Sendable],
            let params = function["parameters"] as? [String: any Sendable],
            let allProps = params["properties"] as? [String: any Sendable],
            let xWire = allProps["x"] as? [String: any Sendable]
        else {
            Issue.record("mcp_number wire 缺失")
            return
        }
        #expect(
            xWire["type"] as? String == "number", "wire type: \(String(describing: xWire["type"]))")
    }

    @Test("object 参数保真嵌套 properties + 元素级 required（非拍平 string）")
    func objectFieldTypeFidelity() async throws {
        let (bridge, registry, _) = try await Self.makeBridge()
        defer { Task { await bridge.disconnectEndpoint(name: "mcp-fidelity") } }

        guard let entry = await registry.lookup("mcp_object"),
            let filter = entry.schema.parameters["filter"]
        else {
            Issue.record("mcp_object/filter 未注册")
            return
        }
        #expect(filter.type == .object, "object→\(filter.type.rawValue) (旧码: .string 兜底)")
        #expect(filter.properties?["a"]?.type == .string, "filter.a 丢失")
        #expect(filter.properties?["b"]?.type == .integer, "filter.b 丢失")
        #expect(
            Set(filter.required ?? []) == ["a"],
            "元素级 required: \(String(describing: filter.required))")

        // wire: 嵌套 properties 在 dict 里
        let specs = await registry.toToolSpecs()
        let wire = specs.first(where: {
            ($0["function"] as? [String: any Sendable])?["name"] as? String == "mcp_object"
        })
        guard
            let function = wire?["function"] as? [String: any Sendable],
            let params = function["parameters"] as? [String: any Sendable],
            let allProps = params["properties"] as? [String: any Sendable],
            let filterWire = allProps["filter"] as? [String: any Sendable]
        else {
            Issue.record("mcp_object wire 缺失")
            return
        }
        #expect(filterWire["type"] as? String == "object")
        let filterProps = filterWire["properties"] as? [String: any Sendable]
        let bVal = filterProps?["b"] as? [String: any Sendable]
        #expect(bVal?["type"] as? String == "integer", "wire 嵌套 b 丢失")
    }

    @Test("array 参数保真 items（旧码丢 items → 裸 array）")
    func arrayItemsFidelity() async throws {
        let (bridge, registry, _) = try await Self.makeBridge()
        defer { Task { await bridge.disconnectEndpoint(name: "mcp-fidelity") } }

        guard let entry = await registry.lookup("mcp_array"),
            let ids = entry.schema.parameters["ids"]
        else {
            Issue.record("mcp_array/ids 未注册")
            return
        }
        #expect(ids.type == .array)
        #expect(ids.items?.type == .integer, "items 丢失: \(String(describing: ids.items?.type))")

        let specs = await registry.toToolSpecs()
        let wire = specs.first(where: {
            ($0["function"] as? [String: any Sendable])?["name"] as? String == "mcp_array"
        })
        guard
            let function = wire?["function"] as? [String: any Sendable],
            let params = function["parameters"] as? [String: any Sendable],
            let allProps = params["properties"] as? [String: any Sendable],
            let idsParam = allProps["ids"] as? [String: any Sendable]
        else {
            Issue.record("mcp_array wire 缺失")
            return
        }
        let itemsWire = idsParam["items"] as? [String: any Sendable]
        #expect(itemsWire?["type"] as? String == "integer", "wire items 丢失")
    }

    @Test("required 子集保真: mcp_optional 只标 a 必填（旧码压平 all）")
    func requiredSubsetFidelity() async throws {
        let (bridge, registry, _) = try await Self.makeBridge()
        defer { Task { await bridge.disconnectEndpoint(name: "mcp-fidelity") } }

        guard let entry = await registry.lookup("mcp_optional") else {
            Issue.record("mcp_optional 未注册")
            return
        }
        #expect(
            entry.schema.required == ["a"],
            "required 子集: \(String(describing: entry.schema.required))")

        let specs = await registry.toToolSpecs()
        let wire = specs.first(where: {
            ($0["function"] as? [String: any Sendable])?["name"] as? String == "mcp_optional"
        })
        let params =
            (wire?["function"] as? [String: any Sendable])?["parameters"] as? [String: any Sendable]
        let required = params?["required"] as? [String]
        #expect(required == ["a"], "wire required 压平 all: \(String(describing: required))")
    }

    #if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
    @Test("FM 路: 4 个富 schema 工具 makeDynamicSchema 全构建成功（wire 修正后）")
    @available(macOS 27.0, iOS 27.0, *)
    func fmSchemaBuildRichSchemas() async throws {
        let (bridge, registry, _) = try await Self.makeBridge()
        defer { Task { await bridge.disconnectEndpoint(name: "mcp-fidelity") } }

        let specs = await registry.toToolSpecs()
        var failures: [String: String] = [:]
        for name in ["mcp_number", "mcp_object", "mcp_array", "mcp_optional"] {
            guard
                let spec = specs.first(where: {
                    ($0["function"] as? [String: any Sendable])?["name"] as? String == name
                }),
                let dict = ((spec["function"] as? [String: any Sendable])?["parameters"])
                    as? [String: Any]
            else {
                failures[name] = "spec missing"
                continue
            }
            if let dynamic = FMToolProxy.makeDynamicSchema(from: dict, name: name),
                let schema = try? FoundationModels.GenerationSchema(root: dynamic, dependencies: [])
            {
                _ = schema
            } else {
                failures[name] = "makeDynamicSchema/GenerationSchema failed"
            }
        }
        #expect(failures.isEmpty, "FM schema failures: \(String(describing: failures))")
    }
    #endif
}
