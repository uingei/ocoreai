// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Multimodal Server Handler — camera/audio/screen I/O and multimodal chat integration
///
/// Honesty contract for the three routes below (AGENTS.md invariant 2 — the surface never
/// claims more than the engine delivered):
///
///   - A capture response's `success` is *derived* from whether bytes came back. Before
///     this file had `CaptureResponse.init(dataType:dataURL:message:)`, the microphone
///     "recording started" leg returned `success: true` with `dataURL: null` — a client
///     that trusted `success` wrote an empty sample and never learned why.
///   - `POST /v1/multimodal/status` publishes `MultimodalDeviceFacts.gather()` next to the
///     toggles: a toggle is intent, permission and device presence are facts, and this host
///     is a live counter-example (camera/mic denied, 0 devices visible, 180 voices).
///   - `/v1/multimodal/speak` reports success only once it knows the text is non-empty and
///     at least one voice is installed — `AudioIO.speak` silently returns on empty text.

import Foundation
/// Cross-platform: HTTPTypes + Hummingbird available on macOS, iOS, iPadOS
import HTTPTypes
import Hummingbird
import Logging

/// Request: POST /v1/multimodal/capture — capture camera frame, audio sample, or screen
struct CaptureRequest: Codable {
    enum CaptureType: String, Codable {
        case camera, microphone, screen
    }

    let type: CaptureType
}

/// Response: multimodal capture result
struct CaptureResponse: Codable {
    let success: Bool
    let dataType: String
    let dataURL: String?
    let message: String?

    init(success: Bool, dataType: String, dataURL: String?, message: String?) {
        self.success = success
        self.dataType = dataType
        self.dataURL = dataURL
        self.message = message
    }

    /// The capture-path initializer: `success` is derived from the payload, so
    /// "`success: true`, here are no bytes" is not constructible on a capture leg.
    init(dataType: String, dataURL: String?, message: String) {
        self.init(success: dataURL != nil, dataType: dataType, dataURL: dataURL, message: message)
    }
}

/// Request: POST /v1/multimodal/speak — TTS output
struct SpeakRequest: Codable {
    let text: String
}

/// Request: POST /v1/multimodal/status — get/set multimodal toggles
struct StatusRequest: Codable {
    var cameraEnabled: Bool?
    var microphoneEnabled: Bool?
    var speakerEnabled: Bool?
    var screenCaptureEnabled: Bool?
}

/// Response: `POST /v1/multimodal/status`.
///
/// Three bands, in the order a reader should consult them: the caller's **intent**
/// (`*Enabled`), the **measured facts** (`*Permission`, `*Count`, omitted when the count
/// could not be taken), and the **verdict** per channel (`*Status`, from
/// `ChannelReadiness.vocabulary`) with `limitations` naming every reason a verdict is not
/// `ready`. Intent and fact disagree routinely; the verdict is the honest answer to "can
/// this box see / hear / speak right now".
struct StatusResponse: Codable {
    let cameraEnabled: Bool
    let microphoneEnabled: Bool
    let speakerEnabled: Bool
    let screenCaptureEnabled: Bool

    let cameraPermission: DevicePermission
    let microphonePermission: DevicePermission
    let speechRecognitionPermission: DevicePermission
    let screenPermission: DevicePermission

    let cameraDeviceCount: Int?
    let microphoneDeviceCount: Int?
    let speechVoiceCount: Int?

    let cameraStatus: ChannelReadiness
    let microphoneStatus: ChannelReadiness
    let speakerStatus: ChannelReadiness
    let screenStatus: ChannelReadiness
    let transcriptionStatus: ChannelReadiness

    /// One line per channel that is not `ready`. Empty means every channel measured ready —
    /// never "empty because nothing was checked".
    let limitations: [String]
}

