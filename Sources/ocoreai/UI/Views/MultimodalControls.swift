// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Multimodal Controls — camera/microphone/speaker/screen toggle panel with preview
/// Accessibility: full VoiceOver labels on toggles, buttons, and status indicators
/// Theme-driven: all colors resolve through @Environment(\.ocoreaiTheme)
/// Fix P0-4: DataURLPreview replaces AsyncImage (data URLs do not work with URLSession)

#if os(macOS)
	import SwiftUI

	struct MultimodalControls: View {
		@Environment(\.ocoreaiTheme) private var theme
		// Observation: these singletons are @Observable types — property access in body
		// automatically establishes reactive dependencies (SE-0403 Observation framework).
		// `let` is sufficient; no property wrapper needed.
		private let mmState = MultimodalState.shared
		private let captureService = CaptureService.shared
		private let audioIO = AudioIO.shared
		private let screenshotService = ScreenshotService.shared

		// Camera/screen preview frame relay — needed solely because DataURLPreview
		// requires a @Binding. The @Observable properties above make the rest of the
		// body reactive to external state changes.
		@State private var cameraFrameURL: String?
		@State private var screenFrameURL: String?

		init() {
			_cameraFrameURL = State(initialValue: CaptureService.shared.latestFrameDataURL)
			_screenFrameURL = State(initialValue: MultimodalState.shared.screenSnapshot)
		}

		var body: some View {
			VStack(alignment: .leading, spacing: 16) {
				// Section header
				HStack {
					Image(systemName: "camera.viewfinder")
						.font(.title2)
						.foregroundStyle(theme.accent)
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

				// Screen capture section
				screenSection

				// Microphone section
				microphoneSection

				// Speaker section
				speakerSection

				// Status bar
				statusRow
			}
			.padding()
			.background(theme.cardBg.opacity(0.95))
			.cornerRadius(12)
			.overlay(
				RoundedRectangle(cornerRadius: 12)
					.stroke(theme.inputBorder.opacity(0.5), lineWidth: 1),
			)
			.accessibilityLabel(StringKey.multimodalControlsLabel.l)
			// React to service frame changes — update relay vars for DataURLPreview bindings
			.onChange(of: captureService.latestFrameDataURL) {
				cameraFrameURL = $0
			}
			.onChange(of: mmState.screenSnapshot) {
				screenFrameURL = $0
			}
		}

		// MARK: - Camera Section

		private var cameraSection: some View {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Image(systemName: "camera.fill")
						.foregroundStyle(mmState.cameraEnabled ? theme.greenDot : theme.textSecondary)
						.accessibilityHidden(true)
					Text(StringKey.multimodalCamera.l)
						.font(.subheadline)
					Spacer()
					Toggle("", isOn: Binding(get: { mmState.cameraEnabled }, set: { MultimodalState.shared.cameraEnabled = $0 }))
						.toggleStyle(.switch)
						// P1-2: wireCamera() is called from MultimodalState.cameraEnabled didSet —
						// .onChange here would duplicate the call (double startCapture).
						// Removed redundant .onChange handler.
						.accessibilityLabel(StringKey.enableCameraLabel.l)
						.accessibilityHint(StringKey.enableCameraHint.l)
				}

				// Camera preview (if frame available)
				// P0-4 fix: uses DataURLPreview which decodes base64 data URLs directly
				if cameraFrameURL != nil || captureService.latestFrameDataURL != nil {
					DataURLPreview(dataURLString: $cameraFrameURL, height: 100)
						.overlay(
							Text(StringKey.multimodalLiveFeed.l)
								.font(.caption2)
								.foregroundStyle(theme.textTertiary)
								.padding(4)
								.background(theme.cardBg.opacity(0.85))
								.cornerRadius(4),
							alignment: .topLeading,
						)
						.accessibilityLabel(StringKey.cameraPreviewLabel.l)
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
						Label(StringKey.captureFrameLabel.l, systemImage: "camera.on.rectangle")
							.frame(maxWidth: .infinity)
					}
					.buttonStyle(.borderedProminent)
					.accessibilityLabel(StringKey.captureFrameLabel.l)
					.accessibilityHint(StringKey.captureFrameHint.l)
				}
			}
		}

		// MARK: - Screen Section

		private var screenSection: some View {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Image(systemName: "desktopcomputer")
						.foregroundStyle(screenshotService.isCapturing ? theme.greenDot : theme.textSecondary)
						.accessibilityHidden(true)
					Text(StringKey.multimodalScreen.l)
						.font(.subheadline)
					Spacer()
					// One-shot capture button
					Button(action: {
						Task {
							_ = await screenshotService.captureScreen()
						}
					}) {
						Label(StringKey.multimodalScreenCaptureLabel.l, systemImage: "camera.macro")
					}
					.buttonStyle(.bordered)
					.accessibilityLabel(StringKey.multimodalScreenCaptureLabel.l)
					.accessibilityHint(StringKey.multimodalScreenCaptureHint.l)
				}

				// Screen preview
				// P0-4 fix: uses DataURLPreview which decodes base64 data URLs directly
				if screenFrameURL != nil || mmState.screenSnapshot != nil {
					DataURLPreview(dataURLString: $screenFrameURL, height: 100)
						.overlay(
							Text(StringKey.multimodalScreenLiveFeed.l)
								.font(.caption2)
								.foregroundStyle(theme.textTertiary)
								.padding(4)
								.background(theme.cardBg.opacity(0.85))
								.cornerRadius(4),
							alignment: .topLeading,
						)
						.accessibilityLabel(StringKey.multimodalScreenLiveFeed.l)
				}
			}
		}

		// MARK: - Microphone Section

		private var microphoneSection: some View {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Image(systemName: "mic.fill")
						.foregroundStyle(
							audioIO.isRecording ? theme.redDot :
								(mmState.microphoneEnabled ? theme.greenDot : theme.textSecondary)
						)
						.accessibilityHidden(true)
					Text(StringKey.multimodalMic.l)
						.font(.subheadline)
					Spacer()
					Toggle("", isOn: Binding(get: { mmState.microphoneEnabled }, set: { MultimodalState.shared.microphoneEnabled = $0 }))
						.toggleStyle(.switch)
						// P1-fix MM-03: removed redundant .onChange — MultimodalState.didSet
						// already calls wireMicrophone → requestMicPermission.
						// Keeping this causes duplicate permission prompts.
						.accessibilityLabel(StringKey.enableMicLabel.l)
					.accessibilityHint(StringKey.enableMicHint.l)
				}

				if mmState.microphoneEnabled {
					Button(action: {
						if audioIO.isRecording {
							// Stop recording then auto-transcribe
							Task {
								_ = await audioIO.stopRecording()
								if let transcript = await audioIO.transcribe(timeout: 15) {
										// Save to shared state so UI can display it
										MultimodalState.shared.lastTranscript = transcript
										// Post transcript so ChatView auto-sends (voice loop)
										NotificationCenter.default.post(
											name: .audioTranscriptAvailable,
											object: nil,
										 userInfo: ["transcript": transcript]
										)
								}
							}
						} else {
							Task { _ = await audioIO.startRecording() }
						}
					}) {
						HStack {
							Image(systemName: audioIO.isRecording ? "stop.circle.fill" : "record.circle")
								.font(.title3)
							Text(audioIO.isRecording ? StringKey.stopRecordingLabel.l : StringKey.startRecordingLabel.l)
						}
						.frame(maxWidth: .infinity)
					}
					.buttonStyle(.borderedProminent)
					.tint(audioIO.isRecording ? theme.redDot : theme.accent)
					.accessibilityLabel(audioIO.isRecording ? StringKey.stopRecordingLabel.l : StringKey.startRecordingLabel.l)
					.accessibilityHint(audioIO.isRecording ? StringKey.stopRecordingHint.l : StringKey.startRecordingHint.l)
				}

				// STT streaming partial text
				if !audioIO.partialText.isEmpty {
					Text(audioIO.partialText)
						.font(.caption)
						.foregroundStyle(theme.accent)
						.lineLimit(3)
						.accessibilityLabel("\(StringKey.multimodalSTTPartialLabel.l): \(audioIO.partialText)")
						.accessibilityAddTraits(.isStaticText)
				} else if let transcript = mmState.lastTranscript {
					Text(transcript)
						.font(.caption)
						.foregroundStyle(theme.textSecondary)
						.lineLimit(2)
						.accessibilityLabel("\(StringKey.lastTranscriptLabel.l): \(transcript)")
						.accessibilityAddTraits(.isStaticText)
				}
			}
		}

		// MARK: - Speaker Section

		private var speakerSection: some View {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Image(systemName: "speaker.wave.3.fill")
						.foregroundStyle(mmState.speakerEnabled ? theme.greenDot : theme.textSecondary)
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
						.accessibilityLabel(StringKey.enableSpeakerLabel.l)
						.accessibilityHint(StringKey.enableSpeakerHint.l)
				}

				if mmState.speakerEnabled {
					Text(StringKey.multimodalTtsHint.l)
						.font(.caption)
						.foregroundStyle(theme.textTertiary)
						.accessibilityLabel(StringKey.ttsActiveLabel.l)
						.accessibilityAddTraits(.isStaticText)
				}
			}
		}

		// MARK: - Status Row

		private var statusRow: some View {
			HStack(spacing: 16) {
				StatusDot(
					isActive: captureService.isCapturing,
					label: StringKey.statusCameraActive.l
				)
				StatusDot(
					isActive: audioIO.isRecording,
					label: StringKey.statusRecording.l
				)
				StatusDot(
					isActive: audioIO.isSpeaking,
					label: StringKey.statusSpeaking.l
				)
				StatusDot(
					isActive: screenshotService.isCapturing,
					label: StringKey.multimodalScreenCaptureActive.l
				)
			}
			.accessibilityLabel(StringKey.statusIndicatorsLabel.l)
		}
	}

	// MARK: - Status Dot Helper

	extension MultimodalControls {
		private struct StatusDot: View {
			let isActive: Bool
			let label: String

			@Environment(\.ocoreaiTheme) private var theme

			var body: some View {
				HStack(spacing: 4) {
					Circle()
						.fill(isActive ? theme.greenDot : theme.textTertiary)
						.frame(width: 6, height: 6)
						.accessibilityHidden(true)
					Text(label)
						.font(.caption2)
						.foregroundStyle(theme.textTertiary)
						.lineLimit(1)
				}
				.accessibilityLabel("\(label): \(isActive ? StringKey.statusActive.l : StringKey.statusInactive.l)")
				.accessibilityAddTraits(.isStaticText)
			}
		}
	}

#endif // os(macOS)
