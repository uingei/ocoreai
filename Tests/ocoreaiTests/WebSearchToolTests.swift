// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `web_search` 工具 — 精确值测试。
///
/// 覆盖三类 seam(均可离线、无网络):
///   1. `WebSearchRequest.build`  —— URL 补 `/v1`、请求体精确 JSON、空 query 拒绝。
///   2. `WebSearchParser.parse`   —— ollama Responses API 逐字段解析(实跑验证形状)、
///                                     error 对象、空 answer 拒绝。
///   3. `WebSearchClient.toolEntry` —— 工具面名字/参数 schema(模型可见契约)。
///
/// 协议来源(实证):已实跑 ollama `/v1/responses`(Addis Ababa, 2.98s, exit 0),
/// 响应 `output[]` = `web_search_call.action.query` + `message.content[].output_text.text`;
/// 基准对齐:codex `ToolSpec::WebSearch`(codex-rs/tools/src/tool_spec.rs:39)。

import Foundation
import Testing

@testable import ocoreai

@Suite("web_search request construction")
struct WebSearchRequestTests {

    @Test
    func addsV1WhenBaseUrlMissing() throws {
        let b = try WebSearchRequest.build(
            query: "Swift 6.2 strict concurrency",
            model: "qwen3.8:27b-mtp",
            baseUrl: "http://127.0.0.1:11434")
        #expect(
            b.url.absoluteString
                == "http://127.0.0.1:11434/v1/responses",
            "base without /v1 must be normalized to /v1/responses")
    }

    @Test
    func keepsExistingV1Suffix() throws {
        let b = try WebSearchRequest.build(
            query: "x", model: "m",
            baseUrl: "http://host:11434/v1/")
        #expect(b.url.absoluteString == "http://host:11434/v1/responses")
    }

    @Test
    func defaultBaseUrlNormalizesToV1Responses() throws {
        let b = try WebSearchRequest.build(
            query: "x", model: "m", baseUrl: "http://127.0.0.1:11434")
        #expect(b.url.absoluteString == "http://127.0.0.1:11434/v1/responses")
    }

    @Test
    func requestBodyIsExactPayload() throws {
        let b = try WebSearchRequest.build(
            query: "What is the capital of Ethiopia?",
            maxOutputTokens: 512,
            model: "qwen3.8:27b-mtp",
            baseUrl: "http://127.0.0.1:11434/v1")
        let obj = try JSONSerialization.jsonObject(with: b.body) as? [String: Any]
        #expect(obj?["model"] as? String == "qwen3.8:27b-mtp")
        #expect(
            (obj?["tools"] as? [[String: String]])?.first?["type"] == "web_search",
            "tools[0].type must be web_search")
        #expect(obj?["input"] as? String == "What is the capital of Ethiopia?")
        #expect(obj?["max_output_tokens"] as? Int == 512)
        #expect(obj?.count == 4, "no stray keys; exactly model/tools/input/max_output_tokens")
    }

    @Test
    func omitsMaxTokensWhenNil() throws {
        let b = try WebSearchRequest.build(query: "x", model: "m", baseUrl: "http://h/v1")
        let obj = try JSONSerialization.jsonObject(with: b.body) as? [String: Any]
        #expect(obj?.contains { $0.key == "max_output_tokens" } == false)
    }

    @Test
    func rejectsEmptyQuery() {
        #expect(
            throws: WebSearchError.apiError(status: nil, message: "query must be non-empty")
        ) {
            _ = try WebSearchRequest.build(query: "   ", model: "m", baseUrl: "http://h")
        }
    }

    @Test
    func rejectsEmptyModel() {
        #expect(
            throws: WebSearchError.apiError(status: nil, message: "model must be non-empty")
        ) {
            _ = try WebSearchRequest.build(query: "valid", model: "", baseUrl: "http://h")
        }
    }
}

@Suite("web_search response parsing")
struct WebSearchParserTests {

    static func sample(_ raw: String) -> Data { Data(raw.utf8) }

