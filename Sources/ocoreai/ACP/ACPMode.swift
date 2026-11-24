// Copyright © 2026 uingei.
// Licensed under MIT.
/// ACPMode.swift. Pure classifier for the `ocoreai acp` invocation.
///
/// Agent Client Protocol (ACP) makes this process a *coding agent* that an editor
/// (Zed, JetBrains, neovim, Sublime, Qt Creator, …) launches as its subprocess and drives over
/// stdio. The token is decided before anything boots, for the reason `HeadlessMode` carries:
/// a surface that cannot honour an argument has to say so before it starts.

import Foundation

enum ACPMode {
    /// Exact subcommand token that selects the ACP agent, parallel to `serve` and `connect`.
    static let acpCommand = "acp"

    enum Request: Equatable {
        /// `acp`, and nothing after it: speak ACP on stdio.
        case run
        /// `acp` plus one help token: print usage and exit 0.
        case help
        /// `acp` plus something it cannot honour, quoted exactly as it arrived.
        case refused(unrecognized: [String])
        /// Not an ACP invocation.
        case notACP
    }

    static func request(for args: [String]) -> Request {
        guard args.count >= 2, args[1] == acpCommand else { return .notACP }
        let trailing = Array(args.dropFirst(2))
        if trailing.isEmpty { return .run }
        if trailing.count == 1, CLIMode.helpTokens.contains(trailing[0]) { return .help }
        return .refused(unrecognized: trailing)
    }

    /// The version this build speaks. ACP's stable wire version is `1`; `2` is still Preview at
    /// the spec tree read 11-24, so a client asking for either other number gets a refusal that
    /// names what we speak rather than a session that silently means something else.
    static let protocolVersion = 1

    static func usageText() -> String {
        """
        ocoreai acp — run ocoreai as an Agent Client Protocol (ACP) agent on stdio.

        An ACP client launches this process, writes JSON-RPC messages to its stdin (one per
        line) and reads this process's JSON-RPC messages from stdout. Logs go to stderr; stdout
        carries protocol messages only. The engine boots windowless and the HTTP bridge stays off,
        so an editor-launched agent never collides with a `ocoreai serve` you already run.

        Speaks ACP protocol version \(protocolVersion): initialize, session/new, session/prompt,
        session/cancel, and session/request_permission (bridged to the same approval broker the
        GUI answers from). session/load, session/resume and session/list are not offered and say
        so; caller-supplied MCP servers are refused by name instead of being dropped quietly.

        The turn is handed the same tool surface the GUI hands (`settings.toolSurface.curation`),
        and no instruction corpus. ACP clients normally also offer to install agents from the ACP
        Registry; this product cannot be listed there, because a registry binary entry must cover
        macOS, Linux and Windows and this engine ships for Apple silicon only.
        """
    }
}
