// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Post-write validity reporting — the tool result must say whether the artefact is valid,
/// not merely that bytes landed.
///
/// `write_file`/`edit_file` verified durability (atomic write + read-back byte compare) and
/// reported `OK` for a `.py` that cannot compile, so the model and `check_tools` were both
/// told the failing thing was fine. These tests pin the new half of that sentence: decidable
/// types carry a verdict, undecidable types carry nothing, and "could not check" never
/// collapses into either verdict.
import Foundation
import Testing

@testable import ocoreai

@Suite("Post-write syntax verdicts — validity is a separate claim from durability")
struct PostWriteSyntaxTests {

    private func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "ocoreai-postwrite-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("json is decided in-process, both ways")
    func jsonVerdicts() {
        let ok = PostWriteSyntax.check(path: "/tmp/x.json", content: #"{"a": 1}"#)
        #expect(ok == .valid("JSON OK"))
        let bad = PostWriteSyntax.check(path: "/tmp/x.json", content: #"{"a": }"#)
        #expect(bad?.failed == true)
        #expect(bad?.headline.contains("JSON invalid") == true)
        // An empty .json is invalid, not "unchecked".
        #expect(PostWriteSyntax.check(path: "/tmp/x.json", content: "")?.failed == true)
    }

    @Test("property list is decided in-process")
    func plistVerdict() {
        let ok = PostWriteSyntax.check(
            path: "/tmp/x.plist",
            content: "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>a</key>"
                + "<string>b</string></dict></plist>")
        #expect(ok?.failed == false)
        #expect(
            PostWriteSyntax.check(path: "/tmp/x.plist", content: "<plist><dict>")?.failed == true)
    }

    @Test("undecidable types stay silent — nil is not a pass")
    func undecidedTypesReturnNil() {
        for p in ["notes.md", "a.txt", "main.swift", "app.toml", "cfg.yaml", "noext"] {
            #expect(
                PostWriteSyntax.check(path: p, content: "anything") == nil,
                "silent expected for \(p)")
        }
        #expect(PostWriteSyntax.suffix(nil) == "")
    }

    @Test("a check that could not run says so and never claims a verdict")
    func notCheckedIsNeverAFailure() {
        let v = PostWriteSyntax.Verdict.notChecked("python unavailable here — syntax not checked")
        #expect(v.failed == false)
        #expect(
            PostWriteSyntax.suffix(v) == " | syntax: python unavailable here — syntax not checked")
    }

    @Test(
        "detail is clipped to the audit window so the verdict cannot be truncated away",
        arguments: [0, 50, 160, 4096])
    func clipping(width: Int) {
        let detail = String(repeating: "e", count: width)
        let joined = ("line one " + detail).trimmingCharacters(in: .whitespaces)
        // clip() also trims, so the expectation trims the same way (width 0 → "line one")
        let clipped = PostWriteSyntax.clip("line one\n" + detail)
        #expect(!clipped.contains("\n"))
        if joined.count > PostWriteSyntax.maxDetailChars {
            #expect(clipped.count == PostWriteSyntax.maxDetailChars + 1)  // + the ellipsis
            #expect(clipped.hasSuffix("…"))
        } else {
            #expect(clipped == joined)
        }
    }

    @Test(
        "a broken .py comes back as OK-but-invalid with the compiler's own words",
        .enabled(if: PostWriteSyntax.pythonExecutable != nil))
    func pythonWriteIsReportedInvalid() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let broken = dir + "/broken.py"
        let line = try FileTools.write(path: broken, content: "def f(:\n    pass\n")
        #expect(line.contains("write_file: OK-but-invalid"))
        #expect(line.contains("syntax: py_compile FAILED"))
        // Durability facts must survive alongside the verdict — the write did happen.
        #expect(line.contains("read-back verified"))

        let fixed = dir + "/fixed.py"
        let okLine = try FileTools.write(path: fixed, content: "def f():\n    return 1\n")
        #expect(okLine.contains("write_file: OK —"))
        #expect(okLine.contains("syntax: py_compile OK"))
        // Premise of the failure case above: the verdict must be about this file. A wrong
        // argv ("py_compile -q …") makes every .py write fail with FileNotFoundError, which
        // would have satisfied the broken-file assertion vacuously.
        #expect(!okLine.contains("FileNotFoundError"))
        #expect(!line.contains("FileNotFoundError"))
    }

    @Test(
        "edit_file reports the verdict too, not just the byte delta",
        .enabled(if: PostWriteSyntax.pythonExecutable != nil))
    func pythonEditIsReportedInvalid() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let good = dir + "/calc.py"
        _ = try FileTools.write(path: good, content: "def add(a, b):\n    return a + b\n")
        let broken = try FileTools.editFile(
            path: good, oldString: "return a + b", newString: "return a +")
        #expect(broken.contains("edit_file: OK-but-invalid"))
        #expect(broken.contains("syntax: py_compile FAILED"))
        #expect(broken.contains("replacement(s)"))
    }
}
