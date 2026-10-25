// `cwd` is the argument this surface's callers most often get wrong, and the failure was
// useless: `cwd="<path>/notes.txt"` reached `Process.currentDirectoryURL` and came back as
// "The operation couldn't be completed. Not a directory" — wording that reads as though the
// *operand* were missing. Measured in two scored runs: three tasks abandoned that way. These
// tests pin the one resolver both exec lanes share (`exec_command`, `exec_shell`).
import Foundation
import Testing

@testable import ocoreai

@Suite("exec cwd — resolved once, honestly, by both lanes")
struct ExecCwdContractTests {

    /// `<tmp>/sub/` plus `<tmp>/sub/notes.txt`, so a file-as-cwd slip is reachable.
    private func makeScratch() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ocoreai-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("alpha beta\ngamma\n".utf8).write(
            to: root.appendingPathComponent("sub/notes.txt"))
        return root
    }

    @Test("a cwd naming a file runs in its directory and says so")
    func fileAsCwdRunsInParent() async throws {
        let ws = try makeScratch()
        defer { try? FileManager.default.removeItem(at: ws) }
        let sub = ws.appendingPathComponent("sub").path
        let report = try await ExecTools.run(
            command: "pwd", cwd: "\(sub)/notes.txt", timeoutSeconds: 20)
        #expect(report.contains("[cwd]"), "report: \(report)")
        #expect(report.contains("is a file, not a directory"), "report: \(report)")
        #expect(report.contains(sub), "report: \(report)")
        #expect(!report.contains("Not a directory"), "report: \(report)")
        #expect(report.contains("exit code: 0"), "report: \(report)")
    }

    @Test("a cwd that does not exist is refused with the remedy in the same breath")
    func missingCwdNamesTheRemedy() async {
        do {
            _ = try await ExecTools.run(
                command: "echo x", cwd: "/no/such/dir/99999", timeoutSeconds: 10)
            #expect(Bool(false), "expected a refusal for a missing cwd")
        } catch let ToolError.invalidParameter(message) {
            #expect(message.contains("/no/such/dir/99999"), "message: \(message)")
            #expect(message.contains("not an existing directory"), "message: \(message)")
            #expect(message.contains("omit cwd"), "message: \(message)")
        } catch {
            #expect(Bool(false), "expected invalidParameter, got \(type(of: error))")
        }
    }

    @Test("a relative cwd anchors on the workspace, not on the process directory")
    func relativeCwdAnchorsOnWorkspace() async throws {
        let ws = try makeScratch()
        defer { try? FileManager.default.removeItem(at: ws) }
        SessionWorkspace.setDirectory(ws.path)
        defer { SessionWorkspace.clear() }
        let report = try await ExecTools.run(command: "pwd", cwd: "sub", timeoutSeconds: 20)
        #expect(report.contains(ws.appendingPathComponent("sub").path), "report: \(report)")
    }

    @Test("both exec lanes start in the same directory when no cwd is given")
    func lanesShareTheDefault() async throws {
        let ws = try makeScratch()
        defer { try? FileManager.default.removeItem(at: ws) }
        SessionWorkspace.setDirectory(ws.path)
        defer { SessionWorkspace.clear() }
        let blocking = try await ExecTools.run(command: "pwd", timeoutSeconds: 20)
        let session = try await ExecSessionManager().spawn(command: "pwd", yieldMs: 4000)
        #expect(blocking.contains(ws.path), "blocking: \(blocking)")
        #expect(session.report.contains(ws.path), "session.report: \(session.report)")
    }

    @Test("a directory cwd stays silent — the note is only for a repair")
    func directoryCwdStaysQuiet() async throws {
        let ws = try makeScratch()
        defer { try? FileManager.default.removeItem(at: ws) }
        let report = try await ExecTools.run(command: "pwd", cwd: ws.path, timeoutSeconds: 20)
        #expect(!report.contains("[cwd]"), "report: \(report)")
        #expect(report.contains(ws.lastPathComponent), "report: \(report)")
    }
}
