// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Regression gate: a numeric knob outside its spec range gets a named 400, and cannot
/// reach the line that kills the process.
///
/// Measured 10-17 (live, macOS 26): `POST /v1/chat/completions {"max_tokens":-5}` answered
/// nothing at all — the server died with `EXC_BREAKPOINT (SIGTRAP)` inside
/// `SchedulerActor.dispatch()`, because `UInt64(request.tokenBudget)` traps on a negative.
/// One malformed body took down every other conversation on the box. `max_tokens: 0` was
/// worse in a quieter way: 200 OK with an empty completion.
///
/// The rules live in `Sources/ocoreai/Models/SamplingDomain.swift` (one checker, three
/// forwarders); the floor under them lives in `Sources/ocoreai/Scheduler/KVCacheBudget.swift`.
/// Ranges and message shape follow vllm (vllm/sampling_params.py:630-712) and its validation
/// handler, which names the offending field as `param`
/// (vllm/entrypoints/serve/exception_handling/handlers/validation.py:171-186).
///
/// Surviving companion: live probe `scripts/probes/09-malformed-request-honesty.sh`, which
/// proves the server is still answering *after* it refuses.

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing
import ocoreaiTestUtilities

@testable import ocoreai

// MARK: - Wire DTO level: every knob, both directions

@Suite("ChatCompletionRequest numeric domain — name the field, keep the process")
struct ChatNumericDomainTests {

    /// Decodes a chat body and returns the domain error, if any.
    private static func violation(
        _ json: String, file: SourceLocation = #_sourceLocation
    ) -> AppError? {
        let req = try! JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        return req.numericDomainError()
    }

    /// `"messages"` is required by the wire; every case below only varies one knob.
    private static func body(_ fields: String) -> String {
        "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\(fields)}"
    }

    @Test("max_tokens below 1 is refused by name, not trapped", arguments: [-5, 0, -1])
    func maxTokensBelowOne(bad: Int) {
        let error = Self.violation(Self.body("\"max_tokens\":\(bad)"))
        guard case .some(.invalidParameter(let param, let message, let value)) = error else {
            Issue.record("max_tokens=\(bad) must be refused, got \(String(describing: error))")
            return
        }
        #expect(param == "max_tokens")
        #expect(value == String(bad))
        #expect(message.contains("at least 1"), "must state the range: \(message)")
        #expect(error?.status == .badRequest)
    }

    @Test("max_tokens 1 (the boundary) is in domain")
    func maxTokensBoundaryPasses() {
        #expect(Self.violation(Self.body("\"max_tokens\":1")) == nil)
        #expect(Self.violation(Self.body("\"max_tokens\":4096")) == nil)
        #expect(Self.violation(Self.body("")) == nil, "absent means model default, always legal")
    }

    @Test("max_completion_tokens is named as the field the client actually sent")
    func maxCompletionTokensNamed() {
        guard
            case .some(.invalidParameter(let param, _, _)) = Self.violation(
                Self.body("\"max_completion_tokens\":-3"))
        else {
            Issue.record("max_completion_tokens=-3 must be refused")
            return
        }
        #expect(param == "max_completion_tokens", "must blame the spelling used, got \(param)")
    }