/// Pure composition of the status payload — no MainActor, no AVFoundation, so the exact
/// wire content is assertable without hardware (`MultimodalStatusHonestyTests`).
func makeMultimodalStatusResponse(
    toggles: (camera: Bool, microphone: Bool, speaker: Bool, screen: Bool),
    facts: MultimodalDeviceFacts,
) -> StatusResponse {
    StatusResponse(
        cameraEnabled: toggles.camera,
        microphoneEnabled: toggles.microphone,
        speakerEnabled: toggles.speaker,
        screenCaptureEnabled: toggles.screen,
        cameraPermission: facts.cameraPermission,
        microphonePermission: facts.microphonePermission,
        speechRecognitionPermission: facts.speechRecognitionPermission,
        screenPermission: facts.screenPermission,
        cameraDeviceCount: facts.cameraDeviceCount,
        microphoneDeviceCount: facts.microphoneDeviceCount,
        speechVoiceCount: facts.speechVoiceCount,
        cameraStatus: facts.cameraStatus,
        microphoneStatus: facts.microphoneStatus,
        speakerStatus: facts.speakerStatus,
        screenStatus: facts.screenStatus,
        transcriptionStatus: facts.transcriptionStatus,
        limitations: facts.limitations,
    )
}

/// Handle multimodal capture (camera frame, audio recording, or screen)
func multimodalCaptureHandler(
    request: CaptureRequest,
    logger: Logger,
) async throws -> Response {
    switch request.type {
    case .camera:
        let captureService = await CaptureService.shared
        if let refusal = try await captureGate(
            channel: "camera",
            dataType: "image/jpeg",
            alreadyRunning: await captureService.isCapturing,
        ) {
            return refusal
        }
        logger.info("Multimodal: capturing camera frame")
        if await !captureService.isCapturing {
            _ = await captureService.startCapture()
        }
        if let frameURL = await captureService.captureFrame() {
            await MainActor.run {
                MultimodalState.shared.cameraSnapshot = frameURL
            }
            return try await Response.json(
                CaptureResponse(
                    dataType: "image/jpeg",
                    dataURL: frameURL,
                    message: "Frame captured",
                ))
        }
        return try await Response.json(
            CaptureResponse(
                dataType: "image/jpeg",
                dataURL: nil,
                message: await captureFailureNote(
                    channel: "camera",
                    serviceReason: await captureService.lastFrameError,
                    fallback: "No frame captured",
                ),
            ))

    case .microphone:
        let audioIO: AudioIO = await AudioIO.shared
        if let refusal = try await captureGate(
            channel: "microphone",
            dataType: "audio/caf",
            alreadyRunning: await audioIO.isRecording,
        ) {
            return refusal
        }
        logger.info("Multimodal: toggling microphone recording")
        if let audioData = await audioIO.toggleRecording() {
            return try await Response.json(
                CaptureResponse(
                    dataType: "audio/caf",
                    dataURL: audioData,
                    message: "Audio captured",
                ))
        }
        // Two-phase surface: this call started a recording rather than returning one.
        // That is progress, not a delivered sample, so `success` stays false — and if the
        // recorder never started (denied / no device) say so instead of implying a
        // recording is running.
        if await audioIO.isRecording {
            return try await Response.json(
                CaptureResponse(
                    dataType: "audio/caf",
                    dataURL: nil,
                    message: "Recording started — call capture again to collect the sample",
                ))
        }
        return try await Response.json(
            CaptureResponse(
                dataType: "audio/caf",
                dataURL: nil,
                message: await captureFailureNote(
                    channel: "microphone",
                    fallback: "Recording did not start — no microphone available",
                ),
            ))

    case .screen:
        let screenshotService = await ScreenshotService.shared
        if let refusal = try await captureGate(
            channel: "screen",
            dataType: "image/png",
            alreadyRunning: await screenshotService.isCapturing,
        ) {
            return refusal
        }
        logger.info("Multimodal: capturing screen")
        if let frameURL = await screenshotService.captureScreen() {
            await MainActor.run {
                MultimodalState.shared.screenSnapshot = frameURL
            }
            return try await Response.json(
                CaptureResponse(
                    dataType: "image/png",
                    dataURL: frameURL,
                    message: "Screen captured",
                ))
        }
        return try await Response.json(
            CaptureResponse(
                dataType: "image/png",
                dataURL: nil,
                message: await captureFailureNote(
                    channel: "screen",
                    serviceReason: await screenshotService.lastError,
                    fallback: "No screen frame captured",
                ),
            ))
    }
}

