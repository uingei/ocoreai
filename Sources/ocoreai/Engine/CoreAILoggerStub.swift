// MARK: - CLILogger stub (no-op for ocoreai)
// Signature mirrors upstream coreai-models CoreAIShared/Logger/Logger.swift:
//   public static func log(_ message: String, component: String? = nil, level: Int = 1)
// The three call shapes used across ocoreai (message-only, component:, level:)
// all match this single upstream declaration.
enum CLILogger {
    static func isEnabled(at level: Int) -> Bool { false }
    static func log(_ message: @autoclosure () -> String, component: String? = nil, level: Int = 1)
    {}
}
