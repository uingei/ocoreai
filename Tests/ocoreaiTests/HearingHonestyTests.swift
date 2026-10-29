// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HearingHonestyTests.swift — nothing reaches Apple's Speech analyzer without a measurement,
/// and nothing on the surface claims more than that measurement supported.
///
/// Why this suite exists (AGENTS.md invariant 2, with an audio hat): on the host this project
/// ships from, `SFSpeechRecognizer(...).supportsOnDeviceRecognition` answers **true** while
/// `SpeechAnalyzer.analyzeSequence(from:)` dies with SIGTRAP — an error no `catch` can take,
/// because it takes the process with it. So OS availability APIs are not evidence, and the
/// only honest gate is one built out of things that were actually measured: permission read
/// without prompting, a locale that resolved, and an analysis pass that completed in a *child*.
///
/// `.serialized` on the probe-state suite is load-bearing: `HearingProbeState` is process-wide,
/// and the circuit-breaker tests must observe their own writes without racing another test.

import Foundation
import Testing

@testable import ocoreai

// MARK: - fixture

/// A readiness built through the same `verdict`/`reason` the seam uses, so a fixture cannot
/// assert a combination the production code would never assemble.
private func readiness(
    tier: Bool = true,
    authorization: DevicePermission = .authorized,
    resolvedLocale: String? = "en-US",
    localeMeasured: Bool = true,
    onDevice: Bool? = true,
    probe: EngineProbeOutcome = .ok,
    requestedLocale: String = "en-US"
) -> HearingReadiness {
    let verdict = HearingReadiness.verdict(
        tierSupported: tier, authorization: authorization,
        resolvedLocale: resolvedLocale, localeMeasured: localeMeasured, probe: probe)
    return HearingReadiness(
        engine: HearingReadiness.engineName,
        tierSupported: tier,
        authorization: authorization,
        requestedLocale: requestedLocale,
        resolvedLocale: resolvedLocale,
        localeMeasured: localeMeasured,
        onDeviceCapable: onDevice,
        probe: probe,
        verdict: verdict,
        reason: Hearing.reason(
            for: verdict, authorization: authorization,
            resolvedLocale: resolvedLocale, probe: probe))
}

private let verdictRows:
    [(
        tier: Bool, authorization: DevicePermission, locale: String?, localeMeasured: Bool,
        probe: EngineProbeOutcome, want: ChannelReadiness, why: String
    )] = [
        (false, .authorized, "en-US", true, .ok, .unsupported, "no engine at this OS tier"),
        (true, .unsupported, "en-US", true, .ok, .unsupported, "no permission axis on target"),
        (true, .denied, "en-US", true, .ok, .blocked, "user refused"),
        (true, .restricted, "en-US", true, .ok, .blocked, "MDM or parental controls"),
        (true, .notDetermined, "en-US", true, .ok, .blocked, "never granted"),
        (true, .notGranted, "en-US", true, .ok, .blocked, "not obtainable for this user"),
        (true, .unknown, "en-US", true, .ok, .unknown, "unreadable axis"),
        (true, .authorized, "en-US", true, .fault, .blocked, "measured SIGTRAP class"),
        (true, .authorized, "en-US", true, .refused, .blocked, "framework threw"),
        (true, .authorized, "en-US", true, .timeout, .blocked, "child outlived its budget"),
        (true, .authorized, "en-US", true, .notRun, .unknown, "nothing measured yet"),
        (true, .authorized, "en-US", true, .unavailable, .unknown, "cannot measure here"),
        (true, .authorized, nil, true, .ok, .blocked, "no local model for the locale"),
        (true, .authorized, "en-US", false, .ok, .unknown, "locale axis not queried"),
        (true, .authorized, "zh-CN", true, .ok, .ready, "every axis measured, every axis yes"),
    ]

