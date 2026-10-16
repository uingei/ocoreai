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
struct AnthropicMessageRequest: Decodable {
    /// Model identifier
    let model: String

    /// System prompt (separate from messages — Anthropic convention)
    ///
    /// Spec-legal as a plain string OR an array of text blocks (the block form
    /// is what SDKs emit when a system block carries `cache_control`), so the
    /// field carries both: see ``AnthropicSystemContent``.
    let system: AnthropicSystemContent?

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

    /// Enable streaming — optional per the Anthropic Messages spec (absent means
    /// false), so it is `Bool?` here. The synthesized decoder in this target
    /// requires every non-Optional key, which rejected spec-legal clients: live
    /// 10-13 `POST /v1/messages` with `{model, max_tokens, messages}` answered
    /// 400 "Coding key `stream` not found." `ChatCompletionRequest` avoids this
    /// by hand-decoding the field (`OpenAIModels.swift:240`). Consumers already
    /// read it as tri-state (`AnthropicMessagesHandler.swift:250` == true).
    var stream: Bool? = nil

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
struct AnthropicMessage: Decodable {
    /// Role: "user" | "assistant"
    let role: String

    /// Content: plain text or array of content blocks
    let content: AnthropicContent?

    enum CodingKeys: String, CodingKey {
        case role, content
    }
}

/// Anthropic content — a plain string, or an array of blocks.
///
/// The array branch decodes *every* block type (see ``AnthropicContentBlock``): the closed
/// element enum it used to have made one unrecognised block fail the whole array, and the
/// fallback below then blanked the message. The fallback stays for shapes that are neither
/// string nor array, but with a total element decoder it can no longer be reached by a
/// spec-legal block, and ``AnthropicMessage/toInternalMessage()`` turns anything left
/// unreadable into a refusal rather than an empty turn.
enum AnthropicContent: Decodable {
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

/// Anthropic `system` field — string | array of text blocks.
///
/// The synthesized decoder for `let system: String?` accepted only the string
/// form, so a spec-legal block array (`[{"type":"text","text":"…"}]` — what the
/// SDKs emit when a system block carries `cache_control`) made the whole
/// `/v1/messages` body fail to decode. Same family as this repo's `stream` and
/// `max_frames` findings: a field the spec calls polymorphic must decode both
/// shapes. Pinned by `AnthropicRequestDecodeTests`.
///
/// Same non-throwing fallback discipline as ``AnthropicContent``: an
/// unrecognizable value becomes empty text, so the caller reports "nothing to
/// count" instead of producing a count out of garbage.
enum AnthropicSystemContent: Decodable {
    case text(String)
    case blocks([AnthropicContentBlock])

    /// Flattened text of the field (text blocks joined by newlines).
    var text: String {
        switch self {
        case .text(let s): return s
        case .blocks(let blocks):
            return blocks.compactMap { block in
                block.type == "text" ? block.text : nil
            }.joined(separator: "\n")
        }
    }

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

/// One content block inside a message's `content` array.
///
/// `type` is deliberately a raw `String`, not a closed enum. With `type` typed as
/// `enum BlockType { case text, toolUse }`, any other spec-legal block — `image`,
/// `document`, `tool_result`, or a type invented after this build — failed to decode, and
/// array decoding is all-or-nothing, so ``AnthropicContent``'s fallback turned the WHOLE
/// message into `.text("")`. Measured 10-15 (`scripts/probes/07-anthropic-blocks.sh`): a
/// `[text, image]` message reached the model as an empty turn — HTTP 200,
/// `usage.input_tokens` 10 against 22 for the same instruction sent as a plain string, and
/// the answer "Please provide the input you would like me to process." A client cannot
/// distinguish that from a model with nothing to say, and `tool_result` — the shape
/// Anthropic's own SDK requires to continue a tool loop — went down the same path.
///
/// So every block decodes, and the decision lives in exactly one place
/// (``AnthropicMessage/toInternalMessage()``): carry what the engine can carry, refuse by
/// name what it cannot. An unknown type is then *representable* instead of destructive,
/// which is also what stops a future Anthropic block type from blanking a working request.
struct AnthropicContentBlock: Decodable {
    /// Block type exactly as the client wrote it.
    let type: String

    /// `text` payload.
    let text: String?

    /// `tool_use` identifier and function name.
    let id: String?
    let name: String?

    /// `tool_use` arguments.
    let input: [String: AnyCodable]?

    /// `tool_result`: the call this block answers.
    let toolUseId: String?

    /// `tool_result` payload: a bare string or an array of blocks.
    let content: AnthropicToolResultContent?

    /// `image` / `document` source.
    let source: AnthropicBlockSource?

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, content, source
        case toolUseId = "tool_use_id"
    }

