// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Post-write syntax verdict — the difference between "the bytes landed" and "what they say
/// is valid".
///
/// ### Why (AGENTS.md invariant 2, applied one layer down)
/// `write_file`/`edit_file` already re-read the file and byte-compare, so their `OK` means
/// *durability*, never *correctness*: a `.py` that cannot compile is reported as a success,
/// the audit trail books it as `success`, and `check_tools` therefore tells the model that
/// the failing thing it just did was fine. Measured 10-22 on the 24-task scoreboard — the
/// four tasks that flip between identical runs (`fix-syntax-error`, `fix-off-by-one`,
/// `make-failing-test-pass`, `move-into-subdir`) and four of the always-failing ones are all
/// "write something to disk and it is wrong", while write/read/exec/honesty never flip. The
/// loop had no ground truth about the artefact, only the model's own narration about it.
///
/// ### Discipline
/// Decidable types only, and nothing is executed: `py_compile` compiles, it does not import or
/// run. Types this file cannot decide return `nil` and the tool result stays exactly what it
/// was — an unavailable check is never reported as a pass, and never as a failure either.
/// The Python spawn refuses to happen without evidence of an installed toolchain, because
/// Apple's `/usr/bin/python3` shim answers a missing toolchain with a modal dialog, and a
/// syntax check must never cost the user one.
import Foundation

enum PostWriteSyntax: Sendable {

    enum Verdict: Sendable, Equatable {
        /// The artefact is valid for its type ("py_compile OK").
        case valid(String)
        /// The bytes landed but are not valid for their type — the case the model must see.
        case invalid(String)
        /// The check could not run here; says nothing about the file.
        case notChecked(String)

        var failed: Bool {
            if case .invalid = self { return true }
            return false
        }

        var headline: String {
            switch self {
            case .valid(let t), .invalid(let t), .notChecked(let t): return t
            }
        }
    }

    /// A syntax check that can outlive the turn must not be able to stall it.
    static let timeoutSeconds: Double = 5
    /// Enough of a compiler message to act on; `check_tools` truncates results anyway.
    static let maxDetailChars = 160

    /// Cached so a session spawns at most one availability probe.
    static let pythonExecutable: String? = PostWriteSyntax.locatePython()

    private static func locatePython() -> String? {
        let fm = FileManager.default
        let shimPresent = fm.isExecutableFile(atPath: "/usr/bin/python3")
        let toolchainInstalled =
            fm.fileExists(atPath: "/Library/Developer/CommandLineTools")
            || fm.fileExists(atPath: "/Applications/Xcode.app")
        var candidates: [String] = []
        // The shim only behaves when a toolchain exists; without one it raises a GUI prompt.
        if shimPresent, toolchainInstalled { candidates.append("/usr/bin/python3") }
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// `nil` = this file type is not decidable here (not "valid", not "unchecked").
    static func check(path: String, content: String) -> Verdict? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "json":
            return jsonVerdict(content)
        case "plist":
            return plistVerdict(content)
        case "py":
            return pythonVerdict(path: path)
        default:
            return nil
        }
    }

    static func jsonVerdict(_ content: String) -> Verdict {
        guard let data = content.data(using: .utf8) else {
            return .invalid("JSON not decodable as UTF-8")
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
            return .valid("JSON OK")
        } catch {
            return .invalid("JSON invalid — \(clip(error.localizedDescription))")
        }
    }

    static func plistVerdict(_ content: String) -> Verdict {
        guard let data = content.data(using: .utf8) else {
            return .invalid("property list not decodable as UTF-8")
        }
        var fmt: PropertyListSerialization.PropertyListFormat = .xml
        do {
            _ = try PropertyListSerialization.propertyList(from: data, options: [], format: &fmt)
            return .valid("property list OK (\(fmt == .xml ? "xml" : "binary"))")
        } catch {
            return .invalid("property list invalid — \(clip(error.localizedDescription))")
        }
    }

    /// `python3 -m py_compile` — compiles to bytecode, imports nothing, runs nothing.
    static func pythonVerdict(path: String) -> Verdict {
        guard let exe = pythonExecutable else {
            return .notChecked("python unavailable here — syntax not checked")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .notChecked("file not on disk — syntax not checked")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["-m", "py_compile", path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        do {
            try proc.run()
        } catch {
            return .notChecked("python could not run (\(clip(error.localizedDescription)))")
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if proc.isRunning {
            proc.terminate()
            return .notChecked("py_compile timed out after \(Int(timeoutSeconds))s — no verdict")
        }
        if proc.terminationStatus == 0 {
            return .valid("py_compile OK")
        }
        let raw = errPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: raw, encoding: .utf8) ?? ""
        let line = text.split(separator: "\n").last.map(String.init) ?? "compile error"
        return .invalid("py_compile FAILED — \(clip(line)) (line numbers are the compiler's)")
    }

    static func clip(_ s: String) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(
            in: .whitespaces)
        if oneLine.count <= maxDetailChars { return oneLine }
        return String(oneLine.prefix(maxDetailChars)) + "…"
    }

    /// Result-line suffix; empty when this type is not decidable here.
    static func suffix(_ verdict: Verdict?) -> String {
        guard let v = verdict else { return "" }
        return " | syntax: \(v.headline)"
    }
}
