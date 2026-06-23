// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MCPTools — bridge ToolRegistry to MCP tools/list and tools/call.
///
/// Exposes registered tools as MCP stdio endpoints with automatic
/// JSON schema translation and argument forwarding.
import Foundation
import Logging

/// MCP tools module — translates ToolRegistry entries into MCP protocol format.
actor MCPTools {
    private let registry: ToolRegistry
    private let logger: Logger
    
    init(
        registry: ToolRegistry,
        log: Logger = Logger(label: "ocoreai.mcp.tools")
    ) {
        self.registry = registry
        self.logger = log
    }
    
    // MARK: - MCP tools/list
    
    /// List all available tools in MCP format.
    ///
    /// Returns `[String: Any]` array with `name` and `inputSchema` keys,
    /// compatible with MCP JSON-RPC `tools/list` response.
    func list() async -> [[String: Any]] {
        let toolNames = await registry.listTools()
        var result: [[String: Any]] = []
        for name in toolNames {
            if let schema = await registry.schema(for: name) {
                var props: [String: [String: Any]] = [:]
                for (paramName, type) in schema.parameters {
                    props[paramName] = ["type": type.rawValue]
                }
                result.append([
                    "name": name,
                    "inputSchema": [
                        "type": "object",
                        "properties": props,
                        "required": Array(schema.parameters.keys)
                    ]
                ])
            }
        }
        logger.info("tools/list returned \(result.count) tools")
        return result
    }
    
    // MARK: - MCP tools/call
    
    /// Execute a tool call and return MCP-formatted result.
    ///
    /// - Parameters:
    ///   - name: Tool name to invoke
    ///   - arguments: JSON object string of arguments
    /// - Returns: MCP content array with `type` and `text` keys
    func call(_ name: String, arguments: String) async -> [[String: Any]] {
        do {
            let output = try await registry.call(name, arguments: arguments)
            return [["type": "text", "text": output]]
        } catch {
            logger.warning("tools/call failed for '\(name)': \(error.localizedDescription)")
            return [["type": "text", "text": "\(error.localizedDescription)"]]
        }
    }
    
    // MARK: - Introspection
    
    /// Count of tools currently registered.
    func count() async -> Int {
        await registry.listTools().count
    }
}
