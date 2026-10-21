// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! TokenEstimate.swift — the one place that answers "roughly how many tokens is this text?"
//! when no tokenizer is loaded.
//!
//! ### Why one home
//! Measured 10-21 (`git grep` at `5c13f6a`): **17** sites in **9** files answered it with
//! **three** formulas. The CJK-aware byte rule was copy-pasted five times (`ChatHandler`,
//! `AnthropicMessagesHandler`, `CompletionsHandler`, `EngineInference`,
//! `ConversationCompaction`); plain "length / 4" ran eleven times — `utf8.count / 4` in
//! `SchedulerActor`, which decides whether a request is admitted, and ten perception-budget
//! sites in `PerceptionEngine`/`PerceptionContext` dividing *characters* by 4; and
//! `utf16/3` once, in the GUI's `ChatState` — the number the composer's context meter shows.
//! Same text, different answers depending on which circuit asked, and those numbers are what
//! clients budget on (`/v1/count-tokens` publishes this heuristic), what admission spends, and
//! what history compaction prunes against.
//!
//! The `utf16/3` variant was the dangerous one: its own doc comment called itself CJK-aware
//! while counting one UTF-16 unit per CJK character, so "你好世界" read as **1** token on the
//! composer's context meter where this rule says **4**. Under-reporting is the direction that
//! hurts — it tells a user there is room in the window when there is not.
//!
//! ### The rule
//! CJK-heavy text (average > 1.5 UTF-8 bytes per character) divides bytes by 3, otherwise
//! by 4. Empty content is 0; a prompt a client will be charged for is never below 1.
//!
//! ### How far off it is — measured, not assumed
//! 10-21, `mlx-community/gemma-4-e2b-it-4bit`, against `/v1/count-tokens` with
//! `tokenizer_backend: real`; "content" = that count minus the 10 tokens of chat-template
//! framing this model adds (measured with a one-character prompt).
//!
//! ```text
//!   sample          content   bytes/3-or-4      utf16/3      bytes/4
//!   english prose        19          22 (+16%)     30 (+58%)      22 (+16%)
//!   chinese              18          26 (+44%)     10 (-44%)       19  (+6%)
//!   mixed zh/en         15          22 (+47%)     13 (-13%)       16  (+7%)
//!   code                17          15 (-12%)     20 (+18%)       15 (-12%)
//!   chinese, long       32          50 (+56%)     18 (-44%)       37 (+16%)
//! ```
//!
//! Read that against the folklore it corrects: **which divisor CJK wants is a property of the
//! model's vocabulary, not of the script.** This tokenizer merges CJK pairs, so `/3`
//! overshoots by ~45% and plain `/4` was the closest of the three on every sample; a
//! vocabulary with one token per CJK glyph flips the verdict the other way. So this file
//! deliberately does not ship a "better" constant — it keeps the one rule clients already
//! receive on `/v1/count-tokens` and states what it costs. The measured next step is to take
//! the ratio from a model that *does* have a tokenizer rather than assume one, the way
//! `ToolProseLedger` measures whether a template renders tools instead of guessing (open
//! item, CHANGELOG 10-21).

enum TokenEstimate {

    /// Size one piece of content, rounded down — 0 is an honest answer for a fragment ("S")
    /// or empty content. Use where per-row sizes are summed (compaction, persisted rows).
    static func contentTokens(_ text: String) -> Int {
        let bytes = text.utf8.count
        let chars = text.count
        guard chars > 0 else { return 0 }
        return bytes / divisor(bytes: bytes, chars: chars)
    }

    /// Size a prompt the client will be charged for: the ratio is taken across the whole
    /// body, and a non-empty prompt is never reported as 0. Returns 0 only when there is no
    /// content at all, which is the caller's signal to reject the request.
    static func promptTokens(_ text: String) -> Int {
        aggregate(bytes: text.utf8.count, chars: text.count)
    }

    /// A multi-completion body, judged as one prompt.
    static func promptTokens(_ texts: [String]) -> Int {
        let bytes = texts.reduce(0) { $0 + $1.utf8.count }
        let chars = texts.reduce(0) { $0 + $1.count }
        return aggregate(bytes: bytes, chars: chars)
    }

    /// A message list, judged as one prompt (the assembled-prompt path).
    static func promptTokens(_ messages: [Message]) -> Int {
        let bytes = messages.reduce(0) { $0 + $1.textContent().utf8.count }
        let chars = messages.reduce(0) { $0 + $1.textContent().count }
        return aggregate(bytes: bytes, chars: chars)
    }

    /// CJK-heavy content tokenizes at roughly one token per 3 UTF-8 bytes; Latin-heavy at
    /// roughly one per 4. Average bytes-per-character separates the two without a script table.
    private static func divisor(bytes: Int, chars: Int) -> Int {
        Double(bytes) / Double(chars) > 1.5 ? 3 : 4
    }

    private static func aggregate(bytes: Int, chars: Int) -> Int {
        guard chars > 0 else { return 0 }
        return max(1, bytes / divisor(bytes: bytes, chars: chars))
    }
}
