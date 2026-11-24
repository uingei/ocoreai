// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ToolSearchTool.swift. The one tool a reachable turn declares besides the core: a BM25 search
/// over the tools this turn does not carry, whose hits the conversation then declares.
///
/// Registered only while `settings.toolSurface.reachable.enabled` was on at boot
/// (`bootstrapBuiltInTools`), so an off build's surface stays byte-identical to the plain one —
/// the `update_plan` route, one precedent. The ranking itself is the pure
/// ``ToolSurfaceReachability`` (pi's shape, `tool.ts:1-21`); this file owns only the tool
/// contract, the recording, and what the result is allowed to claim.
///
/// The recording goes to ``ToolSurfaceDiscovery`` under ``ToolInvocationContext/conversationKey``,
/// the key the dispatch chokepoint already sets. Absent key = absent set, and the result says so
/// rather than inventing a "next turn" that no lane will build (invariant 2).
import Foundation

enum ToolSearchTool {
    struct Args: Codable {
        let query: String
        let limit: Int?
    }

    /// A caller asking for more than this re-buys the bytes the reachable arm saves; pi caps the
    /// same list and for the same reason (`DEFAULT_TOOL_SEARCH_LIMIT`).
    static let maxLimit = 20

    static func toolEntry(registry: ToolRegistry) -> ToolEntry {
        ToolEntry.typed(
            name: ToolSurfaceReachability.searchToolName,
            toolset: "system",
            argsType: Args.self,
            description:
                "Search the installed tools this turn does not declare. Returns the best matches as \"name: description\" and records them for this conversation, so a later turn built from the registry declares them. Use when no declared tool fits the task.",
            schema: ToolSchema(
                parameters: [
                    "query": ToolParameter(
                        type: .string,
                        description: "What you need to do, in words (for example: render a video)"),
                    "limit": ToolParameter(
                        type: .integer,
                        description:
                            "Maximum matches to return (default \(ToolSurfaceReachability.defaultLimit), max \(maxLimit))"
                    ),
                ],
                required: ["query"]
            )
        ) { args in
            let defs = await registry.toToolDefs()
            let conversationKey = ToolInvocationContext.conversationKey
            let core = ToolSurfaceCuration.measuredArmNames.union(
                [ToolSurfaceReachability.searchToolName])
            let alreadyResident = core.union(
                await ToolSurfaceDiscovery.shared.names(for: conversationKey))
            let limit = max(1, min(args.limit ?? ToolSurfaceReachability.defaultLimit, maxLimit))
            let matches = ToolSurfaceReachability.rank(
                query: args.query, in: defs, excluding: alreadyResident, limit: limit)
            guard !matches.isEmpty else {
                return "No undiscovered tool matches \"\(args.query)\"."
            }
            var descriptions: [String: String] = [:]
            for def in defs {
                descriptions[def.function.name] = def.function.description ?? ""
            }
            var lines = matches.map {
                "- \($0.name): \(descriptions[$0.name] ?? "")"
            }
            if let conversationKey {
                await ToolSurfaceDiscovery.shared.record(
                    Set(matches.map(\.name)), for: conversationKey)
                lines.append(
                    "Recorded \(matches.count) match\(matches.count == 1 ? "" : "es") into this "
                        + "conversation's discovered set; a turn built from the registry declares "
                        + "them next turn.")
            } else {
                lines.append(
                    "Nothing recorded: this call is owned by no conversation, so no discovered "
                        + "set exists to extend.")
            }
            return lines.joined(separator: "\n")
        }
    }
}
