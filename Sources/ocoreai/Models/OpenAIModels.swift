// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// openai_models.swift — OpenAI-compatible request/response DTOs + error types
///
/// ### Request Models:
/// - ``ChatCompletionRequest``: Main inference request (supports tool calling, sessions, JSON mode)
/// - ``ModelSamplingPatch``: Partial hot-swap config update
/// - ``CountTokensRequest``: Token counting utility
///
/// ### Response Models:
/// - ``ChatCompletion``: Non-stream response
/// - ``ChatCompletionChunk``: SSE stream delta
/// - ``ModelSamplingResponse``: Runtime config inspection
///
/// ### Tool Calling:
/// Full support for function calling / tool calling aligned with OpenAI/Anthropic API.
/// Tools flow: ``ChatCompletionRequest/tools`` → generation → ``Message/toolCalls`` → assistant response.
///
/// ### Errors:
/// ``AppError`` implements ``LocalizedError`` + ``CustomStringConvertible`` for structured
/// HTTP error responses with proper status codes and descriptions.

import Foundation
import Hummingbird

// MARK: - Request Models

/// Main chat completion request DTO — supports streaming, tool calling, sessions,
/// structured output, and runtime sampling parameters.
///
/// ### Sampling Parameter Priority (3-tier fallback):
/// 1. Request body field (e.g. ``temperature``)
/// 2. Runtime default from ``EnginePool`` (hot-swappable via PATCH)
/// 3. System hard-coded default (e.g. 0.7)
///
/// ### JSON Key Mapping:
/// OpenAI API uses ``snake_case`` keys. Swift properties are ``camelCase``.
/// Explicit ``CodingKeys`` below bridge the two formats.
struct ChatCompletionRequest: Decodable {
    /// Model identifier (optional — when omitted, the default model is resolved
    /// from `PATCH /v1/models/:model/sampling` `default_model: true`; if none is
    /// configured, 400 is returned).
    var model: String?

    /// Message history (system, user, assistant, tool roles)
    var messages: [Message]

    // MARK: Sampling Parameters

    /// Temperature (0.0–2.0, higher = more random)
    var temperature: Float = 0.7

    /// Top-p nucleus sampling threshold
    var topP: Float? = nil

    /// Top-k sampling (keep K most likely tokens)
    var topK: Int? = nil

    /// Maximum output tokens (nil = model default)
    var maxTokens: Int? = nil

    /// Maximum completion tokens (OpenAI standard name, upstream coreai-models
    /// #187 `ServerAPITypes.swift:15/25`). Takes priority over `maxTokens`
    /// in the ChatHandler cascade when both are present.
    var maxCompletionTokens: Int? = nil

    /// Number of choices requested (OpenAI `n`). Decoded so it can be answered honestly:
    /// this server produces exactly one choice per request, so `n > 1` is refused by name
    /// rather than accepted and answered with a single choice (AGENTS.md invariant 2 — the
    /// surface may not silently under-deliver what the client asked for). `n == 1` and an
    /// absent `n` are the same thing.
    var n: Int? = nil

    /// JSON schema for response format override
    var responseFormat: ResponseFormat? = nil

    // MARK: Stream Control

    /// Enable Server-Sent Events streaming
    var stream: Bool = false

    /// Stop sequences (generation halts when matched).
    ///
    /// The wire accepts a bare string too — see ``decodeStopUnion(from:forKey:)``.
    var stop: [String]? = nil

    /// Frequency penalty (penalize repeated tokens)
    var frequencyPenalty: Float = 0

    /// Repetition penalty factor for tokens seen in recent generated history.
    /// `nil` = not set; `> 1.0` active (upstream `needsRepetitionPenalty`,
    /// coreai-models 5660fc6, #176). Consumed by both CoreAI (CompositeSampler
    /// sign-aware divide/multiply over `repetitionPenaltyWindow` history) and
    /// MLX (`GenerateParameters.repetitionPenalty` + `repetitionContextSize`).
    var repetitionPenalty: Double? = nil

    /// Recent-token window for repetition penalty (nil = full generated history),
    /// #176 alignment (upstream `repetitionPenaltyWindow`).
    var repetitionPenaltyWindow: Int? = nil

    /// Presence penalty (penalize tokens already in output)
    var presencePenalty: Float = 0

    /// Min-p sampling threshold
    var minP: Float? = nil

    /// Deterministic seed for reproducible sampling
    var seed: Int64? = nil

    /// Prefill step size for prompt chunking (nil = model default)
    var prefillStepSize: Int? = nil

    /// Max KV cache size — enables RotatingKVCache when set
    var maxKVSize: Int? = nil

    /// Context window for repetition penalty
    var repetitionContextSize: Int? = nil

    /// Context window for presence penalty
    var presenceContextSize: Int? = nil

    /// Context window for frequency penalty
    var frequencyContextSize: Int? = nil

    // MARK: Session Management

    /// Persistent session ID for multi-turn conversations
    var sessionID: String? = nil

    /// System prompt injected before user messages
    var system: String? = nil

    // MARK: Tool Calling (Agent Support)

    /// Tool definitions (function schemas available to the model)
    var tools: [ToolDef]? = nil

    /// Tool choice strategy ("none", "auto", "required", or specific function)
    var toolChoice: String? = nil

    /// Allow parallel tool calls in a single response
    var parallelToolCalls: Bool? = true

    /// Enable post-inference self-correction pipeline
    var selfCorrection: Bool? = false

    /// Reasoning switch — three-state (aligned with upstream mlx-swift-lm
    /// `thinkingEnabled: Bool?`):
    ///   - `nil`/absent → no preference, model template default applies (e.g. Qwen3 ON)
    ///   - `true`  → force `enable_thinking=true`
    ///   - `false` → force `enable_thinking=false`
    /// `reasoningLevel` (light/moderate/deep) and `reasoningEffort` (model-
    /// template words) take precedence when explicitly set.
    var reasoning: Bool? = nil
    /// Reasoning level for FM backend (light/moderate/deep) — aligns with SDK ReasoningLevel
    var reasoningLevel: String? = nil
    /// Reasoning effort (codex-aligned words: low/medium/high/xhigh/max/ultra).
    /// The model chat template consumes the subset it supports (Qwen3.8:
    /// xhigh/medium/low) and rejects the rest itself. Nil = model default.
    var reasoningEffort: String? = nil

    /// Stream options for controlling streaming behavior.
    var streamOptions: StreamOptions? = nil

    // MARK: - Snake-Case Key Mapping (OpenAI API compat)

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream, stop, system
        case topP = "top_p"
        case topK = "top_k"
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case n
        case responseFormat = "response_format"
        case frequencyPenalty = "frequency_penalty"
        case repetitionPenalty = "repetition_penalty"
        case repetitionPenaltyWindow = "repetition_penalty_window"
        case presencePenalty = "presence_penalty"
        case minP = "min_p"
        case seed
        case prefillStepSize = "prefill_step_size"
        case maxKVSize = "max_kv_size"
        case repetitionContextSize = "repetition_context_size"
        case presenceContextSize = "presence_context_size"
        case frequencyContextSize = "frequency_context_size"
        case sessionID = "session_id"
        case tools
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
        case selfCorrection = "self_correction"
        case reasoning
        case reasoningLevel = "reasoning_level"
        case reasoningEffort = "reasoning_effort"
        case streamOptions = "stream_options"
    }

    init(
        model: String,
        messages: [Message],
        temperature: Float = 0.7,
        topP: Float? = nil,
        topK: Int? = nil,
        maxTokens: Int? = nil,
        responseFormat: ResponseFormat? = nil,
        stream: Bool = false,
        stop: [String]? = nil,
        frequencyPenalty: Float = 0,
        repetitionPenalty: Double? = nil,
        repetitionPenaltyWindow: Int? = nil,
        presencePenalty: Float = 0,
        sessionID: String? = nil,
        system: String? = nil,
        tools: [ToolDef]? = nil,
        toolChoice: String? = nil,
        parallelToolCalls: Bool? = true,
        reasoning: Bool? = false,
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxTokens = maxTokens
        self.responseFormat = responseFormat
        self.stream = stream
        self.stop = stop
        self.frequencyPenalty = frequencyPenalty
        self.repetitionPenalty = repetitionPenalty
        self.repetitionPenaltyWindow = repetitionPenaltyWindow
        self.presencePenalty = presencePenalty
        self.sessionID = sessionID
        self.system = system
        self.tools = tools
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.reasoning = reasoning
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Optional BY CONTRACT (doc above + handler default-model path):
        // decodeIfPresent so omission reaches chatCompletionsHandler's
        // resolveModel → actionable 400 ("Set a default via PATCH…").
        // `decode` here made `model` silently required, and HB's
        // keyNotFound mapping leaked "Coding key `model` not found"
        // (live-observed 10-06) instead of the documented guidance.
        model = try c.decodeIfPresent(String.self, forKey: .model)
        messages = try c.decode([Message].self, forKey: .messages)
        temperature = try c.decodeIfPresent(Float.self, forKey: .temperature) ?? 0.7
        stream = (try? c.decodeIfPresent(Bool.self, forKey: .stream)) ?? false
        stop = try decodeStopUnion(from: c, forKey: .stop)
        system = try c.decodeIfPresent(String.self, forKey: .system)
        topP = try c.decodeIfPresent(Float.self, forKey: .topP)
        topK = try c.decodeIfPresent(Int.self, forKey: .topK)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        maxCompletionTokens = try c.decodeIfPresent(Int.self, forKey: .maxCompletionTokens)
        n = try c.decodeIfPresent(Int.self, forKey: .n)
        responseFormat = try c.decodeIfPresent(ResponseFormat.self, forKey: .responseFormat)
        frequencyPenalty = (try? c.decodeIfPresent(Float.self, forKey: .frequencyPenalty)) ?? 0
        // #176 alignment — repetition penalty is Double? (nil = not set); decoded
        // nil-tolerant like minP/seed, consumed via the nil-driven cascade in
        // ChatHandler (unlike the 0-sentinel of the Float-defaulted presence/freq).
        repetitionPenalty = try? c.decodeIfPresent(Double.self, forKey: .repetitionPenalty)
        repetitionPenaltyWindow = try? c.decodeIfPresent(Int.self, forKey: .repetitionPenaltyWindow)
        presencePenalty = (try? c.decodeIfPresent(Float.self, forKey: .presencePenalty)) ?? 0
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        tools = try c.decodeIfPresent([ToolDef].self, forKey: .tools)
        // `tool_choice` is a wire union: a bare keyword ("auto" | "none" |
        // "required") OR a named-tool object. OpenAI nests the name
        // ({"type":"function","function":{"name":"<tool>"}}); this server also
        // tolerates the flat {"type":"function","name":"<tool>"} it accepted
        // first. Both normalize to "function:<name>", which keeps the pin
        // namespace disjoint from a tool literally named "none". Vocabulary and
        // rejections live in ToolCallWire — see toolChoice(from:forKey:).
        toolChoice = try toolChoice(from: c, forKey: .toolChoice)
        parallelToolCalls = try c.decodeIfPresent(Bool.self, forKey: .parallelToolCalls)
        reasoning = try c.decodeIfPresent(Bool.self, forKey: .reasoning)
        // Wire-contract completeness: these fields were declared with
        // CodingKeys and must be decoded (standard names, upstream #187
        // wire baseline).
        minP = try c.decodeIfPresent(Float.self, forKey: .minP)
        seed = try c.decodeIfPresent(Int64.self, forKey: .seed)
        prefillStepSize = try c.decodeIfPresent(Int.self, forKey: .prefillStepSize)
        maxKVSize = try c.decodeIfPresent(Int.self, forKey: .maxKVSize)
        repetitionContextSize = try c.decodeIfPresent(Int.self, forKey: .repetitionContextSize)
        presenceContextSize = try c.decodeIfPresent(Int.self, forKey: .presenceContextSize)
        frequencyContextSize = try c.decodeIfPresent(Int.self, forKey: .frequencyContextSize)
        selfCorrection = try c.decodeIfPresent(Bool.self, forKey: .selfCorrection)
        streamOptions = try c.decodeIfPresent(StreamOptions.self, forKey: .streamOptions)
        reasoningLevel = try c.decodeIfPresent(String.self, forKey: .reasoningLevel)
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
    }

    /// The first numeric spec violation in this request, or nil when every knob is in domain.
    ///
    /// Measured 10-17: `{"max_tokens":-5}` was accepted, reached ``SchedulerActor``, and
    /// `UInt64(tokenBudget)` trapped — the process died over one malformed body. The rules
    /// themselves live in ``SamplingDomain`` (shared with the sibling wires); this forwarder
    /// states only what is specific to the chat wire: OpenAI's `temperature` 0–2, and `n`
    /// pinned to 1 because one chat request returns exactly one choice here.
    func numericDomainError() -> AppError? {
        guard
            let violation = SamplingDomain.firstViolation(
                SamplingKnobs(
                    maxTokens: maxCompletionTokens ?? maxTokens,
                    maxTokensField: maxCompletionTokens != nil
                        ? "max_completion_tokens" : "max_tokens",
                    n: n,
                    nMaximum: 1,
                    temperature: Double(temperature),
                    topP: topP.map(Double.init),
                    topK: topK,
                    minP: minP.map(Double.init),
                    frequencyPenalty: Double(frequencyPenalty),
                    presencePenalty: Double(presencePenalty),
                    repetitionPenalty: repetitionPenalty,
                    seed: seed,
                    counts: [
                        SamplingKnobs.Count(
                            field: "prefill_step_size", value: prefillStepSize ?? 1),
                        SamplingKnobs.Count(field: "max_kv_size", value: maxKVSize ?? 1),
                        SamplingKnobs.Count(
                            field: "repetition_penalty_window", value: repetitionPenaltyWindow ?? 1),
                        SamplingKnobs.Count(
                            field: "repetition_context_size", value: repetitionContextSize ?? 1),
                        SamplingKnobs.Count(
                            field: "presence_context_size", value: presenceContextSize ?? 1),
                        SamplingKnobs.Count(
                            field: "frequency_context_size", value: frequencyContextSize ?? 1),
                    ]
                )
            )
        else {
            return nil
        }
        return .invalidParameter(
            param: violation.param, message: violation.message, value: violation.value)
    }

    /// Decodes the `tool_choice` wire union (bare keyword | named-tool object) into the
    /// internal vocabulary. The rules — which keywords exist, which object shapes carry a
    /// name, what a rejection says — live in ``ToolCallWire``; this is container plumbing.
    ///
    /// Measured before this: OpenAI's own shape
    /// `{"type":"function","function":{"name":"get_weather"}}` answered
    /// `400 {"error":{"message":"Coding key \`name\` not found."}}` — Hummingbird's leak of
    /// a `DecodingError`, naming neither the field nor the accepted shape, for the one form
    /// the spec defines (vllm `chat_completion/protocol.py:220-224`,
    /// sglang `protocol.py:829-833`). Only this server's flat alias worked.
    ///
    /// Every rejection is an ``AppError/invalidParameter(param:message:value:)``: 400,
    /// `type:"invalid_request_error"`, `param:"tool_choice"`, and the spec shape in the
    /// message, so a client learns which knob to fix without parsing prose.
    private func toolChoice(from c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys)
        throws -> String?
    {
        guard c.contains(key) else { return nil }

        // Bare-string path first (the common case).
        if let raw = try? c.decodeIfPresent(String.self, forKey: key) {
            return try ToolCallWire.normalizedToolChoiceWord(raw)
        }

        // Object form. A value that is not an object at all (`tool_choice:["auto"]`,
        // `{"type":5}`) must not leave as a leaked typeMismatch either.
        guard let n = try? c.nestedContainer(keyedBy: ToolChoicePinKeys.self, forKey: key)
        else {
            throw AppError.invalidParameter(
                param: "tool_choice",
                message:
                    "tool_choice must be a string (\"none\", \"auto\", \"required\") or a "
                    + "named-tool object {\"type\":\"function\",\"function\":{\"name\":\"<tool>\"}}"
            )
        }
        let type = try? n.decodeIfPresent(String.self, forKey: .type)
        let flatName = try? n.decodeIfPresent(String.self, forKey: .name)
        var nestedName: String? = nil
        if n.contains(.function),
            let f = try? n.nestedContainer(keyedBy: ToolChoiceFunctionKeys.self, forKey: .function)
        {
            nestedName = try? f.decodeIfPresent(String.self, forKey: .name)
        }
        return try ToolCallWire.normalizedNamedToolChoice(
            type: type, flatName: flatName, nestedName: nestedName)
    }
}

