// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// One refusal, three faces: the guard that kept a generation request naming a listed
/// embedder from loading a non-generating container and hanging lived on the OpenAI-chat
/// face alone; `/v1/messages` and `/v1/completions` reach the same pool with the same id.
/// The decision now has one home (`EmbeddingService.generationRefusal`); these gate the
/// home's exact bytes on each face, so a face that drops the call goes red here.

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing

@testable import ocoreai

@Suite("Embedder refusal — the one home")
struct EmbedderRefusalHomeTests {
    private static let embedder = "mlx-community/LFM2.5-Embedding-350M-4bit"

    @Test(
        "a listed embedder is refused verbatim, naming the embed route and the caller's own endpoint"
    )
    func exactMessage() {
        let refusal = EmbeddingService.generationRefusal(
            modelId: Self.embedder, usedEndpoint: "/v1/messages")
        guard case .invalidRequest(let message)? = refusal else {
            Issue.record("a listed embedder must be refused, got \(String(describing: refusal))")
            return
        }
        #expect(
            message
                == "'\(Self.embedder)' is an embedding model — it has no generation head. "
                + "Call POST /v1/embeddings with {\"input\": \"...\"} instead of /v1/messages."
        )
    }

    @Test("an id the list does not name asks for nothing")
    func nonEmbedderPasses() {
        #expect(
            EmbeddingService.generationRefusal(
                modelId: "mlx-community/Some-Chat-Checkpoint-4bit", usedEndpoint: "/v1/messages")
                == nil)
    }
}

@Suite("Embedder refusal — every generation face, in its own envelope", .serialized)
struct EmbedderRefusalPerFaceTests {
    private static let embedder = "mlx-community/LFM2.5-Embedding-350M-4bit"

    // MARK: - Test app (same construction as CompletionsE2ETests; no inference is reached)

    private static func uuidPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "embedface_\(UUID().uuidString.prefix(8)).sqlite"
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
                logger: Logger(label: "test.embedface")
            ),
            logger: Logger(label: "test.embedface")
        )
    }

    private static func makeTestApp(_ dbPath1: String, _ dbPath2: String) async throws
        -> some ApplicationProtocol
    {
        var poolConfig = EnginePoolConfig.default
        poolConfig.defaultModelId = ""
        let enginePool = EnginePool(
            config: poolConfig,
            logger: Logger(label: "test.embedface"),
            tokenizerManager: TokenizerManager()
        )
        let store = SQLiteStore(path: dbPath1)
        try await store.open()
        let compressor = SessionCompressor(store: store, fts: FTS5Search(store: store))
        let mbStore = SQLiteStore(path: dbPath2)
        try await mbStore.open()
        let mb = MessageBuilder(
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            sessionCompressor: SessionCompressor(store: mbStore, fts: FTS5Search(store: mbStore)),
            complexityAnalyzer: ComplexityAnalyzer(),
            thinkingBudget: ThinkingBudget()
        )
        let scheduler = SchedulerActor(
            maxQueueSize: 4, memoryTracker: nil, log: Logger(label: "test.embedface"))
        let mcpBridge = MCPBridge(
            toolRegistry: ToolRegistry(log: Logger(label: "test.embedface")),
            transport: MCPStdioTransport(log: Logger(label: "test.embedface"))
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
            logger: Logger(label: "test.embedface"),
            authMiddleware: AuthMiddleware<OCoreAIContext>(
                config: .default, logger: Logger(label: "test.embedface")),
            rateLimitMiddleware: makeRateLimitMiddleware(),
            hfToken: nil,
            msToken: nil
        )
    }

    private static func jsonBody(_ json: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: json.utf8.count)
        buffer.writeString(json)
        return buffer
    }

    private static func responseBody(from response: TestResponse) -> String {
        response.body.getString(at: 0, length: response.body.readableBytes) ?? ""
    }

    private static func jsonObject(_ body: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
    }

    @Test(
        "all three faces 400 in their own envelope before the scheduler, naming the embed route, the embedder, and the endpoint the caller used"
    )
    func allThreeFacesRefuse() async throws {
        let db1 = Self.uuidPath()
        let db2 = Self.uuidPath()
        defer { Self.cleanupDBs(db1, db2) }
        let embedder = Self.embedder
        // (face, uri, body, anthropic envelope?) — every body is refused before the engine
        // is asked for anything, so the scripted lane is not needed and no model loads.
        let faces: [(String, String, String, Bool)] = [
            (
                "chat/completions", "/v1/chat/completions",
                #"{"model":"\#(embedder)","messages":[{"role":"user","content":"hi"}],"max_tokens":8}"#,
                false
            ),
            (
                "messages", "/v1/messages",
                #"{"model":"\#(embedder)","messages":[{"role":"user","content":"hi"}],"max_tokens":8}"#,
                true
            ),
            (
                "completions", "/v1/completions",
                #"{"model":"\#(embedder)","prompt":"hi","max_tokens":8}"#,
                false
            ),
        ]
        let judged: Int = try await Self.makeTestApp(db1, db2).test(.router) { client in
            var judged = 0
            for (face, uri, body, isAnthropic) in faces {
                var headers: HTTPFields = [:]
                headers[.contentType] = "application/json"
                let response = try await client.execute(
                    uri: uri, method: .post, headers: headers, body: Self.jsonBody(body))
                #expect(
                    response.status == .badRequest,
                    "\(face): an embedder request must be refused with 400, got \(response.status)")
                let doc = try #require(
                    Self.responseBody(from: response), "\(face): refusal body")
                let json = try #require(
                    Self.jsonObject(doc), "\(face): refusal body must be JSON: \(doc.prefix(200))")
                let error = try #require(
                    json["error"] as? [String: Any],
                    "\(face): refusal must carry an error object: \(doc.prefix(200))")
                let message = error["message"] as? String ?? ""
                #expect(
                    message.contains("is an embedding model"),
                    "\(face): the refusal must name the cause: \(message)")
                #expect(
                    message.contains("POST /v1/embeddings"),
                    "\(face): the refusal must name the route that does answer: \(message)")
                #expect(
                    message.contains(uri),
                    "\(face): the refusal must name the endpoint the caller used: \(message)")
                if isAnthropic {
                    // The face decides the envelope (probe 50's measured shapes): top-level
                    // {"type":"error"}, Anthropic's own error.type, and no OpenAI `code`.
                    #expect(
                        json["type"] as? String == "error",
                        "\(face): the refusal must wear Anthropic's envelope: \(doc.prefix(200))")
                    #expect(
                        error["type"] as? String == "invalid_request_error",
                        "\(face): SDKs dispatch on error.type: \(doc.prefix(200))")
                    #expect(
                        error["code"] == nil,
                        "\(face): Anthropic's object carries no OpenAI `code`: \(doc.prefix(200))")
                } else {
                    #expect(
                        json["type"] as? String != "error",
                        "\(face): the refusal must not wear the other face's envelope: \(doc.prefix(200))"
                    )
                }
                judged += 1
            }
            return judged
        }
        // The scan judges its own subjects: 3 faces or the leg is vacuous, not smaller.
        #expect(judged == 3, "the leg judged \(judged) of 3 faces")
    }
}

