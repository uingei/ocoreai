import Foundation
// DesktopControlPureTests.swift — computer-use action 轴 Pure 层(归一化/校验)精确值验证
//
// 纪律: 精确值断言(#expect == N / throws), 禁 count>0 弱断言。
// Pure 层 = DesktopControl enum(无平台门控, macOS/iOS 同构) —— 不发 CGEvent、
// 不查系统态, 离线可测。Driver(CGEvent)与 Clients 面由 ToolSpecFullRegistryTests
// 覆盖(macOS lane, wire/schema 真实构建)。
import Testing

@testable import ocoreai

// Throwing-closure convention (mirror StreamingWindowTests.swift:174):
//   #expect(throws: ToolError.self) { try ... }  — closure body `try`s the call;
//   the function itself must be `throws` so non-throws branches can `#expect(try ...)`.
struct DesktopControlPureTests {

    // MARK: - button 归一化

    @Test("button 名 → 枚举: 三按钮全通")
    func buttonAllThree() throws {
        #expect(try DesktopControl.button(named: "left") == .left)
        #expect(try DesktopControl.button(named: "right") == .right)
        #expect(try DesktopControl.button(named: "middle") == .middle)
    }

    @Test("button 大小写归一: LEFT / MiDdle 同义")
    func buttonCaseInsensitive() throws {
        #expect(try DesktopControl.button(named: "LEFT") == .left)
        #expect(try DesktopControl.button(named: "MiDdle") == .middle)
    }

