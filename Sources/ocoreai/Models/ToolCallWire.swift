// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! ToolCallWire.swift — what a tool-call turn is allowed to claim about itself.
//!
//! Three decisions decide whether an agent loop keeps running, and until 10-19 all three
//! were made at four separate call sites, in two vocabularies, with no shared rule:
//!
//!   • **which `tool_calls` the client receives** — `parallel_tool_calls:false` was decoded
//!     and read by nobody (and Anthropic's `disable_parallel_tool_use` was mapped to the
//!     constant `true`), so a client that forbade parallel calls got both: measured
//!     10-19 on `mlx-community/gemma-4-e2b-it-4bit`, temp 0, one tool declared twice —
//!     `parallel_tool_calls:false` → 2 calls (`Paris`, `London`), and `/v1/messages` with
//!     `tool_choice:{"type":"auto","disable_parallel_tool_use":true}` → 2 `tool_use` blocks.
//!   • **the word the turn ends with** — every site wrote `calls ? "tool_calls" : reason`,
//!     which overrules `length`. Same model, same prompt, `max_tokens:18`: the engine cut
//!     the turn at 18 tokens and delivered one of the two calls it wanted, and the wire
//!     said `finish_reason:"tool_calls"` (Anthropic face: `tool_use`, never `max_tokens`;
//!     the no-tools control on the same host correctly said `length`). A client that sees
//!     `tool_calls` executes the call and never learns the turn was cut mid-list.
//!   • **which chunks may carry that word** — the SSE path stamped
//!     `finish_reason:"tool_calls"` on the tool-call delta and then sent a terminal chunk
//!     saying `stop`. Both halves are wrong: OpenAI puts a non-null `finish_reason` on the
//!     LAST chunk only, and clients that end the stream on the first non-null one stop
//!     before the answer.
//!
//! vllm keeps all three in one module — `maybe_filter_parallel_tool_calls`
//! (vllm/entrypoints/serve/utils/tool_calls_utils.py:24-43, "Filter to first tool call
//! only when parallel_tool_calls is explicitly False"), `resolve_finish_reason`
//! (`:47-65`, applied at eight call sites) — and sglang agrees on the second
//! (serving_chat.py:2149-2152, "Change finish_reason to 'tool_calls' if we had tool calls
//! **and stopped naturally**"). This file is that home for both faces of this server.
//!
//! What it deliberately does NOT decide: whether a checkpoint *can* honour a demand
//! (`ToolCallDeliveryLedger` measures that per model), and which tools exist
//! (`ToolRegistry.resolveToolSurface`).

import Foundation

/// The wire-level rules for a turn that declares, makes, or refuses to make tool calls.
enum ToolCallWire {

    // MARK: - Parallelism

    /// Did the client explicitly forbid parallel calls?
    ///
    /// Three-state on purpose: `nil` (not sent) and `true` both mean "no restriction", so
    /// only the explicit `false` costs anything — the same reading vllm uses
    /// (`request.parallel_tool_calls is not False` → return unchanged).
    static func limitsToSingleCall(parallelToolCalls: Bool?) -> Bool {
        parallelToolCalls == false
    }

    /// The calls this client may receive, in declaration order.
    ///
    /// When parallel calls are forbidden the client keeps the first call and nothing else:
    /// the model's own emission order, no sorting, no replacement (vllm
    /// `tool_calls_utils.py:31` `item[:1]`, and `delta.tool_calls … index == 0` for the
    /// streaming shape at `:38-42`).
    static func limitedToolCalls(
        _ calls: [ToolCall]?, parallelToolCalls: Bool?
    ) -> [ToolCall]? {
        guard let calls, !calls.isEmpty else { return nil }
        guard limitsToSingleCall(parallelToolCalls: parallelToolCalls) else { return calls }
        return Array(calls.prefix(1))
    }

    // MARK: - The terminal word

    /// The engine's finish reason, upgraded to `tool_calls` only when the turn actually
    /// called **and stopped on its own**.
    ///
    /// A `length` cut stays visible so a client can tell a complete call from one the
    /// budget chopped — the reasoning behind both references' wording (vllm
    /// `tool_calls_utils.py:47-65`; sglang `serving_chat.py:2151` gates on
    /// `finish_reason_type == "stop"`). `cancelled` and `error` are never rewritten into
    /// a success word.
    ///
    /// Not adopted, deliberately: vllm also reports `stop` (not `tool_calls`) when the
    /// caller pinned one named tool. That is a fact about OpenAI's own API this host
    /// cannot observe, so it stays an open item (AGENTS.md § Open) instead of a borrowed
    /// word — a call we delivered is a call we report.
    static func resolveFinishReason(engineReason: String, toolCallsMade: Bool) -> String {
        if toolCallsMade && engineReason == "stop" { return "tool_calls" }
        return engineReason
    }

