// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// HarnessConnectTests — the pure half of `ocoreai connect`: argv classification, PATH
// detection, the printed plan, and the child's environment, all to exact values.
// The live half (server trust via /v1/models, exit forwarding) is probe 55, which
// execs a stand-in harness — a real loop's wire proof stays probe 53's. Same
// formatting discipline as CLIModeTests: bind to a `let` first, keep lines short.
import Foundation
import Testing

@testable import ocoreai

struct HarnessConnectTests {

    @Test("classification table — every token shape lands on exactly one case")
    func classification() throws {
        let cases: [([String], HarnessConnect.Request)] = [
            (["ocoreai"], .notConnect),
            (["ocoreai", "server"], .notConnect),
            (["ocoreai", "serve"], .notConnect),
            (["ocoreai", "--help", "connect"], .notConnect),  // leading help already answered
            (["ocoreai", "connect"], .noHarness),
            (["ocoreai", "connect", "--dry-run"], .noHarness),
            // A lone help token answers with usage (serve's rule), before harness lookup.
            (["ocoreai", "connect", "help"], .help),
            (
                ["ocoreai", "connect", "claude-code"],
                .run(harness: "claude-code", binaryName: "claude", dryRun: false, harnessArgs: [])
            ),
            (
                ["ocoreai", "connect", "--dry-run", "claude-code"],
                .run(harness: "claude-code", binaryName: "claude", dryRun: true, harnessArgs: [])
            ),
            (
                ["ocoreai", "connect", "claude-code", "--dry-run"],
                .run(harness: "claude-code", binaryName: "claude", dryRun: true, harnessArgs: [])
            ),
            (["ocoreai", "connect", "bogus"], .unknownHarness("bogus")),
            (["ocoreai", "connect", "--port", "1"], .refused(unrecognized: ["--port"])),
            (["ocoreai", "connect", "a", "b"], .refused(unrecognized: ["b"])),
            (
                ["ocoreai", "connect", "claude-code", "--", "--bogus"],
                .run(
                    harness: "claude-code", binaryName: "claude", dryRun: false,
                    harnessArgs: ["--bogus"])
            ),
            (
                ["ocoreai", "connect", "claude-code", "--", "--dry-run"],
                .run(
                    harness: "claude-code", binaryName: "claude", dryRun: false,
                    harnessArgs: ["--dry-run"])
            ),
        ]
        for (args, want) in cases {
            let got = HarnessConnect.request(for: args)
            #expect(got == want, "args \(args) → \(got), not \(want)")
        }
    }

    @Test("`--` is parsed once: a second one stays the harness's verbatim text")
    func doubleDashStaysHarnessText() {
        let req = HarnessConnect.request(
            for: ["ocoreai", "connect", "claude-code", "--", "--", "x"])
        let want = HarnessConnect.Request.run(
            harness: "claude-code", binaryName: "claude", dryRun: false,
            harnessArgs: ["--", "x"])
        #expect(req == want)
    }

    @Test("detection returns the fixture's absolute path, in PATH order")
    func detection() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("connect-detect-\(UUID().uuidString)")
        let binA = scratch.appendingPathComponent("a")
        let binB = scratch.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: binA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let script = "#!/bin/sh\nexit 0\n"
        let first = binA.appendingPathComponent("claude")
        let second = binB.appendingPathComponent("claude")
        try script.write(to: first, atomically: true, encoding: .utf8)
        try script.write(to: second, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: first.path)
        // The second copy is NOT executable: a directory entry is not a match.
        let foundA = HarnessConnect.pathOfExecutable(
            named: "claude", inPath: "\(binA.path):\(binB.path)")
        #expect(foundA == first.path)
        let foundB = HarnessConnect.pathOfExecutable(
            named: "claude", inPath: "\(binB.path):\(binA.path)")
        #expect(foundB == first.path, "first executable hit must win, not first directory")
        let missing = HarnessConnect.pathOfExecutable(named: "claude", inPath: binB.path)
        #expect(missing == nil, "a non-executable file of that name is not a harness")
    }

    @Test("base URL follows the bridge's own two variables, defaults included")
    func baseURL() {
        let defaults = HarnessConnect.baseURL(from: [:])
        #expect(defaults == "http://127.0.0.1:8080")
        let both = HarnessConnect.baseURL(from: ["OCOREAI_HOST": "0.0.0.0", "OCOREAI_PORT": "9090"])
        #expect(both == "http://0.0.0.0:9090")
        // serve would not bind there either; the CLI must not invent a different default.
        let junkPort = HarnessConnect.baseURL(from: ["OCOREAI_PORT": "not-a-port"])
        #expect(junkPort == "http://127.0.0.1:8080")
    }

    @Test("the child's env adds the contract and overwrites nothing the caller brought")
    func launchEnvironment() {
        let fresh = HarnessConnect.environmentForLaunch(
            baseURL: "http://127.0.0.1:8080", incoming: ["PATH": "/usr/bin"])
        #expect(fresh["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:8080")
        #expect(fresh["ANTHROPIC_API_KEY"] == HarnessConnect.synthesizedAPIKey)
        let kept = HarnessConnect.environmentForLaunch(
            baseURL: "http://x:1", incoming: ["ANTHROPIC_API_KEY": "user-key"])
        #expect(kept["ANTHROPIC_API_KEY"] == "user-key")
        let empty = HarnessConnect.environmentForLaunch(
            baseURL: "http://x:1", incoming: ["ANTHROPIC_API_KEY": ""])
        #expect(empty["ANTHROPIC_API_KEY"] == HarnessConnect.synthesizedAPIKey)
    }

    @Test("the plan is four exact lines per server state — the user reads the whole verdict")
    func planLinesExact() {
        let args = HarnessConnect.Request.run(
            harness: "claude-code", binaryName: "claude", dryRun: false, harnessArgs: ["-p", "hi"])
        guard case .run(let token, let binary, _, let harnessArgs) = args else {
            Issue.record("fixture must be a run request")
            return
        }
        let ours = HarnessConnect.planLines(
            harnessToken: token, binaryName: binary, binaryPath: "/usr/local/bin/claude",
            server: .ours(baseURL: "http://127.0.0.1:8080"), harnessArgs: harnessArgs)
        let wantOurs = [
            "connect: claude-code",
            "harness: found /usr/local/bin/claude",
            "server:  ours at http://127.0.0.1:8080 (/v1/models answered)",
            "run:     ANTHROPIC_BASE_URL=http://127.0.0.1:8080 claude -p hi",
        ]
        #expect(ours == wantOurs)

        let dark = HarnessConnect.planLines(
            harnessToken: token, binaryName: binary, binaryPath: nil,
            server: .unreachable(baseURL: "http://127.0.0.1:1", reason: "refused"),
            harnessArgs: [])
        #expect(dark[1] == "harness: no claude on PATH — install it, or set PATH to where it lives")
        #expect(
            dark[2] == "server:  http://127.0.0.1:1 is not answering (refused)"
                + " — start it with `ocoreai serve`")
        #expect(dark[3] == "run:     ANTHROPIC_BASE_URL=http://127.0.0.1:1 claude")

        let other = HarnessConnect.planLines(
            harnessToken: token, binaryName: binary, binaryPath: "/usr/bin/claude",
            server: .notOurs(baseURL: "http://127.0.0.1:11434", httpStatus: 404),
            harnessArgs: [])
        #expect(
            other[2] == "server:  http://127.0.0.1:11434 answered 404,"
                + " not our /v1/models — that listener is not this bridge")
    }
}
