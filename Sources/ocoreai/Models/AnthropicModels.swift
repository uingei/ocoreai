// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AnthropicModels.swift — Anthropic Messages API compatible DTOs
///
/// Anthropic API format differs from OpenAI:
/// - ``system`` is a top-level field, not a message role
/// - Stop reasons differ: "end_turn", "max_tokens", "stop_sequence", "tool_use"
/// - Usage tracking with `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`
/// - Tool definitions use Anthropic schema format
///
/// ### Mapping Strategy:
/// - Anthropic request → internal ``ChatCompletionRequest`` → existing inference handler
/// - Internal response → Anthropic response envelope
///
/// Key differences from OpenAI format:
/// | Field | OpenAI | Anthropic |
/// |-------|--------|-----------|
/// | System prompt | messages[role:"system"] | request.system (top-level) |
/// | Finish reason | finish_reason | stop_reason |
/// | Tool calls | message.tool_calls | content[{"type":"tool_use"}] |
/// | Response format | choices[].message | content[] array |

import Foundation

// MARK: - Request Models

/// Anthropic Messages API request — ``POST /v1/messages``
struct AnthropicMessageRequest: Sendable, Decodable {
    /// Model identifier
    let model: String

    /// System prompt (separate from messages — Anthropic convention)
    let system: String?

    /// Message array (no system role — system goes in top-level field)
    let messages: [AnthropicMessage]

    /// Temperature (0.0–1.0, Anthropic default 1.0)
    var temperature: Float? = nil

    /// Top-p nucleus sampling
    var topP: Float? = nil

    /// Top-k sampling
    var topK: Int? = nil

    /// Maximum output tokens
    var maxTokens: Int? = nil

    /// Stop sequences
    var stopSequences: [String]? = nil

    /// Tool definitions (Anthropic format)
    var tools: [AnthropicTool]? = nil

    /// Tool choice strategy
    var toolChoice: AnthropicToolChoice? = nil

    /// Enable streaming
    var stream: Bool = false

    /// Response format (for structured output)
    var responseFormat: AnthropicResponseFormat? = nil

    /// Thinking configuration (for reasoning models)
    var thinking: AnthropicThinkingConfig? = nil

    /// Metadata for user/session tracking
    var metadata: AnthropicMetadata? = nil

    /// Anthropic-specific coding keys
    enum CodingKeys: String, CodingKey {
        case model, system, messages, temperature, stream, tools
        case topP = "top_p"
        case topK = "top_k"
        case maxTokens = "max_tokens"
        case stopSequences = "stop_sequences"
        case toolChoice = "tool_choice"
        case responseFormat = "response_format"
        case thinking, metadata
    }
}

/// Anthropic message — no `system` role, system prompt is top-level.
struct AnthropicMessage: Sendable, Decodable {
    /// Role: "user" | "assistant"
    let role: String

    /// Content: plain text or array of content blocks
    let content: AnthropicContent?

    enum CodingKeys: String, CodingKey {
        case role, content
    }
}

/// Anthropic content — text, tool_use, or tool_result
enum AnthropicContent: Sendable, Decodable {
    case text(String)
    case blocks([AnthropicContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .text(s)
        } else if let blocks = try? container.decode([AnthropicContentBlock].self) {
            self = .blocks(blocks)
        } else {
            self = .text("")
        }
    }
}

/// Single content block inside an assistant message
struct AnthropicContentBlock: Sendable, Decodable {
    enum BlockType: String, Decodable {
        case text
        case toolUse = "tool_use"
    }

    let type: BlockType
    let text: String?
    let id: String?
    let name: String?
    let input: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
    }
}

// MARK: - Response Models

/// Anthropic Messages API response — ``POST /v1/messages``
struct AnthropicMessageResponse: Sendable, Encodable {
    let id: String
    let `type`: String = "message"
    let role: String = "assistant"
    let content: [AnthropicAssistantContent]
    let model: String
    let stopReason: String?
    let usage: AnthropicUsage

    enum CodingKeys: String, CodingKey {
        case id, type, role, content, model
        case stopReason = "stop_reason"
        case usage
    }
}

/// Assistant message content block
struct AnthropicAssistantContent: Sendable, Encodable {
    let type: String
    let text: String?

    init(text: String) {
        self.type = "text"
        self.text = text
    }
}

/// Anthropic-specific token usage tracking
struct AnthropicUsage: Sendable, Encodable {
    let inputTokens: Int
    let outputTokens: Int

    /// Cache creation tokens (reserved for future cache feature)
    let cacheCreationInputTokens: Int? = nil

    /// Cache read tokens (reserved for future cache feature)
    let cacheReadInputTokens: Int? = nil

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

// MARK: - SSE Streaming

/// Anthropic SSE stream event
struct AnthropicStreamEvent: Sendable, Encodable {
    let type: String
    let index: Int?
    let message: AnthropicMessageResponse?
    let delta: AnthropicStreamDelta?
    let usage: AnthropicStreamUsage?

    /// Stream start event
    static func messageStart(message: AnthropicMessageResponse) -> AnthropicStreamEvent {
        AnthropicStreamEvent(type: "message_start", index: nil, message: message, delta: nil, usage: nil)
    }