    @Test("button 未知 → throw(诚实不捏造)")
    func buttonUnknownThrows() {
        #expect(throws: ToolError.self) {
            _ = try DesktopControl.button(named: "index")
        }
    }

    // MARK: - click spec 校验

    @Test("clickSpec 合法: 边界内取值精确")
    func clickSpecValid() throws {
        let s = try DesktopControl.clickSpec(x: 0, y: 0, buttonName: "right", count: 3)
        #expect(s.x == 0)
        #expect(s.y == 0)
        #expect(s.button == .right)
        #expect(s.count == 3)
    }

    @Test("clickSpec 负坐标 → throw(屏幕点非负)")
    func clickSpecNegativeThrows() {
        #expect(throws: ToolError.self) {
            _ = try DesktopControl.clickSpec(x: -1, y: 0, buttonName: "left", count: 1)
        }
        #expect(throws: ToolError.self) {
            _ = try DesktopControl.clickSpec(x: 0, y: -1, buttonName: "left", count: 1)
        }
    }

    @Test("clickSpec count 域 1...3: 0 与 4 → throw(不静默钳位)")
    func clickSpecCountDomain() throws {
        #expect(throws: ToolError.self) {
            _ = try DesktopControl.clickSpec(x: 10, y: 10, buttonName: "left", count: 0)
        }
        #expect(throws: ToolError.self) {
            _ = try DesktopControl.clickSpec(x: 10, y: 10, buttonName: "left", count: 4)
        }
        #expect(try DesktopControl.clickSpec(x: 10, y: 10, buttonName: "left", count: 1).count == 1)
        #expect(try DesktopControl.clickSpec(x: 10, y: 10, buttonName: "left", count: 2).count == 2)
    }

    @Test("clickSpec 未知按钮 → throw")
    func clickSpecButtonUnknown() {
        #expect(throws: ToolError.self) {
            _ = try DesktopControl.clickSpec(x: 10, y: 10, buttonName: "wheel", count: 1)
        }
    }

    // MARK: - drag spec 校验

    @Test("dragSpec 合法: 四边形坐标 + 按钮")
    func dragSpecValid() throws {
        let d = try DesktopControl.dragSpec(x1: 0, y1: 0, x2: 400, y2: 300, buttonName: "middle")
        #expect(d.x1 == 0)
        #expect(d.y1 == 0)
        #expect(d.x2 == 400)
        #expect(d.y2 == 300)
        #expect(d.button == .middle)
    }

    @Test("dragSpec 任一坐标负 → throw")
    func dragSpecNegativeAnywhereThrows() {
        for bad in [
            (
                "x1",
                { _ = try DesktopControl.dragSpec(x1: -1, y1: 0, x2: 1, y2: 1, buttonName: "left") }
            ),
            (
                "y1",
                { _ = try DesktopControl.dragSpec(x1: 0, y1: -1, x2: 1, y2: 1, buttonName: "left") }
            ),
            (
                "x2",
                { _ = try DesktopControl.dragSpec(x1: 0, y1: 0, x2: -1, y2: 1, buttonName: "left") }
            ),
            (
                "y2",
                { _ = try DesktopControl.dragSpec(x1: 0, y1: 0, x2: 1, y2: -1, buttonName: "left") }
            ),
        ] {
            #expect(throws: ToolError.self, "expected \(bad.0) < 0 to throw") { _ = try bad.1() }
        }
    }

    // MARK: - scroll 钳位

    @Test("clampScroll: ±max 对称钳位(纯, 精确)")
    func clampScrollSymmetric() {
        #expect(DesktopControl.clampScroll(lines: 10, maxLines: 20) == 10)
        #expect(DesktopControl.clampScroll(lines: -10, maxLines: 20) == -10)
        #expect(DesktopControl.clampScroll(lines: 999, maxLines: 20) == 20)
        #expect(DesktopControl.clampScroll(lines: -999, maxLines: 20) == -20)
        #expect(DesktopControl.clampScroll(lines: 0, maxLines: 20) == 0)
    }

    // MARK: - modifier 归一化

    @Test("modifier 别名 → 规范名(Cmd 系)")
    func modifierAliasCmd() throws {
        #expect(try DesktopControl.canonicalModifier("command") == "command")
        #expect(try DesktopControl.canonicalModifier("cmd") == "command")
        #expect(try DesktopControl.canonicalModifier("meta") == "command")
        #expect(try DesktopControl.canonicalModifier("CMD") == "command")
    }

    @Test("modifier 别名 → 规范名(Option 系)")
    func modifierAliasOpt() throws {
        #expect(try DesktopControl.canonicalModifier("option") == "option")
        #expect(try DesktopControl.canonicalModifier("alt") == "option")
        #expect(try DesktopControl.canonicalModifier("opt") == "option")
    }

    @Test("modifier 别名 → 规范名(Shift / Control)")
    func modifierShiftControl() throws {
        #expect(try DesktopControl.canonicalModifier("shift") == "shift")
        #expect(try DesktopControl.canonicalModifier("control") == "control")
        #expect(try DesktopControl.canonicalModifier("ctrl") == "control")
    }

    @Test("modifier 未知 → throw(诚实不捏造)")
    func modifierUnknownThrows() {
        #expect(throws: ToolError.self) { _ = try DesktopControl.canonicalModifier("hyper") }
        #expect(throws: ToolError.self) { _ = try DesktopControl.canonicalModifier("hyper") }
    }

    @Test("modifier 数组批量归一: [cmd, alt] → [command, option]")
    func modifiersArray() throws {
        #expect(try DesktopControl.canonicalModifiers(["cmd", "alt"]) == ["command", "option"])
        #expect(try DesktopControl.canonicalModifiers(["SHiFT"]) == ["shift"])
        #expect((try DesktopControl.canonicalModifiers([])).isEmpty)
    }

    // MARK: - key 名 → 键码

    @Test("keyCode: 常用键码精确值(与 keyCodes 真值表对齐)")
    func keyCodeNamed() throws {
        #expect(try DesktopControl.keyCode(named: "return") == 36)
        #expect(try DesktopControl.keyCode(named: "enter") == 76)
        #expect(try DesktopControl.keyCode(named: "tab") == 48)
        #expect(try DesktopControl.keyCode(named: "escape") == 53)
        #expect(try DesktopControl.keyCode(named: "esc") == 53)
        #expect(try DesktopControl.keyCode(named: "left") == 123)
        #expect(try DesktopControl.keyCode(named: "up") == 126)
        #expect(try DesktopControl.keyCode(named: "a") == 0)
        #expect(try DesktopControl.keyCode(named: "space") == 49)
        #expect(try DesktopControl.keyCode(named: "F5") == 96)  // 大小写归一
    }

    @Test("keyCode: 未知键 → throw(引导面)")
    func keyCodeUnknownThrows() {
        #expect(throws: ToolError.self) {
            _ = try DesktopControl.keyCode(named: "f99")
        }
    }

    // MARK: - press 回报文案

    @Test("pressResult: 无修饰 / 有修饰精确文案")
    func pressResultText() {
        #expect(DesktopControl.pressResult(key: "return", modifiers: []) == "press return")
        #expect(
            DesktopControl.pressResult(key: "a", modifiers: ["command", "shift"])
                == "press a (command+shift)")
    }
}
