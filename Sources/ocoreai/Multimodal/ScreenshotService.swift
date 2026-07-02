// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ScreenshotService — macOS screen capture (opt-in feature)
///
/// Screen capture requires ScreenCaptureKit which has breaking API changes
/// across SDK versions. This service gracefully degrades when the API
/// is unavailable or permissions are denied.
///
/// iOS/visionOS: stub (Camera via CaptureService is the visual input on mobile).
///
/// Migrated to @Observable (Swift 5.9+ standard per Apple API Design Guidelines)

#if os(macOS)

	import AppKit
	import Foundation
	import os.log

	private let screenshotLogger = Logger(subsystem: "ocoreai", category: "screenshot")

	extension Notification.Name {
		static let screenFrameAvailable = Notification.Name("ScreenFrameAvailable")
	}

	@Observable
	@MainActor
	final class ScreenshotService {
		static let shared = ScreenshotService()

		/// True when this class can be used (macOS)
		static let isAvailable = true

		/// Screen capture actually works (SC stream initialized successfully)
		var isCaptureEnabled: Bool = false

		/// Is continuous capture running
		var isCapturing: Bool = false

		/// Available screen count
		private(set) var screenCount: Int = 0

		/// Currently selected screen index (0 = primary)
		var selectedScreen: Int = 0

		/// Latest screenshot as base64 data URL (PNG)
		private(set) var latestFrameDataURL: String?

		/// Capture interval in seconds (default 2.0)
		private let frameInterval: TimeInterval = 2.0

		/// Continuous capture task
		private var captureTask: Task<Void, Never>?

		private init() {
			self.screenCount = NSScreen.screens.count
		}

		// MARK: - Discovery

		/// Refresh screen count from system
		nonisolated func discoverScreens() {
			Task { @MainActor in
				Self.shared.screenCount = NSScreen.screens.count
			}
		}

		// MARK: - One-shot capture

		/// Capture a single full-screen frame as base64 PNG data URL.
		/// Returns nil if screen capture permission is not granted.
		@discardableResult
		func captureScreen() async -> String? {
			// ScreenCaptureKit API has breaking changes across SDK versions.
			// This is intentionally a no-op stub until we lock to a specific SDK
			// and implement the SCStreamOutput → CMSampleBuffer → CGImage pipeline.
			screenshotLogger.warning("[ScreenshotService] Screen capture is opt-in and not yet fully implemented")
			return nil
		}

		// MARK: - Continuous feed

		/// Start continuous screen capture at 2s interval
		func startCapture() {
			guard !self.isCapturing else { return }
			self.isCapturing = true
			self.captureTask = Task {
				while !Task.isCancelled {
					await Self.shared.captureScreen()
					do { try await Task.sleep(nanoseconds: UInt64(Self.shared.frameInterval * 1_000_000_000)) }
					catch { break }
				}
			}
			screenshotLogger.info("[ScreenshotService] Continuous capture started (stub)")
		}

		/// Stop continuous screen capture
		func stopCapture() {
			self.captureTask?.cancel()
			self.captureTask = nil
			self.isCapturing = false
			screenshotLogger.info("[ScreenshotService] Continuous capture stopped")
		}

		/// Toggle continuous capture
		func toggleCapture() {
			if self.isCapturing { self.stopCapture() } else { self.startCapture() }
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
		func stopCapture() {
			self.isCapturing = false
		}
		func toggleCapture() {}
	}

#endif // os(iOS) || os(visionOS)
