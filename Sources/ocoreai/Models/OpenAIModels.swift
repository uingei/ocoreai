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
struct ChatCompletionRequest: Sendable, Decodable {
    /// Model identifier (defaults to "default")
    var model: String = "default"

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

    /// JSON schema for response format override
    var responseFormat: ResponseFormat? = nil

    // MARK: Stream Control

    /// Enable Server-Sent Events streaming
    var stream: Bool = false

    /// Stop sequences (generation halts when matched)
    var stop: [String]? = nil

    /// Frequency penalty (penalize repeated tokens)
    var frequencyPenalty: Float = 0

    /// Presence penalty (penalize tokens already in output)
    var presencePenalty: Float = 0

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

    // MARK: - Snake-Case Key Mapping (OpenAI API compat)

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream, stop, system
        case topP = "top_p"
        case topK = "top_k"
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case sessionID = "session_id"
        case tools, toolChoice
        case parallelToolCalls = "parallel_tool_calls"
    }
}

// MARK: - Response Format (Structured Output)

/// Response format configuration for structured output (JSON Mode).
///
/// When ``type`` is "json_object", the model is instructed to output valid JSON.
struct ResponseFormat: Sendable, Decodable {
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
struct JSONSchemaRequest: Sendable, Decodable {
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
struct AnyCodable: Codable, Equatable, @unchecked Sendable {
    /// Wrapped dynamic value
    var value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { value = b }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let s = try? container.decode(String.self) { value = s }
        else if let a = try? container.decode([AnyCodable].self) { value = a }
        else if let o = try? container.decode([String: AnyCodable].self) { value = o }
        else { value = NSNull() }
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
        default: try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        lhs.value as? Data == rhs.value as? Data ||
        lhs.value as? String == rhs.value as? String ||
        lhs.value is NSNull && rhs.value is NSNull
    }
}

// MARK: - Tool Definitions

/// Tool definition (function schema) — describes what tools the model can call.
///
/// Sent in ``ChatCompletionRequest/tools`` to enable function calling.
struct ToolDef: Sendable, Codable {
    /// Tool type (always "function" for function calling)
    var type: String = "function"

    /// Function schema (name, description, parameters)
    let function: FunctionDef
}

/// Function definition inside a ``ToolDef``.
struct FunctionDef: Sendable, Codable {
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
struct ToolCall: Sendable, Codable {
    /// Unique call identifier
    let id: String

    /// Call type (always "function")
    var type: String = "function"

    /// Function invocation details
    let function: ToolCallFunction
}

/// Function invocation details inside a ``ToolCall``.
struct ToolCallFunction: Sendable, Codable {
    /// Function name to invoke
    let name: String

    /// JSON arguments string (parsed from model output)
    let arguments: String

    enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }
}

// MARK: - Message (Multi-Role + Content Polymorphism + Tool Calls)

/// Chat message supporting all roles: system, user, assistant, tool.
///
/// ``ContentPolymorphic`` allows either plain text or multi-part content
/// (text + image_url + audio) inside a single message.
struct Message: Sendable, Codable {
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

    /// Simple string content initializer.
    init(role: String, content: String) {
        self.role = role
        self.content = .text(content)
        self.name = nil
    }

