// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Opt-in per-turn tool-surface curation. Decides which measured arm a native turn is
/// handed, and off means byte-identical to the old full-registry behavior.
///
/// The policy is the eval-measured arm, never re-invented here: the names and the paired
/// verdict live in `scripts/eval/README.md` § repeat recipe (6 tools vs all 40, McNemar
/// p<0.0001). Flipping the default is an owner ruling, not this file's call.
///
/// The third arm is the reachable one (``ToolSurfaceReachability``): the core, `tool_search`,
/// and what this conversation has discovered. It wins over curation when both are on, and it
/// refuses to engage unless `tool_search` is actually in the surface — a narrowed turn with no
/// way to reach the rest is a trap, not an arm.
enum ToolSurfaceCuration {
    /// The measured 6-tool arm's tool names, as registered (`BuiltInTools.swift`).
    static let measuredArmNames: Set<String> = [
        "read_file", "write_file", "edit_file", "edit_lines", "search_files", "exec_command",
    ]

    /// Registry-order subset over the measured arm; a name the registry lacks is simply
    /// absent. Adds nothing that `defs` did not already carry.
    static func curated(_ defs: [ToolDef]) -> [ToolDef] {
        defs.filter { measuredArmNames.contains($0.function.name) }
    }

    /// The whole flag decision, so off/on is assertable without a view model. Off (or a
    /// nil surface. The no-tools route) returns the input untouched. With `reachable` on,
    /// the deferred tools leave the turn and `discovered` (what this conversation's
    /// `tool_search` calls found) re-enters them as declarations.
    static func apply(
        _ defs: [ToolDef]?, enabled: Bool,
        reachable: Bool = false, discovered: Set<String> = []
    ) -> [ToolDef]? {
        guard let defs else { return nil }
        if reachable,
            defs.contains(where: { $0.function.name == ToolSurfaceReachability.searchToolName })
        {
            let core = measuredArmNames.union([ToolSurfaceReachability.searchToolName])
            return ToolSurfaceReachability.residentSurface(
                all: defs, core: core, discovered: discovered)
        }
        guard enabled else { return defs }
        return curated(defs)
    }
}
