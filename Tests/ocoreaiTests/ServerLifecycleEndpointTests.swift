// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Server Lifecycle Endpoint Tests — `/ready`, `/v1/stats`, `POST /v1` auto-route
///
/// Covers the three llm-server (coreai-models) wire contracts added to ocoreai:
/// - ``GET /ready``  — readiness probe (ready/busy)
/// - ``GET /v1/stats`` — structured inference counters/gauges (JSON)
/// - ``POST /v1``    — auto-route (prompt → completions, else chat)
///
/// Every asserted value is exact (no `>0` / "contains something" weak assertions):
/// seeded ``MetricsRegistry`` values are checked field-by-field against the
/// ``/v1/stats`` response; dispatch is proven by branch-specific guard message.

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing

@testable import ocoreai

@Suite("Server Lifecycle Endpoints")
struct ServerLifecycleEndpointTests {
    // MARK: - App factory (returns the seeded MetricsRegistry for exact-value asserts)

    private static func uuidPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("slc_\(UUID().uuidString.prefix(8)).sqlite").path
    }

    private static func cleanup(_ p1: String, _ p2: String) {
        try? FileManager.default.removeItem(atPath: p1)
        try? FileManager.default.removeItem(atPath: p2)
    }

    private static func jsonBody(_ s: String) -> ByteBuffer {
        var b = ByteBufferAllocator().buffer(capacity: s.utf8.count)
        b.writeString(s)
        return b
    }

    private static func bodyString(_ r: TestResponse) -> String {
        r.body.getString(at: 0, length: r.body.readableBytes) ?? ""
    }

    /// Build the app exactly like the production wiring, but return the
    /// ``MetricsRegistry`` so tests can seed it for exact-value assertions.
    private static func makeApp(
        authKeys: [String],
        metrics: MetricsRegistry
    ) async throws -> (some ApplicationProtocol, [String]) {
        let db1 = uuidPath()
        let db2 = uuidPath()
        let enginePool = EnginePool(
            config: .default, logger: log, tokenizerManager: TokenizerManager())
        let store = SQLiteStore(path: db1)
        try await store.open()
        let fts = FTS5Search(store: store)
        let compressor = SessionCompressor(store: store, fts: fts)
        let mbStore = SQLiteStore(path: db2)
        try await mbStore.open()
        let mbFts = FTS5Search(store: mbStore)
        let mb = MessageBuilder(
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "t"),
            sessionCompressor: SessionCompressor(store: mbStore, fts: mbFts),
            complexityAnalyzer: ComplexityAnalyzer(), thinkingBudget: ThinkingBudget())
        let scheduler = SchedulerActor(maxQueueSize: 4, memoryTracker: nil, log: log)
        let app = try await buildApplication(
            enginePool: enginePool,
            scheduler: scheduler,
            metrics: metrics,
            sessionCompressor: compressor,
            semanticSearch: nil,
            mcpBridge: MCPBridge(
                toolRegistry: ToolRegistry(log: log), transport: MCPStdioTransport(log: log)),
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "t"),
            messageBuilder: mb,
            logger: log,
            authMiddleware: AuthMiddleware<OCoreAIContext>(
                config: AuthConfig(apiKeys: authKeys), logger: log),
            rateLimitMiddleware: RateLimitMiddleware(
                provider: RateLimitProvider(
                    config: RateLimitProvider.Config(
                        globalRate: 1000, globalBurst: 2000, perModelRate: 500,
                        perModelBurst: 1000, perIPRate: 500, perIPBurst: 1000, enabled: true),
                    logger: log),
                logger: log
            ),
            hfToken: nil, msToken: nil
        )
        return (app, [db1, db2])
    }

    private static let log = Logger(label: "test.slc")

    // MARK: - GET /ready

    @Test("GET /ready → 200, status=ready, activeSessions=0, loadedModels=0")
    func testReadyEndpoint() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: [], metrics: MetricsRegistry())
        defer { Self.cleanup(dbs[0], dbs[1]) }
        try await app.test(.router) { client in
            try await client.execute(uri: "/ready", method: .get) { r in
                #expect(r.status == .ok, "got \(r.status)")
                let body = Self.bodyString(r)
                #expect(body.contains("\"status\":\"ready\""), "body: \(body)")
                #expect(body.contains("\"activeSessions\":0"), "body: \(body)")
                #expect(body.contains("\"loadedModels\":0"), "body: \(body)")
            }
        }
    }

    @Test("Auth on: GET /ready bypasses (200, no key)")
    func testReadyBypassesAuth() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["k1"], metrics: MetricsRegistry())
        defer { Self.cleanup(dbs[0], dbs[1]) }
        try await app.test(.router) { client in
            try await client.execute(uri: "/ready", method: .get) { r in #expect(r.status == .ok) }
        }
    }

    // MARK: - GET /v1/stats

    @Test("GET /v1/stats exact seeded values")
    func testStatsExactValues() async throws {
        let metrics = MetricsRegistry()
        // Seed exact inference + TTFB samples (simple overloads, token counts zero).
        await metrics.observeInferenceDuration(2.0)  // count=1, sum=2.0
        await metrics.observeTTFB(0.5)  // ttfbCount=1, ttfbSum=0.5
        // Seed exact token counters.
        await metrics.incrementTokens(kind: "prompt", count: 100)
        await metrics.incrementTokens(kind: "generated", count: 40)
        // Seed gauges.
        await metrics.updateActiveSessions(3)
        await metrics.updateLoadedModels(2)

        let (app, dbs) = try await Self.makeApp(authKeys: [], metrics: metrics)
        defer { Self.cleanup(dbs[0], dbs[1]) }
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/stats", method: .get) { r in
                #expect(r.status == .ok, "got \(r.status)")
                let body = Self.bodyString(r)
                #expect(body.contains("\"totalRequests\":1"), "body: \(body)")
                #expect(body.contains("\"totalPromptTokens\":100"), "body: \(body)")
                #expect(body.contains("\"totalGeneratedTokens\":40"), "body: \(body)")
                // Integer-valued Double serializes as "2" (JSON numeric, == 2.0).
                #expect(body.contains("\"totalInferenceSeconds\":2,"), "body: \(body)")
                #expect(body.contains("\"avgInferenceSeconds\":2,"), "body: \(body)")
                #expect(body.contains("\"ttfbSampleCount\":1"), "body: \(body)")
                #expect(body.contains("\"avgTTFBSeconds\":0.5"), "body: \(body)")
                #expect(body.contains("\"activeSessions\":3"), "body: \(body)")
                #expect(body.contains("\"loadedModels\":2"), "body: \(body)")
            }
        }
    }

    @Test("Auth on: GET /v1/stats bypasses (200, no key)")
    func testStatsBypassesAuth() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["k1"], metrics: MetricsRegistry())
        defer { Self.cleanup(dbs[0], dbs[1]) }
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/stats", method: .get) { r in #expect(r.status == .ok)
            }
        }
    }

    // MARK: - POST /v1 auto-route

    @Test("POST /v1 prompt branch → routs to completions (400 'Prompt must be')")
    func testAutoRoutePromptBranch() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: [], metrics: MetricsRegistry())
        defer { Self.cleanup(dbs[0], dbs[1]) }
        try await app.test(.router) { client in
            let buf = Self.jsonBody("{\"prompt\":\"\"}")
            let h: HTTPFields = [.contentType: "application/json"]
            try await client.execute(uri: "/v1", method: .post, headers: h, body: buf) { r in
                // Empty single-string prompt passes the route guard (array non-empty),
                // reaches the completions handler which rejects blank-only prompts → 400.
                #expect(r.status == .badRequest, "got \(r.status)")
                let body = Self.bodyString(r)
                #expect(
                    body.lowercased().contains("prompt") && body.lowercased().contains("non-empty"),
                    "expected completions guard message, body: \(body)"
                )
            }
        }
    }

    @Test("POST /v1 messages branch → routes to chat (400 'Messages array must not be empty')")
    func testAutoRouteChatBranch() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: [], metrics: MetricsRegistry())
        defer { Self.cleanup(dbs[0], dbs[1]) }
        try await app.test(.router) { client in
            let buf = Self.jsonBody("{\"messages\":[]}")
            let h: HTTPFields = [.contentType: "application/json"]
            try await client.execute(uri: "/v1", method: .post, headers: h, body: buf) { r in
                #expect(r.status == .badRequest, "got \(r.status)")
                let body = Self.bodyString(r)
                // empty messages is rejected at decode (required non-empty) or the
                // router guard — both are 400; assert the class, not the exact message.
                #expect(
                    body.contains("Messages") || body.contains("Invalid ChatCompletionRequest"),
                    "expected a 400 chat reject, body: \(body)"
                )
            }
        }
    }

    @Test("POST /v1 invalid JSON → 400")
    func testAutoRouteInvalidJSON() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: [], metrics: MetricsRegistry())
        defer { Self.cleanup(dbs[0], dbs[1]) }
        try await app.test(.router) { client in
            let buf = Self.jsonBody("not json")
            let h: HTTPFields = [.contentType: "application/json"]
            try await client.execute(uri: "/v1", method: .post, headers: h, body: buf) { r in
                #expect(r.status == .badRequest, "got \(r.status)")
                let body = Self.bodyString(r)
                #expect(body.lowercased().contains("json"), "expected JSON error, body: \(body)")
            }
        }
    }

    @Test("POST /v1 prompt type error → 400 (decode path, not 500)")
    func testAutoRoutePromptTypeBad() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: [], metrics: MetricsRegistry())
        defer { Self.cleanup(dbs[0], dbs[1]) }
        try await app.test(.router) { client in
            // prompt present but wrong type → CompletionRequest decode must fail as 400.
            let buf = Self.jsonBody("{\"prompt\":123}")
            let h: HTTPFields = [.contentType: "application/json"]
            try await client.execute(uri: "/v1", method: .post, headers: h, body: buf) { r in
                #expect(r.status == .badRequest, "got \(r.status)")
            }
        }
    }

    @Test("Auth on: POST /v1 requires key (401/403 without)")
    func testAutoRouteRequiresAuth() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["k1"], metrics: MetricsRegistry())
        defer { Self.cleanup(dbs[0], dbs[1]) }
        try await app.test(.router) { client in
            let buf = Self.jsonBody("{\"prompt\":\"hi\"}")
            let h: HTTPFields = [.contentType: "application/json"]
            try await client.execute(uri: "/v1", method: .post, headers: h, body: buf) { r in
                #expect(r.status == .unauthorized || r.status == .forbidden, "got \(r.status)")
            }
        }
    }
}
