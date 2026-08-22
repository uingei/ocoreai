// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ToolHookTests.swift — Codex-aligned hook surface (PreToolUse veto, PostToolUse observation).
///
/// Baseline: codex `codex-rs/protocol/src/protocol.rs` `HookEventName`
/// (preToolUse → deny/ask/allow gating, postToolUse → observation).
///
/// Coverage (exact-value assertions, aligned to the shipped API):
/// - `ToolMatcher`: empty→all, comma list, `*` glob, case-sensitive exact
/// - `ToolHookRunner.evaluatePreToolUse`: no-hooks→allow, deny short-circuit,
///   ask, deny-beats-ask (both orders), first-ask-wins, matcher skip, context fields
/// - `ToolHookRunner.firePostToolUse`: success/error context, matcher skip, empty runner
/// - `ToolRegistry.call` integration (the real chokepoint):
///   deny → `ToolError.denied` + handler never runs; ask → deny;
///   allow → handler runs + PostToolUse observed; failure → observed with error

import Foundation
import Testing

@testable import ocoreai

// MARK: - Reference sink (actor: handlers @Sendable)

actor HookSink {
    private(set) var post:
        [(event: String, tool: String, arguments: String, result: String?, error: String?)] = []

    func recordPost(_ ctx: HookContext) {
        post.append((ctx.event.rawValue, ctx.toolName ?? "", ctx.arguments, ctx.result, ctx.error))
    }
}

// MARK: - ToolMatcher

@Suite("ToolHook — ToolMatcher")
struct ToolMatcherTests {
    @Test("empty pattern list → matches everything")
    func emptyMatchesAll() {
        let m = ToolMatcher("")
        #expect(m.matches("anything") == true)
        #expect(m.matches("") == true)
    }

    @Test("star → matches everything")
    func star() {
        let m = ToolMatcher("*")
        #expect(m.matches("mcp.search") == true)
        #expect(m.matches("") == true)
    }

    @Test("comma list → exact names, case-sensitive")
    func commaList() {
        let m = ToolMatcher("write_file, delete_file")
        #expect(m.matches("write_file") == true)
        #expect(m.matches("delete_file") == true)
        #expect(m.matches("WRITE_FILE") == false)
        #expect(m.matches("read_file") == false)
    }

    @Test("trailing glob = prefix (dot is literal)")
    func trailingGlob() {
        let m = ToolMatcher("mcp.*")
        #expect(m.matches("mcp.search") == true)
        #expect(m.matches("mcp.search.deep") == true)
        #expect(m.matches("mcpsearch") == false)  // dot is now a literal, not a regex any-char
        #expect(m.matches("mcp") == false)
        #expect(m.matches("other") == false)
    }

    @Test("inner glob = ordered prefix+suffix")
    func innerGlob() {
        let m = ToolMatcher("*_file")
        #expect(m.matches("write_file") == true)
        #expect(m.matches("read_file") == true)
        #expect(m.matches("file_writer") == false)
    }

    @Test("special chars escaped (not glob wildcards)")
    func escaping() {
        let m = ToolMatcher("a+b")
        #expect(m.matches("a+b") == true)
        #expect(m.matches("aXb") == false)
    }
}

// MARK: - evaluatePreToolUse

@Suite("ToolHook — evaluatePreToolUse")
struct EvaluatePreToolUseTests {
    @Test("no hooks → allow")
    func noHooks() async {
        let runner = ToolHookRunner(hooks: [])
        let verdict = await runner.evaluatePreToolUse(toolName: "write_file")
        #expect(verdict == .allow)
    }

    @Test("deny hook → exact reason, later hooks short-circuited")
    func denyShortCircuits() async {
        let second = RanCounter()
        let runner = ToolHookRunner(hooks: [
            Hook.any { _ in .deny(reason: "blocked-by-policy") },
            Hook.any { _ in
                await second.increment()
                return .allow
            },
        ])
        let verdict = await runner.evaluatePreToolUse(toolName: "write_file", sessionId: "s1")
        #expect(verdict == .deny(reason: "blocked-by-policy"))
        #expect(await second.value == 0)
    }

    @Test("ask hook → ask with exact reason")
    func askHook() async {
        let runner = ToolHookRunner(hooks: [
            Hook.any { _ in .ask(reason: "confirm?") }
        ])
        let verdict = await runner.evaluatePreToolUse(toolName: "execute_code")
        #expect(verdict == .ask(reason: "confirm?"))
    }

