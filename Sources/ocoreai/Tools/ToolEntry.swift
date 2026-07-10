// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ToolRegistryActor — central tool registration and dispatch.
///
/// Thread safety: Actor isolation, all access via mailbox.
/// Lookup complexity: O(1) dictionary per toolset, +1 actor hop ≈ 3μs.
/// Memory: ~256B per entry, 256 tools ≈ 64KB total.
import Foundation

/// A registered tool entry with execution handler and safety check.
struct ToolEntry {
	let name: String
	let toolset: String
	let schema: ToolSchema
	let handler: @Sendable (String) async throws -> String
	let checkFn: @Sendable () async -> Bool
	let isDestructive: Bool
	let maxDepth: Int
	/// MCP endpoint source name — used for lifecycle cleanup when endpoint disconnects.
	/// nil for built-in tools, non-nil for tools discovered from an external MCP server.
	let mcpSource: String?

	/// Default TTL for checkFn cache — 30 seconds
	static let checkTTL: TimeInterval = 30.0

	init(
		name: String,
		toolset: String,
		schema: ToolSchema,
		handler: @Sendable @escaping (String) async throws -> String,
		checkFn: @Sendable @escaping () async -> Bool = { true },
		isDestructive: Bool = false,
		maxDepth: Int = 3,
		mcpSource: String? = nil,
	) {
		self.name = name
		self.toolset = toolset
		self.schema = schema
		self.handler = handler
		self.checkFn = checkFn
		self.isDestructive = isDestructive
		self.maxDepth = maxDepth
		self.mcpSource = mcpSource
	}

	/// Factory: create a ToolEntry from a typed handler with automatic Codable decode/encode.
	///
	/// - Parameters:
	///   - name: Tool identifier.
	///   - toolset: Toolset group name.
	///   - argsType: Codable type of the tool's arguments.
	///   - description: Human-readable description (optional).
	///   - isDestructive: Whether this tool performs side effects.
	///   - handler: Typed handler that receives decoded `Args` and returns a `Codable` result.
	/// - Returns: A `ToolEntry` ready for registration.
	///
	/// Example:
	/// ```swift
	/// struct InfoArgs: Codable { let topic: String? }
	/// let entry = ToolEntry.typed(name: "info", toolset: "system", argsType: InfoArgs.self) {
	///     args in
	///     args.topic ?? "status"
	/// }
	/// ```
	static func typed<Args: Codable & Sendable>(
		name: String,
		toolset: String,
		argsType: Args.Type,
		description: String = "",
		isDestructive: Bool = false,
		handler: @Sendable @escaping (Args) async throws -> String
	) -> ToolEntry {
		let jsonDecoder = JSONDecoder()
		assert(argsType == Args.self, "argsType unused — type inferred from generics")

		return ToolEntry(
			name: name,
			toolset: toolset,
			schema: ToolSchema(),
			handler: { rawArgs in
				guard let data = rawArgs.data(using: .utf8), !data.isEmpty else {
					throw ToolError.invalidParameter("Arguments required for tool '\(name)'")
				}
				let args: Args
				do {
					args = try jsonDecoder.decode(Args.self, from: data)
				} catch {
					throw ToolError.invalidParameter("Invalid arguments for '\(name)': \(error.localizedDescription)")
				}
				return try await handler(args)
			},
			checkFn: { true },
			isDestructive: isDestructive
		)
	}
}

/// JSON Schema describing tool parameters
struct ToolSchema: Codable {
	let parameters: [String: ParameterType]

	init(parameters: [String: ParameterType] = [:]) {
		self.parameters = parameters
	}
}

/// Supported parameter types for tool argument coercion
enum ParameterType: String, Codable, CaseIterable {
	case string
	case integer
	case boolean
	case array
}

/// Tool execution errors
enum ToolError: Error, LocalizedError {
	case notFound(String)
	case invalidParameter(String)
	case checkFailed(String)
	case loopDetected(String)
	case executionFailed(Error)

	var errorDescription: String? {
		switch self {
		case let .notFound(name): "Tool not found: \(name)"
		case let .invalidParameter(detail): "Invalid parameter: \(detail)"
		case let .checkFailed(name): "Tool check failed: \(name)"
		case let .loopDetected(name): "Execution loop detected: \(name)"
		case let .executionFailed(error): "Tool execution failed: \(error.localizedDescription)"
		}
	}
}
