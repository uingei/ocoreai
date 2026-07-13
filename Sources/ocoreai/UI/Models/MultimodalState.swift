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
			wireCamera(self.cameraEnabled)
		}
	}

	/// Microphone enabled — starts/stops AudioIO automatically
	var microphoneEnabled: Bool = false {
		didSet {
			guard !_restoring else { return }
			save()
			wireMicrophone(self.microphoneEnabled)
		}
	}

	/// Speaker (TTS) enabled — starts/stops AudioIO TTS automatically
	var speakerEnabled: Bool = false {
		didSet {
			guard !_restoring else { return }
			save()
		}
	}

	/// Screen capture enabled — starts/stops ScreenshotService automatically
	var screenCaptureEnabled: Bool = false {
		didSet {
			guard !_restoring else { return }
			save()
			wireScreen(self.screenCaptureEnabled)
		}
	}

	// MARK: - Capture Snapshots

	/// Camera preview image snapshot (base64 data URL)
	var cameraSnapshot: String?

	/// Latest screen capture snapshot (base64 data URL)
	var screenSnapshot: String?

	/// STT streaming partial text (live transcription)
	var sttPartialText: String = ""

	/// Last audio recording data URL
	var lastRecordingDataURL: String?

	var lastTranscript: String?

	/// Flag to guard didSet during restore — prevents services starting on cold boot.
	private var _restoring = false

	/// Debounce timer for async save — coalesces rapid toggle changes.
	private var _saveDebounceTask: Task<Void, Never>?

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
				service.stopCapture()
			}
		}
	}

	/// Wire microphone toggle to AudioIO lifecycle
	private func wireMicrophone(_ value: Bool) {
		Task {
			let audio = MMAudioIO.shared
			if value {
				mmLogger.info("[MultimodalState] Microphone enabled — requesting permission")
				_ = await audio.hasMicPermission()
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

	/// Multimodal context entry — image frame, optional OCR text, and source name.
	/// If ocrText is non-nil and ≥ minCharacters, the frame contains significant
	/// on-screen text and can be sent as structured text (~20 tokens) instead of
	/// an image (~800 tokens), saving ~97% VLM token consumption.
	struct MMContextEntry {
		let name: String
		let dataURL: String? /// nil when OCR text replaces the image
		let ocrText: String? /// Significant text recognized from the frame

		/// Check if this entry should be sent as text (OCR significant) vs image.
		var shouldSendAsText: Bool {
			ocrText != nil && dataURL == nil
		}
	}

	/// Capture current multimodal context snapshot for inference.
	/// Returns an array of MMContextEntry — each entry has an image URL,
	/// OCR text (if significant), or both.
	///
	/// OCR bridge: When camera is enabled and the latest frame contains
	/// significant text (≥ VisionOCR.minCharacters), OCR text replaces
	/// the image data URL, sending structured text instead of a ~800-token image.
	@discardableResult
	func captureContext() async -> [MMContextEntry] {
		var contexts: [MMContextEntry] = []

		// Camera frame — check OCR text first
		if self.cameraEnabled {
			let cs = MMCaptureService.shared
			// If OCR text is significant, send as text instead of image
			if let ocrText = cs.latestOCRText, !ocrText.isEmpty {
				contexts.append(MMContextEntry(name: "camera", dataURL: nil, ocrText: ocrText))
				mmLogger.info("[MultimodalState] Context: camera OCR text captured (\\(ocrText.count) chars)")
			} else if let frameURL = await cs.captureFrame() {
				self.cameraSnapshot = frameURL
				contexts.append(MMContextEntry(name: "camera", dataURL: frameURL, ocrText: nil))
				mmLogger.info("[MultimodalState] Context: camera frame captured")
			}
		}

		// Screen frame
		if self.screenCaptureEnabled {
			let ss = MMScreenshotService.shared
			if let frameURL = await ss.captureScreen() {
				self.screenSnapshot = frameURL
				contexts.append(MMContextEntry(name: "screen", dataURL: frameURL, ocrText: nil))
				mmLogger.info("[MultimodalState] Context: screen frame captured")
			}
		}

		return contexts
	}

	// MARK: - Post-Inference TTS

	/// If speaker is enabled, speak the given text via TTS.
	/// Strips `<thinking>` blocks, code blocks, and truncates long content
	/// to avoid reading out debug/internal artifacts.
	func speakIfEnabled(_ text: String) {
		guard self.speakerEnabled, !text.isEmpty else { return }
		var content = text.replacingOccurrences(of: "<thinking>[^<]*</thinking>",
		                                      with: "",
		                                      options: .regularExpression)
		content = content.replacingOccurrences(of: "```[\\s\\S]*?```",
		                                       with: "[code omitted]",
		                                       options: .regularExpression)
		// Truncate to 500 chars to avoid reading very long outputs
		if content.count > 500 {
			content = String(content.prefix(500)) + "..."
		}
		guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return }
		mmLogger.info("[MultimodalState] Speaker active — TTS: \(content.prefix(50))...")
		MMAudioIO.shared.speak(content)
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
		// Cancel any pending save — debounce coalesces rapid toggle changes
		_saveDebounceTask?.cancel()
		_saveDebounceTask = Task.detached { [
			camera = self.cameraEnabled,
			mic = self.microphoneEnabled,
			spk = self.speakerEnabled,
			screen = self.screenCaptureEnabled,
			enc = self.encoder,
			key = self.storageKey
		] in
			try? await Task.sleep(for: .milliseconds(200))
			Task.isCancelled ? () : ()
			let snapshot = Snapshot(
				cameraEnabled: camera,
				microphoneEnabled: mic,
				speakerEnabled: spk,
				screenCaptureEnabled: screen
			)
			try? enc.encode(snapshot).write(to: key)
		}
	}

	private struct Snapshot: Codable {
		var cameraEnabled: Bool
		var microphoneEnabled: Bool
		var speakerEnabled: Bool
		var screenCaptureEnabled: Bool = false
	}
}

// P0-6: STT transcript notification — delivered when voice recording finishes transcription
extension Notification.Name {
	/// Posted when STT transcription completes — userInfo contains "transcript": String
	static let audioTranscriptAvailable = Notification.Name("AudioTranscriptAvailable")
}
