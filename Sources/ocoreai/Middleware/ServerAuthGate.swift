// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ServerAuthGate.swift — refuse network exposure without authentication.
///
/// ### Why this exists (upstream pattern, omlx `09a7c43` 2026-09-13):
/// `OCOREAI_HOST` may name a LAN interface or `0.0.0.0`. Without this gate,
/// an unset `OCOREAI_API_KEYS` degrades ``AuthMiddleware`` to pass-through
/// and the entire inference API would be served open — no 401 on any route.
/// omlx added the identical rule: *"refuses to start on any non-loopback
/// address without an API key, and API key verification can only be skipped
/// for loopback-only binds."*
///
/// ### Gate semantics (exact-match table, see ``ServerAuthGateTests``):
/// | bind                    | auth enabled | result              |
/// | ------------------------|--------------|---------------------|
/// | loopback (127.x / ::1 …) | either       | pass                |
/// | non-loopback             | **on**       | pass (auth enforced)|
/// | non-loopback             | off          | **refuse** (fail)   |
///
/// Pure + synchronous: no network I/O, so this is unit-testable without a
/// server. ``App.buildApplication`` calls ``checkHost`` before binding.

import Foundation
import Logging

// MARK: - Loopback classification

/// Hostname / IP-string classification for the bind side of the gate.
///
/// Loopback names are matched case-insensitively after trimming; IPv4 is
/// matched by numeric prefix (any `127.0.0.0/8`), IPv6 by `::1` and the
/// mapped-IPv4 form `::ffff:127.x.x.x`. Anything else — hostnames, `0.0.0.0`,
/// `::`, or any non-127 IPv4/IPv6 — is **conservatively non-loopback** and
/// therefore requires auth when binding fails open.
enum LoopbackBinding {
    case loopback
    case nonLoopback

    /// Classify a bind address string from ``OCOREAI_HOST``.
    static func classify(_ raw: String) -> LoopbackBinding {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !host.isEmpty else { return .nonLoopback }

        // Bare loopback names
        for name in ["127.0.0.1", "::1", "localhost", "local"] where host == name {
            return .loopback
        }

        // IPv6-mapped IPv4: "::ffff:127.0.0.1" carries a dotted tail.
        let dotted =
            host.hasPrefix("::ffff:")
            ? String(host.dropFirst(7))
            : host

        let parts = dotted.split(separator: ".")
        if parts.count == 4 {
            if let first = parts.first, Int(first) == 127,
                parts.dropFirst().allSatisfy({ Int($0) != nil })
            {
                return .loopback
            }
            return .nonLoopback
        }

        // IPv4 without a leading mapped prefix and no bare-name match above
        if parts.count == 4, parts.allSatisfy({ Int($0) != nil }) {
            return .nonLoopback
        }
        return .nonLoopback
    }
}

// MARK: - Gate

/// Enforce "no open network bind without API keys" before the server listens.
enum ServerAuthGate {

    /// Error type thrown (and returned in tests) when the gate refuses.
    struct RefusedToServeError: Error, LocalizedError {
        let host: String
        var errorDescription: String? {
            "Refusing to bind '\(host)' — non-loopback bind without API keys "
                + "would serve the inference API open. Set OCOREAI_API_KEYS, or "
                + "bind a loopback address (127.0.0.1)."
        }
    }

    /// Check a bind address against the auth-enabled flag.
    ///
    /// - Parameters:
    ///   - host: Bind address string (`OCOREAI_HOST`, default `127.0.0.1`).
    ///   - authEnabled: ``AuthConfig.enabled`` — true when `OCOREAI_API_KEYS`
    ///     names at least one key.
    ///   - logger: Optional; when present the refusal is logged at `.error`
    ///     (the thrown error carries the user-facing message).
    /// - Throws: ``RefusedToServeError`` in the non-loopback / auth-off cell
    ///   of the table above — the ONLY cell that fails.
    static func checkHost(
        _ host: String,
        authEnabled: Bool,
        logger: Logger? = nil
    ) throws {
        guard LoopbackBinding.classify(host) == .nonLoopback, !authEnabled
        else { return }
        logger?.error(
            "Refusing to bind non-loopback \(host) without OCOREAI_API_KEYS (open inference API); set a key or bind a loopback address."
        )
        throw RefusedToServeError(host: host)
    }
}
