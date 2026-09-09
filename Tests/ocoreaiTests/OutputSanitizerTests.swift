// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// `OutputSanitizer` (non-stream wire hygiene) — exact-value assertions on the
// REAL 2026-09-09 E2E artifact shapes, hex-verified (gemma-4 2B, Qwen3.5 4B):
//   - tool-call JSON arrays emitted as prose (both models)
//   - gemma thinking spans: open 3C 7C "channel" 3E / close 3C "channel" 7C 3E (PIPE 0x7C)
//   - Qwen thinking closer: 3C 2F "think" 3E (FORWARD SLASH 0x2F, NOT a backslash)
//   - real newlines and legitimate prose are ALWAYS preserved
//
// Markers below are assembled from UnicodeScalar code points so this file has
// no escape-prone literals (transport-safe). Assertion style: exact values.

import Foundation
import Testing

@testable import ocoreai

@Suite("OutputSanitizer — non-stream wire hygiene")
struct OutputSanitizerTests {
    // MARK: transport-safe marker constants (code-point assembled)
    private static let lt = Character(UnicodeScalar(0x3C))  // <
    private static let gt = Character(UnicodeScalar(0x3E))  // >
    private static let pip = Character(UnicodeScalar(0x7C))  // |
    private static let sla = Character(UnicodeScalar(0x2F))  // /

    /// gemma open:  3C 7C "channel" 3E
    private static let open = String([lt, pip]) + "channel" + String([gt])
    /// gemma close: <channel|>
    private static let close = String([lt]) + "channel" + String([pip, gt])
    /// qwen closer: 3C 2F "think" 3E
    private static let qclose = String([lt, sla]) + "think" + String([gt])

    // MARK: - Tool-call array as prose

    @Test("tool-call JSON array removed; surrounding prose preserved (exact)")
    func toolArrayRemovedProseKept() {
        let input =
            "[{\"name\":\"exec_command\",\"arguments\":{\"command\":\"swift test\"}}]The fix is applied."
        #expect(OutputSanitizer.strip(input) == "The fix is applied.")
    }

    @Test("multi-entry tool array removed entirely; adjacent prose kept (exact)")
    func multiEntryToolArrayRemoved() {
        let input =
            "Prose before.\n" + "[\n"
            + "  {\"name\": \"search_files\", \"arguments\": {\"pattern\": \"MathUtils\"}},\n"
            + "  {\"name\": \"edit_file\", \"arguments\": {\"path\": \"a.swift\"}}\n" + "]\n"
            + "Prose after."
        let out = OutputSanitizer.strip(input)
        // Multi-line array: after removal the adjacent real newlines remain,
        // giving one legitimate blank-line separator.
        #expect(out == "Prose before.\n\nProse after.")
    }

    @Test("a ']' inside a JSON string value cannot desync the bracket walk (exact)")
    func stringAwareBracketWalk() {
        let input =
            "Before\n"
            + "[{\"name\":\"exec_command\",\"arguments\":{\"command\":\"echo 'a]b' && printf '['\"}}]\n"
            + "After"
        let out = OutputSanitizer.strip(input)
        // The array sat on its own line: after removal the two surrounding
        // real newlines remain (legitimate line break, not swallowed).
        #expect(out == "Before\n\nAfter")
    }

    // MARK: - Non-tool prose arrays are NEVER cut

    @Test("prose JSON array (no 'name') is preserved (exact)")
    func proseArrayPreserved() {
        let input = "Options: [\"a\", \"b\"] remain."
        #expect(OutputSanitizer.strip(input) == input)
    }

    @Test("a single '[' in prose is preserved (exact)")
    func bareBracketPreserved() {
        let input = "See step [1] for details."
        #expect(OutputSanitizer.strip(input) == input)
    }

    @Test("a Swift-literal '[Double]' in a function signature is preserved (exact)")
    func swiftArrayLiteralPreserved() {
        let input =
            "public func median(_ a: [Double]) -> Double {\n    return 0\n}\nThat is valid Swift."
        #expect(
            OutputSanitizer.strip(input) == input.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - gemma pipe thinking spans (open 3C 7C … 3E / close 3C … 7C 3E)

    @Test("gemma span removed; answer kept (exact)")
    func gemmaSpanRemoved() {
        let input = Self.open + "Let me think hard about this." + Self.close + "Done."
        #expect(OutputSanitizer.strip(input) == "Done.")
    }

    @Test("two consecutive gemma spans are both removed (exact)")
    func gemmaTwoSpansRemoved() {
        let input =
            Self.open + "First plan." + Self.close + Self.open + "Second plan." + Self.close
            + "Result."
        #expect(OutputSanitizer.strip(input) == "Result.")
    }

    @Test("unbalanced gemma open (no close) is cut to end; prose before kept (exact)")
    func gemmaUnbalancedOpen() {
        let input = "Answer:" + Self.open + " trailing plan"
        let out = OutputSanitizer.strip(input)
        #expect(out == "Answer:")
    }

    @Test("stray gemma close without an open is removed (exact)")
    func gemmaStrayClose() {
        let input = "Answer " + Self.close + " continues"
        #expect(OutputSanitizer.strip(input) == "Answer  continues")
    }

    // MARK: - Qwen closer tag (3C 2F "think" 3E) → keep text after the LAST one

    @Test("qwen: keep text after the LAST closer; thinking chunks removed (exact)")
    func qwenAfterLastCloser() {
        let input = "think1" + Self.qclose + "think2" + Self.qclose + "## Final answer."
        #expect(OutputSanitizer.strip(input) == "## Final answer.")
    }

    @Test("qwen: single closer splits reasoning from the answer (exact)")
    func qwenSingleCloser() {
        let input = "reasoning" + Self.qclose + "Answer text."
        #expect(OutputSanitizer.strip(input) == "Answer text.")
    }

    @Test("qwen: no closer tag → content preserved verbatim (exact)")
    func qwenNoCloserPreserved() {
        let input = "Plain reasoning with no marker."
        #expect(OutputSanitizer.strip(input) == input)
    }

    // MARK: - Composition (real E2E shape: array + span + answer)

    @Test("real E2E shape: tool array + gemma span + answer (exact)")
    func composedGemma() {
        let input =
            "[{\"name\":\"exec_command\",\"arguments\":{\"command\":\"swift test\"}}]" + Self.open
            + "The user is asking me to find a bug. I will read first." + Self.close
            + "Fixed the even-length median bug."
        #expect(OutputSanitizer.strip(input) == "Fixed the even-length median bug.")
    }

    // MARK: - Idempotence + clean-prose pass-through

    @Test("strip is idempotent (exact equality on double application)")
    func idempotent() {
        let input =
            "[{\"name\":\"x\",\"arguments\":{}}]" + Self.open + " t " + Self.close + "keep"
        let once = OutputSanitizer.strip(input)
        #expect(once == "keep")
        #expect(OutputSanitizer.strip(once) == once)
    }

    @Test("clean prose with a code block and real newlines is unchanged (exact)")
    func cleanProseUntouched() {
        let input =
            "public func median(_ a: [Double]) -> Double {\n" + "    return 0\n" + "}\n" + "\n"
            + "That is valid Swift with real newlines."
        #expect(
            OutputSanitizer.strip(input)
                == input.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