// MARK: - Response Format (Structured Output)

/// Response format configuration for structured output (JSON Mode).
///
/// When ``type`` is "json_object", the model is instructed to output valid JSON.
struct ResponseFormat: Decodable {
    /// Format type: "text" | "json_object" | "json_schema"
    var type: String = "text"

    /// Schema definition (for "json_schema" type)
    var jsonSchema: JSONSchemaRequest? = nil

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

/// JSON schema for structured output validation.
struct JSONSchemaRequest: Decodable {
    /// Schema name
    var name: String

    /// Schema definition (flexible AnyCodable for dynamic structures)
    var schema: [String: AnyCodable]

    /// Strict validation mode
    var strict: Bool? = nil
}

// MARK: - AnyCodable (Dynamic Type Wrapper)

/// Universal type wrapper for dynamic schema structures.
///
/// Supports Bool, Int, Double, String, Array, Dict, and nil.
/// Used in ``JSONSchemaRequest`` where schema shape is user-defined.
///
/// ``@unchecked Sendable``: the `value: Any` property is mutated only during
/// `init(from:)` JSON deserialization, which runs on a single task and never
/// escapes before the returned `AnyCodable` is handed across concurrency
/// boundaries. After decode the value is read-only.
struct AnyCodable: Codable, Equatable, @unchecked Sendable {
    /// Wrapped dynamic value — mutable only during deserialization
    var value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else if let a = try? container.decode([AnyCodable].self) {
            value = a
        } else if let o = try? container.decode([String: AnyCodable].self) {
            value = o
        } else {
            value = NSNull()
        }
    }

    /// 递归包装任意 JSON 兼容值（`Any` 叶子 + 任意深度 `[Any]` / `[String: Any]`），
    /// 供 `ToolDef`/`FunctionDef`/`JSONSchemaRequest` 等动态 schema 构造路径使用。
    ///
    /// 背景：`encode(to:)` 的 cast 只认 `AnyCodable` 容器 —— 直接塞 `[String: Any]`
    /// 会 cast 失败落入 `encodeNil`，整段 schema 被静默吞掉（API 载荷里字段消失，
    /// 但值仍在 struct 里，值测试看不出来）。本方法在构造处统一规范化，
    /// 杜绝该静默丢失面。
    static func wrap(_ v: Any) -> AnyCodable {
        if let nc = v as? AnyCodable { return nc }  // 已是包装值
        if let o = v as? [String: Any] { return AnyCodable(o.mapValues { wrap($0) }) }  // NSDictionary 亦桥接至此
        if let a = v as? [Any] { return AnyCodable(a.map { wrap($0) }) }  // NSArray 亦桥接至此
        return AnyCodable(v)  // 叶子(Bool/Int/Double/String/NSNull 等)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let b as Bool: try container.encode(b)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        case let a as [AnyCodable]: try container.encode(a)
        case let o as [String: AnyCodable]: try container.encode(o)
        default:
            // NSNull / 未预包的 JSON 兼容容器在此兜底（NSNull 是类型模式）。
            if value is NSNull {
                try container.encodeNil()
            } else if let a = value as? [Any] {
                try container.encode(a.map { Self.wrap($0) })
            } else if let o = value as? [String: Any] {
                try container.encode(o.mapValues { Self.wrap($0) })
            } else {
                try container.encodeNil()
            }
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        lhs.value as? Data == rhs.value as? Data || lhs.value as? String == rhs.value as? String
            || lhs.value is NSNull && rhs.value is NSNull
    }
}

// MARK: - Tool Definitions

/// Tool definition (function schema) — describes what tools the model can call.
///
/// Sent in ``ChatCompletionRequest/tools`` to enable function calling.
struct ToolDef: Codable {
    /// Tool type (always "function" for function calling)
    var type: String = "function"

    /// Function schema (name, description, parameters)
    let function: FunctionDef
}

/// Function definition inside a ``ToolDef``.
struct FunctionDef: Codable {
    /// Function name
    let name: String

    /// Human-readable description
    let description: String?

    /// JSON schema parameters (dynamic AnyCodable for flexibility)
    let parameters: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case parameters
    }
}

/// Tool call result — the model's invocation of a tool.
///
/// Appears in ``Message/toolCalls`` when the assistant requests tool execution.
struct ToolCall: Codable {
    /// Unique call identifier
    let id: String

    /// Call type (always "function")
    var type: String = "function"

    /// Function invocation details
    let function: ToolCallFunction
}

/// Function invocation details inside a ``ToolCall``.
struct ToolCallFunction: Codable {
    /// Function name to invoke
    let name: String

    /// JSON arguments string (parsed from model output)
    let arguments: String

    enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }
}

// MARK: - Tool Call Parsing (Shared)

/// Stateful tool call accumulator — chunk-by-chunk equivalent of upstream
/// `ToolCallProcessor.processChunk` / `processEOS`.
///
/// Accumulates text fragments incrementally across multiple chunks. On EOS,
/// attempts JSON array parse of the full buffer. If the buffer is incomplete
/// or malformed at any intermediate point, parsing is deferred until `processEOS`.
struct ToolCallAccumulator {

    /// Raw accumulated text buffer
    private var _buffer = ""

    /// Append a text chunk. Mirrors ToolCallProcessor.processChunk.
    mutating func processChunk(_ text: String) {
        _buffer += text
    }

    /// Attempt to parse accumulated buffer as tool call JSON array on EOS.
    /// Returns nil if buffer is empty or parse fails.
    /// Mirrors ToolCallProcessor.processEOS.
    mutating func processEOS() -> [ToolCall]? {
        let trimmed = _buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = ToolCallAccumulator.parseInternal(from: trimmed)
        _buffer = ""
        return result
    }

    /// Current raw buffer (for test introspection)
    var buffer: String { _buffer }
}

/// Parse tool calls from generated model content.
///
/// Shared by ChatHandler (bridge path) and AgentLoop (fast path) to avoid
/// duplicate parsing logic.
///
/// - Parameter content: Raw generated text from the model
/// - Returns: Array of ``ToolCall`` if detected, otherwise nil
func parseToolCalls(from content: String) -> [ToolCall]? {
    ToolCallAccumulator.parseInternal(from: content)
}

// MARK: - Internal Parsing Logic

extension ToolCallAccumulator {

    /// Core parsing: JSON array of tool call objects.
    /// Handles String, Dictionary, and NSNull arguments — never crashes.
    fileprivate static func parseInternal(from content: String) -> [ToolCall]? {
        guard !content.isEmpty else { return nil }

        do {
            let jsonData = content.data(using: .utf8) ?? Data()
            guard
                let toolArray = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]]
            else {
                return nil
            }

