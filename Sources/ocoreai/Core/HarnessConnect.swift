// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
import Foundation

/// `ocoreai connect` — hand an installed coding harness this server's wire.
///
/// The field's shape (`docs/agent/comparator-consensus.md` § The harness side): nine of twelve
/// serving trees ship detection plus a config writer. Launching instead of writing is the higher
/// rung under "respect the person": the child process is the only thing the contract touches, and
/// its exit undoes it — no user file is merged, so the two ways a naive merge eats the user's own
/// entries (the failure `Rapid-MLX` documents before writing its code) cannot occur here.
///
/// The contract itself is the one probe 53 measured green end-to-end: `ANTHROPIC_BASE_URL` set to
/// our base, a key synthesized only when the caller carries none. The server counts as ours only
/// after `/v1/models` answers in our shape — a listener nobody probed is not "ours".
enum HarnessConnect {
    /// Exact subcommand token, parallel to `HeadlessMode.serveCommand`.
    static let connectCommand = "connect"
    static let dryRunFlag = "--dry-run"

    /// Our token → the binary to find on PATH. Only listed names are promised; anything else is
    /// refused named — argv owes the same honesty rule as `/v1/*`.
    static let harnesses: [String: String] = ["claude-code": "claude"]

    /// Placeholder bearer for a caller with no key: the bridge itself is unauthenticated by
    /// default, and some harnesses refuse to build a request without any key at all.
    static let synthesizedAPIKey = "ocoreai-local"

    /// EX_UNAVAILABLE — the subject of the command is absent (no binary, no bridge). 64 is
    /// reserved for the classifier refusing tokens before anything runs.
    static let unavailableExit: Int32 = 69

    enum Request: Equatable {
        case notConnect
        case help
        case run(harness: String, binaryName: String, dryRun: Bool, harnessArgs: [String])
        case noHarness
        case unknownHarness(String)
        case refused(unrecognized: [String])
    }

    /// Pure classifier, the discipline of `HeadlessMode.serveRequest`: what happens is decided
    /// before anything boots. One `--` splits the line permanently: everything after it belongs
    /// to the harness verbatim, so a harness flag can never be mistaken for one of ours.
    static func request(for args: [String]) -> Request {
        guard args.count >= 2, args[1] == connectCommand else { return .notConnect }
        let trailing = Array(args.dropFirst(2))
        let split = trailing.firstIndex(of: "--") ?? trailing.count
        let control = Array(trailing[..<split])
        let harnessArgs = Array(trailing.dropFirst(split + 1))
        if control.isEmpty { return .noHarness }
        if control.count == 1, CLIMode.helpTokens.contains(control[0]) { return .help }
        var dryRun = false
        var harness: String?
        var unrecognized: [String] = []
        for token in control {
            if token == dryRunFlag {
                dryRun = true
                continue
            }
            if token.hasPrefix("-") {
                unrecognized.append(token)
                continue
            }
            if harness == nil { harness = token } else { unrecognized.append(token) }
        }
        if !unrecognized.isEmpty { return .refused(unrecognized: unrecognized) }
        guard let name = harness else { return .noHarness }
        guard let binaryName = harnesses[name] else { return .unknownHarness(name) }
        return .run(harness: name, binaryName: binaryName, dryRun: dryRun, harnessArgs: harnessArgs)
    }

