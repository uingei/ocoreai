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

    /// Try to construct a GenerationSchema from JSON, fallback to empty.
    private static func tryToBuildSchema(
        from json: [String: any Sendable],
        name: String,
        logger: Logging.Logger
    ) -> FoundationModels.GenerationSchema {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            logger.warning("FMToolProxy: cannot serialize params for \(name)")
            return emptySchema
        }
        return
            (try? JSONDecoder().decode(
                FoundationModels.GenerationSchema.self,
                from: data
            )) ?? emptySchema
    }

    private static var emptySchema: FoundationModels.GenerationSchema {
        do {
            let json: [String: Any] = ["type": "object", "properties": [:]]
            let data = try JSONSerialization.data(withJSONObject: json)
            return try JSONDecoder().decode(
                FoundationModels.GenerationSchema.self,
                from: data
            )
        } catch {
            // Should never happen — empty object schema is valid per SDK.
            // If it does, the FM path caller (tryToBuildSchema) already has a ?? fallback
            // to this same value, so we use a secondary decode path.
            return
                (try? {
                    let json = #"{"type":"string"}"#.data(using: .utf8)!
                    return try JSONDecoder().decode(
                        FoundationModels.GenerationSchema.self, from: json)
                }())
                ?? {
                    // Absolute last resort — should be unreachable
                    fatalError("FMToolBridge: empty schema decode failed (sdk regression)")
                }()
        }
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
                // NOTE: Transcript image attachments require Transcript.ImageAttachment which
                // has no public initializer (opaque SDK type). For now, skip images in transcript
                // path — the core value (tools/reasoning/sampling) is unlocked without them.
                // TODO: Investigate VMultimodalSession or PromptBuilder path for images.
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
