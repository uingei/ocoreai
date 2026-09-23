// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// inspect_ui — 「自主操作计算机」的结构化 UI 语义层。
///
/// 第一性: "自主操作" = 感知(知道现在是什么)→ 决策(模型)→ 动作(改变)→ 感知(确认变成什么)。
/// 此前 ocoreai 的"感知"是像素层(view_screen/OCR), "动作"是盲坐标 CGEvent —— 两半都过不了
/// "这是不是一个控件? 现在 value 是什么?" 这道坎, 所以是开环盲打。
///
/// Apple 为"让程序理解并操作 UI"设计的官方接口 = Accessibility API(AX 元素树)。
/// inspect_ui 读 live AX 树的**语义面**: role / title / description / value + 父子层级,
/// 每个控件行尾附 ` at:(x,y)` —— 屏幕坐标中心的 click/type 可直接消费的命中点。
/// 一次闭合"语义理解 + 动作后验证 + 精准定位"三块, "看到按钮 → 点中按钮" 回路闭合。
///
/// 安全: 只读(零副作用), isDestructive: false, 免审批(同一范式于 observe_state)。
/// 无 Accessibility 权限 → 诚实回报(不假装读到)。macOS 门(AX 是 macOS 语义), 与
/// desktop control 6 工具同 #if os(macOS) 段。全 Safe API, 无 as!/try!。
///
/// AXValue 坐标桥接: kAXPositionAttribute/kAXSizeAttribute 返回 AXValue
/// (CF_BRIDGED_TYPE(id)), Swift 对其 as?/as 均报 error(见 AXValue.h L119),
/// 而 as! 违反项目铁律。已用 live 探针实证: @_silgen_name 直调 AXValueGetValue
/// (参数声明 AnyObject?, C 层自身校验类型) 在 macOS 正确解码真实窗口坐标;
/// 项目已有同惯用法先例 SQLiteStore.swift:30 (sqlite3_* 同法桥接)。
import Foundation

#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import CoreFoundation
#endif

// MARK: - Pure(离线可测 — 不触 AX、全平台)

enum UIInspect {
    /// role 归一(大小写/首尾空白) — 过滤比较与展示稳定统一。纯, 可测。
    static func normalizeRole(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 展示文本安全化: 压换行/空白/截断(避免把一个 textview 全文灌进模型上下文)。纯, 可测。
    static func displayText(_ s: String, max maxLen: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " \u{23CE} ")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: " ")
        guard t.count > maxLen else { return t }
        let idx = t.index(t.startIndex, offsetBy: maxLen)
        return String(t[t.startIndex ..< idx]) + "…"
    }

    /// depth/max_nodes 钳制(fail-closed 上下界, 纯)。越界 → 钳到合法, 不 throw(读树无副作用)。
    static func clamp(depth: Int, nodes: Int) -> (depth: Int, nodes: Int) {
        (min(max(depth, 1), 32), min(max(nodes, 1), 4000))
    }

    /// 单元素可模型读行: 缩进(层级) + role + label + value。纯, 精确可测。
    static func line(depth: Int, role: String, label: String, value: String) -> String {
        let indent = String(repeating: "  ", count: depth)
        var s = indent + "- " + role
        if !label.isEmpty { s += " \"\(label)\"" }
        if !value.isEmpty { s += " value:\"\(value)\"" }
        return s
    }

    /// 元素命中点 = 屏幕坐标系下的 frame 中心(动作层 click/type 直接消费)。纯, 精确可测。
    static func center(x: Double, y: Double, w: Double, h: Double) -> (x: Int, y: Int) {
        (Int((x + w / 2).rounded()), Int((y + h / 2).rounded()))
    }

    /// 行尾坐标后缀 —— "看到 → 点到" 回路里喂给 click 的 (x,y)。纯, 精确可测。
    static func coord(_ c: (x: Int, y: Int)) -> String {
        " at:(\(c.x),\(c.y))"
    }
}

// MARK: - Driver + Client(macOS 门 — AX API, 全 Safe)

#if os(macOS)

