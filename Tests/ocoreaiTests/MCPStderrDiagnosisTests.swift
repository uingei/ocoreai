// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! MCPStderrDiagnosisTests.swift — when an external MCP server fails, the caller is told what
//! the server itself said.
//!
//! ### Why these tests exist (10-21)
//! `MCPStdioClient.launchProcess` had `proc.standardError = nil`, so Foundation sent the child's
//! stderr to /dev/null. Every refusal therefore described the symptom ("exited with status 1",
//! "did not answer within 30s") while the cause — `ModuleNotFoundError`, `MODULE_NOT_FOUND`,
//! `bind: address already in use` — was destroyed on arrival. No existing test could have caught
//! that: the old wording was green precisely because nothing was expected to arrive. So the
//! cases below assert on real bytes from real child processes, and one floors a source scan so
//! `= nil` cannot come back silently (AGENTS.md invariant 1).
//!
//! ### The two directions guarded
//! Evidence must arrive (a dying server's traceback reaches the refusal), and evidence must not be
//! invented (a silent child's wording stays byte-for-byte what it was before — invariant 2 cuts
//! both ways).

import Foundation
import Testing

@testable import ocoreai

private struct MissingRepoFile: Error, CustomStringConvertible {
    let path: String
    var description: String { "missing repo file: \(path)" }
}

// MARK: - Stubs (literal python; no interpolation, so what is on screen is what runs)

/// Dies on startup: names the cause on stderr, exits 3, never performs the handshake.
private let dyingStub = """
    import sys
    print("Traceback (most recent call last):", file=sys.stderr, flush=True)
    print("ModuleNotFoundError: No module named 'ocoreai_stub_dep'", file=sys.stderr, flush=True)
    sys.exit(3)
    """

/// Starts, complains once on stderr, then hangs without ever answering `initialize`.
private let chattyHangStub = """
    import sys, time
    print("FATAL: address already in use: 127.0.0.1:8777", file=sys.stderr, flush=True)
    time.sleep(120)
    """

/// Works properly, and still talks on stderr at startup (capture must not disturb the protocol).
private let workingStub = """
    import sys, json

    print("INFO: ocoreai-stub warming cache", file=sys.stderr, flush=True)

    def out(obj):
        print(json.dumps(obj))
        sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        method = msg.get("method", "")
        if method == "initialize":
            out({"jsonrpc": "2.0", "id": msg.get("id"),
                 "result": {"protocolVersion": "2024-11-05",
                            "capabilities": {"tools": {}},
                            "serverInfo": {"name": "ocoreai-stderr-stub", "version": "0.1"}}})
        elif method.startswith("notifications/"):
            pass
        elif method == "tools/list":
            out({"jsonrpc": "2.0", "id": msg.get("id"),
                 "result": {"tools": [{"name": "ok_tool",
                                       "description": "answers",
                                       "inputSchema": {"type": "object",
                                                       "properties": {}}}]}})
        elif method == "tools/call":
            out({"jsonrpc": "2.0", "id": msg.get("id"),
                 "result": {"content": [{"type": "text", "text": "arrived"}]}})
        else:
            out({"jsonrpc": "2.0", "id": msg.get("id"), "result": {}})
    """

