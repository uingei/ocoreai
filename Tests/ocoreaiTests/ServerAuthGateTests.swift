// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ServerAuthGateTests.swift — exact-value tests for the loopback/auth gate.
///
/// Two tables, exact values (no `> N` style weak asserts):
/// 1. ``LoopbackBinding.classify(_:)`` — full classifier matrix.
/// 2. ``ServerAuthGate.checkHost(_:authEnabled:logger:)`` — the 4-cell gate
///    table (loopback × {on,off}, nonLoopback × {on,off}); only the
///    nonLoopback/off cell must throw, and with the exact error type.

import Foundation
import Testing

@testable import ocoreai

@Suite("LoopbackBinding classify matrix")
final class LoopbackBindingTests {
    @Test("loopback names classify as loopback")
    func loopbackNames() {
        // Exact-value: every entry must classify .loopback.
        for host in [
            "127.0.0.1",  // canonical IPv4 loopback
            "127.0.0.5",  // 127/8 — any 127.x.x.x is loopback
            "127.1.2.3",
            "::1",  // IPv6 loopback
            "::ffff:127.0.0.1",
            "localhost",
            "local",
        ] {
            #expect(LoopbackBinding.classify(host) == .loopback, "expected loopback for \(host)")
        }
    }

    @Test("non-loopback binds classify as nonLoopback")
    func nonLoopbackBinds() {
        // Exact-value: every entry must classify .nonLoopback.
        for host in [
            "0.0.0.0",  // wildcard
            "::",  // IPv6 wildcard
            "192.168.1.10",  // LAN
            "10.0.0.1",
            "172.16.5.4",
            "example.com",  // hostname — conservative: not loopback
            "::ffff:192.168.1.10",
            "",  // empty — conservative: not loopback
            "  10.0.0.1  ",  // whitespace-trimmed, still non-loopback
        ] {
            #expect(
                LoopbackBinding.classify(host) == .nonLoopback, "expected nonLoopback for \(host)")
        }
    }

    @Test("case + whitespace insensitivity on loopback names")
    func caseAndWhitespace() {
        #expect(LoopbackBinding.classify("LOCALHOST") == .loopback)
        #expect(LoopbackBinding.classify("localhost") == .loopback)
        #expect(LoopbackBinding.classify("  127.0.0.1  ") == .loopback)
        #expect(LoopbackBinding.classify(" ::1 ") == .loopback)
    }
}

@Suite("ServerAuthGate 4-cell gate table")
final class ServerAuthGateTests {
    /// Helper: return true iff `host` with `authOn` passes (does not throw).
    private func gatePasses(_ host: String, authOn: Bool) -> Bool {
        do {
            try ServerAuthGate.checkHost(host, authEnabled: authOn, logger: nil)
            return true
        } catch {
            return false
        }
    }

    @Test("gate table — exact 4-cell truth table")
    func gateTable() {
        // Cell 1: loopback + auth off  → PASS (local-only, safe).
        #expect(gatePasses("127.0.0.1", authOn: false) == true)
        // Cell 2: loopback + auth on   → PASS.
        #expect(gatePasses("127.0.0.1", authOn: true) == true)
        // Cell 3: nonLoopback + auth on → PASS (auth enforced).
        #expect(gatePasses("0.0.0.0", authOn: true) == true)
        // Cell 4: nonLoopback + auth off→ REFUSE (the only failing cell).
        #expect(gatePasses("0.0.0.0", authOn: false) == false)
        // Non-loopback hostname, auth off → also refuse.
        #expect(gatePasses("192.168.1.10", authOn: false) == false)
        // Non-loopback hostname, auth on  → pass.
        #expect(gatePasses("192.168.1.10", authOn: true) == true)
        // Default host value (127.0.0.1), any auth state → pass.
        #expect(gatePasses("127.0.0.1", authOn: true) == true)
        #expect(gatePasses("127.0.0.1", authOn: false) == true)
    }

    @Test("throwing cell raises ServerAuthGate.RefusedToServeError, not a different type")
    func exactErrorType() {
        do {
            try ServerAuthGate.checkHost("0.0.0.0", authEnabled: false, logger: nil)
            Issue.record("expected RefusedToServeError to be thrown for 0.0.0.0 without auth")
        } catch let e as ServerAuthGate.RefusedToServeError {
            #expect(e.host == "0.0.0.0")
            #expect((e.errorDescription ?? "").contains("0.0.0.0"))
            #expect((e.errorDescription ?? "").contains("OCOREAI_API_KEYS"))
        } catch let other {
            Issue.record("expected RefusedToServeError, got \(type(of: other))")
        }
    }

    @Test("loopback cell never throws regardless of auth state")
    func loopbackNeverThrows() {
        for authOn in [true, false] {
            for host in ["127.0.0.1", "::1", "localhost"] {
                #expect(
                    (try? ServerAuthGate.checkHost(host, authEnabled: authOn, logger: nil)) != nil)
            }
        }
    }
}