enum UIInspectDriver {
    /// 目标 app 的 pid: 空 = 前台 app; 有 = 按 bundle id / app 名匹配 runningApplications。
    static func resolvePid(_ app: String?) -> pid_t? {
        if let app, !app.isEmpty {
            let apps = NSWorkspace.shared.runningApplications
            if let a = apps.first(where: { $0.bundleIdentifier?.lowercased() == app.lowercased() })
            {
                return a.processIdentifier
            }
            if let a = apps.first(where: { $0.localizedName?.lowercased() == app.lowercased() }) {
                return a.processIdentifier
            }
            return nil
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// 同步读语义树(主线程内跑)。无权限/无目标 → 诚实文案, 不捏造。
    static func readTree(app: String?, depth: Int, nodes: Int, role: String?) -> String {
        guard AXIsProcessTrusted() else {
            return "ui_untrusted — Accessibility read denied. Grant: System Settings > "
                + "Privacy & Security > Accessibility > ocoreai, then retry."
        }
        guard let pid = resolvePid(app) else {
            return "ui_no_app — no target app (frontmost, or matching bundle id / name not found)."
        }
        let (d, n) = UIInspect.clamp(depth: depth, nodes: nodes)
        let root = AXUIElementCreateApplication(pid)
        let roleFilter = role.map(UIInspect.normalizeRole)

        var out: [String] = [
            "# ui-tree pid=\(pid) depth<=\(d) nodes<=\(n)"
                + (roleFilter != nil ? " role=\(roleFilter!)" : "")
        ]
        var emitted = 0
        var total = 0
        var queue: [(el: AXUIElement, layer: Int)] = [(root, 1)]
        while !queue.isEmpty && emitted < n {
            let (el, layer) = queue.removeFirst()
            if layer > d { break }
            total += 1
            let node = readNode(el)
            if roleFilter == nil || UIInspect.normalizeRole(node.role) == roleFilter {
                emitted += 1
                let label = UIInspect.displayText(
                    node.title.isEmpty ? node.description : node.title, max: 80)
                let v = UIInspect.displayText(node.value, max: 120)
                let row = UIInspect.line(depth: layer - 1, role: node.role, label: label, value: v)
                out.append(node.center.map { row + UIInspect.coord($0) } ?? row)
            }
            if layer < d {
                for child in children(el) { queue.append((child, layer + 1)) }
            }
        }
        out.append(
            "# emitted \(emitted)/\(total) node(s)\(emitted == n ? " (node cap reached)" : "")")
        return out.joined(separator: "\n")
    }

    /// 异步收口: AX 读取放主线程, 返回 Sendable String。
    static func readTreeAsync(app: String?, depth: Int, nodes: Int, role: String?) async -> String {
        await MainActor.run {
            UIInspectDriver.readTree(app: app, depth: depth, nodes: nodes, role: role)
        }
    }

    // ── AX 读原语(全部安全转换, 无 as! / try!) ──────────────────────────
    //
    // AXValue 坐标解码: kAXPositionAttribute / kAXSizeAttribute 返回 AXValue
    // (AXValue.h:119 的 CF_BRIDGED_TYPE(id) 指针), Swift 对其 as?/as 一律报
    // error, as! 违反项目铁律。桥接惯用法 = 项目先例 SQLiteStore.swift:30
    // (sqlite3_* 同法 @_silgen_name)。参数按 C ABI 声明为 AnyObject?(对象引用
    // 即 id, 与 C 侧 AXValueRef = CF_BRIDGED_TYPE(id) 指针同传, 探针实证
    // macOS 27.0 上正确解码真实窗口坐标)。进入前已用 CFGetTypeID 校验是
    // AXValue, 非匹配值不会到达 C 解码; 返回 Boolean 失败即 fail-soft 无坐标。
    @_silgen_name("AXValueGetValue")
    private static func axValueGetValue(
        _ value: AnyObject?,
        _ theType: UInt32,
        _ valuePtr: UnsafeMutableRawPointer?,
    ) -> Bool

    static func readAXPoint(_ v: AnyObject?) -> CGPoint? {
        guard
            let v = v,
            CFGetTypeID(v as CFTypeRef) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero
        return axValueGetValue(v, 1 /* kAXValueTypeCGPoint */, &p) ? p : nil
    }

    static func readAXSize(_ v: AnyObject?) -> CGSize? {
        guard
            let v = v,
            CFGetTypeID(v as CFTypeRef) == AXValueGetTypeID()
        else { return nil }
        var s = CGSize.zero
        return axValueGetValue(v, 2 /* kAXValueTypeCGSize */, &s) ? s : nil
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value)
                == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private struct Node {
        var role: String
        var title: String
        var description: String
        var value: String
        /// 屏幕坐标系 frame 中心(clamp 到非负)。无坐标(如 AX 未暴露) → nil, 行尾不加坐标。
        var center: (x: Int, y: Int)?
    }

    private static func copyAttribute(_ el: AXUIElement, attr: CFString) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr, &value) == .success else { return nil }
        return value
    }

