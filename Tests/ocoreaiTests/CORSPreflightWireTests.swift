// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Wire contract tests — the browser-origin decision (`OCOREAI_CORS_ORIGIN`).
///
/// Two claims live here, and both are about ordering rather than about any one layer.
///
/// 1. A preflight must be answered before the API-key gate. `fetch` sends no
///    `Authorization` on an OPTIONS preflight — that is the whole point of the
///    preflight — so a chain that asks for a key first answers 401 to a question whose
///    answer the browser needs in order to send the key. Registering CORS after auth
///    makes every authenticated browser client fail, while `curl` (which never
///    preflights) keeps passing.
///
/// 2. A 404 a browser can read is still a 404 with its envelope. Upstream's CORS layer
///    re-throws a downstream error wrapped so it carries the CORS headers
///    (CORSMiddleware.swift:220-229), and the 404 middleware matches on `HTTPError`,
///    not on the wrapper — with CORS *inside* it, the envelope disappears and the
///    client gets a bare body it cannot parse. Outside it, both survive.
///
/// The off face is asserted too: `nil` must be byte-identical to the surface that
/// existed before this knob, or "opt-in" would be a word and not a fact.

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing

@testable import ocoreai

@Suite("CORS preflight & origin allow-list")
struct CORSPreflightWireTests {

    private static let log = Logger(label: "test.cors.wire")
    private static let allowed = "http://app.test"
    private static let other = "http://elsewhere.test"

