// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MessageBuilder.swift — Context assembly for inference pipeline
///
/// Extracted from ChatHandler.swift so both Fast Path (SwiftUI direct)
/// and Bridge Path (HTTP handler) share the SAME context assembly logic.
///
/// ### Responsibilities:
/// 1. Inject system prompt from SystemPromptBuilder
/// 2. Recall permanent memory from SessionCompressor
/// 3. Inject tool definitions as markdown
/// 4. Inject adaptive reasoning scaffold (三思而后行)
///
/// This is a pure assembly module — it does NOT dispatch inference,
/// does NOT touch HTTP, and does NOT depend on Hummingbird.
///
/// ### Actor Access:
/// SystemPromptBuilder, SessionCompressor, ComplexityAnalyzer are actors.
/// MessageBuilder holds unowned references and serializes accesses.

import Foundation
import Logging

// MARK: - Message Builder Context

/// Dependencies required for message assembly — passed by the caller.
/// Fast Path and Bridge Path both provide their own context.
struct MessageBuilderContext {
    /// Model identifier
    let modelId: String

    /// Raw user messages from the request (no system prompt yet)
    let rawMessages: [Message]

    /// Optional user-provided system prompt override
    let userSystemPrompt: String?

    /// Optional tool definitions (for function calling)
    let tools: [ToolDef]?

    /// Session identifier (for memory + complexity tracking)
    let sessionId: String
}

// MARK: - Instruction-role extraction

/// Roles that carry the caller's standing instructions rather than conversation turns.
///
/// vllm routes both to the developer channel (`entrypoints/openai/responses/harmony.py:128`,
/// `entrypoints/openai/parser/harmony_utils.py:436`) and sglang admits both as generic
/// message roles (`srt/entrypoints/openai/protocol.py:727-729`). `developer` is the role
/// OpenAI's current spec uses in place of `system`.
nonisolated let instructionMessageRoles: Set<String> = ["system", "developer"]

/// Split instruction-role messages out of a conversation.
///
/// Why this exists, measured 10-20 on this host (`mlx-community/gemma-4-e2b-it-4bit`,
/// temp 0): a request whose `messages[0]` was a ~1000-character `system` message delivered
/// the *same* `usage.prompt_tokens` (705) as the identical request with no system message —
/// a differential of zero, i.e. the client's instructions never reached the model — while
/// this server's own estimate line counted them (`promptTokens=838` against 705). The
/// Anthropic face, whose spec puts `system` in a top-level field, delivered the same text
/// (+182 input tokens), so one face honoured the most-used instruction channel in the
/// OpenAI wire and the other silently dropped it.
///
/// The drop was structural: the engine delivers instructions through exactly one channel —
/// the first `system` message it finds (`EngineInference.swift:1791`) — and filters every
/// `system` role out of the feed it renders, because mlx-swift-lm's `Chat.Message.Role`
/// (Chat.swift:120-124) has no `developer` case either. `buildMessages` then inserted this
/// server's own prompt at index 0 and left the client's message in the list, so the client's
/// text sat at index 1: counted, never delivered, and mis-attributed as a user turn for
/// `developer`.
///
/// So instruction-role messages leave the conversation here and go into the single
/// instructions channel that generation actually reads, in the order the caller wrote them.
/// Empty ones are dropped rather than turned into blank turns.
nonisolated func splitInstructionMessages(
    _ messages: [Message]
) -> (instructionText: String?, conversation: [Message]) {
    var texts: [String] = []
    var conversation: [Message] = []
    for message in messages {
        if instructionMessageRoles.contains(message.role.lowercased()) {
            let text = message.textContent()
            if !text.isEmpty { texts.append(text) }
        } else {
            conversation.append(message)
        }
    }
    guard !texts.isEmpty else { return (nil, conversation) }
    return (texts.joined(separator: "\n\n"), conversation)
}

// MARK: - Assembly disclosure

