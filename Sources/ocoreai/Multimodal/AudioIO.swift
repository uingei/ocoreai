// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Audio I/O service — microphone capture + TTS playback + STT transcription
///
/// Cross-platform: AVFoundation available on macOS, iOS, iPadOS.
/// Recording via AVAudioRecorder, TTS via AVSpeechSynthesizer, STT via SFSpeechRecognizer.
///
/// Migrated to @Observable (Swift 5.9+ standard per Apple API Design Guidelines)

import AVFoundation
import AudioToolbox
import Foundation
import os.log
import Speech

private let audioLogger = Logger(subsystem: "ocoreai", category: "audioio")

/// Audio feedback — start/stop beeps via AudioToolbox
private enum AudioFeedback {
	/// Play a short system sound
	static func play(_ soundID: UInt32 = 1108) {
		AudioServicesPlaySystemSound(soundID)
	}

	/// Recording start sound (subtle)
	static func playRecordingStart() {
		Self.play(1108)
	}

	/// Recording end sound
	static func playRecordingEnd() {
		Self.play(1104)
	}

	/// Transcription started sound
	static func playTranscriptionStart() {
		Self.play(1108)
	}

	/// Transcription completed sound
	static func playTranscriptionEnd() {
		Self.play(1104)
	}
}

@Observable
@MainActor
final class AudioIO: NSObject {
	static let shared = AudioIO()

	// MARK: - Microphone state

	/// Is recording
	var isRecording: Bool = false

	// MARK: - TTS state

	/// Is speaking
	var isSpeaking: Bool = false

	// MARK: - STT state

	/// Is recognizing (voice-to-text in progress)
	var isRecognizing: Bool = false

	/// Latest recognized text (final)
	var recognizedText: String = ""

	/// Live partial transcription (streaming updates)
	var partialText: String = ""

	// MARK: - Internal

	private let synthesizer = AVSpeechSynthesizer()
	private var recorder: AVAudioRecorder?
	private var recordedURL: URL?
	private let audioEngine = AVAudioEngine()

	override init() {
		super.init()
		synthesizer.delegate = self
	}
}

// MARK: - Microphone

extension AudioIO {
	func requestMicPermission() async -> Bool {
		await AVCaptureDevice.requestAccess(for: .audio)
	}

	/// Start recording audio
	func startRecording(maxDuration _: TimeInterval = 30) async -> Bool {
		guard !isRecording else { return false }
		guard await requestMicPermission() else { return false }

		let settings: [String: Any] = [
			AVFormatIDKey: Int(kAudioFormatLinearPCM),
			AVSampleRateKey: 44100.0,
			AVNumberOfChannelsKey: 1,
			AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
		]

		recordedURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("ocoreai_audio_\(UUID().uuidString).caf")
		guard let url = recordedURL else { return false }

		beginRecording(to: url, settings: settings)
		AudioFeedback.playRecordingStart()
		return true
	}

	/// Stop recording and return audio as base64 data URL
	func stopRecording() async -> String? {
		guard isRecording else { return nil }
		stopRecordingInternal()
		isRecording = false
		AudioFeedback.playRecordingEnd()

		guard let url = recordedURL,
			  FileManager.default.fileExists(atPath: url.path)
		else {
			return nil
		}

		do {
			let data = try Data(contentsOf: url)
			try? FileManager.default.removeItem(at: url)
			return "data:audio/caf;base64,\(data.base64EncodedString())"
		} catch {
			audioLogger.error("[AudioIO] Failed to read recording: \(error.localizedDescription)")
			return nil
		}
	}

	/// Toggle recording on/off
	func toggleRecording() async -> String? {
		if isRecording {
			return await stopRecording()
		}
		_ = await startRecording()
		return nil
	}

	private func beginRecording(to url: URL, settings: [String: Any]) {
		do {
			recorder = try AVAudioRecorder(url: url, settings: settings)
			recorder?.isMeteringEnabled = true
			recorder?.prepareToRecord()
			recorder?.record()
			isRecording = true
		} catch {
			audioLogger.error("[AudioIO] Recording error: \(error.localizedDescription)")
			isRecording = false
		}
	}

