// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! Regression gate: what a tool-call turn is allowed to claim about itself.
//!
//! Measured 10-19 (live, macOS 26, `mlx-community/gemma-4-e2b-it-4bit`, temp 0, one tool
//! declared and a prompt asking for the weather in two cities):
//!   • `parallel_tool_calls:false` → **2** `tool_calls` (`Paris`, `London`); on
//!     `/v1/messages`, `tool_choice:{"type":"auto","disable_parallel_tool_use":true}` →
//!     **2** `tool_use` blocks. The flag was decoded and read by nobody.
//!   • `max_tokens:18` → `completion_tokens:18` (the budget cut it) and one call delivered,
//!     with `finish_reason:"tool_calls"`; the Anthropic face said `tool_use` at
//!     `max_tokens:18` while its own no-tools control correctly said `max_tokens`.
//!   • SSE: the tool-call delta carried `finish_reason:"tool_calls"` and the terminal chunk
//!     said `stop` — so a streaming client was told there were no calls, and a client that
//!     ends the stream on the first non-null `finish_reason` stopped before the answer.
//!   • `tool_choice:{"type":"function","function":{"name":"get_weather"}}` — OpenAI's own
//!     shape — answered `400 {"error":{"message":"Coding key \`name\` not found."}}`,
//!     while this server's invented flat alias worked; `"banana"` and a bare tool name
//!     answered 200.
//!
//! The rules live in `Sources/ocoreai/Models/ToolCallWire.swift`, following vllm
//! (`entrypoints/serve/utils/tool_calls_utils.py:24-43` and `:47-65`) and sglang
//! (`serving_chat.py:2149-2152`). Surviving companion: live probe
//! `scripts/probes/14-parallel-and-terminal-word.sh`.

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing
import ocoreaiTestUtilities

@testable import ocoreai

private func makeCall(_ id: String, _ city: String) -> ToolCall {
    ToolCall(
        id: id,
        function: ToolCallFunction(name: "get_weather", arguments: "{\"city\":\"\(city)\"}"))
}

// MARK: - The rules

@Suite("ToolCallWire — the terminal word, and one call when the client said one")
struct ToolCallWireRulesTests {

    /// (engine reason, did the turn call, the word the client must get).
    ///
    /// `tool_calls` is reserved for a turn that called **and stopped on its own**:
    /// vllm `resolve_finish_reason` keeps `length` visible ("a `length` cut stays visible
    /// so clients can tell a truncated call from a complete one"), and sglang applies the
    /// upgrade only when `finish_reason_type == "stop"`. `cancelled`/`error` never become
    /// a success word.
    @Test(arguments: [
        ("stop", true, "tool_calls"),
        ("stop", false, "stop"),
        ("length", true, "length"),
        ("length", false, "length"),
        ("cancelled", true, "cancelled"),
        ("error", true, "error"),
        ("error", false, "error"),
    ])
    func terminalWord(reason: String, callsMade: Bool, expected: String) {
        #expect(
            ToolCallWire.resolveFinishReason(engineReason: reason, toolCallsMade: callsMade)
                == expected,
            "engine=\(reason) calls=\(callsMade) → \(expected)")
    }

    @Test("only the terminal chunk may carry a non-null finish_reason")
    func nonTerminalChunksStayNull() {
        for reason in ["stop", "length", "cancelled", "error"] {
            for made in [true, false] {
                #expect(
                    ToolCallWire.terminalFinishReason(
                        engineReason: reason, toolCallsMade: made, terminal: false) == nil,
                    "a mid-stream delta must not claim the turn is over (engine=\(reason))")
            }
        }
        #expect(
            ToolCallWire.terminalFinishReason(
                engineReason: "stop", toolCallsMade: true, terminal: true) == "tool_calls")
    }

    @Test(
        "only an explicit false restricts parallel calls",
        arguments: [
            (Optional<Bool>.none, false), (Optional<Bool>.some(true), false),
            (Optional<Bool>.some(false), true),
        ])
    func threeStateParallel(parallelToolCalls: Bool?, restricted: Bool) {
        #expect(
            ToolCallWire.limitsToSingleCall(parallelToolCalls: parallelToolCalls) == restricted)
    }

    @Test("the client keeps the FIRST call, in the model's own order")
    func limitKeepsFirstCall() {
        let calls = [makeCall("call_a", "Paris"), makeCall("call_b", "London")]
        #expect(ToolCallWire.limitedToolCalls(calls, parallelToolCalls: nil)?.count == 2)
        #expect(ToolCallWire.limitedToolCalls(calls, parallelToolCalls: true)?.count == 2)
        let limited = ToolCallWire.limitedToolCalls(calls, parallelToolCalls: false)
        #expect(limited?.count == 1, "parallel_tool_calls:false must deliver exactly one call")
        #expect(limited?.first?.id == "call_a", "the first call the model emitted is the one kept")
        #expect(
            limited?.first?.function.arguments.contains("Paris") ?? false,
            "the kept call must be the first, not a re-sorted pick")
    }

    @Test("no calls stays no calls, in both directions")
    func emptyStaysEmpty() {
        #expect(ToolCallWire.limitedToolCalls(nil, parallelToolCalls: false) == nil)
        #expect(ToolCallWire.limitedToolCalls([], parallelToolCalls: false) == nil)
        #expect(ToolCallWire.limitedToolCalls(nil, parallelToolCalls: nil) == nil)
    }
}