@Suite("Embedder refusal wiring — one home, three callers, no second copy of the sentence")
struct EmbedderRefusalWiringTests {
    private static func source(_ relative: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 6 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw MissingRepoFile(path: "\(dir.path)/\(relative)")
    }

    struct MissingRepoFile: Error, CustomStringConvertible {
        let path: String
        var description: String { "no repo file at \(path) (walked up from \(#filePath))" }
    }

    private static func count(_ pattern: String, in text: String) throws -> Int {
        try NSRegularExpression(pattern: pattern)
            .matches(in: text, range: NSRange(text.startIndex..., in: text)).count
    }

    @Test("each generation face calls the home exactly once; the sentence has one home")
    func facesAskTheHome() throws {
        let faces: [(file: String, anchor: String)] = [
            ("Sources/ocoreai/Handlers/ChatHandler.swift", "func chatCompletionsHandler("),
            (
                "Sources/ocoreai/Handlers/AnthropicMessagesHandler.swift",
                "func anthropicMessagesHandler("
            ),
            ("Sources/ocoreai/Handlers/CompletionsHandler.swift", "func completionsHandler("),
        ]
        for face in faces {
            let text = try Self.source(face.file)
            // Floor: the face exists before anything counts it.
            #expect(
                text.contains(face.anchor),
                "\(face.file): the anchor is gone — this scan would pass vacuously")
            #expect(
                try Self.count(#"EmbeddingService\.generationRefusal\("#, in: text) == 1,
                "\(face.file): the capability gate must ask the home exactly once")
            // The refusal sentence must not be re-typed at any face.
            #expect(
                try Self.count("is an embedding model", in: text) == 0,
                "\(face.file): the sentence has one home in the ledger")
        }
        let bridge = try Self.source("Sources/ocoreai/Engine/MLXBridge.swift")
        #expect(
            try Self.count(#"static func generationRefusal\("#, in: bridge) == 1,
            "the home is declared exactly once")
        #expect(
            try Self.count("is an embedding model", in: bridge) == 1,
            "the refusal sentence lives in the home and nowhere else")
    }
}
