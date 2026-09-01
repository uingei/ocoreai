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
    ///   - schema: Parameter schema exposed to the model (optional; defaults to empty).
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
        schema: ToolSchema = ToolSchema(),
        isDestructive: Bool = false,
        handler: @Sendable @escaping (Args) async throws -> String
    ) -> ToolEntry {
        let jsonDecoder = JSONDecoder()
        let _ = argsType  // type is inferred from generics; kept for API stability

        return ToolEntry(
            name: name,
            toolset: toolset,
            schema: schema,
            handler: { rawArgs in
                guard let data = rawArgs.data(using: .utf8), !data.isEmpty else {
                    throw ToolError.invalidParameter("Arguments required for tool '\(name)'")
                }
                let args: Args
                do {
                    args = try jsonDecoder.decode(Args.self, from: data)
                } catch {
                    throw ToolError.invalidParameter(
                        "Invalid arguments for '\(name)': \(error.localizedDescription)")
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
    let parameters: [String: ToolParameter]

    init(parameters: [String: ToolParameter] = [:]) {
        self.parameters = parameters
    }
}

/// Tool 参数描述（JSON Schema 面），对齐上游 MLXLMCommon.ToolParameter.schema 行为：
/// 每个参数在 JSON Schema 中暴露 `["type": ..., "description": ...]`，模型据此精确理解入参。
/// `final class`：支持 `items` 自嵌套（struct 不允许自递归存储；class 引用安全）。
/// `@unchecked Sendable`：所有存储属性 `let`（构造后不可变），跨隔离域共享安全。
final class ToolParameter: Codable, Equatable, @unchecked Sendable {
    let type: ParameterType
    let description: String
    /// 数组元素的子 schema（仅 `.array` 有效；对齐 JSON Schema `items`）。
    /// nil = 无 items 声明（向后兼容既有工具）。
    let items: ToolParameter?
    /// 对象必填键（仅 `.object` 有效；元素级必填，如 plan step 的 `step`）。
    let required: [String]?

    init(
        type: ParameterType, description: String = "", items: ToolParameter? = nil,
        required: [String]? = nil
    ) {
        self.type = type
        self.description = description
        self.items = items
        self.required = required
    }

    /// Static shorthands for dictionary literals — e.g. `["key": .string]`。
    /// 不可变全局 `let` + 类属性全 `let` → 无数据竞争面。
    static let string = ToolParameter(type: .string)
    static let integer = ToolParameter(type: .integer)
    static let boolean = ToolParameter(type: .boolean)
    static let array = ToolParameter(type: .array)
    static let object = ToolParameter(type: .object)

    // 值语义比较（测试字段级断言用；类默认引用相等，这里显式补值相等）。
    static func == (lhs: ToolParameter, rhs: ToolParameter) -> Bool {
        lhs.type == rhs.type
            && lhs.description == rhs.description
            && lhs.items == rhs.items
            && lhs.required == rhs.required
    }
}

/// Supported parameter types for tool argument coercion
enum ParameterType: String, Codable, CaseIterable {
    case string
    case integer
    case boolean
    case array
    case object
}

// MARK: - ToolDef bridge

extension ToolEntry {
    /// Convert to OpenAI-format ToolDef — used by Fast Path callers.
    func toToolDef() -> ToolDef {
        let function = FunctionDef(
            name: name,
            description: "Tool: \(name) [\(toolset)]. Parameters: \(parametersDescription)",
            parameters: buildParametersJSON()
        )
        return ToolDef(type: "function", function: function)
    }

    private var parametersDescription: String {
        schema.parameters.map { "\($0.key):\($0.value.type.rawValue)" }.joined(separator: ", ")
    }

    private func buildParametersJSON() -> [String: AnyCodable]? {
        guard !schema.parameters.isEmpty else { return nil }
        // Build properties as [String: AnyCodable] where each value is a JSON Schema object
        // containing both "type" and "description" — aligns with upstream ToolParameter.schema.
        // `.array` 元素带 `items`；`.object` 元素带 `required`（JSON Schema 标准形状）。
        func propSchema(_ param: ToolParameter) -> [String: Any] {
            var s: [String: Any] = ["type": param.type.rawValue]
            if !param.description.isEmpty {
                s["description"] = param.description
            }
            if let items = param.items {
                s["items"] = propSchema(items)
            }
            if let required = param.required {
                s["required"] = required
            }
            return s
        }

        var properties: [String: AnyCodable] = [:]
        for (paramName, param) in schema.parameters {
            properties[paramName] = AnyCodable(propSchema(param))
        }
        var json: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "properties": AnyCodable(properties),
        ]
        // Mark all declared parameters as required
        json["required"] = AnyCodable(Array(schema.parameters.keys))
        return json
    }
}

extension ParameterType {
    fileprivate var jsonSchemaType: String {
        switch self {
        case .string: return "string"
        case .integer: return "integer"
        case .boolean: return "boolean"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

// MARK: - Tool execution errors
enum ToolError: Error, LocalizedError {
    case notFound(String)
    case invalidParameter(String)
    case checkFailed(String)
    case loopDetected(String)
    case executionFailed(Error)
    /// Denied by a `PreToolUse` hook (codex `HookEventName.preToolUse`).
    /// Reason is the hook's message; surfaced to the caller as an HTTP 403-equivalent.
    case denied(reason: String)
    /// Exec-host failure breaker engaged (absorbs codex #41454: exec goal blocked
    /// after 3 consecutive failed attempts). Distinct from `loopDetected` so an
    /// agent can stop-and-retry with a different tool (a success unblocks it)
    /// rather than looking like a same-input cycle.
    case breakerEngaged(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let name): "Tool not found: \(name)"
        case .invalidParameter(let detail): "Invalid parameter: \(detail)"
        case .checkFailed(let name): "Tool check failed: \(name)"
        case .loopDetected(let name): "Execution loop detected: \(name)"
        case .executionFailed(let error): "Tool execution failed: \(error.localizedDescription)"
        case .denied(let reason): "Tool call denied by hook: \(reason)"
        case .breakerEngaged(let name):
            "Exec host blocked after 3 consecutive failures (tool: \(name))"
        }
    }
}
