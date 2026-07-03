// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Multimodal state — camera, microphone, speaker, screen toggles with persistence
///
/// Toggle changes automatically start/stop the corresponding service via didSet.
/// This is the bridge between UI toggles and the actual I/O services.
///
/// Migrated to @Observable (Swift 5.9+ standard per Apple API Design Guidelines)

import Foundation
import os.log

private let mmLogger = Logger(subsystem: "ocoreai", category: "multimodal_state")

#if os(macOS)
	// Forward declarations to avoid circular import — imported via Multimodule later
	typealias MMCaptureService = CaptureService
	typealias MMScreenshotService = ScreenshotService
	typealias MMAudioIO = AudioIO
#else
	typealias MMCaptureService = CaptureService
	typealias MMScreenshotService = ScreenshotService
	typealias MMAudioIO = AudioIO
#endif

@Observable
@MainActor
final class MultimodalState {
	static let shared = MultimodalState()

	private let encoder: JSONEncoder = {
		let enc = JSONEncoder()
		enc.keyEncodingStrategy = .convertToSnakeCase
		return enc
	}()

	private let decoder: JSONDecoder = {
		let dec = JSONDecoder()
		dec.keyDecodingStrategy = .convertFromSnakeCase
		return dec
	}()

	private let fileKey: String = "multimodal_state"

	// MARK: - Service Toggles (with auto-wiring)

	/// Camera enabled — starts/stops CaptureService automatically
	var cameraEnabled: Bool = false {
		didSet {
			guard !_restoring else { return }
			save()
			notifyChange()
			wireCamera(self.cameraEnabled)
		}
	}

	/// Microphone enabled — starts/stops AudioIO automatically
	var microphoneEnabled: Bool = false {
		didSet {
			guard !_restoring else { return }
			save()
			notifyChange()
			wireMicrophone(self.microphoneEnabled)
		}
	}

	/// Speaker (TTS) enabled — starts/stops AudioIO TTS automatically
	var speakerEnabled: Bool = false {
		didSet {
			guard !_restoring else { return }
			save()
			notifyChange()
		}
	}

	/// Screen capture enabled — starts/stops ScreenshotService automatically
	var screenCaptureEnabled: Bool = false {
		didSet {
			guard !_restoring else { return }
			save()
			notifyChange()
			wireScreen(self.screenCaptureEnabled)
		}
	}

	// MARK: - Capture Snapshots

	/// Camera preview image snapshot (base64 data URL)
	var cameraSnapshot: String? {
		didSet { notifyChange() }
	}

	/// Latest screen capture snapshot (base64 data URL)
	var screenSnapshot: String? {
		didSet { notifyChange() }
	}

	/// STT streaming partial text (live transcription)
	var sttPartialText: String = "" {
		didSet { notifyChange() }
	}

	/// Last audio recording data URL
	var lastRecordingDataURL: String? {
		didSet { notifyChange() }
	}

	var lastTranscript: String? {
		didSet { notifyChange() }
	}

	/// Flag to guard didSet during restore — prevents services starting on cold boot.
	private var _restoring = false
	private var objectKey = ObjectStorageKey()

	init() {
		_restoreFromDisk()
	}

	/// Restore persisted toggles from disk without firing didSet side-effects.
	private func _restoreFromDisk() {
		_restoring = true
		// Read persisted values directly into properties — didSet will see _restoring=true
		if let data = try? Data(contentsOf: storageKey),
		   let snapshot = try? decoder.decode(Snapshot.self, from: data) {
			cameraEnabled = snapshot.cameraEnabled
			microphoneEnabled = snapshot.microphoneEnabled
			speakerEnabled = snapshot.speakerEnabled
			screenCaptureEnabled = snapshot.screenCaptureEnabled
		}
		_restoring = false
	}

	// MARK: - Service Wiring (toggle → start/stop)

