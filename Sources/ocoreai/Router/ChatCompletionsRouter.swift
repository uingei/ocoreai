// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatCompletionsRouter.swift — Hummingbird route registration + middleware wiring
///
/// ### Route Matrix:
/// - ``GET /health`` → Health check + engine pool metrics
/// - ``GET /ready`` → Readiness probe (ready/busy) — public
/// - ``GET /v1/models`` → Loaded model list (OpenAI-compatible)
/// - ``GET /v1/stats`` → Inference counters/gauges (JSON) — public
/// - ``GET /metrics`` → Prometheus-compatible metrics endpoint
/// - ``POST /v1`` → Auto-route (prompt → completions, else chat)
/// - ``POST /v1/chat/completions`` → Chat completion (streaming / non-streaming)
/// - ``POST /v1/completions`` → Text completion (streaming / non-streaming)
/// - ``POST /v1/count-tokens`` → Token count utility
/// - ``GET /v1/models/:model/sampling`` → Runtime sampling config inspection
/// - ``PATCH /v1/models/:model/sampling`` → Runtime sampling config hot-swap
/// - ``DELETE /v1/models/:model/sampling`` → Reset single model sampling defaults
/// - ``DELETE /v1/models/sampling`` → Reset all model sampling defaults
///
/// ### Auth Scope:
/// - ``GET /health``, ``GET /ready``, ``GET /v1/models``, ``GET /v1/stats``, ``GET /metrics`` excluded from ``AuthMiddleware``
/// - All other endpoints require valid API key. PATCH/DELETE require admin key.
///
/// ### Metrics:
/// - ``MetricsMiddleware`` tracks per-route HTTP request counts (status/method/path)
/// - ``MetricsRegistry`` exposed via ``GET /metrics`` in Prometheus text format
/// - Inference-level metrics (tokens, TTFB, duration) recorded in ``chat_handler``

import Foundation
import HTTPTypes
import Hummingbird
import Logging

// MARK: - Response Helpers

/// Encode any `Encodable` to JSON Response with status `.ok`.
extension Response {
    fileprivate static func json(
        _ value: some Encodable,
        encoder: JSONEncoder = {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return enc
        }(),
        status: HTTPResponse.Status = .ok,
    ) throws -> Self {
        var headers: HTTPFields = [:]
        headers[.contentType] = "application/json"
        let data = try encoder.encode(value)
        return Response(
            status: status,
            headers: headers,
            body: .init { writer in
                try await writer.write(ByteBuffer(data: data))
            },
        )
    }
}

// MARK: - Custom RequestContext

/// Custom request context carrying core storage + application-specific data.
struct OCoreAIContext: RequestContext {
    var coreContext: CoreRequestContextStorage

    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
    }
}

// MARK: - Router Builder

