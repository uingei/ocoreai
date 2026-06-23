// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Multimodal Controls — camera/microphone/speaker toggle panel with preview
/// Accessibility: full VoiceOver labels on toggles, buttons, and status indicators

#if os(macOS)
import SwiftUI

struct MultimodalControls: View {
	private let mmState = MultimodalState.shared
	private let captureService = CaptureService.shared
	private let audioIO = AudioIO.shared

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			// Section header
			HStack {
				Image(systemName: "eye.and.ear.and.hands.filled")
					.font(.title2)
					.accessibilityHidden(true)
				Text(StringKey.multimodalTitle.l)
					.font(.headline)
				Spacer()
			}
			.padding(.horizontal)

			Divider()
				.accessibilityHidden(true)

			// Camera section
			cameraSection

			// Microphone section
			microphoneSection

			// Speaker section
			speakerSection

			// Status bar
			statusRow
		}
		.padding()
		.background(Color.gray.opacity(0.05))
		.cornerRadius(12)
		.overlay(
			RoundedRectangle(cornerRadius: 12)
				.stroke(Color.secondary, lineWidth: 1)
		)
		.accessibilityLabel("Multimodal Controls")
	}

	// MARK: - Camera Section

	private var cameraSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Image(systemName: "camera.fill")
					.foregroundColor(mmState.cameraEnabled ? .green : .secondary)
					.accessibilityHidden(true)
				Text(StringKey.multimodalCamera.l)
					.font(.subheadline)
				Spacer()
				Toggle("", isOn: Binding(get: { mmState.cameraEnabled }, set: { MultimodalState.shared.cameraEnabled = $0 }))
					.toggleStyle(.switch)
					.onChange(of: mmState.cameraEnabled) { _, value in
						if value {
							Task { await captureService.startCapture() }
						} else {
							captureService.stopCapture()
						}
					}
					.accessibilityLabel("Enable Camera")
					.accessibilityHint("Turn camera on or off")
			}

			// Camera preview (if frame available)
			if let frameURL = captureService.latestFrameDataURL {
				AsyncImage(url: URL(string: frameURL)) { image in
					image
						.resizable()
						.scaledToFit()
						.frame(height: 120)
						.cornerRadius(8)
						.clipped()
				} placeholder: {
					ProgressView()
						.frame(height: 120)
				}
				.overlay(
					Text(StringKey.multimodalLiveFeed.l)
						.font(.caption2)
						.foregroundColor(.gray)
						.padding(4)
						.background(Color.black.opacity(0.6))
						.cornerRadius(4),
					alignment: .topLeading
				)
				.accessibilityLabel("Camera live feed preview")
			}

			// Capture button
			if mmState.cameraEnabled {
				Button(action: {
					Task {
						if let dataURL = await captureService.captureFrame() {
							MultimodalState.shared.cameraSnapshot = dataURL
						}
					}
				}) {
					Label("Capture Frame", systemImage: "camera.on.rectangle")
						.frame(maxWidth: .infinity)
				}
				.buttonStyle(.borderedProminent)
				.accessibilityLabel("Capture Frame")
				.accessibilityHint("Take a snapshot from the camera")
			}
		}
	}

	// MARK: - Microphone Section

	private var microphoneSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Image(systemName: "mic.fill")
					.foregroundColor(
						audioIO.isRecording ? .red :
						(mmState.microphoneEnabled ? .green : .secondary)
					)
					.accessibilityHidden(true)
				Text(StringKey.multimodalMic.l)
					.font(.subheadline)
				Spacer()
				Toggle("", isOn: Binding(get: { mmState.microphoneEnabled }, set: { MultimodalState.shared.microphoneEnabled = $0 }))
					.toggleStyle(.switch)
					.onChange(of: mmState.microphoneEnabled) { _, value in
						if value {
							Task { _ = await audioIO.requestMicPermission() }
						}
					}
					.accessibilityLabel("Enable Microphone")
					.accessibilityHint("Turn microphone on or off")
			}

			if mmState.microphoneEnabled {
				Button(action: {
					if audioIO.isRecording {
						Task {
							if let audioData = await audioIO.stopRecording() {
								MultimodalState.shared.lastTranscript = "[audio captured: " + audioData.prefix(40) + "...]"
							}
						}
					} else {
						Task { _ = await audioIO.startRecording() }
					}
				}) {
					HStack {
						Image(systemName: audioIO.isRecording ? "stop.circle.fill" : "record.circle")
							.font(.title3)
						Text(audioIO.isRecording ? "Stop Recording" : "Start Recording")
					}
					.frame(maxWidth: .infinity)
				}
				.buttonStyle(.borderedProminent)
				.tint(audioIO.isRecording ? Color.red : Color.accentColor)
				.accessibilityLabel(audioIO.isRecording ? "Stop Recording" : "Start Recording")
				.accessibilityHint(audioIO.isRecording ? "Stop the current audio recording" : "Begin recording audio")
			}

			// Show last transcript
			if let transcript = MultimodalState.shared.lastTranscript {
				Text(transcript)
					.font(.caption)
					.foregroundColor(.gray)
					.lineLimit(2)
					.accessibilityLabel("Last transcript: \(transcript)")
					.accessibilityAddTraits(.isStaticText)
			}
		}
	}

	// MARK: - Speaker Section

	private var speakerSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Image(systemName: "speaker.wave.3.fill")
					.foregroundColor(mmState.speakerEnabled ? .green : .secondary)
					.accessibilityHidden(true)
				Text(StringKey.multimodalSpeaker.l)
					.font(.subheadline)
				Spacer()
				Toggle("", isOn: Binding(get: { mmState.speakerEnabled }, set: { MultimodalState.shared.speakerEnabled = $0 }))
					.toggleStyle(.switch)
					.onChange(of: mmState.speakerEnabled) { _, value in
						if !value {
							audioIO.stopSpeaking()
						}
					}
					.accessibilityLabel("Enable Speaker")
					.accessibilityHint("Turn text-to-speech on or off")
			}

			if mmState.speakerEnabled {
				Text(StringKey.multimodalTtsHint.l)
					.font(.caption)
					.foregroundColor(.gray)
					.accessibilityLabel("Text-to-speech is active")
					.accessibilityAddTraits(.isStaticText)
			}
		}
	}

	// MARK: - Status Row

	private var statusRow: some View {
		HStack(spacing: 16) {
			StatusDot(isActive: captureService.isCapturing, label: "Camera Active")
			StatusDot(isActive: audioIO.isRecording, label: "Recording")
			StatusDot(isActive: audioIO.isSpeaking, label: "Speaking")
		}
		.accessibilityLabel("Multimodal status indicators")
	}
}

// MARK: - Status Dot Helper

private struct StatusDot: View {
	let isActive: Bool
	let label: String

	var body: some View {
		HStack(spacing: 4) {
			Circle()
				.fill(isActive ? Color.red : Color.gray)
				.frame(width: 6, height: 6)
				.accessibilityHidden(true)
			Text(label)
				.font(.caption2)
				.foregroundColor(.gray)
				.lineLimit(1)
		}
		.accessibilityLabel("\(label): \(isActive ? "Active" : "Inactive")")
		.accessibilityAddTraits(.isStaticText)
	}
}

// MARK: - Preview

/// #Preview requires Xcode PreviewsMacros plugin — disabled for swift build.
/// For live previews open the project in Xcode instead.

#endif // os(macOS)
