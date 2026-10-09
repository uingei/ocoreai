// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Identity truth: every surface that reports a version must report the
/// SAME value derived from the running artifact — never a frozen literal.
/// (Shipped bug 2026-10: About said v1.0.0, metrics said 1.0.0, MCP said
/// 0.7.0, while v0.1.6 was the released tag.)
import Foundation
import Testing

@testable import ocoreai

@Suite("App version identity")
struct AppVersionIdentityTests {

    @Test("shortVersion is bundle-derived, never a frozen release literal")
    func bundleDerived() {
        let v = AppInfo.shortVersion
        // In the app bundle: the git-tag pipeline's value. In the SPM test
        // host (no Info.plist): the honest "dev" fallback.
        if let plist = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            #expect(v == plist)
        } else {
            #expect(v == "dev")
        }
    }

    @Test("MCP initialize reports the app's real version through dispatch")
    func mcpServerInfoMatchesAppInfo() async throws {
        let server = MCPServer(registry: ToolRegistry(), transport: MCPStdioTransport())
        let line = #"{"jsonrpc":"2.0","id":"1","method":"initialize","params":{}}"#
        let reply = try #require(await server.dispatch(line))
        // Envelope: {jsonrpc: String, id: String, result: {serverInfo: {...}}}
        // — drill with JSONSerialization; typed decode guessed wrong once
        // already (jsonrpc is a String, not a dict).
        let obj = try #require(
            JSONSerialization.jsonObject(with: reply.data(using: .utf8)!) as? [String: Any])
        let result = try #require(obj["result"] as? [String: Any])
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["version"] as? String == AppInfo.shortVersion)
        // Identity lie guard: must never be the historical frozen literal.
        #expect(serverInfo["version"] as? String != "0.7.0")
    }

    @Test("info tool reports the same version the About pane shows")
    func toolInfoMatchesAppInfo() async throws {
        let registry = ToolRegistry()
        await bootstrapBuiltInTools(registry: registry)
        let out = try await registry.call("info", arguments: #"{"topic":"version"}"#)
        #expect(out == AppInfo.shortVersion)
    }
}
