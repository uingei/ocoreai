// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MultimodalStatusHonestyTests.swift — pin what `/v1/multimodal/status` and
/// `/v1/multimodal/capture` are allowed to claim.
///
/// Why gates here (AGENTS.md invariant 2 — the surface never claims more than the engine
/// delivered): the status route is indexed as "permission + device status" and published
/// only three UI toggles, so a client could not tell "camera on" from "camera permitted";
/// and the microphone capture leg answered `success: true` with `dataURL: null`. Both are
/// claims a client acts on, so both are pinned to measured facts here.

import AVFoundation
import Foundation
import Speech
import Testing

@testable import ocoreai

private let readinessCases: [(p: DevicePermission, c: Int?, want: ChannelReadiness)] = [
    (p: .authorized, c: 1, want: .ready),
    (p: .authorized, c: 0, want: .blocked),
    (p: .authorized, c: nil, want: .unknown),
    (p: .denied, c: 3, want: .blocked),
    (p: .denied, c: nil, want: .blocked),
    (p: .restricted, c: 0, want: .blocked),
    (p: .notDetermined, c: 0, want: .unknown),
    (p: .notGranted, c: 1, want: .unknown),
    (p: .unknown, c: 5, want: .unknown),
    (p: .unsupported, c: nil, want: .unsupported),
]
private let avAuthCases: [(raw: Int, want: DevicePermission)] = [
    (raw: 0, want: .notDetermined),
    (raw: 1, want: .restricted),
    (raw: 2, want: .denied),
    (raw: 3, want: .authorized),
    (raw: 42, want: .unknown),
]
private let speechAuthCases: [(raw: Int, want: DevicePermission)] = [
    (raw: 0, want: .notDetermined),
    (raw: 1, want: .denied),
    (raw: 2, want: .restricted),
    (raw: 3, want: .authorized),
    (raw: 42, want: .unknown),
]

private let captureGateCases:
    [(channel: String, permission: DevicePermission, refused: Bool, needle: String)] = [
        (channel: "camera", permission: .authorized, refused: false, needle: ""),
        (channel: "microphone", permission: .authorized, refused: false, needle: ""),
        // Unreadable beats an over-eager "no": the loud error is a failed capture, not a
        // refusal of a channel that may work.
        (channel: "camera", permission: .unknown, refused: false, needle: ""),
        (channel: "camera", permission: .denied, refused: true, needle: "permission denied"),
        (channel: "camera", permission: .restricted, refused: true, needle: "restricted by policy"),
        (
            channel: "camera", permission: .notDetermined, refused: true,
            needle: "does not open the permission dialog"
        ),
        (
            channel: "microphone", permission: .notDetermined, refused: true,
            needle: "flip the microphone toggle"
        ),
        (channel: "screen", permission: .notGranted, refused: true, needle: "Screen Recording"),
        (
            channel: "screen", permission: .unsupported, refused: true,
            needle: "not available on this platform"
        ),
    ]

@Suite("Multimodal honesty — verdicts follow the measured facts")
struct MultimodalStatusHonestyTests {

    private func facts(
        camera: DevicePermission = .authorized,
        microphone: DevicePermission = .authorized,
        speech: DevicePermission = .authorized,
        screen: DevicePermission = .authorized,
        cameras: Int? = 1,
        microphones: Int? = 1,
        voices: Int? = 12,
        screenDelivery: ScreenDelivery = .captured
    ) -> MultimodalDeviceFacts {
        MultimodalDeviceFacts(
            cameraPermission: camera,
            microphonePermission: microphone,
            speechRecognitionPermission: speech,
            screenPermission: screen,
            cameraDeviceCount: cameras,
            microphoneDeviceCount: microphones,
            speechVoiceCount: voices,
            screenDelivery: screenDelivery,
        )
    }

    // MARK: - Verdict derivation

    @Test("permission × device count → verdict, exactly", arguments: readinessCases)
    func readinessTable(p: DevicePermission, c: Int?, want: ChannelReadiness) {
        #expect(MultimodalDeviceFacts.readiness(p, c) == want)
    }

    @Test("speaker readiness is the installed-voice count, not tier support")
    func speakerReadiness() {
        #expect(MultimodalDeviceFacts.speakerReadiness(nil) == .unknown)
        #expect(MultimodalDeviceFacts.speakerReadiness(0) == .blocked)
        #expect(MultimodalDeviceFacts.speakerReadiness(1) == .ready)
        #expect(MultimodalDeviceFacts.speakerReadiness(180) == .ready)
    }