    /// The text this block contributes to the prompt — the ONE rendering rule, used both by
    /// the content guard's read (``AnthropicMessage/plainText``) and by the prompt a model
    /// actually gets (``AnthropicMessage/toInternalMessage()``). Two renderings of the same
    /// message is how a guard and a prompt start disagreeing about what the client sent.
    ///
    /// Nil means "no text": media (carried as its own part) or a type this route refuses.
    var promptTextContribution: String? {
        switch type {
        case "text":
            return (text?.isEmpty == false) ? text : nil
        case "tool_result":
            let tag = toolUseId.map { "tool_result · \($0)" } ?? "tool_result"
            let body = content?.text ?? ""
            return "[\(tag)] \(body.isEmpty ? "no output" : body)"
        case "tool_use":
            let idTag = id.map { " · \($0)" } ?? ""
            return "[tool_call · \(name ?? "unknown")\(idTag)] \(Self.jsonText(input) ?? "{}")"
        case "thinking", "redacted_thinking":
            // No extended-thinking support here, so an opaque echo of a prior chain of
            // thought is not replayed — but the turn says so, rather than leaving the model
            // (or a reader of the transcript) to guess why the assistant skipped a step.
            return "[prior thinking omitted by this server]"
        default:
            return nil
        }
    }

    /// `tool_use.arguments` in the shape the OpenAI-side DTO carries it: compact JSON text.
    static func jsonText(_ value: [String: AnyCodable]?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// `tool_result.content` — the spec allows a bare string or an array of blocks, so both
/// decode; a value that is neither yields empty text and the mapper decides what that means.
enum AnthropicToolResultContent: Decodable {
    case text(String)
    case blocks([AnthropicContentBlock])

    /// Text the result contributes (non-text blocks contribute none).
    var text: String {
        switch self {
        case .text(let s): return s
        case .blocks(let blocks):
            return blocks.compactMap { $0.type == "text" ? $0.text : nil }
                .joined(separator: "\n")
        }
    }

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

/// `image` / `document` source: `{type: "base64" | "url" | "text", media_type, data | url}`.
struct AnthropicBlockSource: Decodable {
    let type: String?
    let mediaType: String?
    let url: String?
    let data: String?

    enum CodingKeys: String, CodingKey {
        case type, url, data
        case mediaType = "media_type"
    }

    /// The form the engine's inline-media path takes: a `data:` URL for inline bytes, the
    /// URL as given for `source.url`. Nil only when the source carries nothing at all,
    /// which the mapper turns into a refusal naming the block rather than a blind turn.
    var mediaURL: String? {
        if let data, !data.isEmpty {
            return data.hasPrefix("data:")
                ? data : "data:\(mediaType ?? "application/octet-stream");base64,\(data)"
        }
        if let url, !url.isEmpty { return url }
        return nil
    }
}

extension AnthropicMessage {
    /// Best-effort text of this message — the content-safety guard, prompt-injection
    /// detection and the metrics token count read this. A block the route cannot carry
    /// contributes nothing here, which is not a silent drop: the same request is refused by
    /// name at ``toInternalMessage()`` before any token is produced.
    var plainText: String {
        switch content {
        case .some(.text(let s)): return s
        case .some(.blocks(let blocks)):
            return blocks.compactMap(\.promptTextContribution).joined(separator: "\n")
        case .none:
            return ""
        }
    }

    /// The internal ``Message`` for this Anthropic message: text in the order the client
    /// wrote it, `image` blocks carried to the engine's inline-vision path, and tool
    /// history rendered as tagged text — this route injects tool *definitions* as text too,
    /// so text is the honest medium for their calls and results. (Handing history back as
    /// live `toolCalls` would invite the engine to dispatch calls that already ran.)
    ///
    /// - Throws: `AppError.invalidRequest` naming a block type the engine cannot carry
    ///   (`document`, `search_result`, or any type this build does not know), an `image`
    ///   block with no source, or a user message whose array holds nothing readable.
    ///   Naming the shape is the alternative to a 200 that answered a turn the client
    ///   believes it sent — the rule `AudioTranscription.unsupportedField` applies to fields.
    func toInternalMessage() throws -> Message {
        switch content {
        case .some(.text(let s)):
            return Message(role: role, content: .text(s))
        case .none:
            return Message(role: role, content: nil)
        case .some(.blocks(let blocks)):
            var texts: [String] = []
            var media: [ContentPart] = []
            for block in blocks {
                switch block.type {
                case "image":
                    guard let url = block.source?.mediaURL else {
                        throw AppError.invalidRequest(
                            "Anthropic image block carries no usable source (expected source.data base64 or source.url)"
                        )
                    }
                    media.append(
                        ContentPart(
                            type: "image_url", text: nil,
                            imageUrl: ContentPart.ImageURL(url: url)))
                case "text":
                    if let contribution = block.promptTextContribution {
                        texts.append(contribution)
                    }
                default:
                    guard let contribution = block.promptTextContribution else {
                        throw AppError.invalidRequest(
                            "Unsupported Anthropic content block type '\(block.type)' — this route carries text, image, tool_result and tool_use, and refuses the rest by name rather than dropping it"
                        )
                    }
                    texts.append(contribution)
                }
            }
            if !media.isEmpty {
                if !texts.isEmpty {
                    media.insert(
                        ContentPart(
                            type: "text", text: texts.joined(separator: "\n"), imageUrl: nil),
                        at: 0)
                }
                return Message(role: role, content: .parts(media))
            }
            guard !texts.isEmpty else {
                // An assistant turn may legitimately carry nothing (a tool call with no
                // prose); a user turn that says nothing is a client error, not a prompt.
                if role == "user" {
                    throw AppError.invalidRequest(
                        "Message content is a block array carrying nothing this route can read")
                }
                return Message(role: role, content: nil)
            }
            return Message(role: role, content: .text(texts.joined(separator: "\n")))
        }
    }
}

// MARK: - Response Models

/// Anthropic Messages API response — ``POST /v1/messages``
struct AnthropicMessageResponse: Encodable {
    let id: String
    let type: String = "message"
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
struct AnthropicAssistantContent: Encodable {
    let type: String
    let text: String?

    init(text: String) {
        type = "text"
        self.text = text
    }
}

/// Anthropic-specific token usage tracking
struct AnthropicUsage: Encodable {
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

/// Response for ``POST /v1/messages/count_tokens`` — Anthropic's budget
/// pre-flight.
///
/// `tokenizer_backend` is an ocoreai extension (`real` | `heuristic`): SDKs
/// ignore unknown keys, and when the count came from the byte heuristic it must
/// not read as a token-exact number. Same marker and vocabulary as
/// `CountTokensResponse.tokenizerBackend` and `GET /v1/capabilities`.
struct AnthropicCountTokensResponse: Encodable {
    let inputTokens: Int
    let tokenizerBackend: String

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case tokenizerBackend = "tokenizer_backend"
    }
}

// MARK: - SSE Streaming

/// Anthropic SSE stream event
struct AnthropicStreamEvent: Encodable {
    let type: String
    let index: Int?
    let message: AnthropicMessageResponse?
    let delta: AnthropicStreamDelta?
    let usage: AnthropicStreamUsage?

    /// Stream start event
    static func messageStart(message: AnthropicMessageResponse) -> AnthropicStreamEvent {
        AnthropicStreamEvent(
            type: "message_start", index: nil, message: message, delta: nil, usage: nil)
    }

    /// Content block start event
    static func contentBlockStart(index: Int) -> AnthropicStreamEvent {
        AnthropicStreamEvent(
            type: "content_block_start", index: index, message: nil, delta: nil, usage: nil)
    }

    /// Delta event (incremental text)
    static func textDelta(index: Int, text: String) -> AnthropicStreamEvent {
        AnthropicStreamEvent(
            type: "content_block_delta", index: index, message: nil,
            delta: AnthropicStreamDelta(
                type: "content_block_delta", partialJson: nil, text: text,
                stopReason: nil, stopSequence: nil),
            usage: nil)
    }

    /// Content block stop event
    static func contentBlockStop(index: Int) -> AnthropicStreamEvent {
        AnthropicStreamEvent(
            type: "content_block_stop", index: index, message: nil, delta: nil, usage: nil)
    }

    /// Message delta event — the only place the Anthropic protocol carries the
    /// terminal `stop_reason`. Live 10-13: the SSE path went
    /// `content_block_stop → message_stop`, so clients read no stop_reason at all
    /// (`stream()` ends without the field the SDKs key on).
    static func messageDelta(stopReason: String, outputTokens: Int) -> AnthropicStreamEvent {
        AnthropicStreamEvent(
            type: "message_delta", index: nil, message: nil,
            delta: AnthropicStreamDelta(
                type: "message_delta", partialJson: nil, text: nil,
                stopReason: stopReason, stopSequence: nil),
            usage: AnthropicStreamUsage(outputTokens: outputTokens, inputTokens: nil))
    }

    /// Message stop event (with final usage)
    static func messageStop(inputTokens: Int, outputTokens: Int) -> AnthropicStreamEvent {
        AnthropicStreamEvent(
            type: "message_stop", index: nil, message: nil, delta: nil,
            usage: AnthropicStreamUsage(outputTokens: outputTokens, inputTokens: inputTokens))
    }
}

/// Incremental delta inside SSE stream
struct AnthropicStreamDelta: Encodable {
    let type: String
    let partialJson: String?
    let text: String?
    /// Terminal reason, present only on `message_delta`.
    let stopReason: String?
    /// Matched stop sequence, present only on `message_delta`.
    let stopSequence: String?

    enum CodingKeys: String, CodingKey {
        case type
        case partialJson = "partial_json"
        case text
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
    }
}

/// Usage in the final stream event
struct AnthropicStreamUsage: Encodable {
    let outputTokens: Int
    /// Optional: Anthropic's `message_delta` carries output_tokens only.
    let inputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

// MARK: - Tool Definitions (Anthropic format)

/// Anthropic tool definition
struct AnthropicTool: Decodable {
    let name: String
    let description: String?
    let inputSchema: AnthropicToolInputSchema?

    /// Convert Anthropic tool to OpenAI ToolDef for internal reuse
    func toOpenAITool() -> ToolDef {
        let funcDef = FunctionDef(
            name: name,
            description: description,
            parameters: inputSchema?.toOpenAIParameters(),
        )
        return ToolDef(type: "function", function: funcDef)
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

/// Anthropic tool input schema (JSON Schema)
struct AnthropicToolInputSchema: Decodable {
    let type: String
    let properties: [String: AnyCodable]?
    let required: [String]?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            type = "object"
            properties = nil
            required = nil
        } else {
            let dict = try container.decode([String: AnyCodable].self)
            type = dict["type"]?.value as? String ?? "object"
            properties = (dict["properties"]?.value as? [String: AnyCodable])
            required = dict["required"]?.value as? [String]
        }
    }

    func toOpenAIParameters() -> [String: AnyCodable]? {
        guard let properties else { return nil }
        return properties
    }
}

/// Tool choice strategy
struct AnthropicToolChoice: Decodable {
    let type: String  // "auto" | "any" | "none" | "tool"

    enum CodingKeys: String, CodingKey {
        case type
    }
}

// MARK: - Response Format

/// Anthropic response format for structured output
struct AnthropicResponseFormat: Decodable {
    let type: String  // "json"

    enum CodingKeys: String, CodingKey {
        case type
    }
}

// MARK: - Thinking Config

/// Thinking/reasoning model configuration
struct AnthropicThinkingConfig: Decodable {
    let type: String
    let budgetTokens: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }
}

// MARK: - Metadata

/// User/session metadata
struct AnthropicMetadata: Decodable {
    let userId: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case sessionId = "session_id"
    }
}

// MARK: - Conversion Helpers

/// Convert Anthropic request to internal ChatCompletionRequest
func toChatCompletionRequest(_ req: AnthropicMessageRequest) throws -> ChatCompletionRequest {
    // Convert messages
    // One mapping for every caller: the same `toInternalMessage` the messages route uses,
    // so detection/metrics and the prompt the model sees cannot disagree about what the
    // client sent.
    let messages: [Message] = try req.messages.map { try $0.toInternalMessage() }

    // Convert tools
    let tools: [ToolDef]? = req.tools?.map { $0.toOpenAITool() }

    // Use thinking budget as maxTokens constraint if provided
    let effectiveMaxTokens: Int? =
        if let budget = req.thinking?.budgetTokens {
            min(req.maxTokens ?? Int.max, budget)
        } else {
            req.maxTokens
        }

    // Activate reasoning mode when thinking config is present
    let reasoningEnabled: Bool? = req.thinking != nil ? true : nil

    return ChatCompletionRequest(
        model: req.model,
        messages: messages,
        temperature: req.temperature ?? 0.7,
        topP: req.topP,
        topK: req.topK,
        maxTokens: effectiveMaxTokens,
        responseFormat: nil,
        stream: req.stream ?? false,
        stop: req.stopSequences,
        frequencyPenalty: 0,
        // #176 alignment — Anthropic API has no repetition-penalty param; default
        // nil = runtime-default cascade (ChatHandler) still applies.
        repetitionPenalty: nil,
        repetitionPenaltyWindow: nil,
        presencePenalty: 0,
        sessionID: req.metadata?.sessionId,
        system: req.system?.text,
        tools: tools,
        toolChoice: nil,
        parallelToolCalls: true,
        reasoning: reasoningEnabled,
    )
}

/// Convert Anthropic stop_reason to OpenAI finish_reason
func anthropicToOpenAIFinishReason(_ reason: String) -> String {
    switch reason {
    case "end_turn": "stop"
    case "max_tokens": "length"
    case "stop_sequence": "stop"
    case "tool_use": "tool_calls"
    case "error": "error"
    default: "stop"
    }
}

/// Convert OpenAI finish_reason to Anthropic stop_reason
func openAIToAnthropicStopReason(_ reason: String) -> String {
    switch reason {
    case "stop": "end_turn"
    case "length": "max_tokens"
    case "tool_calls": "tool_use"
    case "cancelled", "error": reason
    default: "end_turn"
    }
}
