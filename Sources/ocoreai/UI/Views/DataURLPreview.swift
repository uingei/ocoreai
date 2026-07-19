// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DataURLPreview — renders base64 data URLs as SwiftUI images.
///
/// Fix for P0-4: AsyncImage(url:) silently drops data:image/jpeg;base64,… URLs
/// because URLSession only handles http(s) schemes. This component decodes
/// the base64 payload directly into a CGImage and wraps it for SwiftUI.
///
/// Usage:
///     DataURLPreview(dataURLString: $frameDataURL, height: 100)
///         .overlay(liveBadge)

#if os(macOS)

import AppKit
import SwiftUI

/// Renders a base64-encoded data URL (image/jpeg or image/png) as a resizable image.
struct DataURLPreview: View {
    @Binding var dataURLString: String?
    let height: CGFloat

    var body: some View {
        Group {
            if let urlStr = dataURLString, let nsImage = urlStr.dataURLImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(height: height)
                    .cornerRadius(8)
                    .clipped()
            } else {
                // Fallback / first render before decode completes
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: height)
                    .cornerRadius(8)
                    .overlay {
                        ProgressView()
                    }
            }
        }
    }
}

// MARK: - Data URL decoding → NSImage

extension String {
    /// Decode a `data:image/jpeg;base64,…` or `data:image/png;base64,…` data URL
    /// into an `NSImage`.
    var dataURLImage: NSImage? {
        guard hasPrefix("data:image/") else { return nil }

        // Strip the prefix to get base64 payload (find the comma separator)
        guard let commaRange = self.range(of: ",") else { return nil }
        let base64String = String(self[commaRange.upperBound...])

        guard let rawBytes = Data(base64Encoded: base64String) else { return nil }

        // NSImage(data:) handles JPEG, PNG, and other common formats directly
        return NSImage(data: rawBytes)
    }
}

#endif // os(macOS)
