// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ScreenDeliveryHonestyTests.swift — the screen verdict may not outrun a delivered frame.
///
/// Separate from `MultimodalStatusHonestyTests` because that suite owns the
/// permission × device-count derivation every channel shares. This one owns the axis only
/// screen has — whether pixels actually arrived — plus the per-process record that
/// remembers it.
///
/// The defect it exists for (AGENTS.md invariant 2, measured 10-15 on the shipping host):
/// `screenPermission=authorized`, a display enumerated, and
/// `SCScreenshotManager.captureImage` still returned "could not start stream".
/// `/v1/multimodal/status` published `screenStatus: ready` in exactly that state, so a
/// client that trusted the verdict went on to receive "No screen frame captured" from the
/// very next call. The grant answers "did the user allow it"; only a frame answers "does
/// it work here", and this box is the counter-example to treating the first as the second.

import Foundation
import Testing

@testable import ocoreai

/// Every permission × delivery pair, so the property below cannot pass by covering less.
private let screenPairs:
    [(perm: DevicePermission, delivery: ScreenDelivery, want: ChannelReadiness)] = [
        (.authorized, .captured, .ready),
        (.authorized, .failed, .blocked),
        (.authorized, .notAttempted, .unknown),
        (.denied, .captured, .blocked),
        (.denied, .notAttempted, .blocked),
        (.restricted, .captured, .blocked),
        (.notGranted, .captured, .unknown),
        (.notGranted, .notAttempted, .unknown),
        (.notDetermined, .captured, .unknown),
        (.unknown, .captured, .unknown),
        (.unsupported, .captured, .unsupported),
        (.unsupported, .notAttempted, .unsupported),
    ]

@Suite("Screen delivery — the verdict waits for a frame")
struct ScreenDeliveryHonestyTests {

    private func facts(
        _ perm: DevicePermission,
        _ delivery: ScreenDelivery,
        error: String? = nil
    ) -> MultimodalDeviceFacts {
        MultimodalDeviceFacts(
            cameraPermission: .authorized,
            microphonePermission: .authorized,
            speechRecognitionPermission: .authorized,
            screenPermission: perm,
            cameraDeviceCount: 1,
            microphoneDeviceCount: 1,
            speechVoiceCount: 8,
            screenDelivery: delivery,
            screenDeliveryError: error,
            screenDeliveryLatencyMs: error == nil ? nil : 194,
        )
    }

    @Test("permission × delivery → verdict, exactly", arguments: screenPairs)
    func verdictTable(
        pair: (perm: DevicePermission, delivery: ScreenDelivery, want: ChannelReadiness)
    ) {
        #expect(facts(pair.perm, pair.delivery).screenStatus == pair.want)
    }