            var toolCalls: [ToolCall] = []
            for toolObj in toolArray {
                guard let name = toolObj["name"] as? String,
                    let args = toolObj["arguments"]
                else { continue }

                let argsJson: String
                if let argsStr = args as? String {
                    argsJson = argsStr
                } else if args is NSNull {
                    argsJson = "{}"
                } else {
                    argsJson =
                        (try? String(
                            data: JSONSerialization.data(
                                withJSONObject: args, options: []), encoding: .utf8)) ?? "{}"
                }

                let tc = ToolCall(
                    id: "call_\(UUID().uuidString.prefix(8))",
                    function: ToolCallFunction(name: name, arguments: argsJson)
                )
                toolCalls.append(tc)
            }
            return toolCalls.isEmpty ? nil : toolCalls
        } catch {
            return nil
        }
    }
}

// MARK: - Message (Multi-Role + Content Polymorphism + Tool Calls)

/// Chat message supporting all roles: system, user, assistant, tool.
///
/// ``ContentPolymorphic`` allows either plain text or multi-part content
/// (text + image_url + audio) inside a single message.
struct Message: Codable {
    /// Message role: "system" | "user" | "assistant" | "tool"
    let role: String

    /// Message content (text or multi-part)
    var content: ContentPolymorphic?

    /// Sender name (optional, for multi-user scenarios)
    let name: String?

    /// Tool calls issued by the assistant (function invocations)
    var toolCalls: [ToolCall]? = nil

    /// Tool call ID for tool role messages (response to assistant call)
    var toolCallID: String? = nil

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case name
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    /// Simple string content initializer.
    init(role: String, content: String) {
        self.role = role
        self.content = .text(content)
        name = nil
    }

    /// Full initializer with all fields.
    init(
        role: String, content: ContentPolymorphic? = nil, name: String? = nil,
        toolCalls: [ToolCall]? = nil, toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

/// Content polymorphism: plain text or multi-part content array.
///
/// Decodes as ``String`` → ``.text``, as ``[ContentPart]`` → ``.parts``.
enum ContentPolymorphic: Codable {
    /// Plain text content
    case text(String)

    /// Multi-part content (text + media)
    case parts([ContentPart])

    private enum CodingKeys: String, CodingKey {
        case textValue, parts
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .parts(let p): try container.encode(p)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .text(s)
        } else if let p = try? container.decode([ContentPart].self) {
            self = .parts(p)
        } else {
            self = .text("")
        }
    }
}

/// Multi-part message part types (text + image_url + video + audio).
///
/// `CodingKeys` required: OpenAI wire uses **snake_case** (`image_url`,
/// `video_url`, `audio_url`) but Swift stores them **camelCase**
/// `imageUrl`, `videoUrl`, `audioURL`). Without this mapping the bare
/// `Codable` derives JSON keys from the Swift property names, so a real
/// OpenAI request `{"type":"image_url","image_url":{"url":"..."}}`
/// decodes to `imageUrl = nil` — the image is **silently dropped at the
/// wire layer** before it ever reaches the engine (confident blind
/// answer, HTTP 200, zero error). Hence the keys are pinned exactly.
struct ContentPart: Codable {
    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageUrl = "image_url"
        case videoUrl = "video_url"
        case audioURL = "audio_url"
    }

    /// Part type: "text" | "image_url" | "video" | "audio"
    let type: String

    /// Text content (if applicable)
    let text: String?

    /// Image URL reference (if applicable)
    let imageUrl: ImageURL?

    /// Video URL reference (if applicable)
    var videoUrl: VideoURL? = nil

    /// Audio URL reference (if applicable)
    var audioURL: AudioURL? = nil

    /// Image URL wrapper.
    struct ImageURL: Codable {
        /// URL string (http/https or base64 data URL)
        let url: String
    }

    /// Video URL wrapper.
    struct VideoURL: Codable {
        enum CodingKeys: String, CodingKey {
            case url
            case maxFrames = "max_frames"
        }

        /// URL string (http/https or base64 data URL)
        let url: String
        /// Maximum frames to extract per video (default: 16)
        let maxFrames: Int
        init(url: String, maxFrames: Int = 16) {
            self.url = url
            self.maxFrames = maxFrames
        }

        /// `maxFrames` is a non-optional `Int`, but real clients (any
        /// OpenAI-compatible caller) send `{"url": "..."}` WITHOUT `max_frames`.
        /// Plain `decode(Int.self)` would then make `VideoURL` decode fail, so
        /// the whole `[ContentPart]` array decode throws and `ContentPolymorphic`
        /// falls back to `.text("")` — the video (plus its text) silently
        /// dropped end-to-end. Hence decode with `decodeIfPresent` → 16 if
        /// absent. `maxFrames` has 0 read sites in the ocoreai video-consumption
        /// path (upstream `UserInput.Video` has no maxFrames; frame selection
        /// lives in `Gemma4ProcessorConfig.max_frames`), so the default is
        /// inert, not guessed — it only unblocks decoding.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            maxFrames = try c.decodeIfPresent(Int.self, forKey: .maxFrames) ?? 16
        }
    }

    /// Audio URL wrapper.
    struct AudioURL: Codable {
        /// URL string (http/https or local file path)
        let url: String
    }
}

// MARK: - Media Detection (single source of truth)

extension ContentPart {
    /// Whether this part carries a media payload (image, video, or audio).
    /// Pure predicate — no side effects, safe from any isolation domain.
    var isMedia: Bool {
        imageUrl != nil || videoUrl != nil || audioURL != nil
    }
}

extension Message {
    /// Whether this message carries any multimodal payload (image, video, or audio).
    ///
    /// Single source of truth for the "is this a VLM request" predicate.
    /// Previously inlined in two places (EngineInference + MessageBuilder)
    /// with independent filter lambdas — this extension converges both and
    /// removes the drift risk (e.g. one site adding `.audioURL` before the
    /// other, or one site forgetting a new part type).
    var hasMediaPart: Bool {
        if case .parts(let parts) = content {
            return parts.contains { $0.isMedia }
        }
        return false
    }

    /// Count of media parts (image/video/audio) in this message.
    /// Returns 0 for `.text` content or `.parts` with no media.
    ///
    /// Previously inlined in MessageBuilder as a `reduce` over `ContentPart`
    /// filter — this extension is the canonical form.
    var mediaPartCount: Int {
        if case .parts(let parts) = content {
            return parts.filter { $0.isMedia }.count
        }
        return 0
    }
}

// MARK: - Response Models

/// Non-streaming chat completion response (matches OpenAI API format).
struct ChatCompletion: Encodable {
    /// Completion ID
    let id: String

    /// Object type identifier
    let object: String = "chat.completion"

    /// Unix creation timestamp
    let created: Int64

    /// Model identifier
    let model: String

    /// Completion choices (usually 1)
    let choices: [CompletionChoice]

    /// Token usage statistics
    let usage: Usage

    /// What happened to audio the request attached: the on-device analyzer turned it into
    /// text before the model saw the turn (``ChatAudioIngestion``), because no model in
    /// this build can take waveform. Absent when the request carried no audio — absence is
    /// "no audio here", not "audio delivered".
    var audioInput: ChatAudioInput?

    /// The body is OpenAI-shaped, so the extension keeps the snake_case convention of the
    /// fields around it (`prompt_tokens`, `finish_reason`).
    enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case model
        case choices
        case usage
        case audioInput = "audio_input"
        case ocoreai
    }

    /// What this server's own tool loop did during the turn, measured. Absent when no tool
    /// ran — absence is "nothing was dispatched", never "nothing succeeded".
    var ocoreai: OcoreaiTurn? = nil
}

/// One dispatched tool call, as the wire reports it. `durationMs` is the wall time measured
/// around the real dispatch, so a client can verify a timing claim without echoing it back
/// through the model (`ToolResultMeta` is the source; the summary is redacted at the exit).
struct OcoreaiToolRecord: Encodable, Sendable {
    let id: String
    let name: String
    let ok: Bool
    let durationMs: Double
    let summary: String
    let failure: String?
    /// The arguments of a call that **failed**, digested by `ToolResultMeta.argumentsDigest`.
    /// Absent on success: a client must never have to infer from `"args"` whether the call ran.
    let args: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case ok
        case durationMs = "duration_ms"
        case summary
        case failure
        case args
    }

    static func from(_ meta: ToolResultMeta) -> OcoreaiToolRecord {
        OcoreaiToolRecord(
            id: meta.id,
            name: meta.name,
            ok: meta.failure == nil,
            durationMs: meta.durationMs,
            summary: SecretRedactor.redact(meta.resultSummary),
            failure: meta.failure.map { SecretRedactor.redact($0) },
            args: meta.arguments.map { SecretRedactor.redact($0) }
        )
    }
}

/// Namespaced turn extension. `ocoreai` owns this key, so a canonical OpenAI client ignores
/// it and we never present a non-spec field as spec.
struct OcoreaiTurn: Encodable, Sendable {
    let toolResults: [OcoreaiToolRecord]

    init(toolResults: [OcoreaiToolRecord]) {
        self.toolResults = toolResults
    }

    enum CodingKeys: String, CodingKey {
        case toolResults = "tool_results"
    }
}

/// Single choice inside ``ChatCompletion``.
struct CompletionChoice: Encodable {
    /// Assistant's message
    let message: AssistantMessage

    /// Generation finish reason ("stop", "length", "tool_calls", etc.)
    let finishReason: String

    /// Choice index
    let index: Int = 0

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
        case index
    }
}

/// Assistant message with optional tool calls.
struct AssistantMessage: Encodable {
    /// Role identifier (always "assistant")
    let role: String = "assistant"

    /// Text content
    let content: String?

    /// Reasoning/thinking content (OpenAI reasoning models protocol —
    /// mirrors streaming ``ChatDelta.reasoningContent`` = `reasoning_content`).
    /// nil when the model produced no reasoning.
    let reasoningContent: String?

    /// Tool call invocations (if model requested tools)
    let toolCalls: [ToolCall]?

    init(content: String, reasoningContent: String? = nil, toolCalls: [ToolCall]? = nil) {
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
    }
}

/// Token usage statistics (prompt + completion + total + per-category details).
struct Usage: Encodable {
    /// Input (prompt) token count
    let input: Int

    /// Output (completion) token count
    let output: Int

    /// Total token count
    let total: Int

    /// Prompt-side breakdowns (OpenAI `prompt_tokens_details`).
    let promptDetails: PromptTokensDetails?

    /// Completion-side breakdowns (OpenAI `completion_tokens_details`).
    let completionDetails: CompletionTokensDetails?

    /// OpenAI `prompt_tokens_details` — breakdown of the prompt token count.
    struct PromptTokensDetails: Encodable {
        /// Tokens served by a reused KV-cache prefix (upstream
        /// `GenerateCompletionInfo.cachedPromptTokenCount`, mlx-swift-lm #559).
        let cachedTokens: Int

        init(cachedTokens: Int) {
            self.cachedTokens = cachedTokens
        }

        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }

    /// OpenAI `completion_tokens_details` — breakdown of the completion token count.
    struct CompletionTokensDetails: Encodable {
        /// Reasoning/thinking tokens (baseline: mlx-swift-lm + coreai-models
        /// `reasoningTokenCount` in their completion info).
        let reasoningTokens: Int

        init(reasoningTokens: Int) {
            self.reasoningTokens = reasoningTokens
        }

        enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
        }
    }

    init(
        input: Int,
        output: Int,
        cachedPromptTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) {
        self.input = input
        self.output = output
        total = input + output
        // Details are omitted entirely when the leg produced no value (nil) —
        // OpenAI treats the whole `*_tokens_details` object as optional.
        let rt = reasoningTokens
        let prompt: PromptTokensDetails? = cachedPromptTokens.map {
            PromptTokensDetails(cachedTokens: $0)
        }
        let completion: CompletionTokensDetails? = rt.flatMap {
            $0 > 0 ? CompletionTokensDetails(reasoningTokens: $0) : nil
        }
        self.promptDetails = prompt
        self.completionDetails = completion
    }

    /// Coding keys matching OpenAI API field names.
    enum CodingKeys: String, CodingKey {
        case input = "prompt_tokens"
        case output = "completion_tokens"
        case total = "total_tokens"
        case promptDetails = "prompt_tokens_details"
        case completionDetails = "completion_tokens_details"
    }
}

/// The rendered prompt length, which is what `prompt_tokens` means on the wire.
///
/// OpenAI defines `prompt_tokens` as the whole input prompt and
/// `prompt_tokens_details.cached_tokens` as a *breakdown of* it, so
/// `cached_tokens ≤ prompt_tokens` holds by construction — vllm and sglang publish it that way.
///
/// Upstream hands us the two parts and never the total: `GenerateCompletionInfo.promptTokenCount`
/// is what this turn **prefilled** ("When a session reuses a KV-cache prefix only the remaining
/// suffix is fed to the model, so this counts fewer tokens than the rendered prompt" —
/// mlx-swift-lm `Evaluate.swift:2938-2943`), while `cachedPromptTokenCount` is the prefix its KV
// anchor:mlx-swift-lm Libraries/MLXLMCommon/Evaluate.swift:2941 counts fewer tokens than the rendered prompt
/// cache kept. Upstream's own total is `cached + prefilled` (`totalPromptTokenCount`,
/// `Evaluate.swift:3002-3004`), and mlx-swift-lm emits exactly that as its input-token count at
// anchor:mlx-swift-lm Libraries/MLXLMCommon/Evaluate.swift:3003 cachedPromptTokenCount + promptTokenCount
/// `MLXLanguageModel.swift:1377`, `:1519` and `:1721`.
///
/// Publishing the prefilled suffix instead was the deviation this exists to prevent. Measured 10-21
/// on this host, three warm turns on `/v1/chat/completions` answered `prompt_tokens` 30, 44 and 54
/// each with `prompt_tokens_details.cached_tokens: 949` — a breakdown up to 31x the whole it
/// belongs to, and by upstream's own sum (`cached + prefilled`) a prompt of 979 reported as 30:
/// the entire reused prefix is missing from anything a client bills, budgets, or rate-limits with.
enum PromptTokenAccounting {
    /// What this turn's prompt really was: the reused prefix plus the tokens it paid.
    ///
    /// `observedPrefilled == nil` means the path produced no upstream `.info` at all, so
    /// `fallback` (the pre-flight tokenizer count, or the bytes heuristic) is the best number
    /// available for the whole prompt and there is no suffix to add back — adding a cached count
    /// that was never observed here would over-report the prompt instead.
    static func renderedPromptTokens(
        observedPrefilled: Int?, cachedPromptTokens: Int?, fallback: Int
    ) -> Int {
        guard let prefilled = observedPrefilled else { return fallback }
        return prefilled + max(0, cachedPromptTokens ?? 0)
    }
}

// MARK: - Text Completion (OpenAI `/v1/completions`, legacy text-gen API)
//
// Wire contract source of truth: vllm `entrypoints/openai/completion/protocol.py`
// (`CompletionRequest`/`CompletionResponse`, the 2/3 industry-standard shape —
// vllm + sglang agree; omlx DELETE-outlier not followed). Text-gen semantics:
// `prompt` is RAW text (no chat template applied) → `object = "text_completion"`,
// `choices[].text` (not `.message`), `id` prefix `cmpl-`.
//
// P1 boundary (no-expansion, vllm defaults = no-op): `n>1` accepted but generated
// sequentially; `echo`/`suffix`/`logprobs` decoded then no-op (logprobs true value
// is the separate A2 loglikelihood batch, coreai-models semantics).

/// `/v1/completions` request body (OpenAI text-completion wire shape).
struct CompletionRequest: Decodable {
    /// Model identifier (optional — resolved like chat: per-model default, then 400).
    var model: String?

    /// Raw text prompt(s). Accepts a bare string, a list of strings, a list of
    /// token-ids, or a nested list (batch). Normalized to `[String]` for A1 (one
    /// text prompt per choice); token-id prompts are accepted but no-op'd in P1.
    var prompt: [String]

    /// Number of completions to return per prompt. P1: `>1` accepted, generated sequentially.
    var n: Int = 1

    // MARK: Sampling Parameters (OpenAI + ocoreai standard set)

    var temperature: Float = 0.7
    var topP: Float? = nil
    var topK: Int? = nil
    var maxTokens: Int? = nil
    var frequencyPenalty: Float = 0
    var presencePenalty: Float = 0
    var minP: Float? = nil
    var seed: Int64? = nil
    var repetitionPenalty: Double? = nil
    var repetitionPenaltyWindow: Int? = nil
    var repetitionContextSize: Int? = nil

    // MARK: Stream Control

    /// Enable Server-Sent Events streaming.
    var stream: Bool = false
    /// Stop sequences (generation halts when matched).
    ///
    /// Same union as chat — the spec types it `string | array[string] | null`, so this face
    /// decodes it through ``decodeStopUnion`` rather than re-declaring the shape.
    var stop: [String]? = nil
    /// Stream options (usage inclusion) — mirrors chat.
    var streamOptions: StreamOptions? = nil

    // MARK: Accepted-but-no-op fields (decoded for wire parity, P1 no-op)

    /// Echo the prompt in the completion. vllm default `false`; P1 = no-op.
    var echo: Bool = false
    /// Text that follows the prompt (suffix). vllm; P1 = no-op.
    var suffix: String? = nil
    /// Return top-k log-proabilities. A2 (loglikelihood) implements the true value.
    var logprobs: Int? = nil
    /// Per-position log-prob details. A2.
    var logprobTokenIds: [Int]? = nil
    /// Whether the final stop token is present in the output (vllm). P1 = no-op.
    var includeStopStrInOutput: Bool = false
    /// Minimum tokens to generate before a stop token (vllm). P1 = no-op.
    var minTokens: Int = 0
    /// Skip special tokens in output (vllm, default true). P1 = no-op.
    var skipSpecialTokens: Bool = true

    enum CodingKeys: String, CodingKey {
        case model, prompt, n, stream, stop
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case maxTokens = "max_tokens"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case minP = "min_p"
        case seed
        case repetitionPenalty = "repetition_penalty"
        case repetitionPenaltyWindow = "repetition_penalty_window"
        case repetitionContextSize = "repetition_context_size"
        case streamOptions = "stream_options"
        case echo, suffix, logprobs
        case logprobTokenIds = "logprob_token_ids"
        case includeStopStrInOutput = "include_stop_str_in_output"
        case minTokens = "min_tokens"
        case skipSpecialTokens = "skip_special_tokens"
    }

    init(
        prompt: [String],
        model: String? = nil,
        n: Int = 1,
        temperature: Float = 0.7,
        topP: Float? = nil,
        topK: Int? = nil,
        maxTokens: Int? = nil,
        frequencyPenalty: Float = 0,
        presencePenalty: Float = 0,
        minP: Float? = nil,
        seed: Int64? = nil,
        repetitionPenalty: Double? = nil,
        repetitionPenaltyWindow: Int? = nil,
        stream: Bool = false,
        stop: [String]? = nil,
        streamOptions: StreamOptions? = nil,
        echo: Bool = false,
        suffix: String? = nil,
        logprobs: Int? = nil,
        includeStopStrInOutput: Bool = false,
        minTokens: Int = 0,
        skipSpecialTokens: Bool = true,
    ) {
        self.prompt = prompt
        self.model = model
        self.n = n
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxTokens = maxTokens
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.minP = minP
        self.seed = seed
        self.repetitionPenalty = repetitionPenalty
        self.repetitionPenaltyWindow = repetitionPenaltyWindow
        self.stream = stream
        self.stop = stop
        self.streamOptions = streamOptions
        self.echo = echo
        self.suffix = suffix
        self.logprobs = logprobs
        self.includeStopStrInOutput = includeStopStrInOutput
        self.minTokens = minTokens
        self.skipSpecialTokens = skipSpecialTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Prompt is a union type in the OpenAI wire: string | [string] | [Int] | [[Int]].
        // A1 accepts one string or a list of strings, and normalizes to [String].
        // A bare integer list (token-id prompt) is also decoded (accepted, no-op'd in P1)
        // so an `int` payload does not hard-fail the request.
        if let s = try? c.decode(String.self, forKey: .prompt) {
            prompt = [s]
        } else if let arr = try? c.decode([String].self, forKey: .prompt) {
            prompt = arr
        } else {
            // token-id list(s) → A1 no-op: leave empty rather than hard-fail.
            prompt = []
        }
        model = try c.decodeIfPresent(String.self, forKey: .model)
        n = try c.decodeIfPresent(Int.self, forKey: .n) ?? 1
        temperature = try c.decodeIfPresent(Float.self, forKey: .temperature) ?? 0.7
        topP = try c.decodeIfPresent(Float.self, forKey: .topP)
        topK = try c.decodeIfPresent(Int.self, forKey: .topK)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        frequencyPenalty = try c.decodeIfPresent(Float.self, forKey: .frequencyPenalty) ?? 0
        presencePenalty = try c.decodeIfPresent(Float.self, forKey: .presencePenalty) ?? 0
        minP = try c.decodeIfPresent(Float.self, forKey: .minP)
        seed = try c.decodeIfPresent(Int64.self, forKey: .seed)
        repetitionPenalty = try c.decodeIfPresent(Double.self, forKey: .repetitionPenalty)
        repetitionPenaltyWindow = try c.decodeIfPresent(Int.self, forKey: .repetitionPenaltyWindow)
        stream = try c.decodeIfPresent(Bool.self, forKey: .stream) ?? false
        stop = try decodeStopUnion(from: c, forKey: .stop)
        streamOptions = try c.decodeIfPresent(StreamOptions.self, forKey: .streamOptions)
        echo = try c.decodeIfPresent(Bool.self, forKey: .echo) ?? false
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix)
        logprobs = try c.decodeIfPresent(Int.self, forKey: .logprobs)
        includeStopStrInOutput =
            try c.decodeIfPresent(Bool.self, forKey: .includeStopStrInOutput) ?? false
        minTokens = try c.decodeIfPresent(Int.self, forKey: .minTokens) ?? 0
        skipSpecialTokens = try c.decodeIfPresent(Bool.self, forKey: .skipSpecialTokens) ?? true
    }

    /// The first numeric spec violation in this request, or nil when every knob is in domain.
    ///
    /// Same reason as ``ChatCompletionRequest/numericDomainError()`` — a negative
    /// `max_tokens` here becomes ``SchedulingRequest/tokenBudget`` and reaches the scheduler,
    /// where the token-to-byte conversion used to trap. Rules live in ``SamplingDomain``;
    /// this wire differs in one place: `n > 1` is honoured (`n` passes generated
    /// sequentially), so only `n < 1` is out of domain.
    func numericDomainError() -> AppError? {
        guard
            let violation = SamplingDomain.firstViolation(
                SamplingKnobs(
                    maxTokens: maxTokens,
                    n: n,
                    temperature: Double(temperature),
                    topP: topP.map(Double.init),
                    topK: topK,
                    minP: minP.map(Double.init),
                    frequencyPenalty: Double(frequencyPenalty),
                    presencePenalty: Double(presencePenalty),
                    repetitionPenalty: repetitionPenalty,
                    seed: seed,
                    counts: [
                        SamplingKnobs.Count(
                            field: "repetition_penalty_window", value: repetitionPenaltyWindow ?? 1),
                        SamplingKnobs.Count(
                            field: "repetition_context_size", value: repetitionContextSize ?? 1),
                    ]
                )
            )
        else {
            return nil
        }
        return .invalidParameter(
            param: violation.param, message: violation.message, value: violation.value)
    }

}

