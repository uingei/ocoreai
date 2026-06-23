// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MCP stdio transport — bidirectional JSON-RPC over stdin/stdout.
///
/// Transport: Line-delimited JSON per message.
/// Privacy: local stdio only, no network transmission.
import Foundation
import Logging

/// Stdio transport for MCP — reads from stdin, writes to stdout.
actor MCPStdioTransport {
    private let inputQueue: [String]
    private var ready: Bool = false
    private let log: Logger
    
    /// Messages waiting to be flushed to stdout.
    private var pendingWrites: [String] = []
    
    /// Callback for incoming messages
    private var reader: (@Sendable (String) async -> Void)?

    init(log: Logger = Logger(label: "ocoreai.mcp.transport")) {
        self.inputQueue = []
        self.log = log
    }
    
    /// Set message handler
    func setReader(_ handler: @Sendable @escaping (String) async -> Void) {
        self.reader = handler
    }
    
    /// Read a line from stdin (stub for CLI integration).
    func readLine() async -> String? {
        // In actual integration, this reads from FileHandle.standardInput
        // For now, return from queued input
        return nil
    }
    
    /// Write a JSON-RPC message to stdout.
    func write(_ message: String) async {
        pendingWrites.append(message)
    }
    
    /// Flush all pending writes.
    /// Returns the batch of messages to write.
    func flush() async -> [String] {
        let batch = pendingWrites
        pendingWrites.removeAll()
        return batch
    }
    
    /// Check if transport is ready.
    func isReady() -> Bool { ready }
    func setReady() { ready = true }
}
