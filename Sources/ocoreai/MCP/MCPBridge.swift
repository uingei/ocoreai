// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MCP Bridge — bidirectional MCP client + server composition.
import Foundation
import Logging

/// MCP endpoint for client connections.
struct MCPEndpoint: Codable, Sendable {
    let name: String
    let stdioCommand: String
    let stdioArgs: [String]
    let capabilities: [String]
}

/// MCP Bridge actor — manages server and client sides.
actor MCPBridge {
    private let server: MCPServer
    private let endpoints: [MCPEndpoint]
    private let log: Logger
    
    init(
        toolRegistry: ToolRegistry,
        transport: MCPStdioTransport,
        endpoints: [MCPEndpoint] = [],
        log: Logger = Logger(label: "ocoreai.mcp.bridge")
    ) {
        self.server = MCPServer(registry: toolRegistry, transport: transport, log: log)
        self.endpoints = endpoints
        self.log = log
    }
    
    /// Handle an incoming message line (from stdio client).
    func handleLine(_ line: String) async -> String? {
        guard !line.isEmpty else { return nil }
        return await server.dispatch(line)
    }
    
    /// Get server status.
    func status() async -> [String: String] {
        return [
            "server": "ocoreai-mcp",
            "version": "0.7.0",
            "endpoints": String(endpoints.count)
        ]
    }
    
    /// List registered external endpoints.
    func listEndpoints() async -> [[String: String]] {
        endpoints.map {
            ["name": $0.name, "command": $0.stdioCommand]
        }
    }
}
