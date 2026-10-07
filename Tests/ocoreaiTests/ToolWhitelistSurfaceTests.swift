// ToolWhitelistSurfaceTests.swift — P0-3: declared-whitelist filtering of the
// injected tool surface, + 10-06 flip: resolveToolSurface is the single choke.
//
// Semantics under test:
//   1. Wire default flipped (10-06): client declared no tools[] (nil) →
//      ZERO tools injected (`resolveToolSurface` nil branch), never the
//      implicit full registry surface — live evidence: implicit full surface
//      made small models hallucinate tool calls on plain-text requests.
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

    // MARK: - resolveToolSurface: the single choke (10-06 flip)

    @Test("nil declared (client sent no tools[]) → ZERO tools, no-tools route")
    func nilDeclaredYieldsZeroSurface() async {
        let registry = await makeRegistry()
        let specs = await registry.toToolSpecs()
        let (surface, route) = resolveToolSurface(specs: specs, declaredNames: nil)
        #expect(surface.isEmpty, "nil must NOT re-open the full registry surface")
        #expect(route.contains("no-tools route"))
    }

    @Test("empty declared → ZERO tools, no-tools route")
    func emptyDeclaredYieldsZeroSurface() async {
        let registry = await makeRegistry()
        let specs = await registry.toToolSpecs()
        let (surface, route) = resolveToolSurface(specs: specs, declaredNames: [])
        #expect(surface.isEmpty)
        #expect(route.contains("no-tools route"))
    }

    @Test("non-empty declared → whitelist route, exactly those names in spec order")
    func declaredYieldsWhitelistRoute() async {
        let registry = await makeRegistry()
        let specs = await registry.toToolSpecs()
        let (surface, route) = resolveToolSurface(
            specs: specs, declaredNames: ["exec_command", "write_file"])
        let names = surface.compactMap {
            (($0["function"] as? [String: any Sendable])?["name"]) as? String
        }
        #expect(names == ["write_file", "exec_command"])  // spec order, not declared order
        #expect(route.contains("whitelist route"))
    }
}
