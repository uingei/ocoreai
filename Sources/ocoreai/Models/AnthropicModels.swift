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
    /// read it as tri-state (`AnthropicMessagesHandler.swift:292` == true).
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

    /// The first numeric spec violation on this wire, or nil. The Anthropic sibling of
    /// ``ChatCompletionRequest/numericDomainError()`` — rules in ``SamplingDomain``, this
    /// forwarder carries only Anthropic's own bounds: `temperature` is [0, 1] here (not
    /// OpenAI's [0, 2]) and `top_k = 0` means "disabled" rather than being out of domain.
    ///
    /// Before this check a negative `max_tokens` reached the scheduler, where the
    /// token-to-byte conversion trapped and the whole server died on one malformed request.
    /// A spec-invalid value now comes back 400 naming the field and the range, and nothing
    /// downstream is allowed to depend on the caller having been sane.
    func numericDomainError() -> AppError? {
        if let violation = SamplingDomain.firstViolation(
            SamplingKnobs(
                maxTokens: maxTokens,
                temperature: temperature.map(Double.init),
                temperatureRange: 0 ... 1,
                topP: topP.map(Double.init),
                topK: topK,
                counts: [
                    // A non-positive budget asks the engine for no thinking at all.
                    SamplingKnobs.Count(
                        field: "thinking.budget_tokens", value: thinking?.budgetTokens ?? 1)
                ]
            )
        ) {
            return .invalidParameter(
                param: violation.param, message: violation.message, value: violation.value)
        }
        // Anthropic's own pairing rule: the budget is part of the output, so it must be
        // smaller than `max_tokens`. Refusing beats the silent alternative — a budget that
        // eats the ceiling either starves the answer (what `min(max_tokens, budget)` used to
        // do here) or is quietly ignored, and neither is a number the client can trust.
        if thinking?.reasoningEnabled == true,
            let budget = thinking?.budgetTokens,
            let maxTokens,
            budget >= maxTokens
        {
            return .invalidParameter(
                param: "thinking.budget_tokens",
                message:
                    "thinking.budget_tokens (\(budget)) must be less than max_tokens (\(maxTokens)) — the budget is the thinking half of the output and the answer still needs room",
                value: "\(budget)")
        }
        return nil
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
/// spec-legal block, and ``AnthropicMessage/toInternalMessages()`` turns anything left
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
/// (``AnthropicMessage/toInternalMessages()``): carry what the engine can carry, refuse by
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

    /// `tool_result` with `is_error:true` = the call FAILED. The engine's tool channel has
    /// no error bit (`Chat.Message.tool(content, id:)`), so the flag travels as text: a
    /// failed result reads as a failed result, and the model is not told the call succeeded.
    let isError: Bool?

    /// `thinking` / `signature_delta` carried by a replayed thinking block. Decoded so the
    /// block is *representable* rather than destructive; this route never replays a prior
    /// chain of thought (see ``promptTextContribution``) and never verifies a signature.
    let signature: String?

    /// `image` / `document` source.
    let source: AnthropicBlockSource?

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, content, source, signature
        case toolUseId = "tool_use_id"
        case isError = "is_error"
    }

    /// The text this block contributes when it has to travel as TEXT — the ONE rendering
    /// rule, shared by the content guard's read (``AnthropicMessage/plainText``) and by
    /// every fallback in ``AnthropicMessage/toInternalMessages()``. Two renderings of the
    /// same message is how a guard and a prompt start disagreeing about what the client sent.
    ///
    /// This is the FALLBACK medium, not the primary one: a `tool_use` block with an id and a
    /// `tool_result` block with a `tool_use_id` travel on the engine's structured tool
    /// channel instead (see ``toInternalMessages()``), which is where the chat template
    /// renders them. Text is what is left when the correlation id is missing — a result
    /// that cannot be tied to a call is still content the model should see.
    ///
    /// Nil means "no text": media (carried as its own part) or a type this route refuses.
    var promptTextContribution: String? {
        switch type {
        case "text":
            return (text?.isEmpty == false) ? text : nil
        case "tool_result":
            let tag = toolUseId.map { "tool_result · \($0)" } ?? "tool_result"
            let body = content?.text ?? ""
            let failed = (isError == true) ? " [failed]" : ""
            return "[\(tag)\(failed)] \(body.isEmpty ? "no output" : body)"
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
    /// name at ``toInternalMessages()`` before any token is produced.
    var plainText: String {
        switch content {
        case .some(.text(let s)): return s
        case .some(.blocks(let blocks)):
            return blocks.compactMap(\.promptTextContribution).joined(separator: "\n")
        case .none:
            return ""
        }
    }

    /// The engine ``Message``(s) this Anthropic message becomes — one Anthropic turn can be
    /// several engine turns, because the two dialects type a tool exchange differently:
    /// Anthropic puts N `tool_result` blocks in ONE user message, the engine's channel
    /// (and OpenAI's) gives each result its own `role:"tool"` turn with one `tool_call_id`
    /// (`EngineInference.swift` maps `role:"tool"`+`toolCallID` → `Chat.Message.tool(_:id:)`
    /// and `Message.toolCalls` → `Chat.Message.assistant(_:toolCalls:)`).
    ///
    /// So a call and its result travel on the structured channel the chat template renders,
    /// not as prose inside a user turn. That the answer still looked right when it was prose
    /// (measured 10-19: `[tool_result · call_F3F831A7] 17C, light rain` → "The weather in
    /// Paris is 17C with light rain.") says this checkpoint reads tool output out of text;
    /// it does not say the channel is unnecessary — a checkpoint that renders tool output
    /// only from its template's tool role saw nothing. Text remains the fallback whenever a
    /// correlation id is missing: an unattachable result is still content (`is_error` rides
    /// as text too, because the engine's tool turn has no error bit).
    ///
    /// This does not re-run anything: the engine dispatches calls it parses out of
    /// *generation*, never from history, which is why the OpenAI face has always been able
    /// to carry `tool_calls` history safely — and probe 13 §7 asserts it here too.
    ///
    /// - Throws: `AppError.invalidRequest` naming a block type the engine cannot carry
    ///   (`document`, `search_result`, or any type this build does not know), an `image`
    ///   block with no source, or a turn whose array holds nothing readable. Naming the
    ///   shape is the alternative to a 200 that answered a turn the client believes it
    ///   sent — the rule `AudioTranscription.unsupportedField` applies to fields.
    func toInternalMessages() throws -> [Message] {
        switch content {
        case .some(.text(let s)):
            return [Message(role: role, content: .text(s))]
        case .none:
            return [Message(role: role, content: nil)]
        case .some(.blocks(let blocks)):
            var texts: [String] = []
            var media: [ContentPart] = []
            var calls: [ToolCall] = []
            /// The turn's results, in the order the client wrote them. They lead the turn:
            /// the engine's channel puts a result directly after the call it answers, so a
            /// result and its commentary in the same Anthropic message become
            /// `[tool…, user]`, never `[user, tool…]` (a dangling tool turn is what the
            /// latter renders as).
            var results: [Message] = []

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
                case "tool_use" where role == "assistant":
                    // The assistant's own call, in the dialect the engine recognises it by.
                    // An id is mandatory on this channel, so an id-less block gets one
                    // rather than a call the result can never be tied to.
                    calls.append(
                        ToolCall(
                            id: block.id ?? "toolu_\(UUID().uuidString.prefix(8))",
                            type: "function",
                            function: ToolCallFunction(
                                name: block.name ?? "unknown",
                                arguments: AnthropicContentBlock.jsonText(block.input) ?? "{}")))
                case "tool_result" where block.toolUseId?.isEmpty == false:
                    let body = block.content?.text ?? ""
                    let text =
                        (block.isError == true)
                        ? "Error: \(body.isEmpty ? "the call failed" : body)"
                        : (body.isEmpty ? "no output" : body)
                    results.append(
                        Message(role: "tool", content: .text(text), toolCallID: block.toolUseId))
                default:
                    guard let contribution = block.promptTextContribution else {
                        throw AppError.invalidRequest(
                            "Unsupported Anthropic content block type '\(block.type)' — this route carries text, image, tool_result and tool_use, and refuses the rest by name rather than dropping it"
                        )
                    }
                    texts.append(contribution)
                }
            }
            let trailingText = texts.joined(separator: "\n")
            var carried: ContentPolymorphic? = nil
            if !media.isEmpty {
                if !trailingText.isEmpty {
                    media.insert(
                        ContentPart(
                            type: "text", text: trailingText, imageUrl: nil),
                        at: 0)
                }
                carried = .parts(media)
            } else if !trailingText.isEmpty {
                carried = .text(trailingText)
            }

            guard carried != nil || !calls.isEmpty || !results.isEmpty else {
                // An assistant turn may legitimately carry nothing (a call with no
                // prose); a user turn that says nothing is a client error, not a prompt.
                if role == "user" {
                    throw AppError.invalidRequest(
                        "Message content is a block array carrying nothing this route can read")
                }
                return [Message(role: role, content: nil)]
            }
            // The turn's own message exists only if it has something to say: prose, media,
            // or calls. A `[tool_result]`-only user message is that message — appending an
            // empty user turn after it would put a blank segment in the prompt, which is
            // the same class of damage as the blanked block this whole mapper exists to
            // prevent, just one block shorter.
            var turn: Message? = nil
            if !calls.isEmpty {
                turn = Message(role: role, content: carried, toolCalls: calls)
            } else if carried != nil {
                turn = Message(role: role, content: carried)
            }
            return results + (turn.map { [$0] } ?? [])
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

/// Assistant message content block — `text`, `tool_use`, or `thinking`.
///
/// Anthropic types a call as a content block (`{"type":"tool_use","id","name","input"}`)
/// where OpenAI types it as a sibling `tool_calls` array, and `input` is a JSON *object*
/// (OpenAI's `arguments` is a string). Synthesized encoding omits nil keys, so a text
/// block still serializes as `{"type":"text","text":…}` with no stray fields.
///
/// A chain of thought is its own block type, and its text never goes in a `text` block:
/// merging reasoning into `content` (what this face did until 10-19) hands a strict client a
/// `content[0].text` that is mostly thinking, and `content` is what clients display and
/// what they feed back as the assistant turn.
struct AnthropicAssistantContent: Encodable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: [String: AnyCodable]?
    /// `thinking` payload — the reasoning text this turn produced.
    let thinking: String?
    /// Anthropic's integrity token for a thinking block.
    ///
    /// Read the field for what it is here: an **opaque per-block id**, generated by this
    /// server (same stand-in vllm's adapter emits — `signature=uuid.uuid4().hex`,
    /// `entrypoints/anthropic/serving.py:855-862`). It round-trips through this server,
    /// which never verifies it — we have no signing key and no verification path, so a
    /// client must not read integrity from it. The field exists because the spec's
    /// `ThinkingBlock` requires it and SDKs decode it as a non-optional string; omitting
    /// it would break those clients on a turn that genuinely thought.
    let signature: String?

    init(text: String) {
        type = "text"
        self.text = text
        id = nil
        name = nil
        input = nil
        thinking = nil
        signature = nil
    }

    init(toolUseId: String, name: String, input: [String: AnyCodable]) {
        type = "tool_use"
        text = nil
        id = toolUseId
        self.name = name
        self.input = input
        thinking = nil
        signature = nil
    }

    /// A thinking block: reasoning text, plus the opaque block id where one exists.
    /// `content_block_start` opens with `thinking:""` and no signature (the signature
    /// arrives in its own `signature_delta` before the block closes), so the parameter is
    /// optional and the encoder omits the key when there is nothing to carry.
    init(thinking: String, signature: String? = nil) {
        type = "thinking"
        text = nil
        id = nil
        name = nil
        input = nil
        self.thinking = thinking
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, thinking, signature
    }
}

/// An opaque id for a thinking block, in the shape Anthropic's field takes.
///
/// `internal`, not inline at the call sites: both response modes must emit the same
/// thing, and the exact-value test asserts the prefix rather than a random hex string.
func anthropicThinkingSignature() -> String {
    "sig-\(UUID().uuidString.prefix(12).lowercased())"
}

/// Anthropic's `input` object from the engine's argument payload (a JSON string).
///
/// Returns nil when the payload is not a JSON object — the caller must not turn a
/// malformed blob into `input:{}`, because a client would execute a call with arguments
/// the model never asked for. Nil means "no call delivered", and the caller logs it.
func anthropicToolInput(fromJSON raw: String) -> [String: AnyCodable]? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode([String: AnyCodable].self, from: data)
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
    /// Carried by `content_block_start` only. Anthropic's spec names the block here
    /// (`content_block:{"type":"text","text":""}` / `{"type":"tool_use","id","name",
    /// "input":{}}`) and SDKs open their accumulator from `content_block.type`, so an
    /// event that omits it is not a stream a spec client can start a block in.
    var contentBlock: AnthropicAssistantContent? = nil

    enum CodingKeys: String, CodingKey {
        case type, index, message, delta, usage
        case contentBlock = "content_block"
    }

    /// Stream start event
    static func messageStart(message: AnthropicMessageResponse) -> AnthropicStreamEvent {
        AnthropicStreamEvent(
            type: "message_start", index: nil, message: message, delta: nil, usage: nil)
    }

    /// Content block start for a text block, naming the block as the spec requires.
    static func contentBlockStart(index: Int) -> AnthropicStreamEvent {
        AnthropicStreamEvent(
            type: "content_block_start", index: index, message: nil, delta: nil, usage: nil,
            contentBlock: AnthropicAssistantContent(text: ""))
    }

    /// Content block start for a `tool_use` block: id + name + empty input, with the
    /// arguments following as `input_json_delta` — the shape Anthropic clients and
    /// vllm's adapter emit.
    static func toolUseBlockStart(index: Int, id: String, name: String) -> AnthropicStreamEvent {
        AnthropicStreamEvent(
            type: "content_block_start", index: index, message: nil, delta: nil, usage: nil,
            contentBlock: AnthropicAssistantContent(toolUseId: id, name: name, input: [:]))
    }

    /// `input_json_delta` — Anthropic's carrier for tool arguments (OpenAI uses
    /// `function.arguments` for the same bytes).
    static func inputJsonDelta(index: Int, partialJson: String) -> AnthropicStreamEvent {
        AnthropicStreamEvent(
            type: "content_block_delta", index: index, message: nil,
            delta: AnthropicStreamDelta(
                type: "input_json_delta", partialJson: partialJson, text: nil,
                stopReason: nil, stopSequence: nil),
            usage: nil)
    }

    /// Content block start for a `thinking` block. The spec opens it with an empty
    /// `thinking` string, and its `type` is what makes a client accumulate reasoning
    /// separately from the answer that follows.
    static func thinkingBlockStart(index: Int) -> AnthropicStreamEvent {
        AnthropicStreamEvent(
            type: "content_block_start", index: index, message: nil, delta: nil, usage: nil,
            contentBlock: AnthropicAssistantContent(thinking: ""))
    }

    /// `thinking_delta` — Anthropic's carrier for incremental reasoning.
    static func thinkingDelta(index: Int, thinking: String) -> AnthropicStreamEvent {
        AnthropicStreamEvent(
            type: "content_block_delta", index: index, message: nil,
            delta: AnthropicStreamDelta(type: "thinking_delta", thinking: thinking),
            usage: nil)
    }

    /// `signature_delta` — closes a thinking block's payload, as the spec orders it
    /// (signature first, then `content_block_stop`; vllm serving.py:945-961).
    static func signatureDelta(index: Int, signature: String) -> AnthropicStreamEvent {
        AnthropicStreamEvent(
            type: "content_block_delta", index: index, message: nil,
            delta: AnthropicStreamDelta(type: "signature_delta", signature: signature),
            usage: nil)
    }

    /// Delta event (incremental text).
    ///
    /// The **event** is `content_block_delta`; the **delta** inside it is discriminated
    /// by its own `type`, whose text member is `text_delta` (`AnthropicContentDelta` is
    /// a union keyed on `type`: `text_delta`/`input_json_delta`/`thinking_delta`/
    /// `signature_delta`, sglang `srt/entrypoints/anthropic/protocol.py:402-426`).
    /// This one said `content_block_delta` in both slots — measured 10-19, the wire came
    /// back `{"delta":{"type":"content_block_delta","text":"4"}}` — which is outside
    /// that union, so a client that dispatches on `delta.type` (as the SDKs do) sees no
    /// text at all on a turn that answered fine.
    static func textDelta(index: Int, text: String) -> AnthropicStreamEvent {
        AnthropicStreamEvent(
            type: "content_block_delta", index: index, message: nil,
            delta: AnthropicStreamDelta(
                type: "text_delta", partialJson: nil, text: text,
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

/// Incremental delta inside SSE stream — the union Anthropic discriminates by `type`
/// (`text_delta` / `input_json_delta` / `thinking_delta` / `signature_delta`, sglang
/// `srt/entrypoints/anthropic/protocol.py:402-426`), so each member carries only its own
/// payload key and the synthesized encoder omits the rest.
struct AnthropicStreamDelta: Encodable {
    let type: String
    let partialJson: String?
    let text: String?
    /// `thinking_delta` payload.
    let thinking: String?
    /// `signature_delta` payload — the opaque block id, see
    /// ``AnthropicAssistantContent/signature`` for what it is and is not.
    let signature: String?
    /// Terminal reason, present only on `message_delta`.
    let stopReason: String?
    /// Matched stop sequence, present only on `message_delta`.
    let stopSequence: String?

    init(
        type: String,
        partialJson: String? = nil,
        text: String? = nil,
        thinking: String? = nil,
        signature: String? = nil,
        stopReason: String? = nil,
        stopSequence: String? = nil
    ) {
        self.type = type
        self.partialJson = partialJson
        self.text = text
        self.thinking = thinking
        self.signature = signature
        self.stopReason = stopReason
        self.stopSequence = stopSequence
    }

    enum CodingKeys: String, CodingKey {
        case type
        case partialJson = "partial_json"
        case text
        case thinking
        case signature
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
            // `required` arrives as `[AnyCodable]` — AnyCodable decodes an array of
            // strings into an array of boxes, so `as? [String]` fails and the key
            // vanished here even before `toOpenAIParameters()` dropped it. A schema
            // that lost its required list tells the grammar no key is mandatory, and
            // a constrained call then answers with an object missing every argument.
            required = Self.stringArray(dict["required"]?.value)
        }
    }

    /// An array of JSON strings, out of whatever `AnyCodable` boxed it as.
    private static func stringArray(_ value: Any?) -> [String]? {
        if let strings = value as? [String] { return strings }
        if let boxes = value as? [AnyCodable] {
            let strings = boxes.compactMap { $0.value as? String }
            return strings.isEmpty ? nil : strings
        }
        return nil
    }

    /// The caller's declared JSON Schema, whole: `type`, `properties`, `required`.
    ///
    /// Bare `properties` is not a schema — it names no object and requires nothing, so
    /// the engine's constrained path had nothing to fill and a `tool_choice:"any"`
    /// request could not be satisfied. vllm and sglang forward `input_schema` verbatim
    /// for exactly this reason (`vllm/entrypoints/anthropic/serving.py:779`,
    /// `sglang/srt/entrypoints/anthropic/serving.py:672`).
    ///
    /// A schema that names no keys stays `{"type":"object"}`: an open object, never
    /// `properties:{}`, which would pin zero keys (round 19's `jsonObjectSchema`).
    func toOpenAIParameters() -> [String: AnyCodable]? {
        var schema: [String: AnyCodable] = ["type": AnyCodable(type)]
        if let properties {
            schema["properties"] = AnyCodable.wrap(properties)
        }
        if let required {
            schema["required"] = AnyCodable.wrap(required)
        }
        return schema
    }
}

/// Tool choice strategy
struct AnthropicToolChoice: Decodable {
    let type: String  // "auto" | "any" | "none" | "tool"

    /// Pinned tool name for `{"type":"tool","name":…}`; absent on the other variants.
    var name: String? = nil

    /// This request's demand in the repo's own `tool_choice` vocabulary, so the single
    /// forcing rule (`toolChoiceDemandsCall` / `shouldConstrainOutput`) means the same
    /// thing on both wires: Anthropic's `any` is OpenAI's `required`, and a pinned
    /// `tool` is `function:<name>`.
    var openAIVocabulary: String? {
        switch type {
        case "auto": "auto"
        case "none": "none"
        case "any": "required"
        case "tool": name.map { "function:\($0)" } ?? "required"
        default: nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, name
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

    /// The three-state reasoning preference this field states: `enabled` → ON,
    /// `disabled` → OFF, absent/unknown → no preference (the model template's own default
    /// stays in force, which is what Anthropic's `disabled` vs omitted distinction means and
    /// what upstream mlx-swift-lm's `thinkingEnabled: Bool?` models).
    ///
    /// An unrecognised `type` is deliberately NOT treated as ON: guessing "they probably
    /// want thinking" would open a channel the client did not ask for.
    var reasoningEnabled: Bool? {
        switch type.lowercased() {
        case "enabled": return true
        case "disabled": return false
        default: return nil
        }
    }

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
    // One mapping for every caller: the same `toInternalMessages` the messages route uses,
    // so detection/metrics and the prompt the model sees cannot disagree about what the
    // client sent.
    let messages: [Message] = try req.messages.flatMap { try $0.toInternalMessages() }

    // Convert tools
    let tools: [ToolDef]? = req.tools?.map { $0.toOpenAITool() }

    /// `thinking` decides whether the engine thinks, from the field that says so.
    ///
    /// Two defects lived here. (1) The value that opens the reasoning channel
    /// (`InferenceOptions.enableReasoning`) was never set on this face — `toChatCompletion
    /// Request` put a preference on `ChatCompletionRequest.reasoning` and the handler built
    /// its `InferenceOptions` without reading it, so declaring `thinking` changed nothing.
    /// Measured 10-19 (gemma-4-e2b-it-4bit, temperature 0, the same riddle):
    /// `thinking:{"type":"enabled","budget_tokens":400}` → 38 output tokens, no thinking
    /// block; `/v1/chat/completions` `{"reasoning":true}` on the same model and prompt →
    /// 335 tokens. (2) The check was `thinking != nil`, so `{"type":"disabled"}` — the
    /// request to switch thinking OFF — asked for it ON. `type` now decides
    /// (`enabled`→true, `disabled`→false, absent→no preference, model default applies).
    let reasoningEnabled: Bool? = req.thinking?.reasoningEnabled

    /// `budget_tokens` is the thinking *half* of the output, not a ceiling on the answer.
    /// Capping `max_tokens` at the budget left the answer no room on exactly the requests
    /// that asked to think, and enforced nothing: this server does not stop a thinking run
    /// at N tokens (how long one runs is the model template's decision — the honest
    /// statement is that the budget is a *request*, and `thinking.type` is the part with
    /// binding effect). The pair is validated instead: see ``numericDomainError()``.
    let effectiveMaxTokens: Int? = req.maxTokens

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
        // Anthropic's demand in our own vocabulary (`any`→required, `tool`→function:<name>),
        // so `shouldConstrainOutput`/`toolChoiceDemandsCall` mean the same thing on both
        // wires. sglang maps the same four variants (serving.py:685-720).
        toolChoice: req.toolChoice?.openAIVocabulary,
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