    private func dbPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cors_\(UUID().uuidString.prefix(8)).sqlite")
            .path
    }

    /// The real chain — the same `buildRouter` the server boots, not a stand-in.
    private func makeApp(
        cors: CORSPolicy.Allow?,
        authKeys: [String] = []
    ) async throws -> (some ApplicationProtocol, String) {
        // One decision feeds both halves of the chain, exactly as `App` wires it: the
        // value that registers the middleware is the value `AuthMiddleware` consults
        // before a browser write. Passing them separately here would let a test build a
        // chain the server could never build.
        let access = cors.map { CORSPolicy.Decision.on($0) } ?? .off
        let db = dbPath()
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
                config: AuthConfig(apiKeys: authKeys), browserMutation: access,
                logger: Self.log),
            rateLimitMiddleware: RateLimitMiddleware(
                provider: RateLimitProvider(
                    config: RateLimitProvider.Config(
                        globalRate: 1000, globalBurst: 2000,
                        perModelRate: 500, perModelBurst: 1000,
                        perIPRate: 500, perIPBurst: 1000, enabled: false),
                    logger: Self.log),
                logger: Self.log
            ),
            cors: access,
        )
        return (app, db)
    }

    private func preflightHeaders(origin: String) -> HTTPFields {
        var h: HTTPFields = [
            .origin: origin,
            .accessControlRequestMethod: "POST",
        ]
        if let requestHeaders = HTTPField.Name("access-control-request-headers") {
            h[requestHeaders] = "content-type, authorization, api-key"
        }
        return h
    }

    // ── §1 the decision table, exact values ────────────────────────────────────

    @Test("the knob's decision table: unset off, * open, one origin listed")
    func decisionTable() {
        #expect(CORSPolicy.resolve(nil) == .off, "no value must mean no middleware")
        #expect(CORSPolicy.resolve("") == .off)
        #expect(CORSPolicy.resolve("   ") == .off, "whitespace is not an origin")
        #expect(CORSPolicy.resolve("*") == .on(.anyOrigin))
        #expect(
            CORSPolicy.resolve(" \(Self.allowed) ") == .on(.origin(Self.allowed)),
            "a pasted value keeps its trailing newline in the shell — trim it, do not reject it")
    }

    @Test("a value naming two origins is refused, not truncated")
    func multiOriginIsRefusedWithARemedy() {
        let decision = CORSPolicy.resolve("\(Self.allowed),\(Self.other)")
        guard case .rejected(let value, let remedy) = decision else {
            Issue.record("a two-origin value resolved to \(decision) — it must be refused")
            return
        }
        #expect(value.contains(","), "the refusal quotes what was sent")
        #expect(remedy.contains("*"), "the refusal names the exit: \(remedy)")
    }

    /// The write half of the same decision, as a table rather than a story. Pure, so every
    /// row is asserted without a server: no `Origin` means a native client (measured —
    /// `URLSession` sends none), and a knob whose value was refused admits nothing, exactly
    /// as it registers no middleware.
    @Test("the write table: no Origin is a native client; off/refused admits no page")
    func mutationTable() {
        #expect(CORSPolicy.admitsMutation(origin: nil, against: .off))
        #expect(
            CORSPolicy.admitsMutation(origin: "", against: .off),
            "an empty Origin names no page, so it is not a reason to refuse")
        #expect(!CORSPolicy.admitsMutation(origin: Self.allowed, against: .off))
        #expect(
            !CORSPolicy.admitsMutation(
                origin: Self.allowed, against: .rejected(value: "a,b", remedy: "*")),
            "a refused knob must not admit the very origin it refused to parse")
        #expect(
            CORSPolicy.admitsMutation(origin: Self.allowed, against: .on(.origin(Self.allowed))))
        #expect(
            !CORSPolicy.admitsMutation(origin: Self.other, against: .on(.origin(Self.allowed))))
        #expect(CORSPolicy.admitsMutation(origin: Self.other, against: .on(.anyOrigin)))
        // A read answers the same either way and a browser cannot read a reply we do not
        // label; `OPTIONS` is the preflight, whose job is to arrive credential-free.
        #expect(
            !CORSPolicy.mutates(.get) && !CORSPolicy.mutates(.head)
                && !CORSPolicy.mutates(.options))
        #expect(
            CORSPolicy.mutates(.post) && CORSPolicy.mutates(.patch)
                && CORSPolicy.mutates(.delete),
            "PATCH/DELETE are live routes — refusing only POST would leave them open")
    }

    /// The knob is the exit, so the row a real browser client depends on: the admitted
    /// origin writes and the next one over does not — not even holding a key, because a key
    /// says WHO the caller is while `Origin` says WHAT KIND of caller it is.
    @Test("an admitted origin may write; the next origin over may not, key or no key")
    func admittedOriginMayWrite() async throws {
        let (app, db) = try await makeApp(cors: .origin(Self.allowed), authKeys: ["sk-test-1"])
        defer { try? FileManager.default.removeItem(atPath: db) }
        try await app.test(.router) { client in
            var body = ByteBufferAllocator().buffer(capacity: 32)
            body.writeString("{}")
            for (origin, mustRefuse) in [(Self.allowed, false), (Self.other, true)] {
                var h: HTTPFields = [.contentType: "application/json", .origin: origin]
                h[.authorization] = "Bearer sk-test-1"
                try await client.execute(
                    uri: "/v1/chat/completions", method: .post, headers: h, body: body
                ) { r in
                    if mustRefuse {
                        #expect(r.status == .forbidden, "\(origin) was allowed to write")
                    } else {
                        #expect(
                            r.status != .forbidden,
                            "the admitted origin was refused: \(r.status)")
                    }
                }
            }
        }
    }

    // ── §2 off is the old surface, unchanged ───────────────────────────────────

    @Test("knob unset: no CORS header anywhere, and OPTIONS is still a route miss")
    func offFaceIsUnchanged() async throws {
        let (app, db) = try await makeApp(cors: nil)
        defer { try? FileManager.default.removeItem(atPath: db) }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/chat/completions", method: .options,
                headers: self.preflightHeaders(
                    origin: Self.allowed)
            ) { r in
                #expect(
                    r.status == .notFound, "with no CORS layer nothing claims OPTIONS: \(r.status)")
                #expect(
                    r.headers[.accessControlAllowOrigin] == nil,
                    "an unset knob must not authorise anybody")
            }
            try await client.execute(
                uri: "/health", method: .get, headers: [.origin: Self.allowed]
            ) { r in
                #expect(r.status == .ok)
                #expect(r.headers[.accessControlAllowOrigin] == nil)
            }
        }
    }

    // ── §3 the allow-list, on a chain with auth ENABLED ────────────────────────

    @Test("preflight with auth on answers 204 — never 401 to a key a preflight cannot carry")
    func preflightPrecedesAuth() async throws {
        let (app, db) = try await makeApp(cors: .origin(Self.allowed), authKeys: ["sk-test-1"])
        defer { try? FileManager.default.removeItem(atPath: db) }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/chat/completions", method: .options,
                headers: self.preflightHeaders(
                    origin: Self.allowed)
            ) { r in
                #expect(r.status == .noContent, "preflight status: \(r.status)")
                #expect(
                    r.headers[.accessControlAllowOrigin] == Self.allowed,
                    "the listed origin is echoed by name, not as *")
                let methods = r.headers[.accessControlAllowMethods] ?? ""
                // PATCH/DELETE are registered routes (sampling overrides, session delete).
                // A method missing here is a route `curl` reaches and a browser cannot.
                for want in ["GET", "POST", "PATCH", "DELETE", "OPTIONS"] {
                    #expect(methods.contains(want), "allow-methods is missing \(want): \(methods)")
                }
                let headers = (r.headers[.accessControlAllowHeaders] ?? "").lowercased()
                for want in [
                    "authorization", "content-type", "accept", "origin", "api-key", "x-api-key",
                ] {
                    #expect(headers.contains(want), "allow-headers is missing \(want): \(headers)")
                }
                #expect(
                    r.headers[.vary]?.contains("Origin") == true,
                    "an origin-specific answer must say it varies, or a shared cache leaks it")
                #expect(
                    r.headers[.accessControlMaxAge] == "600",
                    "without a max age every single turn pays a second round trip first")
            }
        }
    }

    @Test("an origin that is not listed gets no authorisation, on either face")
    func unlistedOriginIsNotAuthorised() async throws {
        let (app, db) = try await makeApp(cors: .origin(Self.allowed))
        defer { try? FileManager.default.removeItem(atPath: db) }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/chat/completions", method: .options,
                headers: self.preflightHeaders(
                    origin: Self.other)
            ) { r in
                #expect(
                    r.headers[.accessControlAllowOrigin] == nil,
                    "the list is the whole point — an unlisted origin must read nothing")
            }
            try await client.execute(
                uri: "/health", method: .get, headers: [.origin: Self.other]
            ) { r in
                #expect(r.status == .ok, "the request itself is not blocked, only the reading")
                #expect(r.headers[.accessControlAllowOrigin] == nil)
            }
        }
    }

    @Test("a listed origin reads a normal response, and * opens every one")
    func responsePathCarriesTheHeader() async throws {
        let (listed, dbA) = try await makeApp(cors: .origin(Self.allowed))
        defer { try? FileManager.default.removeItem(atPath: dbA) }
        try await listed.test(.router) { client in
            try await client.execute(
                uri: "/health", method: .get, headers: [.origin: Self.allowed]
            ) { r in
                #expect(r.status == .ok)
                #expect(r.headers[.accessControlAllowOrigin] == Self.allowed)
            }
        }
        let (open, dbB) = try await makeApp(cors: .anyOrigin)
        defer { try? FileManager.default.removeItem(atPath: dbB) }
        try await open.test(.router) { client in
            try await client.execute(
                uri: "/health", method: .get, headers: [.origin: Self.other]
            ) { r in
                #expect(r.headers[.accessControlAllowOrigin] == "*")
                #expect(
                    r.headers[.vary] == nil,
                    "`*` is the same answer for every origin, so it must not be cached per-origin")
            }
        }
    }

    // ── §4 the error path stays readable ───────────────────────────────────────

    @Test("a 404 read by a browser keeps the flat envelope AND gains the CORS header")
    func errorPathKeepsItsEnvelope() async throws {
        let (app, db) = try await makeApp(cors: .origin(Self.allowed))
        defer { try? FileManager.default.removeItem(atPath: db) }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/no/such/route", method: .get, headers: [.origin: Self.allowed]
            ) { r in
                #expect(r.status == .notFound)
                #expect(
                    r.headers[.accessControlAllowOrigin] == Self.allowed,
                    "an error the page cannot read is not a contract")
                let data = Data(buffer: r.body)
                let err =
                    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"]
                    as? [String: Any] ?? [:]
                #expect(
                    err["error_code"] as? String == "route_not_found",
                    "the envelope survived the CORS wrapper: \(String(data: data, encoding: .utf8) ?? "<nil>")"
                )
            }
        }
    }
}