/// Single choice inside ``TextCompletionResponse`` (text-gen: `text`, not `message`).
/// Distinct from the chat ``CompletionChoice`` (which carries `message`).
struct TextCompletionChoice: Encodable {
    /// Generated text.
    var text: String
    /// Generation finish reason ("stop", "length", etc.)
    var finishReason: String?
    /// Choice index.
    var index: Int = 0
    /// Token usage for this choice (only when `stream_options.include_usage` is set).
    var usage: Usage?
    /// A2 (loglikelihood) — per-token logprob details. Aligned with
    /// coreai-models `CompletionResponse.CompletionChoice.logprobs`.
    var logprobs: LogprobsResult?

    init(
        text: String, finishReason: String? = nil, index: Int = 0, usage: Usage? = nil,
        logprobs: LogprobsResult? = nil
    ) {
        self.text = text
        self.finishReason = finishReason
        self.index = index
        self.usage = usage
        self.logprobs = logprobs
    }

    enum CodingKeys: String, CodingKey {
        case text
        case finishReason = "finish_reason"
        case index
        case usage
        case logprobs
    }
}

/// A2 (loglikelihood) — per-token logprob result.
/// Aligned with coreai-models `CompletionResponse.LogprobsResult`
/// (CoreAILMCommon/CompletionTypes.swift, 8cec4f8). Field shapes are the
/// OpenAI-compatible `logprobs` payload: `tokens` / `token_logprobs` /
/// `top_logprobs` / `text_offset`.
struct LogprobsResult: Encodable, Sendable {
    let tokens: [String]
    let tokenLogprobs: [Double?]
    let topLogprobs: [[String: Double]?]
    let textOffset: [Int]

    init(
        tokens: [String], tokenLogprobs: [Double?], topLogprobs: [[String: Double]?],
        textOffset: [Int]
    ) {
        self.tokens = tokens
        self.tokenLogprobs = tokenLogprobs
        self.topLogprobs = topLogprobs
        self.textOffset = textOffset
    }

    enum CodingKeys: String, CodingKey {
        case tokens
        case tokenLogprobs = "token_logprobs"
        case topLogprobs = "top_logprobs"
        case textOffset = "text_offset"
    }
}

/// Non-streaming `/v1/completions` response (OpenAI text-completion wire shape).
struct TextCompletionResponse: Encodable {
    /// Completion ID (prefix `cmpl-`).
    var id: String
    /// Object type identifier.
    var object: String = "text_completion"
    /// Unix creation timestamp.
    var created: Int64
    /// Model identifier.
    var model: String
    /// Choices (one per prompt, or `n` per prompt in P1-sequential).
    var choices: [TextCompletionChoice]
    /// Token usage statistics.
    var usage: Usage

    init(id: String, created: Int64, model: String, choices: [TextCompletionChoice], usage: Usage) {
        self.id = id
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }
}

/// Single delta choice inside ``CompletionChunk`` (text-gen: `text` delta).
struct CompletionChunkChoice: Encodable {
    /// Incremental text delta.
    var text: String?
    /// Finish reason (null during stream, set on last chunk).
    var finishReason: String?
    /// Choice index.
    var index: Int = 0

    init(text: String? = nil, finishReason: String? = nil, index: Int = 0) {
        self.text = text
        self.finishReason = finishReason
        self.index = index
    }

    enum CodingKeys: String, CodingKey {
        case text
        case finishReason = "finish_reason"
        case index
    }
}

/// Streaming `/v1/completions` chunk (OpenAI text-completion wire shape).
struct CompletionChunk: Encodable {
    /// Stream ID (prefix `cmpl-`).
    var id: String
    /// Object type identifier.
    var object: String = "text_completion"
    /// Unix creation timestamp.
    var created: Int64
    /// Model identifier.
    var model: String
    /// Delta choices.
    var choices: [CompletionChunkChoice]
    /// Token usage statistics (only when `stream_options.include_usage` is true).
    var usage: Usage?

    init(
        id: String, created: Int64, model: String, choices: [CompletionChunkChoice],
        usage: Usage? = nil
    ) {
        self.id = id
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }
}

/// Stream options for controlling streaming behavior (OpenAI compat).
struct StreamOptions: Decodable {
    /// Whether to include usage statistics in the final stream chunk.
    var includeUsage: Bool = false

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }

    init(includeUsage: Bool = false) {
        self.includeUsage = includeUsage
    }

    /// OpenAI types `stream_options.include_usage` as optional, and `"stream_options": {}` is a
    /// legal body — with the synthesized decoder it was a 400 that killed the whole chat request
    /// (a property default does not relax the decoder: AGENTS.md § Wire DTOs).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        includeUsage = try container.decodeIfPresent(Bool.self, forKey: .includeUsage) ?? false
    }
}

// MARK: - Wire unions

/// Decode OpenAI’s `stop`: the spec types it `string | array[string] | null`, and the
/// canonical SDKs send whichever the caller wrote.
///
/// Why this is a function and not inline: both OpenAI faces declare `stop`, and a rule
/// implemented twice is a rule that drifts. The repo already had the union pattern for
/// `prompt` (``CompletionRequest/init(from:)`` decodes `string | [string] | [int]`) but
/// decoded `stop` as `[String]`-only, so the same request body was honoured on one field
/// and rejected on its neighbour.
///
/// What it deliberately does NOT do: swallow wrong types. Absent and `null` mean
/// no-stop-sequences; a number or object still throws, so a malformed body stays the
/// 4xx-with-field-name that `RequestNumericDomainTests` and probe 09 pin, rather than
/// becoming a silent no-op (the failure shape AGENTS.md invariant 2 is about).
///
/// Comparators on this axis: vllm types it `str | list[str] | None`
/// (`entrypoints/generate/base/protocol.py:26` `StopParam`), sglang
/// `Optional[Union[str, List[str]]]` (`srt/entrypoints/openai/protocol.py:368`, `:894`).
/// - Parameters:
///   - c: The keyed container the request is being decoded from.
///   - key: This request type’s CodingKey for `stop`.
/// - Returns: The sequences to honour, or `nil` when the field is absent or `null`.
func decodeStopUnion<K: CodingKey>(
    from c: KeyedDecodingContainer<K>, forKey key: K
) throws -> [String]? {
    guard c.contains(key), !(try c.decodeNil(forKey: key)) else { return nil }
    if let single = try? c.decode(String.self, forKey: key) { return [single] }
    return try c.decode([String].self, forKey: key)
}

/// Backward compatibility aliases.
typealias ChatCompletionResponse = ChatCompletion
typealias Choice = CompletionChoice

// MARK: - SSE Streaming

#if canImport(CoreAI)
/// Convert ``CoreAILanguageModels/StopReason`` to OpenAI-compatible finish_reason string.
///
/// - Parameter reason: Stop reason from inference engine
/// - Returns: "stop", "length", "cancelled", "error", or nil — the word for
///   "ended on a stop sequence" is `"stop"`: OpenAI's `finish_reason` enum is
///   `stop | length | tool_calls | content_filter`, and vllm/sglang report `stop` for
///   stop-string termination. `stop_sequence` is Anthropic's word — this repo already
///   translates it to `"stop"` on the way IN (`AnthropicModels.swift:850`), so emitting
///   it on the OpenAI wire was the same fact spelled two ways.
func stopReasonToString(_ reason: StopReason?) -> String? {
    guard let reason else { return nil }
    switch reason {
    case .maxTokens: return "length"
    case .eos: return "stop"
    case .stopSequence: return "stop"
    case .cancelled: return "cancelled"
    case .error: return "error"
    }
}
#else
/// Convert ``StopReason`` to OpenAI-compatible finish_reason string.
///\n
/// - Parameter reason: Stop reason from inference engine
/// - Returns: "stop", "length", "cancelled", "error", or nil — the word for
///   "ended on a stop sequence" is `"stop"`: OpenAI's `finish_reason` enum is
///   `stop | length | tool_calls | content_filter`, and vllm/sglang report `stop` for
///   stop-string termination. `stop_sequence` is Anthropic's word — this repo already
///   translates it to `"stop"` on the way IN (`AnthropicModels.swift:850`), so emitting
///   it on the OpenAI wire was the same fact spelled two ways.
///\n
/// P1-1 fix: The previous stub always returned "stop", which lost semantic
/// distinction between eos, max_tokens, cancellation, and error terminations.
/// This caused downstream consumers (ChatHandler, ChatView) to treat OOM/errors
/// as normal completion, preventing retry logic and KV-cache cleanup.
func stopReasonToString(_ reason: StopReason?) -> String? {
    guard let reason else { return nil }
    switch reason {
    case .maxTokens: return "length"
    case .eos: return "stop"
    case .stopSequence: return "stop"
    case .cancelled: return "cancelled"
    case .error: return "error"
    }
}
#endif

/// SSE streaming chunk (incremental delta inside ``POST /v1/chat/completions`` stream).
struct ChatCompletionChunk: Encodable {
    /// Stream ID
    let id: String

    /// Object type identifier
    let object: String = "chat.completion.chunk"

    /// Unix creation timestamp
    let created: Int64

    /// Model identifier
    let model: String

    /// Delta choices
    let choices: [ChunkChoice]

    /// Token usage statistics (only when stream_options.include_usage is true)
    let usage: Usage?

    /// Carried on the terminal chunk when the turn dispatched a tool; nil elsewhere.
    var ocoreai: OcoreaiTurn? = nil

    init(
        id: String,
        created: Int64,
        model: String,
        choices: [ChunkChoice],
        usage: Usage? = nil,
        ocoreai: OcoreaiTurn? = nil
    ) {
        self.id = id
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
        self.ocoreai = ocoreai
    }
}

/// Single delta choice inside ``ChatCompletionChunk``.
struct ChunkChoice: Encodable {
    /// Incremental content delta
    let delta: ChatDelta

    /// Finish reason (null during stream, set on last chunk)
    let finishReason: String?

    /// Choice index
    let index: Int = 0

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
        case index
    }
}

/// Incremental content delta for SSE streaming.
struct ChatDelta: Encodable {
    /// Role (only set in first chunk)
    var role: String?

    /// Text content delta
    var content: String?

    /// Reasoning/thinking content delta (OpenAI reasoning models protocol)
    var reasoningContent: String?

    /// Tool calls delta (if model is requesting tool execution)
    var toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
    }
}

// MARK: - Runtime Parameter Hot-Swap DTOs

/// Per-model runtime sampling defaults — hot-swappable via PATCH endpoint.
///
/// Lives in ``EnginePool`` and cascades: request body > this config > system default.
struct ModelSamplingConfig: Codable {
    /// Generation temperature (0.0–2.0)
    var temperature: Float = 0.7

    /// Top-p nucleus sampling threshold
    var topP: Float? = nil

    /// Top-k sampling (keep K most likely tokens)
    var topK: Int? = nil

    /// Maximum output tokens
    var maxTokens: Int? = nil

    /// Frequency penalty
    var frequencyPenalty: Float = 0

    /// Repetition penalty factor (nil = not set; > 1.0 active). #176 alignment.
    var repetitionPenalty: Double? = nil

    /// Recent-token window for repetition penalty (nil = full generated history).
    var repetitionPenaltyWindow: Int? = nil

    /// Presence penalty
    var presencePenalty: Float = 0

    /// Min-p sampling threshold
    var minP: Float? = nil

    /// Deterministic seed for reproducible sampling
    var seed: Int64? = nil

    /// Sampling mode selection (mirrors upstream MLXSamplingMode). nil → per-field behavior.
    var mode: SamplingMode? = nil

