// Copyright © 2026 uigei@163.com.
// Licensed under MIT.
/// GlobalCrashHandler — Uncaught exception + POSIX signal handler + crash log persistence
///
/// Purpose: when the inference engine or any subsystem crashes, we write
/// a structured log to `~/Library/Application Support/ocoreai/logs/` before exit.
///
/// Thread safety: crash handlers fire on the crash thread (arbitrary).
/// All Foundation calls here are thread-safe on macOS.  We use
/// `@unchecked Sendable` on the class because state mutations only happen
/// during registration (single-threaded startup) and the handlers are
/// fire-and-forget with no shared mutable state afterwards.

import Foundation

#if os(macOS)
import AppKit

// MARK: - Public entry

/// Call once at app startup.
public func registerGlobalCrashHandlers() {
	_ = CrashHandler.register()
	NSLog("[ocoreai] Global crash handlers registered")
}

// MARK: - Crash Handler
private final class CrashHandler: @unchecked Sendable {
	/// `@unchecked Sendable` is safe: all static state is immutable after registration,
	/// registration happens once on startup (single-threaded), and handlers are fire-and-forget.

	// MARK: - Register

	@discardableResult
	static func register() -> Bool {
		installUncaughtExceptionHandler()
		return installSignalHandlers()
	}

	// MARK: - NSUncaughtExceptionHandler

	private static func installUncaughtExceptionHandler() {
		NSSetUncaughtExceptionHandler(exceptionHandler)
	}

	private static let exceptionHandler: @convention(c) (NSException?) -> Void = { exception in
		writeCrash(kind: "uncaught_exception", info: exceptionInfo(exception))
		if let old = NSGetUncaughtExceptionHandler() {
			// Fallback: create a dummy exception so the OS reporter has something to print
			old(exception ?? NSException(name: NSExceptionName("CrashException"),
			                            reason: "Unknown crash", userInfo: nil))
		}
		exit(1) // already crashing — no need to go through
	}

	private static func exceptionInfo(_ e: NSException?) -> String {
		var lines: [String] = []
		if let name = e?.name {
			lines.append("Name: \(name.rawValue)")
		}
		if let reason = e?.reason {
			lines.append("Reason: \(reason)")
		}
		if let userInfo = e?.userInfo, !userInfo.isEmpty {
			lines.append("UserInfo: \(userInfo)")
		}
		if let callStack = e?.callStackReturnAddresses {
			lines.append("CallStack: \(callStack.map { String(format: "0x%lx", $0) })")
		}
		return lines.joined(separator: "; ")
	}

	// MARK: - POSIX Signal Handlers

	private static let crashSignals: [(Int32, String)] = [
		(SIGSEGV, "SIGSEGV"),
		(SIGABRT, "SIGABRT"),
		(SIGBUS, "SIGBUS"),
		(SIGILL, "SIGILL"),
		(SIGFPE, "SIGFPE"),
	]

	private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
		let sigName = signalName(sig)
		writeCrash(kind: "signal", info: "Signal \(sig) (\(sigName)) received")
		abort() // re-raise so OS generates a crash report
	}

	private static func signalName(_ sig: Int32) -> String {
		switch sig {
		case SIGSEGV: return "SIGSEGV"
		case SIGABRT: return "SIGABRT"
		case SIGBUS: return "SIGBUS"
		case SIGILL: return "SIGILL"
		case SIGFPE: return "SIGFPE"
		default: return "UNKNOWN(\(sig))"
		}
	}

	@discardableResult
	private static func installSignalHandlers() -> Bool {
		var allOk = true
		for (sig, _) in crashSignals {
			let old = signal(sig, signalHandler)
			if old == nil {
				allOk = false
			}
		}
		return allOk
	}

	// MARK: - Crash log persistence

	/// Writes `~/Library/Application Support/ocoreai/logs/crash-<timestamp>.log`
	/// Thread-safe on macOS (FileManager, NSFileHandle, etc. are all safe).
	private static func writeCrash(kind: String, info: String) {
		guard let basePath = FileManager.default.urls(
			for: .applicationSupportDirectory, in: .userDomainMask
		).first else { return }

		let logsDir = basePath.appendingPathComponent("ocoreai/logs", isDirectory: true)

		do {
			try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
		} catch {
			return // best-effort only
		}

		let formatter = ISO8601DateFormatter()
		let timestamp = formatter.string(from: Date())
		let filename = "crash-\(timestamp)-\(ProcessInfo.processInfo.processIdentifier).log"
		let fileURL = logsDir.appendingPathComponent(filename)

		var lines: [String] = []
		lines.append("=== ocoreai Crash Log ===")
		lines.append("Kind: \(kind)")
		lines.append("Date: \(formatter.string(from: Date()))")
		lines.append("PID: \(ProcessInfo.processInfo.processIdentifier)")
		lines.append("OS: macos-\(ProcessInfo.processInfo.operatingSystemVersionString)")
		lines.append("Info: \(info)")
		lines.append("")

		// Capture system memory info
		var memSize: Int64 = 0
		var size = MemoryLayout<Int64>.stride
		sysctlbyname("hw.memsize", &memSize, &size, nil, 0)
		lines.append("PhysicalMemory: \(memSize / 1024 / 1024) MB")

		// Thread dump from Foundation
		let threadDump = Thread.callStackSymbols
		if !threadDump.isEmpty {
			lines.append("=== Thread Dump ===")
			lines.append(contentsOf: threadDump)
		}

		let content = lines.joined(separator: "\n")

		do {
			try content.write(to: fileURL, atomically: true, encoding: .utf8)
			fputs("\(content)\n", stderr)
		} catch {
			// silent — we're already crashing
		}
	}
}

#endif

#if os(iOS) || os(watchOS) || os(tvOS)

public func registerGlobalCrashHandlers() {
	// iOS/tvOS/watchOS: no POSIX signal handlers (system handles it)
	let cHandler: @convention(c) (NSException?) -> Void = { exception in
		guard let e = exception else { return }
		let log = "Exception: \(e.name.rawValue), Reason: \(e.reason ?? "unknown")"
		fputs("\(log)\n", stderr)
	}
	NSSetUncaughtExceptionHandler(cHandler)
}

#endif