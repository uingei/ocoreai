// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MCP stdio transport — bidirectional JSON-RPC over stdin/stdout。
///
/// 传输方式：每行一条 JSON 消息（line-delimited JSON）。
/// 隐私：本地 stdio 通信，无网络暴露。

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
    /// 传输是否就绪
    private var ready: Bool = false
    private let log: Logger

    /// 待写给 stdout 的消息批次。
    private var pendingWrites: [String] = []

    init(log: Logger = Logger(label: "ocoreai.mcp.transport")) {
        self.log = log
    }

    // MARK: - 管道配置（子进程模式）

    /// 配置管道模式，绑定子进程输入/输出。
    func configurePipeMode(stdinPipe: Pipe, stdoutPipe: Pipe) {
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.ready = true
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
    /// 优先级：管道模式 > 队列模式。
    /// - Returns: JSON-RPC 消息字符串。无数据时返回 nil。
    func readLine() async -> String? {
        // 管道路线：从 stdoutPipe 异步读取
        if let pipe = stdoutPipe {
            return try? await readLineFromPipe(pipe)
        }
        guard !inputQueue.isEmpty else { return nil }
        return inputQueue.removeFirst()
    }

    /// 从管道读取一行（异步）。
    private func readLineFromPipe(_ pipe: Pipe) async throws -> String? {
        _ = pipe.fileHandleForReading

        return try await withCheckedThrowingContinuation { continuation in
            let readHandle = self.stdoutPipe?.fileHandleForReading ?? FileHandle.standardInput
            DispatchQueue.global().async {
                do {
                    // 非阻塞：尝试读取可用数据
                    let data = try readHandle.read(upToCount: 65_536)
                    guard let data, !data.isEmpty else {
                        continuation.resume(returning: nil)
                        return
                    }

                    guard let text = String(data: data, encoding: .utf8) else {
                        continuation.resume(throwing: MCPTransportError.encodingFailed)
                        return
                    }

                    // 按行切分，取出第一行
                    if let newlineIdx = text.firstIndex(of: "\n") {
                        let line = String(text[..<newlineIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(returning: line.isEmpty ? nil : line)
                    } else {
                        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(returning: line.isEmpty ? nil : line)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 写入一条 JSON-RPC 消息（排队）。
    func write(_ message: String) async {
        pendingWrites.append(message)
    }

    /// 立即写入到管道（子进程模式），跳过缓冲区。
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
    func isReady() -> Bool { ready }
    /// 标记就绪
    func setReady() { ready = true }

    /// 关闭管道。
    func close() async {
        stdinPipe?.fileHandleForWriting.closeFile()
        stdoutPipe?.fileHandleForReading.closeFile()
        stdinPipe = nil
        stdoutPipe = nil
        ready = false
    }
}

/// Stdio 传输层错误类型。
enum MCPTransportError: Error, Sendable {
    case encodingFailed
    case pipeClosed
    case timeout
}