    @Test
    func parsesCanonicalWebSearchResponse() throws {
        // 与 ollama-search.py 实跑成功路径同形状(web_search_call + message/output_text)。
        let raw = """
            {
              "status": "completed",
              "output": [
                {
                  "type": "web_search_call",
                  "action": {"type": "search", "query": "capital of Ethiopia"}
                },
                {
                  "type": "message",
                  "content": [
                    {"type": "output_text", "text": "The capital of Ethiopia is Addis Ababa."}
                  ]
                }
              ],
              "usage": {"input_tokens": 283, "output_tokens": 105, "total_tokens": 388}
            }
            """
        let r = try WebSearchParser.parse(Self.sample(raw))
        #expect(r.status == "completed")
        #expect(r.answer == "The capital of Ethiopia is Addis Ababa.")
        #expect(r.searchQueries == ["capital of Ethiopia"])
        #expect(
            r.usage?.inputTokens == 283
                && r.usage?.outputTokens == 105
                && r.usage?.totalTokens == 388)
    }

    @Test
    func collectsMultipleQueriesAndConcatenatesMessageParts() throws {
        let raw = """
            {
              "status": "completed",
              "output": [
                {"type": "web_search_call", "action": {"query": "swift 6.2"}} ,
                {"type": "web_search_call", "action": {"query": "swift concurrency"}},
                {"type": "message", "content": [
                    {"type": "output_text", "text": "Part one."},
                    {"type": "output_text", "text": "Part two."}
                ]}
              ]
            }
            """
        let r = try WebSearchParser.parse(Self.sample(raw))
        #expect(r.searchQueries == ["swift 6.2", "swift concurrency"], "order-preserving")
        #expect(r.answer == "Part one.\nPart two.")
    }

    @Test
    func surfacesBackendErrorObject() {
        // 协议: 顶层 error 对象 → apiError,保留 status + message 逐字。
        let raw =
            """
            {"status":"incomplete","error":{"code":"503","message":"backend unavailable"}}
            """
        #expect(
            throws: WebSearchError.apiError(
                status: "incomplete", message: "backend unavailable")
        ) {
            try WebSearchParser.parse(Self.sample(raw))
        }
    }

    @Test
    func rejectsEmptyAnswerText() {
        // 有 web_search_call 但无任何 output_text → emptyAnswer(诚实,不返空壳)。
        let raw =
            """
            {"status":"completed","output":[{"type":"web_search_call","action":{"query":"q"}}]}
            """
        let failure = { () -> WebSearchResult in
            try WebSearchParser.parse(Self.sample(raw))
        }
        do {
            _ = try failure()
            Issue.record("expected emptyAnswer")
        } catch let e as WebSearchError {
            #expect(e == .emptyAnswer)
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test
    func rejectsNonObjectTopLevel() {
        let failure = { () -> WebSearchResult in
            try WebSearchParser.parse(Self.sample("[1,2,3]"))
        }
        switch try? failure() {
        case nil: break
        default: Issue.record("expected decode error for non-object payload")
        }
    }
}

@Suite("web_search probe (fail-fast on down backend)")
struct WebSearchProbeTests {

    @Test
    func stripsV1SuffixForApiVersion() throws {
        let p = try WebSearchProbe.build(
            baseUrl: "http://127.0.0.1:11434/v1", timeoutS: 5)
        #expect(p.url.absoluteString == "http://127.0.0.1:11434/api/version")
        #expect(p.timeoutS == 5)
    }

    @Test
    func appendsV1WhenBaseHasNoSuffix() throws {
        let p = try WebSearchProbe.build(baseUrl: "http://127.0.0.1:11434", timeoutS: 5)
        #expect(p.url.absoluteString == "http://127.0.0.1:11434/api/version")
    }

    @Test
    func trimsTrailingSlash() throws {
        let p = try WebSearchProbe.build(baseUrl: "http://h:11434/v1/", timeoutS: 5)
        #expect(p.url.absoluteString == "http://h:11434/api/version")
    }

    @Test
    func clampsTimeoutTo1Through30() throws {
        #expect(try WebSearchProbe.build(baseUrl: "http://h:1", timeoutS: 0).timeoutS == 1)
        #expect(try WebSearchProbe.build(baseUrl: "http://h:1", timeoutS: 99).timeoutS == 30)
        #expect(try WebSearchProbe.build(baseUrl: "http://h:1", timeoutS: 7).timeoutS == 7)
    }

    @Test
    func rejectsInvalidBase() {
        #expect(
            throws: WebSearchError.unreachable(reason: "invalid base_url for probe: h")
        ) {
            _ = try WebSearchProbe.build(baseUrl: "h", timeoutS: 5)
        }
    }
}

@Suite("web_search tool surface")
struct WebSearchToolSurfaceTests {

    @Test
    func toolEntryExposesQueryAndOptionalMaxTokens() {
        let entry = WebSearchClient.toolEntry()
        #expect(entry.name == "web_search")
        #expect(entry.toolset == "web")
        #expect(entry.isDestructive == false)
        #expect(entry.mcpSource == nil, "built-in, not MCP-sourced")

        let params = entry.schema.parameters
        #expect(Set(params.keys) == Set(["query", "max_output_tokens"]))
        #expect(params["query"]?.type == .string)
        #expect(params["max_output_tokens"]?.type == .integer)
    }
}

