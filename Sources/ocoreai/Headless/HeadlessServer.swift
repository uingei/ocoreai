// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HeadlessServer.swift — real headless `ocoreai serve` entry.
///
/// ### Why this exists (proven root cause)
/// The engine's only cold-boot trigger was `AppState.initialize()` — a
/// SwiftUI View lifecycle hook. A process launched without a WindowServer
/// session never instantiates the `WindowGroup`, so `OcoreaiEngine.start()`
/// never ran and the HTTP bridge never bound `127.0.0.1:8080`. `serve` was
/// a phantom argument: nothing parsed `CommandLine.arguments` at all.
///
/// ### This file
/// `HeadlessMode` is a pure argument classifier (unit-testable, no I/O).
/// `HeadlessServer.run()` boots the engine on a windowless AppKit runloop:
///   • `setActivationPolicy(.prohibited)` — no Dock icon, no menus.
///   • `registerGlobalCrashHandlers()` — same crash surface as the GUI.
///   • SIGTERM → graceful shutdown (daemon semantics). SIGINT keeps the
///     default terminal ^C behavior deliberately (signal() disposition is
///     untouched).
///   • stdin EOF → graceful shutdown (agent-harness semantics: the harness
///     closes the pipe to stop the server). Stdin monitoring is only
///     installed for pipes and TTYs — a daemon launched with stdin at
///     `/dev/null` (or closed) must NOT die at boot.
///   • Shutdown drains via `OcoreaiEngine.shared.stop()` (30s bounded drain)
///     then `NSApplication.terminate(nil)`; `NSApp.stop()` is NEVER called
///     (main-thread assertion trap). A detached watchdog thread enforces a
///     hard ~35s ceiling with `_exit(0)` if the AppKit terminate path ever
///     stalls, so the drain never hangs a daemon forever.
///
/// The default (no `serve`) branch in `OcoreaiApp.main()` is byte-identical
/// to the pre-existing GUI path — this file only adds, never re-routes it.

import Foundation
import Logging

#if os(macOS)
import AppKit
#endif

// MARK: - Entry-point selection (pure)

/// Which main() branch the process takes. Pure decision, pinned by tests.
enum EntryPoint: Equatable {
    /// Windowless engine + HTTP bridge (`ocoreai serve`).
    case headless
    /// SwiftUI app (default, unchanged behavior).
    case gui
}

/// Pure argument classifier for the headless `serve` subcommand.
/// No I/O, no globals — safe to unit-test exhaustively.
enum HeadlessMode {
    /// Exact subcommand token that selects headless mode.
    static let serveCommand = "serve"

    /// Decide whether the invocation selects headless serve mode.
    ///
    /// Rules (exhaustively pinned by `HeadlessServeModeTests`):
    ///   • `args[0]` is argv[0] (the binary path) — ignored by definition.
    ///   • The FIRST argument after argv[0] must be exactly `"serve"` → true.
    ///   • Everything else → false (fail-safe default = GUI): no arguments,
    ///     near-miss tokens (`"server"`), and flags before the token
    ///     (e.g. `--help serve`) — leading flags are never skipped, so a
    ///     flag-first invocation stays GUI.
    ///   • Trailing flags after `serve` (e.g. `serve --port 9090`) select
    ///     headless; those flags are documented but not yet consumed
    ///     (`OCOREAI_PORT`/`OCOREAI_HOST` env vars configure the bridge).
    static func isServeInvocation(_ args: [String]) -> Bool {
        guard args.count >= 2 else { return false }
        return args[1] == serveCommand
    }

    /// Entry-point branch selection — GUI unless `serve` selects headless.
    static func entryPoint(for args: [String]) -> EntryPoint {
        isServeInvocation(args) ? .headless : .gui
    }
}

// MARK: - Headless runtime host

/// Nonisolated facade so `OcoreaiApp.main()` (nonisolated process entry)
/// can dispatch identically on every platform.
enum HeadlessServer {
    /// Run the headless serve loop. Blocks until shutdown.
    static func run() {
        #if os(macOS)
        // Process entry ⇒ we are on the main thread; AppKit requires the
        // MainActor isolation it does not statically know about.
        MainActor.assumeIsolated {
            HeadlessRuntime.run()
        }
        #else
        // iOS/iPadOS have no headless daemon story — keep GUI behavior.
        OcoreaiGUIApp.main()
        #endif
    }
}