/// The permission gate shared by all three capture legs: answer the request from the
/// measured permission instead of discovering it by opening a modal dialog nobody on the
/// other end of a socket can answer (measured 10-14: the camera leg parked for ≥45s behind
/// `AVCaptureDevice.requestAccess`). `nil` means the channel may be touched.
///
/// A channel already streaming skips the gate — it could only have started with a grant,
/// and refusing it now would break a working capture.
private func captureGate(
    channel: String,
    dataType: String,
    alreadyRunning: Bool,
) async throws -> Response? {
    guard !alreadyRunning else { return nil }
    let permission = await MainActor.run {
        MultimodalDeviceFacts.permissionsOnly().permission(forChannel: channel)
    }
    guard case .refuse(let reason) = captureAttempt(channel: channel, permission: permission) else {
        return nil
    }
    return try await Response.json(
        CaptureResponse(dataType: dataType, dataURL: nil, message: "Capture refused — \(reason)"))
}

/// The measured reason a channel produced nothing, appended to a capture failure message.
///
/// Precedence: what the capture service observed (the specific failure — throttle, stalled
/// sensor, no photo output) beats what the OS facts say (permission / no device), which
/// beats the bare fallback. Silent: no TCC prompt, and a `serviceReason` costs nothing.
private func captureFailureNote(
    channel: String,
    serviceReason: String? = nil,
    fallback: String,
) async -> String {
    if let serviceReason, !serviceReason.isEmpty {
        return "\(fallback) — \(serviceReason)"
    }
    let facts = await MainActor.run { MultimodalDeviceFacts.permissionsOnly() }
    guard let reason = facts.limitation(forChannel: channel) else { return fallback }
    return "\(fallback) — \(reason)"
}

/// Handle TTS speech output
func multimodalSpeakHandler(
    request: SpeakRequest,
    logger: Logger,
) async throws -> Response {
    guard await MultimodalState.shared.speakerEnabled else {
        return try await Response.json(
            CaptureResponse(
                success: false,
                dataType: "tts",
                dataURL: nil,
                message: "Speaker is disabled",
            ))
    }
    // `AudioIO.speak` returns silently on empty text, so without this guard an empty
    // request used to answer `success: true` having queued nothing.
    let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        return try await Response.json(
            CaptureResponse(
                success: false,
                dataType: "tts",
                dataURL: nil,
                message: "Nothing to speak — text is empty",
            ))
    }
    // Voices are the asset TTS needs; tier support alone does not make this box able to
    // talk (a system with no installed voices synthesizes nothing).
    let voiceCount = await MainActor.run { MultimodalDeviceFacts.voiceCount() }
    if voiceCount == 0 {
        return try await Response.json(
            CaptureResponse(
                success: false,
                dataType: "tts",
                dataURL: nil,
                message: "No installed speech voices — cannot synthesize",
            ))
    }
    logger.info(
        "Multimodal: speaking text (\(text.count) chars, \(voiceCount.map(String.init) ?? "?") voices)"
    )
    await AudioIO.shared.speak(text)
    return try await Response.json(
        CaptureResponse(
            success: true,
            dataType: "tts",
            dataURL: nil,
            message: "Speaking",
        ))
}

/// Handle multimodal status query/update
func multimodalStatusHandler(
    request: StatusRequest?,
    logger _: Logger,
) async throws -> Response {
    let result: StatusResponse = await MainActor.run { () -> StatusResponse in
        let state = MultimodalState.shared
        if let req = request {
            if let camera = req.cameraEnabled { state.cameraEnabled = camera }
            if let mic = req.microphoneEnabled { state.microphoneEnabled = mic }
            if let spk = req.speakerEnabled { state.speakerEnabled = spk }
            if let screen = req.screenCaptureEnabled { state.screenCaptureEnabled = screen }
        }
        return makeMultimodalStatusResponse(
            toggles: (
                camera: state.cameraEnabled,
                microphone: state.microphoneEnabled,
                speaker: state.speakerEnabled,
                screen: state.screenCaptureEnabled,
            ),
            facts: MultimodalDeviceFacts.gather(),
        )
    }
    return try await Response.json(result)
}

/// Encode any Encodable to JSON Response
extension Response {
    fileprivate static func json(
        _ value: some Encodable,
    ) async throws -> Self {
        var headers: HTTPFields = [:]
        headers[.contentType] = "application/json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return Response(
            status: .ok,
            headers: headers,
            body: .init { writer in
                try await writer.write(ByteBuffer(data: data))
                try await writer.finish(nil)
            },
        )
    }
}
