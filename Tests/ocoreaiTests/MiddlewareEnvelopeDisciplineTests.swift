// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Why a gate here: `AppError.response` decides which envelope a refusal wears by the path the
/// request arrived on (3d0e542), but that decision only holds for a refusal that *reaches* it.
/// Three families kept hand-built bodies beside it — the rate limiter's 429, the trie-miss 404,
/// and the safety refusals (`content_policy_violation`, `prompt_injection`), the last two built at
/// five and three sites respectively, two of them inside `POST /v1/messages` itself. So a client
/// speaking Anthropic's protocol to `/v1/messages` got OpenAI's envelope from exactly the layers
/// furthest from the model: a capacity refusal, a wrong URL, a blocked prompt. vllm states why the
/// string inside that envelope is not ours to invent — "Anthropic SDKs dispatch on `error.type`,
/// which must use Anthropic's own vocabulary" (`vllm/entrypoints/anthropic/protocol.py:33-34`).
///
/// The claim this suite holds is therefore about the bytes, at the two places they can be read:
/// the same refusal, on both faces, each in its own envelope, with the refusal's own fact
/// (`error_code`, `details`, `categories`, the measured wait) surviving *both* shapes — the fact
/// is the reason the client is reading the body at all.
///
/// What is proven here is the render and the wire; what is proven in `ContentGuardTests` is the
/// guard's verdict carrying into the typed refusal. The guard itself is installed only by real
/// engine startup (`App.swift:584`) behind a process-global, so the live end-to-end block on both
/// faces is `scripts/probes/50-refusal-envelope-per-face.sh`, not a suite — a test that reached
/// for it would be mutating a process-global to satisfy an assertion (see
/// `ProcessGlobalLeaseDisciplineTests`).

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing

@testable import ocoreai

@Suite("refusals — the layers beside the model wear the envelope the caller parses")
struct MiddlewareEnvelopeDisciplineTests {

    private static let log = Logger(label: "test.refusal.envelope")

    /// Rate knobs that make the refusal a fact rather than a race.
    ///
    /// The refill rate is 0.001 tokens/s, not a number that "looks realistic", because this suite
    /// runs beside ~618 others on one cooperative pool: the first version drained a burst of 1 at
    /// 5 tokens/s and passed in 0.12 s alone, then went red inside `make test` — the stall between
    /// the drain and the target request let one token back, and the request was allowed. That is the
    /// same mechanism `docs/agent/open-items.md` records as the loaded-host cast (wall-clock bounds
    /// betting on the one cooperative pool every suite shares), so the premise here no longer depends
    /// on wall-clock at all: two tokens, a thousand seconds to refill one.
    private static let oneShotRateLimit = RateLimitProvider.Config(
        globalRate: 0.001, globalBurst: 2,
        perModelRate: 0.001, perModelBurst: 2,
        perIPRate: 0.001, perIPBurst: 2,
        enabled: true
    )

