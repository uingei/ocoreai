// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Why a gate here: an error thrown out of `POST /v1/messages` answered this file's OpenAI-shaped
/// body — `{"error":{"message","type":"app_error","code":400}}` — which is not a shape an Anthropic
/// client parses. Both reference stacks answer Anthropic's envelope on that route
/// (`sglang/python/sglang/srt/entrypoints/anthropic/protocol.py:25-36`,
/// `vllm/vllm/entrypoints/anthropic/protocol.py:25-30`), and vllm writes down why the string inside
/// matters: "Anthropic SDKs dispatch on `error.type`, which must use Anthropic's own vocabulary
/// rather than vLLM's internal/Python error class names" (`protocol.py:33-34`). So the same throw
/// must now answer two shapes, chosen by the path the request arrived on — one throw site, two
/// published vocabularies, no second home for either table.
///
/// Both wire assertions go through the real router with a real body, because the claim is about the
/// bytes a client parses: which envelope, which `error.type`, and whether a key belonging to the
/// other wire (`code`) leaked into Anthropic's object.

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing

@testable import ocoreai

@Suite("AppError envelope — each wire gets its own error vocabulary")
struct AnthropicErrorEnvelopeTests {

    private static let log = Logger(label: "test.anthropic.error")

    /// A pool with no default model. The assertions below deliberately fail at the sampling-domain
    /// check, which runs before model resolution, so nothing here needs Metal or weights.
    private static func makeApp(_ dbPath: String) async throws -> some ApplicationProtocol {
        var config = EnginePoolConfig.default
        config.defaultModelId = ""
        let store = SQLiteStore(path: dbPath)
        try await store.open()
        let fts = FTS5Search(store: store)
        let compressor = SessionCompressor(store: store, fts: fts)
        let messageBuilder = MessageBuilder(
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            sessionCompressor: compressor,
            complexityAnalyzer: ComplexityAnalyzer(),
            thinkingBudget: ThinkingBudget()
        )
        return try await buildApplication(
            enginePool: EnginePool(
                config: config, logger: log, tokenizerManager: TokenizerManager()),
            scheduler: SchedulerActor(maxQueueSize: 4, memoryTracker: nil, log: log),
            metrics: MetricsRegistry(),
            sessionCompressor: compressor,
            semanticSearch: nil,
            mcpBridge: MCPBridge(
                toolRegistry: ToolRegistry(log: log),
                transport: MCPStdioTransport(log: log)),
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            messageBuilder: messageBuilder,
            logger: log,
            authMiddleware: AuthMiddleware<OCoreAIContext>(config: .default, logger: log),
            rateLimitMiddleware: RateLimitMiddleware(
                provider: RateLimitProvider(
                    config: RateLimitProvider.Config(
                        globalRate: 1000, globalBurst: 2000, perModelRate: 500, perModelBurst: 1000,
                        perIPRate: 500, perIPBurst: 1000, enabled: true),
                    logger: log),
                logger: log),
            hfToken: nil,
            msToken: nil
        )
    }