    /// Prefill config — stepSize + chunking strategy (aligns with PrefillConfig / upstream PrefillParameters).
    /// JSON key remains "prefill_step_size" for backward compat; chunking added as "prefill_chunking".
    var prefill: PrefillConfig = .default

    /// Max KV cache size (enables RotatingKVCache when set)
    var maxKVSize: Int? = nil

    /// Context window for repetition penalty
    var repetitionContextSize: Int = 20

    /// Context window for presence penalty
    var presenceContextSize: Int = 20

    /// Context window for frequency penalty
    var frequencyContextSize: Int = 20

    /// Model chat-template reasoning effort (e.g. Qwen3.8 `reasoning_effort`).
    /// Wire-not-brain: stored verbatim; word table is the model's (low/medium/
    /// high/xhigh/max/ultra, codex-aligned). nil = model default.
    var reasoningEffort: String? = nil

    /// Response format override ("text" | "json_object")
    var responseFormat: String? = nil

    /// Per-model maximum prompt token count. Requests with
    /// `promptTokenCount > maxContextWindow` are rejected with 400.
    /// `nil` = no per-model cap (system-level limits apply).
    var maxContextWindow: Int? = nil

    /// Whether this model is the default target when a request omits `model`.
    /// At most one model should set this via PATCH; first found wins.
    var defaultModel: Bool = false

    /// Keep this model's pooled sessions resident: exempt from TTL + LRU eviction.
    /// Critical memory pressure (level 3) still flushes everything.
    var pinned: Bool = false

    /// System default configuration
    static let `default`: ModelSamplingConfig = .init()

    /// Test whether this config is all-defaults (useful to mark "customized" state)
    var isDefault: Bool {
        temperature == 0.7 && topP == nil && topK == nil && maxTokens == nil
            && frequencyPenalty == 0 && presencePenalty == 0 && minP == nil && seed == nil
            && repetitionPenalty == nil && repetitionPenaltyWindow == nil
            && responseFormat == nil && reasoningEffort == nil
            && prefill.stepSize == nil && prefill.chunking == .balanced && maxKVSize == nil
            && maxContextWindow == nil && defaultModel == false && pinned == false
    }

    // MARK: - Snake-Case Key Mapping (OpenAI API compat for PATCH)

    enum CodingKeys: String, CodingKey {
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case maxTokens = "max_tokens"
        case frequencyPenalty = "frequency_penalty"
        case repetitionPenalty = "repetition_penalty"
        case repetitionPenaltyWindow = "repetition_penalty_window"
        case presencePenalty = "presence_penalty"
        case minP = "min_p"
        case seed
        case prefill
        case maxKVSize = "max_kv_size"
        case repetitionContextSize = "repetition_context_size"
        case presenceContextSize = "presence_context_size"
        case frequencyContextSize = "frequency_context_size"
        case responseFormat = "response_format"
        case maxContextWindow = "max_context_window"
        case defaultModel = "default_model"
        case pinned
    }
}

/// PATCH body — partial sampling config update (all fields optional).
struct ModelSamplingPatch: Decodable {
    var temperature: Float? = nil
    var topP: Float? = nil
    var topK: Int? = nil
    var maxTokens: Int? = nil
    var frequencyPenalty: Float? = nil
    var repetitionPenalty: Double? = nil
    var repetitionPenaltyWindow: Int? = nil
    var presencePenalty: Float? = nil
    var minP: Float? = nil
    var seed: Int64? = nil
    var prefillStepSize: Int? = nil
    var maxKVSize: Int? = nil
    var repetitionContextSize: Int? = nil
    var presenceContextSize: Int? = nil
    var frequencyContextSize: Int? = nil
    var responseFormat: String? = nil
    var maxContextWindow: Int? = nil
    var defaultModel: Bool? = nil
    var pinned: Bool? = nil

    /// Merge partial fields into a full ``ModelSamplingConfig``.
    func toConfig() -> ModelSamplingConfig {
        merged(onto: .default)
    }

    /// PATCH semantics: overlay only the fields present in this patch onto
    /// `base`. `toConfig()` starts from `.default` (full replace) — wrong for
    /// PATCH: a single-field patch would silently wipe unrelated overrides
    /// (default_model, penalties, context sizes). PATCH must merge.
    func merged(onto base: ModelSamplingConfig) -> ModelSamplingConfig {
        var config = base
        if let t = temperature { config.temperature = t }
        if let p = topP { config.topP = p }
        if let k = topK { config.topK = k }
        if let m = maxTokens { config.maxTokens = m }
        if let f = frequencyPenalty { config.frequencyPenalty = f }
        if let rp = repetitionPenalty { config.repetitionPenalty = rp }
        if let rpw = repetitionPenaltyWindow { config.repetitionPenaltyWindow = rpw }
        if let p = presencePenalty { config.presencePenalty = p }
        if let mp = minP { config.minP = mp }
        if let s = seed { config.seed = s }
        if let r = responseFormat { config.responseFormat = r }
        if let ps = prefillStepSize {
            // Backward compat: stepSize from old key merges into new prefill struct
            config.prefill.stepSize = ps
        }
        if let m = maxKVSize { config.maxKVSize = m }
        if let r = repetitionContextSize { config.repetitionContextSize = r }
        if let p = presenceContextSize { config.presenceContextSize = p }
        if let f = frequencyContextSize { config.frequencyContextSize = f }
        if let m = maxContextWindow { config.maxContextWindow = m }
        if let d = defaultModel { config.defaultModel = d }
        if let p = pinned { config.pinned = p }
        return config
    }

    // MARK: - Snake-Case Key Mapping (OpenAI API compat for PATCH)

    enum CodingKeys: String, CodingKey {
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case maxTokens = "max_tokens"
        case frequencyPenalty = "frequency_penalty"
        case repetitionPenalty = "repetition_penalty"
        case repetitionPenaltyWindow = "repetition_penalty_window"
        case presencePenalty = "presence_penalty"
        case minP = "min_p"
        case seed
        case prefillStepSize = "prefill_step_size"
        case maxKVSize = "max_kv_size"
        case repetitionContextSize = "repetition_context_size"
        case presenceContextSize = "presence_context_size"
        case frequencyContextSize = "frequency_context_size"
        case responseFormat = "response_format"
        case maxContextWindow = "max_context_window"
        case defaultModel = "default_model"
        case pinned
    }
}

/// GET response — full runtime sampling config for a single model.
struct ModelSamplingResponse: Encodable {
    let temperature: Float
    let topP: Float?
    let topK: Int?
    let maxTokens: Int?
    let frequencyPenalty: Float
    let repetitionPenalty: Double?
    let repetitionPenaltyWindow: Int?
    let presencePenalty: Float
    let minP: Float?
    let seed: Int64?
    let maxKVSize: Int?
    let repetitionContextSize: Int
    let presenceContextSize: Int
    let frequencyContextSize: Int
    let responseFormat: String?
    let maxContextWindow: Int?
    let defaultModel: Bool
    let pinned: Bool

    /// Initialize from ``ModelSamplingConfig``.
    init(config: ModelSamplingConfig) {
        temperature = config.temperature
        topP = config.topP
        topK = config.topK
        maxTokens = config.maxTokens
        frequencyPenalty = config.frequencyPenalty
        repetitionPenalty = config.repetitionPenalty
        repetitionPenaltyWindow = config.repetitionPenaltyWindow
        presencePenalty = config.presencePenalty
        minP = config.minP
        seed = config.seed
        maxKVSize = config.maxKVSize
        repetitionContextSize = config.repetitionContextSize
        presenceContextSize = config.presenceContextSize
        frequencyContextSize = config.frequencyContextSize
        responseFormat = config.responseFormat
        maxContextWindow = config.maxContextWindow
        defaultModel = config.defaultModel
        pinned = config.pinned
    }

    enum CodingKeys: String, CodingKey {
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case maxTokens = "max_tokens"
        case frequencyPenalty = "frequency_penalty"
        case repetitionPenalty = "repetition_penalty"
        case repetitionPenaltyWindow = "repetition_penalty_window"
        case presencePenalty = "presence_penalty"
        case minP = "min_p"
        case seed
        case maxKVSize = "max_kv_size"
        case repetitionContextSize = "repetition_context_size"
        case presenceContextSize = "presence_context_size"
        case frequencyContextSize = "frequency_context_size"
        case responseFormat = "response_format"
        case maxContextWindow = "max_context_window"
        case defaultModel = "default_model"
        case pinned
    }
}

// MARK: - Application Errors (LocalizedError + Sendable)

/// Centralized application error type implementing ``LocalizedError``.
///
/// Each case maps to an HTTP status code and a structured error description
/// for consistent JSON error responses across all endpoints.
enum AppError: Error, CustomStringConvertible, LocalizedError, HTTPResponseError {
    /// Bad Request — client sent malformed data
    case invalidRequest(String)

    /// Bad Request — one named field carries a value outside the range its spec publishes.
    ///
    /// ``invalidRequest(String)`` says what went wrong; this says *which knob*, because a
    /// 400 on a 20-field body is only actionable if the client learns which field to fix.
    /// `param` is the wire path (dotted for nested: `thinking.budget_tokens`), `value` the
    /// value as sent. Both are published in the JSON body, which is the shape vllm's
    /// validation handler emits for every 400 (`param`,
    /// vllm/entrypoints/serve/exception_handling/handlers/validation.py:171-186) and the
    /// shape OpenAI/Anthropic SDKs branch on alongside `type`.
    case invalidParameter(param: String, message: String, value: String? = nil)

    /// Bad Request — prompt exceeds the model's `max_context_window` **after**
    /// a full compaction pass removed every removable unit (protected prefix +
    /// suffix + the compaction note alone already exceed the cap).
    ///
    /// Typed (non-string) so JSON clients can branch on the condition and
    /// carry the post-compaction estimate + cap: the transcript is the
    /// authoritative bloated state, and retrying an equally-sized request
    /// fails identically — callers must start a fresh, shorter conversation
    /// instead of retrying (hermes-agent `compression_exhausted` typed bit;
    /// was previously an untyped `invalidRequest(String)`).
    case contextWindowExhausted(postTokens: Int, cap: Int)

    /// Not Found — model does not exist or is not loaded
    case modelNotFound(String)

    /// Service Unavailable — the id is not resident and could not be fetched: the configured
    /// hub answered, and the fallback hub could not be asked within
    /// `HubReachability.probeTimeoutSeconds`. Distinct from `modelNotFound` on purpose: this
    /// one is transient, so the client should retry (or point `HF_ENDPOINT` at a reachable
    /// mirror) instead of concluding the model does not exist.
    case modelUnavailable(modelId: String, reason: String)

    /// Internal Error — engine pool exhausted (max sessions reached)
    case poolExhausted(Int)

    /// Service Unavailable — request queue closed during shutdown
    case queueClosed

    /// Not Found — cold-stored KV cache missing from SSD
    case coldStoreNotFound(String)

    /// Internal Error — inference generation failed
    case generationError(String)

    /// Data Loss — KV cache serialization/deserialization corrupted
    case kvCacheCorruption(String)

    /// Service Unavailable — engine unavailable (load failure)
    case engineUnavailable

    /// Service Unavailable — system memory is under OOM pressure; the OOM guard
    /// refuses new requests to protect existing ones.
    ///
    /// Typed (non-string) so JSON clients can branch on the condition and carry
    /// the actual numbers: "currently X GB of Y GB budget" + a concrete next step
    /// (release memory / use a smaller or more quantized model), mirroring the
    /// error-standard in vllm-metal #756 (`increase --gpu-memory-utilization
    /// (currently 0.15); use a smaller or more quantized model`). Distinct from
    /// ``engineUnavailable`` (engine load failure) so JSON clients can separate
    /// "machine is out of RAM" from "engine not ready" and act differently.
    case memoryExhausted(usedGB: Int, budgetGB: Int)

