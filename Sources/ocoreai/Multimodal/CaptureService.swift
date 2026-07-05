// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Camera capture service — real-time frame sampling for visual input
/// Cross-platform: AVFoundation available on macOS, iOS, iPadOS
///
/// Migrated to @Observable (Swift 5.9+ standard per Apple API Design Guidelines)

import AVFoundation
import Foundation
import os.log
import UniformTypeIdentifiers

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
			mediaType: .video, position: .unspecified,
		).devices
		availableCameras = devices
		selectedCameraID = devices.first?.uniqueID
	}

	// MARK: - Control

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
			try session.addInput(AVCaptureDeviceInput(device: device))
			session.commitConfiguration()
			// startRunning is synchronous — ObjC exceptions don't bridge to Swift throw
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

	/// Capture a single frame and return it as a base64 data URL.
	/// Frames are resized to max 1280px wide and JPEG-compressed at 0.6 quality
	/// to reduce token consumption when sent to VLM.
	/// Returns nil if capturing is not active or no photo output is configured.
	func captureFrame() async -> String? {
		guard isCapturing, session.isRunning else { return nil }
		let now = Date().timeIntervalSince1970
		guard now - lastFrameTime >= frameInterval else { return nil }
		lastFrameTime = now

		let out = session.outputs.first as? AVCapturePhotoOutput
		guard let out else { return nil }

		let settings = AVCapturePhotoSettings()
		settings.flashMode = .off

		return await withCheckedContinuation { cont in
			out.capturePhoto(with: settings, delegate: FrameCaptureDelegate { data in
				if let d = data {
					let compressed = self.compressCameraFrame(d)
					cont.resume(returning: "data:image/jpeg;base64,\(compressed.base64EncodedString())")
				} else {
					cont.resume(returning: nil)
				}
			})
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

		guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
			return data
		}

		// Convert CGImage back to JPEG at 0.6 quality
		guard let dest = CFDataCreateMutable(nil, 0),
			  let destination = CGImageDestinationCreateWithData(dest, UTType.jpeg.identifier as CFString, 1, nil) else {
			return data
		}

		let propOpts: [CFString: Any] = [
			kCGImageDestinationLossyCompressionQuality: 0.6,
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

private class FrameCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
	private let handler: (Data?) -> Void
	init(completion: @escaping (Data?) -> Void) {
		handler = completion
	}

	func photoOutput(_: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
		if let _ = error { handler(nil); return }
		handler(photo.fileDataRepresentation())
	}
}
