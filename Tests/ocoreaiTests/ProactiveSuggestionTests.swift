// Copyright 2026 uingei@163.com.
// Licensed under MIT.
/// ProactiveAdvisor / ProactiveSuggestionStore 精确值测试。
/// 自主回路 — 确定性决策 + 建议生命周期 + **观察可寻址**（切片 3：绝对路径）。
/// 契约：只提案、不执行（永不产生 tool call）；"查看"产可执行草稿（含完整路径）。

import Foundation
import Testing

@testable import ocoreai

// MARK: - Advisor pure-decision tests

@Suite("ProactiveAdvisor.evaluate — 确定性决策")
struct ProactiveAdvisorEvaluateTests {
    /// 构造事件。`p` = **绝对路径**（真值，可寻址）。
    private func ev(_ t: FileChangeEvent.FileChangeEventType, _ p: String, ageSec: TimeInterval = 0)
        -> FileChangeEvent
    {
        FileChangeEvent(path: p, eventType: t, timestamp: Date().addingTimeInterval(-ageSec))
    }

    @Test("空批 → 无建议")
    func emptyBatch() {
        let r = ProactiveAdvisor.evaluate(events: [])
        #expect(r.shouldSuggest == false)
        #expect(r.filePath == nil)
    }

    @Test("仅 modified → 无建议（自己的改动不构成'到达'）")
    func modifiedOnly() {
        let r = ProactiveAdvisor.evaluate(events: [
            ev(.modified, "/tmp/proj/a.swift"), ev(.modified, "/tmp/proj/b.md"),
        ])
        #expect(r.shouldSuggest == false)
        #expect(r.filePath == nil)
    }

    @Test("仅 deleted → 无建议")
    func deletedOnly() {
        let r = ProactiveAdvisor.evaluate(events: [ev(.deleted, "/tmp/proj/a.swift")])
        #expect(r.shouldSuggest == false)
        #expect(r.filePath == nil)
    }

    @Test("单 created → 建议该文件（返回**绝对路径**）")
    func singleCreated() {
        let r = ProactiveAdvisor.evaluate(events: [ev(.created, "/Users/t/Downloads/notes.md")])
        #expect(r.shouldSuggest == true)
        #expect(r.filePath == "/Users/t/Downloads/notes.md")
    }

    @Test("多 created → 取时间戳最新")
    func multiCreatedPicksLatest() {
        let older = ev(.created, "/tmp/proj/old.md", ageSec: 60)
        let newer = ev(.created, "/tmp/proj/new.md", ageSec: 5)
        let r = ProactiveAdvisor.evaluate(events: [older, newer])
        #expect(r.shouldSuggest == true)
        #expect(r.filePath == "/tmp/proj/new.md")
    }

    @Test("隐藏文件(点前缀) → 无建议（系统噪声）")
    func hiddenFileIgnored() {
        let r = ProactiveAdvisor.evaluate(events: [
            ev(.created, "/tmp/proj/.DS_Store"), ev(.created, "/tmp/proj/.gitkeep"),
        ])
        #expect(r.shouldSuggest == false)
        #expect(r.filePath == nil)
    }

    @Test("created + 隐藏混合 → 仍建议非隐藏")
    func hiddenMergedIn() {
        let noise = ev(.created, "/tmp/proj/.DS_Store")
        let real = ev(.created, "/tmp/proj/report.pdf")
        let r = ProactiveAdvisor.evaluate(events: [noise, real])
        #expect(r.shouldSuggest == true)
        #expect(r.filePath == "/tmp/proj/report.pdf")
    }
}

// MARK: - Slice 3：观察可寻址（绝对路径 = 可执行目标）

@Suite("ProactiveSuggestion — 可寻址目标")
struct ProactiveSuggestionAddressableTests {
    @Test("filePath 为完整绝对路径 → 可直接 feed 给 read_file")
    func filePathIsAbsolute() {
        let s = ProactiveSuggestion(
            source: "filesystem",
            filePath: "/Users/t/Projects/ocoreai/report.pdf",
            detailKey: ProactiveAdvisor.detailKeyForNewFile
        )
        #expect(s.filePath.hasPrefix("/"))
        #expect(s.filePath == "/Users/t/Projects/ocoreai/report.pdf")
        // 短名派生 = 末段，展示友好
        #expect(s.fileName == "report.pdf")
    }

