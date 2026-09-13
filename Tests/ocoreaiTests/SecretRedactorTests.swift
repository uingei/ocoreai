// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SecretRedactorTests.swift — exact-value coverage for the codex-baseline
/// port (`codex-rs/secrets/src/sanitizer.rs::redact_secrets`).
///
/// Two layers:
///   1. `SecretRedactor` unit level — full positive + negative matrix
///      (codex's `redacts_supported_bearer_tokens` and
///      `avoids_bearer_false_positives` ported as exact-value `#expect`
///      cases; the other three rule groups get equivalent coverage).
///   2. `ToolRegistry.call` injection level — proves the chokepoint actually
///      returns the redacted string, not just that the helper exists.
import Foundation
import Logging
import Testing

@testable import ocoreai

@Suite("SecretRedactor — codex sanitizer port")
struct SecretRedactorTests {

    private static let redacted = "[REDACTED_SECRET]"

    // MARK: - Bearer tokens (codex positive suite, verbatim semantics)

    @Test("redacts supported bearer tokens (codex positive matrix)")
    func bearerPositive() {
        let r = Self.redacted
        let cases: [(String, String)] = [
            ("Bearer abcde+fghijklmnopqrstuvwxyz012345", "Bearer \(r)"),
            ("Bearer abcdefghijklmnop+secret_suffix", "Bearer \(r)"),
            (
                "Bearer AbcdefghijklMN09._~+/-==; echo done",
                "Bearer \(r); echo done"
            ),
            (
                "authorization: Bearer abcdefghijklmnop",
                "authorization: Bearer \(r)"
            ),
            ("Bearer   abcdefghijklmnop", "Bearer \(r)"),
        ]
        for (input, expected) in cases {
            #expect(SecretRedactor.redact(input) == expected)
        }
    }

    @Test("avoids bearer false positives (codex negative matrix, verbatim)")
    func bearerNegative() {
        let cases = [
            "Bearer of good news",
            "Bearer abcdefghijklmno",
            "NotABearer abcdefghijklmnop",
            "Bearerabcdefghijklmnop",
            "Bearer\nabcdefghijklmnop",
            "Bearer\u{a0}abcdefghijklmnop",
            "Bearer abcdefghijklmno\u{212a}",
        ]
        for input in cases {
            #expect(SecretRedactor.redact(input) == input)
        }
    }

    // MARK: - OpenAI-style keys

    @Test("redacts sk- API keys (≥20 base62), boundary at 19")
    func openAIKey() {
        let key = "sk-" + String(repeating: "a1B2c3D4e5F6g7H8i9", count: 2)  // 40 base62
        let out = SecretRedactor.redact("export OPENAI_API_KEY=\(key)")
        #expect(out == "export OPENAI_API_KEY=[REDACTED_SECRET]")
        #expect(!out.contains(key))
        // 19 chars — below the {20,} threshold, untouched.
        let short = "sk-" + String(repeating: "x", count: 19)
        #expect(SecretRedactor.redact("key: \(short)") == "key: \(short)")
    }

    // MARK: - AWS access key IDs

    @Test("redacts AWS AKIA access key IDs (word-bounded, exactly 16)")
    func awsKeyId() {
        let k = "AKIA" + "ABCD1234EFGH5678"  // 16 [0-9A-Z]
        #expect(SecretRedactor.redact("aws --key \(k)") == "aws --key [REDACTED_SECRET]")
        // Embedded in a longer alphanumeric run — word-boundary kills it.
        let embedded = "XX" + k + "YY"
        #expect(SecretRedactor.redact("v=\(embedded)") == "v=\(embedded)")
        // 17 chars — [0-9A-Z]{16} would match a 16-prefix, but \b fails at the
        // 17th alphanumeric. Codex's pattern is \bAKIA[0-9A-Z]{16}\b — no match.
        let tooLong = "AKIA" + "ABCD1234EFGH56789"  // 17
        #expect(SecretRedactor.redact("k=\(tooLong)") == "k=\(tooLong)")
    }

    // MARK: - Assignment-style secrets

    @Test("redacts key/token/secret/password assignments (value ≥8)")
    func assignments() {
        let r = Self.redacted
        let cases: [(String, String)] = [
            ("api_key: abcd1234efgh5678", "api_key: \(r)"),
            ("token=verylongtokenvalue00", "token=\(r)"),
            ("password: \"hunter2x981\"", "password: \"\(r)\""),
            ("SECRET: mylongsecret123", "SECRET: \(r)"),
        ]
        for (input, expected) in cases {
            #expect(SecretRedactor.redact(input) == expected)
        }
        // 3-char value — below the {8,} threshold, untouched.
        let short = "api_key: ab1"
        #expect(SecretRedactor.redact(short) == short)
        // Non-secret keys must pass (no "token" word, no "key" word).
        let innocent = "git_commit: abcd1234efgh"
        #expect(SecretRedactor.redact(innocent) == innocent)
        _ = r
    }

    // MARK: - Pass-through (no secret)

    @Test("leaves ordinary tool output untouched")
    func neutral() {
        let plain =
            "total 42\ndrwxr-xr-x  5 user  staff  160 Sep 13 12:00 .\n-rw-r--r--  1 user  staff  102 README.md"
        #expect(SecretRedactor.redact(plain) == plain)
    }

    // MARK: - Compound (a realistic .env dump through one pass)

    @Test("redacts a realistic .env dump in one pass")
    func compound() {
        let env = """
            OPENAI_API_KEY=sk-aaaaaaaaaabbbbbbbbbbccccccccccd
            AWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMN12
            Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9
            """
        let out = SecretRedactor.redact(env)
        #expect(out.contains("OPENAI_API_KEY=[REDACTED_SECRET]"))
        #expect(out.contains("[REDACTED_SECRET]"))
        #expect(!out.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        // AKIA line: AKIA + 16 [A-Z0-9] then end-of-line → word boundary holds.
        #expect(out.contains("AKIAABCDEFGHIJKLMN12") == false)
    }
}

// MARK: - Injection point: ToolRegistry.call returns the redacted string

@Suite("ToolRegistry — tool result passes through SecretRedactor")
struct ToolRegistryRedactionTests {

    @Test("call() returns the secret redacted from the result")
    func redactedAtChokepoint() async throws {
        let registry = ToolRegistry()
        let entry = ToolEntry(
            name: "leaky", toolset: "t", schema: ToolSchema(),
            handler: { _ in "secret=abcd1234efgh5678" })
        try await registry.register(entry)
        let out = try await registry.call("leaky", arguments: "{}", caller: "test")
        #expect(!out.contains("abcd1234efgh5678"))
        #expect(out.contains("[REDACTED_SECRET]"))
    }

    @Test("call() leaves a clean tool result unmodified")
    func cleanUnchanged() async throws {
        let registry = ToolRegistry()
        let entry = ToolEntry(
            name: "clean", toolset: "t", schema: ToolSchema(),
            handler: { _ in "exit code: 0\n3 files changed, 42 insertions(+)" })
        try await registry.register(entry)
        let out = try await registry.call("clean", arguments: "{}", caller: "test")
        #expect(out == "exit code: 0\n3 files changed, 42 insertions(+)")
    }
}
