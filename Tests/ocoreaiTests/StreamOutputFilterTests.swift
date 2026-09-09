// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// `StreamOutputFilter` (streaming wire hygiene) — the streaming counterpart
// of `OutputSanitizer`. Exact-value assertions; markers assembled from
// UnicodeScalar code points (transport-safe, no bare sequences).
//
// The golden invariant under test (STRICT — every corpus line, any chunking):
//   concat(content channel) == OutputSanitizer.strip(fullRawText)
//   thinking text routed to the reasoning channel, never to content.

import Foundation
import Testing

@testable import ocoreai

// MARK: transport-safe markers (code-point assembled, same bytes as
// OutputSanitizer — cross-verified in markerParity below).
let lt = Character(UnicodeScalar(0x3C))  // <
let gt = Character(UnicodeScalar(0x3E))  // >
let pip = Character(UnicodeScalar(0x7C))  // |
let sla = Character(UnicodeScalar(0x2F))  // /
let tagOpen = String([lt, pip]) + "channel" + String([gt])
let tagClose = String([lt]) + "channel" + String([pip, gt])
let tagQClose = String([lt, sla]) + "think" + String([gt])
@Suite("StreamOutputFilter — streaming wire hygiene")
struct StreamOutputFilterTests {
    /// Run the filter over one feed() call; returns what feed + finish
    /// report.
    private static func runOne(_ raw: String) -> (
        feedReasoning: String?, fin: (reasoning: String?, content: String?)
    ) {
        let f = StreamOutputFilter()
        let r = f.feed(raw)
        return (r.reasoning, f.finish())
    }

    // MARK: - marker byte-equality with the sanitizer (single source of truth)

    @Test("filter markers are byte-identical to OutputSanitizer markers")
    func markerParity() {
        #expect(tagOpen == OutputSanitizer.gemmaOpen)
        #expect(tagClose == OutputSanitizer.gemmaClose)
        #expect(tagQClose == OutputSanitizer.qwenClose)
    }

    // MARK: - Qwen (closer-only protocol; answer = text after LAST closer)

    @Test("qwen: single closer — tail = content, head = reasoning (exact)")
    func qwenSingleCloser() {
        let raw = "thinking bytes here" + tagQClose + "  the final answer  "
        let (feedReasoning, fin) = Self.runOne(raw)
        #expect(fin.content == "the final answer")
        // Thinking drains at demotion time (the closer), before finish.
        #expect(feedReasoning == "thinking bytes here")
        #expect(fin.reasoning == nil)
    }

    @Test("qwen: 6 closers (real fixture shape) — only last region survives (exact)")
    func qwenMultiCloser() {
        var raw = "T0"
        for i in 1 ... 5 {
            raw += tagQClose + "T\(i)"
        }
        let (feedReasoning, fin) = Self.runOne(raw)
        #expect(fin.content == "T5")
        #expect(feedReasoning == "T0T1T2T3T4")
        #expect(fin.reasoning == nil)
        #expect(fin.content == OutputSanitizer.strip(raw))
    }

    @Test("qwen: no closer at all — clean answer kept whole (exact)")
    func qwenNoCloser() {
        let raw = "  pure clean prose with code: [Double]()  \n"
        let (_, fin) = Self.runOne(raw)
        #expect(fin.content == "pure clean prose with code: [Double]()")
        #expect(fin.reasoning == nil)
        #expect(fin.content == OutputSanitizer.strip(raw))
    }

    @Test("qwen: closer at stream start — empty reasoning, full answer (exact)")
    func qwenCloserAtStart() {
        let raw = tagQClose + "ANSWER"
        let (feedReasoning, fin) = Self.runOne(raw)
        #expect(fin.content == "ANSWER")
        #expect(feedReasoning == nil)
        #expect(fin.reasoning == nil)
    }

    @Test("qwen: tool array inside the ANSWER region is removed (exact)")
    func qwenToolArrayInAnswer() {
        let arr = "[{\"name\":\"exec_command\",\"arguments\":{\"command\":\"swift test\"}}]"
        let raw = "T0" + tagQClose + "ok " + arr + " done"
        let (feedReasoning, fin) = Self.runOne(raw)
        #expect(fin.content == "ok  done")
        #expect(feedReasoning == "T0")
        #expect(fin.reasoning == nil)
        #expect(fin.content == OutputSanitizer.strip(raw))
    }

    @Test("legitimate code indentation passes byte-exact (no compression)")
    func whitespaceFidelity() {
        let code = "let a = [1, 2]\n        let nested = 8\n        let deep = 9"
        let raw = "think" + tagQClose + code
        let (_, fin) = Self.runOne(raw)
        #expect(fin.content == code)
    }

    // MARK: - Gemma (paired spans: open…close = thinking region)

    @Test("gemma: balanced span → interior to reasoning, outside to content (exact)")
    func gemmaBalancedSpan() {
        let raw = "Pre" + tagOpen + "span thinking" + tagClose + "After"
        let (feedReasoning, fin) = Self.runOne(raw)
        #expect(fin.content == "PreAfter")
        #expect(feedReasoning == "span thinking")
        #expect(fin.reasoning == nil)
        #expect(fin.content == OutputSanitizer.strip(raw))
    }

    @Test("gemma: TWO balanced spans both demoted; outer text survives (exact)")
    func gemmaTwoSpans() {
        let raw = "A" + tagOpen + "th1" + tagClose + "B" + tagOpen + "th2" + tagClose + "C"
        let (feedReasoning, fin) = Self.runOne(raw)
        #expect(fin.content == "ABC")
        #expect(feedReasoning == "th1th2")
        #expect(fin.reasoning == nil)
        #expect(fin.content == OutputSanitizer.strip(raw))
    }

