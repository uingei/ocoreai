// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Scheduler domain model — request priority and states.
///
/// P0: Interrupt (urgent mid-stream stop)
/// P1: Chat (interactive conversation)
/// P2: RAG (retrieval + generation)
/// P3: Background (memory compression, archival)
import Foundation

/// Request priority levels.
/// P0 > P1 > P2 > P3. Lower value = higher priority.
public enum RequestPriority: Int, Codable, Sendable, CaseIterable {
    case interrupt = 0
    /// P0: urgent mid-stream interrupt
    case chat
    /// P1: interactive chat
    case rag
    /// P2: retrieval + generation
    case background
    /// P3: memory compression, archival

    public var name: String {
        switch self {
        case .interrupt: "interrupt"
        case .chat: "chat"
        case .rag: "rag"
        case .background: "background"
        }
    }
}

/// A scheduler request.
public struct SchedulingRequest: Identifiable, Sendable, Codable {
    public let id: String
    public let priority: RequestPriority
    public let modelId: String
    public let prompt: String
    public let tokenBudget: Int
    public let createdAt: Date

    /// Create a new scheduling request.
    /// - Parameters:
    ///   - id: Unique request identifier
    ///   - priority: Request priority level
    ///   - modelId: Model to use for inference
    ///   - prompt: Input prompt text
    ///   - tokenBudget: Maximum tokens to generate
    public init(
        id: String,
        priority: RequestPriority,
        modelId: String,
        prompt: String,
        tokenBudget: Int = 4096,
    ) {
        self.id = id
        self.priority = priority
        self.modelId = modelId
        self.prompt = prompt
        self.tokenBudget = tokenBudget
        createdAt = Date()
    }
}
