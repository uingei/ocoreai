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
    static let gemmaOpen = String([lt, pipeC]) + "channel" + String([gt])
    /// gemma close: <channel|>
    static let gemmaClose = String([lt]) + "channel" + String([pipeC, gt])
    /// qwen closer tag: 3C 2F 74 68 69 6E 6B 3E — also the close of the
    /// ` think/think` span (Qwen3.5; open marker verified 3C 74 68 69 6E 6B 3E).
    static let qwenClose = String([lt, slashC]) + "think" + String([gt])
    /// ` think/think` span opener — Qwen3.5 / Qwen3 short-marker family.
    static let thinkOpen = String([lt]) + "think" + String([gt])
    /// ` thinking/thinking` — OpenAI/ChatML-style legacy family.
    static let thinkingOpen = String([lt]) + "thinking" + String([gt])
    static let thinkingClose = String([lt, slashC]) + "thinking" + String([gt])
    /// `|begin_of_thought|>…<|end_of_thought|>` / `…<|eot_id|>` — Qwen3 legacy.
    /// One opener, TWO possible closers → earliest closer wins.
    static let qwen3Open = String([lt, pipeC]) + "begin_of_thought" + String([pipeC, gt])
    /// Qwen3 legacy closer #1 (primary).
    static let qwen3End = String([lt, pipeC]) + "end_of_thought" + String([pipeC, gt])
    /// Qwen3 legacy closer #2 — some checkpoints end the thought run with
    /// `|eot_id|>` instead of the end-of-thought marker.
    static let qwen3Eot = String([lt, pipeC]) + "eot_id" + String([gt])

    /// Longest marker, in Characters. `StreamOutputFilter` holds back
    /// `maxMarkerLength - 1` chars of unsettled tail so a tag that completes
    /// exactly at a feed (detokenize-batch) boundary is still found.
    static var maxMarkerLength: Int {
        var m = max(gemmaOpen.count, gemmaClose.count, qwenClose.count)
        for f in thoughtFamilies {
            m = max(m, f.open.count, f.closer.count)
            if let alt = f.altCloser { m = max(m, alt.count) }
        }
        return m
    }

    /// Thought-span family table — the single source of truth for ALL
    /// thinking markup. `altCloser` = a second acceptable close for the
    /// same opener (earliest close wins, scan order is family order and
    /// then scan position, so a closer from one family never pairs across
    /// an unrelated opener).
    static let thoughtFamilies: [(open: String, closer: String, altCloser: String?)] = [
        (gemmaOpen, gemmaClose, nil),
        (thinkOpen, qwenClose, nil),
        (thinkingOpen, thinkingClose, nil),
        (qwen3Open, qwen3End, qwen3Eot),
    ]

    // MARK: - public API

    /// Strip everything that is not the final user-facing answer.
    /// Single pass: thought-span removal (all families) → Qwen closer-only
    /// demotion → stray closer tokens → tool-plan arrays → trim.
    static func strip(_ content: String) -> String {
        var out = stripThinking(content)
        // A tool-plan array may sit anywhere (thinking or answer region).
        out = removeToolCallArrays(out)
        // NOTE: no whitespace/indent normalization anywhere — legitimate code
        // blocks (real indentation) must pass through byte-exact.
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shared span scan — the single implementation behind `stripThinking`
    /// and `splitThoughts`. Returns surviving prose plus the thought
    /// interiors in stream order (the wire's `reasoning_content`).
    /// Pairing is leftmost-open / first-closer, exactly like the old
    /// `removeGemmaSpans` (first open pairs with the FIRST close after it;
    /// a second open inside the span is literal interior text). An open
    /// with no close after it cuts the tail — a stream cut mid-thought:
    /// the interior is unfinished reasoning, not answer prose.
    private static func scanThoughts(
        _ input: String
    ) -> (prose: String, thinkingPieces: [String]) {
        var prose = input
        var pieces: [String] = []
        for family in thoughtFamilies {
            var guardCt = 0
            while prose.contains(family.open), guardCt < 128 {
                guardCt += 1
                let openRange = prose.range(of: family.open)!
                let tail = prose[openRange.upperBound...]
                // Earliest of the family's closers in the tail wins
                // (Qwen3 legacy has TWO acceptable closers).
                var closeEnd: String.Index?
                for closer in [family.closer, family.altCloser] {
                    guard let closer else { continue }
                    guard let r = tail.range(of: closer) else { continue }
                    if closeEnd == nil || r.upperBound < closeEnd! {
                        closeEnd = r.upperBound
                    }
                }
                if let closeEnd {
                    pieces.append(String(tail[..<closeEnd]))
                    prose = String(prose[..<openRange.lowerBound] + tail[closeEnd...])
                } else {
                    // Incomplete thought (open, no close): drop opener + tail.
                    prose = String(prose[..<openRange.lowerBound])
                    break
                }
            }
        }
        // Closer-only demotion (Qwen E2E shape: reasoning delimited by the
        // closer alone). Runs AFTER span removal so a closer inside a span
        // was already consumed with its interior.
        if let i = prose.range(of: qwenClose, options: [.backwards]) {
            let before = String(prose[..<i.lowerBound])
            prose = String(prose[i.upperBound...])
            if !before.isEmpty { pieces.append(before) }
        }
        return (prose, pieces)
    }

    /// Remove all thinking markup across every family and return the
    /// surviving prose (no tool-array removal, no trim — compose as needed).
    static func stripThinking(_ input: String) -> String {
        let (prose, _) = scanThoughts(input)
        return stripStrayClosers(prose)
    }

    /// (thinking, prose) — the `reasoning_content` split for handlers and
    /// the UI fallback path. Thinking pieces are whitespace-trimmed;
    /// empty interior pieces are dropped.
    static func splitThoughts(_ input: String) -> (thinking: String?, prose: String) {
        let (prose, pieces) = scanThoughts(input)
        var thinkingPieces = pieces.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        thinkingPieces.removeAll { $0.isEmpty }
        return (
            thinkingPieces.isEmpty ? nil : thinkingPieces.joined(separator: "\n"),
            stripStrayClosers(prose)
        )
    }

    /// Stray CLOSE tokens that survived span removal — they are literal
    /// marker garbage (a model echoing its own delimiter), not prose.
    /// Openers can never survive: the span phase pairs or cuts at every
    /// one. Qwen's closer tag is excluded — the closer-only rule already
    /// consumed the last one, and an earlier one is the demotion boundary.
    private static func stripStrayClosers(_ input: String) -> String {
        var out = input
        for marker in [gemmaClose, thinkingClose, qwen3End, qwen3Eot] {
            out = out.replacingOccurrences(of: marker, with: "")
        }
        return out
    }

    // MARK: - tool-call array removal

    /// Exposed for `StreamOutputFilter` so the answer region gets the
    /// identical array-removal on the streaming wire (single implementation).
    static func removeToolCallArrays(_ input: String) -> String {
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
