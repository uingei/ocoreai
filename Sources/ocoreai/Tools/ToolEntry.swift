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
    /// Human-readable description of what the tool does — surfaced to the model
    /// via `toToolSpecs()` / `toToolDef()`. Empty = not provided → callers fall
    /// back to a clean synthesized line (never the raw source text).
    let description: String
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
        description: String = "",
        handler: @Sendable @escaping (String) async throws -> String,
        checkFn: @Sendable @escaping () async -> Bool = { true },
        isDestructive: Bool = false,
        maxDepth: Int = 3,
        mcpSource: String? = nil,
    ) {
        self.name = name
        self.toolset = toolset
        self.schema = schema
        self.description = description
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
            description: description,
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
    /// 09-06: 工具级"必填键"子集(JSON Schema inputSchema.required 的忠实透传)。
    /// nil = 未声明 → 下游惯例保持 "所有已声明 = required"(built-in 现有行为)。
    /// 非 nil = 仅这些键 required(可选参数不再被误标必填)。
    let required: [String]?

    init(parameters: [String: ToolParameter] = [:], required: [String]? = nil) {
        self.parameters = parameters
        self.required = required
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
    /// 09-06: number(=JSON Schema "number"/float)参数 shorthand。
    static let number = ToolParameter(type: .number)
    /// 对象必填键（仅 `.object` 有效；元素级必填，如 plan step 的 `step`）。
    let required: [String]?
    /// 对象子键 schema（仅 `.object` 有效；对齐 JSON Schema `properties`）。
    /// 09-05: 补齐 — 此前模型只带 `required` 键名、不带键类型，对象面
    /// （如 update_plan.plan items 的 step/status）在 wire/FM 层退化空 object。
    let properties: [String: ToolParameter]?

    init(
        type: ParameterType, description: String = "", items: ToolParameter? = nil,
        required: [String]? = nil, properties: [String: ToolParameter]? = nil
    ) {
        self.type = type
        self.description = description
        self.items = items
        self.required = required
        self.properties = properties
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
            && lhs.properties == rhs.properties
    }
}

/// Supported parameter types for tool argument coercion
enum ParameterType: String, Codable, CaseIterable {
    case string
    case integer
    /// 09-06: float 参数档(JSON Schema "number")。此前 MCP number 字段被映射成 .integer,
    /// wire "integer" — 模型按整型生成, float 字段截断。
    case number
    case boolean
    case array
    case object
}

// MARK: - ToolDef bridge

extension ToolEntry {
    /// Convert to OpenAI-format ToolDef — used by Fast Path callers.
    func toToolDef() -> ToolDef {
        // 09-06: 优先工具自带 description;缺失才回退合成行(name/toolset/参数摘要)。
        // 此前合成行无条件发送——22 个有真实描述的内置工具也发不出。
        let synth = "Tool: \(name) [\(toolset)]. Parameters: \(parametersDescription)"
        let function = FunctionDef(
            name: name,
            description: (!description.isEmpty ? description : synth),
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
            if let properties = param.properties, !properties.isEmpty {
                var props: [String: Any] = [:]
                for (k, v) in properties { props[k] = propSchema(v) }
                s["properties"] = props
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
        case .number: return "number"
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
