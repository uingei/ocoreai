// Copyright 2026 Apple Inc. (BSD-3-Clause, coreai-models reference)
// Vended to ocoreai for CoreAI path reasoning segmentation.
// Original: swift/Sources/CoreAILanguageModels/LanguageModel/ThinkTagParser.swift
//
// Vended 2026-08-09: Pure Foundation, no heavy deps. Used in CoreAI inference path
// to segment decoded token deltas into .reasoning vs .text events — aligns with
// upstream CoreAIExecutor.respondVanilla() pipeline.
//
// 2026-08-21 (absorb #182 `637cc63`): merged agentic Format (upstream ahead)
// WITHOUT dropping ocoreai's ahead `promptEndsInsideReasoning` + `init(primedInside:)`.
//
// 2026-09-04 (absorb #206 `b91bb18`): merged upstream #206 agentic-mode hardening —
//   - `consumeEntryMarker` handles first-turn ` to=<target><|message|>` AND
//     continuation-turn `<|start|>assistant to=<target><|message|>` prefixes
//     (upstream `ThinkTagParser.swift:118-152`); failure leaves buffer intact.
//   - `isPartialRoutingHeader` holds back routing headers that arrive across
//     consume() boundaries during streaming, so no partial token
//     (`<|sta`/`assistant `) leaks into user-facing stream.
//   - `static stripReasoning(from:format:)` covers both tagPair and agentic
//     (#206 makes it a public API for non-stream consumers).
//   - `drainAgentic` rewritten to drive from these (upstream 173-219).
//   Kept: ocoreai-ahead `promptEndsInsideReasoning` + `init(primedInside:)`
//   (upstream 684ae8e grep = 0 — `git log -S promptEndsInsideReasoning` empty).
//
// Vendored surface: `struct ThinkTagParser` (internal), `enum Event`,
// `enum Format`, `consume(_:)`, `flush()`, `static tagPairFormat`,
// `static promptEndsInsideReasoning`, `static stripReasoning`.
// Test in `Tests/ocoreaiTests/AgenticThinkTagParserVendoredTests.swift`
// (upstream `AgenticThinkTagParserTests` adapted to @testable ocoreai target).

import Foundation

/// Streaming parser that segments a model's text deltas into plain text and
/// reasoning content emitted inside chain-of-thought markers.
///
/// Two formats are supported:
///
/// **Tag-pair**: symmetric open/close markers wrap reasoning content inline
/// (`<thinking>reasoning</thinking>response`). ocoreai's default mode.
///
/// **Agentic**: multi-turn message routing where reasoning is emitted as
/// `to=self` messages and responses as `to=user` messages, delimited by
/// message boundary tokens (`#182` upstream; streaming hardening `#206`).
/// Upstream `#206` agentic hardening (routing-header prefix variants, partial
/// holdback, `stripReasoning` static) merged 2026-09-04.
struct ThinkTagParser {
    enum Event {
        case text(String)
        case reasoning(String)
    }

    /// Format configuration for the parser.
    enum Format {
        /// Symmetric open/close tag pair (e.g. `<thinking>`/`</thinking>`).
        case tagPair(open: String, close: String)

        /// Agentic message routing with role-based delimiters.
        /// - `selfMarker`: string that begins a reasoning segment (e.g. "to=self<|message|>")
        /// - `userMarker`: string that begins a user-facing segment (e.g. "to=user<|message|>")
        /// - `endOfMessage`: terminates a reasoning segment (e.g. "<|eom|>")
        /// - `endOfTurn`: terminates a user-facing segment (e.g. "<|eot|>")
        case agentic(
            selfMarker: String,
            userMarker: String,
            endOfMessage: String,
            endOfTurn: String
        )
    }

    private let format: Format
    private var buffer: String = ""
    private var insideThink: Bool = false