/// Calls ``EnginePool`` actor methods directly — no ``@MainActor`` bridge needed
func buildRouter(
    enginePool: EnginePool,
    scheduler: SchedulerActor,
    metrics: MetricsRegistry,
    sessionCompressor: SessionCompressor,
    semanticSearch: SemanticSearch?,
    mcpBridge: MCPBridge,
    systemPromptBuilder: SystemPromptBuilder,
    messageBuilder: MessageBuilder,
    logger: Logger,
    authMiddleware: AuthMiddleware<OCoreAIContext>,
    rateLimitMiddleware: RateLimitMiddleware<OCoreAIContext>,
    hfToken: String? = nil,
    msToken: String? = nil,
) -> Router<OCoreAIContext> {
    let routes = Router(context: OCoreAIContext.self)
    routes.add(middleware: authMiddleware)
    routes.add(middleware: rateLimitMiddleware)

    // MARK: Health Check

    routes.get("/health") { _, _ in
        let summary = await enginePool.engineSummary()
        let response = HealthResponse(
            status: "ok",
            timestamp: Int64(Date().timeIntervalSince1970),
            engineSummary: summary,
        )
        return try Response.json(response)
    }

    /// Readiness probe (OpenAI/llm-server convention).
    ///
    /// Unlike ``GET /health`` (process liveness), ``GET /ready`` reports whether
    /// the inference path is currently free to accept work — `ready` when no
    /// session is generating, `busy` otherwise. Public (bypasses ``AuthMiddleware``).
    ///
    /// - Returns: ``ReadyResponse`` with status + current pool gauges.
    routes.get("/ready") { _, _ in
        let summary = await enginePool.engineSummary()
        let response = ReadyResponse(
            status: summary.activeSessions > 0 ? "busy" : "ready",
            timestamp: Int64(Date().timeIntervalSince1970),
            activeSessions: summary.activeSessions,
            loadedModels: summary.loadedModels,
        )
        return try Response.json(response)
    }

    // MARK: Models

    routes.get("/v1/models") { _, _ in
        let models = await enginePool.listModels()
        let modelIds = models.map { $0["id"] ?? "unknown" }
        let response = ModelListResponse(data: modelIds.map { ModelObject(id: $0) })
        return try Response.json(response)
    }

    // MARK: Inference Stats (JSON)

    /// Structured inference counters/gauges for JSON consumers (llm-server
    /// ``GET /v1/stats`` convention). Distinct from ``GET /metrics`` (Prometheus
    /// text) — same underlying ``MetricsRegistry``, different wire shape.
    ///
    /// Public (bypasses ``AuthMiddleware``) — read-only observability, no
    /// sensitive data.
    ///
    /// - Returns: ``StatsResponse`` with request/token/duration/gauge counters.
    routes.get("/v1/stats") { _, _ in
        let snap = await metrics.snapshot()
        let avgInferenceSeconds =
            snap.totalRequests > 0
            ? snap.totalInferenceSeconds / Double(snap.totalRequests)
            : 0
        let avgTTFBSeconds =
            snap.ttfbSampleCount > 0
            ? snap.totalTTFBSeconds / Double(snap.ttfbSampleCount)
            : 0
        let response = StatsResponse(
            totalRequests: snap.totalRequests,
            totalPromptTokens: snap.totalPromptTokens,
            totalGeneratedTokens: snap.totalGeneratedTokens,
            totalInferenceSeconds: snap.totalInferenceSeconds,
            avgInferenceSeconds: avgInferenceSeconds,
            ttfbSampleCount: snap.ttfbSampleCount,
            avgTTFBSeconds: avgTTFBSeconds,
            activeSessions: snap.activeSessions,
            loadedModels: snap.loadedModels,
            timestamp: Int64(Date().timeIntervalSince1970),
        )
        return try Response.json(response)
    }

    // MARK: Prometheus Metrics

    routes.get("/metrics") { _, _ in
        let body = await metrics.export()
        var headers: HTTPFields = [:]
        headers[.contentType] = "text/plain; version=0.0.4"
        return Response(
            status: .ok,
            headers: headers,
            body: .init { writer in
                if let data = body.data(using: .utf8) {
                    try await writer.write(ByteBuffer(data: data))
                }
            },
        )
    }

    // MARK: Anthropic Messages API

    routes.post("/v1/messages") { request, context in
        let anthropicRequest = try await request.decode(
            as: AnthropicMessageRequest.self, context: context,
        )
        guard !anthropicRequest.messages.isEmpty else {
            throw AppError.invalidRequest("Messages array must not be empty")
        }
        return try await anthropicMessagesHandler(
            request: anthropicRequest,
            enginePool: enginePool,
            scheduler: scheduler,
            metrics: metrics,
            sessionCompressor: sessionCompressor,
            semanticSearch: semanticSearch,
            systemPromptBuilder: systemPromptBuilder,
            logger: logger,
        )
    }

    // MARK: Authenticated Routes

    routes.post("/v1/chat/completions") { request, context in
        let chatRequest = try await request.decode(as: ChatCompletionRequest.self, context: context)
        guard !chatRequest.messages.isEmpty else {
            throw AppError.invalidRequest("Messages array must not be empty")
        }
        return try await chatCompletionsHandler(
            request: chatRequest,
            enginePool: enginePool,
            scheduler: scheduler,
            metrics: metrics,
            sessionCompressor: sessionCompressor,
            semanticSearch: semanticSearch,
            messageBuilder: messageBuilder,
            logger: logger,
        )
    }

    routes.post("/v1/completions") { request, context in
        let completionRequest = try await request.decode(
            as: CompletionRequest.self, context: context)
        guard !completionRequest.prompt.isEmpty else {
            throw AppError.invalidRequest("Prompt must be a non-empty string or array of strings")
        }
        return try await completionsHandler(
            request: completionRequest,
            enginePool: enginePool,
            scheduler: scheduler,
            metrics: metrics,
            logger: logger,
        )
    }

    /// Auto-routing endpoint (llm-server ``POST /v1`` convention).
    ///
    /// Some consumers (e.g. lm-evaluation-harness) POST directly to the base
    /// URL instead of a specific endpoint. This route inspects the request
    /// body: a top-level ``prompt`` key dispatches to ``POST /v1/completions``,
    /// otherwise to ``POST /v1/chat/completions`` — then reuses the exact same
    /// handler dispatch, so auth, guard, and wire behavior are identical to
    /// the explicit endpoints.
    routes.post("/v1") { request, _ in
        let bodyBuffer = try await request.body.collect(upTo: 10 * 1024 * 1024)
        let data = Data(bodyBuffer.readableBytesView)
        // Sniff the dispatch key (a lightweight key-existence check, not a full
        // decode) — mirrors the llm-server handleAutoRoute contract.
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if json?["prompt"] != nil {
            let completionRequest = try JSONDecoder().decode(CompletionRequest.self, from: data)
            guard !completionRequest.prompt.isEmpty else {
                throw AppError.invalidRequest(
                    "Prompt must be a non-empty string or array of strings")
            }
            return try await completionsHandler(
                request: completionRequest,
                enginePool: enginePool,
                scheduler: scheduler,
                metrics: metrics,
                logger: logger,
            )
        }
        let chatRequest = try JSONDecoder().decode(ChatCompletionRequest.self, from: data)
        guard !chatRequest.messages.isEmpty else {
            throw AppError.invalidRequest("Messages array must not be empty")
        }
        return try await chatCompletionsHandler(
            request: chatRequest,
            enginePool: enginePool,
            scheduler: scheduler,
            metrics: metrics,
            sessionCompressor: sessionCompressor,
            semanticSearch: semanticSearch,
            messageBuilder: messageBuilder,
            logger: logger,
        )
    }

    routes.post("/v1/count-tokens") { request, context in
        let countRequest = try await request.decode(as: CountTokensRequest.self, context: context)
        guard !countRequest.prompt.isEmpty else {
            throw AppError.invalidRequest("Prompt must not be empty")
        }
        let countResponse = try await countTokensHandler(
            request: countRequest,
            enginePool: enginePool,
        )
        return try Response.json(countResponse)
    }

    // MARK: - LLM Lifecycle — Train + Evaluate

    routes.post("/v1/models/train") { request, context in
        let trainRequest = try await request.decode(as: TrainRequest.self, context: context)
        guard !trainRequest.model.isEmpty else {
            throw AppError.invalidRequest("model must not be empty")
        }
        return try await trainHandler(
            request: trainRequest,
            enginePool: enginePool,
            logger: logger,
        )
    }

    routes.post("/v1/models/evaluate") { request, context in
        let evalRequest = try await request.decode(as: EvalRequest.self, context: context)
        guard !evalRequest.model.isEmpty else {
            throw AppError.invalidRequest("model must not be empty")
        }
        return try await evaluateHandler(
            request: evalRequest,
            enginePool: enginePool,
            logger: logger,
        )
    }

    // MARK: Runtime Parameter Hot-Swap API

    routes.get("/v1/models/:model/sampling") { _, context in
        let modelId = try context.parameters.require("model")
        let config = await enginePool.getSamplingConfig(modelId: modelId)
        let response = ModelSamplingResponse(config: config)
        return try Response.json(response)
    }

    routes.patch("/v1/models/:model/sampling") { request, context in
        let modelId = try context.parameters.require("model")
        let patch = try await request.decode(as: ModelSamplingPatch.self, context: context)
        await enginePool.updateSamplingConfig(modelId: modelId, config: patch.toConfig())
        let updated = await enginePool.getSamplingConfig(modelId: modelId)
        let response = ModelSamplingResponse(config: updated)
        return try Response.json(response)
    }

    routes.delete("/v1/models/:model/sampling") { _, context in
        let modelId = try context.parameters.require("model")
        await enginePool.resetSamplingConfig(modelId: modelId)
        let config = await enginePool.getSamplingConfig(modelId: modelId)
        let response = ModelSamplingResponse(config: config)
        return try Response.json(response)
    }

    routes.delete("/v1/models/sampling") { _, _ in
        await enginePool.resetAllSamplingConfig()
        let response = ModelSamplingResponse(config: .default)
        return try Response.json(response)
    }

    // MARK: Model Download

    routes.post("/v1/models/download") { request, context in
        let downloadRequest = try await request.decode(
            as: DownloadModelRequest.self, context: context,
        )
        return try await modelDownloadHandler(
            request: downloadRequest,
            hfToken: hfToken,
            msToken: msToken,
            logger: logger,
        )
    }

    // MARK: Multimodal (camera / microphone / TTS)

    routes.post("/v1/multimodal/capture") { request, context in
        let captureRequest = try await request.decode(
            as: CaptureRequest.self, context: context,
        )
        return try await multimodalCaptureHandler(
            request: captureRequest,
            logger: logger,
        )
    }

    routes.post("/v1/multimodal/speak") { request, context in
        let speakRequest = try await request.decode(
            as: SpeakRequest.self, context: context,
        )
        return try await multimodalSpeakHandler(
            request: speakRequest,
            logger: logger,
        )
    }

    routes.post("/v1/multimodal/status") { request, context in
        let statusRequest: StatusRequest? = try? await request.decode(
            as: StatusRequest.self, context: context,
        )
        return try await multimodalStatusHandler(
            request: statusRequest,
            logger: logger,
        )
    }

    // MARK: MCP JSON-RPC Endpoint

    routes.post("/mcp") { request, _ in
        let bodyBuffer = try await request.body.collect(upTo: 64 * 1024)
        guard let message = String(data: Data(bodyBuffer.readableBytesView), encoding: .utf8) else {
            return Response(status: .badRequest)
        }
        guard let response = await mcpBridge.handleLine(message) else {
            return Response(status: .noContent)
        }
        let responseBuffer = ByteBuffer(data: Data(response.utf8))
        var headers: HTTPFields = [:]
        headers[.contentType] = "application/json"
        return Response(
            status: .ok,
            headers: headers,
            body: .init(contentsOf: [responseBuffer]),
        )
    }

    // MARK: Session Management API

    routes.get("/sessions") { request, _ in
        let limit = Int(request.uri.queryParameters["limit"] ?? "") ?? 100
        let modelFilter = request.uri.queryParameters["model"].map(String.init)
        do {
            let sessions = try await sessionCompressor.listSessions(
                modelId: modelFilter, limit: limit,
            )
            return try Response.json(sessions)
        } catch {
            throw AppError.inferenceFailed("Failed to list sessions: \(error)")
        }
    }

    routes.delete("/sessions/:id") { _, context in
        let idParam = try context.parameters.require("id")
        guard let id = Int64(idParam) else {
            throw AppError.invalidRequest("Invalid session ID: \(idParam)")
        }
        do {
            try await sessionCompressor.deleteSession(id)
            return try Response.json(SessionDeleteResponse(deleted: true, id: id))
        } catch {
            throw AppError.inferenceFailed("Failed to delete session: \(error)")
        }
    }

    routes.get("/sessions/:id/memory") { _, context in
        let idParam = try context.parameters.require("id")
        guard let id = Int64(idParam) else {
            throw AppError.invalidRequest("Invalid session ID: \(idParam)")
        }
        do {
            let messages = try await sessionCompressor.hotWindow(id)
            return try Response.json(MemoryResponse(session_id: id, messages: messages))
        } catch {
            throw AppError.inferenceFailed("Failed to load memory: \(error)")
        }
    }

    routes.get("/sessions/search") { request, _ in
        guard let q = request.uri.queryParameters["q"] else {
            throw AppError.invalidRequest("Missing 'q' query parameter")
        }
        let limit = Int(request.uri.queryParameters["limit"] ?? "") ?? 20
        let sessionId = request.uri.queryParameters["session"].flatMap { Int64($0) }
        do {
            let results = try await sessionCompressor.searchFTS5(
                query: String(q), sessionId: sessionId, limit: limit,
            )
            return try Response.json(results)
        } catch {
            throw AppError.inferenceFailed("Search failed: \(error)")
        }
    }

    // MARK: Skills API

    routes.get("/skills") { _, _ in
        let skillsList = await systemPromptBuilder.listSkills()
        return try Response.json(skillsList)
    }

    // MARK: Metrics

    let metricsMiddleware = MetricsTrackingMiddleware<OCoreAIContext>(metrics: metrics)
    routes.add(middleware: metricsMiddleware)

    return routes
}

