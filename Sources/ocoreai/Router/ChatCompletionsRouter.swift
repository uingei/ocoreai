// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatCompletionsRouter.swift — Hummingbird route registration + middleware wiring
///
/// ### Route Matrix:
/// - ``GET /health`` → Health check + engine pool metrics
/// - ``GET /v1/models`` → Loaded model list (OpenAI-compatible)
/// - ``GET /metrics`` → Prometheus-compatible metrics endpoint
/// - ``POST /v1/chat/completions`` → Chat completion (streaming / non-streaming)
/// - ``POST /v1/count-tokens`` → Token count utility
/// - ``GET /v1/models/:model/sampling`` → Runtime sampling config inspection
/// - ``PATCH /v1/models/:model/sampling`` → Runtime sampling config hot-swap
/// - ``DELETE /v1/models/:model/sampling`` → Reset single model sampling defaults
/// - ``DELETE /v1/models/sampling`` → Reset all model sampling defaults
///
/// ### Auth Scope:
/// - ``GET /health``, ``GET /v1/models``, ``GET /metrics`` excluded from ``AuthMiddleware``
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

// MARK: - Custom RequestContext

/// Custom request context carrying core storage + application-specific data.
struct OCoreAIContext: RequestContext {
    var coreContext: CoreRequestContextStorage

    init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
    }
}

// MARK: - Router Builder