	/// Wire camera toggle to CaptureService lifecycle
	private func wireCamera(_ value: Bool) {
		Task {
			let service = MMCaptureService.shared
			if value {
				mmLogger.info("[MultimodalState] Camera enabled — starting CaptureService")
				_ = await service.startCapture()
			} else {
				mmLogger.info("[MultimodalState] Camera disabled — stopping CaptureService")
				await service.stopCapture()
			}
		}
	}

	/// Wire microphone toggle to AudioIO lifecycle
	private func wireMicrophone(_ value: Bool) {
		Task {
			let audio = MMAudioIO.shared
			if value {
				mmLogger.info("[MultimodalState] Microphone enabled — requesting permission")
				_ = await audio.requestMicPermission()
			} else {
				mmLogger.info("[MultimodalState] Microphone disabled — stopping recording")
				_ = await audio.stopRecording()
			}
		}
	}

	/// Wire screen capture toggle to ScreenshotService lifecycle
	private func wireScreen(_ value: Bool) {
		Task {
			let service = MMScreenshotService.shared
			if value {
				mmLogger.info("[MultimodalState] Screen capture enabled — starting ScreenshotService")
				service.startCapture()
			} else {
				mmLogger.info("[MultimodalState] Screen capture disabled — stopping ScreenshotService")
				service.stopCapture()
			}
		}
	}

	// MARK: - Multimodal Context Capture

	/// Capture current multimodal context snapshot for inference.
	/// Returns an array of (serviceName: String, imageDataURL: String) pairs.
	/// Only captures from services whose toggle is currently enabled.
	@discardableResult
	func captureContext() async -> [(name: String, dataURL: String)] {
		var contexts: [(String, String)] = []

		// Camera frame
		if self.cameraEnabled {
			let cs = await MMCaptureService.shared
			if let frameURL = await cs.captureFrame() {
				self.cameraSnapshot = frameURL
				contexts.append(("camera", frameURL))
				mmLogger.info("[MultimodalState] Context: camera frame captured")
			}
		}

		// Screen frame
		if self.screenCaptureEnabled {
			let ss = await MMScreenshotService.shared
			if let frameURL = await ss.captureScreen() {
				self.screenSnapshot = frameURL
				contexts.append(("screen", frameURL))
				mmLogger.info("[MultimodalState] Context: screen frame captured")
			}
		}

		return contexts
	}

	// MARK: - Post-Inference TTS

	/// If speaker is enabled, speak the given text via TTS.
	func speakIfEnabled(_ text: String) {
		guard self.speakerEnabled, !text.isEmpty else { return }
		mmLogger.info("[MultimodalState] Speaker active — TTS: \(text.prefix(50))...")
		MMAudioIO.shared.speak(text)
	}

	// MARK: - Storage

	private var storageKey: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first
			?? URL(fileURLWithPath: "/tmp/ocoreai")
			.appendingPathComponent("ocoreai")
			.appendingPathComponent("multimodal_state.json")
	}

	private func save() {
		let data = Snapshot(
			cameraEnabled: cameraEnabled,
			microphoneEnabled: microphoneEnabled,
			speakerEnabled: speakerEnabled,
			screenCaptureEnabled: screenCaptureEnabled
		)
		try? encoder.encode(data).write(to: storageKey)
	}

	private func load() {
		guard let data = try? Data(contentsOf: storageKey) else { return }
		guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return }
		cameraEnabled = snapshot.cameraEnabled
		microphoneEnabled = snapshot.microphoneEnabled
		speakerEnabled = snapshot.speakerEnabled
		screenCaptureEnabled = snapshot.screenCaptureEnabled
	}

	private func notifyChange() {
		NotificationCenter.default.post(
			name: .multimodalStateDidChange,
			object: objectKey
		)
	}

	private struct Snapshot: Codable {
		var cameraEnabled: Bool
		var microphoneEnabled: Bool
		var speakerEnabled: Bool
		var screenCaptureEnabled: Bool = false // backward compat default
	}

	private class ObjectStorageKey {}
}

extension Notification.Name {
	static let multimodalStateDidChange = Notification.Name("MultimodalStateDidChange")
}
