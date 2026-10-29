// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// CLIMode.swift — pure classification of informational CLI invocations.
///
/// ### Why this exists (proven gap, live-tested 2026-10-11)
/// `ocoreai --version` booted the FULL engine (crash handlers, SQLite,
/// memory tracker) and never answered — the process only died because the
/// harness killed it. Every other CLI tool answers `--version`/`--help`
/// instantly with exit 0; on the harness/terminal surface that IS the
/// product. This is the same first-principles fix as HeadlessServer:
/// arguments were parsed nowhere — one exact-token classifier closes it.
///
/// ### Rules (fail-safe, mirrors HeadlessMode)
///   • `args[0]` is argv[0] — ignored by definition.
///   • Only the FIRST token after argv[0] is inspected; leading flags are
///     never skipped past (`serve --version` stays headless, `--version
///     serve` is answered as version — the flag is the first token).
///   • Nothing matched → nil → caller's GUI/serve routing is untouched.
/// The report strings are assembled from AppInfo (the single version truth)
/// and the env-var names actually consumed by the bridge — never a
/// hardcoded release number, never a flag that does nothing.
import Foundation

/// Pure CLI informational-token classifier. No I/O, no globals.
enum CLIMode {
    /// Tokens that print the version and exit 0.
    static let versionTokens: Set<String> = ["--version", "-v"]
    /// Tokens that print usage and exit 0.
    static let helpTokens: Set<String> = ["--help", "-h", "help"]
    /// Tokens that print the OpenAPI 3.1 contract and exit 0. This is how `make openapi`
    /// regenerates the committed artefact: the file a stranger reads must be produced by the
    /// binary that serves the routes, not typed beside them.
    static let openAPITokens: Set<String> = ["--openapi", "--print-openapi"]

    /// The exact usage text — every line describes real behavior:
    /// `serve` is the only subcommand; port/host/API keys are env-configured
    /// (verified against BridgeConfig consumption, not aspirations).
    static func usageText(version: String = AppInfo.shortVersion) -> String {
        """
        ocoreai \(version) — an agent for open models, natively local.

        USAGE:
          ocoreai                      Launch the macOS GUI app.
          ocoreai serve              Headless engine + HTTP bridge (default
                                     127.0.0.1:8080) — no window; SIGTERM or
                                     stdin-EOF shuts it down gracefully.

        CONFIGURATION (environment):
          OCOREAI_HOST / OCOREAI_PORT      Bridge bind address (serve).
          OCOREAI_ENABLE_HTTP=1            Enable the HTTP bridge in the GUI app.
          OCOREAI_API_KEYS                 Require bearer auth on the bridge.
          OCOREAI_DATA_DIR                 Override app data directory.
          OCOREAI_MODELS_DIR               Override model weights directory.

        FLAGS:
          -v, --version                  Print version and exit.
          -h, --help, help               Print this message and exit.
          --openapi                      Print the OpenAPI 3.1 contract (JSON) and exit.
        """
    }

    /// Informational report to print-and-exit, or nil (fall through to
    /// GUI/serve routing unchanged). The OpenAPI branch exists so the artefact has an exit
    /// that boots nothing — one print site is also the ceiling this surface agrees to.
    static func informationalReport(
        for args: [String],
        shortVersion: String = AppInfo.shortVersion
    ) -> String? {
        guard args.count >= 2 else { return nil }
        let token = args[1]
        if versionTokens.contains(token) { return "ocoreai \(shortVersion)" }
        if helpTokens.contains(token) { return usageText(version: shortVersion) }
        if openAPITokens.contains(token) { return OpenAPIDocument.render() }
        return nil
    }
}
