// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// BuiltInTools — registers essential tools into ToolRegistry on boot.
///
/// Each tool corresponds to a real capability (info, skill lookup, audit query).
///
/// Typed tools: use ``ToolEntry.typed(name:toolset:argsType:handler:)`` for
/// compile-safe argument decoding — mirrors Foundation Models ``Tool<Arguments, Output>``
/// pattern without requiring the framework.
import Foundation

/// Bootstrap the tool registry with built-in tools.
///
/// - Parameters:
///   - registry: The tool registry to populate.
///   - skillRegistry: Optional skill registry for skill-related tools.
func bootstrapBuiltInTools(
    registry: ToolRegistry,
    skillRegistry: SkillRegistry? = nil,
) async {
    // ── info ────────────────────────────────────────────────────────────────
    struct InfoArgs: Codable {
        let topic: String?
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "info",
            toolset: "system",
            argsType: InfoArgs.self
        ) { args in
            switch args.topic ?? "status" {
            case "status": return "ocoreai runtime v0.7.0 — healthy"
            case "version": return "0.7.0"
            case "uptime": return "uptime: \(ProcessInfo.processInfo.systemUptime)"
            default: return "topic '\(args.topic ?? "unknown")' not recognized"
            }
        }
    )

    // ── skills_list ────────────────────────────────────────────────────────
    if let sr = skillRegistry {
        struct SkillsListArgs: Codable {
            let category: String?
        }

        try? await registry.register(
            ToolEntry.typed(
                name: "skills_list",
                toolset: "skills",
                argsType: SkillsListArgs.self
            ) { [sr] args in
                let names: [String] =
                    if let cat = args.category, !cat.isEmpty {
                        await sr.lookupCategory(cat).map(\.name)
                    } else {
                        await sr.list()
                    }
                if names.isEmpty {
                    return "no skills found"
                }
                return names.joined(separator: ", ")
            }
        )
    }

    // ── skills_lookup ──────────────────────────────────────────────────────
    if let sr = skillRegistry {
        struct SkillsLookupArgs: Codable {
            let name: String
        }

        try? await registry.register(
            ToolEntry.typed(
                name: "skills_lookup",
                toolset: "skills",
                argsType: SkillsLookupArgs.self
            ) { [sr] args in
                guard !args.name.isEmpty else { return "error: name required" }
                guard let skill = await sr.lookup(args.name) else {
                    return "skill '\(args.name)' not found"
                }
                return "\(skill.name)\n\(skill.description)\nCategory: \(skill.category)"
            }
        )
    }

    // ── skills_view ────────────────────────────────────────────────────────
    if let sr = skillRegistry {
        struct SkillsViewArgs: Codable {
            let name: String
            let file: String?
        }

        try? await registry.register(
            ToolEntry.typed(
                name: "skills_view",
                toolset: "skills",
                argsType: SkillsViewArgs.self
            ) { [sr] args in
                guard !args.name.isEmpty else { return "error: name required" }
                if let file = args.file {
                    // Delegated to skill system — return path for later resolve
                    return "resolve: \(args.name)/\(file)"
                }
                guard let skill = await sr.lookup(args.name) else {
                    return "skill '\(args.name)' not found"
                }
                return skill.promptContent
            }
        )
    }

    // ── read_file ───────────────────────────────────────────────────────────
    struct ReadFileArgs: Codable {
        let path: String
        let offset: Int?
        let limit: Int?
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "read_file",
            toolset: "files",
            argsType: ReadFileArgs.self,
            schema: ToolSchema(parameters: [
                "path": ToolParameter(
                    type: .string, description: "File path (absolute, ~, or cwd-relative)"),
                "offset": ToolParameter(
                    type: .integer, description: "1-based first line to read (default 1)"),
                "limit": ToolParameter(
                    type: .integer, description: "Max lines to read (default 2000)"),
            ])
        ) { args in
            try FileTools.read(path: args.path, offset: args.offset, limit: args.limit)
        }
    )

    // ── write_file ──────────────────────────────────────────────────────────
    struct WriteFileArgs: Codable {
        let path: String
        let content: String
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "write_file",
            toolset: "files",
            argsType: WriteFileArgs.self,
            description: "Write (create or replace) a text file; verified by read-back",
            schema: ToolSchema(parameters: [
                "path": ToolParameter(
                    type: .string, description: "File path to create or overwrite"),
                "content": ToolParameter(type: .string, description: "Full new content"),
            ]),
            isDestructive: true
        ) { args in
            try FileTools.write(path: args.path, content: args.content)
        }
    )

    // ── search_files ────────────────────────────────────────────────────────
    struct SearchFilesArgs: Codable {
        let path: String
        let pattern: String
        let target: String?
        let limit: Int?
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "search_files",
            toolset: "files",
            argsType: SearchFilesArgs.self,
            schema: ToolSchema(parameters: [
                "path": ToolParameter(
                    type: .string, description: "Directory (or file) to search in"),
                "pattern": ToolParameter(
                    type: .string,
                    description:
                        "Filename glob (* supported) in files mode, substring in content mode"),
                "target": ToolParameter(type: .string, description: "files (default) or content"),
                "limit": ToolParameter(type: .integer, description: "Max results (default 50)"),
            ])
        ) { args in
            try FileTools.search(
                path: args.path, pattern: args.pattern, target: args.target, limit: args.limit)
        }
    )

    // ── echo ────────────────────────────────────────────────────────────────
    struct EchoArgs: Codable {
        let message: String?
    }

    try? await registry.register(
        ToolEntry.typed(
            name: "echo",
            toolset: "debug",
            argsType: EchoArgs.self
        ) { args in
            args.message ?? ""
        }
    )
}
