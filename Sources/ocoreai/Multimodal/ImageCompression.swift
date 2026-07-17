// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Platform-independent image compression using CoreGraphics + ImageIO.
///
/// Resize to max 1280px and encode to JPEG at 0.6 quality.
/// Used by both camera frames and file-picked images — consistent
/// token budget for VLM input (~800 tokens vs ~2800 for full-res).

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Compress image data to a JPEG bounded by maxPixel dimensions at 0.6 quality.
/// Returns the original data if compression fails at any stage.
/// Thread-safe (uses CF/CG which is process-global but read-after-write for each call).
nonisolated func compressImage(_ data: Data, maxPixel: CGFloat = 1280, quality: CGFloat = 0.6) -> Data {
	guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
		return data
	}

	let opts: [CFString: Any] = [
		kCGImageSourceCreateThumbnailFromImageAlways: true,
		kCGImageSourceShouldCacheImmediately: true,
		kCGImageSourceThumbnailMaxPixelSize: maxPixel,
	]

	guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
		return data
	}

	// Encode as JPEG
	guard let dest = CFDataCreateMutable(nil, 0),
	      let destination = CGImageDestinationCreateWithData(dest, UTType.jpeg.identifier as CFString, 1, nil) else {
		return data
	}

	let propOpts: [CFString: Any] = [
		kCGImageDestinationLossyCompressionQuality: quality,
	]
	CGImageDestinationSetProperties(destination, propOpts as CFDictionary)
	CGImageDestinationAddImage(destination, thumbnail, nil)

	guard CGImageDestinationFinalize(destination) else {
		return data
	}

	return dest as Data
}
