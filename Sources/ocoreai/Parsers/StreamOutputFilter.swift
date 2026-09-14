// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// `StreamOutputFilter` — the streaming counterpart of `OutputSanitizer` for
// the SSE text channels (`/v1/chat/completions?stream=true`,
// `/v1/completions?stream=true`).
//
// **The golden invariant (strict — for EVERY input, not just well-formed
// ones):**
//
// >   concat(all `content` deltas at stream end)
// >       == OutputSanitizer.strip(entireRawStream)
//
// The filter is a one-pass streaming mirror of `strip()`'s phase order
// (gemma span removal → stray marker removal → last-closer demotion →
// tool-array removal → trim), so the streaming wire cannot drift from the
// non-stream wire.
//
// **Semantics it mirrors (verified against `OutputSanitizer`):**
//
//   * Gemma spans: `open…close` — first open pairs with the FIRST close
//     after it (a second open inside the span is literal interior text,
//     exactly like `removeGemmaSpans`); an open with no close cuts the
//     tail (content = text before the open; the interior is thinking).
//     Span interiors are thinking → routed to `reasoning_content`.
//   * Stray `close` with no open: the non-stream wire just removes the
//     literal; surrounding text is unaffected. (So are stray `open`s that
//     a later close consumes as literal after span removal — the filter
//     consumes them the same way: a close only acts while a span is open.)
//   * Qwen closer: a closer that survives span removal demotes all
//     outside-span text accumulated before it to thinking (non-stream
//     keeps only the text after the LAST closer). A closer INSIDE a span
//     is removed with the span and must NOT demote (phase order!).
//
// **Routing:** everything `strip()` would drop is routed to the
// `reasoning_content` channel instead of evaporating — the wire field
// already exists upstream (coreai-models `reasoning_content` on delta and
// message) and in-tree (the `.reasoning` engine event emits it).
//
// **Why the content settles only at end-of-stream:** with the last-closer
// rule, a text region's fate is only knowable when the next closer (or
// EOS) arrives. Emitting content live would allow later demotion to
// break the invariant (already-sent bytes can't be recalled). Thinking
// text, by contrast, is provably thinking the moment it is demoted —
// so it streams live on the reasoning channel.
//
// **Cross-delta safety:** a marker may be split across engine deltas
// (detokenize batches). Up to `OutputSanitizer.maxMarkerLength - 1`
// trailing chars are never settled while the stream is open, so a marker
// completing exactly at a feed boundary is still found.
//
// **Byte-faithful:** no whitespace normalization anywhere — legitimate
// code indentation passes byte-exact (the space-compression bug class is
// forbidden here).
//
// **Thread safety:** not thread-safe by contract; drive it from the single
// SSE producer task. `@unchecked Sendable`: all state is touched
// exclusively by that one task — `feed`/`finish` are awaited sequentially
// inside a single `onText`/stream loop (no cross-task sharing).
final class StreamOutputFilter: @unchecked Sendable {

    /// Marker chars held back as unsettled tail every feed.
    private let holdBack = OutputSanitizer.maxMarkerLength - 1

    // MARK: - state (strict mirror of `OutputSanitizer.scanThoughts`)

    /// Index into `OutputSanitizer.thoughtFamilies` of the currently
    /// open span (nil = outside spans). A span closes only on its OWN
    /// family's closer — the same leftmost-open / first-own-closer
    /// pairing as the non-stream scan, across ALL families.
    private var spanFamily: Int? = nil
    private var spanInterior = ""  // settled interior text (thinking)
    private var preCloser = ""  // outside-span text since last demotion (answer candidate)
    private var reasoningAccum = ""  // settled thinking (drained on demand)
    private var pendingTail = ""  // unsettled tail (possible partial marker)
    private var finished = false

    // MARK: - API

    /// Feed the next raw delta (exactly as the engine produced it).
    /// Returns newly settled text per channel; either side may be nil.
    /// The content channel is only populated by ``finish()`` by design.
    @discardableResult
    func feed(_ text: String) -> (reasoning: String?, content: String?) {
        guard !finished, !text.isEmpty else { return (nil, nil) }

        var s = pendingTail + text
        pendingTail = ""
        while let tag = earliestTag(in: s) {
            settlePrefix(String(s[..<tag.range.lowerBound]))
            apply(tag.kind)
            s = String(s[tag.range.upperBound...])
        }
        // No more markers in this chunk: settle everything except a tail
        // that could still complete into a marker at the next boundary.
        let hold = min(holdBack, s.count)
        if hold > 0 {
            let cut = s.index(s.startIndex, offsetBy: s.count - hold)
            settlePrefix(String(s[..<cut]))
            s = String(s[cut...])
        }
        pendingTail = s

        return (drainReasoning(), nil)
    }

