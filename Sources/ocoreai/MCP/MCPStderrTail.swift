// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! MCPStderrTail.swift — the last few lines an external MCP server wrote to stderr.
//!
//! ### What was wrong (found 10-21)
//! `MCPStdioClient.launchProcess` set `proc.standardError = nil`, i.e. Foundation pointed the
//! child's stderr at /dev/null. Everything that stream would have named — the Python
//! `ModuleNotFoundError`, the Node `MODULE_NOT_FOUND`, the `bind: address already in use` —
//! was thrown away. So a server that dies on startup was reported as
//! "MCP server process exited with status 1" and one that never answered as
//! "did not answer within 30s". Both sentences are true, neither is a diagnosis, and the
//! operator still has to reproduce the crash by hand, outside this app, to learn *why*.
//!
//! ### Why a bounded tail, and where the shape comes from
//! stderr is diagnostics, not the protocol stream, so it needs neither the protocol's
//! allowance nor an unbounded buffer: codex caps one stderr line at 1 MiB where stdout gets
//! 8 MiB (`rmcp-client/src/executor_process_transport.rs:52-53`) and logs every line as it
//! arrives (`:480 flush_stderr()`), keeping nothing. Same division here, sized for what a
//! person reads: the last `maxLines` lines at `maxLineChars` characters each. A traceback
//! puts the exception line *last*, which is exactly what a ring buffer keeps, and a chatty
//! or hostile server cannot grow this buffer (AGENTS.md: a caller's bug costs a rounding,
//! not the process).

import Foundation

/// 子进程 stderr 的有界尾部：写侧是 drain 线程，读侧是本进程的 actor 与测试。
///
/// `@unchecked Sendable` 的理由：全部可变状态都由 `lock` 保护，每个公开入口的第一件事
/// 就是取锁；唯一的写者是一条串行 drain 线程，读者按锁取值 ⇒ 无数据竞争，且读侧
/// 不需要 await（诊断路径不能为了取证据再跳一次 actor）。
final class MCPStderrTail: @unchecked Sendable {
    /// 诊断里最多带几行。一次 Python traceback 连 framework 帧通常 5–10 行，12 行够
    /// 定位，又不至于把一次 HTTP 拒绝塞成日志转储。
    static let maxLines = 12
    /// 单行最多保留的字符数（超出截断并以 `…` 标注）。
    static let maxLineChars = 400
    /// 半行缓冲的字节上限。UTF-8 最坏 4 字节/字符 ⇒ 与 ``maxLineChars`` 同一道界，
    /// 一个不换行疯狂输出的 server 因此撑不出第二条内存曲线。
    static let maxPartialBytes = maxLineChars * 4

    private let lock = NSLock()
    private var lines: [String] = []
    private var partial: [UInt8] = []
    private var partialTruncated = false
    private var ended = false
    private var suppressed = 0

    /// 收下 drain 读到的一段字节，返回**这一跳补全的整行**（调用方据此逐行落日志）。
    ///
    /// 按字节累积而不是按 chunk 解码：一个 UTF-8 字符可能正好被 chunk 边界切开，
    /// 逐 chunk `String(decoding:)` 会把它变成 U+FFFD，而按行解码不会。
    func append(_ data: Data) -> [String] {
        var completed: [String] = []
        lock.lock()
        defer { lock.unlock() }
        for byte in data {
            if byte == 0x0A {
                if let line = flushPartialLocked() { completed.append(line) }
            } else if partial.count < Self.maxPartialBytes {
                partial.append(byte)
            } else {
                partialTruncated = true
            }
        }
        return completed
    }

    /// 管道 EOF：没换行的尾巴也是一行证据（codex `flush_stderr()` 同理）。
    func finish() -> String? {
        lock.lock()
        defer { lock.unlock() }
        ended = true
        return flushPartialLocked()
    }

    /// 读侧是否已见到 EOF（子进程关掉了 stderr，或已退出）。
    func isEnded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    /// 保留下来的行数（≤ ``maxLines``）。
    func lineCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return lines.count
    }

    /// 折进诊断的文本；**没有证据就返回 `nil`**——不许编造一段"大概是因为"。
    func snapshot() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !lines.isEmpty else { return nil }
        var text = lines.joined(separator: " | ")
        if suppressed > 0 { text += " (+\(suppressed) earlier stderr lines suppressed)" }
        return text
    }

    /// 新一轮连接 = 新一个孩子：上一轮的死因不该混进这一轮的诊断。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
        partial.removeAll(keepingCapacity: true)
        partialTruncated = false
        ended = false
        suppressed = 0
    }

    /// 取走半行缓冲并记账。调用方持锁。
    private func flushPartialLocked() -> String? {
        let bytes = partial
        let truncated = partialTruncated
        partial.removeAll(keepingCapacity: true)
        partialTruncated = false

        // \r 交给 trimming（Windows/进度条式输出）；非法字节由 lossy 解码消化，不崩。
        var text = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if text.count > Self.maxLineChars {
            text = String(text.prefix(Self.maxLineChars)) + "…"
        } else if truncated {
            text += "…"
        }
        lines.append(text)
        while lines.count > Self.maxLines {
            lines.removeFirst()
            suppressed += 1
        }
        return text
    }
}