    /// Is this chunk terminal? Only a terminal chunk may carry a non-null `finish_reason`
    /// (OpenAI's chat chunk: content and `tool_calls` deltas carry `null`).
    ///
    /// `nil` here is not optional tidiness — a client that treats the first non-null
    /// `finish_reason` as end-of-stream drops everything after it, and this server's tool
    /// loop keeps generating after emitting a call.
    static func terminalFinishReason(
        engineReason: String, toolCallsMade: Bool, terminal: Bool
    ) -> String? {
        terminal
            ? resolveFinishReason(engineReason: engineReason, toolCallsMade: toolCallsMade)
            : nil
    }

    // MARK: - tool_choice vocabulary

    /// The bare-string vocabulary `tool_choice` accepts, per OpenAI's chat spec and both
    /// reference stacks (vllm `chat_completion/protocol.py:250-255` is exactly
    /// `"none" | "auto" | "required" | ChatCompletionNamedToolChoiceParam`).
    static let toolChoiceKeywords: [String] = ["none", "auto", "required"]

    /// Internal word for a pinned tool. Namespace-disjoint from the keywords, which is why
    /// a tool literally named `none` cannot impersonate the `none` mode.
    static let namedToolPrefix = "function:"

    /// A bare string from the wire, validated against the vocabulary.
    ///
    /// Anything else (measured 10-19 before this file: `"banana"` and a bare tool name
    /// `"get_weather"` both answered 200 and called anyway) is refused naming the field,
    /// not quietly reinterpreted as `auto`. vllm's message is the model
    /// (`chat_completion/protocol.py:986-992`: *Only named tools, "none", "auto" or
    /// "required" are supported*).
    static func normalizedToolChoiceWord(_ raw: String) throws -> String {
        if toolChoiceKeywords.contains(raw) { return raw }
        if raw.hasPrefix(namedToolPrefix) { return raw }
        throw AppError.invalidParameter(
            param: "tool_choice",
            message:
                "invalid tool_choice \(quoted(raw)) — use \"none\", \"auto\", \"required\", or "
                + "a named tool: {\"type\":\"function\",\"function\":{\"name\":\"<tool>\"}}",
            value: raw
        )
    }

    /// The object form, from whichever shape the client used, normalized to the internal
    /// word.
    ///
    /// OpenAI's spec shape nests the name (`{"type":"function","function":{"name":X}}`,
    /// vllm `protocol.py:220-224`, sglang `protocol.py:829-833`). This server historically
    /// accepted only a flat `{"type":"function","name":X}`, so the canonical shape died at
    /// the decoder with Hummingbird's leaked `Coding key \`name\` not found.` — the same
    /// family as the `model`/`stream` leaks this repo already pins. Both shapes decode
    /// here; the flat one stays a tolerated alias (documented, and pinned by a test) so
    /// clients written against the old behaviour keep working, and every rejection names
    /// `tool_choice` and shows the spec shape.
    static func normalizedNamedToolChoice(
        type: String?, flatName: String?, nestedName: String?
    ) throws -> String {
        // `type` defaults to "function" when absent, as both references declare it
        // (`type: Literal["function"] = "function"`).
        let resolvedType = type ?? "function"
        guard resolvedType == "function" else {
            throw AppError.invalidParameter(
                param: "tool_choice",
                message:
                    "unsupported tool_choice type \(quoted(resolvedType)) — only \"function\" is "
                    + "selectable by name: {\"type\":\"function\",\"function\":{\"name\":\"<tool>\"}}",
                value: resolvedType
            )
        }
        guard let name = flatName ?? nestedName, !name.isEmpty else {
            throw AppError.invalidParameter(
                param: "tool_choice",
                message:
                    "tool_choice with type \"function\" must name the tool — "
                    + "{\"type\":\"function\",\"function\":{\"name\":\"<tool>\"}}"
            )
        }
        return namedToolPrefix + name
    }

    /// `tool_choice` without `tools` is a contradiction: the client demanded a choice from
    /// a set it never declared. `"none"` is exempt (it demands nothing), which is how both
    /// references read it (vllm `protocol.py:971-981`, sglang `protocol.py:1020-1027`).
    ///
    /// `echo` is the word to show the client. The Anthropic face hands over its own
    /// vocabulary (`"any"`, not the internal `required` it maps to), because the value a
    /// client gets back must be a value it recognises as its own.
    static func toolChoiceWithoutToolsError(
        toolChoice: String?, toolCount: Int?, echo: String? = nil
    ) -> AppError? {
        guard let toolChoice, !toolChoice.isEmpty else { return nil }
        guard toolChoice != "none" else { return nil }
        guard toolCount ?? 0 == 0 else { return nil }
        let shown = echo ?? toolChoice
        return AppError.invalidParameter(
            param: "tool_choice",
            message: "tool_choice \(quoted(shown)) requires tools[] — declare at least one tool",
            value: shown
        )
    }

    /// JSON-ish quoting for messages that echo a client's value.
    private static func quoted(_ value: String) -> String { "\"\(value)\"" }
}

/// Keys the object form of `tool_choice` may carry. `name` is this server's flat alias;
/// `function` is OpenAI's nested form, whose inner object carries the name.
enum ToolChoicePinKeys: String, CodingKey {
    case type
    case name
    case function
}

/// The inner `{"name": …}` of OpenAI's nested named-tool form.
enum ToolChoiceFunctionKeys: String, CodingKey {
    case name
}
