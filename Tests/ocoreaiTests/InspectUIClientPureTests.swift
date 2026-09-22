// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
import Testing

@testable import ocoreai

// inspect_ui 的 Pure 段(全平台离线可测, 不触 AX): 精确值/参数化, 禁 count>0 弱断言。
// 覆盖: role 归一 / 展示文本安全化 / depth·nodes 钳制 / 行格式化。
// swift-testing 规范: struct 裸名, @Test 挂在方法上(不是 struct 属性)。
struct InspectUIClientPureTests {

    // MARK: - role 归一(过滤比较与展示一致)

    @Test("normalizeRole: 大小写/空白归一, 空串保留")
    func normalizeRole() {
        #expect(UIInspect.normalizeRole("Button") == "button")
        #expect(UIInspect.normalizeRole("  TEXTFIELD ") == "textfield")
        #expect(UIInspect.normalizeRole("AXButton") == "axbutton")
        #expect(UIInspect.normalizeRole("") == "")
    }

    // MARK: - 展示文本安全化(截断/压空白, 不灌全文)

    @Test("displayText: 短文本原样")
    func displayTextShort() {
        #expect(UIInspect.displayText("Send", max: 80) == "Send")
        #expect(UIInspect.displayText("", max: 80) == "")
    }

    @Test("displayText: 换行/制表符压平, 超长截断 + 尾标")
    func displayTextFlattenTruncate() {
        #expect(UIInspect.displayText("a\tb", max: 80) == "a b")
        #expect(UIInspect.displayText("line1\nline2", max: 80).contains("\u{23CE}"))
        let long = String(repeating: "x", count: 200)
        let out = UIInspect.displayText(long, max: 20)
        #expect(out.count == 21, "20 chars + ellipsis marker")
        #expect(out.hasSuffix("…"))
        #expect(out.hasPrefix(String(repeating: "x", count: 20)))
    }

    // MARK: - depth / max_nodes 钳制(fail-closed)

    @Test("clamp: 越界钳到合法上下界")
    func clampBounds() {
        #expect(UIInspect.clamp(depth: 0, nodes: 0) == (1, 1))
        #expect(UIInspect.clamp(depth: -5, nodes: -1) == (1, 1))
        #expect(UIInspect.clamp(depth: 999, nodes: 999999) == (32, 4000))
        #expect(UIInspect.clamp(depth: 6, nodes: 800) == (6, 800))
    }

    // MARK: - 行格式化(模型可读 + 层级缩进, 精确值)

    @Test("line: 根层(depth=1) role + label")
    func lineRoot() {
        #expect(
            UIInspect.line(depth: 1, role: "application", label: "Safari", value: "")
                == "  - application \"Safari\"")
    }

    @Test("line: 带 value + 层级缩进(depth 5 = 10 空格, count:depth ×2)")
    func lineNestedValue() {
        let r = UIInspect.line(depth: 5, role: "textfield", label: "Search", value: "hello")
        #expect(
            r == String(repeating: "  ", count: 5) + "- textfield \"Search\" value:\"hello\"")
    }

    @Test("line: 无 label / 无 value 的两块空态")
    func lineBare() {
        #expect(UIInspect.line(depth: 2, role: "group", label: "", value: "") == "    - group")
    }
}
