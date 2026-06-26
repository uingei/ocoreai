// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelVersion.swift — SHA256 version verification for downloaded models
///
/// Computes and validates SHA256 checksums for model artifact integrity.
/// Supports streaming hash computation to avoid loading entire files into memory.

import CryptoKit
import Foundation

/// Model version with SHA256 integrity verification.
struct ModelVersion: Codable {
	/// Model identifier
	let modelId: String

	/// Version tag (commit hash, semver, etc.)
	let version: String

	/// SHA256 hash of the model artifact
	let sha256: String

	/// Download source
	let source: String

	/// Timestamp when this version was created/verified
	let timestamp: Date

	/// Size in bytes (estimated or measured)
	let sizeBytes: Int64

	/// Verify the model file on disk matches the expected hash.
	/// - Parameter fileUrl: Path to the model file to verify
	/// - Returns: true if the hash matches
	func verify(at fileUrl: URL) -> Bool {
		guard let actualHash = Self.computeSHA256(fileUrl) else { return false }
		return actualHash.lowercased() == sha256.lowercased()
	}

	/// Compute SHA256 hash of a file using streaming API.
	static func computeSHA256(_ fileUrl: URL) -> String? {
		guard let fileHandle = try? FileHandle(forReadingFrom: fileUrl) else { return nil }
		defer { try? fileHandle.close() }

		var hasher = SHA256()
		let blockSize = 1024 * 64 // 64KB chunks
		var offset: UInt64 = 0

		while true {
			let data = try? fileHandle.read(upToCount: blockSize)
			guard let chunk = data, !chunk.isEmpty else { break }
			hasher.update(data: chunk)
			offset += UInt64(chunk.count)
		}

		let digest = hasher.finalize()
		return digest.map { String(format: "%02x", $0) }.joined()
	}

	/// Compute SHA256 of multiple files (for models split into multiple artifacts).
	static func computeSHA256(fileUrls: [URL]) -> String? {
		var hasher = SHA256()
		for url in fileUrls {
			guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
			defer { try? fileHandle.close() }

			let blockSize = 1024 * 64
			while true {
				guard let data = try? fileHandle.read(upToCount: blockSize),
				      !data.isEmpty else { break }
				hasher.update(data: data)
			}
		}

		let digest = hasher.finalize()
		return digest.map { String(format: "%02x", $0) }.joined()
	}
}

/// Version metadata stored alongside model files for verification.
struct VersionManifest: Codable {
	let version: String
	let source: String
	let sha256: String
	let downloadDate: Date
	let sizeBytes: Int64
	let fileCount: Int

	/// Filesystem path for the manifest file.
	static func manifestPath(in modelDir: URL) -> URL {
		modelDir.appendingPathComponent("MANIFEST.json")
	}

	/// Save manifest to model directory.
	func save(to modelDir: URL) throws {
		let manifestUrl = Self.manifestPath(in: modelDir)
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		let data = try encoder.encode(self)
		try data.write(to: manifestUrl, options: [.atomic])
	}

	/// Load manifest from model directory.
	static func load(from modelDir: URL) throws -> VersionManifest {
		let manifestUrl = Self.manifestPath(in: modelDir)
		let data = try Data(contentsOf: manifestUrl)
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try decoder.decode(VersionManifest.self, from: data)
	}
}
