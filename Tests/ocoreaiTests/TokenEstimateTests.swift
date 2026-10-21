// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! TokenEstimateTests.swift — one rule answers "roughly how many tokens is this text?", and
//! the scan that enforces it proves it can still see the rule.
//!
//! ### What this replaces (measured 10-21)
//! 17 sites in 9 files answered the same question with three formulas: the CJK-aware byte rule
//! copy-pasted five times (`ChatHandler`, `AnthropicMessagesHandler`, `CompletionsHandler`,
//! `EngineInference`, `ConversationCompaction`), "length / 4" eleven times (`utf8.count / 4` in
//! `SchedulerActor` — which decides whether a request is admitted — plus ten character-count
//! sites across the perception budget), and `utf16/3` once, in the GUI's `ChatState` (the
//! composer's context meter). That last copy described itself as CJK-aware while counting one
//! unit per CJK character: "你好世界" read as **1** token on that meter where this rule says
//! **4**.

import Foundation
import Testing

@testable import ocoreai

@Suite("TokenEstimate — exact values for the one rule")
struct TokenEstimateValueTests {

    @Test("Latin content divides bytes by 4")
    static func latinContent() {
        #expect(TokenEstimate.contentTokens("hello") == 1)
        #expect(TokenEstimate.contentTokens("hello world") == 2)
        #expect(TokenEstimate.contentTokens(String(repeating: "0", count: 40)) == 10)
    }

    @Test("CJK content divides bytes by 3 — one char is roughly one token")
    static func cjkContent() {
        #expect(TokenEstimate.contentTokens("你好") == 2)
        #expect(TokenEstimate.contentTokens("中文测试") == 4)
        #expect(TokenEstimate.contentTokens("你好世界") == 4)
        // Mixed body: the average decides, so the CJK bytes are not charged at the Latin rate.
        #expect(TokenEstimate.contentTokens("ab中文") == 2)
    }

    @Test("content sizes floor at zero; prompt sizes floor at one")
    static func floorsDifferOnPurpose() {
        #expect(TokenEstimate.contentTokens("") == 0)
        #expect(TokenEstimate.contentTokens("S") == 0)
        #expect(TokenEstimate.promptTokens("") == 0)
        #expect(TokenEstimate.promptTokens("S") == 1)
        #expect(TokenEstimate.promptTokens("hi") == 1)
    }

    @Test("a transcript is judged as one prompt, ratio across the whole body")
    static func transcriptIsOnePrompt() {
        #expect(
            TokenEstimate.promptTokens([Message(role: "user", content: .text("hi"))]) == 1)
        #expect(
            TokenEstimate.promptTokens([Message(role: "user", content: .text("你好"))]) == 2)
        // No content at all is 0, which is the caller's signal to reject the request.
        #expect(TokenEstimate.promptTokens([Message(role: "user", content: nil)]) == 0)
        // 2 B + 6 B over 4 chars → avg 2.0 → CJK divisor → Int(8/3) = 2.
        #expect(
            TokenEstimate.promptTokens([
                Message(role: "system", content: .text("hi")),
                Message(role: "user", content: .text("你好")),
            ]) == 2)
    }

    @Test("a multi-completion body is judged as one prompt")
    static func multiCompletionBody() {
        #expect(TokenEstimate.promptTokens(["hello", "world"]) == 2)
        #expect(TokenEstimate.promptTokens([String]()) == 0)
    }

    /// The values the GUI meter used to answer, restated at the one rule. `utf16/3` counted one
    /// unit per CJK character, so Chinese text was read at about a quarter of its real cost —
    /// the meter that tells a user how full the context window is.
    @Test("the GUI's CJK reading is corrected, not preserved")
    static func cjkReadingCorrected() {
        #expect(TokenEstimate.promptTokens("你好世界") == 4)  // utf16/3 used to say 1
        #expect(TokenEstimate.promptTokens("hello") == 1)  // unchanged for Latin
        #expect(TokenEstimate.promptTokens(String(repeating: "0", count: 40)) == 10)  // was 13
    }
}

@Suite("TokenEstimate — the rule has one home")
struct TokenEstimateSingleHomeTests {

    private static let home = "Sources/ocoreai/Models/TokenEstimate.swift"