@Test("permission × locale × probe → verdict, exactly", arguments: verdictRows)
func verdictTable(
    tier: Bool, authorization: DevicePermission, locale: String?, localeMeasured: Bool,
    probe: EngineProbeOutcome, want: ChannelReadiness, why: String
) {
    #expect(
        HearingReadiness.verdict(
            tierSupported: tier, authorization: authorization, resolvedLocale: locale,
            localeMeasured: localeMeasured, probe: probe) == want,
        "\(why)")
}

@Test("the table covers its own axes, so a narrowing fails instead of passing vacuously")
func verdictTableFloors() {
    #expect(verdictRows.count >= 15)
    for permission in DevicePermission.allCases {
        #expect(
            verdictRows.contains { $0.authorization == permission },
            "no row for permission \(permission.rawValue)")
    }
    for outcome in EngineProbeOutcome.allCases {
        #expect(
            verdictRows.contains { $0.probe == outcome },
            "no row for probe \(outcome.rawValue)")
    }
}

@Test("`ready` is reachable only on evidence — exhaustively, across every axis combination")
func readyRequiresEvidence() {
    // The property, not a sample of it: `ready` iff the tier has the engine, permission is
    // granted, the probe measured an analysis pass, the locale axis was queried, and
    // something resolved. 2 × 7 × 2 × 2 × 6 = 336 combinations.
    var checked = 0
    for tier in [true, false] {
        for permission in DevicePermission.allCases {
            for locale in [Optional<String>.some("en-US"), nil] {
                for localeMeasured in [true, false] {
                    for probe in EngineProbeOutcome.allCases {
                        checked += 1
                        let verdict = HearingReadiness.verdict(
                            tierSupported: tier, authorization: permission,
                            resolvedLocale: locale, localeMeasured: localeMeasured, probe: probe)
                        let evidence =
                            tier && permission == .authorized && probe == .ok
                            && localeMeasured && locale != nil
                        #expect(
                            (verdict == .ready) == evidence,
                            "verdict \(verdict.rawValue) tier=\(tier) perm=\(permission.rawValue) locale=\(locale ?? "nil") measured=\(localeMeasured) probe=\(probe.rawValue)"
                        )
                    }
                }
            }
        }
    }
    #expect(checked == 336)
}

@Test("unmeasured is `unknown` with no reason attached, not a verdict in disguise")
func unmeasuredIsNotAVerdict() {
    let probeless = readiness(probe: .notRun)
    #expect(probeless.verdict == .unknown)
    #expect(probeless.reason == nil)
    #expect(ChannelReadiness.vocabulary.contains(probeless.verdict.rawValue))
}

@Test("a measured fault outranks a grant")
func faultOutranksGrant() {
    // The whole reason the seam exists: on the shipping host the grant is real and
    // `supportsOnDeviceRecognition` is true, and the engine still traps.
    let grantedButTrapping = readiness(authorization: .authorized, probe: .fault)
    #expect(grantedButTrapping.verdict == .blocked)
    #expect(Hearing.failure(for: grantedButTrapping) == .engineFault)
    #expect(grantedButTrapping.onDeviceCapable == true)
    #expect(grantedButTrapping.limitation?.contains("engineFault") == true)
}

private let reasonRows:
    [(
        authorization: DevicePermission, probe: EngineProbeOutcome, want: TranscriptFailure?,
        why: String
    )] = [
        (.denied, .ok, .speechDenied, "refused by the user"),
        (.restricted, .ok, .speechRestricted, "policy"),
        (.notDetermined, .ok, .speechNotDetermined, "never asked"),
        (.notGranted, .ok, .speechNotDetermined, "not obtainable"),
        (.unsupported, .ok, .osUnsupported, "axis absent from the target"),
        (.authorized, .fault, .engineFault, "child died on a signal"),
        (.authorized, .refused, .engineRefused, "framework threw"),
        (.authorized, .timeout, .engineTimeout, "child outlived the budget"),
    ]

@Test("a blocked verdict names the axis it is blocked on", arguments: reasonRows)
func reasonMapping(
    authorization: DevicePermission, probe: EngineProbeOutcome, want: TranscriptFailure?,
    why: String
) {
    #expect(
        Hearing.reason(
            for: .blocked, authorization: authorization, resolvedLocale: "en-US", probe: probe)
            == want,
        "\(why)")
}

