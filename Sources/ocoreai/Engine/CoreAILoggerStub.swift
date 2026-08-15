// MARK: - CLILogger stub (no-op for ocoreai, matches upstream signature)
enum CLILogger {
    static var isEnabled: Bool { false }
    static func isEnabled(at level: Int) -> Bool { return isEnabled }
    static func log(
        _ message: @autoclosure () -> String, _ level: Int = 0, file: String = "", line: UInt = 0,
        function: String = ""
    ) {}
    static func log(_ message: @autoclosure () -> String, component: String) { log(message()) }
}
