// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// FMToolBridge.swift — Bridge between ocoreai ToolRegistry and FoundationModels.Tool
///
/// Adapts ocoreai's tool infrastructure to the FM SDK's Tool protocol conformance,
/// enabling proper tool routing through the FM path (macOS 27+).

import Foundation
import Logging
import MLXLLM
import MLXLMCommon

#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
import FoundationModels

// MARK: - FM Tool Proxy

/// Adapts a ToolRegistry entry → FoundationModels.Tool protocol conformant type.
///
/// Generics: Arguments = String (raw JSON), Output = String (tool result text).
/// String conforms to ConvertibleFromGeneratedContent and PromptRepresentable
/// in the SDK, so this satisfies the protocol's associatedtype constraints.
///
/// The `parameters` property builds a GenerationSchema from the tool's JSON
/// schema by serializing → Codable init — the SDK's authoritative path.
///
/// NOTE: We use `FoundationModels.Tool` fully qualified everywhere to avoid
/// collision with `MLXLMCommon.Tool` (struct, not protocol).
@available(macOS 27.0, iOS 27.0, *)
struct FMToolProxy: FoundationModels.Tool {
    typealias Arguments = String
    typealias Output = String

    let name: String
    let description: String
    let parameters: FoundationModels.GenerationSchema
    let includesSchemaInInstructions: Bool

    /// Closure that forwards to ToolRegistry.call
    let _dispatch: @Sendable (String, String) async throws -> String

    init(
        name: String,
        description: String,
        parameters: FoundationModels.GenerationSchema,
        dispatch: @Sendable @escaping (String, String) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.includesSchemaInInstructions = true
        self._dispatch = dispatch
    }

    // MARK: - Tool protocol

    /// P1-fix: Forward to ToolRegistry.call with proper error handling.
    /// ToolRegistry.call() expects (name, JSON string) signature.
    @concurrent func call(arguments: String) async throws -> String {
        try await _dispatch(name, arguments)
    }

    // MARK: - Factory

    /// Build a [any FoundationModels.Tool] array from toToolSpecs output.
    static func tools(
        from registry: ToolRegistry,
        toolSpecs: [[String: any Sendable]],
        log logger: Logging.Logger
    ) -> [any FoundationModels.Tool] {
        var result: [any FoundationModels.Tool] = []
        for spec in toolSpecs {
            guard
                let funcDict = spec["function"] as? [String: any Sendable],
                let toolName = funcDict["name"] as? String,
                let toolDesc = funcDict["description"] as? String,
                let toolParams = funcDict["parameters"] as? [String: any Sendable]
            else { continue }

            let schema = tryToBuildSchema(from: toolParams, name: toolName, logger: logger)
            guard let schema else {
                // A tool with an unusable schema is worse than no tool — skip it.
                continue
            }
            let proxy = FMToolProxy(
                name: toolName,
                description: toolDesc,
                parameters: schema,
                dispatch: { toolName, args in
                    try await registry.call(toolName, arguments: args)
                }
            )
            result.append(proxy)
        }
        return result
    }

    /// Try to construct a GenerationSchema from JSON. Returns nil when the
    /// schema shape is incompatible (FM will refuse the tool; that is
    /// worse than no tool, unlike the old fake-empty-schema fallback).
    private static func tryToBuildSchema(
        from json: [String: any Sendable],
        name: String,
        logger: Logging.Logger
    ) -> FoundationModels.GenerationSchema? {
        // 09-05 根因实证（/tmp/fm-schema-probe）：GenerationSchema 的 Codable
        // 是 canonical 形状（必须带 "x-order"/"title"），OpenAI 风格 JSON
        // （"type":"object","properties":...）直接 decode 必 keyNotFound。
        // 正路 = SDK 公开的 DynamicGenerationSchema 树 → GenerationSchema(root:deps:)。
        let dict =
            json as? [String: Any]
            ?? (try? JSONSerialization.jsonObject(
                with: (try? JSONSerialization.data(withJSONObject: json))!
            )) as? [String: Any]
        guard let dict else {
            logger.warning("FMToolProxy: cannot normalize params for \(name)")
            return nil
        }
        if let dynamic = Self.makeDynamicSchema(from: dict, name: name) {
            if let schema = try? FoundationModels.GenerationSchema(
                root: dynamic, dependencies: []
            ) {
                return schema
            }
        }
        // 兜底：输入若已是 canonical 形状（含 "x-order"），保留原 decode 路。
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
            let schema = try? JSONDecoder().decode(
                FoundationModels.GenerationSchema.self, from: data
            )
        {
            return schema
        }
        logger.warning(
            "FMToolProxy: schema conversion failed for \(name) — tool skipped")
        return nil
    }

