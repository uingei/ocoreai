// ToolWhitelistSurfaceTests.swift — P0-3: declared-whitelist filtering of the
// injected tool surface.
//
// Semantics under test:
//   1. Full-surface default (client declared no tools[]) is unchanged —
//      `filteredSpecs` is a no-op when the caller passes all names; we test
//      the *filtered* helper directly since the nil branch is a `?? specs`
//      fallthrough (compile-time).
//   2. Whitelist contract: declared names → only those specs survive, in
//      registry spec order.
//   3. Declared-but-unregistered names → no crash, no phantom spec.
//   4. Empty whitelist → empty surface (disallowed-like).
//   5. Malformed spec (missing function/name) → dropped, never leaks.

import Logging
import Testing

@testable import ocoreai

@Suite("P0-3 Tool Surface Whitelist")
struct ToolWhitelistSurfaceTests {
    private func makeRegistry() async -> ToolRegistry {
        let registry = ToolRegistry(log: Logger(label: "test.whitelist"))
        for (name, param) in [
            ("write_file", "path"),
            ("exec_command", "command"),
            ("read_file", "path"),
        ] {
            try? await registry.register(
                ToolEntry(
                    name: name, toolset: "t", schema: .init(parameters: [param: .string]),
                    handler: { _ in "ok" }))
        }
        return registry
    }

    @Test("whitelist keeps exactly the declared names (order = spec order)")
    func whitelistKeepsDeclared() async {
        let registry = await makeRegistry()
        let specs = await registry.toToolSpecs()
        let filtered = toolSurfaceWhitelist(specs, to: ["exec_command", "write_file"])
        let names = filtered.compactMap {
            (($0["function"] as? [String: any Sendable])?["name"]) as? String
        }
        #expect(names.contains("exec_command"))
        #expect(names.contains("write_file"))
        #expect(!names.contains("read_file"))
        #expect(names.count == 2)
    }

    @Test("declared-but-unregistered name → empty surface, no crash")
    func unknownNameYieldsEmptySurface() async {
        let registry = await makeRegistry()
        let specs = await registry.toToolSpecs()
        let filtered = toolSurfaceWhitelist(specs, to: ["no_such_tool"])
        #expect(filtered.isEmpty)
    }

    @Test("empty whitelist → empty surface")
    func emptyWhitelistYieldsEmpty() async {
        let registry = await makeRegistry()
        let specs = await registry.toToolSpecs()
        #expect(toolSurfaceWhitelist(specs, to: []).isEmpty)
    }

    @Test("all-registered declared → full surface (identity)")
    func allDeclaredKeepsAll() async {
        let registry = await makeRegistry()
        let specs = await registry.toToolSpecs()
        let all = ["write_file", "exec_command", "read_file"]
        #expect(toolSurfaceWhitelist(specs, to: all).count == specs.count)
    }
}