    @Test("n is decoded, and one choice per chat request is stated rather than assumed")
    func nIsDecodedAndBounded() throws {
        // Absent and n=1 are the same request.
        #expect(Self.violation(Self.body("")) == nil)
        #expect(Self.violation(Self.body("\"n\":1")) == nil)
        let decoded = try JSONDecoder().decode(
            ChatCompletionRequest.self, from: Data(Self.body("\"n\":2").utf8))
        #expect(decoded.n == 2, "n must be decoded, or the gate cannot see it")

        guard
            case .some(.invalidParameter(let param, let message, let value)) = Self.violation(
                Self.body("\"n\":2"))
        else {
            Issue.record("n=2 must be refused: this endpoint returns one choice")
            return
        }
        #expect(param == "n")
        #expect(value == "2")
        #expect(message.contains("one choice"), "must say why: \(message)")
        #expect(message.contains("request"), "must give the client what to do instead: \(message)")

        guard
            case .some(.invalidParameter(let zeroParam, let zeroMessage, _)) = Self.violation(
                Self.body("\"n\":0"))
        else {
            Issue.record("n=0 must be refused")
            return
        }
        #expect(zeroParam == "n")
        #expect(
            zeroMessage.contains("at least 1"), "n=0 must state the lower bound: \(zeroMessage)")
    }

    @Test("openai temperature range is [0, 2] — 2.5 out, 0 and 2 in")
    func openAITemperatureRange() {
        #expect(Self.violation(Self.body("\"temperature\":0")) == nil)
        #expect(Self.violation(Self.body("\"temperature\":2")) == nil)
        #expect(Self.violation(Self.body("\"temperature\":0.7")) == nil)
        for bad in [-0.1, 2.5] {
            guard
                case .some(.invalidParameter(let param, let message, _)) = Self.violation(
                    Self.body("\"temperature\":\(bad)"))
            else {
                Issue.record("temperature=\(bad) must be refused")
                continue
            }
            #expect(param == "temperature")
            #expect(message.contains("[0, 2]"), "must state the OpenAI range: \(message)")
        }
    }

    @Test("top_p is (0, 1] — 0 excluded, 1 included")
    func topPRange() {
        #expect(Self.violation(Self.body("\"top_p\":1")) == nil)
        #expect(Self.violation(Self.body("\"top_p\":0.001")) == nil)
        for bad in [0, 1.2, -0.5] {
            guard
                case .some(.invalidParameter(let param, let message, _)) = Self.violation(
                    Self.body("\"top_p\":\(bad)"))
            else {
                Issue.record("top_p=\(bad) must be refused")
                continue
            }
            #expect(param == "top_p")
            #expect(message.contains("(0, 1]"), "0 must be shown as excluded: \(message)")
        }
    }

    /// 0 is not nonsense here: `CompositeSampler.swift:138` applies the top-k filter only
    /// when `topK > 0`, so 0 means "no filter" — the same reading vllm publishes.
    @Test("top_k 0 means disable and passes; below 0 is refused")
    func topKRange() {
        #expect(Self.violation(Self.body("\"top_k\":0")) == nil)
        #expect(Self.violation(Self.body("\"top_k\":40")) == nil)
        guard
            case .some(.invalidParameter(let param, let message, _)) = Self.violation(
                Self.body("\"top_k\":-2"))
        else {
            Issue.record("top_k=-2 must be refused")
            return
        }
        #expect(param == "top_k")
        #expect(message.contains("disable"), "0 must be documented as the alternative: \(message)")
    }

    @Test("min_p is [0, 1]; penalties are [-2, 2]; repetition_penalty is above 0")
    func samplerRanges() {
        #expect(
            Self.violation(
                Self.body(
                    "\"min_p\":0,\"frequency_penalty\":-2,"
                        + "\"presence_penalty\":2,\"repetition_penalty\":1.0")) == nil)
        let cases: [(String, String)] = [
            ("\"min_p\":1.5", "min_p"),
            ("\"min_p\":-0.1", "min_p"),
            ("\"frequency_penalty\":2.1", "frequency_penalty"),
            ("\"presence_penalty\":-2.5", "presence_penalty"),
            ("\"repetition_penalty\":0", "repetition_penalty"),
            ("\"repetition_penalty\":-1", "repetition_penalty"),
        ]
        for (field, expectedParam) in cases {
            guard
                case .some(.invalidParameter(let param, let message, _)) = Self.violation(
                    Self.body(field))
            else {
                Issue.record("\(field) must be refused")
                continue
            }
            #expect(param == expectedParam, "wrong field blamed for \(field): \(param)")
            #expect(message.contains("got"), "must echo the value sent: \(message)")
        }
    }

    @Test("seed 0 is legal, negative seed is refused")
    func seedRange() {
        #expect(Self.violation(Self.body("\"seed\":0")) == nil)
        #expect(Self.violation(Self.body("\"seed\":1234")) == nil)
        guard
            case .some(.invalidParameter(let param, _, let value)) = Self.violation(
                Self.body("\"seed\":-7"))
        else {
            Issue.record("seed=-7 must be refused")
            return
        }
        #expect(param == "seed")
        #expect(value == "-7")
    }

    @Test("engine window knobs must be at least 1, and name which one")
    func windowKnobs() {
        for field in [
            "prefill_step_size", "max_kv_size", "repetition_penalty_window",
            "repetition_context_size", "presence_context_size", "frequency_context_size",
        ] {
            guard
                case .some(.invalidParameter(let param, let message, _)) = Self.violation(
                    Self.body("\"\(field)\":0"))
            else {
                Issue.record("\(field)=0 must be refused")
                continue
            }
            #expect(param == field, "wrong field blamed: \(param) for \(field)")
            #expect(message.contains("at least 1"), "must state the range: \(message)")
        }
    }
}

