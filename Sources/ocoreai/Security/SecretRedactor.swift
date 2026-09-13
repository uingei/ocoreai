// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SecretRedactor.swift — best-effort secret masking in tool-result text
///
/// Port of the codex main-axis baseline `codex-rs/secrets/src/sanitizer.rs`
/// (`redact_secrets`): the same four regexes, applied in the same order,
/// so ocoreai's tool outputs carry the same redaction semantics as codex's
/// client-facing command surface and memory serialization.
///
/// Why it exists — first principles: a coding agent's highest-traffic secret
/// leak is shell/`.env`/config content flowing through a tool result into the
/// model context, where a later turn can echo it out (chat, SSE client,
/// memory). ocoreai had zero masking on that path (verified: the only `mask`
/// in the codebase is a log message string in AuthMiddleware.swift:290).
/// openclaw `dcf3baa8535` (#146596) fixed the same hole on its tool-result
/// delivery surface; codex already had this in-tree, so this is an upstream
/// consumption, not a local invention.
///
/// Scope discipline (matches codex): best effort, well-known shapes only —
/// OpenAI `sk-` keys, AWS access-key IDs, `Bearer` tokens, and
/// `key/token/secret/password = value` assignments. NOT a generic entropy
/// scanner: codex deliberately keeps the false-positive surface small
/// (their `avoids_bearer_false_positives` suite encodes the boundary).
///
/// Perf: all patterns compile once (static lazy). Per-call cost is a linear
/// regex pass over the result string — same order of magnitude as the
/// existing SHA-free loop-detection path in ToolRegistry.

import Foundation

enum SecretRedactor {
    /// Replacement marker (codex uses the identical token).
    static let redacted = "[REDACTED_SECRET]"

    // MARK: - Patterns (port of codex sanitizer.rs, order preserved)

    /// OpenAI-style API keys: `sk-` + ≥20 base62 chars.
    private static let openAIKey = compile(#"sk-[A-Za-z0-9]{20,}"#)

    /// AWS access key IDs: `AKIA` + 16 uppercase alphanumeric, word-bounded.
    private static let awsAccessKeyId = compile(#"\bAKIA[0-9A-Z]{16}\b"#)

    /// `Bearer <token>` — scoped case-insensitive on the scheme word only,
    /// token body = ≥16 chars of base64-ish set, optional `=` padding.
    /// Word-bounded + `[ \t]+` only (no newline/NBSP) to keep
    /// `"Bearer of good news"`-style prose intact (codex negative tests).
    private static let bearerToken = compile(#"(?i:\bBearer)[ \t]+[A-Za-z0-9._~+/-]{16,}=*"#)

    /// Assignment-style secrets: `api_key: xxx` / `token=xxx` / `password: "xxx"`.
    /// Key word is `api[_-]?key | token | secret | password` (case-insensitive),
    /// followed by `:` or `=` assignment, optional quote, then ≥8 non-space
    /// non-quote chars. Groups: $1=key $2=assignment $3=quote.
    private static let secretAssignment =
        compile(#"(?i)\b(api[_-]?key|token|secret|password)\b(\s*[:=]\s*)(["']?)[^\s"']{8,}"#)

    // MARK: - Public API

    /// Redact well-known secret shapes from `input`.
    /// No-op for strings without a match (returns the same string value,
    /// no allocation pressure beyond one pass).
    static func redact(_ input: String) -> String {
        var out = input
        out = replace(out, with: "Bearer \(redacted)", using: bearerToken)
        out = replace(out, with: redacted, using: openAIKey)
        out = replace(out, with: redacted, using: awsAccessKeyId)
        out = replace(out, with: "$1$2$3\(redacted)", using: secretAssignment)
        return out
    }

    // MARK: - Internals

    /// `stringByReplacingMatches` with an optional pattern — a nil pattern
    /// (a compile failure; should never happen for the literals above) is a
    /// no-op for that one rule, keeping the whole redactor best-effort rather
    /// than crashing a customer process over a broken port.
    private static func replace(
        _ string: String, with replacement: String, using pattern: NSRegularExpression?
    ) -> String {
        guard let pattern else { return string }
        return pattern.stringByReplacingMatches(
            in: string, options: [], range: NSRange(string.startIndex..., in: string),
            withTemplate: replacement)
    }

    private static func compile(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }
}
