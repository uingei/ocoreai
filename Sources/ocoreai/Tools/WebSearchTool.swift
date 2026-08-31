// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// WebSearchTool — 获取信息 / web search,一等工具。
///
/// 对齐基准: codex 把 `web_search` 做成一等工具(codex-rs/tools/src/tool_spec.rs
/// `ToolSpec::WebSearch`,Responses API server-side 搜索,provider 代其检索)。
/// ocoreai 推理在本地(MLX/CoreAI/FoundationModels),无 provider 代搜,等价路径 =
/// 注册 `web_search` 工具,handler 调本地 ollama `/v1/responses` 端点
/// `tools: [{"type":"web_search"}]`(协议与已实跑验证的 ollama-search.py 逐字段一致)。
///
/// 后端配置(env,运行期可注入便于测试):
///   OCRE_SEARCH_BASE_URL — 默认 `http://192.168.101.146:11434/v1`(可省略 /v1,自动补)
///   OCRE_SEARCH_MODEL    — 默认 `qwen3.8:27b-mtp`
///   OCRE_SEARCH_TIMEOUT  — 默认 180 (秒)
///
/// 失败诚实:后端不可达/协议错误 → 返回 `error: ...` 文本(不造假、不吞),
/// 让模型自行降级(如改用 `exec_command curl` 或如实告知用户)。
import Foundation

// MARK: - DTO

/// Web search 解析结果(形状对齐 ollama-search.py 输出)。
struct WebSearchResult: Sendable, Equatable {
    let status: String
    let answer: String
    let searchQueries: [String]
    let usage: WebSearchUsage?

    struct WebSearchUsage: Sendable, Equatable {
        let inputTokens: Int
        let outputTokens: Int
        let totalTokens: Int
    }

    /// 面向 LLM 的紧凑单行可 grep 报告(tool-result 消费用)。
    var report: String {
        var lines: [String] = []
        lines.append("status: \(status)")
        if searchQueries.isEmpty {
            lines.append("search_queries: (none)")
        } else {
            lines.append("search_queries:")
            for q in searchQueries { lines.append("  - \(q)") }
        }
        lines.append("answer:")
        lines.append(answer.isEmpty ? "(empty)" : answer)
        if let usage {
            lines.append(
                "usage: in \(usage.inputTokens) / out \(usage.outputTokens) / total \(usage.totalTokens)"
            )
        }
        return lines.joined(separator: "\n")
    }
}

/// Web search 后端/协议错误(诚实上报,不吞)。
enum WebSearchError: Error, LocalizedError, Equatable {
    case httpStatus(Int, bodyExcerpt: String)
    case unreachable(reason: String)
    case down(probeUrl: String, timeoutS: Int)
    case decode(message: String, bodyExcerpt: String)
    case apiError(status: String?, message: String)
    case emptyAnswer

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let excerpt):
            "search backend HTTP \(code): \(excerpt)"
        case .unreachable(let reason):
            "search backend unreachable: \(reason)"
        case .down(let probeUrl, let timeoutS):
            "search backend offline (GET \(probeUrl) failed within \(timeoutS)s) — "
                + "degrade via web_fetch/exec_command or answer without new web data"
        case .decode(let message, let excerpt):
            "search response decode failed: \(message) — body(300): \(excerpt)"
        case .apiError(let status, let message):
            "search backend error: status=\(status ?? "nil") — \(message)"
        case .emptyAnswer:
            "search backend returned no answer text"
        }
    }
}

// MARK: - Request(纯函数,可测)

enum WebSearchRequest {
    struct Built: Sendable, Equatable {
        let url: URL
        let body: Data
    }

    /// 组 `/v1/responses` 请求。base 未以 `/v1` 结尾则自动补(对齐 ollama-search.py)。
    ///
    /// - Returns: 请求 URL + 精确请求体(model / tools=[{type:web_search}] / input / 可选 max_output_tokens)。
    static func build(
        query: String,
        maxOutputTokens: Int? = nil,
        model: String,
        baseUrl: String,
    ) throws -> Built {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebSearchError.apiError(status: nil, message: "query must be non-empty")
        }
        guard !model.isEmpty else {
            throw WebSearchError.apiError(status: nil, message: "model must be non-empty")
        }
        var base = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/v1") { base += "/v1" }
        guard let url = URL(string: base + "/responses") else {
            throw WebSearchError.unreachable(reason: "invalid base_url: \(baseUrl)")
        }