/// What a handler is about to feed the model, in one line.
///
/// The two HTTP faces of this engine now share one assembly, and "shared" is a claim that
/// needs a reading, not a comment: the first version of this round's parity check measured
/// 774 tokens on `/v1/chat/completions` against 769 on `/v1/messages` for the identical
/// request, and nothing in either response said which half of the prompt differed. One
/// symmetric line per request makes that a lookup.
///
/// `enableReasoning` is on the line because it is the field a capability knob terminates
/// at: `thinking.type` on the Anthropic wire and `reasoning` on the OpenAI wire both resolve
/// here, and a knob that reaches the handler but not the options is the defect this round
/// fixed (probe 13 §8 greps this line as its live delivery proof).
///
/// `wireOutputBudget` names what the client asked to spend. It goes on the same line because
/// `max_tokens` is a knob whose delivery has been measured to fail: on one session the turn
/// after a grammar/tool turn spent the *previous* turn's budget (fixed 10-20 — a reused
/// pooled session carried the old parameters, see `MLXSessionPool.staleSamplingFields`), and a
/// response whose `usage.completion_tokens` exceeds the request's `max_tokens` is unreadable
/// unless the log says which side dropped the number. Handler-side "asked" versus
/// engine-side "generation budget" (EngineInference) versus pool-side "override" is what
/// localized it in one run.
///
/// `Logger.Message` takes a single interpolated string, so the pieces are built first.
func logAssembledPrompt(
    _ logger: Logger,
    face: String,
    messages: [Message],
    promptTokens: Int,
    enableReasoning: Bool?,
    declaredToolCount: Int,
    wireOutputBudget: Int?,
) {
    let systemChars =
        messages.first?.role == "system" ? messages[0].textContent().utf8.count : 0
    let roles = messages.map(\.role).joined(separator: ",")
    let reasoning =
        switch enableReasoning {
        case .some(true): "on"
        case .some(false): "off"
        case .none: "default"
        }
    logger.info(
        "Assembled prompt [\(face)]: \(messages.count) message(s) [\(roles)] systemChars=\(systemChars) promptTokens=\(promptTokens) enableReasoning=\(reasoning) declaredTools=\(declaredToolCount) wireMaxTokens=\(wireOutputBudget.map(String.init) ?? "unset")"
    )
}

// MARK: - Message Builder (Async Actor-Backed)