    /// Backward-compatible init (ocoreai's original tagPair entry point).
    /// `primedInside` is preserved for `Qwen3-thinking` / `DeepSeek-R1` prefill
    /// where the opening delimiter is pre-rendered into the prompt and the
    /// first generated token is already reasoning content — see
    /// `EngineInference.swift:299/797`.
    init(open: String = "<thinking>", close: String = "</thinking>", primedInside: Bool = false) {
        self.format = .tagPair(open: open, close: close)
        self.insideThink = primedInside
    }

    /// Format-driven init (upstream `#182`). For `.agentic`, the parser starts
    /// inside a reasoning segment (the first agentic block is by convention
    /// `to=self`).
    init(format: Format) {
        self.format = format
        if case .agentic = format {
            self.insideThink = true
        }
    }

    /// Convenience: derive a Format from the classic open/close marker pair.
    static func tagPairFormat(open: String, close: String) -> Format {
        .tagPair(open: open, close: close)
    }

    // MARK: - ocoreai ahead (upstream 684ae8e has no equivalent — preserved)

    /// Whether a rendered prompt tail ends inside an open reasoning block.
    ///
    /// Qwen3-thinking / DeepSeek-R1 prefill the opening delimiter into the
    /// assistant generation prompt, so the first generated token is already
    /// reasoning content and never emits an opening `openMarker` in the stream.
    /// A parser started Outside would misroute the entire thought block.
    ///
    /// Upstream `coreai-models@684ae8e` does not ship this helper (see
    /// `git log -S promptEndsInsideReasoning` → empty). ocoreai's
    /// `EngineInference:299/797` still require it; do not remove.
    static func promptEndsInsideReasoning(
        renderedPromptTail tail: String,
        openMarker: String,
        closeMarker: String
    ) -> Bool {
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lastOpen = trimmed.range(of: openMarker, options: .backwards)?.upperBound
        let lastClose = trimmed.range(of: closeMarker, options: .backwards)?.upperBound

        switch (lastOpen, lastClose) {
        case (.none, .none): return false
        case (.some, .none): return true
        case (.none, .some): return false
        case (.some(let o), .some(let c)):
            return o > c
        }
    }

    // MARK: - Stream surface

    /// Feed a decoded delta string. Returns segmented events.
    @preconcurrency mutating func consume(_ delta: String) -> [Event] {
        buffer.append(delta)
        switch format {
        case .tagPair:
            return drainTagPair(isFinal: false)
        case .agentic:
            return drainAgentic(isFinal: false)
        }
    }

    /// Emit any pending buffered content as a final event. Required at end of
    /// stream — without it, content held back to wait for a possible marker
    /// match is silently lost.
    @preconcurrency mutating func flush() -> [Event] {
        switch format {
        case .tagPair:
            return drainTagPair(isFinal: true)
        case .agentic:
            return drainAgentic(isFinal: true)
        }
    }

    // MARK: - Tag-pair mode

    /// Drives the symmetric open/close drain. Body is byte-for-byte the same
    /// as the ocoreai 2026-08-09 vendored drain (unchanged; #206 did not touch
    /// tagPair mode).
    @preconcurrency private mutating func drainTagPair(isFinal: Bool) -> [Event] {
        guard case .tagPair = format else { return [] }
        var events: [Event] = []
        while true {
            let marker = insideThink ? closeMarkerForTagPair : openMarkerForTagPair
            let makeEvent: (String) -> Event = insideThink ? { .reasoning($0) } : { .text($0) }

            if let range = buffer.range(of: marker) {
                let before = String(buffer[buffer.startIndex ..< range.lowerBound])
                if !before.isEmpty { events.append(makeEvent(before)) }
                buffer = String(buffer[range.upperBound...])
                insideThink.toggle()
            } else {
                let safe = isFinal ? buffer.endIndex : lastSafeIndex(forTag: marker)
                if safe > buffer.startIndex {
                    let toEmit = String(buffer[buffer.startIndex ..< safe])
                    if !toEmit.isEmpty { events.append(makeEvent(toEmit)) }
                    buffer = String(buffer[safe...])
                }
                return events
            }
        }
    }

