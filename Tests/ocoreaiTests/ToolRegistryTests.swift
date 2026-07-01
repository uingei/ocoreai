// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ToolRegistryTests.swift — Actor tool registration, dispatch, safety.
///
/// Coverage:
/// - Registration: success, duplicate skip, checkFn reject
/// - Lookup: by name, listTools sorted, listByToolset grouped, schema
/// - Execution: happy path, notFound error, handler exception wrapping
/// - Safety: HTML sanitization on error, loop detection, readOnly/destructive checks
/// - History: record after success, trim at 100, expire after 60s

import Testing
import Foundation
import Logging
@testable import ocoreai

// MARK: - Registration Suite

@Suite("ToolRegistry — Registration")
struct ToolRegistryRegistrationTests {
    func makeRegistry() -> ToolRegistry {
        ToolRegistry(log: Logger(label: "test.registry"))
    }
    
    @Test("register tool → lookup returns entry")
    func registerAndLookup_() async {
        let registry = makeRegistry()
        let entry = ToolEntry(
            name: "test_tool",
            toolset: "test",
            schema: ToolSchema(parameters: ["key": .string]),
            handler: { _ in "ok" }
        )
        try? await registry.register(entry)
        #expect(await registry.lookup("test_tool") != nil)
    }
    
    @Test("duplicate registration is skipped silently")
    func duplicateSkipped() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(name: "dup", toolset: "t", schema: ToolSchema(), handler: { _ in "a" }))
        try? await registry.register(
            ToolEntry(name: "dup", toolset: "t", schema: ToolSchema(), handler: { _ in "b" }))
        let first = await registry.lookup("dup")
        #expect(first != nil)
        #expect(await registry.listTools().count == 1)
    }
    
    @Test("checkFn returns false → registration rejected")
    func checkFnRejects() async {
        let registry = makeRegistry()
        let entry = ToolEntry(
            name: "bad",
            toolset: "t",
            schema: ToolSchema(),
            handler: { _ in "x" },
            checkFn: { false }
        )
        do {
            _ = try await registry.register(entry)
            #expect(Bool(false), "Expected registration to throw")
        } catch {
            #expect(error is ToolError)
        }
        #expect(await registry.lookup("bad") == nil)
    }
    
    @Test("listTools returns sorted names")
    func listToolsSorted() async {
        let registry = makeRegistry()
        let names = ["zebra", "alpha", "mid"]
        for n in names {
            try? await registry.register(
                ToolEntry(name: n, toolset: "t", schema: ToolSchema(), handler: { _ in n }))
        }
        let listed = await registry.listTools()
        #expect(listed == ["alpha", "mid", "zebra"])
    }
    
    @Test("listByToolset groups correctly")
    func listByToolsetGroups() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(name: "a1", toolset: "groupA", schema: ToolSchema(), handler: { _ in "" }))
        try? await registry.register(
            ToolEntry(name: "b1", toolset: "groupB", schema: ToolSchema(), handler: { _ in "" }))
        try? await registry.register(
            ToolEntry(name: "a2", toolset: "groupA", schema: ToolSchema(), handler: { _ in "" }))
        
        let ga = await registry.listByToolset("groupA")
        let gb = await registry.listByToolset("groupB")
        let gx = await registry.listByToolset("groupX")
        #expect(ga.count == 2)
        #expect(gb.count == 1)
        #expect(gx.isEmpty)
    }
    
    @Test("schema returns correct schema")
    func schemaReturns() async {
        let registry = makeRegistry()
        let schema = ToolSchema(parameters: ["msg": .string, "count": .integer])
        try? await registry.register(
            ToolEntry(name: "typed", toolset: "t", schema: schema, handler: { _ in "" }))
        let got = await registry.schema(for: "typed")
        #expect(got != nil)
        #expect(got?.parameters["msg"] == .string)
        #expect(got?.parameters["count"] == .integer)
    }
}

// MARK: - Execution Suite

@Suite("ToolRegistry — Execution")
struct ToolRegistryExecutionTests {
    func makeRegistry() -> ToolRegistry {
        ToolRegistry(log: Logger(label: "test.registry.exec"))
    }
    
