// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// Clipboard Pure 段(双平台离线可测, 不触 NSPasteboard/UIPasteboard 运行时):
// 空态 / max_chars 钳制 / 读报告(截断+诚实尾注) / 写报告 — 精确值断言, 禁 count>0 弱断言。
import Testing

@testable import ocoreai

struct ClipboardPureTests {

    @Test("isBlank: nil / 空串为空白; 纯空白不算内容(保留原样), 有字符即非空白")
    func isBlankSemantics() {
        #expect(Clipboard.isBlank(nil))
        #expect(Clipboard.isBlank(""))
        #expect(!Clipboard.isBlank("a"))
        #expect(!Clipboard.isBlank(" "))
    }

    @Test("clampMax: nil/<=0 → 默认 2000; 低于下限 → 100; 高于上限 → 20000; 区间内原样")
    func clampMaxBounds() {
        #expect(Clipboard.clampMax(nil) == 2000)
        #expect(Clipboard.clampMax(0) == 2000)
        #expect(Clipboard.clampMax(-3) == 2000)
        #expect(Clipboard.clampMax(1) == 100)
        #expect(Clipboard.clampMax(50) == 100)
        #expect(Clipboard.clampMax(500) == 500)
        #expect(Clipboard.clampMax(999_999) == 20_000)
    }

    @Test("readReport: 空态给明确空标记(不捏造内容)")
    func readReportEmpty() {
        #expect(Clipboard.readReport(nil, maxLen: 2000) == "clipboard: (empty)")
        #expect(Clipboard.readReport("", maxLen: 2000) == "clipboard: (empty)")
    }

    @Test("readReport: 未超 maxLen → 全量 + 计数头")
    func readReportWhole() {
        let r = Clipboard.readReport("hello", maxLen: 2000)
        #expect(r.hasPrefix("clipboard(5 chars):"))
        #expect(r.contains("hello"))
        #expect(!r.contains("truncated"))
    }

    @Test("readReport: 超 maxLen → 截断 + 诚实尾注(总长 + 余量不显示)")
    func readReportTruncated() {
        let text = String(repeating: "x", count: 100)
        let r = Clipboard.readReport(text, maxLen: 20)
        #expect(r.hasPrefix("clipboard(100 chars, truncated to 20):"), "got: \(r.prefix(60))")
        // 恰好 20 个 x 的正文 + 诚实尾注
        #expect(r.contains(String(repeating: "x", count: 20)))
        #expect(r.contains("…(80 more chars not shown)"))
        // 截断后正文只出 20 个 x(不是 100) — 精确, 非包含
        let body = r.split(separator: "\n").dropFirst().first ?? ""
        let xcount = body.filter { $0 == "x" }.count
        #expect(xcount == 20, "body x-count \(xcount)")
    }
}
