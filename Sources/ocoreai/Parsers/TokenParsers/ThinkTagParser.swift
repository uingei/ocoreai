// Copyright 2026 Apple Inc. (BSD-3-Clause, coreai-models reference)
// Vended to ocoreai for CoreAI path reasoning segmentation.
// Original: swift/Sources/CoreAILanguageModels/LanguageModel/ThinkTagParser.swift
//
// Vended 2026-08-09: Pure Foundation, no heavy deps. Used in CoreAI inference path
// to segment decoded token deltas into .reasoning vs .text events — aligns with
// upstream CoreAIExecutor.respondVanilla() pipeline.

import Foundation

/// Streaming parser that segments a model's text deltas into plain text and
/// reasoning content emitted inside chain-of-thought markers.
///
/// Reasoning-capable models like Qwen3 and DeepSeek-R1 emit chain-of-thought
/// as inline markup mixed into the regular text stream — most commonly
/// `<thinking>...</thinking>`. Without intercepting it, the markup leaks into the
/// user-visible response. This parser routes the body of each thinking block
/// as `.reasoning` events and everything else as `.text` events.
///
/// The marker pair is configurable at init so the same parser works for
/// models with different conventions. Caller is responsible for picking
/// the right pair for a given tokenizer.
struct ThinkTagParser {
    enum Event {
        case text(String)
        case reasoning(String)
    }

    private let openMarker: String
    private let closeMarker: String
    private var buffer: String = ""
    private var insideThink: Bool = false

    init(
        open: String = "<thinking>",
        close: String = "</thinking>"
    ) {
        self.openMarker = open
        self.closeMarker = close
    }

    /// Feed a decoded delta string. Returns segmented events.
    @preconcurrency mutating func consume(_ delta: String) -> [Event] {
        buffer.append(delta)
        return drain(isFinal: false)
    }

    /// Emit any pending buffered content as a final event. Required at end of
    /// stream — without it, content held back to wait for a possible marker
    /// match is silently lost.
    @preconcurrency mutating func flush() -> [Event] {
        drain(isFinal: true)
    }

    @preconcurrency private mutating func drain(isFinal: Bool) -> [Event] {
        var events: [Event] = []
        while true {
            let marker = insideThink ? closeMarker : openMarker
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
}