    /// Comment-aware code lines (prose may name a forbidden shape in order to forbid it).
    private static func codeLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter {
            line in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            return !(trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*"))
        }
    }

    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        while dir.path != "/" {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Sources/ocoreai").path),
                FileManager.default.fileExists(atPath: dir.appendingPathComponent("Tests").path)
            {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw Missing(what: "repo root (Sources/ocoreai + Tests)")
    }

    private static func allSwiftSources() throws -> [(path: String, code: [String])] {
        let root = try repoRoot()
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: root.appendingPathComponent("Sources"),
                includingPropertiesForKeys: nil)
        else { throw Missing(what: "Sources/ enumerator") }
        var out: [(String, [String])] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            out.append((String(url.path.dropFirst(root.path.count + 1)), codeLines(text)))
        }
        return out
    }

    /// The three formulas this file replaces, as regexes. Regex rather than substring because
    /// the copies spelled the quantity in locals — `utf16Count / 3` is what the GUI meter
    /// actually did, and a literal "utf16.count / 3" scan walks straight past it.
    private static let formulas: [(name: String, pattern: String, offender: String)] = [
        ("CJK divisor", #"1\.5\s*\?\s*3\s*:\s*4"#, "let divisor = avgBytesPerChar > 1.5 ? 3 : 4"),
        ("utf16 over 3", #"utf16\w*\s*/\s*3"#, "return max(1, utf16Count / 3)"),
        ("count over 3 or 4", #"(?:utf8\.)?count\s*/\s*[34]\b"#, "return max(10, ocr.count / 4)"),
        (
            "byte length over 3 or 4", #"(?:bytes|byteCount|length|len)\s*/\s*[34]\b"#,
            "return max(1, bytes / 3)"
        ),
    ]

    /// A zero-tolerance scan has to prove it still matches something, or a broken pattern looks
    /// exactly like a clean tree (invariant 1). Each pattern is first run against a synthetic
    /// offender line that must hit, then against the tree, where only the home may contain it.
    @Test("no file except the home divides text length into a token estimate")
    static func noSecondFormula() throws {
        let files = try allSwiftSources()
        #expect(
            files.count >= 150, "only \(files.count) Swift sources scanned — the walk is broken")

        for formula in formulas {
            let regex = try NSRegularExpression(pattern: formula.pattern)
            let range = NSRange(
                formula.offender.startIndex ..< formula.offender.endIndex,
                in: formula.offender)
            #expect(
                regex.firstMatch(in: formula.offender, range: range) != nil,
                "the instrument cannot even see the shape it forbids — \(formula.name)")

            // Paths, not contents: Swift Testing prints the operands of a failed expectation,
            // and a gate that dumps whole files into CI gets muted — which is worse than no
            // gate. The message names the formula and the offending files, and nothing else.
            let offenders: [String] = files.compactMap { path, lines in
                guard path != home else { return nil }
                return lines.contains { line in
                    regex.firstMatch(
                        in: line, range: NSRange(line.startIndex ..< line.endIndex, in: line))
                        != nil
                } ? path : nil
            }
            #expect(offenders.isEmpty, "\(formula.name) is back outside the home — \(offenders)")
        }

        // The discriminator lives in exactly one place, and the callers still number in the
        // dozens: a scan that quietly lost the home would look identical to a clean tree.
        let cjk = try NSRegularExpression(pattern: formulas[0].pattern)
        let homeLines = files.first { $0.path == home }!.code
        let homeHits = homeLines.reduce(0) { total, line in
            total
                + (cjk.firstMatch(
                    in: line,
                    range: NSRange(line.startIndex ..< line.endIndex, in: line)) != nil ? 1 : 0)
        }
        #expect(
            homeHits == 1,
            "the divisor rule must appear exactly once, in the home (got \(homeHits))")
        let callers = files.filter { $0.code.contains { $0.contains("TokenEstimate.") } }
        #expect(
            callers.count >= 8,
            "expected the rewired circuits to call the home, found \(callers.count): \(callers.map(\.path))"
        )
    }

    private struct Missing: Error, CustomStringConvertible {
        let what: String
        var description: String { "could not find \(what) walking up from \(#filePath)" }
    }
}