	private func stopRecordingInternal() {
		recorder?.stop()
		recorder = nil
	}
}

// MARK: - TTS

extension AudioIO {
	func speak(_ text: String) {
		guard !text.isEmpty else { return }
		synthesizer.stopSpeaking(at: .immediate)
		let utterance = AVSpeechUtterance(string: text)
		synthesizer.speak(utterance)
		isSpeaking = true
	}

	func stopSpeaking() {
		synthesizer.stopSpeaking(at: .immediate)
	}
}

// MARK: - Speech-to-Text

extension AudioIO {
	/// Request authorization for speech recognition
	func requestSpeechPermission() async -> Bool {
		let granted = await withCheckedContinuation { continuation in
			SFSpeechRecognizer.requestAuthorization { status in
				continuation.resume(returning: status == .authorized)
			}
		}
		return granted
	}

	/// Continuous speech recognition with streaming partial results.
	/// Returns final transcribed text or nil on cancel/error.
	/// Partial results are pushed to `partialText` in real-time.
	/// Audio feedback (beep) plays on start and end.
	func transcribe(timeout: TimeInterval = 30) async -> String? {
		// Check authorization
		let authorized = await requestSpeechPermission()
		guard authorized else {
			audioLogger.error("[AudioIO] Speech recognition not authorized")
			return nil
		}

		guard let recognizer = SFSpeechRecognizer() else {
			audioLogger.error("[AudioIO] No available speech recognizer")
			return nil
		}

		// Setup audio engine — macOS compatible (no AVAudioSession)
		audioEngine.stop()
		audioEngine.reset()

		let request = SFSpeechAudioBufferRecognitionRequest()
		// 🔥 Streaming: report partial results in real-time
		request.shouldReportPartialResults = true

		let format = audioEngine.inputNode.outputFormat(forBus: 0)
		audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
			request.append(buffer)
		}

		try? audioEngine.start()
		isRecognizing = true
		recognizedText = ""
		partialText = ""
		AudioFeedback.playTranscriptionStart()

		do {
			let task = recognizer.recognitionTask(with: request) { result, error in
				guard let result else { return }
				_ = Task { @MainActor in
					let text = result.bestTranscription.formattedString
					if result.isFinal {
						AudioIO.shared.recognizedText = text
					} else {
						// 🔥 Live partial update — UI can display this in real-time
						AudioIO.shared.partialText = text
					}
				}
			}

			// Wait up to timeout then cancel
			try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
			task.cancel()
			audioEngine.inputNode.removeTap(onBus: 0)
			audioEngine.stop()
			isRecognizing = false
			partialText = ""
			AudioFeedback.playTranscriptionEnd()

			if !recognizedText.isEmpty {
				return recognizedText
			}
			return nil
		} catch {
			audioLogger.error("[AudioIO] STT error: \(error.localizedDescription)")
			audioEngine.inputNode.removeTap(onBus: 0)
			audioEngine.stop()
			isRecognizing = false
			partialText = ""
			AudioFeedback.playTranscriptionEnd()
			return nil
		}
	}

	/// Cancel ongoing recognition immediately
	func cancelTranscription() {
		audioEngine.stop()
		audioEngine.inputNode.removeTap(onBus: 0)
		isRecognizing = false
		partialText = ""
		AudioFeedback.playRecordingEnd()
	}
}

// MARK: - AVSpeechSynthesizerDelegate

extension AudioIO: AVSpeechSynthesizerDelegate {
	nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didStart _: AVSpeechUtterance) {
		Task { @MainActor in
			AudioIO.shared.isSpeaking = true
		}
	}

	nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
		Task { @MainActor in
			AudioIO.shared.isSpeaking = false
		}
	}

	nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
		Task { @MainActor in
			AudioIO.shared.isSpeaking = false
		}
	}
}
