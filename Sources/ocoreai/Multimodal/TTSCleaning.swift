// Copyright © 2026 uingei@163.com
// Licensed under MIT.
/// TTSCleaning.swift — Canonical TTS text cleaning (thinking tags + code blocks).
///
/// All production speak paths (agent `speak` tool, chat speaker, direct
/// `AudioIO.speak`) converge on `AudioIO.speak` — the single real TTS sink.
/// This enum owns the pre-sink cleaning so the agent and speaker paths can't
/// drift: agent `Speak.build` and the chat speaker both route through the exact
/// same `TTSCleaning.speakable(...)` before truncating to their respective caps
/// (speaker 500, agent 8000 — different UX intents, both documented).
///
/// The old `TTSFilterConfig` dead config (zero consumers, self-defined
/// `speechRate [0.5, 2.0]` domain conflicting with Apple `AVSpeechUtterance.rate
/// [0.0, 1.0]`, no 3-repo baseline) is removed per ocoreai's consumer-
/// transparent / no-speculative-API discipline.

import Foundation

/// Deterministic, idempotent text → speakable-text cleanup.
///
/// Nonisolated static API: pure Foundation regex/scan, no actor state, no I/O.
enum TTSCleaning {
    /// Speaker's default pre-sink truncation (500 chars) — the chat UI's "no
    /// TTS on long outputs" UX. The agent `speak` tool exposes 8000 by default
    /// (an explicit "read this out loud" intent); both caps are product choices,
    /// not configuration knobs, so they stay explicit at the call site.
    static let speakerDefaultCap = 500

    /// Strip `<thinking>…</thinking>` blocks and fenced ``` code blocks, collapse
    /// leading/trailing whitespace, truncate to `limit` (append `…` on truncation).
    ///
    /// - `limit = 0` means "no truncation" — the caller enforces its own cap.
    /// - Idempotent: applying twice yields the same result (no `…` artifacts,
    ///  no residual thinking/code markers).
    /// - Pure: no actor state, deterministic on input.
    static func speakable(
        _ text: String, _ limit: Int = speakerDefaultCap
    ) -> String {
        var out = stripThinkingTags(from: text)
        out = stripCodeBlocks(from: out)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if limit > 0, out.count > limit {
            out = String(out.prefix(limit))
        }
        return out
    }

    /// Strip `<thinking>…</thinking>` blocks (multiline, nested content).
    ///
    /// Non-greedy `.*?` with `dotMatchesLineSeparators` so multi-line thinking
    /// bodies and nested HTML/code fragments inside are all removed. Empty input
    /// or "no thinking tags" input returns unchanged.
    private static func stripThinkingTags(from text: String) -> String {
        guard text.contains("<thinking>") else { return text }
        return
            (try? NSRegularExpression(
                pattern: "<thinking>.*?</thinking>",
                options: .dotMatchesLineSeparators
            ).stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "")) ?? text
    }

    /// Remove fenced code blocks line-by-line.
    ///
    /// Returns text with ``` … ``` regions dropped (toggled on each fence line).
    /// Idempotent. Pure Foundation, no I/O, no actor state.
    private static func stripCodeBlocks(from content: String) -> String {
        var inCodeBlock = false
        var out: [String] = []
        out.reserveCapacity(content.components(separatedBy: "\n").count)
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock { continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}
