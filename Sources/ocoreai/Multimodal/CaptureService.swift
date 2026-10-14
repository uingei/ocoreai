// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Camera capture service — real-time frame sampling for visual input
/// Cross-platform: AVFoundation available on macOS, iOS, iPadOS
///
/// Migrated to @Observable (Swift 5.9+ standard per Apple API Design Guidelines)

import AVFoundation
import Foundation
import UniformTypeIdentifiers
import Vision
import os.log

private let captureLogger = Logger(subsystem: "ocoreai", category: "capture")

extension Notification.Name {
    static let cameraFrameAvailable = Notification.Name("CameraFrameAvailable")
}

@Observable
@MainActor
final class CaptureService: NSObject {
    static let shared = CaptureService()

    var availableCameras: [AVCaptureDevice] = []
    var selectedCameraID: String?
    var isCapturing: Bool = false
    var latestFrameDataURL: String?
    /// OCR-recognized text from the latest frame (via Vision).
    /// If this is non-nil, the frame contains significant on-screen text
    /// and can be sent as structured text (~20 tokens) instead of an image (~800 tokens).
    var latestOCRText: String? = nil

    private let session = AVCaptureSession()
    private let frameInterval: TimeInterval = 2.0
    private var lastFrameTime: TimeInterval = 0

    override init() {
        super.init()
        discoverCameras()
    }

    // MARK: - Discovery

