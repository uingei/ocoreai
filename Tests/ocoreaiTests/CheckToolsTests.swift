// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `check_tools` 工具 — 精确值测试(全离线: 条目注入, 不触 AuditTrail actor, 不触 SQLite, 不依赖 wall clock).
///
/// 覆盖:
///   AuditVerify.filterAndSort  — 窗口边界(±2s 精确) / tool 过滤 / status 过滤 / 时间倒序 / id 倒序 tiebreak / limit 截断
///   AuditVerify.clip           — ≤160 原样 / 161 截到 160(边界精确)
///   AuditVerify.render         — 空窗口诚实缺席 / 窗口内四态计数精确 / limit 精确 / 明细行字段精确 / 过滤参数贯穿
///   CheckToolsClient.reduce    — id 去重 in-memory 优先 / distinct 双留
import Foundation
import Testing

@testable import ocoreai

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func mk(
    _ id: String, _ now: Date, _ tool: String,
    _ status: AuditEntry.AuditStatus, _ result: String = "ok",
) -> AuditEntry {
    AuditEntry(
        id: id, timestamp: now, caller: "agent",
        toolName: tool, toolset: "t",
        arguments: [:], status: status,
        resultSummary: result, durationMs: 1.0, traceID: "tr-\(id)",
    )
}

@Suite("check_tools filter/sort")
struct CheckToolsFilterTests {

    @Test
    func windowBoundaryExact() {
        // now-299s 在 300s 窗口内; now-301s 窗口外(精确, 无 ±1 余量)。
        let in_ = mk("i", t0.addingTimeInterval(-299), "exec", .success)
        let out = mk("o", t0.addingTimeInterval(-301), "exec", .success)
        let got = AuditVerify.filterAndSort(
            entries: [out, in_], tool: nil, status: nil,
            windowSeconds: 300, limit: 20, now: t0)
        #expect(got.map(\.id) == ["i"])
    }

    @Test
    func toolFilterExact() {
        let keep = mk("k", t0, "exec", .success)
        let drop = mk("d", t0, "view_screen", .success)
        let got = AuditVerify.filterAndSort(
            entries: [drop, keep], tool: "exec", status: nil,
            windowSeconds: 300, limit: 20, now: t0)
        #expect(got.map(\.id) == ["k"])
    }

    @Test
    func statusFilterExact() {
        let keep = mk("k", t0, "exec", .error)
        let drop = mk("d", t0, "exec", .success)
        let got = AuditVerify.filterAndSort(
            entries: [drop, keep], tool: nil, status: "error",
            windowSeconds: 300, limit: 20, now: t0)
        #expect(got.map(\.id) == ["k"])
    }

    @Test
    func newestFirstWithIdTiebreak() {
        let a = mk("a", t0.addingTimeInterval(-10), "exec", .success)
        let b = mk("b", t0.addingTimeInterval(-5), "exec", .success)
        let c = mk("c", t0.addingTimeInterval(-5), "exec", .success)  // 同 ts 不同 id
        let got = AuditVerify.filterAndSort(
            entries: [a, b, c], tool: nil, status: nil,
            windowSeconds: 300, limit: 10, now: t0)
        #expect(got.map(\.id) == ["c", "b", "a"])  // 最新先; 同 ts → id 倒序
    }

    @Test
    func limitTruncates() {
        // 时间戳各异 → 排序由 ts 决定(不依赖 id tiebreak): 最新 3 条 = n10/n9/n8。
        let es = (1 ... 10).map {
            mk("e\($0)", t0.addingTimeInterval(-Double(10 - $0)), "exec", .success)
        }
        let got = AuditVerify.filterAndSort(
            entries: es, tool: nil, status: nil,
            windowSeconds: 300, limit: 3, now: t0)
        #expect(got.count == 3)
        #expect(got[0].id == "e10" && got[2].id == "e8")
    }
}

@Suite("check_tools clipping")
struct CheckToolsClipTests {
    @Test
    func atBoundaryKeepsFull() {
        let s = String(repeating: "a", count: 160)
        #expect(AuditVerify.clip(s) == s)
    }
    @Test
    func overBoundaryTruncated() {
        let s = String(repeating: "a", count: 161)
        #expect(AuditVerify.clip(s).count == 160)
    }
}

@Suite("check_tools render")
struct CheckToolsRenderTests {