    @Test("TCC camera/mic status maps without prompting, exactly", arguments: avAuthCases)
    func avAuthorizationMapping(raw: Int, want: DevicePermission) throws {
        // NS_ENUM bridging yields a failable init; #require keeps the premise explicit and
        // the suite free of `!` (AGENTS.md: zero force-unwraps in this target).
        let status = try #require(AVAuthorizationStatus(rawValue: raw))
        #expect(DevicePermission(status) == want)
    }

    @Test(
        "Speech authorization maps by its own numbering (denied=1, not 2)",
        arguments: speechAuthCases)
    func speechAuthorizationMapping(raw: Int, want: DevicePermission) throws {
        let status = try #require(SFSpeechRecognizerAuthorizationStatus(rawValue: raw))
        #expect(DevicePermission(status) == want)
    }

    @Test("transcription needs both axes: speech auth AND a usable microphone")
    func transcriptionNeedsBothAxes() {
        #expect(facts().transcriptionStatus == .ready)
        #expect(facts(speech: .denied).transcriptionStatus == .blocked)
        #expect(facts(speech: .restricted).transcriptionStatus == .blocked)
        #expect(facts(microphone: .denied).transcriptionStatus == .blocked)
        #expect(facts(microphones: 0).transcriptionStatus == .blocked)
        #expect(facts(speech: .notDetermined).transcriptionStatus == .unknown)
        #expect(facts(microphones: nil).transcriptionStatus == .unknown)
        #expect(facts(speech: .unsupported).transcriptionStatus == .unsupported)
    }

