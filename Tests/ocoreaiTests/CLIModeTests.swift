// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// CLIModeTests — pins the pure informational CLI surface (--version/--help).
// The live proof (binary answers instantly, exit 0, no engine boot) is the
// smoke run; here we pin the truth table exhaustively, same discipline as
// HeadlessServeModeTests: exact values, no I/O. Formatting discipline:
// every call binds to a `let` first — CI's swift-format (603.0.0) and
// this host's (`main`) wrap long #expect arguments differently; lines
// under 100 chars stay byte-stable in both.
import Testing

@testable import ocoreai

struct CLIModeTests {

    @Test("--version/-v: exact tokens report version from AppInfo truth")
    func versionTokens() {
        let bare = ["ocoreai", "--version"]
        let r1 = CLIMode.versionOrHelpReport(for: bare, shortVersion: "9.9.9")
        #expect(r1 == "ocoreai 9.9.9")

        let app = "/Applications/ocoreai.app/Contents/MacOS/ocoreai"
        let r2 = CLIMode.versionOrHelpReport(for: [app, "-v"], shortVersion: "0.1.12")
        #expect(r2 == "ocoreai 0.1.12")

        // Trailing junk never suppresses the answer (first token rules).
        let junk = ["ocoreai", "--version", "extra"]
        let r3 = CLIMode.versionOrHelpReport(for: junk, shortVersion: "1.2.3")
        #expect(r3 == "ocoreai 1.2.3")
    }

    @Test("--help/-h/help: exact tokens print usage carrying the version")
    func helpTokens() {
        for token in ["--help", "-h", "help"] {
            let args = ["ocoreai", token]
            let report = CLIMode.versionOrHelpReport(for: args, shortVersion: "0.2.0")
            #expect(report != nil, "token \(token) must produce usage")
            #expect(report?.contains("ocoreai 0.2.0") == true)
            #expect(report?.contains("serve") == true)
        }
    }

    @Test("serve routing untouched: serve never captured by info flags")
    func serveNeverCaptured() {
        let serve = ["ocoreai", "serve"]
        let r1 = CLIMode.versionOrHelpReport(for: serve, shortVersion: "X")
        #expect(r1 == nil)
        let serveFlag = ["ocoreai", "serve", "--version"]
        let r2 = CLIMode.versionOrHelpReport(for: serveFlag, shortVersion: "X")
        #expect(r2 == nil)
    }

    @Test("fail-safe default: bare, near-miss, empty → nil (GUI)")
    func failSafeGuiDefault() {
        #expect(CLIMode.versionOrHelpReport(for: [], shortVersion: "X") == nil)
        #expect(CLIMode.versionOrHelpReport(for: ["ocoreai"], shortVersion: "X") == nil)
        // near misses — only the exact tokens answer
        let nearMisses = ["-version", "--versions", "Help", "", "SERVER"]
        for token in nearMisses {
            let args = ["ocoreai", token]
            let report = CLIMode.versionOrHelpReport(for: args, shortVersion: "X")
            #expect(report == nil, "near-miss \(token) must fall through to GUI")
        }
    }

    @Test("usage truth: only real subcommand + env vars consumed in Sources")
    func usageTruth() {
        let usage = CLIMode.usageText(version: "0.1.12")
        let envs = [
            "OCOREAI_HOST", "OCOREAI_PORT", "OCOREAI_ENABLE_HTTP",
            "OCOREAI_API_KEYS", "OCOREAI_DATA_DIR", "OCOREAI_MODELS_DIR",
        ]
        for env in envs {
            #expect(usage.contains(env), "usage must list \(env)")
        }
        #expect(usage.contains("127.0.0.1:8080"))
    }
}