    @Test
    func emptyWindowHonestlyAbsent() {
        let old = mk("x", t0.addingTimeInterval(-999), "exec", .success)
        let out = AuditVerify.render(
            entries: [old], windowSeconds: 300, limit: 20, now: t0)
        #expect(out.contains("no tool executions"))
        #expect(out.contains("last 300s"))
        #expect(out.contains("nothing to verify yet"))
    }

    @Test
    func toolFilterCarriesThroughRender() {
        // 过滤参数贯穿: 2 exec + 1 view_screen, tool=exec → 只 1 条 exec, 头计数=1。
        let a = mk("a", t0, "exec", .success)
        let b = mk("b", t0, "view_screen", .success)
        let out = AuditVerify.render(
            entries: [a, b], tool: "exec", windowSeconds: 300, limit: 20, now: t0)
        #expect(out.contains("1 execution(s)"))
        #expect(out.contains("- exec: success"))
        #expect(out.contains("view_screen") == false)
    }

    @Test
    func statusFilterMismatchHonestlyAbsent() {
        // 过滤无命中 → 诚实缺报(不伪造在场), 且提示 filter 可能是零命中。
        let a = mk("a", t0, "exec", .error)
        let out = AuditVerify.render(
            entries: [a], status: "timeout", windowSeconds: 300, limit: 20, now: t0)
        #expect(out.contains("no tool executions"))
        #expect(out.contains("filter matched nothing"))
    }

    @Test
    func fourStateCountsExact() {
        let es = [
            mk("s", t0, "a", .success),
            mk("e", t0, "b", .error, "boom"),
            mk("c", t0, "c", .cancelled),
            mk("t", t0, "d", .timeout),
        ]
        let out = AuditVerify.render(
            entries: es, windowSeconds: 300, limit: 20, now: t0)
        #expect(out.contains("success 1"))
        #expect(out.contains("error 1"))
        #expect(out.contains("cancelled 1"))
        #expect(out.contains("timeout 1"))
        #expect(out.contains("4 execution(s)"))
    }

    @Test
    func detailLineShowsStatusDurationAge() {
        let e = mk("x", t0.addingTimeInterval(-7), "exec", .error, "exit 1")
        let out = AuditVerify.render(
            entries: [e], windowSeconds: 300, limit: 20, now: t0)
        #expect(out.contains("- exec: error"))
        #expect(out.contains("1ms"))
        #expect(out.contains("age 7s"))
        #expect(out.contains("— exit 1"))
    }

    @Test
    func limitTruncatesRender() {
        let es = (1 ... 10).map { mk("e\($0)", t0, "exec", .success) }
        let out = AuditVerify.render(
            entries: es, windowSeconds: 300, limit: 3, now: t0)
        #expect(out.contains("3 execution(s)"))
        #expect(out.contains("e10") == false)  // id 不出现在输出(工具名才出现)
    }
}

@Suite("check_tools reduce")
struct CheckToolsReduceTests {
    @Test
    func inMemoryWinsOnDuplicateID() {
        // 同 id 两条（持久=旧快照, 内存=新写盘后内存环仍在）→ 内存面优先覆盖（merge 先例, AuditTrail.swift:377）。
        let base = mk("1", t0, "a", .success, "old")
        let mem = mk("1", t0, "a", .success, "fresh")
        let got = CheckToolsClient.reduce(persistent: [base], inMem: [mem])
        #expect(got["1"]?.resultSummary == "fresh")
    }
    @Test
    func distinctIDsBothKept() {
        let a = mk("1", t0, "a", .success)
        let b = mk("2", t0, "b", .success)
        let got = CheckToolsClient.reduce(persistent: [a], inMem: [b])
        #expect(got.count == 2)
    }
    @Test
    func persistentOnlySurvives() {
        // 内存环清空后（重启）→ 持久面仍独自在位(durable 断言, 7676ac5 面)。
        let a = mk("1", t0, "a", .success, "persisted")
        let got = CheckToolsClient.reduce(persistent: [a], inMem: [])
        #expect(got["1"]?.resultSummary == "persisted")
    }
}

@Suite("check_tools tool entry")
struct CheckToolsEntryTests {
    @Test
    func registeredShape() {
        let e = CheckToolsClient.toolEntry()
        #expect(e.name == "check_tools")
        #expect(e.toolset == "verify")
        #expect(
            e.schema.parameters.keys.allSatisfy {
                ["tool", "status", "window_seconds", "limit"].contains($0)
            })
        #expect(e.schema.parameters.count == 4)
    }
}