    /// Service Unavailable — model still loading / prewarming; caller should
    /// retry (poll `state: "loading"` on ``GET /v1/models`` until it flips
    /// to `ready`). Distinct from ``engineUnavailable`` so JSON clients can
    /// tell "transient, retry" apart from "permanent, give up".
    case modelLoading(String)

    /// Internal Error — inference pipeline failed
    case inferenceFailed(String)

    /// Internal Error — tokenization pipeline failed
    case tokenizationFailed(String)

    /// Bad Request — tool call validation/execution failed
    case toolCallFailed(String)

    /// Gone — session expired or invalidated
    case sessionExpired(String)

    /// Service Unavailable — session limit exceeded
    case sessionLimitExceeded

    /// Not Implemented — engine cannot score logprobs (no logits output).
    /// A2 loglikelihood path; upstream coreai-models 501 "Logprobs not supported".
    case logitsUnsupported

    /// Not Implemented — loaded model has no MLX handle (CoreAI-only model).
    /// KV-cache inspection consumes the upstream MLX `cacheStatus` API.
    case kvCacheStatusUnsupported

    /// Too Many Requests — single-slot engine busy (loglikelihood scoring).
    case engineBusy

    /// Service Unavailable — on-device transcription is measured-unavailable: permission not
    /// granted, no local model for the locale, or the Speech engine probe faulted
    /// (`HearingReadiness`). Typed with `error_code` + the remedy so a client branches on the
    /// condition instead of string-parsing, and so "we could not hear" is never a bare 500.
    case transcriptionUnavailable(errorCode: String, reason: String)

    /// Bad Request — the speech failure is a fault in the bytes the client sent, measured by
    /// the decoder (`TranscriptFailure.undecodableAudio`), not by the service. This case
    /// exists because `AudioTranscription.status(for:)` already classifies that failure as a
    /// client error while its throw site had only `.transcriptionUnavailable`, whose status is
    /// 503: one failure was answered 400 by the table and 503 by the wire, and 503 tells a
    /// client "retry the service" when retrying the same bytes can never work. One typed
    /// failure, one status, on every route that hears audio.
    case transcriptionRejected(errorCode: String, reason: String)

    /// Bad Request — the audio in the request could not be used (no `file`/`audio` part,
    /// undecodable bytes, over the size cap, a remote URL, or a field this engine does not
    /// provide such as `response_format: verbose_json`).
    case invalidAudio(reason: String)

    /// Bad Request — a media part named a file this process cannot open (`file://…` or a
    /// filesystem path that is not there). Typed and 4xx because the client can fix it:
    /// without this case the failure surfaced from AVFoundation as
    /// `500 … The operation could not be completed`, naming neither the axis nor the part
    /// (`ChatMediaResolution`, measured 10-16).
    case mediaUnresolvable(reason: String)

    /// Internal Server Error — bytes this server spooled into its own ``MediaSpool`` are
    /// gone while a conversation still cites them. Ours to report, not the client's to fix,
    /// which is why it is not folded into ``mediaUnresolvable``: the remediation differs,
    /// and so does the blame.
    case mediaLost(reason: String)

    /// ``CustomStringConvertible`` description (used in logs)
    var description: String {
        switch self {
        case .invalidRequest(let msg): "Invalid request: \(msg)"
        case .invalidParameter(_, let message, _): "Invalid request: \(message)"
        case .contextWindowExhausted(let postTokens, let cap):
            "Context window exhausted: \(postTokens) tokens after compaction (cap \(cap)) — start a fresh conversation"
        case .modelNotFound(let name): "Model \(name) not found"
        case .modelUnavailable(let name, let reason):
            "Model \(name) is not available right now: \(reason)"
        case .poolExhausted(let max): "Engine pool exhausted (max: \(max))"
        case .queueClosed: "Request queue closed"
        case .coldStoreNotFound(let id): "Cold store entry \(id) not found"
        case .generationError(let msg): "Generation failed: \(msg)"
        case .kvCacheCorruption(let msg): "KV cache corruption: \(msg)"
        case .engineUnavailable: "Engine unavailable"
        case .memoryExhausted(let used, let budget):
            "Request refused due to OOM protection — memory \(used) GB used of \(budget) GB budget. "
                + "Free up memory (close other apps), switch to a smaller or more quantized model, "
                + "or raise the memory budget, then retry."
        case .modelLoading(let name):
            "Model \(name) is still loading — retry when state == \"ready\""
        case .inferenceFailed(let msg): "Inference failed: \(msg)"
        case .tokenizationFailed(let msg): "Tokenization failed: \(msg)"
        case .toolCallFailed(let msg): "Tool call failed: \(msg)"
        case .sessionExpired(let id): "Session - \(id) expired"
        case .sessionLimitExceeded: "Session limit exceeded"
        case .logitsUnsupported: "Logprobs not supported by this engine"
        case .kvCacheStatusUnsupported:
            "KV cache inspection requires an MLX-backed model"
        case .engineBusy: "Engine is busy — try again shortly"
        case .transcriptionUnavailable(_, let reason):
            "Transcription unavailable: \(reason)"
        case .transcriptionRejected(_, let reason):
            "Audio rejected: \(reason)"
        case .invalidAudio(let reason):
            "Invalid audio: \(reason)"
        case .mediaUnresolvable(let reason):
            "Media unresolvable: \(reason)"
        case .mediaLost(let reason):
            "Media lost: \(reason)"
        }
    }

    /// ``LocalizedError`` error description (used in JSON error responses)
    var errorDescription: String? {
        description
    }

    /// ``HTTPResponseError.status`` — Hummingbird uses this to map thrown errors to HTTP status codes.
    ///
    /// Without this, Hummingbird treats any unhandled error as 500 Internal Server Error,
    /// even when the error is a client error (4xx).
    var status: HTTPResponse.Status {
        switch self {
        case .invalidRequest, .invalidParameter, .toolCallFailed, .contextWindowExhausted:
            .badRequest
        case .modelNotFound, .coldStoreNotFound:
            .notFound
        case .poolExhausted, .queueClosed, .engineUnavailable, .memoryExhausted,
            .modelLoading,
            .sessionLimitExceeded:
            .serviceUnavailable
        case .modelUnavailable:
            .serviceUnavailable
        case .sessionExpired:
            .gone
        case .logitsUnsupported:
            .notImplemented
        case .kvCacheStatusUnsupported:
            .notImplemented
        case .engineBusy:
            .tooManyRequests
        case .transcriptionUnavailable:
            .serviceUnavailable
        case .transcriptionRejected:
            .badRequest
        case .invalidAudio:
            .badRequest
        case .mediaUnresolvable:
            .badRequest
        case .mediaLost:
            .internalServerError
        case .generationError, .kvCacheCorruption, .inferenceFailed, .tokenizationFailed:
            .internalServerError
        }
    }

    /// ``HTTPResponseError.response(from:context:)`` — build a JSON error response.
    nonisolated func response(
        from request: Request,
        context: some RequestContext
    ) throws -> Response {
        let detail = NSMutableDictionary(dictionary: [
            "message": errorDescription ?? String(describing: self),
            "type": "app_error",
            "code": status.code,
        ])
        // Typed error payload: the context-window-exhausted condition carries a
        // machine-readable error_code + the exact numbers a client needs to
        // react (fresh session, or raise max_context_window) — without this,
        // clients must string-parse the message to detect exhaustion.
        if case .contextWindowExhausted(let postTokens, let cap) = self {
            detail["error_code"] = "context_window_exhausted"
            detail["post_tokens"] = postTokens
            detail["cap"] = cap
        }
        if case .memoryExhausted(let used, let budget) = self {
            detail["error_code"] = "memory_exhausted"
            detail["used_gb"] = used
            detail["budget_gb"] = budget
        }
        // Hearing refusals carry the measured reason + the fix (System Settings pane, retry
        // guidance), because "transcription unavailable" without the axis is unactionable.
        if case .transcriptionUnavailable(let errorCode, let reason) = self {
            detail["error_code"] = errorCode
            detail["remediation"] = reason
        }
        // Same typed payload as the 503 sibling: clients branch on `error_code`, and the
        // status is the only thing that should differ between "fix your bytes" and
        // "fix the machine".
        if case .transcriptionRejected(let errorCode, let reason) = self {
            detail["error_code"] = errorCode
            detail["remediation"] = reason
        }
        if case .invalidAudio(let reason) = self {
            detail["error_code"] = "invalid_audio"
            detail["remediation"] = reason
        }
        // Media-by-reference gets the same treatment as audio: name the axis, name the fix.
        if case .mediaUnresolvable(let reason) = self {
            detail["error_code"] = "media_unresolvable"
            detail["remediation"] = reason
        }
        if case .mediaLost(let reason) = self {
            detail["error_code"] = "media_lost"
            detail["remediation"] = reason
        }
        // Request-shape refusals speak the clients' own error type. Both specs name
        // `invalid_request_error` for a 400 (OpenAI Errors, Anthropic Errors), and vllm —
        // the reference stack for both wires here — puts the offending field next to it.
        // `app_error` is what an SDK sees for everything it has no name for, so leaving a
        // 400 there costs clients a string-parse.
        switch self {
        case .invalidRequest:
            detail["type"] = "invalid_request_error"
        case .engineBusy:
            // Both specs name this shape for a capacity refusal (OpenAI Errors, Anthropic
            // Errors: `rate_limit_error`), and an SDK branches on `type`, not on the string.
            detail["type"] = "rate_limit_error"
            detail["error_code"] = "engine_busy"
            detail["retry_after_seconds"] = EngineBusySignal.retryAfterSeconds
        case .invalidParameter(let param, _, let value):
            detail["type"] = "invalid_request_error"
            detail["param"] = param
            if let value {
                detail["value"] = value
            }
        default:
            break
        }
        let errorBody = NSDictionary(dictionary: ["error": detail])
        var headers: HTTPFields = [:]
        headers[.contentType] = "application/json"
        // A capacity refusal that does not say when to come back makes the client hammer the
        // box that just said no. RFC 9110 §10.2.3 gives the number a home, and here it is
        // exactly the window the server already spent waiting (EngineBusySignal).
        if case .engineBusy = self {
            headers[.retryAfter] = "\(EngineBusySignal.retryAfterSeconds)"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: errorBody, options: []) else {
            return Response(status: status)
        }
        return Response(
            status: status,
            headers: headers,
            body: .init(contentsOf: [ByteBuffer(data: data)])
        )
    }
}

// MARK: - Grammar Schema Construction (shared: ChatHandler + DirectInferenceClient)

/// `tool_choice: "none"` (OpenAI wire) = "Model must not call any tools"
/// (tool_calls empty). It overrides a declared `tools[]`: the declared
/// schemas stay in the request for template/convenience, but the engine must
/// expose ZERO tools and must not be routed to the tool-call guided path.
/// Any other value ("auto"/"required"/specific-function object, or absent)
/// leaves the declared surface untouched — enforcement semantics
/// (e.g. retry when "required" produced no tool call) is a separate
/// decision and stays downstream of this surface decision.
func effectiveTools(
    from request: ChatCompletionRequest
) -> [ToolDef]? {
    if request.toolChoice == "none" {
        return nil
    }
    return request.tools
}