// MARK: - Metrics Tracking Middleware

struct MetricsTrackingMiddleware<Context: RequestContext>: RouterMiddleware {
    private let metrics: MetricsRegistry

    init(metrics: MetricsRegistry) {
        self.metrics = metrics
    }

    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response,
    ) async throws -> Response {
        let response = try await next(request, context)
        let status = response.status.code
        let path = String(request.uri.path.prefix { $0 != "?" })
        await metrics.incrementHTTPRequest(
            method: request.method.rawValue,
            path: path,
            status: status,
        )
        return response
    }
}

// MARK: - Health Response

struct HealthResponse: Codable {
    let status: String
    let timestamp: Int64
    let engineSummary: EngineSummary
}

/// ``GET /ready`` response — readiness state of the inference path.
///
/// `ready` when no session is generating (work can be accepted);
/// `busy` when at least one session is mid-generation.
struct ReadyResponse: Codable {
    let status: String
    let timestamp: Int64
    let activeSessions: Int
    let loadedModels: Int
}

/// ``GET /v1/stats`` response — structured inference counters/gauges.
///
/// JSON twin of ``GET /metrics`` (Prometheus text). Field names follow the
/// llm-server ``GET /v1/stats`` convention; values come from
/// ``MetricsRegistry`` (same source as Prometheus, different wire shape).
struct StatsResponse: Codable {
    let totalRequests: UInt64
    let totalPromptTokens: UInt64
    let totalGeneratedTokens: UInt64
    let totalInferenceSeconds: Double
    let avgInferenceSeconds: Double
    let ttfbSampleCount: UInt64
    let avgTTFBSeconds: Double
    let activeSessions: Int
    let loadedModels: Int
    let timestamp: Int64
}