    func discoverCameras() {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video, position: .unspecified,
        ).devices
        availableCameras = devices
        selectedCameraID = devices.first?.uniqueID
    }

    // MARK: - Control

    /// Start capturing — also begins background periodic frame sampling
    @discardableResult
    func startCapture() async -> Bool {
        guard let deviceId = selectedCameraID,
            let device = availableCameras.first(where: { $0.uniqueID == deviceId })
        else {
            return false
        }

        guard await AVCaptureDevice.requestAccess(for: .video) else { return false }

        do {
            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            for output in session.outputs {
                session.removeOutput(output)
            }
            try session.addInput(AVCaptureDeviceInput(device: device))
            session.addOutput(AVCapturePhotoOutput())
            session.commitConfiguration()
            // startRunning is synchronous — ObjC exceptions don't bridge to Swift throw
            session.startRunning()
            isCapturing = true
            _ = startBackgroundSampling()
        } catch {
            captureLogger.error("[CaptureService] Start error: \(error.localizedDescription)")
            return false
        }
        return true
    }

    func stopCapture() {
        stopBackgroundSampling()
        session.stopRunning()
        isCapturing = false
    }

    // MARK: - Background Sampling

    /// Periodically sample frames so MultimodalState always has a fresh snapshot
    /// without requiring the user to tap "Capture"
    private var _sampleTask: Task<Void, Never>?

    private func startBackgroundSampling() -> Task<Void, Never> {
        stopBackgroundSampling()
        let task = Task<Void, Never>(priority: .utility) {
            while !Task.isCancelled {
                // Use internal capture path — updates latestFrameDataURL so UI stays fresh
                if let frameURL = await self.capturePhotoFromSession() {
                    self.latestFrameDataURL = frameURL
                }
                try? await Task.sleep(for: .seconds(self.frameInterval))
            }
        }
        _sampleTask = task
        captureLogger.info(
            "[CaptureService] Background sampling started (interval=\(self.frameInterval)s)")
        return task
    }

    private func stopBackgroundSampling() {
        _sampleTask?.cancel()
        _sampleTask = nil
    }

    // MARK: - Frame

    /// Capture a single frame and return it as a base64 data URL.
    /// Frames are resized to max 1280px wide and JPEG-compressed at 0.6 quality
    /// to reduce token consumption when sent to VLM.
    /// Returns nil if capturing is not active or no photo output is configured.
    /// Why the last frame request failed, in one line — measured at the moment of the
    /// failure, so an HTTP response can say which of these it was instead of "no frame".
    /// Cleared on success.
    private(set) var lastFrameError: String?

    func captureFrame() async -> String? {
        guard isCapturing, session.isRunning else {
            lastFrameError = "capture is not running"
            return nil
        }
        let now = Date().timeIntervalSince1970
        guard now - lastFrameTime >= frameInterval else {
            lastFrameError = "sampling is throttled to one frame per \(Int(frameInterval))s"
            return nil
        }
        lastFrameTime = now

        let dataURL = await capturePhotoFromSession()
        // Always update shared state so UI previews stay fresh
        if let url = dataURL {
            latestFrameDataURL = url
            lastFrameError = nil
        }
        return dataURL
    }

    /// Internal: perform the actual photo capture and compression.
    /// Used by both foreground (user tap) and background (periodic sampling).
    /// How long a photo request may stay outstanding before the caller is told it failed.
    /// A still capture on a running session completes in well under a second; 8s is loose
    /// enough for a cold sensor and short enough that no request or sampler loop is ever
    /// parked on it. See `FrameCaptureDelegate.fire` for why a deadline is required at all.
    static let frameTimeout: TimeInterval = 8

    /// Delegates for captures currently outstanding. `capturePhotoWithSettings:delegate:`
    /// takes the delegate as a parameter and the SDK header documents no retention ("An
    /// object conforming to the AVCapturePhotoCaptureDelegate protocol… May not be nil"),
    /// so the caller owns the strong reference for the duration of the capture — an inline
    /// temporary can be released before the callback, and the continuation then never
    /// resumes. Measured 10-14 by scripts/probes/04-multimodal-honesty.sh: with the camera
    /// authorized, `{"type":"camera"}` parked ≥45s and never answered.
    private var pendingFrameDelegates: [FrameCaptureDelegate] = []

    private func capturePhotoFromSession() async -> String? {
        let out = session.outputs.first as? AVCapturePhotoOutput
        guard let out else {
            lastFrameError = "no photo output is configured on the capture session"
            return nil
        }
        // One capture at a time: with the camera stalled, the 2s sampler would otherwise
        // pile up a delegate and a continuation per tick.
        guard pendingFrameDelegates.isEmpty else {
            lastFrameError = "a capture is already in flight"
            return nil
        }

        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        let timeout = Self.frameTimeout

        return await withCheckedContinuation { cont in
            let delegate = FrameCaptureDelegate { data in
                if let d = data {
                    let compressed = self.compressCameraFrame(d)
                    cont.resume(
                        returning: "data:image/jpeg;base64,\(compressed.base64EncodedString())")
                    // Run Vision OCR in background — updates latestOCRText for downstream
                    Task { @MainActor in
                        self.latestOCRText = await VisionOCR.extractText(from: compressed)
                    }
                } else {
                    cont.resume(returning: nil)
                }
            }
            pendingFrameDelegates.append(delegate)
            out.capturePhoto(with: settings, delegate: delegate)

            // Deadline: whoever fires first wins, so the wait always ends — with a frame if
            // AVFoundation delivers, with nil (and a reason) if it does not.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                if delegate.fire(nil) {
                    self?.lastFrameError =
                        "the camera did not deliver a frame within \(Int(timeout))s"
                }
                self?.pendingFrameDelegates.removeAll { $0 === delegate }
            }
        }
    }

    /// Resize frame to max 1280px and compress to JPEG at 0.6 quality.
    /// If resize fails the original data is returned unchanged.
    /// Uses CGImageSourceCreateThumbnailAtIndex for cross-platform correctness.
    private func compressCameraFrame(_ data: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return data
        }

        let maxPixel: CGFloat = 1280
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
        else {
            return data
        }

        // Convert CGImage back to JPEG at 0.6 quality
        guard let dest = CFDataCreateMutable(nil, 0),
            let destination = CGImageDestinationCreateWithData(
                dest, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            return data
        }

        let propOpts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.6
        ]
        CGImageDestinationSetProperties(destination, propOpts as CFDictionary)
        CGImageDestinationAddImage(destination, thumbnail, nil)

        guard CGImageDestinationFinalize(destination) else {
            return data
        }

        return dest as Data
    }

    func toggleCapture() async {
        if isCapturing { stopCapture() } else { _ = await startCapture() }
    }
}

/// Bridges AVFoundation's photo callback to one exactly-once delivery.
///
/// `@unchecked Sendable` justification: the only mutable state is `armed`, read and written
/// under `fireLock`; `handler` is an immutable `@escaping (Data?) -> Void`. `fire` is
/// called from AVFoundation's callback queue and from the MainActor deadline path, so the
/// lock — not isolation — is what makes the exactly-once guarantee hold.
private final class FrameCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate,
    @unchecked Sendable
{
    private let fireLock = NSLock()
    private var armed = true
    private let handler: (Data?) -> Void

    init(completion: @escaping (Data?) -> Void) {
        handler = completion
    }

    /// Deliver the result once. Returns true if this call was the one that delivered, so the
    /// caller can tell a real frame from a deadline it won.
    @discardableResult
    func fire(_ data: Data?) -> Bool {
        fireLock.lock()
        guard armed else {
            fireLock.unlock()
            return false
        }
        armed = false
        fireLock.unlock()
        handler(data)
        return true
    }

    func photoOutput(
        _: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?
    ) {
        if error != nil {
            _ = fire(nil)
            return
        }
        _ = fire(photo.fileDataRepresentation())
    }
}