    @Test("deny beats ask regardless of hook order")
    func denyBeatsAsk() async {
        let denyFirst = ToolHookRunner(hooks: [
            Hook.any { _ in .deny(reason: "no") },
            Hook.any { _ in .ask(reason: "really?") },
        ])
        #expect(await denyFirst.evaluatePreToolUse(toolName: "x") == .deny(reason: "no"))

        let askFirst = ToolHookRunner(hooks: [
            Hook.any { _ in .ask(reason: "really?") },
            Hook.any { _ in .deny(reason: "no") },
        ])
        #expect(await askFirst.evaluatePreToolUse(toolName: "x") == .deny(reason: "no"))
    }

    @Test("first-ask wins when no deny")
    func firstAskWins() async {
        let runner = ToolHookRunner(hooks: [
            Hook.any { _ in .allow },
            Hook.any { _ in .ask(reason: "first-ask") },
            Hook.any { _ in .ask(reason: "second-ask") },
        ])
        let verdict = await runner.evaluatePreToolUse(toolName: "x")
        #expect(verdict == .ask(reason: "first-ask"))
    }

    @Test("matcher miss → hook skipped → allow; matcher hit → deny")
    func matcherGates() async {
        let runner = ToolHookRunner(hooks: [
            Hook.matching("delete_file") { _ in .deny(reason: "no-delete") }
        ])
        #expect(await runner.evaluatePreToolUse(toolName: "read_file") == .allow)
        #expect(
            await runner.evaluatePreToolUse(toolName: "delete_file") == .deny(reason: "no-delete"))
    }

    @Test("context fields exact on pre-tool hook")
    func contextFields() async {
        let runner = ToolHookRunner(hooks: [
            Hook.post { ctx in
                let ok =
                    ctx.event == .preToolUse
                    && ctx.toolName == "write_file"
                    && ctx.arguments == "{\"path\":\"/tmp\"}"
                    && ctx.sessionId == "sess-42"
                    && ctx.result == nil
                    && ctx.error == nil
                return ok ? .allow : .deny(reason: "fields-wrong")
            }
        ])
        let verdict = await runner.evaluatePreToolUse(
            toolName: "write_file", arguments: "{\"path\":\"/tmp\"}", sessionId: "sess-42")
        #expect(verdict == .allow)
    }
}

// MARK: - firePostToolUse

@Suite("ToolHook — firePostToolUse (observation)")
struct FirePostToolUseTests {
    @Test("success path: event/tool/arguments/result captured, error nil")
    func successPath() async {
        let sink = HookSink()
        let runner = ToolHookRunner(hooks: [
            Hook.post { ctx in
                await sink.recordPost(ctx)
                return .allow
            }
        ])
        await runner.firePostToolUse(
            toolName: "write_file", arguments: "{}", result: "saved", sessionId: "s9")
        #expect(await sink.post.count == 1)
        #expect((await sink.post)[0].event == "PostToolUse")
        #expect((await sink.post)[0].tool == "write_file")
        #expect((await sink.post)[0].arguments == "{}")
        #expect((await sink.post)[0].result == "saved")
        #expect((await sink.post)[0].error == nil)
    }

    @Test("error path: error captured, result nil")
    func errorPath() async {
        let sink = HookSink()
        let runner = ToolHookRunner(hooks: [
            Hook.post { ctx in
                await sink.recordPost(ctx)
                return .allow
            }
        ])
        await runner.firePostToolUse(toolName: "execute_code", error: "boom")
        #expect(await sink.post.count == 1)
        #expect((await sink.post)[0].error == "boom")
        #expect((await sink.post)[0].result == nil)
    }

    @Test("matcher miss → post hook skipped")
    func matcherSkips() async {
        let sink = HookSink()
        let runner = ToolHookRunner(hooks: [
            Hook.post(matcher: ToolMatcher("delete_file")) { ctx in
                await sink.recordPost(ctx)
                return .allow
            }
        ])
        await runner.firePostToolUse(toolName: "read_file")
        #expect(await sink.post.count == 0)
    }

    @Test("empty runner: zero cost, no crash")
    func emptyRunner() async {
        let runner = ToolHookRunner.empty
        #expect(runner.isEmpty == true)
        #expect(runner.hooks.count == 0)
        await runner.firePostToolUse(toolName: "x")
        #expect(await runner.evaluatePreToolUse(toolName: "x") == .allow)
    }
}

// MARK: - ToolRegistry.call integration (the real chokepoint)

