// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// HeadlessServeModeTests — pins the pure entry-point selection surface for
// `ocoreai serve` (HeadlessMode). The live proof (windowless boot + HTTP
// bind + SIGTERM drain) is the smoke step, not this suite — the real engine
// is MainActor + GPU-bound and must not be spun up in unit tests. Here we
// pin the truth table exhaustively with exact-value assertions.
//
// The shape that earned this file: `serve` used to accept any trailing token and consume none of
// it, so `ocoreai serve --port 9090` and `ocoreai serve --help` both booted a real server — one
// on a port nobody asked for, one against the caller's own data directory, neither saying so.
// Trailing tokens are now either a help request or a refusal (exit 64), pinned below and by
// `scripts/probes/45-cli-argument-honesty.sh` against the built binary.
import Testing

@testable import ocoreai

struct HeadlessServeModeTests {

    @Test("serve alone runs headless; the binary path is never inspected")
    func serveAloneRuns() {
        #expect(HeadlessMode.serveRequest(for: ["ocoreai", "serve"]) == .run)
        #expect(HeadlessMode.serveRequest(for: ["/path/to/ocoreai", "serve"]) == .run)
    }

    @Test(
        "serve --help/-h/help answers usage instead of booting",
        arguments: ["--help", "-h", "help"])
    func serveHelp(token: String) {
        #expect(HeadlessMode.serveRequest(for: ["ocoreai", "serve", token]) == .help)
    }

    @Test(
        "an argument serve cannot honour is refused, quoted as it arrived",
        arguments: [["--port"], ["--port", "9090"], ["--help", "--port", "9090"], ["--vers"]])
    func unrecognizedIsRefused(trailing: [String]) {
        #expect(
            HeadlessMode.serveRequest(for: ["ocoreai", "serve"] + trailing)
                == .refused(unrecognized: trailing))
    }

    @Test("no arguments: default GUI branch, never headless")
    func bareInvocationIsGui() {
        #expect(HeadlessMode.serveRequest(for: ["ocoreai"]) == .notServe)
        #expect(HeadlessMode.serveRequest(for: []) == .notServe)
    }

    @Test("flag before token: leading flags are NEVER skipped (fail-safe GUI)")
    func flagFirstIsGui() {
        // `--help serve` is answered by CLIMode before this classifier; what reaches here is a
        // non-serve invocation, never a headless boot.
        #expect(HeadlessMode.serveRequest(for: ["ocoreai", "--help", "serve"]) == .notServe)
        #expect(HeadlessMode.serveRequest(for: ["ocoreai", "-v", "serve"]) == .notServe)
    }

    @Test("near-miss tokens: only the exact word serves")
    func nearMissIsGui() {
        for token in ["server", "Serve", "serve ", "--serve", "serve\t"] {
            #expect(HeadlessMode.serveRequest(for: ["ocoreai", token]) == .notServe, "\(token)")
        }
    }
}
