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
    case interrupt = 0  /// P0: urgent mid-stream interrupt
    case chat          /// P1: interactive chat
    case rag           /// P2: retrieval + generation
    case background    /// P3: memory compression, archival
    
    public var name: String {
        switch self {
        case .interrupt: return "interrupt"
        case .chat: return "chat"
        case .rag: return "rag"
        case .background: return "background"
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
    public let timeout: TimeInterval
    
    /// Create a new scheduling request.
    /// - Parameters:
    ///   - id: Unique request identifier
    ///   - priority: Request priority level
    ///   - modelId: Model to use for inference
    ///   - prompt: Input prompt text
    ///   - tokenBudget: Maximum tokens to generate
    ///   - timeout: Seconds before auto-interrupt (default 30s)
    public init(
        id: String,
        priority: RequestPriority,
        modelId: String,
        prompt: String,
        tokenBudget: Int = 4096,
        timeout: TimeInterval = 30
    ) {
        self.id = id
        self.priority = priority
        self.modelId = modelId
        self.prompt = prompt
        self.tokenBudget = tokenBudget
        self.createdAt = Date()
        self.timeout = timeout
    }
}

/// Request lifecycle states
public enum RequestState: String, Codable, Sendable {
    case pending       /// Waiting in priority queue
    case queued        /// Accepted, waiting for model
    case inferring     /// Currently being generated
    case completed     /// Successfully generated
    case interrupted   /// Stop requested by user
    case timedOut      /// Exceeded timeout
    case failed        /// Error during processing
}

/// Request status report
public struct RequestStatus: Codable, Sendable {
    public let requestId: String
    public let state: RequestState
    public let modelId: String
    public let age: TimeInterval
    public let message: String?
    
    public init(
        requestId: String,
        state: RequestState,
        modelId: String,
        age: TimeInterval = 0,
        message: String? = nil
    ) {
        self.requestId = requestId
        self.state = state
        self.modelId = modelId
        self.age = age
        self.message = message
    }
}

/// Scheduler health snapshot
public struct SchedulerSnapshot: Codable, Sendable {
    public let pendingCount: Int
    public let inferringCount: Int
    public let totalRequests: Int
    public let avgQueueTimeMs: Double
    public let memoryUsageGB: Double
    public let oomGuardLevel: String
    
    public init(
        pendingCount: Int,
        inferringCount: Int,
        totalRequests: Int,
        avgQueueTimeMs: Double,
        memoryUsageGB: Double,
        oomGuardLevel: String
    ) {
        self.pendingCount = pendingCount
        self.inferringCount = inferringCount
        self.totalRequests = totalRequests
        self.avgQueueTimeMs = avgQueueTimeMs
        self.memoryUsageGB = memoryUsageGB
        self.oomGuardLevel = oomGuardLevel
    }
}