@Suite("CompletionRequest numeric domain — /v1/completions keeps its own n semantics")
struct CompletionsNumericDomainTests {

    private static func violation(_ fields: String) -> AppError? {
        let json = "{\"prompt\":\"hi\",\(fields)}"
        let req = try! JSONDecoder().decode(CompletionRequest.self, from: Data(json.utf8))
        return req.numericDomainError()
    }

    @Test("max_tokens below 1 is refused (it becomes the scheduler token budget)")
    func maxTokensBelowOne() {
        guard
            case .some(.invalidParameter(let param, let message, _)) = Self.violation(
                "\"max_tokens\":-5")
        else {
            Issue.record("max_tokens=-5 must be refused")
            return
        }
        #expect(param == "max_tokens")
        #expect(message.contains("at least 1"))
    }

    /// The other half of the honesty rule: this endpoint *does* generate `n` passes
    /// (`CompletionsHandler.swift:348` loops `0 ..< n`), so `n > 1` is in domain here even
    /// though chat refuses it. Range per endpoint, not per brand.
    @Test("n above 1 is honoured here; n below 1 is refused")
    func nSemantics() {
        #expect(Self.violation("\"n\":1") == nil)
        #expect(Self.violation("\"n\":3") == nil, "completions generates n passes sequentially")
        guard case .some(.invalidParameter(let param, _, _)) = Self.violation("\"n\":0") else {
            Issue.record("n=0 must be refused")
            return
        }
        #expect(param == "n")
    }

    @Test("temperature above 2 is refused on this wire too")
    func temperatureRange() {
        #expect(Self.violation("\"temperature\":2") == nil)
        guard case .some(.invalidParameter(let param, _, _)) = Self.violation("\"temperature\":9")
        else {
            Issue.record("temperature=9 must be refused")
            return
        }
        #expect(param == "temperature")
    }
}

@Suite("AnthropicMessageRequest numeric domain — Anthropic bounds, not OpenAI bounds")
struct AnthropicNumericDomainTests {

    private static func violation(_ fields: String) -> AppError? {
        let json =
            "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\(fields)}"
        let req = try! JSONDecoder().decode(AnthropicMessageRequest.self, from: Data(json.utf8))
        return req.numericDomainError()
    }

    @Test("max_tokens below 1 is refused")
    func maxTokensBelowOne() {
        guard
            case .some(.invalidParameter(let param, let message, _)) = Self.violation(
                "\"max_tokens\":-1")
        else {
            Issue.record("max_tokens=-1 must be refused")
            return
        }
        #expect(param == "max_tokens")
        #expect(message.contains("at least 1"))
    }

    /// The axis this suite exists for: 1.5 is valid OpenAI and invalid Anthropic. A shared
    /// bounds table with per-wire ranges is what keeps the two specs apart.
    @Test("temperature 1.5 is legal on OpenAI and refused on Anthropic")
    func temperatureRangeDiffersByWire() {
        guard
            case .some(.invalidParameter(let param, let message, _)) = Self.violation(
                "\"temperature\":1.5")
        else {
            Issue.record("temperature=1.5 must be refused on the Anthropic wire")
            return
        }
        #expect(param == "temperature")
        #expect(message.contains("[0, 1]"), "must state Anthropic range, not OpenAI: \(message)")

        let openAI = try! JSONDecoder().decode(
            ChatCompletionRequest.self,
            from: Data(
                "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"temperature\":1.5}"
                    .utf8))
        #expect(openAI.numericDomainError() == nil, "1.5 is inside OpenAI's [0, 2]")
    }

    @Test("top_k 0 is disabled-not-invalid on this wire")
    func topKZeroPasses() {
        #expect(Self.violation("\"top_k\":0") == nil)
        guard case .some(.invalidParameter(let param, _, _)) = Self.violation("\"top_k\":-1")
        else {
            Issue.record("top_k=-1 must be refused")
            return
        }
        #expect(param == "top_k")
    }

    /// `thinking.budget_tokens` is consumed as an output cap
    /// (`toChatCompletionRequest` takes `min(max_tokens, budget_tokens)`), so a zero budget
    /// asks for nothing and gets named rather than silently clamped.
    @Test("thinking.budget_tokens gets a dotted param path")
    func thinkingBudgetNamed() {
        #expect(Self.violation("\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":2048}") == nil)
        guard
            case .some(.invalidParameter(let param, _, let value)) = Self.violation(
                "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":0}")
        else {
            Issue.record("thinking.budget_tokens=0 must be refused")
            return
        }
        #expect(param == "thinking.budget_tokens", "nested field path: \(param)")
        #expect(value == "0")
    }
}