@Suite("ToolHook — ToolRegistry.call integration")
struct ToolRegistryHookIntegrationTests {
    private func entry(name: String = "write_file", throws err: ToolError? = nil) -> ToolEntry {
        ToolEntry(
            name: name, toolset: "fs",
            schema: ToolSchema(),
            handler: { (_: String) async throws -> String in
                if let err { throw err }
                return "EXECUTED"
            })
    }

    @Test("deny hook → ToolError.denied, handler NEVER runs")
    func denyVeto() async throws {
        let ran = RanCounter()
        let registry = ToolRegistry(hooks: [
            Hook.matching("write_file") { _ in .deny(reason: "blocked-by-policy") }
        ])
        let e = ToolEntry(
            name: "write_file", toolset: "fs", schema: ToolSchema(),
            handler: { (_: String) async throws -> String in
                await ran.increment()
                return "EXECUTED"
            })
        try await registry.register(e)
        do {
            _ = try await registry.call("write_file", arguments: "{}", caller: "t")
            Issue.record("expected ToolError.denied, got success")
        } catch let ToolError.denied(reason) {
            #expect(reason == "blocked-by-policy")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
        #expect(await ran.value == 0)
    }

    @Test("ask hook → treated as deny (no approval surface), exact reason")
    func askTreatedAsDeny() async throws {
        let registry = ToolRegistry(hooks: [
            Hook.any { _ in .ask(reason: "needs-approval") }
        ])
        try await registry.register(entry())
        do {
            _ = try await registry.call("write_file", arguments: "{}", caller: "t")
            Issue.record("expected ToolError.denied, got success")
        } catch let ToolError.denied(reason) {
            #expect(reason == "needs-approval")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("allow hook → handler runs, exact result, PostToolUse observed")
    func allowRunsAndObserves() async throws {
        let sink = HookSink()
        let registry = ToolRegistry(hooks: [
            Hook.any { _ in .allow },
            Hook.post { ctx in
                await sink.recordPost(ctx)
                return .allow
            },
        ])
        try await registry.register(entry())
        let result = try await registry.call(
            "write_file", arguments: "{\"path\":\"/tmp\"}", caller: "t")
        #expect(result == "EXECUTED")
        #expect(await sink.post.count == 1)
        #expect((await sink.post)[0].event == "PostToolUse")
        #expect((await sink.post)[0].arguments == "{\"path\":\"/tmp\"}")
        #expect((await sink.post)[0].result == "EXECUTED")
        #expect((await sink.post)[0].error == nil)
    }

    @Test("handler failure → original ToolError propagates, PostToolUse observed with error")
    func failureObserved() async throws {
        let sink = HookSink()
        let registry = ToolRegistry(hooks: [
            Hook.post { ctx in
                await sink.recordPost(ctx)
                return .allow
            }
        ])
        try await registry.register(entry(throws: .invalidParameter("bad-arg")))
        do {
            _ = try await registry.call("write_file", arguments: "{}", caller: "t")
            Issue.record("expected ToolError.invalidParameter, got success")
        } catch let ToolError.invalidParameter(detail) {
            #expect(detail == "bad-arg")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
        #expect(await sink.post.count == 1)
        #expect((await sink.post)[0].result == nil)
        #expect((await sink.post)[0].error != nil)
        if case let observedError? = (await sink.post)[0].error {
            #expect(observedError.contains("bad-arg") == true)
        } else {
            Issue.record("post-observed error was nil despite handler throwing")
        }
    }

    @Test("registry default init (no hooks) → tools run unaffected")
    func defaultRegistryUnaffected() async throws {
        let registry = ToolRegistry()
        try await registry.register(entry())
        #expect(try await registry.call("write_file", arguments: "{}", caller: "t") == "EXECUTED")
    }

    @Test("matcher-scoped deny: only the named tool is gated")
    func matcherScopedDeny() async throws {
        let registry = ToolRegistry(hooks: [
            Hook.matching("delete_file") { _ in .deny(reason: "no-delete") }
        ])
        try await registry.register(
            ToolEntry(
                name: "read_file", toolset: "fs", schema: ToolSchema(),
                handler: { (_: String) async throws -> String in "ok" }))
        try await registry.register(entry(name: "delete_file"))
        #expect(try await registry.call("read_file", arguments: "{}", caller: "t") == "ok")
        do {
            _ = try await registry.call("delete_file", arguments: "{}", caller: "t")
            Issue.record("expected deny on delete_file")
        } catch let ToolError.denied(reason) {
            #expect(reason == "no-delete")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}

// MARK: - Counter

actor RanCounter {
    private var count = 0
    func increment() { count += 1 }
    var value: Int { count }
}