    /// Full initializer with all fields.
    init(role: String, content: ContentPolymorphic? = nil, name: String? = nil, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil) {
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
enum ContentPolymorphic: Sendable, Codable {
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

/// Single content part inside a multi-part message.
struct ContentPart: Sendable, Codable {
    /// Part type: "text" | "image_url" | "audio"
    let type: String

    /// Text content (if applicable)
    let text: String?

    /// Image URL reference (if applicable)
    let imageUrl: ImageURL?

    /// Image URL wrapper.
    struct ImageURL: Sendable, Codable {
        /// URL string (http/https or base64 data URL)
        let url: String
    }
}

// MARK: - Response Models

/// Non-streaming chat completion response (matches OpenAI API format).
struct ChatCompletion: Sendable, Encodable {
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
}

/// Single choice inside ``ChatCompletion``.
struct CompletionChoice: Sendable, Encodable {
    /// Assistant's message
    let message: AssistantMessage

    /// Generation finish reason ("stop", "length", "tool_calls", etc.)
    let finishReason: String

    /// Choice index
    let index: Int = 0
}

/// Assistant message with optional tool calls.
struct AssistantMessage: Sendable, Encodable {
    /// Role identifier (always "assistant")
    let role: String = "assistant"

    /// Text content
    let content: String?

    /// Tool call invocations (if model requested tools)
    let toolCalls: [ToolCall]?

    init(content: String, toolCalls: [ToolCall]? = nil) {
        self.content = content
        self.toolCalls = toolCalls
    }
}

/// Token usage statistics (prompt + completion + total).
struct Usage: Sendable, Encodable {
    /// Input (prompt) token count
    let input: Int

    /// Output (completion) token count
    let output: Int

    /// Total token count
    let total: Int

    init(input: Int, output: Int) {
        self.input = input
        self.output = output
        self.total = input + output
    }

    /// Coding keys matching OpenAI API field names.
    enum CodingKeys: String, CodingKey {
        case input = "prompt_tokens"
        case output = "completion_tokens"
        case total = "total_tokens"
    }
}

/// Backward compatibility aliases.
typealias ChatCompletionResponse = ChatCompletion
typealias Choice = CompletionChoice

// MARK: - SSE Streaming

#if coreai
/// Convert ``CoreAILanguageModels/StopReason`` to OpenAI-compatible finish_reason string.
///
/// - Parameter reason: Stop reason from inference engine
/// - Returns: "stop", "length", "stop_sequence", "cancelled", "error", or nil
func stopReasonToString(_ reason: StopReason?) -> String? {
    guard let reason = reason else { return nil }
    switch reason {
    case .maxTokens: return "length"
    case .eos: return "stop"
    case .stopSequence: return "stop_sequence"
    case .cancelled: return "cancelled"
    case .error: return "error"
    }
}
#else
/// Stub: return "stop" when CoreAI trait is not enabled
func stopReasonToString(_ reason: StopReason?) -> String? {
    "stop"
}
#endif

/// SSE streaming chunk (incremental delta inside ``POST /v1/chat/completions`` stream).
struct ChatCompletionChunk: Sendable, Encodable {
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
}

/// Single delta choice inside ``ChatCompletionChunk``.
struct ChunkChoice: Sendable, Encodable {
    /// Incremental content delta
    let delta: ChatDelta

    /// Finish reason (null during stream, set on last chunk)
    let finishReason: String?

    /// Choice index
    let index: Int = 0
}

/// Incremental content delta for SSE streaming.
struct ChatDelta: Sendable, Encodable {
    /// Role (only set in first chunk)
    var role: String?

    /// Text content delta
    var content: String?

    /// Tool calls delta (if model is requesting tool execution)
    var toolCalls: [ToolCall]? = nil
}

// MARK: - Runtime Parameter Hot-Swap DTOs

/// Per-model runtime sampling defaults — hot-swappable via PATCH endpoint.
///
/// Lives in ``EnginePool`` and cascades: request body > this config > system default.
struct ModelSamplingConfig: Sendable, Codable {
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

    /// Presence penalty
    var presencePenalty: Float = 0

    /// Response format override ("text" | "json_object")
    var responseFormat: String? = nil

    /// System default configuration
    static let `default`: ModelSamplingConfig = .init()

    // MARK: - Snake-Case Key Mapping (OpenAI API compat for PATCH)

    enum CodingKeys: String, CodingKey {
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case maxTokens = "max_tokens"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case responseFormat = "response_format"
    }
}

/// PATCH body — partial sampling config update (all fields optional).
struct ModelSamplingPatch: Sendable, Decodable {
    var temperature: Float? = nil
    var topP: Float? = nil
    var topK: Int? = nil
    var maxTokens: Int? = nil
    var frequencyPenalty: Float? = nil
    var presencePenalty: Float? = nil
    var responseFormat: String? = nil

    /// Merge partial fields into a full ``ModelSamplingConfig``.
    func toConfig() -> ModelSamplingConfig {
        var config = ModelSamplingConfig.default
        if let t = temperature { config.temperature = t }
        if let p = topP { config.topP = p }
        if let k = topK { config.topK = k }
        if let m = maxTokens { config.maxTokens = m }
        if let f = frequencyPenalty { config.frequencyPenalty = f }
        if let p = presencePenalty { config.presencePenalty = p }
        if let r = responseFormat { config.responseFormat = r }
        return config
    }

    // MARK: - Snake-Case Key Mapping (OpenAI API compat for PATCH)

    enum CodingKeys: String, CodingKey {
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case maxTokens = "max_tokens"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case responseFormat = "response_format"
    }
}

/// GET response — full runtime sampling config for a single model.
struct ModelSamplingResponse: Sendable, Encodable {
    let temperature: Float
    let topP: Float?
    let topK: Int?
    let maxTokens: Int?
    let frequencyPenalty: Float
    let presencePenalty: Float
    let responseFormat: String?

    /// Initialize from ``ModelSamplingConfig``.
    init(config: ModelSamplingConfig) {
        self.temperature = config.temperature
        self.topP = config.topP
        self.topK = config.topK
        self.maxTokens = config.maxTokens
        self.frequencyPenalty = config.frequencyPenalty
        self.presencePenalty = config.presencePenalty
        self.responseFormat = config.responseFormat
    }
}

// MARK: - Application Errors (LocalizedError + Sendable)

/// Centralized application error type implementing ``LocalizedError``.
///
/// Each case maps to an HTTP status code and a structured error description
/// for consistent JSON error responses across all endpoints.
enum AppError: Error, CustomStringConvertible, LocalizedError {
    /// Bad Request — client sent malformed data
    case invalidRequest(String)

    /// Not Found — model does not exist or is not loaded
    case modelNotFound(String)

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

    /// Internal Error — inference pipeline failed
    case inferenceFailed(String)

    /// Internal Error — tokenization pipeline failed
    case tokenizationFailed(String)

    /// Bad Request — tool call validation/execution failed
    case toolCallFailed(String)

    /// Gone — session expired or invalidated
    case sessionExpired(String)

    /// ``CustomStringConvertible`` description (used in logs)
    var description: String {
        switch self {
        case .invalidRequest(let msg): return "Invalid request: \(msg)"
        case .modelNotFound(let name): return "Model \(name) not found"
        case .poolExhausted(let max): return "Engine pool exhausted (max: \(max))"
        case .queueClosed: return "Request queue closed"
        case .coldStoreNotFound(let id): return "Cold store entry \(id) not found"
        case .generationError(let msg): return "Generation failed: \(msg)"
        case .kvCacheCorruption(let msg): return "KV cache corruption: \(msg)"
        case .engineUnavailable: return "Engine unavailable"
        case .inferenceFailed(let msg): return "Inference failed: \(msg)"
        case .tokenizationFailed(let msg): return "Tokenization failed: \(msg)"
        case .toolCallFailed(let msg): return "Tool call failed: \(msg)"
        case .sessionExpired(let id): return "Session \(id) expired"
        }
    }

    /// ``LocalizedError`` error description (used in JSON error responses)
    var errorDescription: String? { description }
}