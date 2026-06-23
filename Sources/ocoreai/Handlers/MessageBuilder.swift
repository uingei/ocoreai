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

// MARK: - Message Builder Context

/// Dependencies required for message assembly — passed by the caller.
/// Fast Path and Bridge Path both provide their own context.
struct MessageBuilderContext: Sendable {
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
        thinkingBudget: ThinkingBudget
    ) {
        self.systemPromptBuilder = systemPromptBuilder
        self.sessionCompressor = sessionCompressor
        self.complexityAnalyzer = complexityAnalyzer
        self.thinkingBudget = thinkingBudget
    }
    
    /// Build the complete message list ready for tokenization.
    ///
    /// This replaces the old `buildMessageList()` in ChatHandler.swift.
    /// Both Fast Path (UI) and Bridge Path (HTTP) call this.
    ///
    /// - Parameter ctx: Context with raw messages, tools, session ID
    /// - Returns: Ordered ``Message`` array ready for inference
    /// - Throws: ``AppError.invalidRequest`` if validation fails
    func buildMessages(context: MessageBuilderContext) async throws -> [Message] {
        var messages = context.rawMessages
        
        // Phase 1: Build system prompt from skills
        let builtSystemPrompt = await systemPromptBuilder.buildSystemPrompt()
        
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
        
        // Phase 3: Compose final system prompt (priority: user > built > memory)
        let finalSystem: String
        if let userSystem = context.userSystemPrompt, !userSystem.isEmpty {
            finalSystem = userSystem + "\n\n" + builtSystemPrompt + memoryContext
        } else if !builtSystemPrompt.isEmpty {
            finalSystem = builtSystemPrompt + memoryContext
        } else {
            finalSystem = memoryContext.isEmpty ? "" : memoryContext
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
                        content: "You have access to the following tools:\n\n\(toolDefs)"
                    )
                    messages.insert(toolMessage, at: 0)
                }
            }
        }
        
        // Phase 6: Guard — message list must not be empty
        guard !messages.isEmpty else {
            throw AppError.invalidRequest(
                "Message list is empty for model '\(context.modelId)'"
            )
        }
        
        // Phase 7: Inject adaptive reasoning scaffold (三思而后行)
        let userMessage = messages.first(where: { $0.role == "user" })?.textContent()
            ?? context.rawMessages.first?.textContent() ?? ""
        let complexity = await complexityAnalyzer.analyze(
            input: userMessage,
            messageCount: max(1, messages.count),
            sessionId: context.sessionId
        )
        let reasoningScaffold = await thinkingBudget.scaffolding(
            for: complexity,
            sessionId: context.sessionId
        )
        if !reasoningScaffold.isEmpty {
            if let sysIdx = messages.firstIndex(where: { $0.role == "system" }) {
                if case .text(var existingContent) = messages[sysIdx].content {
                    existingContent += "\n\n" + reasoningScaffold
                    messages[sysIdx].content = .text(existingContent)
                }
            }
        }
        
        return messages
    }
}

// MARK: - ChatHandler Compatibility

/// Extension to keep ChatHandler.swift compile-compatible — delegates to MessageBuilder.
///
/// TODO: Remove this once ChatHandler is fully refactored to use MessageBuilder directly.
extension MessageBuilder {
    /// Legacy wrapper matching the old ChatHandler signature.
    ///
    /// - Parameters:
    ///   - request: Chat completion request
    ///   - systemPromptBuilder: System prompt assembly actor
    ///   - sessionCompressor: Session persistence actor
    /// - Returns: Ordered ``Message`` array
    func buildMessageList(
        request: ChatCompletionRequest,
        systemPromptBuilder: SystemPromptBuilder,
        sessionCompressor: SessionCompressor
    ) async throws -> [Message] {
        let ctx = MessageBuilderContext(
            modelId: request.model,
            rawMessages: request.messages,
            userSystemPrompt: request.system,
            tools: request.tools,
            sessionId: request.sessionID ?? UUID().uuidString
        )
        return try await buildMessages(context: ctx)
    }
}