// MARK: - Scheduler floor: no wire value may own the process

@Suite("Scheduler token math — the floor under the wire gate")
struct SchedulerTokenFloorTests {

    @Test("KVCacheBudget.bytes floors at zero instead of trapping on UInt64(negative)")
    func bytesFloor() {
        #expect(KVCacheBudget.bytes(-5) == 0, "the expression that used to SIGTRAP")
        #expect(KVCacheBudget.bytes(0) == 0)
        #expect(KVCacheBudget.bytes(1) == 1024)
        #expect(KVCacheBudget.bytes(7) == 7 * 1024)
        #expect(KVCacheBudget.bytesPerToken == 1024)
    }

    @Test("estimatedCost: a negative output budget must not discount the input")
    func estimatedCostDoesNotDiscount() async {
        let gate = AdmissionGate(memoryTracker: nil)
        // Before the fix this was UInt64(100 + -50) — 50 tokens billed for 100.
        let cost = await gate.estimatedCost(inputTokens: 100, maxOutputTokens: -50)
        #expect(cost == 100 * 1024, "negative output must bill zero, not subtract: \(cost)")
        let both = await gate.estimatedCost(inputTokens: -1, maxOutputTokens: -1)
        #expect(both == 0)
        let normal = await gate.estimatedCost(inputTokens: 100, maxOutputTokens: 50)
        #expect(normal == 150 * 1024)
    }

    /// The exact crash path from 10-17, one level below the wire: a request whose budget is
    /// negative reaches `dispatch()` and must come back as a result or a typed error — never
    /// as a dead process.
    @Test("submitAndDispatch survives a negative tokenBudget")
    func submitSurvivesNegativeBudget() async throws {
        let scheduler = SchedulerActor(
            maxQueueSize: 4, memoryTracker: nil, log: Logger(label: "test.numeric-domain"))
        let request = SchedulingRequest(
            id: "neg-budget-1", priority: .chat, modelId: "m", prompt: "hi", tokenBudget: -5)
        // Either answer is fine — admitted, or refused with a typed reason. What is not
        // fine is the 10-17 outcome: reaching this line at all is the assertion, because
        // before the fix `UInt64(-5)` inside dispatch() ended the process here. A refusal
        // by this call can only ever be about *our* request, so a dispatch that does come
        // back is ours by contract.
        do {
            let dispatched = try await scheduler.submitAndDispatch(request)
            #expect(dispatched.id == request.id)
        } catch let error as SchedulerError {
            #expect(
                error.errorDescription?.isEmpty == false,
                "a refusal must stay explainable: \(error)")
        }
    }
}

// MARK: - HTTP level: the gate is wired at the seam, not just available

@Suite("Malformed numeric bodies get 400 at the HTTP seam — no model needed")
struct MalformedRequestHTTPTests {

