// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `get_plan` 读面 — 精确值测试(全离线: 快照注入, 不触 PlanTaskStore / SQLite).
///
/// 覆盖:
///   PlanRead.render  — 混合 3 状态计数精确 / step 1:1 顺序 / 三状态 tick 记号精确 /
///                      note 有/无 / 未知状态显式标记 / 空 items 边界 / 缺席诚实文案
///   PlanRead.utcTime — epoch 精确锚点(0 / 86400 / 31536000)
///   GetPlanClient    — 注册面(plan toolset · 零参 schema · 名称)
import Foundation
import Testing

@testable import ocoreai

// MARK: - fixture

private func snap(
    _ items: [(String, String)],
    note: String? = nil,
    ts: Int64 = 1_788_415_211
) -> PlanSnapshot {
    PlanSnapshot(
        items: items.map { PlanSnapshot.Item(step: $0.0, status: $0.1) },
        explanation: note,
        updatedAt: ts)
}

@Suite("get_plan render")
struct GetPlanRenderTests {

    @Test
    func mixedStatusExactCountsAndOrder() {
        let out = PlanRead.render(
            snap(
                [
                    ("init repo", "completed"),
                    ("fix channel gating", "in_progress"),
                    ("add tests", "pending"),
                    ("docs", "pending"),
                ], note: "修复感知轴"))
        let lines = out.components(separatedBy: "\n")
        #expect(lines.count == 7)
        #expect(lines[0] == "plan — 4 steps: 1 completed, 1 in_progress, 2 pending")
        #expect(lines[1] == "note: 修复感知轴")
        #expect(lines[2] == "1. [x] init repo (completed)")
        #expect(lines[3] == "2. [>] fix channel gating (in_progress)")
        #expect(lines[4] == "3. [ ] add tests (pending)")
        #expect(lines[5] == "4. [ ] docs (pending)")
        #expect(lines[6].hasPrefix("updated: ") && lines[6].hasSuffix(" UTC"))
    }

    @Test
    func absentReportsHonestPointer() {
        #expect(
            PlanRead.render(nil)
                == "no plan recorded in this session — call update_plan to create one")
    }

    @Test
    func emptyItemsHeaderZeroCounts() {
        let out = PlanRead.render(snap([], note: nil))
        let lines = out.components(separatedBy: "\n")
        #expect(lines.count == 2)  // header + updated, 无 step 行
        #expect(lines[0] == "plan — 0 steps: 0 completed, 0 in_progress, 0 pending")
        #expect(lines[1].hasPrefix("updated: "))
    }

    @Test
    func blankExplanationOmitsNoteLine() {
        // 空/纯空白 explanation 不产生 note 行(不渲染噪声)。
        for blank in ["", "   ", "\n"] {
            let out = PlanRead.render(snap([("a", "pending")], note: blank))
            let lines = out.components(separatedBy: "\n")
            #expect(lines.count == 3)
            #expect(!lines.contains { $0.hasPrefix("note:") })
        }
    }

    @Test
    func unknownStatusMarkedExplicitly() {
        // 非三值状态(库内历史数据可能)→ tick 显式 `?`, 原文照显(不静默改写)。
        let out = PlanRead.render(snap([("legacy", "blocked")]))
        let lines = out.components(separatedBy: "\n")
        #expect(lines[0] == "plan — 1 steps: 0 completed, 0 in_progress, 0 pending")
        #expect(lines[1] == "1. [?] legacy (blocked)")
    }

    @Test
    func stepTextVerbatim() {
        // step 原文逐字透传(不 trim/不改写): trim 的是 note, 不是 step。
        let out = PlanRead.render(snap([("  spaced  step  ", "pending")]))
        #expect(out.contains("  spaced  step   (pending)"))
    }
}

@Suite("get_plan utcTime")
struct GetPlanUtcTests {

    @Test
    func epochAnchorsExact() {
        #expect(PlanRead.utcTime(0) == "1970-01-01 00:00:00 UTC")
        #expect(PlanRead.utcTime(86_400) == "1970-01-02 00:00:00 UTC")
        #expect(PlanRead.utcTime(31_536_000) == "1971-01-01 00:00:00 UTC")
    }

    @Test
    func nonMidnightExact() {
        // 2026-09-03 06:00:11 UTC 的 epoch → 精确串。
        #expect(PlanRead.utcTime(1_788_415_211) == "2026-09-03 06:00:11 UTC")
    }
}

@Suite("get_plan client surface")
struct GetPlanSurfaceTests {
    @Test
    func registeredShape() {
        let e = GetPlanClient.toolEntry()
        #expect(e.name == "get_plan")
        #expect(e.toolset == "plan")
        #expect(e.schema.parameters.isEmpty)
        #expect(!e.isDestructive)  // 只读查询面
        _ = e  // 类型检查 = 编译期契约(argsType/闭包面)
    }
}