@Test("no locale, no words — and an unqueried locale is not a verdict")
func localeUnsupportedIsItsOwnReason() {
    #expect(
        Hearing.reason(
            for: .blocked, authorization: .authorized, resolvedLocale: nil, probe: .ok)
            == .localeUnsupported)
    #expect(readiness(localeMeasured: false).verdict == .unknown)
    #expect(
        Hearing.reason(
            for: .ready, authorization: .authorized, resolvedLocale: "en-US", probe: .ok) == nil)
}

// MARK: - probe outcome mechanics

private let classifyRows:
    [(exitCode: Int32?, signal: Int32?, timedOut: Bool, want: EngineProbeOutcome, why: String)] = [
        (0, nil, false, .ok, "clean exit"),
        (1, nil, false, .refused, "framework threw"),
        (133, nil, false, .refused, "non-zero exit is a refusal, not a fault"),
        (nil, 5, false, .fault, "SIGTRAP — the class that would have killed the parent"),
        (nil, 6, false, .fault, "SIGABRT"),
        (0, nil, true, .timeout, "our deadline outranks a clean exit"),
        (nil, nil, true, .timeout, "killed by us after the deadline"),
        (nil, nil, false, .refused, "no code, no signal: nothing said it worked"),
        // Precedence: a signal outranks a numeric status, and our deadline outranks both, so a
        // kill the parent initiated can never be misreported as an engine fault.
        (0, 9, true, .timeout, "deadline beats signal"),
        (0, 9, false, .fault, "signal beats exit code"),
    ]

@Test("how a child ended maps onto the closed vocabulary, exactly", arguments: classifyRows)
func probeClassification(
    exitCode: Int32?, signal: Int32?, timedOut: Bool, want: EngineProbeOutcome, why: String
) {
    #expect(
        EngineProbeOutcome.classify(exitCode: exitCode, signal: signal, timedOut: timedOut) == want,
        "\(why)")
}

@Test("only a clean pass authorises an in-process call to the framework")
func inProcessPermission() {
    let unsafe: Set<String> = ["fault", "refused", "timeout"]
    for outcome in EngineProbeOutcome.allCases {
        #expect(
            outcome.allowsInProcessASR != unsafe.contains(outcome.rawValue),
            "\(outcome.rawValue) disagrees with the circuit-breaker rule")
    }
}

@Test("the fork-bomb guard is live inside this suite")
func testRunnerGuardIsLive() {
    // `Bundle.main.executableURL` inside a test host is the test runner, so re-exec'ing
    // "self" there would start another test run, which would spawn another. This assertion is
    // the difference between a probe and a process that multiplies until the machine dies.
    let bundlePath = Bundle.main.bundlePath
    let xcEnvironment = ProcessInfo.processInfo.environment.keys.sorted().filter {
        $0.hasPrefix("XC") || $0.contains("XCTest")
    }
    // Identity is the load-bearing rule. The enumerated signals were measured absent on this
    // host under `swift test` (Bundle.main is SwiftPM's libexec, no XC* keys set), which is
    // exactly how the suite came to spawn a child of the test runner before the whitelist.
    #expect(
        !HearingEngineProbe.isProductBinary,
        "not the product binary, yet identity would let this process re-exec itself")
    #expect(HearingEngineProbe.selfExecutable() == nil)
    #expect(
        HearingEngineProbe.isInTestRunner,
        "guard is dead on this host: Bundle.main=\(bundlePath), XC* env=\(xcEnvironment)")
}

@Test("and it short-circuits before any process is spawned")
func probeNeverSpawnsInsideTests() async {
    let outcome = await HearingEngineProbe.run(timeout: 1)
    #expect(outcome == .unavailable, "a probe child ran from inside the test host")
}

// MARK: - probe state (process-wide, so serialized)

