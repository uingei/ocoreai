// Copyright © 2026 uingei@163.com.
/// MCP Endpoint & Config Tests
///
/// Coverage: MCPEndpoint model, MCPEndpoint.Status, MCPBridgeConfig defaults
/// Rationale: First line of defense for MCP module — verify DTO correctness

import Foundation
import Testing
import ocoreaiTestUtilities
@testable import ocoreai

@Suite("MCP — Endpoint model")
struct MCPEndpointTests {
    @Test("Endpoint fields match constructor")
    func fieldsMatchConstructor() {
        let ep = MCPEndpoint(
            name: "my-server",
            stdioCommand: "npx",
            stdioArgs: ["-y", "@server/example"],
            capabilities: ["tools", "resources"]
        )
        #expect(ep.name == "my-server")
        #expect(ep.stdioCommand == "npx")
        #expect(ep.stdioArgs == ["-y", "@server/example"])
        #expect(ep.capabilities == ["tools", "resources"])
    }

    @Test("Default capabilities are [\"tools\"]")
    func defaultCapabilities() {
        let ep = MCPEndpoint(name: "x", stdioCommand: "echo")
        #expect(ep.capabilities == ["tools"])
    }

    @Test("Status Codable round-trip")
    func statusRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for status: MCPEndpoint.Status in [.connected, .disconnected, .connecting, .errored] {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(MCPEndpoint.Status.self, from: data)
            #expect(decoded == status)
        }
    }

    @Test("FanOutStrategy raw values")
    func fanOutStrategyRawValues() {
        #expect(MCPEndpoint.FanOutStrategy.parallel.rawValue == "parallel")
        #expect(MCPEndpoint.FanOutStrategy.serial.rawValue == "serial")
    }
}

@Suite("MCP — Bridge Config")
struct MCPBridgeConfigTests {
    @Test("Default config matches documented values")
    func defaultConfig() {
        let config = MCPBridgeConfig.default
        #expect(config.callCacheEnabled == true)
        #expect(config.callCacheMaxEntries == 256)
        #expect(config.callCacheTTLSeconds == 60)
        #expect(config.serverTimeoutSeconds == 10)
    }

    @Test("Custom config overrides work")
    func customConfig() {
        let config = MCPBridgeConfig(
            callCacheEnabled: false,
            callCacheMaxEntries: 128,
            callCacheTTLSeconds: 30,
            serverTimeoutSeconds: 5,
            fanOutStrategy: .serial
        )
        #expect(config.callCacheEnabled == false)
        #expect(config.callCacheMaxEntries == 128)
        #expect(config.callCacheTTLSeconds == 30)
        #expect(config.serverTimeoutSeconds == 5)
        #expect(config.fanOutStrategy == .serial)
    }
}