/// Shared actor for message assembly. Thread-safe, dual-channel compatible.
actor MessageBuilder {
    private let systemPromptBuilder: SystemPromptBuilder
    private let sessionCompressor: SessionCompressor
    private let complexityAnalyzer: ComplexityAnalyzer
    private let thinkingBudget: ThinkingBudget

    /// Internal initializer — takes actor references directly.
    init(
        systemPromptBuilder: SystemPromptBuilder,
        sessionCompressor: SessionCompressor,
        complexityAnalyzer: ComplexityAnalyzer,
        thinkingBudget: ThinkingBudget,
    ) {
        self.systemPromptBuilder = systemPromptBuilder
        self.sessionCompressor = sessionCompressor
        self.complexityAnalyzer = complexityAnalyzer
        self.thinkingBudget = thinkingBudget
    }

    /// Last analyzed complexity score — cached so ChatHandler can peek at `taskType`
    /// without duplicating the classification work.
    private var lastScore: ComplexityScore?

    /// Build the complete message list ready for tokenization.
    ///
    /// This replaces the old `buildMessageList()` in ChatHandler.swift.
    /// Both Fast Path (UI) and Bridge Path (HTTP) call this.
    ///
    /// - Parameter ctx: Context with raw messages, tools, session ID
    /// - Returns: Ordered ``Message`` array ready for inference
    /// - Throws: ``AppError.invalidRequest`` if validation fails
    func buildMessages(context: MessageBuilderContext) async throws -> [Message] {
        // Instruction-role messages (`system`, `developer`) are the caller's standing
        // instructions, not conversation turns: the engine reads them from one channel and
        // filters them out of the rendered feed, so leaving one in the list means counting it
        // here and dropping it there. See ``splitInstructionMessages`` for the measurement.
        let (inlineInstructions, conversationMessages) = splitInstructionMessages(
            context.rawMessages)
        var messages = conversationMessages

        // Phase 1: Build system prompt from skills
        // The tool surface for THIS turn, taken from the same field Phase 5 uses
        // to inject tool definitions: `nil` (client declared nothing) and `[]`
        // (declared empty) both mean zero executable tools, which is how the
        // engine resolves them (`resolveToolSurface`). Telling the model to run
        // commands on such a turn produced fabricated `terminal command:` output
        // (live, 2026-10-12).
        let hasToolsThisTurn = context.tools?.isEmpty == false
        let builtSystemPrompt = await systemPromptBuilder.buildSystemPrompt(
            hasTools: hasToolsThisTurn)

        // Phase 2: Recall permanent memory (non-fatal)
        var memoryContext = ""
        do {
            let recalled = try await sessionCompressor.recallPermanentMemory(limit: 10)
            if !recalled.isEmpty {
                let summaries = recalled.map {
                    "**[\($0.memoryType.rawValue)]** \($0.cause) → \($0.result)"
                }.joined(separator: "\n")
                memoryContext = """

                    ## Recalled Memory
                    The following structured knowledge from past sessions is relevant:

                    \(summaries)
                    """
            }
        } catch {
            // Memory recall failure is non-fatal — proceed without it
        }

        // Phase 3: Compose final system prompt (priority: user > workspace/project
        // instructions > built base+skills > memory — codex agents_md.rs order:
        // host user instructions before project AGENTS.md docs, both before
        // internal guidance). Workspace section comes from the active session's
        // working directory (worktree session) or the configured working directory
        // (AGENTS.md discovery); empty when neither is set.
        let workspaceCwd =
            SessionWorkspace.currentDirectory()
            ?? WorkspaceContext.configuredDirectory()
            ?? ""
        let workspaceSection = WorkspaceContext.buildSection(cwd: workspaceCwd)

        // One client-instructions channel, both spellings: the non-spec top-level `system`
        // field some SDKs send, plus whatever the request wrote as `system`/`developer`
        // messages, in the caller's own order.
        let clientInstructions =
            [context.userSystemPrompt, inlineInstructions]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let finalSystem: String =
            if !clientInstructions.isEmpty {
                clientInstructions
                    + (workspaceSection.isEmpty ? "" : "\n\n" + workspaceSection)
                    + "\n\n" + builtSystemPrompt + memoryContext
            } else if !builtSystemPrompt.isEmpty {
                (workspaceSection.isEmpty ? "" : workspaceSection + "\n\n")
                    + builtSystemPrompt + memoryContext
            } else if !workspaceSection.isEmpty {
                workspaceSection + memoryContext
            } else {
                memoryContext.isEmpty ? "" : memoryContext
            }

        // Phase 4: Inject system message at the front
        if !finalSystem.isEmpty {
            messages.insert(Message(role: "system", content: finalSystem), at: 0)
        }

        // Phase 5: Inject tool definitions into system message (if tools present)
        if let tools = context.tools, !tools.isEmpty {
            let toolDefs = tools.compactMap { tool -> String? in
                guard let desc = tool.function.description else { return nil }
                return "## Tool: \(tool.function.name)\nDescription: \(desc)"
            }.joined(separator: "\n\n")

            if !toolDefs.isEmpty {
                if let firstSystem = messages.firstIndex(where: { $0.role == "system" }) {
                    if case .text(var existingContent) = messages[firstSystem].content {
                        existingContent += "\n\nAvailable tools:\n\(toolDefs)"
                        messages[firstSystem].content = .text(existingContent)
                    }
                } else {
                    let toolMessage = Message(
                        role: "system",
                        content: "You have access to the following tools:\n\n\(toolDefs)",
                    )
                    messages.insert(toolMessage, at: 0)
                }
            }
        }

        // Phase 6: Guard — message list must not be empty
        guard !messages.isEmpty else {
            throw AppError.invalidRequest(
                "Message list is empty for model '\(context.modelId)'",
            )
        }

        // Phase 7: Inject adaptive reasoning scaffold (三思而后行)
        let userMessage =
            messages.first(where: { $0.role == "user" })?.textContent()
            ?? conversationMessages.first?.textContent() ?? ""

        // FIX: VLM requests with .parts (images/audio/video) produce empty textContent(),
        // causing ComplexityAnalyzer to score 0 and ThinkingBudget to return no scaffold.
        // Detect multimodal messages and provide a fallback for complexity analysis.
        // Uses Message.mediaPartCount (single source of truth with the engine's
        // VLM guard — previously a parallel reduce over ContentPart).
        let totalMediaParts = messages.reduce(0) { $0 + $1.mediaPartCount }
        let hasMultimodal = totalMediaParts > 0

        let effectiveInput =
            if userMessage.isEmpty && hasMultimodal {
                "[multimodal: \(totalMediaParts) media part(s)]"
            } else {
                userMessage
            }
        guard !effectiveInput.isEmpty else {
            return messages  // nothing to analyze, skip scaffold
        }

        let complexity = await complexityAnalyzer.analyze(
            input: effectiveInput,
            messageCount: max(1, messages.count),
            sessionId: context.sessionId,
        )
        lastScore = complexity  // cache for lastComplexityScore()
        let reasoningScaffold = await thinkingBudget.scaffolding(
            for: complexity,
            sessionId: context.sessionId,
        )
        if !reasoningScaffold.isEmpty {
            if let sysIdx = messages.firstIndex(where: { $0.role == "system" }) {
                switch messages[sysIdx].content {
                case .text(var existingContent):
                    existingContent += "\n\n" + reasoningScaffold
                    messages[sysIdx].content = .text(existingContent)
                case .none:
                    messages[sysIdx].content = .text(reasoningScaffold)
                case .parts:
                    // System message with .parts — append scaffold as text part
                    var parts: [ContentPart]
                    if case .parts(let p) = messages[sysIdx].content {
                        parts = p
                    } else {
                        parts = []
                    }
                    parts.append(ContentPart(type: "text", text: reasoningScaffold, imageUrl: nil))
                    messages[sysIdx].content = .parts(parts)
                }
            } else {
                // No system message found — prepend one with the scaffold
                let sysMsg = Message(role: "system", content: reasoningScaffold)
                messages.insert(sysMsg, at: 0)
            }
        }

        return messages
    }

    /// Return the full complexity score from the last `buildMessages` call.
    func lastComplexityScore() -> ComplexityScore? {
        lastScore
    }
}
