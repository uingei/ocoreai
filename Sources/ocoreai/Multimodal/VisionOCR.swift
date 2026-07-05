// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Vision OCR processor — on-device text recognition via VNRecognizeTextRequest.
///
/// Runs ANE-accelerated text recognition on camera frames. If the frame
/// contains enough text (>minCharacters), returns a structured text string
/// instead of the raw image, saving ~97% VLM token consumption.
///
/// API: VNRecognizeTextRequest (iOS 13+, macOS 10.15+)
/// Returns: Structured text from VNRecognizedTextObservation, or nil if
/// no significant text was found.

import Foundation
import Vision

/// On-device Vision OCR — ANE-accelerated text recognition
@MainActor
struct VisionOCR {
	/// Minimum number of recognized characters to consider the OCR result
	/// "significant" — frames below this threshold still go as images to VLM.
	static let minCharacters = 10

	/// Run OCR on raw image data. Returns structured text if the frame
	/// contains significant text content, otherwise nil (keep as image).
	///
	/// - Parameter data: Raw camera frame data (JPEG or PNG)
	/// - Returns: Recognized text string or nil (no text / too little text)
	static func extractText(from data: Data) async -> String? {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil),
			  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, nil) else {
			return nil
		}

		let request = VNRecognizeTextRequest()
		request.automaticallyDetectsLanguage = true
		request.recognitionLevel = .accurate

		let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
		try? handler.perform([request])

		guard let observations = request.results else {
			return nil
		}

		// Extract text from observations — sorted by confidence descending
		var lines: [String] = []
		for observation in observations {
			if let text = observation.topCandidates(1).first?.string,
			   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				lines.append(text)
			}
		}

		let fullText = lines.joined(separator: "\n")
		// Only return OCR result if it has enough content to meaningfully reduce tokens
		return fullText.count >= minCharacters ? fullText : nil
	}
}
