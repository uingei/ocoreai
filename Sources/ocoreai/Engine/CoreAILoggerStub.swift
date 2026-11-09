// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// MARK: - CLILogger stub (no-op for ocoreai)
// Signature mirrors upstream coreai-models CoreAIShared/Logger/Logger.swift:
//   public static func log(_ message: String, component: String? = nil, level: Int = 1)
// The three call shapes used across ocoreai (message-only, component:, level:)
// all match this single upstream declaration.
// Adjudicated: 7fd2063 — re-read 10-29: upstream CoreAIShared/Logger/Logger.swift:30 is still
// `log(_:component:level:)` with `level: Int = 1`, so the mirror holds; window = 0 by signature.
// Adjudicated: b1b9459 (#485 read 11-09: adds `warnOnce` over a process-global set — the stub
// mirrors only `log(_:component:level:)`, unchanged, and ocoreai has zero `warnOnce` callers
// (grep empty); row: coreai-fork-window-log.md § Window read 11-09)
enum CLILogger {
    static func isEnabled(at level: Int) -> Bool { false }
    static func log(_ message: @autoclosure () -> String, component: String? = nil, level: Int = 1)
    {}
}
