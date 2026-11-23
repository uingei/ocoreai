// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Opt-in per-turn tool-surface curation. Decides which measured arm a native turn is
/// handed, and off means byte-identical to the old full-registry behavior.
///
/// The policy is the eval-measured arm, never re-invented here: the names and the paired
/// verdict live in `scripts/eval/README.md` § repeat recipe (6 tools vs all 40, McNemar
/// p<0.0001). Flipping the default is an owner ruling, not this file's call.
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
    /// nil surface. The no-tools route) returns the input untouched.
    static func apply(_ defs: [ToolDef]?, enabled: Bool) -> [ToolDef]? {
        guard enabled, let defs else { return defs }
        return curated(defs)
    }
}
