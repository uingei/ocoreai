// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HearingEngineProbe.swift — the process mechanics behind ``HearingReadiness``.
///
/// Split out of `HearingReadiness.swift` on purpose: that file is the *judgment* (what the
/// measured axes mean, and what the surface may therefore claim), this one is the *plumbing*
/// (spawning a throwaway copy of this binary and reading how it died). Two things that change
/// for different reasons, and a reader should not have to hold both to answer either.
///
/// Why the child process exists at all: on this host `SpeechAnalyzer.analyzeSequence(from:)`
/// dies with SIGTRAP instead of throwing, so no `catch` in the parent can contain it — see
/// the crash-report evidence in `HearingReadiness.swift`'s header and CHANGELOG 10-15.

import Foundation
import Logging

// MARK: - Self probe

#if os(macOS)
/// Runs the Speech analysis in a **child** process so a framework trap cannot reach the app.
enum HearingEngineProbe {
    // The flag and the environment marker are one home on purpose: they are the protocol
    // between two copies of this binary, and they live on ``HearingSelfProbe`` (the side that
    // parses them, and the side that is not macOS-gated because `Application.swift` dispatches
    // to it on every platform). Re-declaring them here would be a second truth to drift.

    /// Synthetic fixture: 16 kHz mono PCM16 — a 440 Hz burst, then silence. Deterministic,
    /// no microphone, no network, no TCC: the probe asks only "does the engine survive a
    /// pass", so it must not depend on the permission whose state it is characterizing.
    ///
    /// A tone, not pure silence: a silent file can be short-circuited before the encoder
    /// runs, which would let the probe pass having exercised nothing.
    static func syntheticWav(seconds: Double = 0.9) -> Data {
        let sampleRate = 16_000
        let totalSamples = max(1, Int(seconds * Double(sampleRate)))
        let burstSamples = min(totalSamples / 2, Int(0.35 * Double(sampleRate)))
        var pcm = [Int16](repeating: 0, count: totalSamples)
        for index in 0 ..< burstSamples {
            let phase = Double(index) / Double(sampleRate) * 2.0 * .pi * 440.0
            pcm[index] = Int16(max(-12_000, min(12_000, sin(phase) * 12_000.0)))
        }
        var out = Data()
        func ascii(_ text: String) { out.append(contentsOf: text.utf8) }
        func u32(_ value: Int) {
            for shift in [0, 8, 16, 24] {
                out.append(UInt8(truncatingIfNeeded: (value >> shift) & 0xff))
            }
        }
        func u16(_ value: Int) {
            for shift in [0, 8] {
                out.append(UInt8(truncatingIfNeeded: (value >> shift) & 0xff))
            }
        }
        let byteCount = pcm.count * MemoryLayout<Int16>.size
        ascii("RIFF")
        u32(36 + byteCount)
        ascii("WAVEfmt ")
        u32(16)
        u16(1)  // PCM
        u16(1)  // mono
        u32(sampleRate)
        u32(sampleRate * 2)  // byte rate
        u16(2)  // block align
        u16(16)  // bits per sample
        ascii("data")
        u32(byteCount)
        pcm.withUnsafeBytes { body in out.append(contentsOf: body) }
        return out
    }

    /// Write the fixture to a temp file the child can read; nil when the write fails, which
    /// the caller reports as `unavailable` rather than as a pass.
    static func writeFixture() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai-hearing-probe-\(UUID().uuidString.prefix(8)).wav")
        do {
            try syntheticWav().write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// The name the only permitted re-exec target has: `swift build` emits `ocoreai`, and
    /// `scripts/build-app.sh` sets `CFBundleExecutable` to the same word.
    static let productName = "ocoreai"

    /// What this process *would* re-exec: the bundle's executable, else `argv[0]`.
    ///
    /// `Bundle.main.executableURL` covers the .app; `argv[0]` covers `swift run`, a bare SPM
    /// binary and a shell invocation.
    static func candidateExecutable() -> URL? {
        if let url = Bundle.main.executableURL,
            FileManager.default.isExecutableFile(atPath: url.path)
        {
            return url
        }
        if let argv0 = CommandLine.arguments.first, argv0.hasPrefix("/"),
            FileManager.default.isExecutableFile(atPath: argv0)
        {
            return URL(fileURLWithPath: argv0)
        }
        return nil
    }

    /// The re-exec target: this binary, and **only** this binary.
    ///
    /// The guard is a whitelist on purpose. The alternative — enumerate the hosts that must
    /// not be re-exec'd — was measured failing here on 10-15: under `swift test`,
    /// `Bundle.main` is `/Library/Developer/CommandLineTools/usr/libexec/swift/pm` and no
    /// XCTest environment key is set, so an enumeration concluded "not a test host" and the
    /// suite spawned a child of the test runner. A probe that can multiply on the machine it
    /// is measuring is not a probe. Anything that is not the product binary resolves to nil,
    /// which the seam reports as `unavailable` — "cannot measure here", never `ok`.
    static func selfExecutable() -> URL? {
        guard let candidate = candidateExecutable() else { return nil }
        return candidate.deletingPathExtension().lastPathComponent == productName
            ? candidate
            : nil
    }

    /// Whether this process is the product binary — the only one allowed to re-exec itself.
    static var isProductBinary: Bool { selfExecutable() != nil }

    /// Whether this process is a test host.
    ///
    /// Second belt, not the first: the identity rule in ``selfExecutable()`` is what holds
    /// when a runner nobody predicted appears, but a host that announces itself should be
    /// believed too, and `OCOREAI_DISABLE_ASR_PROBE` is the operator's kill switch.
    /// `HearingHonestyTests` asserts one of the two is live inside the suite.
    static var isInTestRunner: Bool {
        if Bundle.main.bundlePath.hasSuffix(".xctest") { return true }
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) { return true }
        let environment = ProcessInfo.processInfo.environment
        if environment.keys.contains("XCTestConfigurationFilePath")
            || environment.keys.contains("OCOREAI_DISABLE_ASR_PROBE")
        {
            return true
        }
        return !isProductBinary
    }