    private static func copyString(_ el: AXUIElement, attr: CFString) -> String {
        guard let v = copyAttribute(el, attr: attr) else { return "" }
        if let s = v as? String { return s }
        if let num = v as? NSNumber { return num.stringValue }
        return ""
    }

    private static func readNode(_ el: AXUIElement) -> Node {
        let role = copyString(el, attr: kAXRoleAttribute as CFString)
        let title = copyString(el, attr: kAXTitleAttribute as CFString)
        let desc = copyString(el, attr: kAXDescriptionAttribute as CFString)
        let value = copyString(el, attr: kAXValueAttribute as CFString)
        // 屏幕坐标中心(可选): position + size 皆为 AXValue, 缺一即无坐标(fail-soft, 行仍出)
        var center: (x: Int, y: Int)?
        if let pos = readAXPoint(copyAttribute(el, attr: kAXPositionAttribute as CFString)),
            let sz = readAXSize(copyAttribute(el, attr: kAXSizeAttribute as CFString))
        {
            let c = UIInspect.center(
                x: pos.x, y: pos.y, w: sz.width, h: sz.height)
            center = (max(c.x, 0), max(c.y, 0))
        }
        return Node(
            role: role.isEmpty ? "unknown" : role,
            title: title,
            description: desc,
            value: value,
            center: center)
    }
}

enum InspectUIClient {
    static let toolName = "inspect_ui"

    struct Args: Codable, Sendable {
        let app: String?
        let depth: Int?
        let max_nodes: Int?
        let role: String?
    }

    static func toolEntry() -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "computer",
            argsType: Args.self,
            description:
                "Read the macOS accessibility (AX) element tree of an app — semantic roles, "
                + "titles, descriptions, values, with hierarchy. Every element that exposes a "
                + "frame is annotated ` at:(x,y)` — the screen-space center to click/type at. "
                + "Use it to UNDERSTAND the UI (what controls exist, current value/state), to "
                + "LOCATE a control precisely (instead of guessing pixels), and to VERIFY state "
                + "after an action. Read-only — changes nothing. Workflow: inspect_ui → act "
                + "(click/type at the given coords) → inspect_ui again to confirm. Params: app "
                + "(bundle id or name, default frontmost), depth (default 6, cap 32), max_nodes "
                + "(default 800, cap 4000), role (e.g. button / textfield / menu).",
            schema: ToolSchema(parameters: [
                "app": ToolParameter(
                    type: .string,
                    description: "Target app bundle id or name (default: frontmost app)"),
                "depth": ToolParameter(
                    type: .integer, description: "Max tree depth to traverse (default 6, cap 32)"),
                "max_nodes": ToolParameter(
                    type: .integer, description: "Max nodes to emit (default 800, cap 4000)"),
                "role": ToolParameter(
                    type: .string,
                    description:
                        "Only emit elements with this AX role (e.g. button, textfield, menu)"),
            ]),
            isDestructive: false
        ) { args in
            return await UIInspectDriver.readTreeAsync(
                app: args.app,
                depth: args.depth ?? 6,
                nodes: args.max_nodes ?? 800,
                role: args.role)
        }
    }
}

#endif
