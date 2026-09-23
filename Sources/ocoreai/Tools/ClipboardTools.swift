// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Clip — 「自主操作计算机」的跨应用数据通道。
///
/// 第一性: 文本是跨 app 的通用货币。桌面 6 原语 + app 生命周期让 agent 能「切到某个
/// app」, 但「把 A 里的文本搬到 B」此前只能逐字 type_text (慢、Unicode 脆、长文本
/// 不可行) 或让用户手动复制。剪贴板是 Apple 为「跨应用传数据」设计的官方面, 一次
/// read + 一次 write 就把 A→B 闭合: 读 A 产生的文本(或用户选中的) → 写到剪贴板 →
/// 切到 B 粘贴。这是"自主操作计算机"动作链里最常用的一根管道。
///
/// 深度 + 各平台(非 macOS-only): 剪贴板是 iOS 17 与 macOS 14 各自的一等公民——
///   macOS 14  NSPasteboard.general  string(forType:) / setString(_:forType:) / clearContents()
///   iOS 17    UIPasteboard.general  .string
/// 两个都是 14/17 基线内的非弃用 API, 且与本仓 UI 层已用的同一表面
/// (ChatView.swift:914 macOS 分支 / :925 iOS 分支) 完全一致 — 不另造桥, 消费平台面。
/// 故本工具跨平台注册(不 #if 到 macOS), 与桌面控制/AX/App 生命周期(那些是 macOS 专属
/// 语义)不同轴。
///
/// 审批边界(安全原则, 最高权威): 拦「后果/权限/物理」= 边界(留)。
///   read_clipboard   只读, 零副作用, 免审批(同 inspect_ui / observe_state 范式)
///   write_clipboard  改全局 app 可见态(用户与所有 app 都能感知) → isDestructive: true
///                    走审批门。注意: 这是对「全局状态变更」这条后果的边界, 不判断
///                    写入的是什么文本内容(不拦内容类别/价值观)。
///
/// 纪律: 读输出截断(防一个 50KB 剪贴板灌爆模型上下文, 同 inspect_ui displayText),
/// 全 Safe API, 无 as!/try!/fatalError。Pure/Driver/Client 三段(同 SpeechTools/
/// AppLifecycle)。
import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Pure(双平台离线可测 — 不触 NSPasteboard/UIPasteboard 运行时)

enum Clipboard {
    /// 空态: nil 或零长即空(纯空白不视为数据, 保留原样展示)。纯, 精确可测。
    static func isBlank(_ s: String?) -> Bool {
        (s == nil) || (s == "")
    }

    /// max_chars 钳制: nil/<=0 → 默认 2000; 否则 clamp [100, 20000]。纯, 精确可测。
    static func clampMax(_ n: Int?) -> Int {
        guard let n, n > 0 else { return 2000 }
        return min(max(n, 100), 20_000)
    }

    /// 读报告: 元信息 + 截断正文。未超 → 全量; 超 → 前 maxLen + 诚实尾注(总长/余量)。
    /// 空 → 明确的空态(不捏造内容)。纯, 精确可测。
    static func readReport(_ text: String?, maxLen: Int) -> String {
        if isBlank(text) { return "clipboard: (empty)" }
        let t = text!
        let total = t.count
        guard total > maxLen else {
            return "clipboard(\(total) chars):\n\(t)"
        }
        let head = String(t.prefix(maxLen))
        return
            "clipboard(\(total) chars, truncated to \(maxLen)):\n\(head)\n…(\(total - maxLen) more chars not shown)"
    }

    /// 写确认: 成功给字符数(供模型核对写对了多少), 失败给诚实原因。纯, 精确可测。
    static func writeReport(_ text: String, ok: Bool) -> String {
        guard ok else { return "clipboard: write FAILED (platform rejected the write)" }
        return "clipboard set (\(text.count) chars)"
    }
}

// MARK: - Driver(平台, 主线程 — 剪贴板是 GUI 态, 收口 MainActor)

enum ClipboardDriver {
    static func readText() async -> String? {
        await MainActor.run { () -> String? in
            #if os(macOS)
            return NSPasteboard.general.string(forType: .string)
            #else
            return UIPasteboard.general.string
            #endif
        }
    }

    /// 写 = 「替换」语义: 先 clearContents 清掉既有类型(图/RTF…), 再写入纯文本。
    /// macOS 返回 setString 的真值; iOS 赋值恒成。
    static func writeText(_ s: String) async -> Bool {
        await MainActor.run { () -> Bool in
            #if os(macOS)
            let pb = NSPasteboard.general
            pb.clearContents()
            return pb.setString(s, forType: .string)
            #else
            UIPasteboard.general.string = s
            return true
            #endif
        }
    }
}

// MARK: - Clients(双平台工具面)

enum ReadClipboardClient {
    static let toolName = "read_clipboard"
    struct Args: Codable, Sendable { let max_chars: Int? }

    static func toolEntry() -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "computer",
            argsType: Args.self,
            description:
                "Read the current system clipboard TEXT (macOS NSPasteboard / iOS UIPasteboard). "
                + "Read-only — changes nothing. Returns the clipboard text, truncated by default "
                + "to `max_chars` (default 2000) to protect the context window. Use it to CAPTURE "
                + "text another app produced (after selecting + copy via the desktop tools) or to "
                + "SEE what the user last copied before you overwrite it with write_clipboard.",
            schema: ToolSchema(parameters: [
                "max_chars": ToolParameter(
                    type: .integer,
                    description:
                        "Max chars to return (default 2000, cap 20000); larger text is truncated with an honest tail note"
                )
            ]),
            isDestructive: false
        ) { args in
            let maxLen = Clipboard.clampMax(args.max_chars)
            let text = await ClipboardDriver.readText()
            return Clipboard.readReport(text, maxLen: maxLen)
        }
    }
}

enum WriteClipboardClient {
    static let toolName = "write_clipboard"
    struct Args: Codable, Sendable { let text: String }

    static func toolEntry() -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "computer",
            argsType: Args.self,
            description:
                "Write TEXT to the system clipboard (macOS NSPasteboard / iOS UIPasteboard), "
                + "replacing its current contents. Changes global app-visible state (the user and "
                + "every app can now see it), so it routes through the approval gate. Use it to hand "
                + "text to the frontmost app for a subsequent paste (Cmd-Ctrl+V) instead of typing it "
                + "character by character — the reliable path for long / Unicode / symbol-heavy content.",
            schema: ToolSchema(parameters: [
                "text": ToolParameter(
                    type: .string,
                    description: "The exact text to place on the clipboard")
            ]),
            isDestructive: true
        ) { args in
            let ok = await ClipboardDriver.writeText(args.text)
            return Clipboard.writeReport(args.text, ok: ok)
        }
    }
}
