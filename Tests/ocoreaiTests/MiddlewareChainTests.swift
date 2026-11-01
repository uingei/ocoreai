// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Integration Tests — Middleware Chain: Auth + Rate Limit
///
/// Fills the gap where HTTPE2ESmokeTests runs with auth disabled
/// (AuthMiddleware(.default) → env var → empty → bypassed).
/// These tests verify the middleware pipeline with auth actually enabled.

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing

@testable import ocoreai

private func e2eUUID() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("e2e_\(UUID().uuidString.prefix(8)).sqlite")
        .path
}

private func cleanupE2E(_ paths: [String]) {
    for p in paths { try? FileManager.default.removeItem(atPath: p) }
}

@Suite("Middleware Chain")
struct MiddlewareChainTests {

    private static let log = Logger(label: "test.integration.middleware")

    private static func jsonBody(_ dict: [String: Any]) throws -> ByteBuffer {
        var buf = ByteBufferAllocator().buffer(capacity: 1024)
        buf.writeBytes(try JSONSerialization.data(withJSONObject: dict, options: []))
        return buf
    }

    private static func makeApp(
        authKeys: [String],
        rlConfig: RateLimitProvider.Config = RateLimitProvider.Config(
            globalRate: 1000, globalBurst: 2000,
            perModelRate: 500, perModelBurst: 1000,
            perIPRate: 500, perIPBurst: 1000, enabled: true
        )
    ) async throws -> ((some ApplicationProtocol), [String]) {
        let db1 = e2eUUID()
        let db2 = e2eUUID()
        let enginePool = EnginePool(
            config: .default, logger: Self.log, tokenizerManager: TokenizerManager())
        let store = SQLiteStore(path: db1)
        try await store.open()
        let fts = FTS5Search(store: store)
        let compressor = SessionCompressor(store: store, fts: fts)
        let mbStore = SQLiteStore(path: db2)
        try await mbStore.open()
        let mbFts = FTS5Search(store: mbStore)
        let mb = MessageBuilder(
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            sessionCompressor: SessionCompressor(store: mbStore, fts: mbFts),
            complexityAnalyzer: ComplexityAnalyzer(),
            thinkingBudget: ThinkingBudget()
        )
        let scheduler = SchedulerActor(maxQueueSize: 4, memoryTracker: nil, log: Self.log)
        let app = try await buildApplication(
            enginePool: enginePool, scheduler: scheduler, metrics: MetricsRegistry(),
            sessionCompressor: compressor,
            semanticSearch: nil,
            mcpBridge: MCPBridge(
                toolRegistry: ToolRegistry(log: Self.log),
                transport: MCPStdioTransport(log: Self.log)),
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            messageBuilder: mb, logger: Self.log,
            authMiddleware: AuthMiddleware<OCoreAIContext>(
                config: AuthConfig(apiKeys: authKeys), logger: Self.log),
            rateLimitMiddleware: RateLimitMiddleware(
                provider: RateLimitProvider(config: rlConfig, logger: Self.log),
                logger: Self.log
            ),
            hfToken: nil, msToken: nil
        )
        return (app, [db1, db2])
    }

    // ── Auth blocks unauthenticated ──