///
/// Calls ``EnginePool`` actor methods directly — no ``@MainActor`` bridge needed
/// because Hummingbird 2.0 routes use ``async/await`` natively.
///
/// - Parameters:
///   - enginePool: Engine pool actor
///   - metrics: Shared metrics registry
///   - logger: Observability logger
///   - authMiddleware: Auth middleware instance
///   - rateLimitMiddleware: Rate limit middleware instance
/// - Returns: ``Router`` conforming to ``HTTPResponderBuilder``
func buildRouter(
    enginePool: EnginePool,
    metrics: MetricsRegistry,
    logger: Logger,
    authMiddleware: AuthMiddleware<OCoreAIContext>,
    rateLimitMiddleware: RateLimitMiddleware<OCoreAIContext>,
    hfToken: String? = nil,
    msToken: String? = nil
) -> Router<OCoreAIContext> {
    let routes = Router(context: OCoreAIContext.self)
    // Add middleware to router
    routes.add(middleware: authMiddleware)
    routes.add(middleware: rateLimitMiddleware)

    // MARK: Health Check

    /// GET /health — returns engine pool summary with status + timestamp
    routes.get("/health") { _, context in
        let summary = await enginePool.engineSummary()
        let response = HealthResponse(
            status: "ok",
            timestamp: Int64(Date().timeIntervalSince1970),
            engineSummary: summary
        )
        var h: HTTPFields = [:]
        h[HTTPField.Name("Content-Type")!] = "application/json"
        let data = try JSONEncoder().encode(response)
        return Response(status: .ok, headers: h, body: .init { writer in
            try await writer.write(ByteBuffer(data: data))
        })
    }

    // MARK: Models

    /// GET /v1/models — returns loaded model list (OpenAI-compatible format)
    routes.get("/v1/models") { _, context in
        let models = await enginePool.listModels()
        let modelIds = models.map { $0["id"] ?? "unknown" }
        let response = ModelListResponse(data: modelIds.map { ModelObject(id: $0) })
        var h: HTTPFields = [:]
        h[HTTPField.Name("Content-Type")!] = "application/json"
        let data = try JSONEncoder().encode(response)
        return Response(status: .ok, headers: h, body: .init { writer in
            try await writer.write(ByteBuffer(data: data))
        })
    }

    // MARK: Prometheus Metrics

    /// GET /metrics — Prometheus-compatible metrics exporter
    routes.get("/metrics") { request, context in
        let body = await metrics.export()
        var headers: HTTPFields = [:]
        headers[.contentType] = "text/plain; version=0.0.4"
        return Response(
            status: .ok,
            headers: headers,
            body: .init { writer in
                if let data = body.data(using: .utf8) { try await writer.write(ByteBuffer(data: data)) }
            }
        )
    }

    // MARK: Anthropic Messages API

    /// POST /v1/messages — Anthropic-compatible messages endpoint
    /// (Converts to internal pipeline, returns Anthropic response envelope)
    routes.post("/v1/messages") { request, context in
        let anthropicRequest = try await request.decode(
            as: AnthropicMessageRequest.self, context: context
        )
        guard !anthropicRequest.messages.isEmpty else {
            throw AppError.invalidRequest("Messages array must not be empty")
        }
        return try await anthropicMessagesHandler(
            request: anthropicRequest,
            enginePool: enginePool,
            metrics: metrics,
            logger: logger
        )
    }

    // MARK: Authenticated Routes (with metrics collection)

    /// POST /v1/chat/completions — orchestrates the full inference pipeline:
    /// tokenization → inference → detokenization → SSE or non-stream response
    routes.post("/v1/chat/completions") { request, context in
        let chatRequest = try await request.decode(as: ChatCompletionRequest.self, context: context)
        guard !chatRequest.messages.isEmpty else {
            throw AppError.invalidRequest("Messages array must not be empty")
        }
        return try await chatCompletionsHandler(
            request: chatRequest,
            enginePool: enginePool,
            metrics: metrics,
            logger: logger
        )
    }

    /// POST /v1/count-tokens — token count utility endpoint
    routes.post("/v1/count-tokens") { request, context in
        let countRequest = try await request.decode(as: CountTokensRequest.self, context: context)
        guard !countRequest.prompt.isEmpty else {
            throw AppError.invalidRequest("Prompt must not be empty")
        }
        let countResponse = try await countTokensHandler(
            request: countRequest,
            enginePool: enginePool
        )
        var h: HTTPFields = [:]
        h[HTTPField.Name("Content-Type")!] = "application/json"
        let data = try JSONEncoder().encode(countResponse)
        return Response(status: .ok, headers: h, body: .init { writer in
            try await writer.write(ByteBuffer(data: data))
        })
    }

    // MARK: Runtime Parameter Hot-Swap API

    /// GET /v1/models/:model/sampling — inspect runtime sampling defaults
    routes.get("/v1/models/:model/sampling") { request, context in
        let modelId = try context.parameters.require("model")
        let config = await enginePool.getSamplingConfig(modelId: modelId)
        let response = ModelSamplingResponse(config: config)
        var h: HTTPFields = [:]
        h[HTTPField.Name("Content-Type")!] = "application/json"
        let data = try JSONEncoder().encode(response)
        return Response(status: .ok, headers: h, body: .init { writer in
            try await writer.write(ByteBuffer(data: data))
        })
    }

    /// PATCH /v1/models/:model/sampling — hot-swap runtime sampling defaults
    routes.patch("/v1/models/:model/sampling") { request, context in
        let modelId = try context.parameters.require("model")
        let patch = try await request.decode(as: ModelSamplingPatch.self, context: context)
        await enginePool.updateSamplingConfig(modelId: modelId, config: patch.toConfig())
        let updated = await enginePool.getSamplingConfig(modelId: modelId)
        let response = ModelSamplingResponse(config: updated)
        var h: HTTPFields = [:]
        h[HTTPField.Name("Content-Type")!] = "application/json"
        let data = try JSONEncoder().encode(response)
        return Response(status: .ok, headers: h, body: .init { writer in
            try await writer.write(ByteBuffer(data: data))
        })
    }

    /// DELETE /v1/models/:model/sampling — reset single model to system defaults
    routes.delete("/v1/models/:model/sampling") { request, context in
        let modelId = try context.parameters.require("model")
        await enginePool.resetSamplingConfig(modelId: modelId)
        let config = await enginePool.getSamplingConfig(modelId: modelId)
        let response = ModelSamplingResponse(config: config)
        var h: HTTPFields = [:]
        h[HTTPField.Name("Content-Type")!] = "application/json"
        let data = try JSONEncoder().encode(response)
        return Response(status: .ok, headers: h, body: .init { writer in
            try await writer.write(ByteBuffer(data: data))
        })
    }

    /// DELETE /v1/models/sampling — reset ALL model sampling defaults
    routes.delete("/v1/models/sampling") { _, context in
        await enginePool.resetAllSamplingConfig()
        let response = ModelSamplingResponse(config: .default)
        var h: HTTPFields = [:]
        h[HTTPField.Name("Content-Type")!] = "application/json"
        let data = try JSONEncoder().encode(response)
        return Response(status: .ok, headers: h, body: .init { writer in
            try await writer.write(ByteBuffer(data: data))
        })
    }

#if mlx
    // MARK: Model Download

    /// POST /v1/models/download — trigger model download with SSE progress
    routes.post("/v1/models/download") { request, context in
        let downloadRequest = try await request.decode(
            as: DownloadModelRequest.self, context: context
        )
        return try await modelDownloadHandler(
            request: downloadRequest,
            hfToken: hfToken,
            msToken: msToken,
            logger: logger
        )
    }
#endif

    // Wrap with metrics tracking middleware
    let metricsMiddleware = MetricsTrackingMiddleware<OCoreAIContext>(metrics: metrics)
    routes.add(middleware: metricsMiddleware)

    return routes
}

