// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// FileToolsTests.swift — file tool surface: read_file / write_file / search_files.
///
/// Verifies the P0 tool-surface implementation (codex borrow: apply-before-verify)
/// and that the registry wiring exposes them with correct safety classifications.
import Foundation
import Logging
import Testing

@testable import ocoreai

@Suite("FileTools — read/write/search")
struct FileToolsBehaviorTests {
    private var workdir: URL = URL(fileURLWithPath: "ft_test_\(UUID().uuidString)")

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        workdir = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
    }

    func seed() throws {
        let alpha = workdir.appendingPathComponent("alpha.txt")
        try "hello\nworld\nline3".write(to: alpha, atomically: true, encoding: .utf8)
        let log = workdir.appendingPathComponent("notes.log")
        try "needle content here".write(to: log, atomically: true, encoding: .utf8)
        let sub = workdir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let gamma = sub.appendingPathComponent("gamma.swift")
        try "deep needle".write(to: gamma, atomically: true, encoding: .utf8)
    }

    @Test("read_file returns numbered lines with full-window and windowed reads")
    func readBasics() throws {
        try seed()
        let full = try FileTools.read(path: workdir.appendingPathComponent("alpha.txt").path)
        #expect(full.contains("1|hello"))
        #expect(full.contains("3|line3"))
        #expect(full.contains("total_lines: 3 (full)"))

        let window = try FileTools.read(
            path: workdir.appendingPathComponent("alpha.txt").path,
            offset: 2, limit: 1)
        #expect(window.contains("2|world"))
        #expect(!window.contains("line3"))
        #expect(window.contains("continue at offset=3"))

        #expect(throws: ToolError.self) {
            try FileTools.read(path: workdir.appendingPathComponent("alpha.txt").path, offset: 99)
        }
        #expect(throws: ToolError.self) {
            try FileTools.read(path: workdir.appendingPathComponent("missing.txt").path)
        }
    }

    @Test("write_file creates, replaces, and verifies by read-back")
    func writeBasics() throws {
        try seed()
        let created = workdir.appendingPathComponent("sub/delta.swift")
        let createResult = try FileTools.write(path: created.path, content: "<t>123</t>\nend")
        #expect(createResult.contains("created"))
        #expect(createResult.contains("read-back verified"))
        #expect((try? String(contentsOf: created, encoding: .utf8)) == "<t>123</t>\nend")

        let alpha = workdir.appendingPathComponent("alpha.txt").path
        let original = (try? Data(contentsOf: URL(fileURLWithPath: alpha)))?.count ?? 0
        let replaceResult = try FileTools.write(path: alpha, content: "replaced")
        #expect(replaceResult.contains("replaced \(original) bytes"))
        #expect(replaceResult.contains("read-back verified"))

        let empty = workdir.appendingPathComponent("e.txt")
        _ = try FileTools.write(path: empty.path, content: "")
        #expect((try? Data(contentsOf: empty))?.isEmpty == true)

        #expect(throws: ToolError.self) {
            try FileTools.write(
                path: workdir.appendingPathComponent("big").path,
                content: String(repeating: "x", count: FileTools.maxWriteBytes + 1))
        }
    }

    @Test("search_files finds by filename glob and by content substring")
    func searchBasics() throws {
        try seed()
        let byName = try FileTools.search(path: workdir.path, pattern: "a*")
        #expect(byName.contains("alpha.txt"))
        #expect(!byName.contains("notes.log"))

        let byGlob = try FileTools.search(path: workdir.path, pattern: "*.swift")
        #expect(byGlob.contains("gamma.swift"))

        let byContent = try FileTools.search(
            path: workdir.path, pattern: "needle", target: "content")
        #expect(byContent.contains("notes.log"))
        #expect(byContent.contains("gamma.swift"))
        #expect(byContent.contains("total: 2"))

        #expect(try FileTools.search(path: workdir.path, pattern: "zzz*").contains("0 files"))
        #expect(
            try FileTools.search(path: workdir.path, pattern: "absent-string", target: "content")
                .contains("0 files"))

        // Hidden files/dirs are not searched.
        let hid = workdir.appendingPathComponent(".hiddendir")
        try FileManager.default.createDirectory(at: hid, withIntermediateDirectories: true)
        let secret = hid.appendingPathComponent("s.txt")
        try "secret needle".write(to: secret, atomically: true, encoding: .utf8)
        #expect(
            try FileTools.search(path: workdir.path, pattern: "secret", target: "content")
                .contains("0 files"))
    }

    @Test("edit_file replaces on exact match, refuses ambiguous or missing matches")
    func editFileBehavior() throws {
        try seed()
        let target = workdir.appendingPathComponent("alpha.txt").path
        try "hello\nworld\nline3".write(
            to: URL(fileURLWithPath: target), atomically: true, encoding: .utf8)

        // Unique match → applied + verified.
        let ok = try FileTools.editFile(
            path: target, oldString: "world", newString: "WORLD", occurrences: 1)
        #expect(ok.contains("OK"))
        #expect(ok.contains("1 replacement(s)"))
        #expect(ok.contains("read-back verified"))
        #expect(
            (try? String(contentsOf: URL(fileURLWithPath: target), encoding: .utf8))
                == "hello\nWORLD\nline3")

        // Ambiguous (2 matches while expecting 1) → refused, file untouched.
        let multi = workdir.appendingPathComponent("multi.txt").path
        try "dup x dup".write(to: URL(fileURLWithPath: multi), atomically: true, encoding: .utf8)
        #expect(throws: ToolError.self) {
            try FileTools.editFile(
                path: multi, oldString: "dup", newString: "D", occurrences: 1)
        }
        #expect(
            (try? String(contentsOf: URL(fileURLWithPath: multi), encoding: .utf8)) == "dup x dup")

        // Explicit occurrences=2 → applied.
        _ = try FileTools.editFile(
            path: multi, oldString: "dup", newString: "DUP", occurrences: 2)
        #expect(
            (try? String(contentsOf: URL(fileURLWithPath: multi), encoding: .utf8)) == "DUP x DUP")

        // Missing match → refused; no-op (old==new) → refused; empty old → refused.
        #expect(throws: ToolError.self) {
            try FileTools.editFile(
                path: multi, oldString: "never-there", newString: "x", occurrences: 1)
        }
        #expect(throws: ToolError.self) {
            try FileTools.editFile(
                path: multi, oldString: "x", newString: "x", occurrences: 1)
        }
        #expect(throws: ToolError.self) {
            try FileTools.editFile(
                path: multi, oldString: "", newString: "x", occurrences: 0)
        }
    }

    @Test("binary files are rejected for read")
    func binaryReject() throws {
        try seed()
        let bin = workdir.appendingPathComponent("b.bin")
        try Data([0, 1, 2, 3]).write(to: bin)
        #expect(throws: ToolError.self) {
            try FileTools.read(path: bin.path)
        }
    }

    @Test("path resolution expands tilde and cwd-relative paths")
    func pathResolution() {
        #expect(FileTools.resolve("~/x.y").path == NSHomeDirectory() + "/x.y")
        #expect(FileTools.resolve("/abs/p").path == "/abs/p")
        #expect(FileTools.resolve("../rel").path.hasSuffix("/rel"))
    }
}