    /// End-of-stream settlement: returns the final per-channel text.
    /// The content channel here is byte-identical to
    /// `OutputSanitizer.strip` of the complete raw stream.
    @discardableResult
    func finish() -> (reasoning: String?, content: String?) {
        guard !finished else { return (nil, nil) }
        finished = true

        settlePrefix(pendingTail)
        pendingTail = ""

        // Span still open at EOS: non-stream cuts the tail at the open —
        // the answer is only the pre-open text; the interior is thinking.
        if spanFamily != nil {
            reasoningAccum += spanInterior
        }

        let content = cleanAnswer(preCloser)
        let reasoning = reasoningAccum
        return (
            reasoning.isEmpty ? nil : reasoning,
            content.isEmpty ? nil : content
        )
    }

    // MARK: - settlement

    /// Route a now-settled text prefix per the current scanner state.
    private func settlePrefix(_ text: String) {
        guard !text.isEmpty else { return }
        if spanFamily != nil {
            spanInterior += text
        } else {
            preCloser += text
        }
    }

    /// Apply a settled marker event. Contract (unchanged from the
    /// pre-convergence filter — `chunkingInvariance` exact values lock
    /// it): a marker that is NOT the open of a fresh span / the paired
    /// closer of the open span / the qwen demotion boundary is CONSUMED
    /// as an event — it never re-enters either channel. (`scanThoughts`
    /// keeps such literals verbatim inside thinking pieces instead;
    /// that is a reasoning-channel-only divergence, pre-existing, and
    /// the filter form is the cleaner consumer output.)
    private func apply(_ kind: TagKind) {
        switch kind {
        case .open(let i):
            if spanFamily == nil {
                spanFamily = i
                spanInterior = ""
            }
        // else: nested opener — consumed (clean reasoning stream).

        case .close(let i):
            if spanFamily == i {
                // Paired close: the interior is thinking.
                reasoningAccum += spanInterior
                spanInterior = ""
                spanFamily = nil
            } else if spanFamily == nil, i == qwenFamily {
                // `
                // ` outside any span: closer-only demotion.
                reasoningAccum += preCloser
                preCloser = ""
            }
        // Else: inside a span (other family's closer) or stray
        // non-qwen closer outside — consumed.
        }
    }

    /// Index of the `
    // ` family in `thoughtFamilies` — the sole
    /// closer-only demotion family. Computed from the table (never
    /// hardcoded): the family whose open is `thinkOpen` and whose closer
    /// is `qwenClose`.
    private var qwenFamily: Int? {
        OutputSanitizer.thoughtFamilies.firstIndex {
            $0.open == OutputSanitizer.thinkOpen && $0.closer == OutputSanitizer.qwenClose
        }
    }

    /// Final answer hygiene: identical to the non-stream exit
    /// (tool-array removal + trim, nothing else — byte-faithful).
    private func cleanAnswer(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return OutputSanitizer.removeToolCallArrays(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func drainReasoning() -> String? {
        let r = reasoningAccum
        reasoningAccum = ""
        return r.isEmpty ? nil : r
    }

    // MARK: - marker search

    private enum TagKind {
        /// `i` = index into `OutputSanitizer.thoughtFamilies`.
        case open(Int)
        case close(Int)
    }

    private struct Found {
        let range: Range<String.Index>
        let kind: TagKind
    }

    /// Earliest marker occurrence in `s` (any family, open or close).
    /// Markers come from `OutputSanitizer.thoughtFamilies` (code-point
    /// assembled) — single source of truth with `scanThoughts`.
    private func earliestTag(in s: String) -> Found? {
        var best: Found? = nil
        func consider(_ range: Range<String.Index>, _ kind: TagKind) {
            if best == nil || range.lowerBound < best!.range.lowerBound {
                best = Found(range: range, kind: kind)
            }
        }
        for (i, family) in OutputSanitizer.thoughtFamilies.enumerated() {
            if let r = s.range(of: family.open) {
                consider(r, .open(i))
            }
            for closer in [family.closer, family.altCloser] {
                guard let closer else { continue }
                if let r = s.range(of: closer) {
                    consider(r, .close(i))
                }
            }
        }
        return best
    }
}
