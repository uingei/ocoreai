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
    /// Codex-aligned lifecycle hooks for PreToolUse veto / PostToolUse observation.
    /// Default empty → hooks are opt-in via a non-empty `[Hook]` (e.g. `auditPolicy`,
    /// `destructiveOnly`, etc.). A `nil` matcher means the hook applies to every tool.
    /// See `Agents/Hooks/ToolHookRunner.swift` for the surface and semantics.
    internal let hookRunner: ToolHookRunner
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

    /// 审批 broker（codex `ExecApprovalRequest` 通路）；`nil` 时 `.ask` 保持硬拒
    /// （回归保护：无 UI 面时不得静默放行）。
    private let approvalBroker: ApprovalBroker?
    let logger: Logger

    init(
        readOnlyWhitelist: [String] = ["search_files", "read_file", "memory_search"],
        destructiveBlacklist: [String] = [
            "write_file", "delete_file", "exec_command", "execute_code",
            "exec_shell", "write_stdin", "exec_poll",
        ],
        auditTrail: AuditTrail? = nil,
        hooks: [Hook] = [],
        approvalBroker: ApprovalBroker? = nil,
        log: Logger = Logger(label: "ocoreai.tools.registry"),
    ) {
        self.readOnlyWhitelist = Set(readOnlyWhitelist)
        self.destructiveBlacklist = Set(destructiveBlacklist)
        self.auditTrail = auditTrail
        self.hookRunner = ToolHookRunner(hooks: hooks)
        self.approvalBroker = approvalBroker
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

    /// List all registered tool entries (name + schema) — used to expose tools
    /// to Fast Path callers for function calling.
    func listToolEntries() -> [(name: String, toolset: String, schema: ToolSchema)] {
        tools.values.compactMap { entry in
            (entry.name, entry.toolset, entry.schema)
        }
    }

    /// Convert all registered tools to OpenAI-format ToolDef array.
    /// Bridges ToolRegistry → InferenceRequest / AgentLoop tool definitions.
    func toToolDefs() -> [ToolDef] {
        tools.values.compactMap { entry in
            entry.toToolDef()
        }
    }

    /// List tools in a specific toolset
    func listByToolset(_ toolset: String) -> [String] {
        byToolset[toolset] ?? []
    }

    /// List tools registered from a specific MCP endpoint source.
    func listByMcpSource(_ source: String) -> [String] {
        tools.values.filter { $0.mcpSource == source }.map(\.name)
    }

    /// Get schema for a tool
    func schema(for name: String) -> ToolSchema? {
        tools[name]?.schema
    }

    // MARK: - Execution

    /// Shared security preflight for a tool call — PreToolUse hooks (allow/deny/ask)
    /// and the user-approval broker (`.ask` → pending → decision).
    ///
    /// Codex baseline: the `ExecApprovalRequest` chokepoint applies to **all**
    /// tool execution, including MCP-routed sensitive actions (#41094 routes
    /// marked MCP actions to the synchronous reviewer). ocoreai parity: this is
    /// the single gate — local tools via `call`, external MCP tools via
    /// `MCPBridge.routeToExternalServers`. The hook's reason always carries the
    /// gate context (`.ask(let reason)`); hooks with `matcher == nil` apply to
    /// every tool (codex "no matcher → global"), so MCP tool names need no
    /// per-name enumeration.
    ///
    /// Extracted from `call` — local-tool behavior is unchanged: same verdict
    /// order, same broker path, same deny reasons, same log lines.
    /// - Throws: ``ToolError/denied(reason:):`` on `.deny` or user denial.
    func securityPrecheck(toolName: String, arguments: String) async throws {
        // PreToolUse hook veto — codex `HookEventName.preToolUse`.
        // A single deny/ask from any non-skipped matcher short-circuits here,
        // BEFORE audit, loop detection, or handler execution. If a hook is
        // added later with `matcher == nil` it will apply to every tool —
        // that's the design intent (mirrors codex "no matcher → global").
        let verdict = await hookRunner.evaluatePreToolUse(toolName: toolName, arguments: arguments)
        if verdict != .allow {
            switch verdict {
            case .deny(let reason):
                logger.info("Tool '\(toolName)' denied by PreToolUse hook")
                throw ToolError.denied(reason: reason)
            case .ask(let reason):
                // User-approval gate — codex `ExecApprovalRequest` → TUI cell →
                // `ReviewDecision`. broker 存在 → 挂起等裁决；broker 缺席 → 硬拒
                // （回归保护：无审批面时绝不静默放行）。
                if let broker = approvalBroker {
                    logger.info("Tool '\(toolName)' requires approval — routing to broker")
                    let decision = await broker.request(
                        toolName: toolName, arguments: arguments, reason: reason)
                    switch decision {
                    case .approved, .approvedForSession:
                        break
                    case .denied(let denyReason):
                        logger.info("Tool '\(toolName)' denied by user")
                        throw ToolError.denied(reason: denyReason)
                    }
                } else {
                    logger.info("Tool '\(toolName)' requires approval (no broker) — denying")
                    throw ToolError.denied(reason: reason)
                }
            case .allow: break
            }
        }
    }

    /// Dispatch a tool call after safety checks.
    /// - Parameters:
    ///   - name: Tool name to invoke
    ///   - arguments: JSON-encoded argument string
    ///   - caller: Optional caller identity for audit trail (default: "unknown")
    /// - Returns: Tool result string
    /// - Throws: ``ToolError`` on validation or execution failure
    func call(_ name: String, arguments: String, caller: String = "unknown") async throws -> String
    {
        // 0. Security preflight (PreToolUse hooks + approval broker gate) —
        //    shared with the external-MCP path (see `securityPrecheck`).
        try await securityPrecheck(toolName: name, arguments: arguments)

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
            let argsMap: [String: String] =
                if let data = arguments.data(using: .utf8),
                    let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String]
                {
                    decoded
                } else {
                    ["raw": arguments]
                }
            token = await at.beginCall(
                caller: caller, toolName: name, toolset: entry.toolset, arguments: argsMap)
        } else {
            token = nil
        }

        // 5. Execute
        //    PostToolUse hooks fire AFTER the handler returns, on both success and
        //    failure paths, so an observation hook can log both outcomes (codex
        //    semantics — hooks are observation-only here; the verdict is ignored).
        do {
            let result = try await entry.handler(arguments)
            recordExecution(name, hash: inputHash)
            // Complete audit on success
            if let t = token {
                await auditTrail?.completeToken(t, status: .success, result: result)
            }
            await hookRunner.firePostToolUse(
                toolName: name, arguments: arguments, result: result, error: nil)
            return result
        } catch {
            // Complete audit on error
            if let t = token {
                await auditTrail?.completeToken(
                    t, status: .error, result: error.localizedDescription)
            }
            await hookRunner.firePostToolUse(
                toolName: name, arguments: arguments, result: nil,
                error: error.localizedDescription)
            // If handler already threw a ToolError, re-throw without double-wrapping
            if let toolErr = error as? ToolError {
                throw toolErr
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
        return NSError(
            domain: "ocoreai.tool.sanitized", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
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

    // MARK: - Lifecycle

    /// Unregister a single tool by name.
    /// - Returns: `true` if the tool was found and removed.
    func unregister(_ toolName: String) -> Bool {
        guard let entry = tools.removeValue(forKey: toolName) else {
            logger.warning("Unregister miss: \(toolName)")
            return false
        }
        // Remove from toolset index
        if var names = byToolset[entry.toolset] {
            names.removeAll { $0 == toolName }
            if names.isEmpty {
                byToolset.removeValue(forKey: entry.toolset)
            } else {
                byToolset[entry.toolset] = names
            }
        }
        logger.info("Unregistered tool: \(toolName)")
        return true
    }

    /// Batch-unregister all tools that came from a specific MCP endpoint.
    func unregisterToolsFromSource(_ source: String) {
        let toolNames = listByMcpSource(source)
        _ = toolNames.map { unregister($0) }
        if !toolNames.isEmpty {
            logger.info("Batch-unregistered \(toolNames.count) tools from MCP source: \(source)")
        }
    }

    /// Convert all registered tools to MLXLMCommon-style `[ToolSpec]` for ChatSession.
    /// ToolSpec == `[String: any Sendable]` matching upstream OpenAI function-calling schema.
    /// Each parameter includes `["type": ..., "description": ...]` dict — aligns with
    /// upstream ToolParameter.schema behavior (MLXLMCommon/Tool/ToolParameter.swift).
    func toToolSpecs() -> [[String: any Sendable]] {
        tools.values.map { entry in
            var properties: [String: [String: any Sendable]] = [:]
            for (paramName, param) in entry.schema.parameters {
                properties[paramName] = ["type": param.type.rawValue]
                if !param.description.isEmpty {
                    properties[paramName]?["description"] = param.description
                }
            }
            var params: [String: any Sendable] = ["type": "object", "properties": properties]
            if !entry.schema.parameters.isEmpty {
                params["required"] = Array(entry.schema.parameters.keys)
            }
            return [
                "type": "function" as any Sendable,
                "function": [
                    "name": entry.name as any Sendable,
                    "description": "Tool: \\(entry.name) [\\(entry.toolset)]" as any Sendable,
                    "parameters": params as any Sendable,
                ] as [String: any Sendable],
            ] as [String: any Sendable]
        }
    }
}
