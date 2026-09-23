// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// desktop control axis — 「Computer = AI 的可操作环境」的 action 半(input 轴)。
///
/// 与感知轴(view_screen / observe_state / view_image / generate_video)对称:
///   感知 = 观察(读半): ScreenCaptureKit + Vision(既有);
///   action = 驱动(写半): CGEvent 键鼠注入(本文件)。
/// 本文件落地前, action 面全库为零(实证: CGEvent / CGWarpMouseCursorPosition /
/// AXUIElement / NSPasteboard 非 UI 执行面 = 0)—— computer use 只读屏、不能动,
/// 是主轴(Apple 软硬件)下最明显的架构债。
///
/// 6 原语(指针 + 键盘 + 滚轮全覆盖):
///   move_mouse  指针定位 · click  单/双/三击(左/右/中) · drag  按下→移动→释放
///   scroll      滚轮(lines, + = 下) · type_text  任意 Unicode(含 CJK)
///   key_press   虚拟键 + modifiers(cmd/shift/control/option)
///
/// 安全(三层, 均 fail-closed):
///   1. 6 个全 `isDestructive: true` → 串行执行 + 逐次审批 ask(App.swift
///      destructive matcher, 每次驱动用户裁决)
///   2. 无 Accessibility 权限 → 驱动不生效; 工具面 `trustedStatus()` 诚实回报
///      权限态与授予引导, 不假装已发出
///   3. headless 通道 → 既有 securityGate fail-closed 拒绝(无 GUI 裁决者)
///
/// 基线: codex `computer_use` 一等轴(`codex-rs/features/src/lib.rs:1468`,
/// Stage::Stable, default_enabled: true)—— ocoreai 同向: 默认可达, 每次驱动用户裁决。
///
/// 平台: Pure 段全平台(纯计算, 离线可测); Driver/Clients 段 `#if os(macOS)`
/// 门控 —— CGEvent/虚拟键码是 macOS 语义(与感知轴 ScreenCaptureKit 门控一致,
/// macOS 14+ 目标系统覆盖 macOS 15/26/27 全档)。
import Foundation

// MARK: - Pure(离线可测 — 不发 CGEvent、不查系统态, 全平台)

enum DesktopControl {
    enum MouseButton: String, Codable, CaseIterable, Sendable {
        case left, right, middle
    }

    struct ClickSpec: Equatable, Sendable {
        let x: Int
        let y: Int
        let button: MouseButton
        let count: Int
    }

    struct DragSpec: Equatable, Sendable {
        let x1: Int
        let y1: Int
        let x2: Int
        let y2: Int
        let button: MouseButton
    }

    /// 按钮名 → 枚举(未知 → throw, 诚实不捏造; 纯函数可测)。
    static func button(named name: String) throws -> MouseButton {
        guard let b = MouseButton(rawValue: name.lowercased()) else {
            throw ToolError.invalidParameter("unknown button '\(name)' — use left|right|middle")
        }
        return b
    }

    /// click 归一化: 坐标 >= 0(屏幕点), count ∈ 1...3(越界 throw, 不静默钳位)。
    static func clickSpec(x: Int, y: Int, buttonName: String, count: Int) throws -> ClickSpec {
        guard x >= 0, y >= 0 else {
            throw ToolError.invalidParameter(
                "coordinates must be >= 0 screen points (got \(x), \(y))")
        }
        guard count >= 1, count <= 3 else {
            throw ToolError.invalidParameter("count must be 1|2|3 — got \(count)")
        }
        return ClickSpec(x: x, y: y, button: try button(named: buttonName), count: count)
    }

    static func dragSpec(x1: Int, y1: Int, x2: Int, y2: Int, buttonName: String) throws -> DragSpec
    {
        for (name, v) in [("x1", x1), ("y1", y1), ("x2", x2), ("y2", y2)] where v < 0 {
            throw ToolError.invalidParameter("\(name) must be >= 0 screen points (got \(v))")
        }
        return DragSpec(x1: x1, y1: y1, x2: x2, y2: y2, button: try button(named: buttonName))
    }

    /// scroll 行钳位(±maxLines 对称; 纯)。
    static func clampScroll(lines: Int, maxLines: Int) -> Int {
        max(-maxLines, min(maxLines, lines))
    }

    /// key_press 回报文案(纯, 可精确断言)。
    static func pressResult(key: String, modifiers: [String]) -> String {
        let mods = modifiers.joined(separator: "+")
        return mods.isEmpty ? "press \(key)" : "press \(key) (\(mods))"
    }

