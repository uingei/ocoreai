// Copyright 2026 Apple Inc. (BSD-3-Clause, coreai-models reference)
// Vended to ocoreai for CoreAI path tool call detection.
// Original: swift/Sources/CoreAILanguageModels/ToolCallParser.swift
//
// Vended 2026-08-09: Pure Foundation, no heavy deps. Used in CoreAI inference path
// to detect tool call blocks in decoded token deltas — aligns with upstream
// CoreAIExecutor.respondVanilla() pipeline.
//
// Re-vendored 2026-08-28: tool-call id → `call_<8hex>` (coreai-models #203,
// OpenAI-style), consistent with ocoreai's ToolCallAccumulator (OpenAIModels.swift)
// and the round-trip result message (EngineInference.swift `Chat.Message.tool`).

import Foundation

/// Streaming parser that detects tool call blocks in the model's token stream.
struct ToolCallParser {
    enum Event {
        case text(String)
        case toolCall(id: String, name: String, argsJSON: String)
    }

    private let openMarker: String
    private let closeMarker: String
    private var buffer: String = ""
    private var isInsideToolCall: Bool = false

    init(openMarker: String = "\u{8958}", closeMarker: String = "\u{8959}") {
        self.openMarker = openMarker
        self.closeMarker = closeMarker
    }

    mutating func consume(_ delta: String) -> [Event] {
        buffer.append(delta)
        return drain(isFinal: false)
    }

    /// Emit any pending buffered content as final events.
    ///
    /// Required at end of stream — without it, text held back to wait for a
    /// possible marker match is silently lost. An unclosed block
    /// at EOS is dropped (malformed JSON is not useful to surface as text).
    /// Exception: newline-terminated formats (e.g. Mistral\'[TOOL_CALLS])
    /// have no trailing close token, so the buffered content is parsed on EOS.
    mutating func flush() -> [Event] {
        drain(isFinal: true)
    }

    private mutating func drain(isFinal: Bool) -> [Event] {
        var events: [Event] = []
        while let range = buffer.range(of: isInsideToolCall ? closeMarker : openMarker) {
            processMarker(at: range, events: &events)
            isInsideToolCall.toggle()
        }
        processRemainder(of: &events, isFinal: isFinal)
        return events
    }

    private mutating func processMarker(at range: Range<String.Index>, events: inout [Event]) {
        let before = String(buffer[buffer.startIndex ..< range.lowerBound])
        if isInsideToolCall {
            events.append(contentsOf: parseToolCalls(from: before))
        } else if !before.isEmpty {
            events.append(.text(before))
        }
        buffer = String(buffer[range.upperBound...])
    }

    private mutating func processRemainder(of events: inout [Event], isFinal: Bool) {
        if isInsideToolCall {
            guard isFinal else { return }
            if closeMarker == "\n" {
                events.append(contentsOf: parseToolCalls(from: buffer))
            }
            buffer = ""
        } else {
            let safe = isFinal ? buffer.endIndex : lastSafeIndex(for: openMarker)
            if safe > buffer.startIndex {
                let toEmit = String(buffer[buffer.startIndex ..< safe])
                if !toEmit.isEmpty { events.append(.text(toEmit)) }
                buffer = String(buffer[safe...])
            }
        }
    }

    private func parseToolCalls(from json: String) -> [Event] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return [] }

        if trimmed.hasPrefix("["),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        {
            return array.compactMap { makeToolCallEvent(from: $0) }
        }

        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return makeToolCallEvent(from: obj).map { [$0] } ?? []
        }

        return []
    }

    private func makeToolCallEvent(from obj: [String: Any]) -> Event? {
        guard let name = obj["name"] as? String else { return nil }

        let argsJSON: String
        if let argsDict = obj["arguments"] as? [String: Any],
            let argsData = try? JSONSerialization.data(withJSONObject: argsDict),
            let argsStr = String(data: argsData, encoding: .utf8)
        {
            argsJSON = argsStr
        } else if let argsStr = obj["arguments"] as? String {
            argsJSON = argsStr
        } else {
            argsJSON = "{}"
        }

        let callId = "call_\(UUID().uuidString.prefix(8).lowercased())"
        return .toolCall(id: callId, name: name, argsJSON: argsJSON)
    }

    /// Rightmost index such that the suffix from there to end-of-buffer is NOT
    /// a non-empty prefix of `tag`. Same implementation as `ThinkTagParser`.
    private func lastSafeIndex(for tag: String) -> String.Index {
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
