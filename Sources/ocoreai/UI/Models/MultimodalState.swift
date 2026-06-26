// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Multimodal state — camera, microphone, speaker toggles with persistence
///
/// Migrated to @Observable (Swift 5.9+ standard per Apple API Design Guidelines)

import Foundation

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

	/// Camera enabled
	var cameraEnabled: Bool = false {
		didSet { save(); notifyChange() }
	}

	/// Microphone enabled
	var microphoneEnabled: Bool = false {
		didSet { save(); notifyChange() }
	}

	/// Speaker (TTS) enabled
	var speakerEnabled: Bool = false {
		didSet { save(); notifyChange() }
	}

	/// Camera preview image snapshot (base64 NSDataURL)
	var cameraSnapshot: String? {
		didSet { notifyChange() }
	}

	/// Last audio recording data URL
	var lastRecordingDataURL: String? {
		didSet { notifyChange() }
	}

	var lastTranscript: String? {
		didSet { notifyChange() }
	}

	private let objectKey = ObjectStorageKey()

	init() {
		load()
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
		let data = Snapshot(cameraEnabled: cameraEnabled, microphoneEnabled: microphoneEnabled, speakerEnabled: speakerEnabled)
		try? encoder.encode(data).write(to: storageKey)
	}

	private func load() {
		guard let data = try? Data(contentsOf: storageKey) else { return }
		guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return }
		cameraEnabled = snapshot.cameraEnabled
		microphoneEnabled = snapshot.microphoneEnabled
		speakerEnabled = snapshot.speakerEnabled
	}

	private func notifyChange() {
		NotificationCenter.default.post(
			name: .multimodalStateDidChange,
			object: objectKey,
		)
	}

	private struct Snapshot: Codable {
		var cameraEnabled: Bool
		var microphoneEnabled: Bool
		var speakerEnabled: Bool
	}

	private class ObjectStorageKey {}
}

extension Notification.Name {
	static let multimodalStateDidChange = Notification.Name("MultimodalStateDidChange")
}