    /// modifier 名 → 规范名(纯, 不依赖 CGEventFlags; 未知 → throw)。
    static func canonicalModifier(_ name: String) throws -> String {
        switch name.lowercased() {
        case "shift": return "shift"
        case "control", "ctrl": return "control"
        case "option", "alt", "opt": return "option"
        case "command", "cmd", "meta": return "command"
        default:
            throw ToolError.invalidParameter(
                "unknown modifier '\(name)' — use shift|control|option|command")
        }
    }

    static func canonicalModifiers(_ names: [String]) throws -> [String] {
        try names.map { try canonicalModifier($0) }
    }

    /// 键名 → kVK 码(常用键; 纯, 未知 → throw)。
    static let keyCodes: [String: Int] = [
        "return": 36, "enter": 76, "tab": 48, "space": 49, "backspace": 51,
        "delete": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "pageup": 116, "pagedown": 121, "home": 115, "end": 119,
        "f5": 96, "a": 0, "b": 11, "c": 8, "d": 2, "e": 14,
        "f": 3, "g": 5, "h": 4, "i": 34, "j": 38, "k": 40, "l": 37,
        "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15,
        "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
        "y": 16, "z": 6, "0": 29, "1": 18, "2": 19, "3": 20,
        "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "+": 69, "-": 27, "=": 24, ";": 41, "'": 39,
        "[": 33, "]": 30, "\\": 42, ",": 43, ".": 47, "/": 44, "`": 50,
    ]

    static func keyCode(named key: String) throws -> Int {
        guard let code = keyCodes[key.lowercased()] else {
            throw ToolError.invalidParameter(
                "unknown key '\(key)' — use a known key name like \"return\"/\"escape\"/\"a\"/\"f5\" (see tool description)"
            )
        }
        return code
    }
}

#if os(macOS)
import AppKit
import CoreGraphics

// MARK: - Driver(真 CGEvent — macOS-only; 测试只调 Pure, 不触系统态)

enum DesktopControlDriver {
    static let maxScrollLines = 20

