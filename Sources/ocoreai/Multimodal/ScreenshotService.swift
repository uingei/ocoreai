// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ScreenshotService — macOS screen capture via ScreenCaptureKit
///
/// Uses SCScreenshotManager.captureImage() for one-shot capture.
/// Continuous mode polls captureScreen() at a configurable interval.
///
/// Migrated to @Observable (Swift 5.9+ standard per Apple API Design Guidelines)

#if os(macOS)

import AppKit
import Foundation
import os.log
import ScreenCaptureKit

private let screenshotLogger = Logger(subsystem: "ocoreai", category: "screenshot")

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

	// Settings
	private let frameInterval: TimeInterval = 2.0

	// Background continuous task
	private var captureTask: Task<Void, Never>?

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
		// If continuous capture is running, reuse the latest frame
		if let cached = self.latestFrameDataURL {
			return cached
		}

		guard let url = await Self.captureOnce() else {
			screenshotLogger.warning("[ScreenshotService] Capture failed")
			return nil
		}
		self.latestFrameDataURL = url
		NotificationCenter.default.post(name: .screenFrameAvailable, object: nil)
		screenshotLogger.info("[ScreenshotService] Captured frame: \(url.prefix(20))...")
		return url
	}

	// MARK: - Internal capture implementation

	nonisolated static func captureOnce() async -> String? {
		// 1. Get shareable content
		guard let content = try? await SCShareableContent.excludingDesktopWindows(
			false,
			onScreenWindowsOnly: true
		) else {
			screenshotLogger.error("[ScreenshotService] Failed to get shareable content")
			return nil
		}

		// 2. Get first display
		guard let screen = content.displays.first else {
			screenshotLogger.error("[ScreenshotService] No screens/displays available")
			return nil
		}

		// 3. Build content filter
		let filter = SCContentFilter(display: screen, including: [])

		// 4. Stream configuration
		let config = SCStreamConfiguration()
		config.width = screen.width
		config.height = screen.height

		// 5. Capture screenshot via SCScreenshotManager (returns CGImage directly)
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

				// Encode to JPEG data URL
				if let url = Self.encodeFrame(cgImage) {
					cont.resume(returning: url)
				} else {
					cont.resume(returning: nil)
				}
			}
		}
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

	// MARK: - Continuous capture

	/// Start continuous screen capture at configured interval
	func startCapture() {
		guard !isCapturing else { return }
		isCapturing = true
		captureTask = Task(priority: .utility) {
			while !Task.isCancelled {
				await Self.shared.captureScreen()
				do { try await Task.sleep(for: .seconds(Self.shared.frameInterval)) }
				catch { break }
			}
		}
		screenshotLogger.info("[ScreenshotService] Continuous capture started (interval=\(self.frameInterval)s)")
	}

	/// Stop continuous screen capture
	func stopCapture() {
		captureTask?.cancel()
		captureTask = nil
		isCapturing = false
		screenshotLogger.info("[ScreenshotService] Continuous capture stopped")
	}

	/// Toggle continuous capture
	func toggleCapture() {
		if self.isCapturing { stopCapture() } else { startCapture() }
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