    /// 09-05: OpenAI/JSON-Schema 风格 dict → DynamicGenerationSchema 树。
    /// 递归处理 type/properties/required/items/enum，覆盖 ocoreai 21 内置工具的
    /// 全部实际形状（string/integer/number/boolean/array<scalar>/array<object>）。
    static func makeDynamicSchema(
        from schema: [String: Any],
        name: String
    ) -> FoundationModels.DynamicGenerationSchema? {
        let type = schema["type"] as? String ?? "object"

        // 标量映射 — Generable 原生类型
        switch type {
        case "string":
            return FoundationModels.DynamicGenerationSchema(type: String.self, guides: [])
        case "integer", "int64", "int32":
            return FoundationModels.DynamicGenerationSchema(type: Int.self, guides: [])
        case "number", "float", "double":
            return FoundationModels.DynamicGenerationSchema(type: Double.self, guides: [])
        case "boolean":
            return FoundationModels.DynamicGenerationSchema(type: Bool.self, guides: [])
        default:
            break
        }

        if type == "array" {
            let itemSchema = (schema["items"] as? [String: Any]) ?? ["type": "string"]
            guard
                let itemDynamic = makeDynamicSchema(
                    from: itemSchema, name: "\(name).items"
                )
            else { return nil }
            return FoundationModels.DynamicGenerationSchema(arrayOf: itemDynamic)
        }

        if type == "object" {
            let props = (schema["properties"] as? [String: [String: Any]]) ?? [:]
            let required = Set(schema["required"] as? [String] ?? [])
            var dynamicProps: [FoundationModels.DynamicGenerationSchema.Property] = []
            for (propName, propSchema) in props {
                guard
                    let child = makeDynamicSchema(
                        from: propSchema, name: "\(name).\(propName)"
                    )
                else { return nil }
                dynamicProps.append(
                    FoundationModels.DynamicGenerationSchema.Property(
                        name: propName,
                        description: propSchema["description"] as? String,
                        schema: child,
                        isOptional: !required.contains(propName)
                    )
                )
            }
            return FoundationModels.DynamicGenerationSchema(
                name: name,
                description: schema["description"] as? String,
                properties: dynamicProps
            )
        }

        // 不认识的类型（enum/object-const 等）→ 降级 string 而非整体放弃
        return FoundationModels.DynamicGenerationSchema(type: String.self, guides: [])
    }
}

// MARK: - Transcript helpers

@available(macOS 27.0, iOS 27.0, *)
enum FMTranscriptHelpers {
    // Transcript.Prompt takes [Transcript.Segment] — distinct from FoundationModels.Prompt (PromptRepresentable)
    typealias TMEntry = FoundationModels.Transcript.Entry
    typealias TMSegment = FoundationModels.Transcript.Segment
    typealias TTPrompt = FoundationModels.Transcript.Prompt

    /// Build a transcript.instructions entry with system instructions + tool definitions.
    static func instructionsEntry(
        systemInstructions: String?,
        tools: [any FoundationModels.Tool]?
    ) -> TMEntry? {
        guard let instr = systemInstructions, !instr.isEmpty else { return nil }
        let toolDefArray: [FoundationModels.Transcript.ToolDefinition]
        if let tools {
            toolDefArray = tools.map { FoundationModels.Transcript.ToolDefinition(tool: $0) }
        } else {
            toolDefArray = []
        }
        return TMEntry.instructions(
            FoundationModels.Transcript.Instructions(
                segments: [
                    TMSegment.text(FoundationModels.Transcript.TextSegment(content: instr))
                ],
                toolDefinitions: toolDefArray
            )
        )
    }

    /// Convert Chat.Message (MLXLMCommon) to transcript prompt/response entries.
    /// Handles text + image attachments.
    static func chatMessageEntries(
        from messages: [MLXLMCommon.Chat.Message]
    ) -> [TMEntry] {
        var entries: [TMEntry] = []

        for msg in messages {
            switch msg.role {
            case .user:
                var segments: [TMSegment] = []
                if !msg.content.isEmpty {
                    segments.append(
                        .text(FoundationModels.Transcript.TextSegment(content: msg.content)))
                }
                // NOTE: Transcript path carries text only. Transcript.ImageAttachment has
                // no public initializer (opaque SDK type), so image segments cannot be
                // constructed here — an SDK API-surface constraint, not a pending task.
                // Core value (tools/reasoning/sampling) is fully unlocked without images.
                _ = msg.images  // avoid unused warning
                if !segments.isEmpty {
                    entries.append(
                        TMEntry.prompt(
                            TTPrompt(segments: segments)
                        ))
                }
            case .assistant:
                if !msg.content.isEmpty {
                    entries.append(
                        TMEntry.response(
                            FoundationModels.Transcript.Response(segments: [
                                TMSegment.text(
                                    FoundationModels.Transcript.TextSegment(content: msg.content))
                            ])
                        ))
                }
            default:
                break
            }
        }

        return entries
    }

    /// Extract the primary user prompt text from the last user message in the array.
    /// Used by the FM path to pass actual user input instead of an empty string.
    static func lastUserPromptText(from messages: [MLXLMCommon.Chat.Message]) -> String {
        for msg in messages.reversed() {
            if msg.role == .user && !msg.content.isEmpty {
                return msg.content
            }
        }
        return " "  // fallback: non-empty placeholder for FM SDK safety
    }

    /// Build the full transcript from instructions + message history.
    static func build(
        systemInstructions: String?,
        messages: [MLXLMCommon.Chat.Message],
        tools: [any FoundationModels.Tool]?
    ) -> FoundationModels.Transcript {
        var entries: [TMEntry] = []
        if let instrEntry = instructionsEntry(
            systemInstructions: systemInstructions,
            tools: tools
        ) {
            entries.append(instrEntry)
        }
        entries.append(contentsOf: chatMessageEntries(from: messages))
        return FoundationModels.Transcript(entries: entries)
    }
}

#endif  // FoundationModelsIntegration