    static func move(_ x: Int, _ y: Int) {
        let p = CGPoint(x: x, y: y)
        guard
            let e = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: p,
                mouseButton: .left)
        else { return }
        e.post(tap: .cghidEventTap)
    }

    static func click(_ spec: DesktopControl.ClickSpec) {
        move(spec.x, spec.y)
        for _ in 0 ..< spec.count {
            postMouse(
                at: CGPoint(x: spec.x, y: spec.y), down: true,
                button: mouseButton(spec.button))
            postMouse(
                at: CGPoint(x: spec.x, y: spec.y), down: false,
                button: mouseButton(spec.button))
        }
    }

    static func drag(_ spec: DesktopControl.DragSpec) {
        postMouse(
            at: CGPoint(x: spec.x1, y: spec.y1), down: true,
            button: mouseButton(spec.button))
        move(spec.x2, spec.y2)
        postMouse(
            at: CGPoint(x: spec.x2, y: spec.y2), down: false,
            button: mouseButton(spec.button))
    }

    static func scroll(vLines: Int) {
        guard vLines != 0 else { return }
        let step: Int32 = vLines > 0 ? 1 : -1
        for _ in 0 ..< min(abs(vLines), maxScrollLines) {
            guard
                let e = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .line,
                    wheelCount: 1,
                    wheel1: step,
                    wheel2: 0,
                    wheel3: 0)
            else { return }
            e.post(tap: .cghidEventTap)
        }
    }

    static func typeText(_ s: String) {
        // UTF-16 逐 unit 直传 — 任意 Unicode(含 CJK)无需键码表。
        // 非 ASCII 走 keyboardSetUnicodeString(C 自由函数, CJK 可靠)。
        for unit in s.utf16 {
            let vk: CGKeyCode = (unit == 32) ? 49 : 0
            guard
                let down = CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: vk,
                    keyDown: true)
            else { return }
            if unit != 32 {
                var u = unit
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            }
            down.post(tap: .cghidEventTap)
            if let up = CGEvent(
                keyboardEventSource: nil,
                virtualKey: vk,
                keyDown: false)
            {
                up.post(tap: .cghidEventTap)
            }
        }
    }

    static func press(_ keyCode: Int, modifierNames: [String]) {
        let vk = CGKeyCode(keyCode)
        var flags: CGEventFlags = []
        for m in modifierNames {
            switch m {
            case "shift": flags.insert(.maskShift)
            case "control": flags.insert(.maskControl)
            case "option": flags.insert(.maskAlternate)
            case "command": flags.insert(.maskCommand)
            default: break
            }
        }
        guard
            let down = CGEvent(
                keyboardEventSource: nil,
                virtualKey: vk,
                keyDown: true)
        else { return }
        down.flags = flags
        down.post(tap: .cghidEventTap)
        if let up = CGEvent(
            keyboardEventSource: nil,
            virtualKey: vk,
            keyDown: false)
        {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    /// 诚实权限态: 无 Accessibility 权限 → 引导授予(工具面回报), 不假装已发出。
    static func trustedStatus() -> String {
        if AXIsProcessTrusted() { return "trusted" }
        return
            "not_trusted(Grant Accessibility: System Settings > Privacy & Security > Accessibility > ocoreai, then retry)"
    }

    private static let middle: CGMouseButton = CGMouseButton(rawValue: 2)!

    private static func mouseButton(_ b: DesktopControl.MouseButton) -> CGMouseButton {
        switch b {
        case .left: return .left
        case .right: return .right
        case .middle: return middle
        }
    }

    private static func postMouse(at p: CGPoint, down: Bool, button: CGMouseButton) {
        let et: CGEventType
        if down {
            et =
                button == .right
                ? .rightMouseDown
                : button == middle ? .otherMouseDown : .leftMouseDown
        } else {
            et =
                button == .right
                ? .rightMouseUp
                : button == middle ? .otherMouseUp : .leftMouseUp
        }
        guard
            let e = CGEvent(
                mouseEventSource: nil,
                mouseType: et,
                mouseCursorPosition: p,
                mouseButton: button)
        else { return }
        e.post(tap: .cghidEventTap)
    }

    /// CGEvent post 要求主线程上下文 — 从 async 调用的唯一收口.
    static func runOnMain(_ body: @escaping @MainActor () -> Void) async {
        await MainActor.run { body() }
    }
}

// MARK: - Clients(工具面 — 6 原语, 全 destructive, 逐次审批)

enum MoveMouseClient {
    static let toolName = "move_mouse"
    struct Args: Codable, Sendable {
        let x: Int
        let y: Int
    }

    static func toolEntry() -> ToolEntry {
        ToolEntry.typed(
            name: toolName, toolset: "computer", argsType: Args.self,
            description: "Move the mouse pointer to (x, ocoreai screen points). "
                + "Absolute macOS screen coordinates, top-left origin. "
                + "Requires Accessibility permission for ocoreai; the result reports the permission state.",
            schema: ToolSchema(parameters: [
                "x": ToolParameter(
                    type: .integer, description: "Absolute screen X in points (>= 0)"),
                "y": ToolParameter(
                    type: .integer, description: "Absolute screen Y in points (>= 0)"),
            ]),
            isDestructive: true
        ) { args in
            _ = try DesktopControl.clickSpec(x: args.x, y: args.y, buttonName: "left", count: 1)
            await DesktopControlDriver.runOnMain { DesktopControlDriver.move(args.x, args.y) }
            return "pointer -> (\(args.x), \(args.y)) [\(DesktopControlDriver.trustedStatus())]"
        }
    }
}

enum ClickClient {
    static let toolName = "click"
    struct Args: Codable, Sendable {
        let x: Int
        let y: Int
        let button: String?
        let count: Int?
    }

    static func toolEntry() -> ToolEntry {
        ToolEntry.typed(
            name: toolName, toolset: "computer", argsType: Args.self,
            description: "Click at (x, y) — absolute macOS screen points, top-left origin. "
                + "button: left|right|middle (default left); count: 1|2|3 = single/double/triple (default 1).",
            schema: ToolSchema(parameters: [
                "x": ToolParameter(
                    type: .integer, description: "Absolute screen X in points (>= 0)"),
                "y": ToolParameter(
                    type: .integer, description: "Absolute screen Y in points (>= 0)"),
                "button": ToolParameter(
                    type: .string, description: "left|right|middle (default left)"),
                "count": ToolParameter(
                    type: .integer, description: "1|2|3 single/double/triple click (default 1)"),
            ]),
            isDestructive: true
        ) { args in
            let spec = try DesktopControl.clickSpec(
                x: args.x, y: args.y, buttonName: args.button ?? "left", count: args.count ?? 1)
            await DesktopControlDriver.runOnMain { DesktopControlDriver.click(spec) }
            let kind = ["single", "double", "triple"][spec.count - 1]
            return
                "\(kind)-click \(spec.button.rawValue) @ (\(spec.x), \(spec.y)) [\(DesktopControlDriver.trustedStatus())]"
        }
    }
}

enum DragClient {
    static let toolName = "drag"
    struct Args: Codable, Sendable {
        let x1: Int
        let y1: Int
        let x2: Int
        let y2: Int
        let button: String?
    }

    static func toolEntry() -> ToolEntry {
        ToolEntry.typed(
            name: toolName, toolset: "computer", argsType: Args.self,
            description:
                "Drag from (x1, y1) to (x2, y2) — absolute macOS screen points, top-left origin. "
                + "Press at start, move, release at end. button: left|right|middle (default left).",
            schema: ToolSchema(parameters: [
                "x1": ToolParameter(type: .integer, description: "Start X in points (>= 0)"),
                "y1": ToolParameter(type: .integer, description: "Start Y in points (>= 0)"),
                "x2": ToolParameter(type: .integer, description: "End X in points (>= 0)"),
                "y2": ToolParameter(type: .integer, description: "End Y in points (>= 0)"),
                "button": ToolParameter(
                    type: .string, description: "left|right|middle (default left)"),
            ]),
            isDestructive: true
        ) { args in
            let spec = try DesktopControl.dragSpec(
                x1: args.x1, y1: args.y1, x2: args.x2, y2: args.y2,
                buttonName: args.button ?? "left")
            await DesktopControlDriver.runOnMain { DesktopControlDriver.drag(spec) }
            return
                "drag \(spec.button.rawValue): (\(spec.x1), \(spec.y1)) -> (\(spec.x2), \(spec.y2)) [\(DesktopControlDriver.trustedStatus())]"
        }
    }
}

enum ScrollClient {
    static let toolName = "scroll"
    struct Args: Codable, Sendable {
        /// lines; 正 = 下, 负 = 上。
        let lines: Int
    }

    static func toolEntry() -> ToolEntry {
        ToolEntry.typed(
            name: toolName, toolset: "computer", argsType: Args.self,
            description: "Scroll the wheel by `lines` lines (positive = down, negative = up). "
                + "Clamped to ±\(DesktopControlDriver.maxScrollLines) per call. Acts at the current pointer location.",
            schema: ToolSchema(parameters: [
                "lines": ToolParameter(
                    type: .integer,
                    description:
                        "Lines: positive down, negative up (clamped ±\(DesktopControlDriver.maxScrollLines))"
                )
            ]),
            isDestructive: true
        ) { args in
            let clamped = DesktopControl.clampScroll(
                lines: args.lines, maxLines: DesktopControlDriver.maxScrollLines)
            await DesktopControlDriver.runOnMain { DesktopControlDriver.scroll(vLines: clamped) }
            return "scroll \(clamped) lines [\(DesktopControlDriver.trustedStatus())]"
        }
    }
}

enum TypeTextClient {
    static let toolName = "type_text"
    struct Args: Codable, Sendable {
        /// 原文(任意 Unicode; CJK 直传无需键码)。
        let text: String
    }

    static func toolEntry() -> ToolEntry {
        ToolEntry.typed(
            name: toolName, toolset: "computer", argsType: Args.self,
            description:
                "Type `text` verbatim (any Unicode / CJK) into the currently focused control. "
                + "Ensure the target has focus first (click / key_press).",
            schema: ToolSchema(parameters: [
                "text": ToolParameter(
                    type: .string, description: "Text to type verbatim (CJK / Unicode supported)")
            ]),
            isDestructive: true
        ) { args in
            guard !args.text.isEmpty else {
                throw ToolError.invalidParameter("text is empty — nothing to type")
            }
            await DesktopControlDriver.runOnMain { DesktopControlDriver.typeText(args.text) }
            return "typed \(args.text.count) char(s) [\(DesktopControlDriver.trustedStatus())]"
        }
    }
}

enum KeyPressClient {
    static let toolName = "key_press"
    struct Args: Codable, Sendable {
        /// 键名(见 DesktopControl.keyCodes 面) — "return" / "escape" / "a" / "f5" 等。
        let key: String
        /// 修饰键名数组 — shift / control / option / command(别名可, 内部归一)。
        let modifiers: [String]?
    }

    static func toolEntry() -> ToolEntry {
        let keys = DesktopControl.keyCodes.keys.sorted().joined(separator: ", ")
        return ToolEntry.typed(
            name: toolName, toolset: "computer", argsType: Args.self,
            description:
                "Press `key` (one of: \(keys)) with optional `modifiers` (array: shift, control, option, command). "
                + "Example: [\"command\", \"a\"] = Cmd+A select-all.",
            schema: ToolSchema(parameters: [
                "key": ToolParameter(type: .string, description: "Key name: \(keys)"),
                "modifiers": ToolParameter(
                    type: .array,
                    description: "Optional modifiers: shift|control|option|command",
                    items: ToolParameter(type: .string, description: "shift|control|option|command")
                ),
            ]),
            isDestructive: true
        ) { args in
            let code = try DesktopControl.keyCode(named: args.key)
            let mods = try DesktopControl.canonicalModifiers(args.modifiers ?? [])
            await DesktopControlDriver.runOnMain {
                DesktopControlDriver.press(code, modifierNames: mods)
            }
            return DesktopControl.pressResult(key: args.key.lowercased(), modifiers: mods)
                + " [\(DesktopControlDriver.trustedStatus())]"
        }
    }
}

#endif
