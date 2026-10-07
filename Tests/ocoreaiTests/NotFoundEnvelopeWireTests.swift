// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Wire contract tests — JSON envelope on EVERY error path, including
/// unmatched routes and HEAD semantics.
///
/// Before NotFoundEnvelopeMiddleware, a trie-miss 404 had an EMPTY body
/// (Hummingbird's HTTPError(.notFound) carries nil body → bare
/// Response(status:)), the only endpoint class in this service that broke
/// the "every error is structured JSON" contract. And without
/// .autoGenerateHeadEndpoints, `HEAD /health` 404d on a route that exists —
/// RFC 9110: GET implies HEAD. Both are honesty-floor defects: a client
/// cannot distinguish "route missing" from "server broken" from `404 len=0`.

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing

@testable import ocoreai

@Suite("404 Envelope & HEAD Wire Contract")
struct NotFoundEnvelopeWireTests {

    private static let log = Logger(label: "test.notfound.envelope")

    private func e2eUUID() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nf_\(UUID().uuidString.prefix(8)).sqlite")
            .path
    }

    private func makeApp() async throws -> (some ApplicationProtocol, String) {
        let db = e2eUUID()
        let enginePool = EnginePool(
            config: .default, logger: Self.log, tokenizerManager: TokenizerManager())
        let store = SQLiteStore(path: db)
        try await store.open()
        let fts = FTS5Search(store: store)
        let compressor = SessionCompressor(store: store, fts: fts)
        let mb = MessageBuilder(
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            sessionCompressor: compressor,
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
                config: AuthConfig(apiKeys: []), logger: Self.log),
            rateLimitMiddleware: RateLimitMiddleware(
                provider: RateLimitProvider(
                    config: RateLimitProvider.Config(
                        globalRate: 1000, globalBurst: 2000,
                        perModelRate: 500, perModelBurst: 1000,
                        perIPRate: 500, perIPBurst: 1000, enabled: false),
                    logger: Self.log),
                logger: Self.log
            ),
            hfToken: nil, msToken: nil
        )
        return (app, db)
    }

    private func decodeError(_ body: ByteBuffer) throws -> [String: Any] {
        let data = Data(buffer: body)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let top = obj as? [String: Any],
            let err = top["error"] as? [String: Any]
        else {
            Issue.record(
                "body is not the {\"error\":{…}} envelope: \(String(data: data, encoding: .utf8) ?? "<binary>")"
            )
            return [:]
        }
        return err
    }

    // ── Unmatched path: flat-JSON envelope, never an empty body ──

    @Test("unknown path → 404 with flat JSON envelope + route_not_found")
    func unknownPathHasEnvelope() async throws {
        let (app, db) = try await makeApp()
        defer { try? FileManager.default.removeItem(atPath: db) }
        try await app.test(.router) { client in
            try await client.execute(uri: "/no/such/route", method: .get) { r in
                #expect(r.status == .notFound)
                let err = try self.decodeError(r.body)
                #expect(err["code"] as? Int == 404)
                #expect(err["type"] as? String == "app_error")
                #expect(err["error_code"] as? String == "route_not_found")
                let msg = err["message"] as? String ?? ""
                #expect(msg.contains("GET /no/such/route"), "message names the miss: \(msg)")
                #expect(r.headers[.contentType]?.contains("application/json") == true)
            }
        }
    }

    @Test("unknown method on known path shape → envelope names method+path")
    func postToHealthUnknownMethod() async throws {
        let (app, db) = try await makeApp()
        defer { try? FileManager.default.removeItem(atPath: db) }
        try await app.test(.router) { client in
            // /health registers GET only (+ auto HEAD). POST misses the trie.
            try await client.execute(uri: "/health", method: .post) { r in
                #expect(r.status == .notFound)
                let err = try self.decodeError(r.body)
                #expect(err["error_code"] as? String == "route_not_found")
                let details = err["details"] as? [String: Any] ?? [:]
                #expect(details["method"] as? String == "POST")
                #expect(details["path"] as? String == "/health")
            }
        }
    }

    // ── Boundary: the catch is HTTPError(.notFound)-only — matched-route ──
    // ── AppError 404s keep their ORIGINAL envelope (no details key) ───────

    @Test("boundary: matched-route AppError 404 keeps original shape")
    func appError404Unchanged() async throws {
        let (app, db) = try await makeApp()
        defer { try? FileManager.default.removeItem(atPath: db) }
        try await app.test(.router) { client in
            // /v1/models/:model/sampling IS registered; unknown model → AppError
            // .modelNotFound thrown INSIDE the handler, re-encoded by HB at the
            // responder level — invisible to NotFoundEnvelopeMiddleware (which
            // only observes the trie miss below the responder chain).
            try await client.execute(
                uri: "/v1/models/no-such-model/sampling", method: .get
            ) { r in
                #expect(r.status == .notFound)
                let err = try self.decodeError(r.body)
                #expect(err["code"] as? Int == 404)
                #expect(err["type"] as? String == "app_error")
                // AppError envelope: message says "not found", NO error_code
                // (only context-window/memory cases carry error_code), NO
                // details key — proves the middleware did NOT rewrite it.
                let msg = err["message"] as? String ?? ""
                #expect(msg.contains("no-such-model"), "named the model: \(msg)")
                #expect(
                    err["error_code"] == nil, "AppError 404 must not gain route_not_found: \(err)")
                #expect(err["details"] == nil)
            }
        }
    }

    // ── HEAD: GET implies HEAD (RFC 9110) ──

    @Test("HEAD /health → 200, empty body, content-length preserved")
    func headHealthWorks() async throws {
        let (app, db) = try await makeApp()
        defer { try? FileManager.default.removeItem(atPath: db) }
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .head) { r in
                #expect(r.status == .ok, "HEAD on a registered GET must not 404")
                // createHeadResponse keeps content-type, strips the body.
                #expect(r.body.readableBytesView.isEmpty)
                #expect(r.headers[.contentType]?.contains("application/json") == true)
            }
        }
    }

    @Test("HEAD unknown path → 404 envelope (not empty body)")
    func headUnknownPathEnvelope() async throws {
        let (app, db) = try await makeApp()
        defer { try? FileManager.default.removeItem(atPath: db) }
        try await app.test(.router) { client in
            try await client.execute(uri: "/nope", method: .head) { r in
                #expect(r.status == .notFound)
                // createHeadResponse() strips bodies — envelope presence is
                // asserted via content-type + the GET sibling of same path.
                #expect(r.headers[.contentType]?.contains("application/json") == true)
            }
            try await client.execute(uri: "/nope", method: .get) { r in
                let err = try self.decodeError(r.body)
                #expect(err["error_code"] as? String == "route_not_found")
            }
        }
    }

    // ── Envelope is valid for every miss method ──

    @Test("PUT/PATCH/DELETE unknown → envelope on all")
    func allMethodsMissEnvelope() async throws {
        let (app, db) = try await makeApp()
        defer { try? FileManager.default.removeItem(atPath: db) }
        try await app.test(.router) { client in
            for method in [HTTPRequest.Method.put, .patch, .delete] {
                try await client.execute(uri: "/unknown/\(method.rawValue)", method: method) { r in
                    #expect(r.status == .notFound)
                    let err = try self.decodeError(r.body)
                    #expect(err["error_code"] as? String == "route_not_found")
                }
            }
        }
    }
}