/// Does this turn DEMAND a tool call?
///
/// OpenAI carries that instruction in `tool_choice`, never in the presence of
/// `tools[]`: absent/"auto" = the model may answer instead of calling; "required"
/// and the pinned `{"type":"function",…}` (normalized to `function:<name>` when
/// decoded) = it must. Guided generation's grammar is a oneOf
/// over call objects with no answer-directly branch, so it is the enforcement
/// mechanism and may switch on THIS predicate only. Gating it on the declaration
/// instead is what cost a declaring request its answer (measured 10-18:
/// `tools:[get_weather]` + "What is 2 + 2?" → `content:""`, `finish_reason:"stop"`,
/// while the no-tools control answered `4`). vllm/sglang keep the same split —
/// they parse whatever the model emitted and only force when told to.
func toolChoiceDemandsCall(_ toolChoice: String?) -> Bool {
    guard let toolChoice else { return false }
    return toolChoice == "required" || toolChoice.hasPrefix("function:")
}

/// The one home for "must this turn's output be grammar-constrained?".
///
/// Two faces assemble `InferenceOptions` themselves — the HTTP wire (`ChatHandler`) and
/// the SwiftUI fast path (`DirectInferenceClient`) — so the rule may not live in both.
/// Keyed to "tools present", a plain message arriving on a face that declares the whole
/// registry but cannot express a demand gets a calls-only grammar, and a question with no
/// sensible tool for it must still resolve into a call — to whichever registry tool the
/// grammar happens to prefer, twice running it was two different ones (CHANGELOG 10-18 续4).
///
/// So constraining follows a DEMAND, never the presence of a declaration: `tool_choice`
/// = `required`/pinned function (the client asked for a call), or a JSON
/// `response_format` (the client asked for JSON). Anything else — absent, `auto`, `none`,
/// and any face with no `tool_choice` surface yet, like the GUI — leaves the model free
/// to answer, with calls arriving through the parser/events path.
func shouldConstrainOutput(
    declaredTools: [ToolDef]?,
    responseFormat: ResponseFormat?,
    toolChoice: String?
) -> Bool {
    let hasJsonShape =
        responseFormat?.type == "json_schema" || responseFormat?.type == "json_object"
    return (declaredTools?.isEmpty == false && toolChoiceDemandsCall(toolChoice))
        || hasJsonShape
}

/// Build a JSON Schema string for GrammarConstraint from tool definitions.
/// Returns `nil` when no tools are provided.
///
/// Used by both the HTTP API layer (ChatHandler) and the UI fast path
/// (DirectInferenceClient) to enable GuidedGeneration grammar-constrained output.
/// When tools are present, the schema constrains the model to emit a valid
/// oneOf array of tool call objects — eliminating regex post-processing failures.
///
/// Named sub-schemas ($defs) in tool parameters are hoisted to the envelope
/// root with per-tool namespaced keys (<tool>__<def>) and $refs are rewritten
/// to match — preventing dangling pointers that cause xgrammar compilation failure.
/// (Mirrors upstream commit 1032402)
/// 递归扁平化 AnyCodable 嵌套 → JSON 原生 Any。
/// JSONSerialization 遇 AnyCodable struct (__SwiftValue) → NSException
/// (ObjC 异常不是 Swift Error,try? 接不住,进程死)。全深度递归剥壳。
func flattenJSONValue(_ v: Any) -> Any {
    if let c = v as? AnyCodable {
        return flattenJSONValue(c.value)
    }
    if let a = v as? [Any] {
        return a.map { flattenJSONValue($0) }
    }
    if let o = v as? [String: Any] {
        return o.mapValues { flattenJSONValue($0) }
    }
    return v
}

/// `tools[]` → JSON text in the shape templates and upstream `ToolSpec` consume:
/// `[{"type":"function","function":{name,description,parameters}}, …]`.
///
/// This is the caller's declaration verbatim (its description, its parameter
/// schema), so a tool this server does not register is still declarable to the
/// model instead of vanishing — see `InferenceOptions.declaredToolSpecsJSON`.
/// Values are flattened to JSON-native `Any` first (`AnyCodable` would reach
/// JSONSerialization as a `__SwiftValue` and raise an uncatchable ObjC exception).
/// nil/empty in → nil out: "no tools declared" is not an empty surface.
func openAIToolSpecsJSON(from defs: [ToolDef]?) -> String? {
    guard let defs, !defs.isEmpty else { return nil }
    let specs: [[String: Any]] = defs.map { def in
        var function: [String: Any] = ["name": def.function.name]
        if let description = def.function.description {
            function["description"] = description
        }
        if let parameters = def.function.parameters {
            function["parameters"] = flattenJSONValue(parameters)
        }
        return ["type": def.type, "function": function]
    }
    guard
        let data = try? JSONSerialization.data(withJSONObject: specs, options: []),
        let json = String(data: data, encoding: .utf8)
    else {
        return nil
    }
    return json
}

/// The schema for "give me JSON, but no shape is specified" — OpenAI's
/// `response_format: {"type":"json_object"}`, and any constrained turn that arrives
/// without a schema.
///
/// It must be `{"type":"object"}`, not `{"type":"object","properties":{}}`: naming
/// zero properties tells the grammar that no key is legal, so the only thing the model
/// may emit is the empty object. Measured on this host, same prompt, temperature 0 —
/// `json_object` returned `'{}'` in 2 completion tokens, while a `json_schema` turn
/// carrying `{"type":"object"}` returned `{"answer": 8, "unit": "planets"}` in 20,
/// and a schema with `"properties":{}` reproduced the empty reply exactly. A client
/// got valid JSON and no information, delivered as 200 OK with `finish_reason:"stop"`.
/// vllm and sglang both map this mode to `{"type":"object"}`
/// (`vllm/parser/abstract_parser.py:277`, `sglang/srt/entrypoints/openai/protocol.py:1191`).
let jsonObjectSchema = #"{"type":"object"}"#

func buildGrammarSchema(
    from tools: [ToolDef]?,
    responseFormat: ResponseFormat? = nil,
    toolChoice: String? = nil
) -> String? {
    // 递归剥壳见 `flattenJSONValue`(共享: grammar 与 tool-spec 两条路都必须
    // 把 AnyCodable 换成 JSON 原生 Any, 两处各写一份迟早漂移)。

    let toAny: ([String: AnyCodable]) -> [String: Any] = { dict in
        (flattenJSONValue(dict) as? [String: Any]) ?? [:]
    }

    // Which constraint wins. `shouldConstrainOutput` decided WHETHER this turn is
    // constrained; this decides WITH WHAT. A tool grammar goes on the wire only when
    // `tool_choice` demands a call — sglang installs one solely for `required`/named
    // choices (serving_chat.py:1488-1501) and calls the schema "response data"
    // (serving_chat.py:1349-1353). With a JSON `response_format` beside undeclared-as-demand
    // tools the JSON wins; the four orderings tried on this engine, and what each cost, are
    // recorded at the decision below.
    let jsonShapeAsked =
        responseFormat?.type == "json_schema" || responseFormat?.type == "json_object"
    var toolGrammar: [String: Any]?
    if let toolsDef = tools, !toolsDef.isEmpty {
        var hoistedDefs: [String: Any] = [:]
        let oneOf: [[String: Any]] = toolsDef.compactMap { tool in
            let funcDef = tool.function
            guard let params = funcDef.parameters else { return nil }

            // Hoist $defs to envelope root, rewrite $refs with per-tool namespace
            let hoistedParams = buildGrammarSchemaHoistDefs(
                in: toAny(params),
                toolName: funcDef.name,
                into: &hoistedDefs
            )

            return [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "const": funcDef.name],
                    "arguments": hoistedParams,
                ],
                "required": ["name", "arguments"],
            ]
        }
        guard !oneOf.isEmpty else { return nil }

        var envelope: [String: Any] = ["oneOf": oneOf]
        if !hoistedDefs.isEmpty {
            envelope["$defs"] = hoistedDefs
        }

        toolGrammar = ["type": "array", "items": envelope]
    }

    // The caller's JSON, resolved once. A schema-less `json_object` is an OPEN object —
    // naming zero properties is what used to make every `json_object` reply `{}`
    // (`jsonObjectSchema`).
    var jsonGrammar: [String: Any]?
    if jsonShapeAsked {
        // The open-object literal is the same decision as `jsonObjectSchema` (strict
        // concurrency will not host a `[String: Any]` global); `openObjectFormsAgree`
        // pins the two so they cannot drift apart.
        jsonGrammar = responseFormat?.jsonSchema.map { toAny($0.schema) } ?? ["type": "object"]
    }

    guard let tool = toolGrammar else {
        return jsonGrammar.flatMap { grammarSchemaString($0) }
    }
    guard let json = jsonGrammar else {
        return grammarSchemaString(tool)
    }
    if toolChoiceDemandsCall(toolChoice) {
        return grammarSchemaString(tool)
    }
    // Both channels asked, no demand: the JSON wins. Four shapes were run on this engine
    // and this is the only one that keeps a decidable promise (§6: keys arrive 3/3 with the
    // tools still declared, both shapes). The others each cost a channel — envelope-first
    // delivered the caller's JSON 0/3 with every turn ending `finish: tool_calls`; an
    // `anyOf` of both compiled and then reported the document finished after one brace
    // (`grammarTerm=true tokens=1`, content `'{'` / `'}'`); and no grammar at all fenced the
    // answer in ```json so the client could not parse it (3/3, probe 12 §6/§7). What JSON-first
    // still cannot do is ground the answer: a turn that must call a tool before it answers
    // cannot emit the call, measured by §7 — the gap is the loop's per-iteration grammar, not
    // an ordering, so it is recorded open rather than fixed by picking a different loser.
    return grammarSchemaString(json)
}

/// One home for "compile a grammar object into the string GuidedGeneration takes".
/// Internal, not private: `GrammarSchemaRegressionTests` pins that this is still the only
/// serialiser behind `jsonObjectSchema`, and that needs the function by name.
func grammarSchemaString(_ grammar: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: grammar, options: []) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

/// Hoist `$defs` from a tool parameter schema to the envelope root,
/// namespacing keys with `<toolName>__` and rewriting `$ref` pointers.
/// Mirrors upstream commit 1032402 — structure-aware rewrite that only
/// touches `$ref` values, leaving description/const/enum/pattern strings intact.
private func buildGrammarSchemaHoistDefs(
    in params: [String: Any],
    toolName: String,
    into hoistedDefs: inout [String: Any]
) -> [String: Any] {
    // Rewrite $refs in the entire tree first (before hoisting, since refs
    // can appear inside other $defs bodies)
    let rewritten =
        buildGrammarSchemaRewriteRefs(
            in: params as Any,
            toolName: toolName
        ) as? [String: Any] ?? params

    // Extract and remove $defs from the rewritten tree
    var result = rewritten
    if let defs = result.removeValue(forKey: "$defs") as? [String: Any] {
        for (key, value) in defs {
            hoistedDefs["\(toolName)__\(key)"] = value
        }
    }
    return result
}

/// Recursively rewrite `"$ref": "#/$defs/<name>"` → `"#/$defs/<toolName>__<name>"`
/// in a parsed JSON schema tree. Structure-aware: only rewrites string values
/// directly under `$ref` keys, so other strings survive verbatim.
private func buildGrammarSchemaRewriteRefs(
    in value: Any,
    toolName: String
) -> Any {
    switch value {
    case let object as [String: Any]:
        var result: [String: Any] = [:]
        result.reserveCapacity(object.count)
        for (key, nested) in object {
            if key == "$ref", let ref = nested as? String, ref.hasPrefix("#/$defs/") {
                result[key] = "#/$defs/\(toolName)__" + String(ref.dropFirst(8))
            } else {
                result[key] = buildGrammarSchemaRewriteRefs(in: nested, toolName: toolName)
            }
        }
        return result
    case let array as [Any]:
        return array.map { buildGrammarSchemaRewriteRefs(in: $0, toolName: toolName) }
    default:
        return value
    }
}