    /// Spawn self in probe mode, bounded by `timeout`, and classify how it ended.
    ///
    /// The child's stdout goes to a temp file rather than a pipe: the parent must never
    /// block on a pipe it forgot to drain, and the whole point of the probe is that it
    /// cannot be allowed to hang the process that started it.
    static func run(timeout: TimeInterval) async -> EngineProbeOutcome {
        guard !isInTestRunner else { return .unavailable }
        guard let executable = selfExecutable() else { return .unavailable }
        guard let fixture = writeFixture() else { return .unavailable }
        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai-hearing-probe-\(UUID().uuidString.prefix(8)).json")
        FileManager.default.createFile(atPath: outPath.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: outPath)
        }
        // Nothing here blocks. `DispatchSemaphore.wait` is unavailable from an async context
        // on this SDK (measured: "Await a Task handle instead"), and parking a cooperative
        // pool thread for the 20 s probe budget would be wrong regardless — so the wait is
        // Foundation's own `terminationHandler`, and the deadline is a sleeping task racing
        // it. Two things can land, so exactly-once is mandatory: the same shape the camera
        // capture fix settled on (`cdd4cc7` — retained object, one `fire()`, one deadline).
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<EngineProbeOutcome, Never>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = [HearingSelfProbe.flag, fixture.path]
            var env = ProcessInfo.processInfo.environment
            env[HearingSelfProbe.environmentMarker] = "1"
            process.environment = env
            if let handle = FileHandle(forWritingAtPath: outPath.path) {
                process.standardOutput = handle
                process.standardError = handle
            } else {
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
            }
            let landing = ProbeLanding { outcome in continuation.resume(returning: outcome) }
            process.terminationHandler = { finished in
                let code = finished.terminationStatus
                let exitedCleanly = finished.terminationReason == .exit
                let outcome = EngineProbeOutcome.classify(
                    exitCode: exitedCleanly ? code : nil,
                    signal: exitedCleanly ? nil : code,
                    timedOut: false)
                // Read it while the child is finished and the file still exists: the child's
                // own lines say *where* it died — `pre-analysis` present with no `final` line
                // means the trap was inside the analysis pass. Exit status alone only says that
                // it died, which is why this file was being created, written, and deleted
                // unread.
                logProbeOutcome(outcome, childOutput: readReport(outPath))
                landing.childReported()
                landing.fire(outcome)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: .unavailable)
                return
            }
            let pid = process.processIdentifier
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                guard !landing.childHasReported else { return }
                // We are ending this one, so the outcome is *our* deadline rather than the
                // child's signal: `timedOut` outranks everything in `classify`, so a kill we
                // initiated can never be misreported as an engine fault.
                landing.fire(.timeout)
                logProbeOutcome(.timeout, childOutput: readReport(outPath))
                // `terminate()` is the API this SDK has (`Process.kill()` does not exist at
                // the macos14 deployment target — measured, it fails the build), so escalate
                // by pid. The probe child blocks inside the analysis pass and may hold a
                // speech recognizer, so a child that ignored SIGTERM must not linger on the
                // microphone after we stopped caring about its answer. `kill(pid, 0)` is the
                // liveness check that keeps a reassigned pid out of reach of the SIGKILL.
                kill(pid, SIGTERM)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !landing.childHasReported, kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
    }

    /// The child's stdout, bounded: it is a diagnostic, not a payload, and a runaway child
    /// must not be able to make the parent allocate without limit.
    static func readReport(_ url: URL, byteLimit: Int = 4096) -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: byteLimit)) ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line per probe outcome, with whatever the child managed to say.
    ///
    /// `… stage=pre-analysis` and no `stage=final` is the trap signature: the child got as
    /// far as the analysis call and the framework took it down. That distinction is the whole
    /// difference between "the engine is broken" and "the engine was never reached", and it
    /// belongs in a log a human can read, not in a temp file the parent deletes.
    static func logProbeOutcome(_ outcome: EngineProbeOutcome, childOutput: String) {
        let collapsed = childOutput.replacingOccurrences(of: "\n", with: " ⏎ ")
        let detail = collapsed.isEmpty ? "no report (killed before it could write)" : collapsed
        Logger(label: "ocoreai.hearing.probe").info(
            "hearing engine probe → \(outcome.rawValue) · child: \(detail)")
    }
}

/// Exactly-once landing for the probe child, plus whether the child reported for itself.
///
/// Two jobs, both load-bearing. Exactly-once: the termination handler and the deadline race,
/// and resuming a continuation twice is undefined behaviour. `childHasReported`: before
/// sending a signal to a pid the OS may already have handed to another process, the parent
/// has to know whether its child is the one still standing.
///
/// `@unchecked Sendable` justification: every field is read and written only under `lock`.
private final class ProbeLanding: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var reportedByChild = false
    private let body: (EngineProbeOutcome) -> Void

    init(_ body: @escaping (EngineProbeOutcome) -> Void) {
        self.body = body
    }

    /// Whether the child's own `terminationHandler` has run.
    var childHasReported: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reportedByChild
    }

    func childReported() {
        lock.lock()
        reportedByChild = true
        lock.unlock()
    }

    /// Resume once; later landings are dropped because the answer is already in flight.
    func fire(_ outcome: EngineProbeOutcome) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        body(outcome)
    }
}
#endif
