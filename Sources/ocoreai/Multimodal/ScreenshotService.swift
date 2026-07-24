// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ScreenshotService — macOS screen capture via ScreenCaptureKit
///
/// Real-time capture powered by SCStream (delegate callbacks, no polling).
/// One-shot fallback via SCScreenshotManager.captureImage() for backwards compatibility.
///
/// Migrated to @Observable (Swift 5.9+ standard per Apple API Design Guidelines)

#if os(macOS)

import AppKit
import CoreFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import os.log
import ScreenCaptureKit
import Vision

private let screenshotLogger = Logger(subsystem: "ocoreai", category: "screenshot")

// Rate limit constant — not tied to MainActor so FrameOutput can read it directly.
private let frameRateLimitSeconds: TimeInterval = 1.0

extension Notification.Name {
	static let screenFrameAvailable = Notification.Name("ScreenFrameAvailable")
}

@Observable
@MainActor
final class ScreenshotService {
	static let shared = ScreenshotService()
	static let isAvailable = true

	var isCapturing: Bool = false
	private(set) var screenCount: Int = 0
	private(set) var latestFrameDataURL: String?
	
	/// OCR-recognized text from the latest screen frame (via Vision).
	/// If this is non-nil, the frame contains significant on-screen text
	/// and can be sent as structured text (~20 tokens) instead of an image (~800 tokens).
	var latestOCRText: String? = nil

	// SCStream-based capture
	private var stream: SCStream?
	private var streamOutput: FrameOutput?

	private init() {
		self.screenCount = NSScreen.screens.count
	}

	// MARK: - Discovery

	nonisolated func discoverScreens() {
		Task { @MainActor in
			Self.shared.screenCount = NSScreen.screens.count
		}
	}

	// MARK: - One-shot capture

	@discardableResult
	func captureScreen() async -> String? {
		// Reuse cached frame when continuous capture is active.
		if self.isCapturing, let cached = self.latestFrameDataURL {
			return cached
		}

		guard let url = await Self.captureOnce() else {
			screenshotLogger.warning("[ScreenshotService] One-shot capture failed")
			return nil
		}
		self.latestFrameDataURL = url
		screenshotLogger.info("[ScreenshotService] One-shot frame: \(url.prefix(20))...")
		return url
	}

	// MARK: - Internal capture implementation

	nonisolated static func captureOnce() async -> String? {
		guard let content = try? await SCShareableContent.excludingDesktopWindows(
			false,
			onScreenWindowsOnly: true
		) else {
			screenshotLogger.error("[ScreenshotService] Failed to get shareable content")
			return nil
		}

		guard let screen = content.displays.first else {
			screenshotLogger.error("[ScreenshotService] No screens/displays available")
			return nil
		}

		let filter = SCContentFilter(display: screen, including: [])
		let config = SCStreamConfiguration()
		config.width = screen.width
		config.height = screen.height

		return await withCheckedContinuation { cont in
			SCScreenshotManager.captureImage(
				contentFilter: filter,
				configuration: config
			) { cgImageRef, error in
				if let err = error {
					screenshotLogger.error("[ScreenshotService] SCScreenshotManager error: \(err.localizedDescription)")
					cont.resume(returning: nil)
					return
				}

				guard let cgImage = cgImageRef else {
					screenshotLogger.error("[ScreenshotService] SCScreenshotManager returned nil image")
					cont.resume(returning: nil)
					return
				}

				cont.resume(returning: Self.encodeFrame(cgImage))
			}
		}
	}

	/// Helper: extract JPEG bytes from a base64 data URL so downstream can reuse
	/// without re-decoding the full frame.
	nonisolated static func jpegDataFromDataURL(_ dataURL: String) -> Data? {
		guard dataURL.hasPrefix("data:image/jpeg;base64,") else { return nil }
		let base64 = String(dataURL.dropFirst("data:image/jpeg;base64,".count))
		return Data(base64Encoded: base64)
	}

	// MARK: - Image encoding