struct EngineSummary: Codable {
    let loadedModels: Int
    let activeSessions: Int
    let modelIds: [String]
    let gpuCacheGB: Double
    let specializedModels: Int

    init(
        loadedModels: Int, activeSessions: Int, modelIds: [String] = [], gpuCacheGB: Double,
        specializedModels: Int = 0
    ) {
        self.loadedModels = loadedModels
        self.activeSessions = activeSessions
        self.modelIds = modelIds
        self.gpuCacheGB = gpuCacheGB
        self.specializedModels = specializedModels
    }
}

// MARK: - Session API Response Types

struct MemoryResponse: Codable {
    let session_id: Int64
    let messages: [MessageModel]
}

struct SessionDeleteResponse: Codable {
    let deleted: Bool
    let id: Int64
}

// MARK: - Model List Response (OpenAI-Compatible)

struct ModelListResponse: Codable {
    var object: String = "list"
    var data: [ModelObject]
}

struct ModelObject: Codable {
    var id: String
    var object: String = "model"
    var ownedBy: String = "ocoreai"
}

// MARK: - Count Tokens Request/Response

struct CountTokensRequest: Codable {
    let model: String
    let prompt: String
}

struct CountTokensResponse: Codable {
    let model: String
    let tokenCount: Int

    enum CodingKeys: String, CodingKey {
        case model
        case tokenCount = "prompt_tokens"
    }
}

// MARK: - Count Tokens Handler

func countTokensHandler(
    request: CountTokensRequest,
    enginePool: EnginePool,
) async throws -> CountTokensResponse {
    let handle = try await enginePool.acquire(model: request.model)
    defer { Task { await handle.release() } }

    let count = try await handle.countTokens(text: request.prompt)
    return CountTokensResponse(model: request.model, tokenCount: count)
}