    /// Content block start event
    static func contentBlockStart(index: Int) -> AnthropicStreamEvent {
        AnthropicStreamEvent(type: "content_block_start", index: index, message: nil, delta: nil, usage: nil)
    }

    /// Delta event (incremental text)
    static func textDelta(index: Int, text: String) -> AnthropicStreamEvent {
        AnthropicStreamEvent(type: "content_block_delta", index: index, message: nil,
            delta: AnthropicStreamDelta(type: "content_block_delta", partialJson: nil, text: text),
            usage: nil)
    }

    /// Content block stop event
    static func contentBlockStop(index: Int) -> AnthropicStreamEvent {
        AnthropicStreamEvent(type: "content_block_stop", index: index, message: nil, delta: nil, usage: nil)
    }

    /// Message stop event (with final usage)
    static func messageStop(inputTokens: Int, outputTokens: Int) -> AnthropicStreamEvent {
        AnthropicStreamEvent(type: "message_stop", index: nil, message: nil, delta: nil,
            usage: AnthropicStreamUsage(outputTokens: outputTokens, inputTokens: inputTokens))
    }
}

/// Incremental delta inside SSE stream
struct AnthropicStreamDelta: Sendable, Encodable {
    let type: String
    let partialJson: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case type
        case partialJson = "partial_json"
        case text
    }
}

/// Usage in the final stream event
struct AnthropicStreamUsage: Sendable, Encodable {
    let outputTokens: Int
    let inputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

// MARK: - Tool Definitions (Anthropic format)

/// Anthropic tool definition
struct AnthropicTool: Sendable, Decodable {
    let name: String
    let description: String?
    let inputSchema: AnthropicToolInputSchema?

    /// Convert Anthropic tool to OpenAI ToolDef for internal reuse
    func toOpenAITool() -> ToolDef {
        let funcDef = FunctionDef(
            name: name,
            description: description,
            parameters: inputSchema?.toOpenAIParameters()
        )
        return ToolDef(type: "function", function: funcDef)
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

/// Anthropic tool input schema (JSON Schema)
struct AnthropicToolInputSchema: Sendable, Decodable {
    let type: String = "object"
    let properties: [String: AnyCodable]? = nil
    let required: [String]? = nil

    func toOpenAIParameters() -> [String: AnyCodable]? {
        guard let properties = properties else { return nil }
        return properties
    }
}

/// Tool choice strategy
struct AnthropicToolChoice: Sendable, Decodable {
    let type: String  // "auto" | "any" | "none" | "tool"

    enum CodingKeys: String, CodingKey {
        case type
    }
}

// MARK: - Response Format

/// Anthropic response format for structured output
struct AnthropicResponseFormat: Sendable, Decodable {
    let type: String  // "json"

    enum CodingKeys: String, CodingKey {
        case type
    }
}

// MARK: - Thinking Config

/// Thinking/reasoning model configuration
struct AnthropicThinkingConfig: Sendable, Decodable {
    let type: String
    let budgetTokens: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }
}

// MARK: - Metadata

/// User/session metadata
struct AnthropicMetadata: Sendable, Decodable {
    let userId: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case sessionId = "session_id"
    }
}

// MARK: - Conversion Helpers

/// Convert Anthropic request to internal ChatCompletionRequest
func toChatCompletionRequest(_ req: AnthropicMessageRequest) -> ChatCompletionRequest {
    // Convert messages
    let messages: [Message] = req.messages.map { msg in
        let content: ContentPolymorphic?
        switch msg.content {
        case .some(.text(let s)):
            content = .text(s)
        case .some(.blocks(let blocks)):
            let texts = blocks.compactMap {
                switch $0.type {
                case .text: return $0.text
                case .toolUse: return nil  // Skip tool_use blocks from user
                }
            }.joined(separator: "\n")
            content = texts.isEmpty ? nil : .text(texts)
        case .none:
            content = nil
        }
        return Message(role: msg.role, content: content)
    }

    // Convert tools
    let tools: [ToolDef]? = req.tools?.map { $0.toOpenAITool() }

    return ChatCompletionRequest(
        model: req.model,
        messages: messages,
        temperature: req.temperature ?? 0.7,
        topP: req.topP,
        topK: req.topK,
        maxTokens: req.maxTokens,
        responseFormat: nil,
        stream: req.stream,
        stop: req.stopSequences,
        frequencyPenalty: 0,
        presencePenalty: 0,
        sessionID: req.metadata?.sessionId,
        system: req.system,
        tools: tools,
        toolChoice: nil,
        parallelToolCalls: true
    )
}

/// Convert Anthropic stop_reason to OpenAI finish_reason
func anthropicToOpenAIFinishReason(_ reason: String) -> String {
    switch reason {
    case "end_turn": return "stop"
    case "max_tokens": return "length"
    case "stop_sequence": return "stop"
    case "tool_use": return "tool_calls"
    case "error": return "error"
    default: return "stop"
    }
}

/// Convert OpenAI finish_reason to Anthropic stop_reason
func openAIToAnthropicStopReason(_ reason: String) -> String {
    switch reason {
    case "stop": return "end_turn"
    case "length": return "max_tokens"
    case "tool_calls": return "tool_use"
    case "cancelled", "error": return reason
    default: return "end_turn"
    }
}
