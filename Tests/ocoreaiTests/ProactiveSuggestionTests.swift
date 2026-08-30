// Copyright 2026 uingei@163.com.
// Licensed under MIT.
/// ProactiveAdvisor / ProactiveSuggestionStore 精确值测试。
/// 自主回路切片 1 — 确定性决策 + 建议生命周期（只提案、不执行 = 永不产生 tool call）。

import Foundation
import Testing

@testable import ocoreai

// MARK: - Advisor pure-decision tests

@Suite("ProactiveAdvisor.evaluate — 确定性决策")
struct ProactiveAdvisorEvaluateTests {
    private func ev(_ t: FileChangeEvent.FileChangeEventType, _ p: String, ageSec: TimeInterval = 0)
        -> FileChangeEvent
    {
        FileChangeEvent(path: p, eventType: t, timestamp: Date().addingTimeInterval(-ageSec))
    }

    @Test("空批 → 无建议")
    func emptyBatch() {
        let r = ProactiveAdvisor.evaluate(events: [])
        #expect(r.shouldSuggest == false)
        #expect(r.fileName == nil)
    }

    @Test("仅 modified → 无建议（自己的改动不构成'到达'）")
    func modifiedOnly() {
        let r = ProactiveAdvisor.evaluate(events: [ev(.modified, "a.swift"), ev(.modified, "b.md")])
        #expect(r.shouldSuggest == false)
        #expect(r.fileName == nil)
    }

    @Test("仅 deleted → 无建议")
    func deletedOnly() {
        let r = ProactiveAdvisor.evaluate(events: [ev(.deleted, "a.swift")])
        #expect(r.shouldSuggest == false)
    }

    @Test("单 created → 建议该文件")
    func singleCreated() {
        let r = ProactiveAdvisor.evaluate(events: [ev(.created, "notes.md")])
        #expect(r.shouldSuggest == true)
        #expect(r.fileName == "notes.md")
    }

    @Test("多 created → 取时间戳最新")
    func multiCreatedPicksLatest() {
        let older = ev(.created, "old.md", ageSec: 60)
        let newer = ev(.created, "new.md", ageSec: 5)
        let r = ProactiveAdvisor.evaluate(events: [older, newer])
        #expect(r.shouldSuggest == true)
        #expect(r.fileName == "new.md")
    }

    @Test("隐藏文件(点前缀) → 无建议（系统噪声）")
    func hiddenFileIgnored() {
        let r = ProactiveAdvisor.evaluate(events: [
            ev(.created, ".DS_Store"), ev(.created, ".gitkeep"),
        ])
        #expect(r.shouldSuggest == false)
        #expect(r.fileName == nil)
    }

    @Test("created + 隐藏混合 → 仍建议非隐藏")
    func hiddenMergedIn() {
        let noise = ev(.created, ".DS_Store")
        let real = ev(.created, "report.pdf")
        let r = ProactiveAdvisor.evaluate(events: [noise, real])
        #expect(r.shouldSuggest == true)
        #expect(r.fileName == "report.pdf")
    }
}

// MARK: - Store lifecycle tests (present / dedupe / dismiss / TTL)

@Suite("ProactiveSuggestionStore — 生命周期")
struct ProactiveSuggestionStoreTests {
    @MainActor
    @Test("present 写入 current")
    func presentSetsCurrent() {
        ProactiveSuggestionStore.shared.dismiss()
        ProactiveSuggestionStore.shared.present(fileName: "a.md")
        #expect(ProactiveSuggestionStore.shared.current?.fileName == "a.md")
        #expect(ProactiveSuggestionStore.shared.current?.source == "filesystem")
    }

    @MainActor
    @Test("同名重复 present → 不新增(单槽)、刷新时间戳")
    func dedupeKeepsSingleSlot() {
        ProactiveSuggestionStore.shared.dismiss()
        ProactiveSuggestionStore.shared.present(fileName: "a.md")
        let idBefore = ProactiveSuggestionStore.shared.current?.id
        ProactiveSuggestionStore.shared.present(fileName: "a.md")
        #expect(ProactiveSuggestionStore.shared.current?.id == idBefore)
    }

    @MainActor
    @Test("新文件替换旧建议")
    func newFileReplaces() {
        ProactiveSuggestionStore.shared.dismiss()
        ProactiveSuggestionStore.shared.present(fileName: "a.md")
        ProactiveSuggestionStore.shared.present(fileName: "b.md")
        #expect(ProactiveSuggestionStore.shared.current?.fileName == "b.md")
    }

    @MainActor
    @Test("dismiss 清场")
    func dismissClears() {
        ProactiveSuggestionStore.shared.present(fileName: "a.md")
        ProactiveSuggestionStore.shared.dismiss()
        #expect(ProactiveSuggestionStore.shared.current == nil)
    }

    @MainActor
    @Test("accept 返回草稿(含文件名)且不自动执行")
    func acceptReturnsDraft() {
        ProactiveSuggestionStore.shared.dismiss()
        ProactiveSuggestionStore.shared.present(fileName: "report.pdf")
        let draft = ProactiveSuggestionStore.shared.accept()
        // 草稿为本地化模板填入文件名（非哨兵）
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
        ProactiveSuggestionStore.shared.present(fileName: "x.txt")
        let d = ProactiveSuggestionStore.shared.accept()
        #expect(!d.isEmpty)
        #expect(d != ProactiveSuggestionStore.notApplicable)
    }
}