// MARK: - The tool_choice vocabulary

@Suite("tool_choice — the spec shape decodes, the rest is refused by name")
struct ToolChoiceVocabularyTests {

    private static let toolsJSON =
        #","tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{},"required":[]}}}]"#

    private static func decode(_ toolChoiceJSON: String) throws -> String? {
        let body =
            #"{"model":"m","messages":[{"role":"user","content":"hi"}]"# + toolsJSON
            + ",\"tool_choice\":" + toolChoiceJSON + "}"
        return try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(body.utf8))
            .toolChoice
    }

    /// The vocabulary both references publish (vllm `chat_completion/protocol.py:250-255`,
    /// sglang `protocol.py:901`), plus the internal word for a pin.
    @Test(arguments: [
        ("\"auto\"", "auto"), ("\"none\"", "none"), ("\"required\"", "required"),
        ("\"function:get_weather\"", "function:get_weather"),
    ])
    func keywordsPassThrough(_ sent: String, expected: String) throws {
        #expect(try Self.decode(sent) == expected)
    }

    /// OpenAI's canonical named-tool form — the one that used to die at the decoder.
    @Test("the spec's nested named-tool shape decodes to the pin word")
    func canonicalNestedShape() throws {
        #expect(
            try Self.decode(#"{"type":"function","function":{"name":"get_weather"}}"#)
                == "function:get_weather")
        // `type` defaults to "function" where it is omitted, as both references declare.
        #expect(try Self.decode(#"{"function":{"name":"get_weather"}}"#) == "function:get_weather")
    }

    /// The flat alias this server accepted first stays working (it is what probe 11 and
    /// `ToolsWireDecodeTests` were written against), and stays distinguishable from the
    /// `none` mode by the `function:` prefix.
    @Test("the flat alias still decodes, including a tool literally named none")
    func flatAliasStillWorks() throws {
        #expect(
            try Self.decode(#"{"type":"function","name":"get_weather"}"#)
                == "function:get_weather")
        #expect(try Self.decode(#"{"type":"function","name":"none"}"#) == "function:none")
    }

    /// Every refusal names `tool_choice` and says what the client may send instead —
    /// Hummingbird's `Coding key \`name\` not found.` named neither.
    @Test(arguments: [
        "\"banana\"", "\"get_weather\"", "\"REQUIRED\"",
        #"{"type":"bogus","name":"x"}"#,
        #"{"type":"none"}"#,
        #"{"type":"function"}"#,
        #"{"function":{}}"#,
        #"{"type":"function","name":""}"#,
        #"["auto"]"#,
    ])
    func refusalsNameTheField(_ sent: String) {
        var param: String? = nil
        var thrown = false
        do {
            _ = try Self.decode(sent)
        } catch let error as AppError {
            thrown = true
            if case .invalidParameter(let p, let message, _) = error {
                param = p
                #expect(
                    message.contains("tool_choice"),
                    "the message must name the field: \(message)")
            }
        } catch {
            param = nil
        }
        #expect(thrown, "\(sent) must be refused, not accepted silently")
        #expect(
            param == "tool_choice",
            "\(sent) refused by the wrong field: \(String(describing: param))")
    }

    @Test("the echoed value is what the client sent")
    func valueIsEchoed() {
        do {
            _ = try Self.decode("\"banana\"")
            Issue.record("expected a refusal")
        } catch let error as AppError {
            guard case .invalidParameter(_, _, let value) = error else {
                Issue.record("expected invalidParameter")
                return
            }
            #expect(value == "banana")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    /// `tool_choice` demands a choice from a set the client never declared. Both
    /// references refuse it; `"none"` is exempt because it demands nothing.
    @Test(arguments: [
        (Optional<String>.none, Optional<Int>.none, false),
        (Optional<String>.some("none"), Optional<Int>.none, false),
        (Optional<String>.some("auto"), Optional<Int>.none, true),
        (Optional<String>.some("auto"), Optional<Int>.some(0), true),
        (Optional<String>.some("required"), Optional<Int>.some(0), true),
        (Optional<String>.some("function:get_weather"), Optional<Int>.none, true),
        (Optional<String>.some("auto"), Optional<Int>.some(1), false),
    ])
    func toolChoiceNeedsTools(
        choice: String?, toolCount: Int?, shouldRefuse: Bool
    ) {
        let error = ToolCallWire.toolChoiceWithoutToolsError(
            toolChoice: choice, toolCount: toolCount)
        if shouldRefuse {
            #expect(
                error != nil,
                "tool_choice=\(choice ?? "nil") with \(toolCount.map(String.init) ?? "no") tools must be refused"
            )
        } else {
            #expect(error == nil, "tool_choice=\(choice ?? "nil") must not be refused")
        }
    }
}