    /// A pool with no default model: every leg here refuses before the engine is needed, so this
    /// suite holds no Metal and no weights (the reason it belongs to the sandbox tier).
    private static func makeApp(
        rateConfig: RateLimitProvider.Config? = nil
    ) async throws -> (some ApplicationProtocol, String) {
        let dbPath = NSTemporaryDirectory() + "ocoreai-refusal-\(UUID().uuidString).sqlite"
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
        let app = try await buildApplication(
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
                    config: rateConfig ?? RateLimitProvider.Config(), logger: log),
                logger: log),
            hfToken: nil,
            msToken: nil
        )
        return (app, dbPath)
    }

    private static func json(_ response: TestResponse) -> [String: Any] {
        let text = response.body.getString(at: 0, length: response.body.readableBytes) ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private static func errorObject(_ body: [String: Any]) -> [String: Any] {
        body["error"] as? [String: Any] ?? [:]
    }

    /// A body with an out-of-range `temperature` — the request never needs to be answered, it only
    /// has to reach the rate limiter, so the subject stays the refusal.
    private static let body =
        #"{"model":"m","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}"#

    // MARK: - 429: the token bucket refuses before routing, on either face

    /// One capacity refusal, two envelopes. The OpenAI face keeps `code` (its error object has
    /// one); the Anthropic face must not (its object is exactly `{type,message}` and the status is
    /// already the status line). Both must carry the wait the bucket measured — in the body *and*
    /// in `Retry-After`, off one number, because a 429 that says nothing about when to come back
    /// trains the client to hammer the box that just said no.
    @Test("429 — Anthropic's shape on /v1/messages, OpenAI's elsewhere, one wait either way")
    func rateLimitRefusalOnBothFaces() async throws {
        // Anthropic face.
        let (anthropicApp, anthropicDB) = try await Self.makeApp(rateConfig: Self.oneShotRateLimit)
        defer { try? FileManager.default.removeItem(atPath: anthropicDB) }
        try await anthropicApp.test(.router) { client in
            // Drain the burst, asserting each drain request was admitted: the premise that the
            // bucket started full is checked, not assumed, so a later 429 cannot be a config slip.
            for _ in 0 ..< 2 {
                try await client.execute(uri: "/health", method: .get) { r in
                    #expect(
                        r.status == .ok,
                        "the drain request itself was refused — the bucket never started full")
                }
            }
            try await client.execute(
                uri: "/v1/messages", method: .post,
                body: ByteBuffer(string: Self.body)
            ) { r in
                #expect(r.status == .tooManyRequests, "expected 429, got \(r.status)")
                let body = Self.json(r)
                #expect(
                    body["type"] as? String == "error",
                    "not Anthropic's envelope: \(body)")
                let err = Self.errorObject(body)
                #expect(err["type"] as? String == "rate_limit_error")
                #expect(err["code"] == nil, "Anthropic's error object is {type,message}: \(err)")
                #expect(err["error_code"] as? String == "rate_limited")
                let wait = err["retry_after_seconds"] as? Int
                #expect(wait != nil, "the measured wait did not reach the body: \(err)")
                let header = r.headers[.retryAfter]
                #expect(
                    header == wait.map { "\($0)" },
                    """
                    Retry-After \(header ?? "nil") and retry_after_seconds \
                    \(String(describing: wait)) are not one number
                    """)
                if let limitName = HTTPField.Name("X-RateLimit-Limit") {
                    #expect(
                        r.headers[limitName] == nil,
                        "a header named for a number is carrying the word 'exceeded' again")
                }
            }
        }

        // OpenAI face.
        let (openAIApp, openAIDB) = try await Self.makeApp(rateConfig: Self.oneShotRateLimit)
        defer { try? FileManager.default.removeItem(atPath: openAIDB) }
        try await openAIApp.test(.router) { client in
            for _ in 0 ..< 2 {
                try await client.execute(uri: "/health", method: .get) { r in
                    #expect(
                        r.status == .ok,
                        "the drain request itself was refused — the bucket never started full")
                }
            }
            try await client.execute(
                uri: "/v1/chat/completions", method: .post,
                body: ByteBuffer(string: Self.body)
            ) { r in
                #expect(r.status == .tooManyRequests, "expected 429, got \(r.status)")
                let body = Self.json(r)
                #expect(
                    body["type"] == nil,
                    "the Anthropic discriminator leaked onto the OpenAI face: \(body)")
                let err = Self.errorObject(body)
                #expect(err["type"] as? String == "rate_limit_error")
                #expect(err["code"] as? Int == 429, "the OpenAI face keeps its `code`: \(err)")
                #expect(err["error_code"] as? String == "rate_limited")
                let wait = err["retry_after_seconds"] as? Int
                #expect(r.headers[.retryAfter] == wait.map { "\($0)" })
            }
        }
    }

    // MARK: - 404: the trie miss is a refusal like any other

    /// A miss under `/v1/messages` must read as Anthropic's `not_found_error`, and a miss anywhere
    /// else as OpenAI's — while `error_code: route_not_found` and the `details` pair survive both,
    /// because they are the part the client repairs against. The middleware used to own a literal
    /// copy of this body, which is how the same 404 said `app_error` while a handler-thrown 404
    /// said `not_found_error`.
    @Test("404 — the trie miss answers in the called face's envelope and keeps its details")
    func routeMissOnBothFaces() async throws {
        let (app, db) = try await Self.makeApp()
        defer { try? FileManager.default.removeItem(atPath: db) }
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/messages/no-such-subroute", method: .get) { r in
                #expect(r.status == .notFound)
                let body = Self.json(r)
                #expect(body["type"] as? String == "error", "not Anthropic's envelope: \(body)")
                let err = Self.errorObject(body)
                #expect(err["type"] as? String == "not_found_error")
                #expect(err["code"] == nil, "Anthropic's object carries no `code`: \(err)")
                #expect(err["error_code"] as? String == "route_not_found")
                let details = err["details"] as? [String: Any] ?? [:]
                #expect(details["method"] as? String == "GET")
                #expect(
                    details["path"] as? String == "/v1/messages/no-such-subroute",
                    "the miss must name itself: \(details)")
            }
            try await client.execute(uri: "/no/such/route", method: .get) { r in
                #expect(r.status == .notFound)
                let body = Self.json(r)
                #expect(body["type"] == nil)
                let err = Self.errorObject(body)
                #expect(err["type"] as? String == "not_found_error")
                #expect(err["code"] as? Int == 404)
                #expect(err["error_code"] as? String == "route_not_found")
                let details = err["details"] as? [String: Any] ?? [:]
                #expect(details["path"] as? String == "/no/such/route")
            }
        }
    }

    // MARK: - The envelope has one home

    /// A scan, so it asserts its own premises: it finds its root by searching (a fixed number of
    /// `deletingLastPathComponent()` hops rots the day the tree moves), floors how many files it
    /// actually read, and requires the positive control — the one home — to match its own pattern
    /// before it believes a zero anywhere else. Without that floor this test would pass on a silent
    /// directory walk and on a build where the renderer changed its spelling.
    @Test("one file builds the error envelope; the hand-built bodies stay gone")
    func envelopeHasOneHome() throws {
        let root = try Self.repoRoot()
        let sources = root.appendingPathComponent("Sources/ocoreai")
        let pattern = "dictionary: [\"error\":"

        var read = 0
        var homes: [String] = []
        let files = Self.swiftFiles(in: sources)
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            read += 1
            if text.contains(pattern) {
                homes.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }

        // Premise floor: the walk found real files, and the pattern is real.
        #expect(read > 100, "the scan read \(read) files — it is not walking Sources/ocoreai")
        #expect(
            homes.contains("Sources/ocoreai/Models/OpenAIModels.swift"),
            """
            the positive control failed: AppError.response no longer matches the pattern, so a \
            zero elsewhere would mean nothing (homes: \(homes))
            """)
        #expect(
            homes == ["Sources/ocoreai/Models/OpenAIModels.swift"],
            "the envelope gained a second home: \(homes.sorted())")
    }

    // MARK: - Repo access

    /// Walk up until the marker file is found — the pattern in `OpenAPIContractTests`, for the
    /// reason recorded there: a fixed hop count from `#filePath` is a second truth about the tree.
    private static func repoRoot() throws -> URL {
        let probe = "Sources/ocoreai/Models/OpenAIModels.swift"
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(probe).path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw NotFound(path: "\(dir.path)/\(probe)")
    }

    private struct NotFound: Error, CustomStringConvertible {
        let path: String
        var description: String { "no repo root above \(path)" }
    }

    private static func swiftFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard
            let walker = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
