// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ToolRegistryActor — central tool registration and dispatch.
///
/// Thread safety: Actor isolation, all access via mailbox.
/// Lookup complexity: O(1) dictionary per toolset, +1 actor hop ≈ 3μs.
/// Memory: ~256B per entry, 256 tools ≈ 64KB total.
import Foundation

/// A registered tool entry with execution handler and safety check.
struct ToolEntry: Sendable {
    let name: String
    let toolset: String
    let schema: ToolSchema
    let handler: @Sendable (String) async throws -> String
    let checkFn: @Sendable () async -> Bool
    let isDestructive: Bool
    let maxDepth: Int
    
    /// Default TTL for checkFn cache — 30 seconds
    static let checkTTL: TimeInterval = 30.0
    
    init(
        name: String,
        toolset: String,
        schema: ToolSchema,
        handler: @Sendable @escaping (String) async throws -> String,
        checkFn: @Sendable @escaping () async -> Bool = { true },
        isDestructive: Bool = false,
        maxDepth: Int = 3
    ) {
        self.name = name
        self.toolset = toolset
        self.schema = schema
        self.handler = handler
        self.checkFn = checkFn
        self.isDestructive = isDestructive
        self.maxDepth = maxDepth
    }
}

/// JSON Schema describing tool parameters
struct ToolSchema: Sendable, Codable {
    let parameters: [String: ParameterType]
    
    init(parameters: [String: ParameterType] = [:]) {
        self.parameters = parameters
    }
}

/// Supported parameter types for tool argument coercion
enum ParameterType: String, Sendable, Codable, CaseIterable {
    case string
    case integer
    case boolean
    case array
    
    /// Coerce a JSON string value to the target type
    func coerce(_ raw: String) throws -> Any {
        switch self {
        case .string:
            return raw
        case .integer:
            guard let int = Int(raw) else {
                throw ToolError.invalidParameter("Expected integer, got '\"\(raw)\"'")
            }
            return int
        case .boolean:
            let lower = raw.lowercased()
            guard ["true", "false"].contains(lower) else {
                throw ToolError.invalidParameter("Expected boolean, got '\"\(raw)\"'")
            }
            return lower == "true"
        case .array:
            guard let data = raw.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                return [raw]
            }
            return parsed
        }
    }
}

/// Tool execution errors
enum ToolError: Error, Sendable, LocalizedError {
    case notFound(String)
    case invalidParameter(String)
    case checkFailed(String)
    case loopDetected(String)
    case executionFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .notFound(let name): return "Tool not found: \(name)"
        case .invalidParameter(let detail): return "Invalid parameter: \(detail)"
        case .checkFailed(let name): return "Tool check failed: \(name)"
        case .loopDetected(let name): return "Execution loop detected: \(name)"
        case .executionFailed(let error): return "Tool execution failed: \(error.localizedDescription)"
        }
    }
}
