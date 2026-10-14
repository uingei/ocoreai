// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// CountTokensEndpointTests — the counting surface over real HTTP, no model loaded.
///
/// `CountTokensWireShapeTests` pins the DTO; this pins the ROUTE and the ERROR
/// contract, which is where the 10-13 live failures actually were:
///   * `POST /v1/messages/count_tokens` answered 404 (the endpoint did not exist),
///     while the 404 envelope sent the client to `/v1/capabilities` for an endpoint
///     index that payload did not have;
///   * `POST /v1/count-tokens` answered `400 Coding key `prompt` not found.` for
///     spec-legal `messages`/`input` bodies.
///
/// Deliberately model-free: an unknown model id must fail with `model_not_found`, not
/// with a route/validation error. That keeps these suites runnable without a GPU (a
/// loaded model means Metal, and in a sandboxed session an MLX device failure aborts
/// the whole test process instead of reporting). The happy path — a 200 with a
/// token-exact count — is the live `serve` + `curl` probe recorded in AGENTS.md.
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing
import ocoreaiTestUtilities

@testable import ocoreai

@Suite("Count-tokens endpoints — HTTP contract (no model)")
struct CountTokensEndpointTests {

    private static let unknownModel = "ocoreai-endpoint-test-no-such-model"

    private static func uuidPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "counttok_\(UUID().uuidString.prefix(8)).sqlite"
        ).path
    }

    private static func makeTestApp(_ dbPath1: String, _ dbPath2: String) async throws
        -> some ApplicationProtocol
    {
        let log = Logger(label: "test.counttokens")
        // No default model: every request must resolve to `model_not_found`, which is
        // the point — see the suite header.
        var config = EnginePoolConfig.default
        config.defaultModelId = ""
        let enginePool = EnginePool(
            config: config, logger: log, tokenizerManager: TokenizerManager())

        let store = SQLiteStore(path: dbPath1)
        try await store.open()
        let fts = FTS5Search(store: store)
        let compressor = SessionCompressor(store: store, fts: fts)

        let mbStore = SQLiteStore(path: dbPath2)
        try await mbStore.open()
        let mb = MessageBuilder(
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            sessionCompressor: SessionCompressor(store: mbStore, fts: FTS5Search(store: mbStore)),
            complexityAnalyzer: ComplexityAnalyzer(),
            thinkingBudget: ThinkingBudget()
        )

        return try await buildApplication(
            enginePool: enginePool,
            scheduler: SchedulerActor(maxQueueSize: 4, memoryTracker: nil, log: log),
            metrics: MetricsRegistry(),
            sessionCompressor: compressor,
            semanticSearch: nil,
            mcpBridge: MCPBridge(
                toolRegistry: ToolRegistry(log: log),
                transport: MCPStdioTransport(log: log)
            ),
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            messageBuilder: mb,
            logger: log,
            authMiddleware: AuthMiddleware<OCoreAIContext>(config: .default, logger: log),
            rateLimitMiddleware: RateLimitMiddleware(
                provider: RateLimitProvider(
                    config: RateLimitProvider.Config(
                        globalRate: 1000,
                        globalBurst: 2000,
                        perModelRate: 500,
                        perModelBurst: 1000,
                        perIPRate: 500,
                        perIPBurst: 1000,
                        enabled: false
                    ),
                    logger: log
                ),
                logger: log
            ),
            hfToken: nil,
            msToken: nil
        )
    }

    private static func body(_ dict: [String: Any]) throws -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 1024)
        buffer.writeBytes(try JSONSerialization.data(withJSONObject: dict, options: []))
        return buffer
    }

    private static func text(_ response: TestResponse) -> String {
        response.body.getString(at: 0, length: response.body.readableBytes) ?? ""
    }

    /// `error.error_code` of a JSON error body, "" when absent.
    private static func errorCode(_ response: TestResponse) -> String {
        guard
            let obj = try? JSONSerialization.jsonObject(with: Data(buffer: response.body))
                as? [String: Any],
            let error = obj["error"] as? [String: Any]
        else { return "" }
        return error["error_code"] as? String ?? ""
    }

    private static func errorMessage(_ response: TestResponse) -> String {
        guard
            let obj = try? JSONSerialization.jsonObject(with: Data(buffer: response.body))
                as? [String: Any],
            let error = obj["error"] as? [String: Any]
        else { return "" }
        return error["message"] as? String ?? ""
    }

    @Test("POST /v1/messages/count_tokens is wired (not a 404 route-not-found)")
    func anthropicCountTokensRouteExists() async throws {
        let (db1, db2) = (Self.uuidPath(), Self.uuidPath())
        defer {
            try? FileManager.default.removeItem(atPath: db1)
            try? FileManager.default.removeItem(atPath: db2)
        }
        let app = try await Self.makeTestApp(db1, db2)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/messages/count_tokens",
                method: .post,
                headers: [.contentType: "application/json"],
                body: try Self.body([
                    "model": Self.unknownModel,
                    "messages": [["role": "user", "content": "size this prompt"]],
                ])
            ) { response in
                // The status is 404 here (unknown model) — what must NOT be true is
                // `route_not_found`: that is the 10-13 failure this endpoint fixes.
                #expect(Self.errorCode(response) != "route_not_found")
                #expect(Self.errorMessage(response).contains(Self.unknownModel))
            }
        }
    }

    @Test("spec-legal bodies are accepted — no `Coding key prompt not found`")
    func specLegalShapesAreNotRejectedByTheDecoder() async throws {
        let (db1, db2) = (Self.uuidPath(), Self.uuidPath())
        defer {
            try? FileManager.default.removeItem(atPath: db1)
            try? FileManager.default.removeItem(atPath: db2)
        }
        let app = try await Self.makeTestApp(db1, db2)
        // Encode outside the @Sendable closure: [String: Any] is not Sendable, and the
        // Hummingbird test client's closure is @Sendable.
        let rawShapes: [(String, [String: Any])] = [
            ("OpenAI input string", ["model": Self.unknownModel, "input": "hello"]),
            ("OpenAI input parts", ["model": Self.unknownModel, "input": ["a", "b"]]),
            (
                "OpenAI input messages",
                [
                    "model": Self.unknownModel,
                    "input": [["role": "user", "content": "hi"]],
                ],
            ),
            (
                "Anthropic messages + system",
                [
                    "model": Self.unknownModel,
                    "system": "be terse",
                    "messages": [["role": "user", "content": "hi"]],
                ],
            ),
            ("legacy prompt", ["model": Self.unknownModel, "prompt": "hello"]),
        ]
        let shapes: [(String, ByteBuffer)] = try rawShapes.map { label, shape in
            (label, try Self.body(shape))
        }
        try await app.test(.router) { client in
            for (label, shape) in shapes {
                try await client.execute(
                    uri: "/v1/count-tokens",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: shape
                ) { response in
                    let message = Self.errorMessage(response)
                    #expect(response.status.code != 400, "\(label) rejected: \(message)")
                    #expect(
                        !message.contains("Coding key"),
                        "\(label) hit the synthesized-decoder wall: \(message)")
                    #expect(Self.errorCode(response) != "route_not_found", "\(label) not routed")
                }
            }
        }
    }

    @Test("nothing countable → 400 that names the fields a client may send")
    func emptyCountRequestNamesTheAcceptedFields() async throws {
        let (db1, db2) = (Self.uuidPath(), Self.uuidPath())
        defer {
            try? FileManager.default.removeItem(atPath: db1)
            try? FileManager.default.removeItem(atPath: db2)
        }
        let app = try await Self.makeTestApp(db1, db2)
        try await app.test(.router) { client in
            for body in [["model": Self.unknownModel], ["model": Self.unknownModel, "prompt": ""]] {
                try await client.execute(
                    uri: "/v1/count-tokens",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: try Self.body(body)
                ) { response in
                    #expect(response.status.code == 400)
                    let message = Self.errorMessage(response)
                    for field in ["messages", "input", "prompt"] {
                        #expect(
                            message.contains(field),
                            "400 must name `\(field)`: \(message)")
                    }
                }
            }
        }
    }

    @Test("GET /v1/capabilities publishes the endpoint index the 404 hint points at")
    func capabilitiesPublishesEndpointIndex() async throws {
        let (db1, db2) = (Self.uuidPath(), Self.uuidPath())
        defer {
            try? FileManager.default.removeItem(atPath: db1)
            try? FileManager.default.removeItem(atPath: db2)
        }
        let app = try await Self.makeTestApp(db1, db2)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/capabilities", method: .get) { response in
                #expect(response.status.code == 200)
                guard
                    let obj = try? JSONSerialization.jsonObject(
                        with: Data(buffer: response.body)) as? [String: Any],
                    let lines = obj["endpoints"] as? [[String: Any]]
                else {
                    Issue.record(
                        "`endpoints` missing from /v1/capabilities: \(Self.text(response))")
                    return
                }
                // The index the 404 hint promises is the catalog, at full length.
                #expect(lines.count == V1EndpointCatalog.routes.count)
                let published: Set<String> = Set(
                    lines.compactMap { line in
                        guard let method = line["method"] as? String,
                            let path = line["path"] as? String
                        else { return nil }
                        return "\(method) \(path)"
                    })
                #expect(published.count == lines.count, "duplicate or malformed index lines")
                for must in [
                    "POST /v1/count-tokens", "POST /v1/messages/count_tokens",
                    "GET /v1/capabilities", "POST /v1/chat/completions",
                ] {
                    #expect(published.contains(must), "index is missing \(must)")
                }
                for line in lines {
                    #expect((line["note"] as? String)?.isEmpty == false)
                    #expect(
                        ["public", "key", "admin"].contains(line["auth"] as? String ?? ""),
                        "auth column not derived from the policy: \(line)")
                }
                #expect(obj["tokenizerBackend"] != nil || obj["tokenizer_backend"] != nil)
            }
        }
    }
}