    private var openMarkerForTagPair: String {
        if case .tagPair(let open, _) = format { return open }
        return ""
    }

    private var closeMarkerForTagPair: String {
        if case .tagPair(_, let close) = format { return close }
        return ""
    }

    // MARK: - Agentic mode (#182 base; #206 streaming hardening merged 2026-09-04)

    /// Try to consume a routing header at the start of the buffer (#206).
    /// Returns true if a header was consumed, setting `insideThink` accordingly.
    ///
    /// Handles two prefix variants:
    /// - First turn: ` to=<target><|message|>` (leading space, no `<|start|>`)
    /// - Subsequent segments: `<|start|>assistant to=<target><|message|>`
    ///
    /// Non-destructive on failure: saves and restores buffer if no complete
    /// routing header is matched.
    @preconcurrency private mutating func consumeEntryMarker(
        selfMarker: String, userMarker: String, messageToken: String
    ) -> Bool {
        let saved = buffer

        if buffer.hasPrefix(" to=") {
            buffer.removeFirst()
        }

        let headerPrefix = "<|start|>assistant "
        if buffer.hasPrefix(headerPrefix) {
            buffer = String(buffer.dropFirst(headerPrefix.count))
        }

        if buffer.hasPrefix(selfMarker) {
            buffer = String(buffer.dropFirst(selfMarker.count))
            insideThink = true
            return true
        }
        if buffer.hasPrefix(userMarker) {
            buffer = String(buffer.dropFirst(userMarker.count))
            insideThink = false
            return true
        }
        if buffer.hasPrefix("to="),
            let range = buffer.range(of: messageToken)
        {
            buffer = String(buffer[range.upperBound...])
            insideThink = false
            return true
        }

        buffer = saved
        return false
    }

    /// Returns true if the buffer could be the start of a routing header that
    /// hasn't fully arrived yet during streaming (#206).
    @preconcurrency private func isPartialRoutingHeader() -> Bool {
        if buffer.isEmpty { return false }
        let headerPrefix = "<|start|>assistant "
        if headerPrefix.hasPrefix(buffer) { return true }
        if buffer.hasPrefix(headerPrefix) && buffer.range(of: "<|message|>") == nil {
            return true
        }
        if buffer.hasPrefix("to=") && buffer.range(of: "<|message|>") == nil {
            return true
        }
        if " to=".hasPrefix(buffer) { return true }
        if buffer.hasPrefix(" to=") && buffer.range(of: "<|message|>") == nil {
            return true
        }
        return false
    }

    @preconcurrency private mutating func drainAgentic(isFinal: Bool) -> [Event] {
        guard case .agentic(let selfMarker, let userMarker, let eom, let eot) = format else {
            return []
        }
        let messageToken = "<|message|>"

        var events: [Event] = []
        while true {
            if !isFinal && isPartialRoutingHeader() {
                return events
            }

            _ = consumeEntryMarker(
                selfMarker: selfMarker, userMarker: userMarker, messageToken: messageToken)

            if insideThink {
                if let range = buffer.range(of: eom) {
                    let before = String(buffer[buffer.startIndex ..< range.lowerBound])
                    if !before.isEmpty { events.append(.reasoning(before)) }
                    buffer = String(buffer[range.upperBound...])
                    insideThink = false
                } else if let range = buffer.range(of: userMarker) {
                    let before = String(buffer[buffer.startIndex ..< range.lowerBound])
                    if !before.isEmpty { events.append(.reasoning(before)) }
                    buffer = String(buffer[range.upperBound...])
                    insideThink = false
                } else {
                    let holdBack = max(eom.count, userMarker.count) - 1
                    return emitSafe(
                        events: &events, holdBack: isFinal ? 0 : holdBack, asReasoning: true)
                }
            } else {
                if let range = buffer.range(of: eot) {
                    let before = String(buffer[buffer.startIndex ..< range.lowerBound])
                    if !before.isEmpty { events.append(.text(before)) }
                    buffer = String(buffer[range.upperBound...])
                    insideThink = true
                } else if let range = buffer.range(of: selfMarker) {
                    let before = String(buffer[buffer.startIndex ..< range.lowerBound])
                    if !before.isEmpty { events.append(.text(before)) }
                    buffer = String(buffer[range.upperBound...])
                    insideThink = true
                } else {
                    let holdBack = max(eot.count, selfMarker.count) - 1
                    return emitSafe(
                        events: &events, holdBack: isFinal ? 0 : holdBack, asReasoning: false)
                }
            }
        }
    }