@Suite("FileTools — registry wiring")
struct FileToolsRegistryTests {
    @Test("bootstrap registers read_file, write_file, search_files with correct safety flags")
    func registryWiring() async throws {
        let registry = ToolRegistry(log: Logger(label: "test.filetools"))
        await bootstrapBuiltInTools(registry: registry)

        let names = await registry.listTools()
        #expect(names.contains("read_file"))
        #expect(names.contains("write_file"))
        #expect(names.contains("edit_file"))
        #expect(names.contains("search_files"))

        #expect(await registry.isReadOnly("read_file"))
        #expect(await registry.isReadOnly("search_files"))
        #expect(!(await registry.isReadOnly("write_file")))
        #expect(!(await registry.isReadOnly("edit_file")))
        #expect(await registry.isDestructive("write_file"))
        #expect(await registry.isDestructive("edit_file"))
        #expect(!(await registry.isDestructive("read_file")))

        // Schemas must expose their parameters to the model.
        let readSchema = await registry.schema(for: "read_file")
        #expect(readSchema?.parameters["path"] != nil)
        #expect(readSchema?.parameters["limit"] != nil)
        let writeSchema = await registry.schema(for: "write_file")
        #expect(writeSchema?.parameters["content"] != nil)
        let editSchema = await registry.schema(for: "edit_file")
        #expect(editSchema?.parameters["oldString"] != nil)
        #expect(editSchema?.parameters["occurrences"] != nil)
        let searchSchema = await registry.schema(for: "search_files")
        #expect(searchSchema?.parameters["pattern"] != nil)
        #expect(searchSchema?.parameters["target"] != nil)

        // End-to-end dispatch through the registry.
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftreg_\(UUID().uuidString).txt").path
        let writeJSON = #"{"path":"\#(target)","content":"a b c\n"}"#
        let writeOut = try await registry.call("write_file", arguments: writeJSON, caller: "test")
        #expect(writeOut.contains("read-back verified"))

        let editJSON = #"{"path":"\#(target)","oldString":"b","newString":"B","occurrences":1}"#
        let editOut = try await registry.call("edit_file", arguments: editJSON, caller: "test")
        #expect(editOut.contains("1 replacement(s)"))
        #expect(editOut.contains("read-back verified"))

        let readJSON = #"{"path":"\#(target)"}"#
        let readOut = try await registry.call("read_file", arguments: readJSON, caller: "test")
        #expect(readOut.contains("1|a B c"))

        let searchDir = (target as NSString).deletingLastPathComponent
        let searchOut = try await registry.call(
            "search_files",
            arguments: #"{"path":"\#(searchDir)","pattern":"ftreg_*"}"#,
            caller: "test"
        )
        #expect(searchOut.contains(target))

        try? FileManager.default.removeItem(atPath: target)
    }
}