	nonisolated static func encodeFrame(_ image: CGImage) -> String? {
		let scale: CGFloat = 0.5
		let scaledWidth = CGFloat(image.width) * scale
		let scaledHeight = CGFloat(image.height) * scale

		guard let ctx = CGContext(
			data: nil,
			width: Int(scaledWidth),
			height: Int(scaledHeight),
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
		) else { return nil }

		ctx.interpolationQuality = CGInterpolationQuality.medium
		ctx.scaleBy(x: scale, y: scale)
		ctx.draw(image, in: CGRect(origin: .zero, size: CGSize(width: scaledWidth, height: scaledHeight)))

		guard let scaled = ctx.makeImage() else { return nil }

		let rep = NSBitmapImageRep(cgImage: scaled)
		guard let jpegData = rep.representation(
			using: NSBitmapImageRep.FileType.jpeg,
			properties: [NSBitmapImageRep.PropertyKey.compressionFactor: 0.6]
		) else { return nil }

		return "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
	}

	// MARK: - Continuous capture (SCStream)

	/// Start real-time screen capture via SCStream.
	/// Frames arrive at ~30fps; we rate-limit to 1fps for memory efficiency.
	func startCapture() {
		guard !isCapturing else { return }

		// SCStream setup runs off MainActor on a background task.
		Task {
			// 1. Get shareable content
			guard let content = try? await SCShareableContent.excludingDesktopWindows(
				false,
				onScreenWindowsOnly: true
			) else {
				screenshotLogger.error("[ScreenshotService] SCStream: failed to get shareable content")
				await MainActor.run { Self.shared.isCapturing = false }
				return
			}

			guard let screen = content.displays.first else {
				screenshotLogger.error("[ScreenshotService] SCStream: no displays available")
				await MainActor.run { Self.shared.isCapturing = false }
				return
			}

			// 2. Build content filter (screen-only, no window chrome)
			let filter = SCContentFilter(display: screen, including: [])

			// 3. Stream configuration
			let config = SCStreamConfiguration()
			config.width = screen.width
			config.height = screen.height

			// 4. Create the stream output handler (delegate for both lifecycle + frames)
			let output = FrameOutput(service: Self.shared)

			// 5. Create SCStream with delegate + output
			do {
				let newStream = SCStream(
					filter: filter,
					configuration: config,
					delegate: output
				)
				try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: nil)

				// Store references on MainActor (isolated properties)
				await MainActor.run {
					Self.shared.stream = newStream
					Self.shared.streamOutput = output
					Self.shared.isCapturing = true
				}

				// 6. Start capture — callback-driven, no polling
				do {
					try await newStream.startCapture()
					screenshotLogger.info("[ScreenshotService] SCStream capture started")
				} catch {
					screenshotLogger.error("[ScreenshotService] SCStream startCapture error: \(error.localizedDescription)")
					await MainActor.run { Self.shared.isCapturing = false }
				}
			} catch {
				screenshotLogger.error("[ScreenshotService] SCStream setup failed: \(error.localizedDescription)")
				await MainActor.run { Self.shared.isCapturing = false }
			}
		}
	}

	/// Stop continuous screen capture
	func stopCapture() {
		// stopCapture is async — we await it, then immediately nil out references.
		Task {
			let s = self.stream
			do { try await s?.stopCapture() } catch {
				screenshotLogger.error("[ScreenshotService] SCStream stopCapture error: \(error.localizedDescription)")
			}
			self.stream = nil
			self.streamOutput = nil
			self.isCapturing = false
		}
		screenshotLogger.info("[ScreenshotService] SCStream capture stopped")
	}

	/// Toggle continuous capture
	func toggleCapture() {
		if self.isCapturing { stopCapture() } else { startCapture() }
	}

	// MARK: - Frame caching

	/// Update latest frame data URL on MainActor for @Observable reactivity.
	private func updateFrameURL(_ url: String) {
		self.latestFrameDataURL = url
		screenshotLogger.info("[ScreenshotService] Frame updated: \(url.prefix(20))...")
	}

	// MARK: - SCStream delegate + output (internal helper)

	/// Handles SCStreamDelegate lifecycle and SCStreamOutput frame delivery.
	/// NSObject subclass required by SCStream delegate protocols.
	/// Carries its own rate-limit timer so the callback thread never blocks.
	///
	/// `service` is marked `nonisolated(unsafe)` because FrameOutput callbacks
	/// fire on SCStream's internal queue (nonisolated), but we only interact
	/// with the service from inside `Task { @MainActor }` or DispatchQueue.main
	/// blocks where MainActor isolation is guaranteed.
	private final class FrameOutput: NSObject, SCStreamDelegate, SCStreamOutput {

		nonisolated(unsafe) private weak var service: ScreenshotService?
		private let lock = NSLock()
		private var _lastFrameTime: UInt64 = 0

		init(service: ScreenshotService) {
			self.service = service
			super.init()
		}

		// — SCStreamDelegate —

		func streamDidBecomeActive(_ stream: SCStream) {
			screenshotLogger.info("[ScreenshotService] SCStream became active")
		}

		func streamDidBecomeInactive(_ stream: SCStream) {
			screenshotLogger.info("[ScreenshotService] SCStream became inactive")
		}

		func stream(_ stream: SCStream, didStopWithError error: Error) {
			screenshotLogger.error("[ScreenshotService] SCStream stopped with error: \(error.localizedDescription)")
			let service = self.service
			Task { @MainActor in
				service?.isCapturing = false
				service?.stream = nil
			}
		}

		// — SCStreamOutput —

		func stream(_ stream: SCStream, didOutput sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
			guard type == .screen else { return }

			// Rate limit: skip frames arriving within frameRateLimitSeconds
			let now = UInt64(DispatchTime.now().uptimeNanoseconds)
			guard !shouldSkipFrame(now: now) else { return }

			// Extract CGImage via CIImage (standard CVPixelBuffer → CGImage bridge)
			guard let imageBuffer = sampleBuffer.imageBuffer else {
				return
			}

			CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
			defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

			let ciImage = CIImage(cvPixelBuffer: imageBuffer)
			let context = CIContext(options: nil)
			guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
				return
			}

			// Encode to JPEG data URL
			guard let url = ScreenshotService.encodeFrame(cgImage) else {
				return
			}

			// Dispatch frame update to MainActor — capture service reference first
			// so `self` is not held across the closure boundary.
			let service = self.service
			Task { @MainActor in
				service?.updateFrameURL(url)
			}
			
			// Run Vision OCR in background — updates latestOCRText for downstream
			// Screen frames often contain more text than camera frames (terminal, IDE, docs),
			// so OCR bridge saves even more tokens here (~97% reduction).
			Task {
				guard let jpegData = ScreenshotService.jpegDataFromDataURL(url) else { return }
				let ocrText = await VisionOCR.extractText(from: jpegData)
				Task { @MainActor in
					service?.latestOCRText = ocrText
				}
			}
		}

		// Checks rate limit under lock; returns true if the caller should drop this frame.
		private func shouldSkipFrame(now: UInt64) -> Bool {
			lock.lock()
			defer { lock.unlock() }

			let elapsed = Double(now - _lastFrameTime) / 1e9
			guard elapsed >= frameRateLimitSeconds else {
				return true
			}
			_lastFrameTime = now
			return false
		}
	}
}

#elseif os(iOS) || os(visionOS)

import Foundation
import os.log

@Observable
@MainActor
final class ScreenshotService: NSObject {
	static let shared = ScreenshotService()
	static let isAvailable = false
	var isCapturing: Bool = false
	var latestFrameDataURL: String?

	@discardableResult
	func captureScreen() async -> String? {
		_ = Logger(subsystem: "ocoreai", category: "screenshot")
			.warning("[ScreenshotService] Screen capture not supported on this platform")
		return nil
	}

	func startCapture() {}
	func stopCapture() { self.isCapturing = false }
	func toggleCapture() {}
}

#endif