// MARK: - Metrics Tracking Middleware

/// Middleware that records HTTP request count metrics in Prometheus format.
struct MetricsTrackingMiddleware<Context: RequestContext>: Sendable, RouterMiddleware {
    private let metrics: MetricsRegistry

    init(metrics: MetricsRegistry) {
        self.metrics = metrics
    }

    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let response = try await next(request, context)
        let status = response.status.code
        let path = String(request.uri.path.prefix { $0 != "?" })
        await self.metrics.incrementHTTPRequest(
            method: request.method.rawValue,
            path: path,
            status: status
        )
        return response
    }
}

// MARK: - Health Response

/// Response DTO for ``GET /health`` endpoint.
struct HealthResponse: Sendable, Codable {
    /// Status string ("ok")
    let status: String

    /// Unix timestamp in seconds
    let timestamp: Int64

    /// Engine pool summary snapshot
    let engineSummary: EngineSummary
}

/// Engine pool summary included in health check response.
struct EngineSummary: Sendable, Codable {
    /// Number of loaded model instances
    let loadedModels: Int

    /// Number of active inference sessions
    let activeSessions: Int

    /// Current GPU KV cache usage in gigabytes
    let gpuCacheGB: Double

    /// Number of models with CoreAI specialization compiled (v15)
    let specializedModels: Int

    /// Initialize with metrics snapshot
    init(loadedModels: Int, activeSessions: Int, gpuCacheGB: Double, specializedModels: Int = 0) {
        self.loadedModels = loadedModels
        self.activeSessions = activeSessions
        self.gpuCacheGB = gpuCacheGB
        self.specializedModels = specializedModels
    }
}

// MARK: - Model List Response (OpenAI-Compatible)

/// Root response DTO for ``GET /v1/models`` (matches OpenAI API format)
struct ModelListResponse: Sendable, Codable {
    /// List type identifier
    var object: String = "list"

    /// Array of model entries
    var data: [ModelObject]
}

/// Single model entry inside ``ModelListResponse``.
struct ModelObject: Sendable, Codable {
    /// Model identifier
    var id: String

    /// Object type identifier ("model")
    var `object`: String = "model"

    /// Owner identifier
    var ownedBy: String = "ocoreai"

    /// Initialize with model ID
    init(id: String) {
        self.id = id
    }
}

// MARK: - Count Tokens Request/Response

/// Request DTO for ``POST /v1/count-tokens`` endpoint.
struct CountTokensRequest: Sendable, Codable {
    /// Model identifier to use
    let model: String

    /// Prompt text to count tokens for
    let prompt: String
}

/// Response DTO for ``POST /v1/count-tokens`` endpoint.
struct CountTokensResponse: Sendable, Codable {
    /// Model identifier
    let model: String

    /// Token count
    let tokenCount: Int

    /// Coding keys to match OpenAI naming convention
    enum CodingKeys: String, CodingKey {
        case model
        case tokenCount = "prompt_tokens"
    }
}

// MARK: - Count Tokens Handler

/// Count tokens for a prompt, delegating to ``EnginePool`` for model resolution.
///
/// - Parameters:
///   - request: Token count request payload
///   - enginePool: Engine pool actor
/// - Returns: ``CountTokensResponse`` with token count
/// - Throws: ``AppError/modelNotFound(_:)`` if model not loaded
func countTokensHandler(
    request: CountTokensRequest,
    enginePool: EnginePool
) async throws -> CountTokensResponse {
    let handle = try await enginePool.acquire(model: request.model)
    defer { try? await handle.release() }

    let count = try await handle.countTokens(text: request.prompt)
    return CountTokensResponse(
        model: request.model,
        tokenCount: count
    )
}