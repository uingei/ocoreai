// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Completions Endpoint Tests — /v1/completions wire contract + HTTP validation
///
/// Two suites:
/// 1. ``CompletionsWireTests`` — precise-value DTO decode/encode assertions
///    (prompt union decode, default fields, object/id/choices/usage wire shape,
///    stream-option usage presence). No inference required.
/// 2. ``CompletionsE2ETests`` — HTTP pipeline (router guard → handler validation)
///    through a real Hummingbird test app, mirroring ``HTTPE2ESmokeTests`` scope
///    (no inference / no model load).

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing
import ocoreaiTestUtilities

@testable import ocoreai

// MARK: - Wire Contract (DTO decode/encode, precise values)

@Suite("Completions Wire — DTO Contract")
struct CompletionsWireTests {
    private func decode(_ json: String) throws -> CompletionRequest {
        try JSONDecoder().decode(CompletionRequest.self, from: Data(json.utf8))
    }

    private static func encodeDict<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: Prompt union decode

    @Test("Bare-string prompt decodes to single-element array")
    func bareStringPrompt() throws {
        let req = try decode(#"{"prompt": "Hello world", "model": "m"}"#)
        #expect(req.prompt == ["Hello world"])
        #expect(req.prompt.count == 1)
    }

    @Test("Array-of-strings prompt decodes preserving order")
    func arrayPrompt() throws {
        let req = try decode(#"{"prompt": ["a", "b", "c"]}"#)
        #expect(req.prompt == ["a", "b", "c"])
    }

    @Test("Missing prompt field decodes to empty (enforced as 400 at router/handler)")
    func missingPromptDecodesEmpty() throws {
        // House design: decode is lenient (token-id payloads must not hard-fail,
        // per `init(from:)` comment); the 400 is enforced by the router guard
        // + handler guard (both observed in-tree at 169-170 / 57-59).
        let req = try decode(#"{"model": "m"}"#)
        #expect(req.prompt.isEmpty)
    }

    @Test("Empty-string array prompt decodes (handler rejects via 400)")
    func emptyArrayPromptDecodes() throws {
        let req = try decode(#"{"prompt": []}"#)
        #expect(req.prompt.isEmpty)
    }

    // MARK: Wire defaults (vllm parity)

    @Test("Defaults: n=1, stream=false, temperature=0.7, penalties=0")
    func wireDefaults() throws {
        let req = try decode(#"{"prompt": "hi"}"#)
        #expect(req.n == 1)
        #expect(req.stream == false)
        #expect(req.temperature == 0.7)
        #expect(req.topP == nil)
        #expect(req.maxTokens == nil)
        #expect(req.frequencyPenalty == 0)
        #expect(req.presencePenalty == 0)
        #expect(req.echo == false)
        #expect(req.stop == nil)
        #expect(req.streamOptions == nil)
    }

    @Test("Explicit values override defaults")
    func explicitOverrides() throws {
        let req = try decode(
            #"{"prompt": "hi", "n": 3, "seed": 42, "temperature": 0.1, "top_p": 0.9, "max_tokens": 128, "stop": ["\n"], "stream": true}"#
        )
        #expect(req.n == 3)
        #expect(req.seed == 42)
        #expect(req.temperature == 0.1)
        #expect(req.topP == 0.9)
        #expect(req.maxTokens == 128)
        #expect(
            req.stop?.first == "\n",
            "stop first = \(String(format: "%d chars", (req.stop?.first ?? "").utf8.count)) utf8")
        #expect(req.stream == true)
    }

    // MARK: Non-stream response encode

    @Test("TextCompletionResponse wire shape (object/id/choices/usage)")
    func responseEncode() throws {
        let resp = TextCompletionResponse(
            id: "cmpl-test123",
            created: 1_700_000_000,
            model: "model-x",
            choices: [
                TextCompletionChoice(text: "Hi there", finishReason: "stop", index: 0)
            ],
            usage: Usage(input: 9, output: 3),
        )
        let root = try Self.encodeDict(resp)
        #expect(root["object"] as? String == "text_completion")
        #expect(root["id"] as? String == "cmpl-test123")
        #expect(root["created"] as? Int == 1_700_000_000)
        #expect(root["model"] as? String == "model-x")

        let choices = root["choices"] as? [[String: Any]]
        #expect(choices?.count == 1)
        #expect(choices?[0]["text"] as? String == "Hi there")
        #expect(choices?[0]["finish_reason"] as? String == "stop")
        #expect(choices?[0]["index"] as? Int == 0)

        let usage = root["usage"] as? [String: Any]
        #expect(usage?["prompt_tokens"] as? Int == 9)
        #expect(usage?["completion_tokens"] as? Int == 3)
        #expect(usage?["total_tokens"] as? Int == 12)
    }

    @Test("Multiple choices encode in order with distinct indices")
    func multipleChoicesEncode() throws {
        let resp = TextCompletionResponse(
            id: "cmpl-multi",
            created: 1,
            model: "m",
            choices: [
                TextCompletionChoice(text: "one", finishReason: "stop", index: 0),
                TextCompletionChoice(text: "two", finishReason: "length", index: 1),
            ],
            usage: Usage(input: 1, output: 8),
        )
        let root = try Self.encodeDict(resp)
        let choices = root["choices"] as? [[String: Any]]
        #expect(choices?.count == 2)
        #expect(choices?[0]["text"] as? String == "one")
        #expect(choices?[1]["text"] as? String == "two")
        #expect(choices?[0]["index"] as? Int == 0)
        #expect(choices?[1]["index"] as? Int == 1)
        #expect(choices?[1]["finish_reason"] as? String == "length")
    }

    // MARK: Stream chunk encode

    @Test("CompletionChunk: object + delta text, usage omitted when nil")
    func chunkNoUsage() throws {
        let chunk = CompletionChunk(
            id: "cmpl-s1",
            created: 1_700_000_001,
            model: "m",
            choices: [CompletionChunkChoice(text: "delta", finishReason: nil, index: 0)],
        )
        let root = try Self.encodeDict(chunk)
        #expect(root["object"] as? String == "text_completion")
        #expect(root["id"] as? String == "cmpl-s1")
        #expect(!root.keys.contains("usage"), "usage key must be absent when nil")
        let choices = root["choices"] as? [[String: Any]]
        let first = choices?.first ?? [:]
        #expect(first["text"] as? String == "delta")
        #expect(
            !first.keys.contains("finish_reason"),
            "finish_reason must be absent (null) on delta chunks")
    }

    @Test("CompletionChunk stop-chunk: empty text + finish_reason")
    func chunkStop() throws {
        let chunk = CompletionChunk(
            id: "cmpl-s2",
            created: 1_700_000_002,
            model: "m",
            choices: [CompletionChunkChoice(text: "", finishReason: "stop", index: 0)],
        )
        let root = try Self.encodeDict(chunk)
        let choices = root["choices"] as? [[String: Any]]
        #expect(choices?[0]["text"] as? String == "")
        #expect(choices?[0]["finish_reason"] as? String == "stop")
    }

    @Test("CompletionChunk with include_usage carries usage payload")
    func chunkWithUsage() throws {
        let chunk = CompletionChunk(
            id: "cmpl-s3",
            created: 1_700_000_003,
            model: "m",
            choices: [CompletionChunkChoice(text: "", finishReason: "stop", index: 0)],
            usage: Usage(input: 5, output: 4),
        )
        let root = try Self.encodeDict(chunk)
        let usage = root["usage"] as? [String: Any]
        #expect(usage?["prompt_tokens"] as? Int == 5)
        #expect(usage?["completion_tokens"] as? Int == 4)
        #expect(usage?["total_tokens"] as? Int == 9)
    }
}

// MARK: - E2E: Router guard + handler validation (no inference)

@Suite("Completions E2E — HTTP Validation Pipeline")
struct CompletionsE2ETests {
    // MARK: - Helpers (mirror HTTPE2ESmokeTests test-app construction)

    private static func uuidPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "comple_\(UUID().uuidString.prefix(8)).sqlite"
        ).path
    }

    private static func cleanupDBs(_ p1: String, _ p2: String) {
        try? FileManager.default.removeItem(atPath: p1)
        try? FileManager.default.removeItem(atPath: p2)
    }

    private static func makeRateLimitMiddleware() -> RateLimitMiddleware<OCoreAIContext> {
        RateLimitMiddleware(
            provider: RateLimitProvider(
                config: RateLimitProvider.Config(
                    globalRate: 1000,
                    globalBurst: 2000,
                    perModelRate: 500,
                    perModelBurst: 1000,
                    perIPRate: 500,
                    perIPBurst: 1000,
                    enabled: true
                ),
                logger: Logger(label: "test.comple")
            ),
            logger: Logger(label: "test.comple")
        )
    }

    private static func makeTestApp(_ dbPath1: String, _ dbPath2: String) async throws
        -> some ApplicationProtocol
    {
        let enginePool = EnginePool(
            config: .default,
            logger: Logger(label: "test.comple"),
            tokenizerManager: TokenizerManager()
        )
        let store = SQLiteStore(path: dbPath1)
        try await store.open()
        let fts = FTS5Search(store: store)
        let compressor = SessionCompressor(store: store, fts: fts)

        let mbStore = SQLiteStore(path: dbPath2)
        try await mbStore.open()
        let mbFts = FTS5Search(store: mbStore)
        let mb = MessageBuilder(
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            sessionCompressor: SessionCompressor(store: mbStore, fts: mbFts),
            complexityAnalyzer: ComplexityAnalyzer(),
            thinkingBudget: ThinkingBudget()
        )

        let scheduler = SchedulerActor(
            maxQueueSize: 4,
            memoryTracker: nil,
            log: Logger(label: "test.comple")
        )

        let mcpBridge = MCPBridge(
            toolRegistry: ToolRegistry(log: Logger(label: "test.comple")),
            transport: MCPStdioTransport(log: Logger(label: "test.comple"))
        )

        return try await buildApplication(
            enginePool: enginePool,
            scheduler: scheduler,
            metrics: MetricsRegistry(),
            sessionCompressor: compressor,
            semanticSearch: nil,
            mcpBridge: mcpBridge,
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            messageBuilder: mb,
            logger: Logger(label: "test.comple"),
            authMiddleware: AuthMiddleware<OCoreAIContext>(
                config: .default,
                logger: Logger(label: "test.comple")
            ),
            rateLimitMiddleware: makeRateLimitMiddleware(),
            hfToken: nil,
            msToken: nil
        )
    }

    private static func jsonBody(_ dict: [String: Any]) throws -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 1024)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        buffer.writeBytes(data)
        return buffer
    }

    private static func stringBody(_ s: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: s.utf8.count)
        buffer.writeString(s)
        return buffer
    }

    private static func responseBody(from response: TestResponse) -> String {
        response.body.getString(at: 0, length: response.body.readableBytes) ?? ""
    }

    // MARK: - Tests

    @Test("POST /v1/completions empty prompt → 400 with message")
    func emptyPrompt() async throws {
        let db1 = Self.uuidPath()
        let db2 = Self.uuidPath()
        defer { Self.cleanupDBs(db1, db2) }
        try await Self.makeTestApp(db1, db2).test(.router) { client in
            let buf: ByteBuffer = try Self.jsonBody([
                "model": "any-model", "prompt": "",
            ])
            var headers: HTTPFields = [:]
            headers[.contentType] = "application/json"
            try await client.execute(
                uri: "/v1/completions", method: .post, headers: headers, body: buf
            ) { response in
                #expect(response.status == .badRequest)
                let body = Self.responseBody(from: response)
                #expect(body.contains("non-empty"), "body: \(body)")
            }
        }
    }

    @Test("POST /v1/completions whitespace-only prompt array → 400")
    func whitespaceOnlyPrompts() async throws {
        let db1 = Self.uuidPath()
        let db2 = Self.uuidPath()
        defer { Self.cleanupDBs(db1, db2) }
        try await Self.makeTestApp(db1, db2).test(.router) { client in
            let buf: ByteBuffer = try Self.jsonBody([
                "model": "any-model", "prompt": ["   ", "\t\n"],
            ])
            var headers: HTTPFields = [:]
            headers[.contentType] = "application/json"
            try await client.execute(
                uri: "/v1/completions", method: .post, headers: headers, body: buf
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test("POST /v1/completions prompt but no model + no default → 400")
    func noModelNoDefault() async throws {
        let db1 = Self.uuidPath()
        let db2 = Self.uuidPath()
        defer { Self.cleanupDBs(db1, db2) }
        try await Self.makeTestApp(db1, db2).test(.router) { client in
            let buf: ByteBuffer = try Self.jsonBody(["prompt": "say hi"])
            var headers: HTTPFields = [:]
            headers[.contentType] = "application/json"
            try await client.execute(
                uri: "/v1/completions", method: .post, headers: headers, body: buf
            ) { response in
                #expect(response.status == .badRequest)
                let body = Self.responseBody(from: response)
                #expect(body.contains("default model"), "body: \(body)")
            }
        }
    }

    @Test("POST /v1/completions stream=true decodes through router validation")
    func streamFlagValidation() async throws {
        let db1 = Self.uuidPath()
        let db2 = Self.uuidPath()
        defer { Self.cleanupDBs(db1, db2) }
        try await Self.makeTestApp(db1, db2).test(.router) { client in
            let buf: ByteBuffer = try Self.jsonBody([
                "prompt": "hi", "stream": true,
            ])
            var headers: HTTPFields = [:]
            headers[.contentType] = "application/json"
            try await client.execute(
                uri: "/v1/completions", method: .post, headers: headers, body: buf
            ) { response in
                // No model + no default → 400 regardless of stream flag.
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test("POST /v1/completions invalid JSON → 400")
    func invalidJSON() async throws {
        let db1 = Self.uuidPath()
        let db2 = Self.uuidPath()
        defer { Self.cleanupDBs(db1, db2) }
        try await Self.makeTestApp(db1, db2).test(.router) { client in
            let buf = Self.stringBody("not json at all")
            var headers: HTTPFields = [:]
            headers[.contentType] = "application/json"
            try await client.execute(
                uri: "/v1/completions", method: .post, headers: headers, body: buf
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }
}
