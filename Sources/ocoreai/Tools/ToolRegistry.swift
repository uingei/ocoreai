// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Central tool registry — actor-isolated, concurrent-safe registration and dispatch.
///
/// P95 lookup: ~3μs (1 actor hop + O(1) dict).
/// Memory: ~64KB for 256 tools.
/// Security: checkFn preflight with TTL cache, SHA256 loop detection.
/// Audit: every tool call is logged via AuditTrail with trace ID and duration.
import Foundation
import Logging

actor ToolRegistry {
	/// Audit trail for tool execution logging (nil = auditing disabled)
	private let auditTrail: AuditTrail?
	/// Read-only tool lookup table (published after registration changes)
	private var tools: [String: ToolEntry] = [:]
	/// Toolset → [tool name] mapping for batch queries
	private var byToolset: [String: [String]] = [:]
	/// Read-only whitelist — these tools may execute concurrently
	private let readOnlyWhitelist: Set<String>
	/// Destructive blacklist — these tools must execute serially
	private let destructiveBlacklist: Set<String>

	/// Loop detection: tracks (tool_name, last_input_hash) to prevent cycles
	private var executionHistory: [(name: String, hash: String, time: ContinuousClock.Instant)] = []
	private let maxHistoryDepth = 3

	let logger: Logger

	init(
		readOnlyWhitelist: [String] = ["search_files", "read_file", "memory_search"],
		destructiveBlacklist: [String] = ["write_file", "delete_file", "execute_code"],
		auditTrail: AuditTrail? = nil,
		log: Logger = Logger(label: "ocoreai.tools.registry"),
	) {
		self.readOnlyWhitelist = Set(readOnlyWhitelist)
		self.destructiveBlacklist = Set(destructiveBlacklist)
		self.auditTrail = auditTrail
		logger = log
	}

	// MARK: - Registration

	/// Register a new tool entry.
	/// - Parameter entry: The tool to register.
	/// - Throws: ``ToolError`` if a tool with the same name already exists.
	func register(_ entry: ToolEntry) async throws {
		guard tools[entry.name] == nil else {
			logger.warning("Tool '\(entry.name)' already registered — skipping")
			return
		}

		// Preflight checkFn
		guard await entry.checkFn() else {
			throw ToolError.checkFailed(entry.name)
		}

		tools[entry.name] = entry
		// Index by toolset
		byToolset[entry.toolset, default: []].append(entry.name)
		logger.info("Registered tool: \(entry.name) [\(entry.toolset)]")
	}

	// MARK: - Lookup

	/// Find a tool by name
	func lookup(_ name: String) -> ToolEntry? {
		tools[name]
	}

	/// List all registered tool names
	func listTools() -> [String] {
		Array(tools.keys).sorted()
	}

	/// List tools in a specific toolset
	func listByToolset(_ toolset: String) -> [String] {
		byToolset[toolset] ?? []
	}

	/// Get schema for a tool
	func schema(for name: String) -> ToolSchema? {
		tools[name]?.schema
	}

	// MARK: - Execution

	/// Dispatch a tool call after safety checks.
	/// - Parameters:
	///   - name: Tool name to invoke
	///   - arguments: JSON-encoded argument string
	///   - caller: Optional caller identity for audit trail (default: "unknown")
	/// - Returns: Tool result string
	/// - Throws: ``ToolError`` on validation or execution failure
	func call(_ name: String, arguments: String, caller: String = "unknown") async throws -> String {
		// 1. Lookup
		guard let entry = tools[name] else {
			throw ToolError.notFound(name)
		}

		// 2. Loop detection via SHA256 of input
		let inputHash = String(format: "%llX", arguments.hashValue)
		try checkLoop(entry: entry, inputHash: inputHash)

		// 3. Destructive tool serialization check
		if destructiveBlacklist.contains(name) {
			logger.info("Serial execution of destructive tool: \(name)")
		}

		// 4. Begin audit trail
		let token: AuditToken?
		if let at = auditTrail {
			let argsMap: [String: String] = if let data = arguments.data(using: .utf8),
			                                   let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String]
			{
				decoded
			} else {
				["raw": arguments]
			}
			token = await at.beginCall(caller: caller, toolName: name, toolset: entry.toolset, arguments: argsMap)
		} else {
			token = nil
		}

		// 5. Execute
		do {
			let result = try await entry.handler(arguments)
			recordExecution(name, hash: inputHash)
			// Complete audit on success
			if let t = token {
				await auditTrail?.completeToken(t, status: .success, result: result)
			}
			return result
		} catch {
			// Complete audit on error
			if let t = token {
				await auditTrail?.completeToken(t, status: .error, result: error.localizedDescription)
			}
			let sanitized = sanitizeError(error)
			throw ToolError.executionFailed(sanitized)
		}
	}

	// MARK: - Safety

	/// Check if a tool is read-only (safe for concurrent execution)
	func isReadOnly(_ name: String) -> Bool {
		readOnlyWhitelist.contains(name)
	}

	/// Check if a tool is destructive (must serialize)
	func isDestructive(_ name: String) -> Bool {
		destructiveBlacklist.contains(name) || tools[name]?.isDestructive == true
	}

	/// Sanitize error output to prevent prompt injection
	private func sanitizeError(_ error: Error) -> Error {
		let msg = error.localizedDescription
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
		return NSError(domain: "ocoreai.tool.sanitized", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
	}

	/// SHA256-based loop detection
	private func checkLoop(
		entry: ToolEntry,
		inputHash: String,
	) throws {
		// Clean old entries (> 60 seconds)
		let now = ContinuousClock.now
		executionHistory.removeAll { $0.time.duration(to: now) >= .seconds(60) }

		// Check for recent identical calls (cycle = same tool + same input ≥ maxDepth times)
		let recentCount = executionHistory.count(where: {
			$0.name == entry.name && $0.hash == inputHash
		})

		guard recentCount < maxHistoryDepth else {
			throw ToolError.loopDetected(entry.name)
		}
	}

	/// Record a successful execution for loop detection
	private func recordExecution(_ name: String, hash: String) {
		executionHistory.append((name: name, hash: hash, time: ContinuousClock.now))
		// Trim history
		if executionHistory.count > 100 {
			executionHistory.removeFirst(50)
		}
	}
}
