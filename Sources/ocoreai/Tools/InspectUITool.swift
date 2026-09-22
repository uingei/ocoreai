// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// inspect_ui — 「自主操作计算机」的结构化 UI 语义层。
///
/// 第一性: "自主操作" = 感知(知道现在是什么)→ 决策(模型)→ 动作(改变)→ 感知(确认变成什么)。
/// 此前 ocoreai 的"感知"是像素层(view_screen/OCR), "动作"是盲坐标 CGEvent —— 两半都过不了
/// "这是不是一个控件? 现在 value 是什么?" 这道坎, 所以是开环盲打。
///
/// Apple 为"让程序理解并操作 UI"设计的官方接口 = Accessibility API(AX 元素树)。
/// inspect_ui 读 live AX 树的**语义面**: role / title / description / value + 父子层级。
/// 一次补"语义理解 + 动作后验证"两块(读 value/state 确认动作生效); 精确定位仍由
/// 既有 view_screen(像素) + OCR 承担 —— 那条路已通, 不必在此重造。
///
/// 安全: 只读(零副作用), isDestructive: false, 免审批(同一范式于 observe_state)。
/// 无 Accessibility 权限 → 诚实回报(不假装读到)。macOS 门(AX 是 macOS 语义), 与
/// desktop control 6 工具同 #if os(macOS) 段。全 Safe API, 无 as!/try!。
import Foundation

#if os(macOS)
import AppKit
import ApplicationServices
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
                out.append(
                    UIInspect.line(depth: layer - 1, role: node.role, label: label, value: v))
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
    }

    private static func copyString(_ el: AXUIElement, attr: CFString) -> String {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr, &value) == .success else { return "" }
        if let s = value as? String { return s }
        if let num = value as? NSNumber { return num.stringValue }
        return ""
    }

    private static func readNode(_ el: AXUIElement) -> Node {
        let role = copyString(el, attr: kAXRoleAttribute as CFString)
        let title = copyString(el, attr: kAXTitleAttribute as CFString)
        let desc = copyString(el, attr: kAXDescriptionAttribute as CFString)
        let value = copyString(el, attr: kAXValueAttribute as CFString)
        return Node(
            role: role.isEmpty ? "unknown" : role,
            title: title,
            description: desc,
            value: value)
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
                + "titles, descriptions, values, with hierarchy. Use it to UNDERSTAND the UI "
                + "(what controls exist, what their current value/state is) and to VERIFY state "
                + "after an action. For precise pixel location of a control, use view_screen + OCR "
                + "and click the coordinate. Read-only — changes nothing. Params: app (bundle id "
                + "or name, default frontmost), depth (default 6, cap 32), max_nodes (default 800, "
                + "cap 4000), role (e.g. button / textfield / menu).",
            schema: ToolSchema(parameters: [
                "app": ToolParameter(
                    type: .string,
                    description: "Target app bundle id or name (default: frontmost app)"),
                "depth": ToolParameter(
                    type: .string, description: "Max tree depth to traverse (default 6, cap 32)"),
                "max_nodes": ToolParameter(
                    type: .string, description: "Max nodes to emit (default 800, cap 4000)"),
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