@Suite("HearingProbeState: one probe per process, and a fault that holds", .serialized)
struct HearingProbeStateTests {

    @Test("a fault opens the circuit for the rest of the process")
    func faultOpensCircuit() async {
        let state = HearingProbeState.shared
        await state.resetForTesting()
        let before = await state.cached
        #expect(before == .notRun)
        let openBefore = await state.isOpen
        #expect(!openBefore)

        await state.record(.fault)
        let open = await state.isOpen
        #expect(open)
        // Cached, so the next request refuses without paying another child — and provably
        // did: inside this host a real probe answers `.unavailable`, never `.fault`.
        let again = await state.once(timeout: 1)
        #expect(again == .fault)
    }

    @Test("a refusal is retryable; a clean pass is not re-run")
    func refusalIsRetryableOkIsTerminal() async {
        let state = HearingProbeState.shared
        await state.resetForTesting()
        await state.record(.refused)
        // `refused` may be transient, so `once` retries rather than pinning it; inside this
        // host the retry lands on `.unavailable`, which proves the cache did not hold it.
        let retried = await state.once(timeout: 1)
        #expect(retried == .unavailable)

        await state.resetForTesting()
        await state.record(.ok)
        let okAgain = await state.once(timeout: 1)
        #expect(okAgain == .ok, "a measured pass was re-probed")
        await state.resetForTesting()
    }

    @Test("concurrent first callers share one answer, not eight children")
    func concurrentCallersJoin() async {
        let state = HearingProbeState.shared
        await state.resetForTesting()
        var results: [EngineProbeOutcome] = []
        await withTaskGroup(of: EngineProbeOutcome.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { await state.once(timeout: 2) }
            }
            for await outcome in group {
                results.append(outcome)
            }
        }
        #expect(results.count == 8)
        #expect(Set(results) == Set([EngineProbeOutcome.unavailable]))
        await state.resetForTesting()
    }
}

// MARK: - the gate in front of the framework

@Test(
    "the gate refuses every axis that cannot deliver, and says why",
    arguments: [
        (
            Optional<EngineProbeOutcome>.some(.fault), Optional<DevicePermission>.some(.authorized),
            TranscriptFailure.engineFault
        ),
        (.some(.timeout), .some(.authorized), .engineTimeout),
        (.some(.refused), .some(.authorized), .engineRefused),
        (.some(.ok), .some(.denied), .speechDenied),
        (.some(.ok), .some(.restricted), .speechRestricted),
        (.some(.ok), .some(.notDetermined), .speechNotDetermined),
        (.some(.ok), .some(.notGranted), .speechNotDetermined),
        (.some(.ok), .some(.unsupported), .osUnsupported),
    ] as [(probe: EngineProbeOutcome?, authorization: DevicePermission?, want: TranscriptFailure)])
func gateRefusals(
    probe: EngineProbeOutcome?, authorization: DevicePermission?, want: TranscriptFailure
) {
    let gate = Hearing.attempt(
        readiness: readiness(
            authorization: authorization ?? .authorized, probe: probe ?? .ok))
    #expect(gate == .refuse(reason: want.remediation), "expected refusal naming \(want.rawValue)")
}

@Test("tier and locale refuse too — with the fix named, not just the condition")
func gateRefusesTierAndLocale() {
    #expect(
        Hearing.attempt(readiness: readiness(tier: false))
            == .refuse(reason: TranscriptFailure.osUnsupported.remediation))
    #expect(
        Hearing.attempt(readiness: readiness(resolvedLocale: nil))
            == .refuse(reason: TranscriptFailure.localeUnsupported.remediation))
    // Remediation text is actionable, not a restatement of the error.
    #expect(TranscriptFailure.localeUnsupported.remediation.contains("locale"))
}

