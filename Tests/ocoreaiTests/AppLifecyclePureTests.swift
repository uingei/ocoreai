// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// App lifecycle Pure 段(全平台离线可测, 不触 NSWorkspace 运行时状态):
// 寻址语义 / list 格式化 / 钳制 / 过滤 — 精确值断言, 禁 count>0 弱断言。
import Testing

@testable import ocoreai

struct AppLifecyclePureTests {

    @Test("normalize: 空白归一, 小写语义留给匹配侧")
    func normalizeTrims() {
        #expect(AppLifecycle.normalize("  TextEdit ") == "TextEdit")
        #expect(AppLifecycle.normalize("com.apple.Safari") == "com.apple.Safari")
        #expect(AppLifecycle.normalize("") == "")
    }

    @Test("addressKind: 含 '.' = bundle id 精确寻址; 纯名 = 名称解析")
    func addressKindSemantics() {
        #expect(AppLifecycle.addressKind("com.apple.TextEdit") == .bundleID)
        #expect(AppLifecycle.addressKind("Bundle.Id.Example") == .bundleID)
        #expect(AppLifecycle.addressKind("TextEdit") == .appName)
        #expect(AppLifecycle.addressKind("Safari") == .appName)
    }

    @Test("clampList: 越界钳到合法上下界")
    func clampListBounds() {
        #expect(AppLifecycle.clampList(limit: 0) == 1)
        #expect(AppLifecycle.clampList(limit: -7) == 1)
        #expect(AppLifecycle.clampList(limit: 100) == 100)
        #expect(AppLifecycle.clampList(limit: 100000) == 500)
    }

    @Test("line: 列分隔格式精确(名 / bundle id / 前后态)")
    func lineFormatExact() {
        #expect(
            AppLifecycle.line(name: "TextEdit", bundle: "com.apple.TextEdit", active: true)
                == "TextEdit\tcom.apple.TextEdit\tactive")
        #expect(
            AppLifecycle.line(name: "Hermes", bundle: "(none)", active: false)
                == "Hermes\t(none)\tbackground")
    }

    @Test("display: 压空白 + 超长截断尾标(默认 64)")
    func displaySafe() {
        #expect(AppLifecycle.display("a\tb\nc") == "a b c")
        let long = String(repeating: "x", count: 80)
        let out = AppLifecycle.display(long)
        #expect(out.count == 65, "64 chars + ellipsis marker")
        #expect(out.hasSuffix("…"))
        #expect(out.hasPrefix(String(repeating: "x", count: 64)))
    }

    @Test("header: 元信息头行(无过滤/有过滤两态)")
    func headerText() {
        #expect(AppLifecycle.header(n: 5, limit: 100, filter: nil) == "# apps 5/100")
        #expect(
            AppLifecycle.header(n: 2, limit: 100, filter: "edit") == "# apps 2 (filter: edit)/100")
    }

    @Test("matches: 名或 bundle id 任一命中, 小写包含; 空过滤 = 全命中")
    func matchesSemantics() {
        #expect(AppLifecycle.matches("TextEdit", "com.apple.TextEdit", nil))
        #expect(AppLifecycle.matches("TextEdit", "com.apple.TextEdit", ""))
        #expect(AppLifecycle.matches("TextEdit", "com.apple.TextEdit", "edit"))
        #expect(AppLifecycle.matches("TextEdit", "com.apple.TextEdit", "Apple.Text"))
        #expect(!AppLifecycle.matches("TextEdit", "com.apple.TextEdit", "Notes"))
    }
}