    private static func uuidPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "numeric_\(UUID().uuidString.prefix(8)).sqlite"
        ).path
    }

    private static func cleanup(_ paths: [String]) {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
    }

    private static func makeTestApp(_ dbPaths: [String]) async throws -> some ApplicationProtocol {
        var config = EnginePoolConfig.default
        config.defaultModelId = ""
        let enginePool = EnginePool(
            config: config,
            logger: Logger(label: "test.numeric-http"),
            tokenizerManager: TokenizerManager()
        )
        let store = SQLiteStore(path: dbPaths[0])
        try await store.open()
        let compressor = SessionCompressor(store: store, fts: FTS5Search(store: store))

        let mbStore = SQLiteStore(path: dbPaths[1])
        try await mbStore.open()
        let mb = MessageBuilder(
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            sessionCompressor: SessionCompressor(store: mbStore, fts: FTS5Search(store: mbStore)),
            complexityAnalyzer: ComplexityAnalyzer(),
            thinkingBudget: ThinkingBudget()
        )

        return try await buildApplication(
            enginePool: enginePool,
            scheduler: SchedulerActor(
                maxQueueSize: 4, memoryTracker: nil, log: Logger(label: "test.numeric-http")),
            metrics: MetricsRegistry(),
            sessionCompressor: compressor,
            semanticSearch: nil,
            mcpBridge: MCPBridge(
                toolRegistry: ToolRegistry(log: Logger(label: "test.numeric-http")),
                transport: MCPStdioTransport(log: Logger(label: "test.numeric-http"))
            ),
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            messageBuilder: mb,
            logger: Logger(label: "test.numeric-http"),
            authMiddleware: AuthMiddleware<OCoreAIContext>(
                config: .default, logger: Logger(label: "test.numeric-http")),
            rateLimitMiddleware: RateLimitMiddleware<OCoreAIContext>(
                provider: RateLimitProvider(
                    config: RateLimitProvider.Config(
                        globalRate: 1000, globalBurst: 2000, perModelRate: 500, perModelBurst: 1000,
                        perIPRate: 500, perIPBurst: 1000, enabled: true),
                    logger: Logger(label: "test.numeric-http")),
                logger: Logger(label: "test.numeric-http")),
            hfToken: nil,
            msToken: nil
        )
    }

    /// JSON body bytes for a POST.
    private static func buffer(for json: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: json.utf8.count)
        buffer.writeString(json)
        return buffer
    }

    /// A malformed body must be refused *before* anything that needs a model — otherwise the
    /// answer for a server with nothing loaded is 503 and the gate is untested.
    /// One malformed-body case: endpoint, body, and the `param` the 400 must name.
    private struct Case {
        let uri: String
        let body: String
        let param: String
        let value: String
    }

    /// The gate must fire *before* anything that needs a loaded model — with nothing loaded,
    /// an un-guarded body would answer 503 and the assertion would test nothing.
    private static func expectNamed400(_ c: Case) async throws {
        let dbs = [uuidPath(), uuidPath()]
        defer { cleanup(dbs) }
        let app = try await makeTestApp(dbs)
        try await app.test(.router) { client in
            let headers: HTTPFields = [.contentType: "application/json"]
            try await client.execute(
                uri: c.uri, method: .post, headers: headers, body: buffer(for: c.body)
            ) { response in
                let text = response.body.getString(at: 0, length: response.body.readableBytes) ?? ""
                let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                let error = (object as? [String: Any])?["error"] as? [String: Any]
                let message = error?["message"] as? String ?? text
                #expect(
                    response.status == .badRequest,
                    "\(c.uri) answered \(response.status.code) for \(c.body)")
                #expect(
                    error?["param"] as? String == c.param,
                    "error.param must name the field, got \(String(describing: error?["param"])) in \(text)"
                )
                #expect(
                    error?["type"] as? String == "invalid_request_error",
                    "a 400 speaks the clients own error type, got \(String(describing: error?["type"]))"
                )
                #expect(message.contains(c.value), "message must echo what was sent: \(message)")
                #expect(message.contains("must"), "message must state the rule: \(message)")
            }
        }
    }

    @Test("POST /v1/chat/completions max_tokens=-5 gets 400 naming max_tokens")
    func chatNegativeMaxTokens() async throws {
        try await Self.expectNamed400(
            Case(
                uri: "/v1/chat/completions",
                body:
                    "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":-5}",
                param: "max_tokens", value: "-5"))
    }

    @Test("POST /v1/chat/completions n=4 gets 400 naming n")
    func chatN4() async throws {
        try await Self.expectNamed400(
            Case(
                uri: "/v1/chat/completions",
                body:
                    "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"n\":4}",
                param: "n", value: "4"))
    }

    @Test("POST /v1/completions max_tokens=0 gets 400 instead of an empty completion")
    func completionsZeroMaxTokens() async throws {
        try await Self.expectNamed400(
            Case(
                uri: "/v1/completions",
                body: "{\"model\":\"m\",\"prompt\":\"hi\",\"max_tokens\":0}",
                param: "max_tokens", value: "0"))
    }

    @Test("POST /v1/messages max_tokens=-1 gets 400 naming max_tokens")
    func anthropicNegativeMaxTokens() async throws {
        try await Self.expectNamed400(
            Case(
                uri: "/v1/messages",
                body:
                    "{\"model\":\"m\",\"max_tokens\":-1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
                param: "max_tokens", value: "-1"))
    }

    @Test("POST /v1/messages temperature=1.5 gets 400 — Anthropic range, not OpenAI")
    func anthropicTemperatureAboveOne() async throws {
        try await Self.expectNamed400(
            Case(
                uri: "/v1/messages",
                body:
                    "{\"model\":\"m\",\"max_tokens\":64,\"temperature\":1.5,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
                param: "temperature", value: "1.5"))
    }
}