    @Test("no `ready` without a captured frame — every pair checked, none skipped")
    func verdictCannotOutrunEvidence() {
        var checked = 0
        for perm in DevicePermission.allCases {
            for delivery in ScreenDelivery.allCases {
                let status = facts(perm, delivery).screenStatus
                if status == .ready {
                    #expect(
                        perm == .authorized && delivery == .captured,
                        "screenStatus said ready on \(perm.rawValue)/\(delivery.rawValue)")
                }
                checked += 1
            }
        }
        // Premise floor: a scan over an empty or narrowed pair list would pass vacuously.
        #expect(checked == DevicePermission.allCases.count * ScreenDelivery.allCases.count)
        #expect(checked == 21)
    }

    @Test("every non-ready verdict names its reason, and the reason is the measured one")
    func limitationsExplained() {
        // Granted but failing: pointing at the Settings pane would send the reader to a
        // toggle that is already on, so the framework's own words are the useful answer.
        let failing = facts(.authorized, .failed, error: "could not start stream")
        #expect(failing.screenStatus == .blocked)
        #expect(
            failing.limitations
                == ["screen: permission granted but capture failed — could not start stream"])
        #expect(
            failing.limitation(forChannel: "screen")
                == "permission granted but capture failed — could not start stream")

        // Granted but never exercised: say that, rather than implying a failure.
        let untried = facts(.authorized, .notAttempted)
        #expect(
            untried.limitations
                == [
                    "screen: permission granted but no frame captured in this process yet — "
                        + "`ready` waits for a delivered frame"
                ])

        // Refused: the pane is the fix, and the line still says so.
        #expect(
            facts(.denied, .notAttempted).limitations[0]
                == "screen: screen-recording permission denied — System Settings ▸ Privacy & "
                + "Security ▸ Screen Recording")
        #expect(
            facts(.unsupported, .notAttempted).limitations[0]
                == "screen: screen capture unavailable on this platform")
    }

    @Test("a delivered frame silences the screen limitation entirely")
    func readyHasNoLimitationLine() {
        #expect(facts(.authorized, .captured).limitations.isEmpty)
    }

    @Test("the wire publishes the evidence, and omits what was never measured")
    func wireShape() throws {
        let failing = makeMultimodalStatusResponse(
            toggles: (camera: true, microphone: true, speaker: true, screen: true),
            facts: facts(.authorized, .failed, error: "could not start stream"))
        let failingJSON =
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(failing)) as? [String: Any]
        #expect(failingJSON?["screenDelivery"] as? String == "failed")
        #expect(failingJSON?["screenDeliveryError"] as? String == "could not start stream")
        #expect(failingJSON?["screenDeliveryLatencyMs"] as? Int == 194)
        #expect(failingJSON?["screenStatus"] as? String == "blocked")

        let delivered = makeMultimodalStatusResponse(
            toggles: (camera: true, microphone: true, speaker: true, screen: true),
            facts: facts(.authorized, .captured))
        let deliveredJSON =
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(delivered)) as? [String: Any]
        #expect(deliveredJSON?["screenDelivery"] as? String == "captured")
        #expect(deliveredJSON?["screenStatus"] as? String == "ready")
        // Absent, not null: "nothing failed" is not a fact about a failure.
        #expect(deliveredJSON?["screenDeliveryError"] == nil)
        #expect(deliveredJSON?["screenDeliveryLatencyMs"] == nil)
    }

    @Test("the delivery vocabulary is pinned, so the live probe cannot drift")
    func vocabulary() {
        #expect(ScreenDelivery.vocabulary == ["notAttempted", "captured", "failed"])
    }
}

/// Serialized: these drive process-wide state, so they must not interleave with anything
/// else reading the same record.
@Suite(.serialized)
struct ScreenDeliveryRecordTests {

    @MainActor @Test("the facts read the record — and the record says nothing until asked")
    func factsReadTheRecord() {
        ScreenDeliveryRecord.resetForTesting()
        var measured = MultimodalDeviceFacts.permissionsOnly()
        #expect(measured.screenDelivery == .notAttempted)
        #expect(measured.screenDeliveryError == nil)
        #expect(measured.screenDeliveryLatencyMs == nil)

        ScreenDeliveryRecord.failed(reason: "could not start stream", latencyMs: 194)
        measured = MultimodalDeviceFacts.permissionsOnly()
        #expect(measured.screenDelivery == .failed)
        #expect(measured.screenDeliveryError == "could not start stream")
        #expect(measured.screenDeliveryLatencyMs == 194)
        // Whether that reads as blocked or unknown depends on the grant, but the verdict
        // never reads `ready` — the case the shipping host was caught publishing.
        #expect(measured.screenStatus != .ready)
        #expect(
            measured.screenStatus
                == (measured.screenPermission == .authorized ? .blocked : .unknown))

        // A later success overwrites: the record reports the last attempt, not a grudge.
        ScreenDeliveryRecord.captured(latencyMs: 1102)
        measured = MultimodalDeviceFacts.permissionsOnly()
        #expect(measured.screenDelivery == .captured)
        #expect(measured.screenDeliveryError == nil)
        #expect(measured.screenDeliveryLatencyMs == 1102)
        #expect(
            measured.screenStatus
                == (measured.screenPermission == .authorized ? .ready : .unknown))

        ScreenDeliveryRecord.resetForTesting()
        #expect(MultimodalDeviceFacts.permissionsOnly().screenDelivery == .notAttempted)
    }
}