        // 精确请求体(键序与 ollama-search.py 一致: model, tools, input[, max_output_tokens])
        var payload: [String: Any] = [
            "model": model,
            "tools": [["type": "web_search"]],
            "input": query,
        ]
        if let maxOutputTokens, maxOutputTokens > 0 {
            payload["max_output_tokens"] = maxOutputTokens
        }
        do {
            let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return Built(url: url, body: body)
        } catch {
            throw WebSearchError.decode(message: error.localizedDescription, bodyExcerpt: "")
        }
    }
}

// MARK: - Parser(纯函数,可测)

enum WebSearchParser {
    /// 解析 ollama Responses API web_search 响应。
    ///
    /// 协议(实跑验证):
    ///   `status` ∈ "completed"…;  `error?`(后端错误);
    ///   `output[]`:`web_search_call.action.query`(检索词)与
    ///   `message.content[]`(`output_text.text`)为答案;`usage.*_tokens`。
    ///
    /// - Throws: `WebSearchError.apiError` / `decode` / `emptyAnswer`。
    static func parse(_ data: Data) throws -> WebSearchResult {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw WebSearchError.decode(
                message: error.localizedDescription,
                bodyExcerpt: String(data: data.prefix(300), encoding: .utf8) ?? "(binary)")
        }
        guard let dict = root as? [String: Any] else {
            throw WebSearchError.decode(
                message: "top-level not an object", bodyExcerpt: excerpt(data))
        }

        let status = (dict["status"] as? String) ?? ""
        if let err = dict["error"] as? [String: Any] {
            let message = (err["message"] as? String) ?? (err["code"] as? String) ?? "unknown"
            throw WebSearchError.apiError(status: status, message: message)
        }

        var queries: [String] = []
        var answer: String = ""
        if let output = dict["output"] as? [[String: Any]] {
            for item in output {
                let type = item["type"] as? String ?? ""
                switch type {
                case "web_search_call":
                    if let action = item["action"] as? [String: Any],
                        let q = action["query"] as? String, !q.isEmpty
                    {
                        queries.append(q)
                    }
                case "message":
                    var part = ""
                    for c in (item["content"] as? [[String: Any]]) ?? [] {
                        if c["type"] as? String == "output_text", let text = c["text"] as? String {
                            part += (part.isEmpty ? "" : "\n") + text
                        }
                    }
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        answer += (answer.isEmpty ? "" : "\n") + trimmed
                    }
                default:
                    break
                }
            }
        }

        var usage: WebSearchResult.WebSearchUsage?
        if let u = dict["usage"] as? [String: Any],
            let inp = u["input_tokens"] as? Int
        {
            usage = WebSearchResult.WebSearchUsage(
                inputTokens: inp,
                outputTokens: u["output_tokens"] as? Int ?? 0,
                totalTokens: u["total_tokens"] as? Int ?? (inp + (u["output_tokens"] as? Int ?? 0)))
        }

        guard !answer.isEmpty else { throw WebSearchError.emptyAnswer }
        return WebSearchResult(
            status: status,
            answer: answer,
            searchQueries: queries,
            usage: usage)
    }

    private static func excerpt(_ data: Data) -> String {
        String(data: data.prefix(300), encoding: .utf8) ?? "(binary)"
    }
}

// MARK: - Probe(纯函数 URL 构造 + async 探活,宕机快速失败)

enum WebSearchProbe {
    struct Built: Sendable, Equatable {
        let url: URL
        let timeoutS: Int
    }

    /// `/api/version` 探活 URL。base 含 `/v1` 后缀则剥离(ollama 双端点:`/api/*` 与 `/v1/*`)。
    /// timeout 下限 1s(env 注入可测:OCRE_SEARCH_PROBE_TIMEOUT,默认 5)。
    static func build(baseUrl: String, timeoutS: Int = 5) throws -> Built {
        var base = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        guard base.count > "http://".count, let url = URL(string: base + "/api/version") else {
            throw WebSearchError.unreachable(
                reason: "invalid base_url for probe: \(baseUrl)")
        }
        return Built(url: url, timeoutS: max(1, min(timeoutS, 30)))
    }

