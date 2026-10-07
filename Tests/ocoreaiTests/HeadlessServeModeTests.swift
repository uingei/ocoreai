// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// HeadlessServeModeTests — pins the pure entry-point selection surface for
// `ocoreai serve` (HeadlessMode). The live proof (windowless boot + HTTP
// bind + SIGTERM drain) is the smoke step, not this suite — the real engine
// is MainActor + GPU-bound and must not be spun up in unit tests. Here we
// pin the truth table exhaustively with exact-value assertions.
import Testing

@testable import ocoreai

struct HeadlessServeModeTests {

    @Test("serve subcommand: exact first token after argv[0] selects headless")
    func serveExactToken() {
        #expect(HeadlessMode.isServeInvocation(["ocoreai", "serve"]) == true)
        #expect(HeadlessMode.isServeInvocation(["/path/to/ocoreai", "serve"]) == true)
        // Trailing flags select headless too (documented, not yet consumed).
        #expect(HeadlessMode.isServeInvocation(["ocoreai", "serve", "--port"]) == true)
        #expect(
            HeadlessMode.isServeInvocation(["ocoreai", "serve", "--port", "9090"]) == true)
    }

    @Test("no arguments: default GUI branch, never headless")
    func bareInvocationIsGui() {
        #expect(HeadlessMode.isServeInvocation(["ocoreai"]) == false)
        #expect(HeadlessMode.isServeInvocation([]) == false)
    }

    @Test("flag before token: leading flags are NEVER skipped (fail-safe GUI)")
    func flagFirstIsGui() {
        #expect(HeadlessMode.isServeInvocation(["ocoreai", "--help", "serve"]) == false)
        #expect(HeadlessMode.isServeInvocation(["ocoreai", "-v", "serve"]) == false)
    }

    @Test("near-miss tokens: only the exact word serves")
    func nearMissIsGui() {
        #expect(HeadlessMode.isServeInvocation(["ocoreai", "server"]) == false)
        #expect(HeadlessMode.isServeInvocation(["ocoreai", "Serve"]) == false)
        #expect(HeadlessMode.isServeInvocation(["ocoreai", "serve "]) == false)
        #expect(HeadlessMode.isServeInvocation(["ocoreai", "--serve"]) == false)
    }

    @Test("entryPoint: GUI default, headless only via serve")
    func entryPointSelection() {
        #expect(HeadlessMode.entryPoint(for: ["ocoreai"]) == .gui)
        #expect(HeadlessMode.entryPoint(for: ["ocoreai", "run"]) == .gui)
        #expect(HeadlessMode.entryPoint(for: ["ocoreai", "serve"]) == .headless)
        #expect(HeadlessMode.entryPoint(for: ["ocoreai", "serve", "--port"]) == .headless)
    }
}
