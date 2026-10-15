// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HearingReadiness.swift — the one gate in front of every on-device ASR call.
///
/// ### Why a gate, and why out-of-process
/// The host this project ships from (macOS 26.6.2, Mac17,6) is a live counter-example for
/// every shortcut that answers "is STT available?" by asking the OS:
///
///   * `SFSpeechRecognizer(locale: .current).supportsOnDeviceRecognition` → **true**
///   * `SpeechTranscriber.supportedLocale(equivalentTo:)` → **zh_CN / en_US** (non-nil)
///   * the crash report alongside it says `appleIntelligenceStatus:
///     {"state":"unavailable","reasons":["regionIneligible"]}`
///   * and `SpeechAnalyzer.analyzeSequence(from:)` does not throw — it **traps**
///     (`EXC_BREAKPOINT`/SIGTRAP, faulting frame `specialized SpeechAnalyzer.analyzeSequence`)
///
/// Both availability APIs answer "yes" on a box where the analysis pass dies, and the death
/// is not catchable: the `try` at `AudioIO.swift:213` handles a *thrown* error, while a
/// SIGTRAP inside the framework takes the whole process — GUI, engine pool, sessions — with
/// it. This is invariant 1 with an audio hat: a premise inferred from an API instead of run
/// is a premise that rots, and here it rots into a crash rather than a wrong boolean.
///
/// ### The contract this file enforces
/// 1. **Never prompt on a server path.** Authorization is read with
///    `SFSpeechRecognizer.authorizationStatus()`, silently. A wire client cannot answer a
///    modal TCC dialog, so prompting is the camera hang (`cdd4cc7`) re-run.
/// 2. **Never run the framework blind.** The first attempt is preceded by an engine probe
///    that performs the analysis in a **child** process (`ocoreai --probe-hearing <file>`).
///    A trap there costs one refused request and a measured verdict; a trap in the parent
///    costs the app. The outcome is cached per process and a fault opens the circuit.
/// 3. **Claim exactly what was measured.** `EngineProbeOutcome.ok` means "a synthetic
///    analysis pass completed in a child without trapping or erroring" — not that words come
///    out. That stronger claim belongs to `scripts/probes/05-hearing.sh`, which posts a real
///    utterance and reads the transcript back.
///
/// ### Reuses, does not re-author
/// `DevicePermission`, `ChannelReadiness`, `CaptureAttempt` and `privacyPane(forChannel:)`
/// come from ``MultimodalDeviceFacts`` on purpose — one closed vocabulary per axis, so the
/// mic-capture path and the transcription path cannot publish two meanings of `blocked`.
/// The transcription itself is ``LocalSTT`` (Speech framework, macOS/iOS 26+).

import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

/// Why a transcript did not happen — closed vocabulary, so clients branch on `error_code`
/// instead of string-parsing a sentence.
enum TranscriptFailure: String, Codable, CaseIterable, Error, Sendable {
    /// The Speech engine this seam needs does not exist on this OS tier.
    case osUnsupported
    /// Speech Recognition was never granted to this process (read silently, never prompted).
    case speechNotDetermined
    /// The user refused Speech Recognition for this app.
    case speechDenied
    /// Speech Recognition is not obtainable by this user (MDM / parental controls).
    case speechRestricted
    /// No local model resolves for the requested locale.
    case localeUnsupported
    /// The engine was probed out-of-process and the child was killed by a signal (SIGTRAP).
    case engineFault
    /// The probe child ran and the framework refused (non-zero exit).
    case engineRefused
    /// The probe child neither finished nor died inside its budget.
    case engineTimeout
    /// The bytes are not readable audio (bad base64, wrong container, empty file).
    case undecodableAudio
    /// The OS speech detector never fired: the sample contained no speech.
    case noSpeechDetected
    /// The detector fired but the transcriber produced no words.
    case emptyTranscript