    @Test("Auth on: no key → 401/403")
    func testAuthBlocksUnauthenticated() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["key1"])
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            let buf = try Self.jsonBody([
                "model": "x", "messages": [["role": "user", "content": "hi"]],
            ])
            let h: HTTPFields = [.contentType: "application/json"]
            try await client.execute(
                uri: "/v1/chat/completions", method: .post, headers: h, body: buf
            ) { r in
                #expect(r.status == .unauthorized || r.status == .forbidden, "got \(r.status)")
            }
        }
    }

    @Test("Auth on: GET /health bypasses")
    func testAuthBypassHealth() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["key1"])
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { r in #expect(r.status == .ok) }
        }
    }

    @Test("Auth on: GET /v1/models bypasses")
    func testAuthBypassModels() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["key1"])
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) { r in
                #expect(r.status == .ok)
            }
        }
    }

    // ── Auth: valid credentials pass ──

    @Test("Auth on: Bearer passes → handler sees request")
    func testAuthBearer() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["key1"])
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            let buf = try Self.jsonBody(["model": "x", "messages": []])
            var h: HTTPFields = [.contentType: "application/json"]
            h[.authorization] = "Bearer key1"
            try await client.execute(
                uri: "/v1/chat/completions", method: .post, headers: h, body: buf
            ) { r in
                #expect(r.status != .unauthorized, "auth fail: \(r.status)")
            }
        }
    }

    @Test("Auth on: api-key header passes")
    func testAuthApiKeyHeader() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["secret"])
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            let buf = try Self.jsonBody([
                "model": "x", "messages": [["role": "user", "content": "hi"]],
            ])
            var h: HTTPFields = [.contentType: "application/json"]
            h[HTTPField.Name("api-key")!] = "secret"
            try await client.execute(
                uri: "/v1/chat/completions", method: .post, headers: h, body: buf
            ) { r in
                #expect(r.status != .unauthorized, "auth fail: \(r.status)")
            }
        }
    }

    @Test("Auth on: api_key query param passes")
    func testAuthQueryParam() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["qkey"])
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            let buf = try Self.jsonBody([
                "model": "x", "messages": [["role": "user", "content": "hi"]],
            ])
            let h: HTTPFields = [.contentType: "application/json"]
            try await client.execute(
                uri: "/v1/chat/completions?api_key=qkey", method: .post, headers: h, body: buf
            ) { r in
                #expect(r.status != .unauthorized, "auth fail: \(r.status)")
            }
        }
    }

    @Test("Auth on: wrong key → 401")
    func testAuthWrongKey() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["correct"])
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            let buf = try Self.jsonBody([
                "model": "x", "messages": [["role": "user", "content": "hi"]],
            ])
            var h: HTTPFields = [.contentType: "application/json"]
            h[.authorization] = "Bearer wrong"
            try await client.execute(
                uri: "/v1/chat/completions", method: .post, headers: h, body: buf
            ) { r in
                #expect(r.status == .unauthorized, "got \(r.status)")
            }
        }
    }

    @Test("Auth off: no key required")
    func testAuthDisabled() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: [])
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            let buf = try Self.jsonBody(["model": "x", "messages": []])
            let h: HTTPFields = [.contentType: "application/json"]
            try await client.execute(
                uri: "/v1/chat/completions", method: .post, headers: h, body: buf
            ) { r in
                #expect(r.status == .badRequest, "auth off, got \(r.status)")
            }
        }
    }

    // ── Rate limit ──

    // ── § credential rungs: the ladder is a decision, and the order is pinned ──

    /// Anthropic's SDK authenticates with `x-api-key`, and `openapi.json` publishes
    /// `/v1/messages`. With a key configured and this rung missing, that SDK got 401 from
    /// a door the contract advertised — the surface claiming more than it served.
    @Test("Auth on: x-api-key passes (what the Anthropic SDK sends)")
    func testAuthAnthropicKeyHeader() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["secret"])
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            let buf = try Self.jsonBody(["model": "x", "messages": []])
            var h: HTTPFields = [.contentType: "application/json"]
            h[HTTPField.Name("x-api-key")!] = "secret"
            try await client.execute(
                uri: "/v1/chat/completions", method: .post, headers: h, body: buf
            ) { r in
                #expect(r.status != .unauthorized, "auth fail: \(r.status)")
            }
        }
    }

    /// The rung must not become a bypass: an empty-looking credential on a readable rung
    /// still has to match the configured key.
    @Test("Auth on: wrong key in x-api-key → 401 (a rung, not a bypass)")
    func testAuthAnthropicKeyWrong() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["correct"])
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            let buf = try Self.jsonBody(["model": "x", "messages": []])
            var h: HTTPFields = [.contentType: "application/json"]
            h[HTTPField.Name("x-api-key")!] = "guessed"
            try await client.execute(
                uri: "/v1/chat/completions", method: .post, headers: h, body: buf
            ) { r in
                #expect(r.status == .unauthorized, "got \(r.status)")
            }
        }
    }

    /// The order, stated as an assertion because it is a decision: the FIRST rung present
    /// is the one judged, once. splash instead refuses any request whose supplied
    /// credentials disagree (`http_security.py:22-38`); we keep the ladder mlx-serve and
    /// omlx run, so a client sending two rungs is answered by the earlier one — and this
    /// line is where a future change to that choice has to be argued.
    @Test("Ladder order: a bad Bearer ahead of a good x-api-key is refused, not skipped")
    func testCredentialLadderOrder() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["secret"])
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            let buf = try Self.jsonBody(["model": "x", "messages": []])
            var h: HTTPFields = [.contentType: "application/json"]
            h[.authorization] = "Bearer stale"
            h[HTTPField.Name("x-api-key")!] = "secret"
            try await client.execute(
                uri: "/v1/chat/completions", method: .post, headers: h, body: buf
            ) { r in
                #expect(r.status == .unauthorized, "got \(r.status)")
            }
        }
    }

    // ── § the 401 names a scheme (RFC 9110 §10.2.3), the 403 does not ──

    @Test("401 carries WWW-Authenticate naming the scheme that applies")
    func testUnauthorizedNamesChallenge() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["key1"])
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            let buf = try Self.jsonBody(["model": "x", "messages": []])
            let h: HTTPFields = [.contentType: "application/json"]
            try await client.execute(
                uri: "/v1/chat/completions", method: .post, headers: h, body: buf
            ) { r in
                #expect(r.status == .unauthorized, "got \(r.status)")
                #expect(
                    r.headers[.wwwAuthenticate] == #"Bearer realm="ocoreai""#,
                    "a 401 with no challenge leaves the client to guess: \(r.headers)")
            }
        }
    }

    // ── § a browser page may not write here ──

    /// `POST /mcp` reaches `tools/call`, no key is configured by default, and a
    /// `text/plain` body never preflights — so before this gate any web page the user
    /// happened to have open could drive this process. The control matters as much as the
    /// refusal: the same write WITHOUT an Origin is a native client and must still work,
    /// or the gate is a self-inflicted outage measured as a security win.
    @Test("A mutating request from a browser Origin is refused — and the key does not buy it")
    func testBrowserOriginWriteRefused() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["key1"])
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            let buf = try Self.jsonBody(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
            var page: HTTPFields = [.contentType: "text/plain"]
            page[.origin] = "http://some-page.example"
            page[.authorization] = "Bearer key1"
            try await client.execute(uri: "/mcp", method: .post, headers: page, body: buf) { r in
                #expect(r.status == .forbidden, "got \(r.status)")
                // No credential would change the answer — that is what the refusal says —
                // so RFC 9110 gives a 403 no challenge.
                #expect(r.headers[.wwwAuthenticate] == nil, "403 named a challenge")
            }
            var native: HTTPFields = [.contentType: "application/json"]
            native[.authorization] = "Bearer key1"
            try await client.execute(
                uri: "/mcp", method: .post, headers: native, body: buf
            ) { r in
                #expect(
                    r.status != .forbidden && r.status != .unauthorized,
                    "a native client (no Origin) must still be served, got \(r.status)")
            }
        }
    }

    @Test("A read from a browser Origin is not a write (and CORS still withholds the reply)")
    func testBrowserOriginReadNotRefused() async throws {
        let (app, dbs) = try await Self.makeApp(authKeys: ["key1"])
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            var h: HTTPFields = [:]
            h[.origin] = "http://some-page.example"
            h[.authorization] = "Bearer key1"
            try await client.execute(uri: "/health", method: .get, headers: h) { r in
                #expect(r.status == .ok, "a GET is not a mutation, got \(r.status)")
                #expect(r.headers[.accessControlAllowOrigin] == nil, "CORS is off here")
            }
        }
    }

    @Test("Rate limit: burst=2 → 3rd request 429")
    func testRateLimitExhaustion() async throws {
        let tiny = RateLimitProvider.Config(
            globalRate: 5, globalBurst: 2,
            perModelRate: 5, perModelBurst: 2,
            perIPRate: 5, perIPBurst: 2, enabled: true
        )
        let (app, dbs) = try await Self.makeApp(authKeys: [], rlConfig: tiny)
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { r in #expect(r.status == .ok) }
            try await client.execute(uri: "/health", method: .get) { r in #expect(r.status == .ok) }
            try await client.execute(uri: "/health", method: .get) { r in
                #expect(r.status == .tooManyRequests, "expected 429, got \(r.status)")
            }
        }
    }

    @Test("Rate limit: disabled → 5 requests pass")
    func testRateLimitDisabled() async throws {
        let off = RateLimitProvider.Config(
            globalRate: 1000, globalBurst: 2000,
            perModelRate: 500, perModelBurst: 1000,
            perIPRate: 500, perIPBurst: 1000, enabled: false
        )
        let (app, dbs) = try await Self.makeApp(authKeys: [], rlConfig: off)
        defer { cleanupE2E(dbs) }
        try await app.test(.router) { client in
            for _ in 0 ..< 5 {
                try await client.execute(uri: "/health", method: .get) { r in
                    #expect(r.status == .ok)
                }
            }
        }
    }
}
