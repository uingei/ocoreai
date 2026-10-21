// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// WorkspacePathAnchorTests — where a relative tool path lands, and whether the caller
/// can find out.
///
/// Why (measured 10-22, `scripts/eval/run.sh`): the first task-success scoreboard scored
/// 4/9, and five failures were the same sentence in the server log —
/// `edit_file: cannot read (missing or non-UTF8): calc.py`. `SessionWorkspace.setDirectory`
/// is called only from the UI (`ChatViewModel`, `SessionManager`), so a wire client had no
/// way to state a workspace: every relative path anchored to the *process* cwd, the
/// `working_directory:` line was absent from the prompt, and the refusal named only the
/// relative name — so the model retried the same wrong path until it gave up. Two homes
/// fix that: `OCOREAI_WORKSPACE` in `WorkspaceContext.configuredDirectory()` (the fallback
/// every consumer already reads), and `FileTools.pathContext` in the refusals.
import Foundation
import Testing

@testable import ocoreai

@Suite(.serialized)
struct WorkspacePathAnchorTests {

    private static func sandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_anchor_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("OCOREAI_WORKSPACE anchors relative paths, and beats a stored setting")
    func envAnchorWins() throws {
        let ws = try Self.sandbox()
        try "def add(a, b):\n    return a + b\n"
            .write(to: ws.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)

        let suite = "ocoreai.anchor.test.\(UUID().uuidString.prefix(8))"
        let stored = UserDefaults(suiteName: suite)!
        stored.set(FileManager.default.temporaryDirectory, forKey: WorkspaceContext.settingsKey)

        setenv(WorkspaceContext.workspaceEnvironmentKey, ws.path, 1)
        defer {
            unsetenv(WorkspaceContext.workspaceEnvironmentKey)
            stored.removePersistentDomain(forName: suite)
        }

        #expect(WorkspaceContext.environmentDirectory() == ws.path)
        // The chain every consumer reads (FileTools.resolve, ExecTools.effectiveCwd,
        // MessageBuilder's working_directory line) resolves to the stated workspace.
        #expect(WorkspaceContext.configuredDirectory(defaults: stored) == ws.path)

        let text = try FileTools.read(path: "calc.py")
        #expect(text.contains("return a + b"))
    }

    @Test("a stated workspace that does not exist (or is a file) is no anchor")
    func envAnchorValidated() throws {
        let dir = try Self.sandbox()
        let file = dir.appendingPathComponent("plain.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        #expect(
            WorkspaceContext.environmentDirectory(environment: [:]) == nil,
            "unset env must not invent an anchor")
        #expect(
            WorkspaceContext.environmentDirectory(environment: [
                WorkspaceContext.workspaceEnvironmentKey: dir.appendingPathComponent("absent").path
            ]) == nil,
            "a missing directory is not an anchor — the fix must not relocate refusals into nowhere"
        )
        #expect(
            WorkspaceContext.environmentDirectory(environment: [
                WorkspaceContext.workspaceEnvironmentKey: file.path
            ]) == nil,
            "a file path is not a working directory")
    }

    @Test("a refusal names the absolute path it looked at and who anchored it")
    func refusalIsRecoverable() throws {
        let ws = try Self.sandbox()
        SessionWorkspace.setDirectory(ws.path)
        defer { SessionWorkspace.clear() }

        do {
            _ = try FileTools.read(path: "missing.py")
            Issue.record("reading a missing file must not succeed")
        } catch let ToolError.invalidParameter(message) {
            #expect(
                message.contains(ws.appendingPathComponent("missing.py").path),
                "the refusal has to name where it looked: \(message)")
            #expect(
                message.contains("session workspace"),
                "and who anchored it, so the caller can correct instead of retrying: \(message)")
        }
    }

    /// The refusal must describe the anchor it actually used — which depends on how this
    /// host is configured, so the assertion follows the measured anchor instead of assuming
    /// one (a gate that only passes on a pristine machine is a gate that gets ignored).
    @Test("the refusal names the anchor it really used, including the no-workspace case")
    func fallbackIsTruthful() throws {
        SessionWorkspace.clear()
        unsetenv(WorkspaceContext.workspaceEnvironmentKey)
        let anchor = WorkspaceContext.configuredDirectory()

        do {
            _ = try FileTools.read(path: "definitely_absent_\(UUID().uuidString.prefix(8)).py")
            Issue.record("reading a missing file must not succeed")
        } catch let ToolError.invalidParameter(message) {
            if anchor == nil {
                #expect(
                    message.contains("OCOREAI_WORKSPACE"),
                    "no workspace set: the refusal has to say how to set one: \(message)")
                #expect(
                    message.contains("process cwd"),
                    "and admit it fell back to the process cwd: \(message)")
            } else {
                #expect(
                    message.contains("configured workspace"),
                    "a configured anchor must be named as such, not dressed up as a session: \(message)"
                )
                #expect(
                    message.contains(anchor ?? ""),
                    "and the refusal must name that anchor: \(message)")
            }
        }
    }
}
