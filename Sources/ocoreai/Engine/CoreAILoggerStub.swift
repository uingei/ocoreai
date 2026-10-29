// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// MARK: - CLILogger stub (no-op for ocoreai)
// Signature mirrors upstream coreai-models CoreAIShared/Logger/Logger.swift:
//   public static func log(_ message: String, component: String? = nil, level: Int = 1)
// The three call shapes used across ocoreai (message-only, component:, level:)
// all match this single upstream declaration.
// Adjudicated: 7fd2063 — re-read 10-29: upstream CoreAIShared/Logger/Logger.swift:30 is still
// `log(_:component:level:)` with `level: Int = 1`, so the mirror holds; window = 0 by signature.
enum CLILogger {
    static func isEnabled(at level: Int) -> Bool { false }
    static func log(_ message: @autoclosure () -> String, component: String? = nil, level: Int = 1)
    {}
}