    /// Machine-readable code for the JSON error envelope (`speech_not_determined`,
    /// `engine_fault`, …) — derived from the closed vocabulary so the two can never drift.
    var errorCode: String {
        var out = ""
        for character in rawValue {
            if character.isUppercase {
                out.append("_")
                out.append(Character(character.lowercased()))
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// What the OS speech detector reported, for the two outcomes where listening actually
    /// happened: `false` when it never fired, `true` when it fired and no words came out.
    ///
    /// `nil` for every refusal, where nothing was listened to — absence keeps "not measured"
    /// distinct from a measured no, the same rule that omits an unmeasurable device count on
    /// `POST /v1/multimodal/status` instead of publishing `0`.
    var detectedSpeech: Bool? {
        switch self {
        case .noSpeechDetected: return false
        case .emptyTranscript: return true
        default: return nil
        }
    }

    /// What the caller has to change, named concretely.
    var remediation: String {
        switch self {
        case .osUnsupported:
            return "Requires macOS 26 / iOS 26 for the on-device Speech engine"
        case .speechNotDetermined:
            return "Grant Speech Recognition in System Settings ▸ Privacy & Security ▸ "
                + "Speech Recognition, then retry (this service never prompts on a wire request)"
        case .speechDenied:
            return "Speech Recognition is denied for this app — enable it in System Settings ▸ "
                + "Privacy & Security ▸ Speech Recognition"
        case .speechRestricted:
            return "Speech Recognition is restricted for this user by the device policy"
        case .localeUnsupported:
            return "No local speech model for this locale — send `language` with a supported "
                + "BCP-47 tag, or install the language in System Settings"
        case .engineFault:
            return "The on-device Speech engine crashed while being probed — transcription is "
                + "disabled for this process so the crash cannot reach the app"
        case .engineRefused:
            return "The on-device Speech engine refused the probe pass — check that on-device "
                + "dictation models are installed (System Settings ▸ Keyboard ▸ Dictation)"
        case .engineTimeout:
            return "The on-device Speech engine did not finish its probe pass — retry, or "
                + "check whether on-device dictation is enabled"
        case .undecodableAudio:
            return "Send readable audio: `audio` as a data URL or base64 string, an `audio_url`, "
                + "or multipart/form-data with a `file` part"
        case .noSpeechDetected:
            return "The sample contains no speech — the OS speech detector never fired"
        case .emptyTranscript:
            return "Speech was detected but no words were produced — retry, or send `language` "
                + "with a different locale"
        }
    }
}

/// Result of the out-of-process engine probe.
///
/// `ok` is deliberately weak and precisely worded: a synthetic analysis pass completed in a
/// child process without trapping or erroring. It is *not* a claim that the engine produced
/// correct words — that claim is `scripts/probes/05-hearing.sh`'s job, with a real utterance.
enum EngineProbeOutcome: String, Codable, CaseIterable, Sendable {
    /// No probe has run in this process (nothing measured either way).
    case notRun
    /// A child completed a synthetic analysis pass without trapping or erroring.
    case ok
    /// The child was killed by a signal — the SIGTRAP class that would have killed the parent.
    case fault
    /// The child ran and the framework threw (non-zero exit).
    case refused
    /// The child did not finish inside the probe budget.
    case timeout
    /// This target cannot spawn a process (no `Process`), so the probe is not available.
    case unavailable

    /// Whether the seam may call the framework in-process after this outcome.
    var allowsInProcessASR: Bool {
        self != .fault && self != .refused && self != .timeout
    }

    /// Map a finished (or abandoned) child onto the closed vocabulary.
    ///
    /// Pure, so the mapping is pinned by unit test rather than by whatever mood a host is
    /// in: a signal is `fault` even when the numeric status would look almost fine.
    static func classify(exitCode: Int32?, signal: Int32?, timedOut: Bool) -> EngineProbeOutcome {
        if timedOut { return .timeout }
        if let signal, signal != 0 { return .fault }
        if exitCode == 0 { return .ok }
        if exitCode != nil { return .refused }
        return .refused
    }
}

/// The measured state of "can this box hear?", published on `POST /v1/multimodal/status`
/// and consulted by `POST /v1/audio/transcriptions` before it touches the framework.
///
/// `Codable`, not just `Encodable`: `StatusResponse` is `Codable`, so a nested type that only
/// encoded broke the build; and round-tripping is the useful property anyway — a probe can
/// decode the payload it just read and assert against the same type the server built.
struct HearingReadiness: Codable, Equatable, Sendable {
    /// Which engine this seam drives. Constant today; named so that a second engine (an MLX
    /// ASR model, if upstream ever consumes audio) is a new value, not a redefined word.
    let engine: String
    /// The OS tier has the engine (`SpeechAnalyzer` exists at 26+).
    let tierSupported: Bool
    /// Speech Recognition permission, read without prompting.
    let authorization: DevicePermission
    /// Locale the caller asked for.
    let requestedLocale: String
    /// What the OS resolved it to; nil when nothing resolved **or** when it was not queried.
    /// `localeMeasured` keeps those two apart — conflating them is how "unknown" turns into
    /// a false verdict.
    let resolvedLocale: String?
    /// Whether the locale axis was actually queried.
    let localeMeasured: Bool
    /// `SFSpeechRecognizer.supportsOnDeviceRecognition`, published because this host proves
    /// it is not sufficient: true here, while the engine traps.
    let onDeviceCapable: Bool?
    /// Outcome of the out-of-process probe.
    let probe: EngineProbeOutcome
    /// Verdict for clients: `ready` requires evidence, `unknown` means unverified.
    let verdict: ChannelReadiness
    /// The reason the verdict is not `ready`.
    let reason: TranscriptFailure?

    enum CodingKeys: String, CodingKey {
        case engine
        case tierSupported = "tier_supported"
        case authorization
        case requestedLocale = "requested_locale"
        case resolvedLocale = "resolved_locale"
        case localeMeasured = "locale_measured"
        case onDeviceCapable = "on_device_capable"
        case probe
        case verdict
        case reason
    }

    static let engineName = "apple-speech-analyzer"

    /// Derive the verdict from the measured axes. Pure — every row is asserted in tests.
    ///
    /// Order matters: an axis absent from the target is `unsupported`; a measured no is
    /// `blocked`; an unreadable axis is `unknown`; a fault measured out-of-process outranks a
    /// grant, because a grant on a trapping engine is not evidence of delivery; and anything
    /// left unmeasured is `unknown` — never `ready`, never a zero dressed as a verdict.
    static func verdict(
        tierSupported: Bool,
        authorization: DevicePermission,
        resolvedLocale: String?,
        localeMeasured: Bool,
        probe: EngineProbeOutcome
    ) -> ChannelReadiness {
        if !tierSupported { return .unsupported }
        if authorization == .unsupported { return .unsupported }
        switch authorization {
        case .denied, .restricted, .notDetermined, .notGranted:
            return .blocked
        case .unknown:
            return .unknown
        case .authorized, .unsupported:
            break
        }
        switch probe {
        case .fault, .refused, .timeout:
            return .blocked
        case .notRun, .unavailable:
            return .unknown
        case .ok:
            break
        }
        if localeMeasured && resolvedLocale == nil { return .blocked }
        if !localeMeasured { return .unknown }
        return .ready
    }

    /// One line for the status payload's `limitations` list; nil when there is nothing to
    /// warn about, so a healthy host publishes no noise.
    var limitation: String? {
        if verdict == .ready { return nil }
        switch verdict {
        case .ready:
            return nil
        case .unsupported:
            return "transcription: Speech engine unavailable on this platform"
        case .unknown:
            return "transcription: unverified here (probe=\(probe.rawValue), "
                + "localeMeasured=\(localeMeasured ? "yes" : "no"))"
        case .blocked:
            let why = reason?.rawValue ?? "blocked"
            return "transcription: \(why) (probe=\(probe.rawValue))"
        }
    }
}

/// A transcript plus the facts a client needs to judge it.
struct HearingTranscript: Sendable, Equatable {
    let text: String
    /// Which engine produced this — measured, not configured.
    let engine: String
    /// OS speech-detector truth: was there speech in the sample at all.
    let detected: Bool
    /// Locale actually used (the OS may resolve a nearby one).
    let locale: String
    /// Measured duration of the decoded sample; nil when it could not be read.
    let durationSeconds: Double?
}

// MARK: - Probe state

/// Cache for the one-shot engine probe. An actor because the seam is called from HTTP
/// handlers (nonisolated) and from `@MainActor` UI paths: two concurrent first requests must
/// not spawn two children, and the circuit breaker must not race.
actor HearingProbeState {
    static let shared = HearingProbeState()

    private var outcome: EngineProbeOutcome = .notRun
    private var inFlight: Task<EngineProbeOutcome, Never>?

    /// The cached outcome, without running anything.
    var cached: EngineProbeOutcome { outcome }

    /// Whether a fault has been measured this process (refuse without touching the OS).
    var isOpen: Bool { outcome == .fault }

    /// Probe once; concurrent callers join the same task. `refused`/`timeout` are retryable
    /// by design (they may be transient); `ok` and `fault` are terminal for the process.
    func once(timeout: TimeInterval) async -> EngineProbeOutcome {
        switch outcome {
        case .ok, .fault, .unavailable:
            return outcome
        case .notRun, .refused, .timeout:
            break
        }
        if let running = inFlight { return await running.value }
        #if os(macOS)
        let task = Task { await HearingEngineProbe.run(timeout: timeout) }
        inFlight = task
        let result = await task.value
        outcome = result
        inFlight = nil
        return result
        #else
        // No `Process` to re-exec on this platform, so the probe is not available rather
        // than not run: "cannot measure here" and "have not measured yet" are different
        // claims, and `verdict` treats them differently.
        return .unavailable
        #endif
    }

    /// Record an in-process outcome: a transcription that actually produced words proves the
    /// engine runs, which is stronger evidence than the synthetic pass.
    func record(_ newOutcome: EngineProbeOutcome) {
        outcome = newOutcome
    }

    /// Test seam: clear the cache so a unit test can drive the once-per-process logic.
    func resetForTesting() {
        outcome = .notRun
        inFlight = nil
    }
}

// MARK: - Seam

/// The single entry point for on-device transcription. Every caller — HTTP handler, GUI
/// press-to-talk, agent tool — goes through here, so "call the OS and hope" cannot return
/// by way of a new call site.
enum Hearing {
    /// The tier floor: file-based offline transcription needs `SpeechAnalyzer` (26+).
    static var tierAvailable: Bool {
        #if canImport(Speech)
        if #available(macOS 26.0, iOS 26.0, *) { return true }
        return false
        #else
        return false
        #endif
    }

    /// Read the permission axis only — no prompt, no engine, no locale query. Cheap enough
    /// for a status endpoint's fast path, and safe on any thread.
    static func permissionsOnly(locale: Locale = .current) -> HearingReadiness {
        let tier = tierAvailable
        #if canImport(Speech)
        let authorization = DevicePermission(SFSpeechRecognizer.authorizationStatus())
        #else
        let authorization = DevicePermission.unsupported
        #endif
        return build(
            tierSupported: tier, authorization: authorization, resolvedLocale: nil,
            localeMeasured: false, onDeviceCapable: nil, probe: .notRun,
            requestedLocale: locale.identifier)
    }

    /// Measure every axis, including the out-of-process engine probe (cached per process, and
    /// only ever run when a grant exists — see ``HearingEngineProbe``).
    /// - Parameter probeEngine: run the out-of-process probe if none is cached. Pass `false`
    ///   on read-only paths (a status endpoint must not pay a 20 s probe for a snapshot);
    ///   the cached outcome is still reported, so the difference is "not measured yet"
    ///   rather than a guessed verdict.
    static func measure(locale: Locale = .current, probeEngine: Bool = true) async
        -> HearingReadiness
    {
        let tier = tierAvailable
        #if canImport(Speech)
        let authorization = DevicePermission(SFSpeechRecognizer.authorizationStatus())
        #else
        let authorization = DevicePermission.unsupported
        #endif
        var resolved: String? = nil
        var onDevice: Bool? = nil
        if tier {
            #if canImport(Speech)
            if #available(macOS 26.0, iOS 26.0, *) {
                resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale)?
                    .identifier
            }
            onDevice = SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition
            #endif
        }
        // Probe only behind a grant: without one the framework has nothing to run, and the
        // probe characterizes the engine, not the permission gate.
        let probe: EngineProbeOutcome
        #if os(macOS)
        if !probeEngine {
            probe = await HearingProbeState.shared.cached
        } else if tier && authorization == .authorized {
            probe = await HearingProbeState.shared.once(timeout: 20)
        } else {
            probe = .notRun
        }
        #else
        probe = tier ? .unavailable : .notRun
        #endif
        return build(
            tierSupported: tier, authorization: authorization, resolvedLocale: resolved,
            localeMeasured: tier, onDeviceCapable: onDevice, probe: probe,
            requestedLocale: locale.identifier)
    }

    /// Assemble readiness so `verdict` and `reason` can never disagree with the axes they
    /// were computed from (the one place both are derived).
    private static func build(
        tierSupported: Bool,
        authorization: DevicePermission,
        resolvedLocale: String?,
        localeMeasured: Bool,
        onDeviceCapable: Bool?,
        probe: EngineProbeOutcome,
        requestedLocale: String
    ) -> HearingReadiness {
        let verdict = HearingReadiness.verdict(
            tierSupported: tierSupported, authorization: authorization,
            resolvedLocale: resolvedLocale, localeMeasured: localeMeasured, probe: probe)
        return HearingReadiness(
            engine: HearingReadiness.engineName,
            tierSupported: tierSupported,
            authorization: authorization,
            requestedLocale: requestedLocale,
            resolvedLocale: resolvedLocale,
            localeMeasured: localeMeasured,
            onDeviceCapable: onDeviceCapable,
            probe: probe,
            verdict: verdict,
            reason: reason(
                for: verdict, authorization: authorization,
                resolvedLocale: resolvedLocale, probe: probe)
        )
    }

    /// Map a verdict back onto the closed reason vocabulary (pure; asserted in tests).
    static func reason(
        for verdict: ChannelReadiness,
        authorization: DevicePermission,
        resolvedLocale: String?,
        probe: EngineProbeOutcome
    ) -> TranscriptFailure? {
        switch verdict {
        case .ready, .unknown:
            return nil
        case .unsupported:
            return .osUnsupported
        case .blocked:
            switch authorization {
            case .denied: return .speechDenied
            case .restricted: return .speechRestricted
            case .notDetermined, .notGranted: return .speechNotDetermined
            case .unsupported: return .osUnsupported
            case .authorized, .unknown: break
            }
            switch probe {
            case .fault: return .engineFault
            case .refused: return .engineRefused
            case .timeout: return .engineTimeout
            default: break
            }
            return resolvedLocale == nil ? .localeUnsupported : nil
        }
    }

    /// The failure matching a readiness, for the wire's `error_code`.
    static func failure(for readiness: HearingReadiness) -> TranscriptFailure? {
        reason(
            for: readiness.verdict, authorization: readiness.authorization,
            resolvedLocale: readiness.resolvedLocale, probe: readiness.probe)
    }

    /// Whether a transcription may be attempted at all, and why not when it may not.
    ///
    /// `.unknown` authorization still attempts — refusing on an unreadable value would block
    /// paths that work, and the honest direction to err is the loud refusal, not the quiet
    /// one (same rule as `captureAttempt`). A measured fault never attempts.
    static func attempt(readiness: HearingReadiness) -> CaptureAttempt {
        if !readiness.tierSupported {
            return .refuse(reason: TranscriptFailure.osUnsupported.remediation)
        }
        switch readiness.probe {
        case .fault:
            return .refuse(reason: TranscriptFailure.engineFault.remediation)
        case .timeout:
            return .refuse(reason: TranscriptFailure.engineTimeout.remediation)
        case .refused:
            return .refuse(reason: TranscriptFailure.engineRefused.remediation)
        case .ok, .notRun, .unavailable:
            break
        }
        switch readiness.authorization {
        case .denied:
            return .refuse(reason: TranscriptFailure.speechDenied.remediation)
        case .restricted:
            return .refuse(reason: TranscriptFailure.speechRestricted.remediation)
        case .notDetermined, .notGranted:
            return .refuse(reason: TranscriptFailure.speechNotDetermined.remediation)
        case .unsupported:
            return .refuse(reason: TranscriptFailure.osUnsupported.remediation)
        case .authorized, .unknown:
            break
        }
        if readiness.localeMeasured && readiness.resolvedLocale == nil {
            return .refuse(reason: TranscriptFailure.localeUnsupported.remediation)
        }
        return .attempt
    }

    /// Transcribe a local audio file — the only place a wire path reaches ``LocalSTT``.
    static func transcribe(
        file url: URL, locale: Locale, timeout: TimeInterval = 30
    ) async -> Result<HearingTranscript, TranscriptFailure> {
        let readiness = await measure(locale: locale)
        if case .refuse = attempt(readiness: readiness) {
            return .failure(failure(for: readiness) ?? .speechNotDetermined)
        }
        #if canImport(AVFoundation) && canImport(Speech)
        guard #available(macOS 26.0, iOS 26.0, *) else {
            return .failure(.osUnsupported)
        }
        // Decodability is checked here so "the client sent bytes we cannot read"
        // (undecodableAudio) stays distinct from "the engine refused" (engineRefused).
        guard (try? AVAudioFile(forReading: url)) != nil else {
            return .failure(.undecodableAudio)
        }
        return await withTaskGroup(of: Result<HearingTranscript, TranscriptFailure>.self) {
            group in
            group.addTask {
                do {
                    let result = try await LocalSTT.transcribe(url: url, locale: locale)
                    let text = result.text.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        return .failure(result.detected ? .emptyTranscript : .noSpeechDetected)
                    }
                    await HearingProbeState.shared.record(.ok)
                    return .success(
                        HearingTranscript(
                            text: text,
                            engine: HearingReadiness.engineName,
                            detected: result.detected,
                            locale: readiness.resolvedLocale ?? locale.identifier,
                            durationSeconds: durationSeconds(of: url)))
                } catch {
                    return .failure(.engineRefused)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                return .failure(.engineTimeout)
            }
            let first = await group.next() ?? .failure(.engineTimeout)
            group.cancelAll()
            return first
        }
        #else
        return .failure(.osUnsupported)
        #endif
    }

    #if canImport(AVFoundation)
    /// Measured sample duration: `AVAudioFile.length / sampleRate`.
    static func durationSeconds(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Double(file.length) / rate
    }
    #else
    static func durationSeconds(of url: URL) -> Double? { nil }
    #endif
}
