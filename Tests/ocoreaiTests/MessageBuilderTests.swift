// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MessageBuilderTests.swift — Tests for the 7-phase message assembly pipeline
///
/// Tests real production paths by constructing the full actor chain:
/// SQLiteStore → FTS5Search → SessionCompressor, plus ComplexityAnalyzer + ThinkingBudget.
///
/// Focus:
///  - System prompt injection (Phase 1-4)
///  - Tool definition injection (Phase 5)
///  - Empty-message guard (Phase 6)
///  - Complexity caching (lastTaskType / lastComplexityScore)

import Testing
import Foundation
import Logging
@testable import ocoreai

private func makeFixture() async throws -> MessageBuilder {
    let tmpPath = "/tmp/ocoreai_test_\(UUID().uuidString.prefix(8)).db"
    let store = SQLiteStore(path: tmpPath)
    try await store.open()

    let registry = SkillRegistry()
    try await registry.bootstrap(skillsDir: nil)

    let fts = FTS5Search(store: store)

    let spb = SystemPromptBuilder(basePrompt: "You are an AI assistant.")
    await spb.setRegistry(registry)

    let compressor = SessionCompressor(store: store, fts: fts)

    let analyzer = ComplexityAnalyzer()
    let budget = ThinkingBudget()

    return MessageBuilder(
        systemPromptBuilder: spb,
        sessionCompressor: compressor,
        complexityAnalyzer: analyzer,
        thinkingBudget: budget
    )
}

private func makeFixtureNoRegistry() async throws -> MessageBuilder {
    let tmpPath = "/tmp/ocoreai_test_\(UUID().uuidString.prefix(8)).db"
    let store = SQLiteStore(path: tmpPath)
    try await store.open()

    let fts = FTS5Search(store: store)

    let spb = SystemPromptBuilder(basePrompt: "You are an AI assistant.")
    let compressor = SessionCompressor(store: store, fts: fts)

    let analyzer = ComplexityAnalyzer()
    let budget = ThinkingBudget()

    return MessageBuilder(
        systemPromptBuilder: spb,
        sessionCompressor: compressor,
        complexityAnalyzer: analyzer,
        thinkingBudget: budget
    )
}

@Suite("MessageBuilder — Phase 1-4: system prompt injection")
struct SystemPromptInjectionTests {
    @Test("buildMessages prepends system message")
    func prependsSystem() async throws {
        let builder = try await makeFixture()
        let ctx = MessageBuilderContext(
            modelId: "test",
            rawMessages: [Message(role: "user", content: "hello")],
            userSystemPrompt: nil,
            tools: nil,
            sessionId: "s1"
        )
        let msgs = try await builder.buildMessages(context: ctx)
        #expect(msgs.first?.role == "system")
        guard case let .text(content) = msgs.first?.content else {
            Issue.record("First message should be .text")
            return
        }
        #expect(content.contains("You are an AI assistant"))
    }

    @Test("user system prompt overrides built prompt and takes priority")
    func userSystemOverride() async throws {
        let builder = try await makeFixture()
        let ctx = MessageBuilderContext(
            modelId: "test",
            rawMessages: [Message(role: "user", content: "hello")],
            userSystemPrompt: "CUSTOM OVERRIDE",
            tools: nil,
            sessionId: "s1"
        )
        let msgs = try await builder.buildMessages(context: ctx)
        guard case let .text(content) = msgs.first?.content else {
            Issue.record("First message should be .text")
            return
        }
        #expect(content.hasPrefix("CUSTOM OVERRIDE"))
    }

    @Test("raw messages preserved in order after system injection")
    func rawMessagesOrder() async throws {
        let builder = try await makeFixture()
        let ctx = MessageBuilderContext(
            modelId: "test",
            rawMessages: [
                Message(role: "user", content: "first"),
                Message(role: "assistant", content: "ok"),
                Message(role: "user", content: "second"),
            ],
            userSystemPrompt: nil,
            tools: nil,
            sessionId: "s1"
        )
        let msgs = try await builder.buildMessages(context: ctx)
        #expect(msgs.count == 4)
        #expect(msgs[1].role == "user")
        #expect(msgs[2].role == "assistant")
        #expect(msgs[3].role == "user")
    }

    @Test("returns system message from basePrompt when no registry")
    func emptySystemSkipped() async throws {
        let builder = try await makeFixtureNoRegistry()
        let ctx = MessageBuilderContext(
            modelId: "test",
            rawMessages: [Message(role: "user", content: "hello")],
            userSystemPrompt: nil,
            tools: nil,
            sessionId: "s1"
        )
        let msgs = try await builder.buildMessages(context: ctx)
        // SystemPromptBuilder has a base prompt, so system message IS prepended
        #expect(msgs.first?.role == "system")
        #expect(msgs.count == 2)
    }
}

@Suite("MessageBuilder — Phase 5: tool definition injection")
struct ToolDefinitionInjectionTests {
    @Test("tool defs appended to system message content")
    func toolDefsAppended() async throws {
        let builder = try await makeFixture()
        let tool = ToolDef(
            type: "function",
            function: FunctionDef(
                name: "calc",
                description: "Calculate",
                parameters: nil
            )
        )
        let ctx = MessageBuilderContext(
            modelId: "test",
            rawMessages: [Message(role: "user", content: "3+3")],
            userSystemPrompt: nil,
            tools: [tool],
            sessionId: "s1"
        )
        let msgs = try await builder.buildMessages(context: ctx)
        guard let system = msgs.first, system.role == "system",
              case let .text(content) = system.content else {
            Issue.record("No system message with .text content")
            return
        }
        #expect(content.contains("## Tool: calc"))
        #expect(content.contains("Calculate"))
    }