// MARK: - The Anthropic face carries the same flag

@Suite("disable_parallel_tool_use reaches the internal request")
struct AnthropicParallelFlagTests {

    private static let toolsJSON =
        #","tools":[{"name":"get_weather","input_schema":{"type":"object","properties":{},"required":[]}}]"#

    private static func mappedParallel(_ toolChoiceJSON: String?) throws -> Bool? {
        var body =
            #"{"model":"m","max_tokens":32,"messages":[{"role":"user","content":"hi"}]"#
            + toolsJSON
        if let toolChoiceJSON { body += ",\"tool_choice\":" + toolChoiceJSON }
        body += "}"
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: Data(body.utf8))
        return try toChatCompletionRequest(req).parallelToolCalls
    }

    @Test(arguments: [
        (Optional<String>.none, true),
        (Optional<String>.some(#"{"type":"auto"}"#), true),
        (Optional<String>.some(#"{"type":"any"}"#), true),
        (Optional<String>.some(#"{"type":"auto","disable_parallel_tool_use":false}"#), true),
        (Optional<String>.some(#"{"type":"auto","disable_parallel_tool_use":true}"#), false),
        (
            Optional<String>.some(
                #"{"type":"tool","name":"get_weather","disable_parallel_tool_use":true}"#),
            false,
        ),
    ])
    func flagMapsToTheOpenAIKnob(toolChoiceJSON: String?, expected: Bool) throws {
        let mapped = try Self.mappedParallel(toolChoiceJSON)
        #expect(
            mapped == expected,
            "tool_choice \(toolChoiceJSON ?? "<absent>") must map parallel_tool_calls=\(expected), got \(String(describing: mapped))"
        )
    }
}

// MARK: - Seam: both faces route through the one home

@Suite("Both faces route the tool-call claims through ToolCallWire")
struct ToolCallWireSeamTests {

    /// Finds the repo root by searching (never by fixed `deletingLastPathComponent()` hops —
    /// three "passing" assertions here were really ENOENT).
    private func repoFile(_ relative: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent(relative)
            if let data = try? Data(contentsOf: candidate) {
                return String(decoding: data, as: UTF8.self)
            }
            dir.deleteLastPathComponent()
        }
        Issue.record("could not find \(relative) from \(#filePath)")
        return ""
    }

    /// Floors the scan's own premises: a file that stopped reading as this repo's handler,
    /// or a rule call that vanished from both faces, fails here rather than passing
    /// vacuously (AGENTS.md: a scan must assert its own hit count).
    @Test(arguments: [
        "Sources/ocoreai/Handlers/ChatHandler.swift",
        "Sources/ocoreai/Handlers/AnthropicMessagesHandler.swift",
    ])
    func bothFacesUseTheOneHome(_ path: String) throws {
        let src = try repoFile(path)
        #expect(src.count > 20_000, "\(path) read looks truncated (\(src.count) chars)")
        #expect(
            src.contains("ToolCallWire.resolveFinishReason("),
            "\(path) is back to inventing its own terminal word")
        #expect(
            src.contains("ToolCallWire.limitedToolCalls(")
                || src.contains("ToolCallWire.limitsToSingleCall("),
            "\(path) no longer applies the parallel limit at its emit sites")
        #expect(
            !src.contains("? \"tool_calls\" :") && !src.contains("? \"tool_use\" :"),
            "\(path) is back to overriding the finish reason whenever a call exists")
    }

    @Test("the SSE path no longer stamps a terminal word on a mid-stream delta")
    func streamDeltasStayNull() throws {
        let src = try repoFile("Sources/ocoreai/Handlers/ChatHandler.swift")
        #expect(src.count > 20_000, "ChatHandler.swift read looks truncated")
        #expect(
            !src.contains("finishReason: \"tool_calls\","),
            "a tool_calls delta must carry finish_reason:null — the terminal chunk owns the word"
        )
        #expect(
            src.contains("lastFinishReason = stopReasonToString(reason) ?? \"stop\""),
            "the per-pass reason must still be recorded; the settle resolves it")
    }
}

// MARK: - HTTP seam: the refusal is a named 400, not a leaked DecodingError

@Suite("tool_choice misuse gets a named 400 at the HTTP seam — no model needed")
struct ToolChoiceHTTPTests {

    private static func uuidPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "toolwire_\(UUID().uuidString.prefix(8)).sqlite"
        ).path
    }

    private static func cleanup(_ paths: [String]) {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
    }

    private static func makeTestApp(_ dbPaths: [String]) async throws -> some ApplicationProtocol {
        var config = EnginePoolConfig.default
        config.defaultModelId = ""
        let enginePool = EnginePool(
            config: config,
            logger: Logger(label: "test.toolchoice-http"),
            tokenizerManager: TokenizerManager()
        )
        let store = SQLiteStore(path: dbPaths[0])
        try await store.open()
        let compressor = SessionCompressor(store: store, fts: FTS5Search(store: store))

        let mbStore = SQLiteStore(path: dbPaths[1])
        try await mbStore.open()
        let mb = MessageBuilder(
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            sessionCompressor: SessionCompressor(store: mbStore, fts: FTS5Search(store: mbStore)),
            complexityAnalyzer: ComplexityAnalyzer(),
            thinkingBudget: ThinkingBudget()
        )

        return try await buildApplication(
            enginePool: enginePool,
            scheduler: SchedulerActor(
                maxQueueSize: 4, memoryTracker: nil, log: Logger(label: "test.toolchoice-http")),
            metrics: MetricsRegistry(),
            sessionCompressor: compressor,
            semanticSearch: nil,
            mcpBridge: MCPBridge(
                toolRegistry: ToolRegistry(log: Logger(label: "test.toolchoice-http")),
                transport: MCPStdioTransport(log: Logger(label: "test.toolchoice-http"))
            ),
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            messageBuilder: mb,
            logger: Logger(label: "test.toolchoice-http"),
            authMiddleware: AuthMiddleware<OCoreAIContext>(
                config: .default, logger: Logger(label: "test.toolchoice-http")),
            rateLimitMiddleware: RateLimitMiddleware<OCoreAIContext>(
                provider: RateLimitProvider(
                    config: RateLimitProvider.Config(
                        globalRate: 1000, globalBurst: 2000, perModelRate: 500, perModelBurst: 1000,
                        perIPRate: 500, perIPBurst: 1000, enabled: true),
                    logger: Logger(label: "test.toolchoice-http")),
                logger: Logger(label: "test.toolchoice-http")),
            hfToken: nil,
            msToken: nil
        )
    }

    private static func buffer(for json: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: json.utf8.count)
        buffer.writeString(json)
        return buffer
    }

    private struct Case {
        let uri: String
        let body: String
        let value: String
    }

    /// A refusal must fire before anything needs a model: with nothing loaded, an
    /// un-guarded body answers 503 and the assertion tests nothing.
    private static func expectNamed400(_ c: Case) async throws {
        let dbs = [uuidPath(), uuidPath()]
        defer { cleanup(dbs) }
        let app = try await makeTestApp(dbs)
        try await app.test(.router) { client in
            let headers: HTTPFields = [.contentType: "application/json"]
            try await client.execute(
                uri: c.uri, method: .post, headers: headers, body: buffer(for: c.body)
            ) { response in
                let text = response.body.getString(at: 0, length: response.body.readableBytes) ?? ""
                let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                let error = (object as? [String: Any])?["error"] as? [String: Any]
                let message = error?["message"] as? String ?? text
                #expect(
                    response.status == .badRequest,
                    "\(c.uri) answered \(response.status.code) for \(c.body)")
                #expect(
                    error?["param"] as? String == "tool_choice",
                    "error.param must name tool_choice, got \(String(describing: error?["param"])) in \(text)"
                )
                #expect(
                    error?["type"] as? String == "invalid_request_error",
                    "a 400 speaks the clients' own error type, got \(String(describing: error?["type"]))"
                )
                #expect(
                    !message.contains("Coding key"),
                    "Hummingbird's decoder wording leaked to the wire: \(message)")
                #expect(message.contains(c.value), "message must echo what was sent: \(message)")
            }
        }
    }

    @Test("POST /v1/chat/completions tool_choice:\"banana\" is refused by name")
    func chatUnknownKeyword() async throws {
        try await Self.expectNamed400(
            Case(
                uri: "/v1/chat/completions",
                body:
                    #"{"model":"m","messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","properties":{},"required":[]}}}],"tool_choice":"banana"}"#,
                value: "banana"))
    }

    /// The named-tool object proves the shape decoded (a decode failure would name a coding
    /// key, not `tool_choice`) while the missing `tools[]` earns the named 400.
    @Test("POST /v1/chat/completions accepts OpenAI's nested named-tool shape")
    func chatCanonicalNamedToolDecodes() async throws {
        try await Self.expectNamed400(
            Case(
                uri: "/v1/chat/completions",
                body:
                    #"{"model":"m","messages":[{"role":"user","content":"hi"}],"tool_choice":{"type":"function","function":{"name":"get_weather"}}}"#,
                value: "get_weather"))
    }

    @Test("POST /v1/chat/completions still accepts the flat alias")
    func chatFlatAliasDecodes() async throws {
        try await Self.expectNamed400(
            Case(
                uri: "/v1/chat/completions",
                body:
                    #"{"model":"m","messages":[{"role":"user","content":"hi"}],"tool_choice":{"type":"function","name":"get_weather"}}"#,
                value: "get_weather"))
    }

    @Test("POST /v1/chat/completions tool_choice as an array is refused, not leaked")
    func chatArrayToolChoice() async throws {
        try await Self.expectNamed400(
            Case(
                uri: "/v1/chat/completions",
                body:
                    #"{"model":"m","messages":[{"role":"user","content":"hi"}],"tool_choice":["auto"]}"#,
                value: "tool_choice"))
    }

    @Test("POST /v1/messages tool_choice without tools is refused too")
    func messagesToolChoiceNeedsTools() async throws {
        try await Self.expectNamed400(
            Case(
                uri: "/v1/messages",
                body:
                    #"{"model":"m","max_tokens":32,"messages":[{"role":"user","content":"hi"}],"tool_choice":{"type":"any"}}"#,
                value: "any"))
    }
}