// MARK: - Model discovery (self-heal on model-not-found)

@Suite("web_search model discovery — self-heal, disclosed")
struct WebSearchModelDiscoveryTests {
    @Test("parseTags reads ollama /api/tags names")
    func parseTags() {
        let json = Data(
            """
            {"models":[
              {"name":"qwen3.8:27b-nvfp4","model":"qwen3.8:27b-nvfp4"},
              {"name":"llama3.2:latest","model":"llama3.2:latest"},
              {"digest":"no-name"}
            ]}
            """.utf8)
        #expect(
            WebSearchModelDiscovery.parseTags(json) == ["qwen3.8:27b-nvfp4", "llama3.2:latest"])
    }

    @Test("parseTags malformed → empty (honest failure, no crash)")
    func parseTagsMalformed() {
        #expect(WebSearchModelDiscovery.parseTags(Data("not json".utf8)) == [])
        #expect(WebSearchModelDiscovery.parseTags(Data("{}".utf8)) == [])
    }

    @Test("pick keeps preferred when installed")
    func pickPreferred() {
        #expect(WebSearchModelDiscovery.pick(preferred: "b", installed: ["a", "b"]) == "b")
    }

    @Test("pick falls back deterministically when preferred missing")
    func pickFallback() {
        // Sorted first = stable across machines with the same installs.
        #expect(
            WebSearchModelDiscovery.pick(preferred: "ghost-model", installed: ["z", "a"]) == "a")
        #expect(WebSearchModelDiscovery.pick(preferred: "x", installed: []) == nil)
    }

    @Test("substitution is disclosed in the LLM-facing report")
    func reportDiscloses() {
        let r = WebSearchResult(
            status: "completed", answer: "42", searchQueries: ["q"], usage: nil,
            modelSubstituted: "requested 'ghost' not installed; used 'real'")
        #expect(r.report.contains("NOTE: requested 'ghost' not installed; used 'real'"))
        // No substitution → no NOTE line (no noise when honest path taken).
        let clean = WebSearchResult(
            status: "completed", answer: "42", searchQueries: [], usage: nil)
        #expect(!clean.report.contains("NOTE:"))
    }
}

// MARK: - Capability-probed fallback (200-with-empty ≠ usable)

@Suite("web_search fallback — probe candidates, disclose trail")
struct WebSearchFallbackCandidatesTests {
    @Test("candidates excludes preferred, deterministic order, capped")
    func candidatesOrder() {
        let all = ["glm:latest", "qwen-a", "qwen-b", "zeta", "alpha"]
        let c = WebSearchModelDiscovery.candidates(preferred: "ghost", installed: all, max: 3)
        // Sorted minus preferred, first 3.
        #expect(c == ["alpha", "glm:latest", "qwen-a"])
        // Preferred removed from its own fallback list.
        #expect(
            WebSearchModelDiscovery.candidates(
                preferred: "alpha", installed: all, max: 3) == ["glm:latest", "qwen-a", "qwen-b"])
        // Cap clamped to sane bounds; empty installed → empty.
        #expect(WebSearchModelDiscovery.candidates(preferred: "x", installed: [], max: 3).isEmpty)
        #expect(WebSearchModelDiscovery.candidates(preferred: "x", installed: all, max: 0).isEmpty)
    }

    @Test("disclosure keeps single-shot wording, appends honest trail")
    func disclosureTrail() {
        // No attempts → byte-identical to the original single-shot contract.
        #expect(
            WebSearchModelDiscovery.disclosure(
                original: "m", used: "f", failedAttempts: [])
                == "requested 'm' not installed; used 'f'")
        // Trail records WHY each candidate was rejected (proven failure modes).
        let d = WebSearchModelDiscovery.disclosure(
            original: "qwen3.8:27b-mtp", used: "qwen3.8:27b-nvfp4",
            failedAttempts: [
                ("glm-4.7-flash:latest", "no answer text"),
                ("gemma:e2b", "HTTP 404"),
            ])
        #expect(
            d == "requested 'qwen3.8:27b-mtp' not installed; "
                + "tried 'glm-4.7-flash:latest' (no answer text), 'gemma:e2b' (HTTP 404); "
                + "used 'qwen3.8:27b-nvfp4'")
        // The disclosure surfaces IN the LLM-facing report.
        var r = WebSearchResult(
            status: "completed", answer: "42", searchQueries: ["q"], usage: nil)
        r.modelSubstituted = d
        #expect(r.report.contains("NOTE: requested 'qwen3.8:27b-mtp'"))
        #expect(r.report.contains("no answer text"))
    }
}
