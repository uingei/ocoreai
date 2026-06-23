// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Multimodal Server Handler — camera/audio I/O and multimodal chat integration

/// Cross-platform: HTTPTypes + Hummingbird available on macOS, iOS, iPadOS
import HTTPTypes
import Hummingbird
import Logging
import Foundation

/// Request: POST /v1/multimodal/capture — capture camera frame or audio sample
struct CaptureRequest: Codable {
    enum CaptureType: String, Codable {
        case camera, microphone
    }
    let type: CaptureType
}

/// Response: multimodal capture result
struct CaptureResponse: Codable {
    let success: Bool
    let dataType: String
    let dataURL: String?
    let message: String?
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
}

struct StatusResponse: Codable {
    let cameraEnabled: Bool
    let microphoneEnabled: Bool
    let speakerEnabled: Bool
}

/// Handle multimodal capture (camera frame or audio recording)
func multimodalCaptureHandler(
    request: CaptureRequest,
    logger: Logger
) async throws -> Response {
    switch request.type {
    case .camera:
        let captureService = await CaptureService.shared
        logger.info("Multimodal: capturing camera frame")
        if await !captureService.isCapturing {
            _ = await captureService.startCapture()
        }
        if let frameURL = await captureService.captureFrame() {
            await MainActor.run {
                MultimodalState.shared.cameraSnapshot = frameURL
            }
            return try await .json(CaptureResponse(
                success: true,
                dataType: "image/jpeg",
                dataURL: frameURL,
                message: "Frame captured"
            ))
        }
        return try await Response.json(CaptureResponse(
            success: false,
            dataType: "image/jpeg",
            dataURL: nil,
            message: "No frame captured"
        ))

    case .microphone:
        let audioIO: AudioIO = await AudioIO.shared
        logger.info("Multimodal: toggling microphone recording")
        if let audioData = await audioIO.toggleRecording() {
            return try await Response.json(CaptureResponse(
                success: true,
                dataType: "audio/caf",
                dataURL: audioData,
                message: "Audio captured"
            ))
        }
        return try await Response.json(CaptureResponse(
            success: true,
            dataType: "audio/caf",
            dataURL: nil,
            message: "Recording started"
        ))
    }
}

/// Handle TTS speech output
func multimodalSpeakHandler(
    request: SpeakRequest,
    logger: Logger
) async throws -> Response {
    guard await MultimodalState.shared.speakerEnabled else {
        return try await Response.json(CaptureResponse(
            success: false,
            dataType: "tts",
            dataURL: nil,
            message: "Speaker is disabled"
        ))
    }
    logger.info("Multimodal: speaking text (\\(request.text.count) chars)")
    await AudioIO.shared.speak(request.text)
    return try await Response.json(CaptureResponse(
        success: true,
        dataType: "tts",
        dataURL: nil,
        message: "Speaking"
    ))
}

/// Handle multimodal status query/update
func multimodalStatusHandler(
    request: StatusRequest?,
    logger: Logger
) async throws -> Response {
    let result: StatusResponse = await MainActor.run { () -> StatusResponse in
        let state = MultimodalState.shared
        if let req = request {
            if let camera = req.cameraEnabled { state.cameraEnabled = camera }
            if let mic = req.microphoneEnabled { state.microphoneEnabled = mic }
            if let spk = req.speakerEnabled { state.speakerEnabled = spk }
        }
        return StatusResponse(
            cameraEnabled: state.cameraEnabled,
            microphoneEnabled: state.microphoneEnabled,
            speakerEnabled: state.speakerEnabled
        )
    }
    return try await Response.json(result)
}

/// Encode any Encodable to JSON Response
private extension Response {
    static func json<T: Encodable>(
        _ value: T
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
            }
        )
    }
}