    @Test("draft 含完整绝对路径（LLM 拿到可寻址目标，不需猜目录）")
    func draftContainsFullPath() {
        let s = ProactiveSuggestion(
            source: "filesystem",
            filePath: "/Users/t/Downloads/data.csv",
            detailKey: ProactiveAdvisor.detailKeyForNewFile
        )
        let draft = ProactiveSuggestionStore.draftText(for: s)
        #expect(draft.contains("/Users/t/Downloads/data.csv"), "草稿必须含完整绝对路径: \(draft)")
        #expect(draft.contains("data.csv"), "草稿须含短名展示: \(draft)")
    }
}

// MARK: - Store lifecycle tests (present / dedupe / dismiss / accept)

@Suite("ProactiveSuggestionStore — 生命周期")
struct ProactiveSuggestionStoreTests {
    @MainActor
    @Test("present 写入 current（携带绝对路径）")
    func presentSetsCurrent() {
        ProactiveSuggestionStore.shared.dismiss()
        ProactiveSuggestionStore.shared.present(filePath: "/tmp/proj/a.md")
        let cur = ProactiveSuggestionStore.shared.current
        #expect(cur?.filePath == "/tmp/proj/a.md")
        #expect(cur?.fileName == "a.md")
        #expect(cur?.source == "filesystem")
    }

    @MainActor
    @Test("同路径重复 present → 不新增(单槽)、刷新时间戳")
    func dedupeKeepsSingleSlot() {
        ProactiveSuggestionStore.shared.dismiss()
        ProactiveSuggestionStore.shared.present(filePath: "/tmp/proj/a.md")
        let idBefore = ProactiveSuggestionStore.shared.current?.id
        ProactiveSuggestionStore.shared.present(filePath: "/tmp/proj/a.md")
        #expect(ProactiveSuggestionStore.shared.current?.id == idBefore)
    }

    @MainActor
    @Test("新文件替换旧建议")
    func newFileReplaces() {
        ProactiveSuggestionStore.shared.dismiss()
        ProactiveSuggestionStore.shared.present(filePath: "/tmp/proj/a.md")
        ProactiveSuggestionStore.shared.present(filePath: "/tmp/proj/b.md")
        #expect(ProactiveSuggestionStore.shared.current?.fileName == "b.md")
        #expect(ProactiveSuggestionStore.shared.current?.filePath == "/tmp/proj/b.md")
    }

    @MainActor
    @Test("dismiss 清场")
    func dismissClears() {
        ProactiveSuggestionStore.shared.present(filePath: "/tmp/proj/a.md")
        ProactiveSuggestionStore.shared.dismiss()
        #expect(ProactiveSuggestionStore.shared.current == nil)
    }

    @MainActor
    @Test("accept 返回可执行草稿(含完整路径)且不自动执行")
    func acceptReturnsExecutableDraft() {
        ProactiveSuggestionStore.shared.dismiss()
        ProactiveSuggestionStore.shared.present(filePath: "/Users/t/Downloads/report.pdf")
        let draft = ProactiveSuggestionStore.shared.accept()
        // 草稿为可执行指令：含完整绝对路径（可寻址目标）+ 短名展示
        #expect(draft.contains("/Users/t/Downloads/report.pdf"), "草稿须含完整路径: \(draft)")
        #expect(draft.contains("report.pdf"))
        #expect(draft != ProactiveSuggestionStore.notApplicable)
    }

    @MainActor
    @Test("无建议 accept → notApplicable 哨兵")
    func acceptNone() {
        ProactiveSuggestionStore.shared.dismiss()
        #expect(ProactiveSuggestionStore.shared.accept() == ProactiveSuggestionStore.notApplicable)
    }

    @MainActor
    @Test("草稿非空 = 非哨兵")
    func draftIsReal() {
        ProactiveSuggestionStore.shared.dismiss()
        ProactiveSuggestionStore.shared.present(filePath: "/tmp/proj/x.txt")
        let d = ProactiveSuggestionStore.shared.accept()
        #expect(!d.isEmpty)
        #expect(d != ProactiveSuggestionStore.notApplicable)
    }
}