@Test("an unreadable permission still attempts — the loud error beats the quiet refusal")
func unknownPermissionStillAttempts() {
    // Refusing on `.unknown` would block paths that work; the seam errs toward the visible
    // failure. Same rule `captureAttempt` follows on the camera and mic legs.
    #expect(Hearing.attempt(readiness: readiness(authorization: .unknown)) == .attempt)
    #expect(Hearing.attempt(readiness: readiness(probe: .unavailable)) == .attempt)
    #expect(Hearing.attempt(readiness: readiness(probe: .notRun)) == .attempt)
    #expect(Hearing.attempt(readiness: readiness()) == .attempt)
}

// MARK: - the status fast path

@Test("a permission read is not a capability claim")
func permissionsOnlyNeverClaimsReady() {
    let snapshot = Hearing.permissionsOnly()
    #expect(snapshot.verdict != .ready)
    #expect(snapshot.localeMeasured == false)
    #expect(snapshot.probe == .notRun)
    #expect(snapshot.resolvedLocale == nil)
    // And it still has to say something: the limitation line is how a client learns why.
    #expect(snapshot.limitation?.hasPrefix("transcription:") == true)
}

@Test("asking for status does not pay for the probe")
func statusDoesNotRunTheProbe() async {
    let state = HearingProbeState.shared
    await state.resetForTesting()
    let measured = await Hearing.measure(probeEngine: false)
    #expect(measured.probe == .notRun, "a status read spawned an engine probe")
    #expect(measured.verdict != .ready)
}

@Test("readiness round-trips through the wire shape, and absent stays absent")
func readinessRoundTrips() throws {
    let full = readiness(probe: .ok)
    let data = try JSONEncoder().encode(full)
    #expect(try JSONDecoder().decode(HearingReadiness.self, from: data) == full)

    let json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
    #expect(json?["tier_supported"] as? Bool == true)
    #expect(json?["locale_measured"] as? Bool == true)
    #expect(json?["on_device_capable"] as? Bool == true)
    #expect(json?["probe"] as? String == "ok")
    #expect(json?["verdict"] as? String == "ready")

    // Unmeasured axes are omitted rather than published as null-ish placeholders: "cannot
    // tell" and "no" are different claims (the rule the device counts on status follow).
    let unmeasuredData = try JSONEncoder().encode(readiness(onDevice: nil, probe: .notRun))
    let unmeasured = (try JSONSerialization.jsonObject(with: unmeasuredData)) as? [String: Any]
    #expect(unmeasured?["on_device_capable"] == nil)
    #expect(unmeasured?["reason"] == nil)
}

// MARK: - status payload

@Test("the hearing axis replaces the snapshot line it supersedes")
func statusPrefersTheMeasuredAxis() throws {
    let facts = MultimodalDeviceFacts.unmeasured
    let hearing = readiness(probe: .fault)
    let response = makeMultimodalStatusResponse(
        toggles: (camera: true, microphone: true, speaker: true, screen: true),
        facts: facts,
        hearing: hearing)

    // The verdict a client reads is the one resting on more measurement.
    #expect(response.transcriptionStatus == .blocked)
    #expect(response.hearing == hearing)
    // One line per channel: the seam's line replaces the snapshot's, rather than sitting
    // next to it as a second opinion on the same axis.
    let transcriptionLines = response.limitations.filter { $0.hasPrefix("transcription:") }
    #expect(transcriptionLines.count == 1)
    #expect(transcriptionLines.first?.contains("engineFault") == true)
    // Every other channel keeps its own line, so nothing else was silently dropped.
    #expect(response.limitations.count == facts.limitations.count)
}

@Test("no hearing measurement means the field is absent, and the snapshot speaks")
func statusWithoutHearingOmitsTheField() throws {
    let facts = MultimodalDeviceFacts.unmeasured
    let response = makeMultimodalStatusResponse(
        toggles: (camera: true, microphone: true, speaker: true, screen: true),
        facts: facts)
    #expect(response.hearing == nil)
    #expect(response.transcriptionStatus == facts.transcriptionStatus)

    let object =
        (try JSONSerialization.jsonObject(with: try JSONEncoder().encode(response)))
        as? [String: Any]
    // Absence is "not measured", never "fine": the key must not appear as null or `{}`.
    #expect(object?["hearing"] == nil)
}

