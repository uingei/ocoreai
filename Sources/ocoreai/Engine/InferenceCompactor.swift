// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// InferenceCompactor.swift — Pre-turn context compaction (Agent line, codex-aligned)
///
/// codex reference: codex-rs/core/src/compact.rs + protocol/src/openai_models.rs
///   auto_compact_token_limit. Upstream contract absorbed here:
///   - threshold = effective_context_window * 9/10 (config may tighten)
///   - pre-turn trigger: compress older history once, keep the recent tail
///     verbatim, prepend a summary of the compressed part
///   - compaction failure is NON-fatal: the turn proceeds on the unmodified
///     messages (upstream never blocks a turn on compaction errors)
///
/// ocoreai binding: the summarizing call reuses the existing LLM path
/// (SummarizerActor.makeCallback()), so no new dependency is introduced.
/// The pure function `compact` is testable without any live model.

import Foundation

/// Pre-turn compaction: shrink an over-long `[Message]` history by
/// summarizing the older part and keeping the recent tail verbatim.
enum InferenceCompactor {
    /// Default trigger threshold — fraction of the model context window
    /// at which compaction runs before the turn. Mirrors codex:
    /// `context_window * 9 / 10`.
    static let thresholdFraction = 0.9

    /// Fraction of the context window reserved for the verbatim recent
    /// tail (the part never summarized). 0.2 leaves 80% headroom for
    /// summary, system prompt and generation.
    static let recentBudgetFraction = 0.2

    /// Prefix marking a compaction summary message. The engine path and
    /// session persistence treat it as regular user-role content — the
    /// prefix only lets UI/tooling identify compressed history.
    static let summaryPrefix = "[compacted context] "

    /// Rough token estimate, CJK-aware. Same formula the inference path
    /// already uses as tokenizer fallback (UTF-8 bytes / 4 overestimates
    /// CJK; ~4 bytes/token holds for EN/CJK mix at this precision level
    /// — compaction is opportunistic, precision is not required).
    static func estimateTokens(_ text: String) -> Int {
        max(1, text.utf8.count / 4)
    }

    /// Estimate total tokens of a message list (content only; tool-call
    /// payloads are a small minority and left out of the estimate).
    static func estimateTokens(_ messages: [Message]) -> Int {
        messages.reduce(0) { partial, message in
            partial + estimateTokens(text(of: message))
        }
    }

    /// Extract readable text from a message's polymorphic content.
    static func text(of message: Message) -> String {
        guard let content = message.content else { return "" }
        switch content {
        case .text(let value):
            return value
        case .parts(let parts):
            // Media parts (image/video/audio) carry no text and are
            // intentionally excluded from the transcript.
            return parts.compactMap { part in
                part.type == "text" ? part.text : nil
            }
            .joined(separator: "\n")
        }
    }

    /// Compute the split for compaction:
    /// - keep all `system` messages at their original leading positions
    /// - the rest is split into `oldSummary` (compressed) and `recentTail`
    ///   (kept verbatim, newest last)
    ///
    /// Returns `nil` when there is nothing worth summarizing (not enough
    /// non-system messages).
    struct Split {
        let system: Int  // count of leading system messages
        let oldSummary: [Message]
        let recentTail: [Message]
    }

    static func computeSplit(messages: [Message], estimatedTailBudgetTokens: Int) -> Split? {
        guard let firstNonSystem = messages.firstIndex(where: { $0.role != "system" }),
            messages.count - firstNonSystem > 3
        else {
            return nil
        }
        let rest = Array(messages[firstNonSystem...])

        let budget = max(1, estimatedTailBudgetTokens)
        // Greedy newest-first tail selection: newest messages stay verbatim
        // until the token budget is spent.
        var tail: [Message] = []
        var used = 0
        var oldestTailIndex = rest.startIndex
        for index in rest.indices.reversed() {
            let cost = estimateTokens(text(of: rest[index]))
            if used + cost <= budget || tail.isEmpty {
                tail.insert(rest[index], at: 0)
                used += cost
                oldestTailIndex = index
                if index == rest.indices.first! { break }
            } else {
                break
            }
        }
        var old = Array(rest[rest.startIndex ..< oldestTailIndex])
        // Never tear apart a tool group: an assistant message with toolCalls
        // must stay adjacent to its tool responses. If the boundary leaves
        // a dangling trailing assistant-call in `old`, slide it into `tail`.
        while let last = old.last, last.role == "assistant",
            (last.toolCalls?.isEmpty ?? true) == false
        {
            old.removeLast()
            tail.insert(last, at: 0)
        }
        guard !old.isEmpty, !tail.isEmpty else { return nil }
        return Split(system: firstNonSystem, oldSummary: old, recentTail: tail)
    }

    /// Condense `messages` in place (rebuild) for over-long histories.
    ///
    /// - Parameters:
    ///   - messages: the full prompt history (system first, then roles).
    ///   - contextWindowTokens: model context window (0 when unknown — then
    ///     no estimate can be trusted and compaction is skipped).
    ///   - summarize: async text→summary call (LLM-backed in production).
    /// - Returns: the compacted history, or `nil` when compaction was
    ///   skipped (under threshold, nothing worth splitting, or the summary
    ///   call failed). Callers treat `nil` as "proceed unchanged";
    ///   summarization failures never propagate.
    static func compact(
        _ messages: [Message],
        contextWindowTokens: Int,
        summarize: @Sendable (String) async throws -> String
    ) async -> [Message]? {
        guard contextWindowTokens > 0, !messages.isEmpty else { return nil }
        let estimate = estimateTokens(messages)
        let threshold = Int(Double(contextWindowTokens) * thresholdFraction)
        guard estimate > threshold else { return nil }
        let tailBudget = max(64, Int(Double(contextWindowTokens) * recentBudgetFraction))
        guard let split = computeSplit(messages: messages, estimatedTailBudgetTokens: tailBudget)
        else { return nil }

        var transcript = ""
        for message in split.oldSummary {
            let line = text(of: message)
            guard !line.isEmpty else { continue }
            transcript += "\(message.role.uppercased()): \(line)\n"
        }
        guard !transcript.isEmpty else { return nil }

        let prompt = """
            Condense the conversation below into a compact, faithful summary \
            (decisions made, constraints, open questions, key artifacts). \
            It replaces this history; keep it under ~40 lines.

            \(transcript)
            """
        let summary: String
        do {
            summary = try await summarize(prompt)
        } catch {
            // codex contract: compaction failure never blocks the turn.
            return nil
        }
        guard !summary.isEmpty else { return nil }

        let rebuilt =
            split.system == 0
            ? [Message(role: "user", content: summaryPrefix + summary)] + split.recentTail
            : Array(messages.prefix(split.system))
                + [Message(role: "user", content: summaryPrefix + summary)]
                + split.recentTail
        guard rebuilt.count < messages.count else { return nil }
        return rebuilt
    }
}