#if os(macOS)
/// Windowless AppKit host for `ocoreai serve`. MainActor by design:
/// `OcoreaiEngine` is MainActor-isolated and `NSApplication.run()`
/// pumps the main runloop that services MainActor work.
@MainActor
enum HeadlessRuntime {
    private static let logger = Logger(label: "ocoreai.headless")

    /// Retained so the dispatch sources stay live for process lifetime.
    private static var signalSources: [DispatchSourceSignal] = []
    private static var stdinHandle: FileHandle?
    private static var shutdownStarted = false

    /// Hard ceiling for the shutdown path (engine drain is 30s-bounded;
    /// +5s grace before the watchdog force-exits).
    static let shutdownCeilingSeconds: TimeInterval = 35

    /// Boot engine + bridge on a windowless runloop. Blocks until the
    /// AppKit terminate path (triggered by SIGTERM / stdin EOF) returns.
    static func run() {
        NSLog("[ocoreai] headless serve starting (pid \(getpid()))")
        // No Dock tile, no menu bar, no windows — daemon semantics.
        NSApplication.shared.setActivationPolicy(.prohibited)

        // Same crash surface as the GUI path (AppDelegate does this).
        registerGlobalCrashHandlers()

        // Mirror the HF Hub environment knobs the GUI delegate sets —
        // xet's swallowed exceptions and mirror opt-in apply headless too.
        setenv("HF_HUB_DISABLE_XET", "1", 1)
        if let mirror = ProcessInfo.processInfo.environment["HF_ENDPOINT_MIRROR"] {
            setenv("HF_ENDPOINT", mirror, 1)
        }

        installShutdownSignal()
        installStdinWatcher()

        Task {
            await OcoreaiEngine.shared.start()
            let state = OcoreaiEngine.shared.lifecycleState.rawValue
            let host = ProcessInfo.processInfo.environment["OCOREAI_HOST"] ?? "127.0.0.1"
            let port = ProcessInfo.processInfo.environment["OCOREAI_PORT"] ?? "8080"
            print(
                "ocoreai headless — lifecycle: \(state), bridge: \(host):\(port)")
            fflush(stdout)
        }

        // Pump the main runloop — MainActor work (engine start, HTTP
        // bridge, gauge tasks) proceeds on this thread. Returns when
        // NSApplication.terminate(_:) completes.
        NSApplication.shared.run()
        NSLog("[ocoreai] headless run loop exited")
    }

    // MARK: - Shutdown

    /// One-shot graceful shutdown: drain engine, then terminate AppKit.
    /// NEVER calls NSApp.stop() (main-thread assertion trap).
    static func beginShutdown(reason: String) {
        guard !shutdownStarted else { return }
        shutdownStarted = true
        logger.info("Shutdown signal received (\(reason)) — draining engine")
        NSLog("[ocoreai] Shutdown signal received (\(reason))")
        fflush(stdout)

        // Hard ceiling: terminate() should land well inside the engine's
        // own 30s bounded drain. If the AppKit termination path ever
        // stalls, force-exit — a daemon must never hang on shutdown.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: shutdownCeilingSeconds)
            NSLog("[ocoreai] shutdown ceiling exceeded — force exit")
            fflush(stdout)
            _exit(0)
        }

        Task { @MainActor in
            await OcoreaiEngine.shared.stop()
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Signal + stdin watchers

    /// SIGTERM → graceful shutdown (launchd/`kill` semantics). SIGINT is
    /// deliberately left at default disposition (terminal ^C).
    static func installShutdownSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // .main queue ⇒ main thread ⇒ MainActor assumption is sound.
            MainActor.assumeIsolated {
                beginShutdown(reason: "SIGTERM")
            }
        }
        source.resume()
        signalSources.append(source)
    }

    /// stdin EOF → graceful shutdown (agent-harness convention). Only
    /// installed for pipes and TTYs: daemons started with stdin already
    /// at /dev/null or closed must not interpret that as stop.
    private static func installStdinWatcher() {
        let stdin = FileHandle.standardInput
        var st = stat()
        guard fstat(stdin.fileDescriptor, &st) == 0 else { return }
        let isPipe = (st.st_mode & S_IFMT) == S_IFIFO
        guard isPipe || isatty(stdin.fileDescriptor) != 0 else {
            logger.debug("stdin not a pipe/tty — EOF watcher skipped")
            return
        }
        stdinHandle = stdin
        stdin.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        beginShutdown(reason: "stdin EOF")
                    }
                }
            }
        }
    }
}
#endif
