// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MCP stdio transport — bidirectional JSON-RPC over stdin/stdout。
///
/// 传输方式：每行一条 JSON 消息（line-delimited JSON）。
/// 隐私：本地 stdio 通信，无网络暴露。
///
/// 读取路径用 POSIX select（有界等待）+ 原始 fd read（非阻塞 drain），
/// 不用 `FileHandle.read(upToCount:)`（本机 macOS 27 beta 上表现为长时阻塞，
/// 实测 13–23s/行；availableData 与 raw read 均毫秒级）。

import Foundation
import Logging

/// Stdio 传输层：负责读取输入、写入输出。
///
/// 两种工作模式：
///   1. **队列模式**（默认）：外部调用 `enqueue(_:)` 注入消息，
///      `readLine()` 从队列弹出。适用于 HTTP 桥接路径。
///   2. **管道模式**：直接通过 `stdinPipe` / `stdoutPipe` 与
///      子进程通信。适用于 MCP client ↔ remote server。
actor MCPStdioTransport {
    /// 队列模式下的输入缓冲区
    private var inputQueue: [String] = []
    /// 管道模式的 stdin/stdout 引用（子进程通信用）
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    /// 管道读字节缓冲（跨调用累积，处理无换行的半行 + 多行同 chunk）
    private var pipeReadBuffer: Data = Data()
    /// 传输是否就绪
    private var ready: Bool = false
    /// 管道已结束（close() 或 EOF 置位）：readLine() 立即返回 nil，
    /// 让调用方走超时/错误路径，而不是 nil→sleep→nil 无界空转。
    private var transportClosed: Bool = false
    private let log: Logger

    /// 待写给 stdout 的消息批次。
    private var pendingWrites: [String] = []

    init(log: Logger = Logger(label: "ocoreai.mcp.transport")) {
        self.log = log
    }

    // MARK: - 管道配置（子进程模式）

    /// 配置管道模式，绑定子进程输入/输出。
    /// 新绑定 = 全新传输状态（清掉上一轮的 closed 标志与残留缓冲，否则重连后 readLine 恒 nil / 脏缓冲）。
    func configurePipeMode(stdinPipe: Pipe, stdoutPipe: Pipe) {
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.transportClosed = false
        self.pipeReadBuffer.removeAll()
        ready = true
    }

    // MARK: - 队列模式

    /// 将消息注入输入队列（队列模式）。
    func enqueue(_ line: String) {
        guard !line.isEmpty else { return }
        inputQueue.append(line)
    }

    // MARK: - 读写

    /// 读取一行 JSON-RPC 消息。
    ///
    /// 无数据时单次有界等待（≤50ms）后返回 nil（不死等）；
    /// EOF/closed 状态立即返回 nil。半行数据留在 `pipeReadBuffer` 供下轮取用。
    func readLine() async -> String? {
        if transportClosed { return nil }
        if let pipe = stdoutPipe {
            return readLineFromPipe(pipe)
        }
        guard !inputQueue.isEmpty else { return nil }
        return inputQueue.removeFirst()
    }

    /// select 有界等待 → 非阻塞 drain → 从缓冲取第一完整行。
    private func readLineFromPipe(_ pipe: Pipe) -> String? {
        let fh = pipe.fileHandleForReading
        let fd = fh.fileDescriptor
        guard fd >= 0 else { return nil }

        // 幂等置非阻塞（保证后续 read 在数据耗尽时返回 EAGAIN 而非挂死）
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0, (flags & O_NONBLOCK) == 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        // 已缓冲数据 → 不必等内核，直接取行
        if pipeReadBuffer.isEmpty {
            // poll 有界等待（≤50ms）；EINTR 重试；其他错误交给 drain 判定
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while true {
                let r = poll(&pfd, 1, 50)
                if r > 0 { break }  // POLLIN / POLLHUP / POLLNVAL
                if r < 0, errno == EINTR { continue }
                break  // timeout 或错误 → 进入 drain 判定
            }
        }

        // 非阻塞 drain：读满当前可读（EAGAIN = 清空），n==0 = EOF
        var chunk = [UInt8](repeating: 0, count: 8192)
        while !transportClosed {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                pipeReadBuffer.append(contentsOf: chunk[0 ..< n])
                continue
            }
            if n == 0 {
                transportClosed = true  // EOF：子进程关闭了 stdout
                break
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }
            // 其他读错误：按 EOF 处理（管道不可用）
            transportClosed = true
            break
        }

        // 取第一完整行（\n 之前），残留字节留到下轮
        if let nl = pipeReadBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: pipeReadBuffer[..<nl], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pipeReadBuffer.removeSubrange(..<pipeReadBuffer.index(after: nl))
            return line.isEmpty ? nil : line
        }
        guard !pipeReadBuffer.isEmpty else { return nil }
        // 无换行的残留：子进程已终止（EOF，closed=true）→ 返回残行；否则等待下轮补足
        if transportClosed {
            let leftover = String(decoding: pipeReadBuffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pipeReadBuffer.removeAll()
            return leftover.isEmpty ? nil : leftover
        }
        return nil
    }

    /// 写入一条 JSON-RPC 消息（排队）。
    func write(_ message: String) async {
        pendingWrites.append(message)
    }

    /// 立即写入到管道（子进程模式)，跳过缓冲区。
    @discardableResult
    func writeDirect(_ message: String) async -> Bool {
        guard let pipe = stdinPipe else {
            pendingWrites.append(message)
            return false
        }
        return writeString(pipe, text: message)
    }

    /// 将字符串写入管道。
    @discardableResult
    private func writeString(_ pipe: Pipe, text: String) -> Bool {
        guard let data = text.appending("\n").data(using: .utf8) else {
            return false
        }
        pipe.fileHandleForWriting.write(data)
        return true
    }

    /// 刷新所有待写消息（队列模式）。
    @discardableResult
    func flush() async -> [String] {
        let batch = pendingWrites
        pendingWrites.removeAll()

        if let pipe = stdinPipe {
            let combined = batch.joined(separator: "\n") + "\n"
            guard let data = combined.data(using: .utf8) else { return batch }
            pipe.fileHandleForWriting.write(data)
        }

        return batch
    }

    // MARK: - 状态

    /// 传输是否就绪
    func isReady() -> Bool {
        ready
    }

    /// 标记就绪
    func setReady() {
        ready = true
    }

    /// 管道是否已结束（EOF/close）——客户端死进程路径参考。
    func isEnded() -> Bool {
        transportClosed
    }

    /// 关闭管道。
    func close() async {
        transportClosed = true
        pipeReadBuffer.removeAll()
        stdinPipe?.fileHandleForWriting.closeFile()
        stdoutPipe?.fileHandleForReading.closeFile()
        stdinPipe = nil
        stdoutPipe = nil
        ready = false
    }
}

/// Stdio 传输层错误类型。
enum MCPTransportError: Error {
    case pipeClosed
    case timeout
}