@Test("a healthy hearing axis publishes no limitation line")
func readyHearingPublishesNoNoise() {
    let response = makeMultimodalStatusResponse(
        toggles: (camera: true, microphone: true, speaker: true, screen: true),
        facts: MultimodalDeviceFacts.unmeasured,
        hearing: readiness(probe: .ok))
    #expect(response.transcriptionStatus == .ready)
    #expect(!response.limitations.contains { $0.hasPrefix("transcription:") })
}

// MARK: - what the surface advertises

@Test("`local_stt` points at where speech enters and where it is measured")
func capabilityLinePointsAtTheSeam() throws {
    // The tier-floor boolean is not a delivery claim, so the note has to say where the
    // delivery claim lives — otherwise `/v1/capabilities` advertises "local STT" as though
    // this box had already been shown to transcribe.
    let line = try #require(RuntimeCapability.lines.first { $0.name == "local_stt" })
    if #available(macOS 26.0, iOS 26.0, *) {
        #expect(line.available == true)
        #expect(line.note.contains("/v1/audio/transcriptions"))
        #expect(line.note.contains("hearing"))
        #expect(line.note.contains("probe"))
    } else {
        #expect(line.available == false)
    }
}

@Test("the endpoint index describes the contract the handler actually implements")
func endpointNoteIsNotAPromiseOfMore() throws {
    let spec = try #require(
        V1EndpointCatalog.routes.first {
            $0.method == "POST" && $0.path == "/v1/audio/transcriptions"
        })
    // multipart is the spec shape, base64/url the extension, and the refusals a client can
    // hit are named so nobody has to bisect a 400 to find out.
    #expect(spec.note.contains("multipart"))
    #expect(spec.note.contains("base64"))
    #expect(spec.note.contains("permission"))
    #expect(spec.note.contains("locale"))
    #expect(spec.note.contains("engine"))
}

// MARK: - vocabulary floors

@Test("the closed vocabularies are pinned, so a live probe cannot drift from the code")
func vocabularies() {
    #expect(
        EngineProbeOutcome.allCases.map(\.rawValue)
            == ["notRun", "ok", "fault", "refused", "timeout", "unavailable"])
    #expect(TranscriptFailure.allCases.count == 11)
    #expect(HearingReadiness.engineName == "apple-speech-analyzer")
}

@Test("every probe outcome has an honest place in the verdict")
func everyProbeOutcomeHasAVerdict() {
    for outcome in EngineProbeOutcome.allCases {
        let verdict = HearingReadiness.verdict(
            tierSupported: true, authorization: .authorized, resolvedLocale: "en-US",
            localeMeasured: true, probe: outcome)
        switch outcome {
        case .ok:
            #expect(verdict == .ready)
        case .fault, .refused, .timeout:
            #expect(verdict == .blocked)
        case .notRun, .unavailable:
            // "Have not measured" and "cannot measure here" both outrank `ready`: an axis
            // that produced no evidence cannot produce a capability claim.
            #expect(verdict == .unknown)
        }
    }
}

@Test("the probe flag is internal transport, not a documented CLI mode")
func probeFlagStaysInternal() {
    let help = CLIMode.informationalReport(for: ["ocoreai", "--help"]) ?? ""
    #expect(!help.contains(HearingSelfProbe.flag), "an internal probe flag leaked into --help")
    // And the child parses its own protocol: flag then fixture path.
    #expect(
        HearingSelfProbe.isRequested(arguments: ["ocoreai", HearingSelfProbe.flag, "/tmp/a.wav"]))
    #expect(
        HearingSelfProbe.fixturePath(in: ["ocoreai", HearingSelfProbe.flag, "/tmp/a.wav"])
            == "/tmp/a.wav")
    #expect(!HearingSelfProbe.isRequested(arguments: ["ocoreai", "serve"]))
    #expect(HearingSelfProbe.fixturePath(in: ["ocoreai", HearingSelfProbe.flag]) == nil)
}