    @Test("tool defs create system message when none exists")
    func toolDefsCreateSystem() async throws {
        let builder = try await makeFixtureNoRegistry()
        let tool = ToolDef(
            type: "function",
            function: FunctionDef(
                name: "search",
                description: "Web search",
                parameters: nil
            )
        )
        let ctx = MessageBuilderContext(
            modelId: "test",
            rawMessages: [Message(role: "user", content: "query")],
            userSystemPrompt: nil,
            tools: [tool],
            sessionId: "s1"
        )
        let msgs = try await builder.buildMessages(context: ctx)
        #expect(msgs.first?.role == "system")
    }
}

@Suite("MessageBuilder — Phase 6: empty message guard")
struct EmptyMessageGuardTests {
    @Test("empty raw messages throw when system prompt is also empty")
    func emptyRawThrows() async throws {
        let tmpPath = "/tmp/ocoreai_test_empty_\(UUID().uuidString.prefix(8)).db"
        let store = SQLiteStore(path: tmpPath)
        try await store.open()
        let fts = FTS5Search(store: store)
        let spb = SystemPromptBuilder(basePrompt: "") // Empty base prompt
        let compressor = SessionCompressor(store: store, fts: fts)
        let analyzer = ComplexityAnalyzer()
        let budget = ThinkingBudget()

        let builder = MessageBuilder(
            systemPromptBuilder: spb,
            sessionCompressor: compressor,
            complexityAnalyzer: analyzer,
            thinkingBudget: budget
        )
        let ctx = MessageBuilderContext(
            modelId: "test",
            rawMessages: [],
            userSystemPrompt: nil,
            tools: nil,
            sessionId: "s1"
        )
        do {
            _ = try await builder.buildMessages(context: ctx)
            #expect(Bool(false), "buildMessages should throw for empty message list")
        } catch {
            #expect(error is AppError)
        }
    }
}

@Suite("MessageBuilder — Phase 7: reasoning scaffold injection")
struct ReasoningScaffoldTests {
    @Test("code query with large context injects scaffold into system message")
    func codeQueryScaffoldInjected() async throws {
        let builder = try await makeFixture()
        // Build a message list with enough messages to push complexity up
        // (messageCount feeds complexityAnalyzer → higher score → scaffold injection)
        let msgs: [Message] = (0..<20).map { i in
            Message(role: i % 2 == 0 ? "user" : "assistant", content: "iteration \(i)")
        }
        let ctx = MessageBuilderContext(
            modelId: "test",
            rawMessages: msgs,
            userSystemPrompt: nil,
            tools: nil,
            sessionId: "scaffold_test"
        )
        let result = try await builder.buildMessages(context: ctx)
        // Verify system message exists
        #expect(result.first?.role == "system")
        // Verify scaffold was injected (code-related keywords + large messageCount → scaffold)
        guard case let .text(sysContent) = result.first?.content else {
            Issue.record("System message should have .text content")
            return
        }
        // ComplexityAnalyzer classifies multi-message code context as higher complexity.
        // ThinkingBudget injects scaffold for non-simple bands → system message grows.
        let basePrompt = "You are an AI assistant."
        let baselineLength = basePrompt.count
        #expect(
            sysContent.count - baselineLength > 10,
            "Scaffold should expand system message by >10 chars (delta: \(sysContent.count - baselineLength), base: \(baselineLength))"
        )
    }

    @Test("simple factual query may skip scaffold due to zero-overhead path")
    func simpleQuerySkipsScaffold() async throws {
        let builder = try await makeFixture()
        let ctx = MessageBuilderContext(
            modelId: "test",
            rawMessages: [Message(role: "user", content: "Hi")],
            userSystemPrompt: nil,
            tools: nil,
            sessionId: "simple_scaffold"
        )
        let msgs = try await builder.buildMessages(context: ctx)
        #expect(msgs.first?.role == "system")
        guard case let .text(sysContent) = msgs.first?.content else {
            Issue.record("System message should have .text content")
            return
        }
        // "Hi" → factual/casual in simple band → ThinkingBudget returns "" (zero overhead)
        // System message stays at baseprompt size only
        #expect(
            sysContent.contains("You are an AI assistant"),
            "Base prompt should be present in system message"
        )
        #expect(
            !sysContent.contains("## Reasoning Protocol") &&
            !sysContent.contains("## Code Protocol"),
            "Simple casual query should NOT inject scaffold"
        )
    }
}

@Suite("MessageBuilder — complexity cache query")
struct ComplexityCacheTests {
    @Test("lastTaskType returns .general before build")
    func lastTaskTypeBefore() async throws {
        let builder = try await makeFixture()
        #expect(await builder.lastTaskType() == .general)
    }

    @Test("lastComplexityScore is nil before build")
    func lastScoreNil() async throws {
        let builder = try await makeFixture()
        #expect(await builder.lastComplexityScore() == nil)
    }

    @Test("code-related query results in .code task type")
    func codeTaskTypeDetected() async throws {
        let builder = try await makeFixture()
        let ctx = MessageBuilderContext(
            modelId: "test",
            rawMessages: [Message(role: "user", content: "Write a Python function that reverses a linked list")],
            userSystemPrompt: nil,
            tools: nil,
            sessionId: "s1"
        )
        _ = try await builder.buildMessages(context: ctx)
        let score = await builder.lastComplexityScore()
        #expect(score != nil, "Complexity score should be populated after build")
        // "function", "reverses", "linked list" → .code via keyword match
        let taskType = await builder.lastTaskType()
        #expect(taskType == .code, "Python linked-list prompt should be classified as .code (got \(taskType.rawValue))")
        // Verify score composite is populated — code task should yield a positive score
        #expect(score?.composite ?? 0 > 0, "Code task should have positive composite score")
    }
}
