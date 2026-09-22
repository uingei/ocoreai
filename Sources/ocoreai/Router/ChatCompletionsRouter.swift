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
/// - ``GET /v1/models/:model/kv-cache`` → Planned KV cache topology + capacity disposition
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
                try await writer.finish(nil)
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

    /// `GET /v1/models` — **磁盘就绪 ∪ 内存已加载**(来源无关)。
    ///
    /// OpenAI 语义:客户端用本端点**选模型**,故必须列出磁盘上全部就绪模型
    /// (safetensors / CoreAI .aimodel 完整),不能只报 `loadedModels` — 冷启动
    /// 未 prewarm 时只报已加载会让用户以为"模型不存在"。
    ///
    /// id = `root/<org>/<name>` 相对路径(ModelStore 布局即 flat root),
    /// **不带** `hf:`/`mscope:` 来源前缀 — 下载来源对模型身份透明;
    /// local 源(绝对路径)原样保留。加载状态由 `state` 表达:
    /// `"ready"`(可用) / `"loading"`(prewarm 中);未知 → `"ready"`。
    /// 客户端按 id 请求 chat 时,Engine 侧 prefix 归一化兜底
    /// (`loadModel` 剥前缀 + flat root 本地短路)。
    routes.get("/v1/models") { _, _ in
        // 1) 内存已加载(EnginePool 内部 id 保留原样 — chat/session 键依赖它)
        let loaded = await enginePool.listModels()
        // 2) 磁盘就绪 — 只管 `~/.ocoreai/models`(root),不跨到 .cache 遗留缓存;
        //    来源无关(ModelStore 已 dedup + 判定有权重才算就绪)
        let rootP = ModelStore.root.standardizedFileURL.path
        let ready = ModelStore.discoverReady().filter {
            $0.weightsDir.standardizedFileURL.path.hasPrefix(rootP + "/")
        }
        // id 归一化:剥来源前缀(仅用于 wire id 与 loaded 匹配);
        // 客户端拿到的 id 即"磁盘相对路径或本地绝对路径",不再带 hf:/mscope: 前缀
        func normalize(_ raw: String) -> String {
            if raw.hasPrefix("hf:"), raw != "hf:" { return String(raw.dropFirst(3)) }
            if raw.hasPrefix("huggingface:") { return String(raw.dropFirst(12)) }
            if raw.hasPrefix("mscope:"), raw != "mscope:" { return String(raw.dropFirst(7)) }
            return raw
        }
        let loadedState: [String: String] = Dictionary(
            uniqueKeysWithValues: loaded.map { (normalize($0["id"] ?? ""), $0["state"] ?? "ready") }
        )

        // 3) 并集:磁盘就绪优先;loaded 独有(磁盘扫描未覆盖)保留原 id
        var seen = Set<String>()
        var objects: [ModelObject] = []
        for r in ready {
            let id = normalize(r.id)
            guard seen.insert(id).inserted else { continue }
            objects.append(
                ModelObject(
                    id: id,
                    state: loadedState[id] ?? "ready",
                    vlm: r.isVlm,
                    weightsDir: r.weightsDir.path
                ))
        }
        for m in loaded {
            let rawId = m["id"] ?? ""
            guard !rawId.isEmpty, seen.insert(rawId).inserted else { continue }
            objects.append(ModelObject(id: rawId, state: m["state"] ?? "ready"))
        }
        let response = ModelListResponse(data: objects)
        return try Response.json(response)
    }

    /// `GET /v1/capabilities` — runtime capability matrix on *this* hardware + OS version.
    ///
    /// Public (bypasses AuthMiddleware, same as `/v1/models`) — read-only observability,
    /// no sensitive data. This is the wire readout of `RuntimeCapability`:
    /// the single source of truth that the system prompt and the `info` tool also consume,
    /// so model/UI/HTTP clients never see three different answers.
    ///
    /// - Returns: `{ os, version, arch, capabilities: [{name, available, note}, ...] }`
    routes.get("/v1/capabilities") { _, _ in
        struct CAPayload: Encodable {
            let os: String
            let version: String
            let arch: String
            let capabilities: [RuntimeCapability.Line]
        }
        let payload = CAPayload(
            os: RuntimeCapability.osName,
            version: RuntimeCapability.osVersion,
            arch: RuntimeCapability.arch,
            capabilities: RuntimeCapability.lines,
        )
        return try Response.json(payload)
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
                try await writer.finish(nil)
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
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Malformed JSON is a client error: 400, not a 500 via raw SerializationError.
            throw AppError.invalidRequest("Body is not valid JSON")
        }
        if json["prompt"] != nil {
            // Decode failures (wrong prompt type, etc.) are 400, not 500 via raw DecodingError.
            guard
                let completionRequest = try? JSONDecoder().decode(
                    CompletionRequest.self, from: data)
            else {
                throw AppError.invalidRequest("Invalid CompletionsRequest JSON")
            }
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
        guard let chatRequest = try? JSONDecoder().decode(ChatCompletionRequest.self, from: data)
        else {
            throw AppError.invalidRequest("Invalid ChatCompletionRequest JSON")
        }
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

    routes.get("/v1/models/:model/kv-cache") { _, context in
        let modelId = try context.parameters.require("model")
        let response = try await enginePool.kvCacheStatus(modelId: modelId)
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

/// `state` / `vlm` / `weightsDir` 是 ocoreai 扩展字段,OpenAI 兼容客户端忽略即可。
///
/// 客户端拿这些 id 直接发 chat:MLX 模型已实证 — `loadModel` → ModelScope
/// 本地缓存短路在 `~/.ocoreai/models/<org>/<name>/` 平级根命中,秒级加载。
struct ModelObject: Codable {
    var id: String
    var object: String = "model"
    var ownedBy: String = "ocoreai"
    var state: String? = nil
    var vlm: Bool? = nil
    var weightsDir: String? = nil
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