    @Test("gemma: unbalanced trailing tagOpen → tail cut, interior still reasoning (exact)")
    func gemmaUnbalancedOpen() {
        let raw = "Pre" + tagOpen + "never closed"
        let (feedReasoning, fin) = Self.runOne(raw)
        #expect(fin.content == "Pre")
        #expect(fin.reasoning == "never closed")
        #expect(feedReasoning == nil)
        #expect(fin.content == OutputSanitizer.strip(raw))
    }

    @Test("gemma: stray tagClose (no tagOpen) → tag consumed, text kept (exact)")
    func gemmaStrayClose() {
        let raw = "Pre" + tagClose + "After"
        let (_, fin) = Self.runOne(raw)
        #expect(fin.content == "PreAfter")
        #expect(fin.reasoning == nil)
        #expect(fin.content == OutputSanitizer.strip(raw))
    }

    @Test("gemma: tagOpen inside tagOpen — first tagOpen pairs with first tagClose (exact)")
    func gemmaNestedOpen() {
        let raw = "A" + tagOpen + "B" + tagOpen + "C" + tagClose + "D"
        let (feedReasoning, fin) = Self.runOne(raw)
        #expect(fin.content == "AD")
        #expect(feedReasoning == "BC")
        #expect(fin.reasoning == nil)
        #expect(fin.content == OutputSanitizer.strip(raw))
    }

    // MARK: - hygiene

    @Test("finish() is idempotent (second call returns nothing)")
    func finishIdempotent() {
        let f = StreamOutputFilter()
        _ = f.feed("hello")
        let first = f.finish()
        let second = f.finish()
        #expect(first.content == "hello")
        #expect(second.content == nil)
        #expect(second.reasoning == nil)
    }

    @Test("feed after finish is a no-op")
    func feedAfterFinishNoop() {
        let f = StreamOutputFilter()
        _ = f.feed("before")
        _ = f.finish()
        let after = f.feed("after")
        #expect(after == (reasoning: nil, content: nil))
    }

    @Test("empty feeds produce nothing")
    func emptyFeeds() {
        let f = StreamOutputFilter()
        let a = f.feed("")
        #expect(a == (reasoning: nil, content: nil))
        let b = f.finish()
        #expect(b == (reasoning: nil, content: nil))
    }

    // MARK: - the golden property: chunking invariance + STRICT strip parity

    /// For the whole corpus (incl. pathological mixed-marker interleave —
    /// each real model emits only one protocol, so these only prove the
    /// filter can't be exploited to smuggle thinking into content) and a
    /// spread of chunk sizes (incl. 1-byte feeds and tag-boundary splits):
    ///   * settled content == OutputSanitizer.strip(fullRaw)  [STRICT]
    ///   * every chunking yields the same (reasoning, content) pair.
    @Test("chunking invariance + strict strip parity (10×9 cases)")
    func chunkingInvariance() {
        let corpus: [String] = [
            // qwen, 5 closers, real-prose regions
            "T0" + tagQClose + "T1" + tagQClose + "T2" + tagQClose + "T3" + tagQClose
                + "T4" + tagQClose + "ANSWER",
            // qwen clean
            "plain answer, no tags at all",
            // qwen closer + tool array in answer
            "think" + tagQClose + "ok [{\"name\":\"x\",\"arguments\":{\"y\":[1,2]}}] end",
            // gemma paired
            "Pre" + tagOpen + "span" + tagClose + "After",
            // gemma unbalanced
            "Head" + tagOpen + "never closed",
            // gemma stray tagClose
            "a" + tagClose + "b",
            // pathological: gemma span then a trailing qwen closer (strict == "C")
            "A" + tagOpen + "s" + tagClose + "B" + tagQClose + "C",
            // pathological: closer inside a span must NOT demote (strict == "y")
            tagOpen + tagQClose + "x" + tagClose + tagQClose + "y" + tagOpen + "z",
            // code with real 8-space indentation (no compression anywhere)
            "think" + tagQClose + "let x = [\n        1,\n        2\n]\ndone",
            // markers back to back with no text between
            tagQClose + tagQClose + "final",
            // empty span
            tagOpen + tagClose,
        ]
        let sizes = [1, 2, 3, 5, 7, 9, 10, 13, 21, Int.max]
        for raw in corpus {
            // baseline: single feed
            let base = StreamOutputFilter()
            let baseFeedR = base.feed(raw).reasoning ?? ""
            let baseFin = base.finish()
            let baseContent = baseFin.content ?? ""
            let baseReasoning = baseFeedR + (baseFin.reasoning ?? "")

            // STRICT golden invariant: content == strip(full) — for EVERY
            // corpus line, including the pathological interleaves.
            #expect(
                baseContent == OutputSanitizer.strip(raw),
                "strip-parity broke for: '\(raw)'")
            #expect(!baseContent.contains(tagOpen))
            #expect(!baseContent.contains(tagClose))
            #expect(!baseContent.contains(tagQClose))

            // Every chunking must route both channels identically.
            for size in sizes {
                let f = StreamOutputFilter()
                var chunkReasoning = ""
                var i = raw.startIndex
                while i < raw.endIndex {
                    let e = raw.index(
                        i, offsetBy: min(size, raw.distance(from: i, to: raw.endIndex)))
                    let r = f.feed(String(raw[i ..< e]))
                    chunkReasoning += r.reasoning ?? ""
                    i = e
                }
                let r = f.finish()
                let content = r.content ?? ""
                let reasoning = chunkReasoning + (r.reasoning ?? "")
                #expect(
                    content == baseContent,
                    "chunk size \(size) split the content channel: '\(raw)'")
                #expect(
                    reasoning == baseReasoning,
                    "chunk size \(size) split the reasoning channel: '\(raw)'")
            }
        }
    }
}
