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

	/// Enable post-inference self-correction pipeline
	var selfCorrection: Bool? = false

	/// Enable deep reasoning mode (三思而后行) — multi-step reasoning scaffold
	var reasoning: Bool? = false

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
		case selfCorrection
		case reasoning
	}

	init(
		model: String = "default",
		messages: [Message],
		temperature: Float = 0.7,
		topP: Float? = nil,
		topK: Int? = nil,
		maxTokens: Int? = nil,
		responseFormat: ResponseFormat? = nil,
		stream: Bool = false,
		stop: [String]? = nil,
		frequencyPenalty: Float = 0,
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
		model = try c.decodeIfPresent(String.self, forKey: .model) ?? "default"
		messages = try c.decode([Message].self, forKey: .messages)
		temperature = try c.decodeIfPresent(Float.self, forKey: .temperature) ?? 0.7
		stream = (try? c.decodeIfPresent(Bool.self, forKey: .stream)) ?? false
		stop = try c.decodeIfPresent([String].self, forKey: .stop)
		system = try c.decodeIfPresent(String.self, forKey: .system)
		topP = try c.decodeIfPresent(Float.self, forKey: .topP)
		topK = try c.decodeIfPresent(Int.self, forKey: .topK)
		maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
		responseFormat = try c.decodeIfPresent(ResponseFormat.self, forKey: .responseFormat)
		frequencyPenalty = (try? c.decodeIfPresent(Float.self, forKey: .frequencyPenalty)) ?? 0
		presencePenalty = (try? c.decodeIfPresent(Float.self, forKey: .presencePenalty)) ?? 0
		sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
		tools = try c.decodeIfPresent([ToolDef].self, forKey: .tools)
		toolChoice = try c.decodeIfPresent(String.self, forKey: .toolChoice)
		parallelToolCalls = try c.decodeIfPresent(Bool.self, forKey: .parallelToolCalls)
		reasoning = try c.decodeIfPresent(Bool.self, forKey: .reasoning)
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
			guard let toolArray = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
				return nil
			}

			var toolCalls: [ToolCall] = []
			for toolObj in toolArray {
				guard let name = toolObj["name"] as? String,
				      let args = toolObj["arguments"] else { continue }

				let argsJson: String
				if let argsStr = args as? String {
					argsJson = argsStr
				} else if args is NSNull {
					argsJson = "{}"
				} else {
					argsJson = (try? String(data: JSONSerialization.data(
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

	/// Simple string content initializer.
	init(role: String, content: String) {
		self.role = role
		self.content = .text(content)
		name = nil
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
		case let .text(s): try container.encode(s)
		case let .parts(p): try container.encode(p)
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

/// Multi-part message part types (text + image_url + audio).
struct ContentPart: Codable {
	/// Part type: "text" | "image_url" | "audio"
	let type: String

	/// Text content (if applicable)
	let text: String?

	/// Image URL reference (if applicable)
	let imageUrl: ImageURL?

	/// Audio URL reference (if applicable)
	var audioURL: AudioURL? = nil

	/// Image URL wrapper.
	struct ImageURL: Codable {
		/// URL string (http/https or base64 data URL)
		let url: String
	}

	/// Audio URL wrapper.
	struct AudioURL: Codable {
		/// URL string (http/https or local file path)
		let url: String
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
}

/// Single choice inside ``ChatCompletion``.
struct CompletionChoice: Encodable {
	/// Assistant's message
	let message: AssistantMessage

	/// Generation finish reason ("stop", "length", "tool_calls", etc.)
	let finishReason: String

	/// Choice index
	let index: Int = 0
}

/// Assistant message with optional tool calls.
struct AssistantMessage: Encodable {
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
struct Usage: Encodable {
	/// Input (prompt) token count
	let input: Int

	/// Output (completion) token count
	let output: Int

	/// Total token count
	let total: Int

	init(input: Int, output: Int) {
		self.input = input
		self.output = output
		total = input + output
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

#if canImport(CoreAI) && !OCOREAI_DISABLE_COREAI
	/// Convert ``CoreAILanguageModels/StopReason`` to OpenAI-compatible finish_reason string.
	///
	/// - Parameter reason: Stop reason from inference engine
	/// - Returns: "stop", "length", "stop_sequence", "cancelled", "error", or nil
	func stopReasonToString(_ reason: StopReason?) -> String? {
		guard let reason else { return nil }
		switch reason {
		case .maxTokens: return "length"
		case .eos: return "stop"
		case .stopSequence: return "stop_sequence"
		case .cancelled: return "cancelled"
		case .error: return "error"
		}
	}
#else
	/// Convert ``StopReason`` to OpenAI-compatible finish_reason string.
	///\n
	/// - Parameter reason: Stop reason from inference engine
	/// - Returns: "stop", "length", "stop_sequence", "cancelled", "error", or nil
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
		case .stopSequence: return "stop_sequence"
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
}

/// Single delta choice inside ``ChatCompletionChunk``.
struct ChunkChoice: Encodable {
	/// Incremental content delta
	let delta: ChatDelta

	/// Finish reason (null during stream, set on last chunk)
	let finishReason: String?

	/// Choice index
	let index: Int = 0
}

/// Incremental content delta for SSE streaming.
struct ChatDelta: Encodable {
	/// Role (only set in first chunk)
	var role: String?

	/// Text content delta
	var content: String?

	/// Tool calls delta (if model is requesting tool execution)
	var toolCalls: [ToolCall]?
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

	/// Presence penalty
	var presencePenalty: Float = 0

	/// Response format override ("text" | "json_object")
	var responseFormat: String? = nil

	/// System default configuration
	static let `default`: ModelSamplingConfig = .init()

	/// Test whether this config is all-defaults (useful to mark "customized" state)
	var isDefault: Bool {
		temperature == 0.7 && topP == nil && topK == nil && maxTokens == nil
			&& frequencyPenalty == 0 && presencePenalty == 0 && responseFormat == nil
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

/// PATCH body — partial sampling config update (all fields optional).
struct ModelSamplingPatch: Decodable {
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
struct ModelSamplingResponse: Encodable {
	let temperature: Float
	let topP: Float?
	let topK: Int?
	let maxTokens: Int?
	let frequencyPenalty: Float
	let presencePenalty: Float
	let responseFormat: String?

	/// Initialize from ``ModelSamplingConfig``.
	init(config: ModelSamplingConfig) {
		temperature = config.temperature
		topP = config.topP
		topK = config.topK
		maxTokens = config.maxTokens
		frequencyPenalty = config.frequencyPenalty
		presencePenalty = config.presencePenalty
		responseFormat = config.responseFormat
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

	/// Service Unavailable — BlockPool exhausted and unable to evict
	case blockPoolExhausted

	/// Service Unavailable — session limit exceeded
	case sessionLimitExceeded

	/// Service Unavailable — memory pressure threshold exceeded
	case memoryPressure

	/// Not Found — session not found in PagedKVCache
	case sessionNotFound(String)

	/// ``CustomStringConvertible`` description (used in logs)
	var description: String {
		switch self {
		case let .invalidRequest(msg): "Invalid request: \(msg)"
		case let .modelNotFound(name): "Model \(name) not found"
		case let .poolExhausted(max): "Engine pool exhausted (max: \(max))"
		case .queueClosed: "Request queue closed"
		case let .coldStoreNotFound(id): "Cold store entry \(id) not found"
		case let .generationError(msg): "Generation failed: \(msg)"
		case let .kvCacheCorruption(msg): "KV cache corruption: \(msg)"
		case .engineUnavailable: "Engine unavailable"
		case let .inferenceFailed(msg): "Inference failed: \(msg)"
		case let .tokenizationFailed(msg): "Tokenization failed: \(msg)"
		case let .toolCallFailed(msg): "Tool call failed: \(msg)"
		case let .sessionExpired(id): "Session \(id) expired"
		case .blockPoolExhausted: "BlockPool exhausted — unable to evict"
		case .sessionLimitExceeded: "Session limit exceeded"
		case .memoryPressure: "Memory pressure threshold exceeded"
				case .sessionNotFound: "Session not found"
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
		case .invalidRequest, .toolCallFailed:
			.badRequest
		case .modelNotFound, .coldStoreNotFound, .sessionNotFound:
			.notFound
		case .poolExhausted, .queueClosed, .engineUnavailable,
		     .blockPoolExhausted, .sessionLimitExceeded, .memoryPressure:
			.serviceUnavailable
		case .sessionExpired:
			.gone
		case .generationError, .kvCacheCorruption, .inferenceFailed, .tokenizationFailed:
			.internalServerError
		}
	}

	/// ``HTTPResponseError.response(from:context:)`` — build a JSON error response.
	nonisolated func response(
		from request: Request,
		context: some RequestContext
	) throws -> Response {
		let detail = NSDictionary(dictionary: [
			"message": errorDescription ?? String(describing: self),
			"type": "app_error",
			"code": status.code,
		])
		let errorBody = NSDictionary(dictionary: ["error": detail])
		var headers: HTTPFields = [:]
		headers[.contentType] = "application/json"
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

/// Build a JSON Schema string for GrammarConstraint from tool definitions.
/// Returns `nil` when no tools are provided.
///
/// Used by both the HTTP API layer (ChatHandler) and the UI fast path
/// (DirectInferenceClient) to enable GuidedGeneration grammar-constrained output.
/// When tools are present, the schema constrains the model to emit a valid
/// oneOf array of tool call objects — eliminating regex post-processing failures.
func buildGrammarSchema(
	from tools: [ToolDef]?,
	responseFormat: ResponseFormat? = nil
) -> String? {
	// Helper: convert [String: AnyCodable] → [String: Any] for JSONSerialization
	let toAny: ([String: AnyCodable]) -> [String: Any] = { dict in
		Dictionary(uniqueKeysWithValues: dict.map { ($0, $1.value) })
	}

	// Tools path: build function_call-style schema
	if let toolsDef = tools, !toolsDef.isEmpty {
		let functionSchemas: [[String: Any]] = toolsDef.compactMap { tool in
			let funcDef = tool.function
			guard let params = funcDef.parameters else { return nil }
			return [
				"type": "object",
				"properties": [
					"name": ["type": "string", "const": funcDef.name],
					"arguments": toAny(params),
				],
				"required": ["name", "arguments"],
			]
		}
		guard !functionSchemas.isEmpty,
			  let data = try? JSONSerialization.data(
				withJSONObject: [
					"type": "array",
					"items": ["oneOf": functionSchemas],
				],
				options: []
			  ), let s = String(data: data, encoding: .utf8) else {
			return nil
		}
		return s
	}

	// JSON schema path: passthrough or fallback
	if let responseFmt = responseFormat,
	   (responseFmt.type == "json_schema" || responseFmt.type == "json_object") {
		if let schemaReq = responseFmt.jsonSchema,
		   let data = try? JSONSerialization.data(
			withJSONObject: toAny(schemaReq.schema),
			options: []
		   ), let s = String(data: data, encoding: .utf8) {
			return s
		}
		// Generic JSON object fallback
		return "{\"type\":\"object\",\"properties\":{}}"
	}
	return nil
}
