// ToolSurfaceCurationHonestyTests.swift — the native turn's tool surface is honest to the
// flag: off hands the full registry untouched, on hands exactly the eval-measured 6-tool
// arm — never more, never re-invented (AGENTS.md invariant 2 applied to what a turn is
// handed; the measured arm and its verdict live in `scripts/eval/README.md` § repeat
// recipe).

import Foundation
import Testing

@testable import ocoreai

@Suite("tool-surface curation (off = untouched, on = measured arm exactly)", .serialized)
struct ToolSurfaceCurationHonestyTests {

    private func def(_ name: String) -> ToolDef {
        ToolDef(function: FunctionDef(name: name, description: nil, parameters: nil))
    }

    private func names(_ defs: [ToolDef]?) -> [String] {
        (defs ?? []).map { $0.function.name }
    }

    @Test("the policy pins the eval-measured arm's six names exactly")
    func policyIsTheMeasuredArm() {
        let expected: Set<String> = [
            "read_file", "write_file", "edit_file", "edit_lines", "search_files", "exec_command",
        ]
        #expect(ToolSurfaceCuration.measuredArmNames == expected)
    }

    @Test("off returns the surface untouched, order and count included")
    func offIsUntouched() {
        let defs = ["clock", "exec_command", "view_screen", "read_file"].map { def($0) }
        #expect(names(ToolSurfaceCuration.apply(defs, enabled: false)) == names(defs))
    }

    @Test("the no-tools route stays nil whatever the flag says")
    func nilSurfaceSurvives() {
        #expect(ToolSurfaceCuration.apply(nil, enabled: false) == nil)
        #expect(ToolSurfaceCuration.apply(nil, enabled: true) == nil)
    }

    @Test("on keeps exactly the arm names, in the registry's own order")
    func onKeepsArmInRegistryOrder() {
        let defs = ["clock", "exec_command", "view_screen", "read_file", "speak", "edit_lines"]
            .map { def($0) }
        #expect(
            names(ToolSurfaceCuration.apply(defs, enabled: true))
                == ["exec_command", "read_file", "edit_lines"])
    }

    @Test("an arm name missing from the registry degrades to the intersection, never adds")
    func missingArmNameDegrades() {
        let defs = ["write_file", "memory_search", "edit_file"].map { def($0) }
        #expect(
            names(ToolSurfaceCuration.apply(defs, enabled: true))
                == ["write_file", "edit_file"])
        #expect(names(ToolSurfaceCuration.apply([], enabled: true)).isEmpty)
    }
}