private func writeStub(_ source: String, tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp_stderr_\(tag)_\(UUID().uuidString).py")
    try source.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// Resolves the repo root by walking up until the file is found (finding it is its own proof).
private func repoRelative(_ relative: String) throws -> String {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0 ..< 6 {
        let candidate = dir.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return try String(contentsOf: candidate, encoding: .utf8)
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    throw MissingRepoFile(path: "\(dir.path)/\(relative)")
}

/// 只留代码行：解释"为什么不能那样写"的注释不是那样写。门若把注释也算命中，
/// 维护者的修法就成了删注释，理由反而被销毁（与 AGENTS.md claim 扫描同一口径）。
private func codeOnly(_ source: String) -> String {
    source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { line in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("/*") && !trimmed.hasPrefix("*")
        }
        .joined(separator: "\n")
}

// MARK: - The bounded tail

@Suite("MCP stderr tail")
struct MCPStderrTailTests {

    @Test("a flood keeps the last 12 lines and counts what it dropped")
    func floodKeepsTailAndCountsSuppressed() {
        let tail = MCPStderrTail()
        var last: String?
        for i in 1 ... 5000 {
            last = tail.append(Data("line-\(i)\n".utf8)).last
        }
        #expect(last == "line-5000", "the newest line is the one that completed")
        #expect(tail.lineCount() == MCPStderrTail.maxLines)
        let text = tail.snapshot() ?? ""
        #expect(text.contains("line-5000"), "newest line present: \(text.suffix(60))")
        #expect(
            text.contains("line-\(5000 - MCPStderrTail.maxLines + 1)"),
            "the window starts exactly at maxLines back")
        #expect(
            !text.contains("line-1 |"),
            "suppressed lines must not survive in the window: \(text.prefix(60))")
        #expect(
            text.contains("4988 earlier stderr lines suppressed"),
            "the reader is told how much was dropped, not just that something was: \(text.suffix(60))"
        )
    }

    @Test("one enormous line cannot grow the buffer or the message")
    func oversizedLineIsTruncatedWithMarker() {
        let tail = MCPStderrTail()
        let huge = String(repeating: "x", count: 5000)
        let done = tail.append(Data((huge + "\n").utf8))
        #expect(done.count == 1)
        let line = done[0]
        #expect(line.hasSuffix("…"), "truncation is visible, not silent")
        #expect(
            line.count <= MCPStderrTail.maxLineChars + 1,
            "a 5000-char line lands at \(line.count) chars, ceiling \(MCPStderrTail.maxLineChars) + marker"
        )
    }

    @Test("a line split across chunks assembles; so does a multibyte character")
    func chunkBoundariesDoNotBreakLines() {
        let tail = MCPStderrTail()
        #expect(tail.append(Data("hel".utf8)).isEmpty, "half a line is not a line yet")
        #expect(tail.append(Data("lo wor".utf8)).isEmpty)
        #expect(tail.append(Data("ld\n".utf8)) == ["hello world"])

        // 一个中文字符正好被 chunk 切开：按 chunk 解码会出 U+FFFD，按字节累积不会。
        let utf8 = Array("诊断中文OK\n".utf8)
        let fresh = MCPStderrTail()
        fresh.append(Data(utf8[0 ..< 3]))
        fresh.append(Data(utf8[3...]))
        let text = fresh.snapshot() ?? ""
        #expect(text == "诊断中文OK", "split multibyte must decode whole, got \(text)")
        #expect(!text.contains("\u{FFFD}"), "no replacement characters from chunk splitting")
    }

    @Test("a tail without a newline is still evidence at EOF")
    func finishFlushesNewlinelessTail() {
        let tail = MCPStderrTail()
        _ = tail.append(Data("killed by OOM".utf8))
        #expect(tail.snapshot() == nil, "no newline yet ⇒ the window is still empty")
        #expect(tail.finish() == "killed by OOM", "codex flush_stderr(): EOF flushes the tail")
        #expect(tail.snapshot() == "killed by OOM")
        #expect(tail.isEnded(), "EOF is recorded so the caller stops waiting")
    }

    @Test("empty means no evidence, and reset clears the previous child's story")
    func emptyAndReset() {
        let tail = MCPStderrTail()
        #expect(tail.snapshot() == nil, "no stderr ⇒ no invented diagnosis")
        _ = tail.append(Data("boom\n".utf8))
        #expect(tail.snapshot() == "boom")
        tail.reset()
        #expect(tail.snapshot() == nil, "a new child must not inherit the old cause")
        #expect(!tail.isEnded())
    }

    @Test("the refusal wording: evidence appended, never invented, never doubled")
    func wireWording() {
        // 没有证据 ⇒ 与加采集之前的文案逐字相同（老客户端的匹配不会漂）。
        let bare = MCPClientError.childExited(137)
        #expect(
            bare.localizedDescription == "MCP server process exited with status 137",
            "no evidence must not change the historical wording: \(bare.localizedDescription)")
        #expect(bare.stderrEvidence == nil)

        let withTail = MCPClientError.childExited(137, stderr: "Killed")
        let text = withTail.localizedDescription
        #expect(text.contains("exited with status 137"), "the symptom stays named: \(text)")
        #expect(text.contains("— stderr: Killed"), "and the cause is appended: \(text)")

        // attemptConnection 会把内层错误再包一次：已有证据不得被覆盖或说第二遍。
        #expect(withTail.withStderr("other").stderrEvidence == "Killed")
        #expect(bare.withStderr(nil).stderrEvidence == nil)
        #expect(bare.withStderr("").stderrEvidence == nil, "empty is not evidence")
        #expect(
            bare.withStderr("boom").withStderr("again").stderrEvidence == "boom",
            "exactly one stderr clause per diagnosis")
    }
}

// MARK: - Live children

@Suite("MCP stderr diagnosis (live child)")
struct MCPStderrDeliveryTests {

