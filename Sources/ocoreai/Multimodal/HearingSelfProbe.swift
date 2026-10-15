// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HearingSelfProbe.swift — the child side of the hearing probe.
///
/// `ocoreai --probe-hearing <audio-file>` runs one Speech analysis pass, prints one JSON line
/// and exits. The parent (`HearingEngineProbe`) treats a signal here as a measured
/// `engineFault` instead of letting the same signal take down the app.
///
/// ### Why the protocol constants live here, not in `HearingEngineProbe`
/// `HearingEngineProbe` is `#if os(macOS)` because `Process` is the macOS half of the pair.
/// But `UI/Application.swift` dispatches to this file's `isRequested` on every launch, on
/// every platform — so if the flag lived on the macOS-only type, the iOS leg (`build-ios`)
/// would not compile. The protocol between the two copies of the binary therefore belongs on
/// the side both platforms can see: this one.

import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

/// The child side of the probe, and a runnable mode for scripts:
/// `ocoreai --probe-hearing <audio-file>` prints one JSON line and exits.
///
/// Exit 0 = an analysis pass completed; exit 1 = the framework threw. A trap looks like exit
/// 133 (SIGTRAP) to the parent and is what `EngineProbeOutcome.fault` exists to catch.
enum HearingSelfProbe {
    /// Flag the re-exec'd self looks for. Deliberately absent from `--help`: it is internal
    /// transport between two copies of the same binary, not a user-facing mode.
    static let flag = "--probe-hearing"

    /// Environment marker so the child can prove it was spawned as a probe (and so a stray
    /// invocation cannot be mistaken for a transcription request).
    static let environmentMarker = "OCOREAI_HEARING_PROBE"

    static func isRequested(arguments: [String]) -> Bool {
        arguments.contains(flag)
    }

    /// Path of the fixture argument following the flag, if any.
    static func fixturePath(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        return arguments[next]
    }

    /// What one probe pass measured.
    ///
    /// A `Sendable` value type because the analysis runs on a task while the deadline is held
    /// by the main thread: closing a task over a mutable `[String: Any]` is exactly the
    /// region-isolation error Swift 6 rejects ("sending value of non-Sendable type … risks
    /// causing data races", measured). The JSON envelope is assembled once, at the end, from
    /// this snapshot.
    struct Report: Sendable {
        var ok = false
        var chars: Int? = nil
        var detected: Bool? = nil
        var error: String? = nil
        var detail: String? = nil
        var exitCode: Int32 = 1
    }

    /// One-shot hand-off from the probe task to the waiting main thread.
    ///
    /// `@unchecked Sendable` justification: the single field is written under `lock`, and the
    /// reader reads it only after acquiring the semaphore or after that wait's deadline
    /// expires, so the ordering is established by the semaphore rather than the type system.
    private final class ReportBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Report()

        func set(_ newValue: Report) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func get() -> Report {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// One JSON line on stdout, via `FileHandle` and not `print()`: this repo keeps stdout
    /// reserved for CLI product surface (the `print_sites` claim in AGENTS.md counts it).
    private static func emit(_ payload: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
            FileHandle.standardOutput.write(data)
        }
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    /// Run the probe and terminate.
    ///
    /// Two lines, not one: the stage is announced **before** the framework is touched, because
    /// on the host this ships from the analysis pass dies with SIGTRAP and nothing after it
    /// ever runs (measured 10-15 — exit 133, stdout empty). So a `pre-analysis` line with no
    /// `final` line tells the parent the trap was inside the analysis, which an exit status
    /// cannot say, and the parent can log where it died instead of only that it died.
    static func run(arguments: [String]) -> Never {
        let path = fixturePath(in: arguments)
        let tier = Hearing.tierAvailable
        let box = ReportBox()

        if let path, tier {
            let url = URL(fileURLWithPath: path)
            let finished = DispatchSemaphore(value: 0)
            emit([
                "stage": "pre-analysis",
                "engine": HearingReadiness.engineName,
                "tier": tier,
                "file": path,
                "authorization": authorizationRaw(),
            ])
            if #available(macOS 26.0, iOS 26.0, *) {
                Task {
                    var report = Report()
                    do {
                        let result = try await LocalSTT.transcribe(url: url, locale: .current)
                        report.ok = true
                        report.chars = result.text.count
                        report.detected = result.detected
                        report.exitCode = 0
                    } catch {
                        report.error = String(describing: type(of: error))
                        report.detail = error.localizedDescription
                    }
                    box.set(report)
                    finished.signal()
                }
            } else {
                var report = Report()
                report.error = "osUnsupported"
                box.set(report)
                finished.signal()
            }
            // The child bounds itself too: the parent's budget is the outer bound, and a
            // child that has to be killed by its parent is a child that hung.
            if finished.wait(timeout: .now() + 25) == .timedOut {
                var timedOut = box.get()
                timedOut.ok = false
                timedOut.error = "timeout"
                timedOut.exitCode = 1
                box.set(timedOut)
            }
        } else {
            var report = Report()
            report.error = tier ? "missingFixture" : "osUnsupported"
            box.set(report)
        }

        let report = box.get()
        var payload: [String: Any] = [
            "stage": "final",
            "engine": HearingReadiness.engineName,
            "tier": tier,
            "ok": report.ok,
        ]
        if let path { payload["file"] = path }
        if tier { payload["authorization"] = authorizationRaw() }
        if let chars = report.chars { payload["chars"] = chars }
        if let detected = report.detected { payload["detected"] = detected }
        if let error = report.error { payload["error"] = error }
        if let detail = report.detail { payload["detail"] = detail }
        emit(payload)

        exit(report.exitCode)
    }

    private static func authorizationRaw() -> Int {
        #if canImport(Speech)
        return SFSpeechRecognizer.authorizationStatus().rawValue
        #else
        return -1
        #endif
    }
}