    /// Emit the safe prefix of the buffer, holding back `holdBack` chars that
    /// might be a marker prefix — upstream `ThinkTagParser.emitSafe`.
    private mutating func emitSafe(events: inout [Event], holdBack: Int, asReasoning: Bool)
        -> [Event]
    {
        let safeEnd: String.Index
        if holdBack <= 0 || buffer.isEmpty {
            safeEnd = buffer.endIndex
        } else {
            safeEnd = buffer.index(buffer.endIndex, offsetBy: -min(holdBack, buffer.count))
        }
        if safeEnd > buffer.startIndex {
            let toEmit = String(buffer[buffer.startIndex ..< safeEnd])
            if !toEmit.isEmpty {
                events.append(asReasoning ? .reasoning(toEmit) : .text(toEmit))
            }
            buffer = String(buffer[safeEnd...])
        }
        return events
    }

    // MARK: - Helpers

    /// Rightmost index such that the suffix from there to end-of-buffer is
    /// NOT a non-empty prefix of `tag`.
    @preconcurrency private func lastSafeIndex(forTag tag: String) -> String.Index {
        let maxHold = tag.count - 1
        guard !buffer.isEmpty, maxHold > 0 else { return buffer.endIndex }
        let holdStart = buffer.index(buffer.endIndex, offsetBy: -min(maxHold, buffer.count))
        for offset in 0 ..< buffer.distance(from: holdStart, to: buffer.endIndex) {
            let idx = buffer.index(holdStart, offsetBy: offset)
            if tag.starts(with: buffer[idx...]) {
                return idx
            }
        }
        return buffer.endIndex
    }

    /// Strip all completed thinking blocks from a full string.
    /// Unclosed blocks at the end are also removed.
    static func stripCompleted(
        from text: String, open: String = "<thinking>", close: String = "</thinking>"
    ) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var remaining = text[...]
        while let startRange = remaining.range(of: open) {
            result.append(contentsOf: remaining[remaining.startIndex ..< startRange.lowerBound])
            if let endRange = remaining.range(
                of: close, range: startRange.upperBound ..< remaining.endIndex)
            {
                remaining = remaining[endRange.upperBound...]
            } else {
                // Unclosed block — discard everything from here
                return result
            }
        }
        result.append(contentsOf: remaining)
        return result
    }

    /// Strip reasoning content for a given format (handles both tag-pair and agentic).
    /// Upstream `#206` makes this a public API for non-stream consumers.
    static func stripReasoning(from text: String, format: Format) -> String {
        switch format {
        case .tagPair(let open, let close):
            return stripCompleted(from: text, open: open, close: close)
        case .agentic(let selfMarker, let userMarker, let eom, let eot):
            var parser = ThinkTagParser(
                format: .agentic(
                    selfMarker: selfMarker, userMarker: userMarker,
                    endOfMessage: eom, endOfTurn: eot))
            let events = parser.consume(text) + parser.flush()
            return events.compactMap { event -> String? in
                if case .text(let t) = event { return t }
                return nil
            }.joined()
        }
    }
}