    @Test("a server that dies on startup names its own exception in the refusal")
    func dyingServerNamesItsOwnCause() async throws {
        let stub = try writeStub(dyingStub, tag: "dies")
        let ep = MCPEndpoint(name: "dies", stdioCommand: "python3", stdioArgs: [stub.path])
        let client = MCPStdioClient(endpoint: ep, transport: MCPStdioTransport())

        var captured: MCPClientError?
        do {
            try await client.connect()
        } catch let error as MCPClientError {
            captured = error
        }
        await client.disconnect()

        guard let error = captured else {
            Issue.record("a server that exits 3 without a handshake must not 'connect'")
            return
        }
        // 类型必须还是 .childExited：旧写法把它压成 .protocolError，上层从此分不出崩与卡。
        guard case .childExited(let status, let tail) = error else {
            Issue.record("expected .childExited, got \(error)")
            return
        }
        #expect(status == 3, "termination status survives to the caller")
        let text = error.localizedDescription
        #expect(text.contains("ModuleNotFoundError"), "the cause reaches the caller: \(text)")
        #expect(
            text.contains("Traceback (most recent call last):"),
            "the ring keeps the older frames too: \(text)")
        #expect(
            text.components(separatedBy: "stderr:").count == 2,
            "exactly one stderr clause, got: \(text)")
        #expect(
            tail?.contains("ModuleNotFoundError") == true, "evidence is structured, not only prose")
    }

    @Test("a server that hangs after complaining times out at its budget, with the complaint")
    func hungServerTimeoutCarriesItsComplaint() async throws {
        let stub = try writeStub(chattyHangStub, tag: "hangs")
        let ep = MCPEndpoint(
            name: "hangs", stdioCommand: "python3", stdioArgs: [stub.path],
            startupTimeoutSeconds: 2)
        let client = MCPStdioClient(endpoint: ep, transport: MCPStdioTransport())

        let started = Date()
        var captured: MCPClientError?
        do {
            try await client.connect()
        } catch let error as MCPClientError {
            captured = error
        }
        await client.disconnect()
        let elapsed = Date().timeIntervalSince(started)

        guard let error = captured else {
            Issue.record("a server that never answers must not 'connect'")
            return
        }
        guard case .timeout(let name, let seconds, _) = error else {
            Issue.record("expected .timeout, got \(error)")
            return
        }
        #expect(name == "hangs")
        #expect(seconds == 2, "the bound that fired is the bound that was set")
        #expect(elapsed >= 1.9 && elapsed < 4.0, "cut at 2s, measured \(elapsed)s")
        #expect(
            error.localizedDescription.contains("address already in use"),
            "the refusal says why it could not start: \(error.localizedDescription)")
    }

    @Test("a working server still gets captured, and capture does not disturb the protocol")
    func workingServerIsStillCaptured() async throws {
        let stub = try writeStub(workingStub, tag: "works")
        let ep = MCPEndpoint(name: "works", stdioCommand: "python3", stdioArgs: [stub.path])
        let client = MCPStdioClient(endpoint: ep, transport: MCPStdioTransport())
        try await client.connect()
        defer { Task { await client.disconnect() } }

        // listToolsRaw：跨 actor 只能带 Sendable，`[[String: Any]]` 出不了隔离域。
        let raw = try await client.listToolsRaw()
        #expect(raw.contains("ok_tool"), "tools/list still answers through the stderr capture")

        var tail: String?
        for _ in 0 ..< 50 {
            tail = await client.testStderrTail()
            if tail != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            tail == "INFO: ocoreai-stub warming cache",
            "a healthy server's stderr is recorded too, not only failures: \(tail ?? "nil")")
    }

    @Test("the /dev/null regression cannot come back silently")
    func devNullSinkIsGoneFromTheClient() throws {
        let src = codeOnly(
            try repoRelative("Sources/ocoreai/MCP/MCPStdioClient.swift"))
        // 自证：模式必须先能命中，否则"没扫到 = 通过"就是空转（AGENTS.md invariant 1）。
        #expect(src.contains("proc.standardError"), "scan pattern rotted: no stderr wiring at all")
        #expect(
            src.contains("proc.standardError = stderr"), "the child's stderr must reach our pipe")
        #expect(src.contains("startStderrDrain("), "and there must be a reader, not just a pipe")
        #expect(
            src.components(separatedBy: "standardError = nil").count == 1,
            "`standardError = nil` sends the diagnosis to /dev/null — the defect this suite exists for"
        )
    }
}
