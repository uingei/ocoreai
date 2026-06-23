// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Camera capture service — real-time frame sampling for visual input
/// Cross-platform: AVFoundation available on macOS, iOS, iPadOS
///
/// Migrated to @Observable (Swift 5.9+ standard per Apple API Design Guidelines)

import AVFoundation
import Foundation
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
            mediaType: .video, position: .unspecified
        ).devices
        availableCameras = devices
        selectedCameraID = devices.first?.uniqueID
    }
    
    // MARK: - Control
    
    @discardableResult
    func startCapture() async -> Bool {
        guard let deviceId = selectedCameraID,
              let device = availableCameras.first(where: { $0.uniqueID == deviceId }) else {
            return false
        }
        do {
            guard await AVCaptureDevice.requestAccess(for: .video) else { return false }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            for input in session.inputs { session.removeInput(input) }
            if session.canAddInput(try AVCaptureDeviceInput(device: device)) {
                session.addInput(try AVCaptureDeviceInput(device: device))
            }
            session.startRunning()
            isCapturing = true
        } catch {
            captureLogger.error("[CaptureService] Start error: \(error.localizedDescription)")
            return false
        }
        return true
    }
    
    func stopCapture() {
        session.stopRunning()
        isCapturing = false
    }
    
    // MARK: - Frame
    
    func captureFrame() async -> String? {
        guard isCapturing, session.isRunning else { return nil }
        let now = Date().timeIntervalSince1970
        guard now - lastFrameTime >= frameInterval else { return nil }
        lastFrameTime = now
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        return await withCheckedContinuation { cont in
            let out = session.outputs.first as? AVCapturePhotoOutput
            out?.capturePhoto(with: settings, delegate: FrameCaptureDelegate { data in
                if let d = data {
                    cont.resume(returning: "data:image/jpeg;base64,\(d.base64EncodedString())")
                } else {
                    cont.resume(returning: nil)
                }
            })
        }
    }
    
    func toggleCapture() async {
        if isCapturing { stopCapture() } else { _ = await startCapture() }
    }
}

private class FrameCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let handler: (Data?) -> Void
    init(completion: @escaping (Data?) -> Void) { self.handler = completion }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let _ = error { handler(nil); return }
        handler(photo.fileDataRepresentation())
    }
}