    private static func body(_ response: TestResponse) -> [String: Any] {
        let text = response.body.getString(at: 0, length: response.body.readableBytes) ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    /// `temperature: 5` breaks both faces' bound (OpenAI [0,2], Anthropic [0,1]) at the first line
    /// of the handler, so the refusal is the subject and no model is ever needed.
    private static let outOfRange =
        #"{"model":"m","max_tokens":16,"temperature":5,"messages":[{"role":"user","content":"hi"}]}"#

    // MARK: - The table

    @Test("Anthropic's vocabulary, one name per status this server can emit")
    func anthropicErrorTypeTable() {
        // Names read off `vllm/entrypoints/anthropic/protocol.py:34-53`; the two fallbacks are that
        // function's own, so a client gets one answer from either stack.
        #expect(AppError.invalidRequest("x").anthropicErrorTypeName == "invalid_request_error")
        #expect(
            AppError.invalidParameter(param: "temperature", message: "range", value: "5")
                .anthropicErrorTypeName == "invalid_request_error")
        #expect(AppError.modelNotFound("org/x").anthropicErrorTypeName == "not_found_error")
        #expect(AppError.engineBusy.anthropicErrorTypeName == "rate_limit_error")
        #expect(AppError.modelLoading("org/x", nil).anthropicErrorTypeName == "overloaded_error")
        #expect(AppError.engineUnavailable.anthropicErrorTypeName == "overloaded_error")
        #expect(AppError.inferenceFailed("boom").anthropicErrorTypeName == "api_error")
        // A 501 (the decisions refusal) is ≥500: `api_error`, not a 4xx name.
        #expect(AppError.decisionsUnavailable("no logits").anthropicErrorTypeName == "api_error")
        // vllm has no entry for 410 and falls through to its 4xx default; so do we — reproducing
        // that beats inventing a name Anthropic never defined for an expired session.
        #expect(AppError.sessionExpired("s").anthropicErrorTypeName == "invalid_request_error")
    }

    // MARK: - The two envelopes, off a live router

    @Test("`/v1/messages` answers Anthropic's envelope, with Anthropic's type")
    func messagesRouteAnswersAnthropic() async throws {
        let db = FileManager.default.temporaryDirectory
            .appendingPathComponent("aee_\(UUID().uuidString.prefix(8)).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: db) }
        let app = try await Self.makeApp(db)
        try await app.test(.router) { client in
            var buffer = ByteBufferAllocator().buffer(capacity: Self.outOfRange.utf8.count)
            buffer.writeString(Self.outOfRange)
            try await client.execute(uri: "/v1/messages", method: .post, body: buffer) { response in
                let body = Self.body(response)
                #expect(response.status == .badRequest, "expected 400: \(body)")
                #expect(
                    body["type"] as? String == "error",
                    "not Anthropic's envelope — an Anthropic SDK has no parser for this: \(body)")
                let error = try #require(
                    body["error"] as? [String: Any], "no error object: \(body)")
                #expect(
                    error["type"] as? String == "invalid_request_error",
                    "wrong vocabulary: \(error)")
                #expect(
                    error["message"] as? String != nil,
                    "the message left with the reshape: \(error)")
                // Anthropic's error object is `{type,message}`; `code` is this server's OpenAI-face
                // key, and `param`/`error_code` are ocoreai additions carried on both faces.
                #expect(
                    error["code"] == nil,
                    "the OpenAI-face `code` leaked into Anthropic's object: \(error)")
                #expect(
                    error["param"] as? String == "temperature",
                    "naming the offending field must survive the reshape: \(error)")
            }
        }
    }

    @Test("the OpenAI face keeps its own envelope and its `code`")
    func chatRouteKeepsOpenAIEnvelope() async throws {
        let db = FileManager.default.temporaryDirectory
            .appendingPathComponent("aee_\(UUID().uuidString.prefix(8)).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: db) }
        let app = try await Self.makeApp(db)
        try await app.test(.router) { client in
            var buffer = ByteBufferAllocator().buffer(capacity: Self.outOfRange.utf8.count)
            buffer.writeString(Self.outOfRange)
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: buffer) {
                response in
                let body = Self.body(response)
                #expect(response.status == .badRequest, "expected 400: \(body)")
                // No top-level `type` on this wire: that discriminator belongs to Anthropic.
                #expect(body["type"] == nil, "Anthropic's discriminator appeared here: \(body)")
                let error = try #require(
                    body["error"] as? [String: Any], "no error object: \(body)")
                #expect(error["type"] as? String == "invalid_request_error")
                #expect(
                    error["code"] as? Int == 400, "the OpenAI-face `code` went missing: \(error)")
                #expect(error["param"] as? String == "temperature")
            }
        }
    }
}
