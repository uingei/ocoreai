import Foundation

/// Single choke point between engine output and the OpenAI-compatible wire.
///
/// Non-stream final `message.content` only (the agent E2E wire mode is
/// non-stream). Every marker below was verified by hex-dumping the decoded
/// 2026-09-09 E2E fixtures (gemma-4 2B, Qwen3.5 4B) — not by visual reading:
///
///   * Both models emit a fake top-level `[{ "name", "arguments" }]`
///     tool-plan array as prose (a tool call "planned" in text instead of via
///     the structured channel).
///   * gemma thinking spans: open 3C 7C "channel" 3E  (pipe 0x7C)
///                           close 3C "channel" 7C 3E (pipe 0x7C)
///   * Qwen thinking is delimited by a closer 3C 2F "think" 3E (FORWARD SLASH
///     0x2F — not a backslash); the user-facing answer is the content AFTER
///     the last such closer (captured fixtures carry no opener).
///
/// Real newlines and all legitimate prose are preserved verbatim.
///
/// TRANSPORT SAFETY: every marker is assembled from UnicodeScalar code
/// points plus plain words, so this source has no escape-prone literals. Do
/// not rewrite marker construction back into plain string literals.
enum OutputSanitizer {
    // MARK: - code points
    private static let lt = Character(UnicodeScalar(0x3C))  // <
    private static let gt = Character(UnicodeScalar(0x3E))  // >
    private static let pipeC = Character(UnicodeScalar(0x7C))  // |
    private static let slashC = Character(UnicodeScalar(0x2F))  // /
    private static let backslC = Character(UnicodeScalar(0x5C))
    private static let quoteC = Character(UnicodeScalar(0x22))

    // MARK: - thinking markers (code-point assembled)
    /// gemma open:  <|channel>
    private static let gemmaOpen = String([lt, pipeC]) + "channel" + String([gt])
    /// gemma close: <channel|>
    private static let gemmaClose = String([lt]) + "channel" + String([pipeC, gt])
    /// qwen closer tag: 3C 2F 74 68 69 6E 6B 3E
    private static let qwenClose = String([lt, slashC]) + "think" + String([gt])

    // MARK: - public API

    /// Strip everything that is not the final user-facing answer.
    static func strip(_ content: String) -> String {
        var out = content

        // gemma: remove balanced <open>…<close> spans; a trailing unbalanced
        // open (stream cut mid-thought) → opener and everything after is
        // dropped. Then any leftover stray marker token → "".
        out = removeGemmaSpans(out)
        out = out.replacingOccurrences(of: gemmaClose, with: "")
        out = out.replacingOccurrences(of: gemmaOpen, with: "")

        // qwen: keep only the text after the LAST closer tag.
        if let i = out.range(of: qwenClose, options: [.backwards]) {
            out = String(out[i.upperBound...])
        }

        // A tool-plan array may sit anywhere (thinking or answer region).
        out = removeToolCallArrays(out)
        // NOTE: no whitespace/indent normalization anywhere — legitimate code
        // blocks (real indentation) must pass through byte-exact.
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove every `<gemmaOpen> … <gemmaClose>` span. A `<gemmaOpen>` with
    /// no `<gemmaClose>` after it: the opener and everything after are cut.
    private static func removeGemmaSpans(_ input: String) -> String {
        var out = input
        while let openRange = out.range(of: gemmaOpen) {
            let tail = out[openRange.upperBound...]
            if let closeRange = tail.range(of: gemmaClose) {
                out = String(out[..<openRange.lowerBound] + tail[closeRange.upperBound...])
            } else {
                out = String(out[..<openRange.lowerBound])
                break
            }
        }
        return out
    }

    // MARK: - tool-call array removal

    private static func removeToolCallArrays(_ input: String) -> String {
        // Single forward scan: collect ranges of tool-plan arrays, then
        // splice them out in reverse (keeps earlier indices valid).
        var ranges: [Range<String.Index>] = []
        var offset = 0
        var guardCt = 0
        while offset < input.count, guardCt < 128 {
            guard let a = firstTopLevelArray(in: input, from: offset) else { break }
            guardCt += 1
            if isToolCallArray(String(input[a.start ..< a.end])) {
                ranges.append(a.start ..< a.end)
            }
            offset = a.endOffset
        }
        var out = input
        for r in ranges.reversed() {
            out.removeSubrange(r)
        }
        return out
    }

    /// Locate the first top-level `[ … ]` region starting at/after `offset`
    /// (string/escape aware). Indices in `String.Index` space.
    private static func firstTopLevelArray(
        in s: String, from offset: Int
    ) -> (start: String.Index, end: String.Index, endOffset: Int)? {
        let chars = Array(s)
        guard offset < chars.count else { return nil }
        var i = offset
        while i < chars.count, chars[i] != "[" { i += 1 }
        guard i < chars.count else { return nil }
        let start = i
        var depth = 0
        var inString = false
        var escaped = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == backslC {
                    escaped = true
                } else if c == quoteC {
                    inString = false
                }
            } else {
                switch c {
                case quoteC: inString = true
                case "[": depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 {
                        let startIdx = s.index(s.startIndex, offsetBy: start)
                        let endIdx = s.index(s.startIndex, offsetBy: i + 1)
                        return (start: startIdx, end: endIdx, endOffset: i + 1)
                    }
                default: break
                }
            }
            i += 1
        }
        return nil
    }

    /// A tool-plan array: JSON array of objects where at least one carries a
    /// `name` entry. Legitimate JSON arrays / Swift literals without `name`
    /// are left untouched.
    private static func isToolCallArray(_ slice: String) -> Bool {
        guard let data = slice.data(using: .utf8),
            let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return false }
        guard !arr.isEmpty else { return false }
        return arr.contains { $0["name"] != nil }
    }

    // MARK: - hygiene (no-op by design: legitimate whitespace passes through)
}