    /// GET 探活。任何 HTTP 响应 = 在线;连接层失败 = 离线(快速失败,不吞)。
    static func isUp(
        base: String, environment: [String: String] = ProcessInfo.processInfo.environment
    )
        async -> Bool
    {
        let timeoutEnv = Int(environment["OCRE_SEARCH_PROBE_TIMEOUT"] ?? "") ?? 5
        let built: Built
        do { built = try build(baseUrl: base, timeoutS: timeoutEnv) } catch { return false }
        var req = URLRequest(url: built.url)
        req.httpMethod = "GET"
        req.timeoutInterval = TimeInterval(built.timeoutS)
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse) != nil
        } catch {
            return false
        }
    }
}

// MARK: - Client(async,env 注入可测)

enum WebSearchClient {
    /// 执行一次 web search。environment 注入(env 可测,不 monkeypatch ProcessInfo)。
    /// - Returns: 解析后的结果。
    /// - Throws: `WebSearchError.unreachable` / `httpStatus` / 解析错误。
    static func search(
        query: String,
        maxOutputTokens: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) async throws -> WebSearchResult {
        let base = environment["OCRE_SEARCH_BASE_URL"] ?? "http://192.168.101.146:11434/v1"
        let model = environment["OCRE_SEARCH_MODEL"] ?? "qwen3.8:27b-mtp"
        let timeoutS = Int(environment["OCRE_SEARCH_TIMEOUT"] ?? "") ?? 180

        let built = try WebSearchRequest.build(
            query: query, maxOutputTokens: maxOutputTokens, model: model, baseUrl: base)

        // 宕机快速失败:先 GET /api/version(短超时),不通直接抛 .down,不等 POST 的长超时。
        let probe: WebSearchProbe.Built
        do {
            probe = try WebSearchProbe.build(
                baseUrl: base, timeoutS: Int(environment["OCRE_SEARCH_PROBE_TIMEOUT"] ?? "") ?? 5)
        } catch {
            throw WebSearchError.unreachable(reason: "\(error.localizedDescription)")
        }
        if await !WebSearchProbe.isUp(base: base, environment: environment) {
            throw WebSearchError.down(probeUrl: probe.url.absoluteString, timeoutS: probe.timeoutS)
        }

        var urlRequest = URLRequest(url: built.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = built.body
        urlRequest.timeoutInterval = TimeInterval(timeoutS)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch let e as URLError {
            throw WebSearchError.unreachable(
                reason: "\(built.url.absoluteString): \(e.localizedDescription)")
        } catch {
            throw WebSearchError.unreachable(
                reason: "\(built.url.absoluteString): \(error.localizedDescription)")
        }

        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw WebSearchError.httpStatus(
                http.statusCode,
                bodyExcerpt: String(data: data.prefix(300), encoding: .utf8) ?? "(binary)")
        }
        return try WebSearchParser.parse(data)
    }

    /// 面向 tool handler:成功返回报告,失败返回 `error: ...` 文本(诚实,供模型降级)。
    static func runForTool(
        query: String,
        maxOutputTokens: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) async -> String {
        do {
            let result = try await search(
                query: query, maxOutputTokens: maxOutputTokens, environment: environment)
            return result.report
        } catch let e as WebSearchError {
            return "error: \(e.errorDescription ?? "unknown web_search error")"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Tool 注册

extension WebSearchClient {
    /// `web_search` ToolEntry——信息获取一等工具(对齐 codex ToolSpec::WebSearch)。
    static func toolEntry() -> ToolEntry {
        struct WebSearchArgs: Codable {
            let query: String
            let max_output_tokens: Int?
        }
        return ToolEntry.typed(
            name: "web_search",
            toolset: "web",
            argsType: WebSearchArgs.self,
            description:
                "Search the web for current information (news, docs, facts) via the local ollama web_search backend.",
            schema: ToolSchema(parameters: [
                "query": ToolParameter(type: .string, description: "Search query."),
                "max_output_tokens": ToolParameter(
                    type: .integer, description: "Optional cap on answer tokens."),
            ])
        ) { args in
            await WebSearchClient.runForTool(
                query: args.query, maxOutputTokens: args.max_output_tokens)
        }
    }
}
