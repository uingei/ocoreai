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

    /// The net counts ONE conversation's repeats. Measured live 10-21: four
    /// `sleep(duration_ms:8000)` calls from four different sessions inside 60 s made the fourth
    /// come back `[tool_error: Execution loop detected: sleep] FAILED — its effects do not
    /// exist.` to a client that had called the tool once. The registry is one process-wide
    /// actor, so the streak has to be bucketed by the conversation that owns the call — the
    /// same reason `SessionIsolationTests` exists and the reason `sleep` asks
    /// `SteerQueue.pendingCount(sessionKey:)` rather than a global flag.
    @Test("loop detection is scoped per conversation — another conversation is not contaminated")
    func loopDetectionIsConversationScoped() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(
                name: "repeater", toolset: "debug", schema: ToolSchema(),
                handler: { _ in "ok" }, maxDepth: 3))
        let args = #"{"duration_ms":8000}"#

        // Conversation A fills its own bucket: 3 identical calls pass, the 4th is refused.
        for _ in 0 ..< 3 {
            do {
                _ = try await registry.call("repeater", arguments: args, conversationKey: "conv-A")
            } catch {
                #expect(Bool(false), "conv-A call should succeed before the cap: \(error)")
            }
        }
        do {
            _ = try await registry.call("repeater", arguments: args, conversationKey: "conv-A")
            #expect(Bool(false), "conv-A must still trip its own net at depth+1")
        } catch let error as ToolError {
            #expect(error.localizedDescription.contains("loop detected"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }

        // Conversation B, same tool, byte-identical arguments: A's streak must not be B's.
        do {
            _ = try await registry.call("repeater", arguments: args, conversationKey: "conv-B")
        } catch {
            #expect(
                Bool(false),
                """
                conv-B's first identical call was refused because conv-A repeated it — \
                cross-conversation contamination: \(error)
                """)
        }

        // Scoping must not weaken the net: B trips on its own repeats too.
        for _ in 0 ..< 2 {
            _ = try? await registry.call("repeater", arguments: args, conversationKey: "conv-B")
        }
        do {
            _ = try await registry.call("repeater", arguments: args, conversationKey: "conv-B")
            #expect(Bool(false), "conv-B must trip its own net after its own 3 identical calls")
        } catch let error as ToolError {
            #expect(error.localizedDescription.contains("loop detected"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    /// Lanes with no conversation (inbound MCP `tools/call`, a proactive GUI read, a harness)
    /// share one `process` bucket — the net stays armed where no identity exists, rather than
    /// being switched off by the scoping above.
    @Test("keyless calls share one bucket, so scoping cannot silently disarm the net")
    func keylessCallsStillShareOneBucket() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(
                name: "repeater", toolset: "debug", schema: ToolSchema(),
                handler: { _ in "ok" }, maxDepth: 3))
        let args = #"{"duration_ms":8000}"#

        for _ in 0 ..< 3 {
            _ = try? await registry.call("repeater", arguments: args)
        }
        do {
            _ = try await registry.call("repeater", arguments: args)
            #expect(Bool(false), "keyless calls must accumulate in one bucket and trip at depth+1")
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

        // Attempt maxHistoryDepth+1 with IDENTICAL args: this must fire the
        // loop gate FIRST (before any handler runs), rather than retrying and
        // throwing `executionFailed` again.
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
    // Scope: the tools that RUN a command (`exec_command` + the live-session trio),
    // not every tool — codex counts failures of `exec`. Trigger: 3 consecutive
    // HANDLER failures → refused on the 4th call (distinct from the loop net, which
    // keys on identical re-attempts). Reset: a successful tool in the same
    // conversation, or TTL. Streaks are bucketed per conversation: the registry is
    // process-wide, so one client's grind must not refuse another client's run.

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

    @Test("the breaker covers exec_command — the name the default toolset runs")
    func execCommandTripsBreaker() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(
                name: "exec_command", toolset: "debug", schema: ToolSchema(),
                handler: { _ in throw BrokenToolError() }))

        // `exec_shell`-only tests could not see this: the default `execHostTools` set
        // named the live-session trio, and `exec_command` — the one-shot runner every
        // default toolset registers — was outside it, so the breaker never fired for
        // the surface an agent actually grinds. Args vary to keep the loop net out.
        for i in 0 ..< 3 {
            do {
                _ = try await registry.call("exec_command", arguments: "{\"command\": \"run\(i)\"}")
                #expect(Bool(false), "Broken exec_command should throw")
            } catch let error as ToolError {
                #expect(error.localizedDescription.contains("execution failed"))
            } catch {
                #expect(Bool(false), "Unexpected error type: ")
            }
        }
        do {
            _ = try await registry.call("exec_command", arguments: "{\"command\": \"fourth\"}")
            #expect(Bool(false), "Expected breaker to refuse the 4th exec_command")
        } catch let error as ToolError {
            #expect(error.localizedDescription.contains("Exec host blocked"))
        } catch {
            #expect(Bool(false), "Unexpected error type: ")
        }
    }

    @Test("exec breaker streaks are per conversation, not process-wide")
    func execBreakerIsScopedToConversation() async {
        let registry = makeRegistry()
        try? await registry.register(
            ToolEntry(
                name: "exec_command", toolset: "debug", schema: ToolSchema(),
                handler: { _ in throw BrokenToolError() }))

        // Conversation A burns its 3 failures.
        for i in 0 ..< 3 {
            _ = try? await registry.call(
                "exec_command", arguments: "{\"command\": \"a\(i)\"}", conversationKey: "conv-A")
        }

        // B runs the same tool on the same process-wide registry: it inherits none of
        // A's streak, so its call must reach the handler (plain failure, not refusal).
        do {
            _ = try await registry.call(
                "exec_command", arguments: "{\"command\": \"b1\"}", conversationKey: "conv-B")
            #expect(Bool(false), "Broken exec_command should throw")
        } catch let error as ToolError {
            #expect(error.localizedDescription.contains("execution failed"))
        } catch {
            #expect(Bool(false), "Unexpected error type: ")
        }

        // A is still broken: B's clean run does not buy A's breaker back.
        do {
            _ = try await registry.call(
                "exec_command", arguments: "{\"command\": \"a4\"}", conversationKey: "conv-A")
            #expect(Bool(false), "Expected A's own breaker to still refuse")
        } catch let error as ToolError {
            #expect(error.localizedDescription.contains("Exec host blocked"))
        } catch {
            #expect(Bool(false), "Unexpected error type: ")
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
