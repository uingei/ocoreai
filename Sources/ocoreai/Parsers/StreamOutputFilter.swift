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

    // MARK: - state (strict mirror of strip()'s phase order)

    private var spanOpen = false  // between a gemma open and its paired close
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

        // Span still open at EOS: non-stream cuts the tail — the answer
        // is only the pre-open text; the interior is thinking.
        if spanOpen {
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
        if spanOpen {
            spanInterior += text
        } else {
            preCloser += text
        }
    }

    /// Apply a settled marker event — the exact phase-order semantics.
    private func apply(_ kind: TagKind) {
        switch kind {
        case .gemmaOpen:
            if !spanOpen {
                // A new span begins. (A second open inside a span is
                // literal interior text — `removeGemmaSpans` pairs the
                // FIRST open with the FIRST following close, so this one
                // is dropped with the outer span's interior. Do nothing.)
                spanOpen = true
                spanInterior = ""
            }

        case .gemmaClose:
            if spanOpen {
                // Paired close: the interior is thinking.
                reasoningAccum += spanInterior
                spanInterior = ""
                spanOpen = false
            }
        // Else: stray close — the non-stream wire removes the literal
        // and leaves the surrounding text (answer candidate) intact.

        case .qwenClose:
            if !spanOpen {
                // A closer that survives span removal demotes the current
                // answer candidate: non-stream keeps only the text after
                // the LAST such closer, so everything before it was
                // thinking.
                reasoningAccum += preCloser
                preCloser = ""
            }
        // Else: the closer is inside a span — removed with the span
        // interior (strip's span phase runs first), no demotion.
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
        case gemmaOpen
        case gemmaClose
        case qwenClose
    }

    private struct Found {
        let range: Range<String.Index>
        let kind: TagKind
    }

    /// Earliest marker occurrence in `s` (any kind). Markers come from
    /// `OutputSanitizer` (code-point assembled) — single source of truth.
    private func earliestTag(in s: String) -> Found? {
        let candidates: [(String, TagKind)] = [
            (OutputSanitizer.gemmaOpen, .gemmaOpen),
            (OutputSanitizer.gemmaClose, .gemmaClose),
            (OutputSanitizer.qwenClose, .qwenClose),
        ]
        var best: Found? = nil
        for (tag, kind) in candidates {
            guard let r = s.range(of: tag) else { continue }
            if best == nil || r.lowerBound < best!.range.lowerBound {
                best = Found(range: r, kind: kind)
            }
        }
        return best
    }
}