    @Test("screen `ready` needs a delivered frame, not just the grant")
    func screenStatus() {
        // This is the assertion that used to read `facts(screen: .authorized) == .ready`,
        // i.e. "the user allowed it, therefore it works". Measured 10-15 on the shipping
        // host: the grant is on, a display enumerates, and SCScreenshotManager still
        // refuses — so the grant answers only the first of two questions.
        #expect(facts(screen: .authorized).screenStatus == .ready)
        #expect(
            facts(screen: .authorized, screenDelivery: .notAttempted).screenStatus == .unknown)
        #expect(
            facts(screen: .authorized, screenDelivery: .failed).screenStatus == .blocked)
        #expect(facts(screen: .denied).screenStatus == .blocked)
        #expect(facts(screen: .restricted).screenStatus == .blocked)
        // CGPreflightScreenCaptureAccess reports permitted vs not only — not a verdict.
        #expect(facts(screen: .notGranted).screenStatus == .unknown)
        #expect(facts(screen: .unsupported).screenStatus == .unsupported)
    }

    // MARK: - Limitations

    @Test("all facts present → no limitations, and every channel ready")
    func allReady() {
        let measured = facts()
        #expect(measured.limitations.isEmpty)
        #expect(measured.cameraStatus == .ready)
        #expect(measured.microphoneStatus == .ready)
        #expect(measured.speakerStatus == .ready)
        #expect(measured.screenStatus == .ready)
        #expect(measured.transcriptionStatus == .ready)
    }

    @Test("one line per blocked channel, in fixed order, and nothing else")
    func limitationLines() {
        let measured = facts(camera: .denied, screen: .notGranted, voices: 0)
        #expect(measured.limitations.count == 3)
        #expect(measured.limitations[0].hasPrefix("camera: "))
        #expect(measured.limitations[1].hasPrefix("speaker: "))
        #expect(measured.limitations[2].hasPrefix("screen: "))
        #expect(
            measured.limitations[0]
                == "camera: permission denied — grant it in System Settings ▸ Privacy & Security")
        #expect(
            measured.limitations[1] == "speaker: no installed speech voices — cannot synthesize")
    }

    @Test("limitation(forChannel:) strips the prefix and stays nil when unblocked")
    func limitationLookup() {
        let measured = facts(microphone: .denied)
        #expect(
            measured.limitation(forChannel: "microphone")
                == "permission denied — grant it in System Settings ▸ Privacy & Security")
        #expect(measured.limitation(forChannel: "camera") == nil)
        #expect(measured.limitation(forChannel: "nonexistent-channel") == nil)
    }

    @Test("nothing measured → nothing claimed, and every channel names its reason")
    func unmeasuredClaimsNothing() throws {
        let response = makeMultimodalStatusResponse(
            toggles: (camera: true, microphone: true, speaker: true, screen: true),
            facts: .unmeasured,
        )
        // Toggles are intent: they stay true here to prove the verdict band, not they.
        #expect(response.cameraStatus == .unsupported)
        #expect(response.microphoneStatus == .unsupported)
        #expect(response.speakerStatus == .unknown)
        #expect(response.screenStatus == .unsupported)
        #expect(response.transcriptionStatus == .unsupported)
        #expect(response.cameraPermission == .unsupported)
        #expect(response.cameraDeviceCount == nil)
        #expect(response.microphoneDeviceCount == nil)
        #expect(response.speechVoiceCount == nil)
        #expect(response.screenDelivery == .notAttempted)
        #expect(response.limitations.count == 5)

        let json =
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(response)) as? [String: Any]
        #expect(json != nil)
        // Unknown counts are omitted, never reported as 0 ("none found" ≠ "cannot tell").
        #expect(json?["cameraDeviceCount"] == nil)
        #expect(json?["microphoneDeviceCount"] == nil)
        #expect(json?["speechVoiceCount"] == nil)
        // The delivery axis says "nothing attempted" rather than going quiet on the field
        // that tells a reader it was never exercised — and keeps its error absent, not null.
        #expect(json?["screenDelivery"] as? String == "notAttempted")
        #expect(json?["screenDeliveryError"] == nil)
        #expect(json?["screenDeliveryLatencyMs"] == nil)
        // No published verdict may say `ready` when nothing was measured.
        let verdicts: [String] = [
            "cameraStatus", "microphoneStatus", "speakerStatus",
            "screenStatus", "transcriptionStatus",
        ]
        for key in verdicts {
            #expect(json?[key] as? String != "ready", "\(key) claimed ready with no facts")
            #expect(
                ChannelReadiness.vocabulary.contains(json?[key] as? String ?? ""),
                "\(key) left the closed vocabulary")
        }
        let permissions: [String] = [
            "cameraPermission", "microphonePermission",
            "speechRecognitionPermission", "screenPermission",
        ]
        for key in permissions {
            #expect(
                DevicePermission.vocabulary.contains(json?[key] as? String ?? ""),
                "\(key) left the closed vocabulary")
        }
    }

    @Test("the toggles survive into the payload untouched")
    func togglesPassThrough() {
        let response = makeMultimodalStatusResponse(
            toggles: (camera: true, microphone: false, speaker: true, screen: false),
            facts: facts(),
        )
        #expect(response.cameraEnabled == true)
        #expect(response.microphoneEnabled == false)
        #expect(response.speakerEnabled == true)
        #expect(response.screenCaptureEnabled == false)
        #expect(response.speechVoiceCount == 12)
        #expect(response.cameraDeviceCount == 1)
    }

    @Test("closed vocabularies are pinned, so the live probe cannot drift")
    func vocabularies() {
        #expect(
            DevicePermission.vocabulary
                == [
                    "authorized", "denied", "restricted", "notDetermined", "notGranted",
                    "unsupported", "unknown",
                ])
        #expect(ChannelReadiness.vocabulary == ["ready", "blocked", "unknown", "unsupported"])
    }

    // MARK: - Capture payload

    @Test("success is derived from the payload — bytes present is the only way to succeed")
    func captureSuccessIsDerived() {
        let withBytes = CaptureResponse(
            dataType: "audio/caf", dataURL: "data:audio/caf;base64,AA==", message: "Audio captured")
        #expect(withBytes.success == true)

        let noBytes = CaptureResponse(
            dataType: "audio/caf", dataURL: nil,
            message: "Recording started — call capture again to collect the sample")
        #expect(noBytes.success == false)
        #expect(noBytes.dataURL == nil)
    }

    @Test(
        "a started-but-empty microphone response encodes success:false", arguments: [true, false])
    func captureWireShape(started: Bool) throws {
        let response = CaptureResponse(
            dataType: "audio/caf",
            dataURL: nil,
            message: started
                ? "Recording started — call capture again to collect the sample"
                : "Recording did not start — permission denied",
        )
        let json =
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(response)) as? [String: Any]
        #expect(json?["success"] as? Bool == false)
        #expect(json?["dataURL"] as? String == nil)
        #expect((json?["message"] as? String)?.isEmpty == false)
    }

    // MARK: - The wire path decides, it does not ask

    @Test(
        "capture is gated on the measured permission, never on finding out via a dialog",
        arguments: captureGateCases)
    func captureGateTable(
        channel: String, permission: DevicePermission, refused: Bool, needle: String
    ) {
        switch captureAttempt(channel: channel, permission: permission) {
        case .attempt:
            #expect(!refused, "\(channel)/\(permission.rawValue) must be refused but attempted")
        case .refuse(let reason):
            #expect(
                refused, "\(channel)/\(permission.rawValue) must attempt but was refused: \(reason)"
            )
            #expect(
                reason.contains(needle),
                "\(channel)/\(permission.rawValue): \(reason) lacks \(needle)")
            #expect(reason.hasPrefix("\(channel): "), "refusal must name its channel: \(reason)")
        }
    }

    @Test("every refusal names the exact pane to fix, and the whole refusal set is non-empty")
    func captureGateNamesTheFix() {
        let panes = [
            "camera": "Camera", "microphone": "Microphone", "screen": "Screen Recording",
            "transcription": "Speech Recognition",
        ]
        for (channel, pane) in panes {
            #expect(privacyPane(forChannel: channel) == pane)
            if case .refuse(let reason) = captureAttempt(channel: channel, permission: .denied) {
                #expect(reason.contains(pane), "\(channel) denial must name \(pane): \(reason)")
            } else {
                Issue.record("a denied \(channel) must be refused")
            }
        }
        #expect(privacyPane(forChannel: "something-new") == "something-new")
    }

    @Test("permission(forChannel:) picks the axis the verdict is built from")
    func permissionLookup() {
        let measured = facts(
            camera: .denied, microphone: .restricted, speech: .notDetermined,
            screen: .notGranted)
        #expect(measured.permission(forChannel: "camera") == .denied)
        #expect(measured.permission(forChannel: "microphone") == .restricted)
        #expect(measured.permission(forChannel: "transcription") == .notDetermined)
        #expect(measured.permission(forChannel: "screen") == .notGranted)
        // An unmapped channel is unknown — which the gate treats as "attempt", not "no".
        #expect(measured.permission(forChannel: "unknown-channel") == .unknown)
    }

    // MARK: - Status must read, never ask

    @Test(
        "the status/capture surface uses non-prompting APIs only (scan asserts it can match)",
        arguments: [
            "Sources/ocoreai/Handlers/MultimodalHandler.swift",
            "Sources/ocoreai/Multimodal/MultimodalDeviceFacts.swift",
        ] as [String])
    func statusPathNeverPrompts(relativePath: String) throws {
        let source = codeOnly(try repoFile(relativePath))
        for prompting in [
            "requestAccess(for:", "requestAuthorization",
            "requestPersonalVoiceAuthorization",
        ] {
            #expect(
                !source.contains(prompting),
                "\(relativePath) calls \(prompting) — a status read must not open a TCC dialog")
        }
        // Premise check: the scanner can match. AudioIO is the prompting site by design
        // (the user asked to talk), and lives in the same directory being scanned.
        let audio = codeOnly(try repoFile("Sources/ocoreai/Multimodal/AudioIO.swift"))
        #expect(
            audio.contains("requestAccess(for:"), "premise: scanner stopped matching requestAccess")
    }

    // MARK: - Live gather (vocabulary conformance only; values are host-dependent)

    @MainActor
    @Test("gather() returns values inside the closed vocabularies on this host")
    func gatherConformsHere() {
        let measured = MultimodalDeviceFacts.gather()
        #expect(measured.speechVoiceCount != nil, "AVFoundation must enumerate voices here")
        #expect(measured.cameraDeviceCount != nil)
        #expect(measured.microphoneDeviceCount != nil)
        // Whatever the verdicts are, every non-ready channel must say why.
        let channels: [(name: String, status: ChannelReadiness)] = [
            ("camera", measured.cameraStatus), ("microphone", measured.microphoneStatus),
            ("speaker", measured.speakerStatus), ("screen", measured.screenStatus),
            ("transcription", measured.transcriptionStatus),
        ]
        for channel in channels {
            if channel.status != .ready {
                #expect(
                    measured.limitations.contains { $0.hasPrefix("\(channel.name): ") },
                    "\(channel.name) is \(channel.status.rawValue) with no limitation line")
            }
        }
    }

    // MARK: - Helpers

    /// Source with whole-line comments removed — the convention `scripts/audit.swift_patterns.sh`
    /// uses, because this rule first fired on the doc comment that *states* it
    /// ("Never prompt. `AVCaptureDevice.requestAccess(for:)`…"). Documentation about a rule
    /// is not a call site.
    private func codeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return
                    !(trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*"))
            }
            .joined(separator: "\n")
    }

    /// Repo-root-relative source read, finding the root by walking up until the file
    /// appears (never a fixed `deletingLastPathComponent()` hop count — see
    /// V1EndpointCatalogTests for the failure that rule exists to prevent).
    private func repoFile(_ relative: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 6 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw MissingRepoFile(path: "\(dir.path)/\(relative)")
    }

    struct MissingRepoFile: Error, CustomStringConvertible {
        let path: String
        var description: String { "no repo file at \(path) (walked up from \(#filePath))" }
    }
}
