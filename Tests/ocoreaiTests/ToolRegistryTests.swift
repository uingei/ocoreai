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

import Foundation
import Logging
import Testing

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
            schema: ToolSchema(parameters: ["key": ToolParameter(type: .string)]),
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
        let schema = ToolSchema(parameters: [
            "msg": ToolParameter(type: .string, description: "message text"),
            "count": ToolParameter(type: .integer, description: "count value"),
        ])
        try? await registry.register(
            ToolEntry(name: "typed", toolset: "t", schema: schema, handler: { _ in "" }))
        let got = await registry.schema(for: "typed")
        #expect(got != nil)
        #expect(got?.parameters["msg"]?.type == .string)
        #expect(got?.parameters["msg"]?.description == "message text")
        #expect(got?.parameters["count"]?.type == .integer)
        #expect(got?.parameters["count"]?.description == "count value")
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
            ToolEntry(
                name: "echo", toolset: "debug", schema: ToolSchema(),
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
            ToolEntry(
                name: "boom", toolset: "debug", schema: ToolSchema(),
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
            ToolEntry(
                name: "unsafe", toolset: "debug", schema: ToolSchema(),
                handler: { _ in
                    throw NSError(
                        domain: "t", code: 0,
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
            ToolEntry(
                name: "repeater", toolset: "debug", schema: ToolSchema(),
                handler: { _ in "ok" }, maxDepth: 3))

        // First 3 calls should succeed
        for _ in 0 ..< 3 {
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

    private struct BrokenToolError: Error {}

    @Test("loop detection counts FAILED identical attempts (not just successes)")
    func repeatedFailuresAreLoopDetected() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(
                name: "breaker", toolset: "debug", schema: ToolSchema(),
                handler: { _ in throw BrokenToolError() }))

        // Attempt 1..maxHistoryDepth execute-and-fail (the net can only stop
        // AFTER maxHistoryDepth identical attempts, same as the success path).
        for _ in 0 ..< 3 {
            do {
                _ = try await registry.call("breaker", arguments: "{}")
                #expect(Bool(false), "Broken tool should throw")
            } catch {
                // Expected: executionFailed (or wrapped) — acceptable pre-cap.
            }
        }

        // Attempt maxHistoryDepth+1 with IDENTICAL args: pre-fix this threw
        // `executionFailed` again (net was blind to failures); post-fix the
        // loop gate fires FIRST, before the handler runs.
        do {
            _ = try await registry.call("breaker", arguments: "{}")
            #expect(Bool(false), "Expected loop detection throw on repeated failure")
        } catch let error as ToolError {
            #expect(error.localizedDescription.contains("loop detected"))
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    // ── exec-host failure breaker (absorbs codex #41454) ──────────────────
    // Scope: exec-host tools only (exec_shell / write_stdin / exec_poll) —
    // codex counts `exec` host failures, not every tool. Trigger: 3 consecutive
    // HANDLER failures → refused on the 4th call (distinct from the loop net,
    // which keys on identical re-attempts). Reset: any successful tool, or TTL.

    @Test("3 consecutive exec-host handler failures trip the breaker (breakerEngaged)")
    func execBreakerTripsAfter3Failures() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(
                name: "exec_shell", toolset: "debug", schema: ToolSchema(),
                handler: { _ in throw BrokenToolError() }))

        // 3 consecutive handler failures (varying args so the SHA loop net —
        // which keys on identical re-attempts — stays at ≤3 and does NOT fire).
        for i in 0 ..< 3 {
            let args = "{\"cmd\": \"failing \(i)\"}"
            do {
                _ = try await registry.call("exec_shell", arguments: args)
                #expect(Bool(false), "Broken exec tool should throw")
            } catch let error as ToolError {
                #expect(error.localizedDescription.contains("execution failed"))
            } catch {
                #expect(Bool(false), "Unexpected error type: ")
            }
        }

        // 4th attempt (a 4th distinct input, so loop net still <3): the breaker
        // fires BEFORE the handler runs and reports itself distinctly.
        do {
            _ = try await registry.call("exec_shell", arguments: "{\"cmd\": \"again\"}")
            #expect(Bool(false), "Expected breaker to refuse the call")
        } catch let error as ToolError {
            #expect(error.localizedDescription.contains("Exec host blocked"))
        } catch {
            #expect(Bool(false), "Unexpected error type: ")
        }
    }

    @Test("a success between exec failures resets the breaker streak")
    func execBreakerResetsAfterSuccess() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(
                name: "exec_shell", toolset: "debug", schema: ToolSchema(),
                handler: { _ in throw BrokenToolError() }))
        try? await registry.register(
            ToolEntry(
                name: "read_file", toolset: "debug", schema: ToolSchema(),
                handler: { _ in "ok" }))

        // 2 failures → success (resets) → 2 more failures. Streak never reaches 3
        // consecutively, so the breaker must NOT engage.
        let failing: [String] = [
            "{\"cmd\": \"a\"}", "{\"cmd\": \"b\"}",
            "{\"cmd\": \"c\"}", "{\"cmd\": \"d\"}",
        ]
        for (i, args) in failing.enumerated() {
            if i == 2 { _ = try? await registry.call("read_file", arguments: "{}") }
            do {
                _ = try await registry.call("exec_shell", arguments: args)
                #expect(Bool(false), "Broken exec tool should throw")
            } catch let error as ToolError {
                // All four must be plain handler failures (pre-breaker), proving
                // the mid-run success kept the streak below threshold.
                #expect(error.localizedDescription.contains("execution failed"))
            } catch {
                #expect(Bool(false), "Unexpected error type: ")
            }
        }
    }

    @Test("non-exec handler failures do NOT count toward the exec breaker")
    func nonExecFailuresIgnoredByBreaker() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(
                name: "exec_shell", toolset: "debug", schema: ToolSchema(),
                handler: { _ in throw BrokenToolError() }))
        try? await registry.register(
            ToolEntry(
                name: "bad_tool", toolset: "debug", schema: ToolSchema(),
                handler: { _ in throw BrokenToolError() }))

        // 5 handler failures of a NON-exec tool (varying args, loop net stays <3):
        // codex scopes the streak to the exec host — these must NOT advance it.
        for i in 0 ..< 5 {
            do {
                _ = try await registry.call("bad_tool", arguments: "{\"n\": \(i)}")
                #expect(Bool(false), "bad_tool should throw")
            } catch let error as ToolError {
                #expect(error.localizedDescription.contains("execution failed"))
            } catch {
                #expect(Bool(false), "Unexpected error type: ")
            }
        }

        // exec host still has its OWN full 3-failure tolerance: 3 failures pass
        // (each a plain handler failure — none refused by the breaker), and only
        // the 4th exec failure engages it. Proves the 5 non-exec failures above
        // did not pre-consume the exec streak (which would have tripped sooner).
        for i in 0 ..< 3 {
            do {
                _ = try await registry.call("exec_shell", arguments: "{\"cmd\": \"fail\(i)\"}")
                #expect(Bool(false), "Broken exec tool should throw")
            } catch let error as ToolError {
                #expect(error.localizedDescription.contains("execution failed"))
            } catch {
                #expect(Bool(false), "Unexpected error type: ")
            }
        }
        do {
            _ = try await registry.call("exec_shell", arguments: "{\"cmd\": \"4th\"}")
            #expect(Bool(false), "Expected breaker to engage on 4th exec failure")
        } catch let error as ToolError {
            #expect(error.localizedDescription.contains("Exec host blocked"))
        } catch {
            #expect(Bool(false), "Unexpected error type: ")
        }
    }

    @Test("TTL zero ⇒ exec breaker expires instantly (never sticks)")
    func execBreakerTTLExpiry() async {
        let registry = ToolRegistry(execFailureTTL: .zero)
        try? await registry.register(
            ToolEntry(
                name: "exec_shell", toolset: "debug", schema: ToolSchema(),
                handler: { _ in throw BrokenToolError() }))

        // 3 failures record the streak, but with TTL = .zero the next check
        // sees the streak as already expired → the 4th call is the handler's
        // own failure again, NOT a refusal.
        for i in 0 ..< 4 {
            do {
                _ = try await registry.call("exec_shell", arguments: "{\"cmd\": \"x\(i)\"}")
                #expect(Bool(false), "Broken exec tool should throw")
            } catch let error as ToolError {
                #expect(error.localizedDescription.contains("execution failed"))
            } catch {
                #expect(Bool(false), "Unexpected error type: ")
            }
        }
    }

    @Test("different input bypasses loop detection")
    func differentInputBypasses() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(
                name: "diff_in", toolset: "debug", schema: ToolSchema(),
                handler: { _ in "ok" }))

        for i in 0 ..< 10 {
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