    /// Absolute path of the first executable of this name on a PATH string, in PATH order — a
    /// different search order would report a binary the user's own `which` denies.
    static func pathOfExecutable(named name: String, inPath path: String) -> String? {
        for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    enum ServerStatus: Equatable {
        case ours(baseURL: String)
        case unreachable(baseURL: String, reason: String)
        case notOurs(baseURL: String, httpStatus: Int)
    }

    /// The bridge's own address rules — the same two variables `serve` binds with.
    static func baseURL(from env: [String: String]) -> String {
        let host = env["OCOREAI_HOST"].flatMap { $0.isEmpty ? nil : $0 } ?? "127.0.0.1"
        let port = env["OCOREAI_PORT"].flatMap { Int($0) } ?? 8080
        return "http://\(host):\(port)"
    }

    /// One bounded GET at `/v1/models`; our answer is 200 with a `data` array. The request's own
    /// timeout is the deadline, so a silent listener can never park the CLI.
    static func probeServer(baseURL: String, timeout: TimeInterval = 3) -> ServerStatus {
        guard let url = URL(string: baseURL + "/v1/models") else {
            return .unreachable(baseURL: baseURL, reason: "malformed base URL \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let gate = DispatchSemaphore(value: 0)
        var statusCode = 0
        var body = Data()
        var failure: String?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { gate.signal() }
            if let error {
                failure = error.localizedDescription
                return
            }
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            body = data ?? Data()
        }
        task.resume()
        if gate.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            return .unreachable(baseURL: baseURL, reason: "no answer within \(Int(timeout))s")
        }
        if let failure { return .unreachable(baseURL: baseURL, reason: failure) }
        let parsed = try? JSONSerialization.jsonObject(with: body)
        let isOurs = statusCode == 200 && (parsed as? [String: Any])?["data"] is [Any]
        if isOurs { return .ours(baseURL: baseURL) }
        return .notOurs(baseURL: baseURL, httpStatus: statusCode)
    }

    /// The printed plan, one line per subject, so the user reads detection, trust and the exact
    /// run line before anything execs. Pure: tests pin it byte-for-byte.
    static func planLines(
        harnessToken: String,
        binaryName: String,
        binaryPath: String?,
        server: ServerStatus,
        harnessArgs: [String]
    ) -> [String] {
        let serverLine: String
        let base: String
        switch server {
        case .ours(let url):
            base = url
            serverLine = "server:  ours at \(url) (/v1/models answered)"
        case .unreachable(let url, let reason):
            base = url
            serverLine =
                "server:  \(url) is not answering (\(reason)) — start it with `ocoreai serve`"
        case .notOurs(let url, let status):
            base = url
            serverLine =
                "server:  \(url) answered \(status), not our /v1/models — that listener is not this bridge"
        }
        let args = harnessArgs.isEmpty ? "" : " \(harnessArgs.joined(separator: " "))"
        return [
            "connect: \(harnessToken)",
            "harness: \(binaryPath.map { "found \($0)" } ?? "no \(binaryName) on PATH — install it, or set PATH to where it lives")",
            serverLine,
            "run:     ANTHROPIC_BASE_URL=\(base) \(binaryName)\(args)",
        ]
    }

    /// The child's environment: inherited plus the measured contract. A caller-supplied key is
    /// kept — severing a real credential is probe 53's job (it must prove one possible source),
    /// not connect's, where the base URL alone already routes every request here.
    static func environmentForLaunch(baseURL: String, incoming: [String: String]) -> [String:
        String]
    {
        var env = incoming
        env["ANTHROPIC_BASE_URL"] = baseURL
        let existingKey = env["ANTHROPIC_API_KEY"] ?? ""
        if existingKey.isEmpty {
            env["ANTHROPIC_API_KEY"] = synthesizedAPIKey
        }
        return env
    }

    /// Detect → probe → print | exec. Prints land on stdout: this is the CLI surface `print`
    /// belongs to. Returns the exit code; the caller exits with it unchanged.
    static func run(harness token: String, binaryName: String, dryRun: Bool, harnessArgs: [String])
        -> Int32
    {
        #if os(macOS)
        let env = ProcessInfo.processInfo.environment
        let binaryPath = pathOfExecutable(named: binaryName, inPath: env["PATH"] ?? "/usr/bin:/bin")
        let server = probeServer(baseURL: baseURL(from: env))
        for line in planLines(
            harnessToken: token, binaryName: binaryName, binaryPath: binaryPath,
            server: server, harnessArgs: harnessArgs)
        {
            print(line)
        }
        // A dry run reports a plan, not a reservation: it answers the question even when the
        // subjects are absent, because "what would run" does not depend on them being up.
        if dryRun { return 0 }
        // The plan above already names each absent subject with its remedy; stderr carries the
        // verdict and points there rather than keeping a second copy of every message.
        guard let found = binaryPath else {
            FileHandle.standardError.write(
                Data(
                    "ocoreai connect: cannot launch — the harness line above names what is missing\n"
                        .utf8))
            return unavailableExit
        }
        guard case .ours(let base) = server else {
            FileHandle.standardError.write(
                Data("ocoreai connect: cannot launch — the server line above names why\n".utf8))
            return unavailableExit
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: found)
        process.arguments = harnessArgs
        process.environment = environmentForLaunch(baseURL: base, incoming: env)
        do {
            try process.run()
        } catch {
            // The cause is the OS's refusal, not a symptom: permission, arch, or the binary
            // vanished between detect and exec — all three need different remedies.
            FileHandle.standardError.write(
                Data(
                    "ocoreai connect: exec of \(found) failed: \(error.localizedDescription)\n".utf8
                ))
            return unavailableExit
        }
        process.waitUntilExit()
        return process.terminationStatus
        #else
        // Same channel as the macOS plan lines, written the way the file's other output goes:
        // the print-site ceiling stays the number a reviewer can re-grep.
        FileHandle.standardOutput.write(
            Data("connect: this platform launches no harnesses\n".utf8))
        return unavailableExit
        #endif
    }

    static func usageText() -> String {
        """
        ocoreai connect <harness> [--dry-run] [-- <harness args…>]
          Launch an installed coding agent with ANTHROPIC_BASE_URL pointed at this
          bridge (OCOREAI_HOST/OCOREAI_PORT, default http://127.0.0.1:8080). Nothing
          is written to any config file; the child's exit is the whole change.
          --dry-run prints the plan and exits 0 without exec'ing anything.
          Supported harnesses: \(harnesses.keys.sorted().joined(separator: ", "))
        """
    }
}