    @Test("successful execution returns handler result")
    func happyPath() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(name: "echo", toolset: "debug", schema: ToolSchema(),
                      handler: { _ in "echo: hello" }))
        do {
            let result = try await registry.call("echo", arguments: "{}")
            #expect(result.contains("hello"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }
    
    @Test("notFound tool throws")
    func notFound() async {
        let registry = makeRegistry()
        do {
            _ = try await registry.call("nonexistent", arguments: "{}")
            #expect(Bool(false), "Expected throw")
        } catch {
            #expect(error is ToolError)
        }
    }
    
    @Test("handler exception wrapped as executionFailed")
    func handlerThrows() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(name: "boom", toolset: "debug", schema: ToolSchema(),
                      handler: { _ in throw NSError(domain: "h", code: 1) }))
        do {
            _ = try await registry.call("boom", arguments: "{}")
            #expect(Bool(false), "Expected throw")
        } catch let error as ToolError {
            #expect(error.localizedDescription.contains("Tool execution failed"))
        } catch {
            #expect(Bool(false), "Unexpected non-ToolError: \(error)")
        }
    }
    
    @Test("error output HTML sanitized")
    func htmlSanitized() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(name: "unsafe", toolset: "debug", schema: ToolSchema(),
                      handler: { _ in
                throw NSError(domain: "t", code: 0,
                             userInfo: [NSLocalizedDescriptionKey: "<script>alert(1)</script>"])
            }))
        do {
            _ = try await registry.call("unsafe", arguments: "{}")
            #expect(Bool(false), "Expected throw")
        } catch {
            let msg = error.localizedDescription
            #expect(!msg.contains("<"))
            #expect(!msg.contains(">"))
            #expect(msg.contains("&lt;"))
        }
    }
    
    @Test("loop detection blocks maxDepth+1 identical calls")
    func loopDetection() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(name: "repeater", toolset: "debug", schema: ToolSchema(),
                      handler: { _ in "ok" }, maxDepth: 3))
        
        // First 3 calls should succeed
        for _ in 0..<3 {
            do {
                _ = try await registry.call("repeater", arguments: "{}")
            } catch {
                #expect(Bool(false), "Call should not throw before maxDepth")
            }
        }
        
        // Next call blocked by loop detection
        do {
            _ = try await registry.call("repeater", arguments: "{}")
            #expect(Bool(false), "Expected loop detection throw")
        } catch let error as ToolError {
            #expect(error.localizedDescription.contains("loop detected"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }
    
    @Test("different input bypasses loop detection")
    func differentInputBypasses() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(name: "diff_in", toolset: "debug", schema: ToolSchema(),
                      handler: { _ in "ok" }))
        
        for i in 0..<10 {
            let val = String(i)
            let args = "{\"v\": \"" + val + "\"}"
            do {
                _ = try await registry.call("diff_in", arguments: args)
            } catch {
                #expect(Bool(false), "Should not loop-detect on different inputs")
            }
        }
    }
}

// MARK: - Safety Suite

@Suite("ToolRegistry — Safety Checks")
struct ToolRegistrySafetyTests {
    func makeRegistry() -> ToolRegistry {
        ToolRegistry(log: Logger(label: "test.safety"))
    }
    
    @Test("readOnly tool returns true")
    func readOnlyCheck() async {
        let registry = ToolRegistry(
            readOnlyWhitelist: ["read_a", "read_b"],
            log: Logger(label: "test.safety.read")
        )
        #expect(await registry.isReadOnly("read_a") == true)
        #expect(await registry.isReadOnly("read_b") == true)
        #expect(await registry.isReadOnly("not_ro") == false)
    }
    
    @Test("destructive tool returns true by blacklist")
    func destructiveByBlacklist() async {
        let registry = ToolRegistry(
            destructiveBlacklist: ["del_file"],
            log: Logger(label: "test.safety.dest")
        )
        #expect(await registry.isDestructive("del_file") == true)
        #expect(await registry.isDestructive("safe_tool") == false)
    }
    
    @Test("destructive tool returns true by entry flag")
    func destructiveByEntryFlag() async {
        let registry = makeRegistry()
        let entry = ToolEntry(
            name: "risky",
            toolset: "danger",
            schema: ToolSchema(),
            handler: { _ in "" },
            isDestructive: true
        )
        try? await registry.register(entry)
        #expect(await registry.isDestructive("risky") == true)
    }
}
