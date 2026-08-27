// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DataURLPreview — renders base64 data URLs as SwiftUI images.
///
/// Fix for P0-4: AsyncImage(url:) silently drops data:image/jpeg;base64,… URLs
/// because URLSession only handles http(s) schemes. This component decodes
/// the base64 payload directly into a platform image and wraps it for SwiftUI.
///
/// Cross-platform: UIImage on iOS, NSImage on macOS.
///
/// Usage:
///     DataURLPreview(dataURLString: $frameDataURL, height: 100)
///         .overlay(liveBadge)

import SwiftUI

#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif

/// Renders a base64-encoded data URL (image/jpeg or image/png) as a resizable image.
struct DataURLPreview: View {
    @Binding var dataURLString: String?
    let height: CGFloat

    var body: some View {
        if let urlStr = dataURLString,
            let image = urlStr.dataURLImage as? PlatformImage
        {
            rendered(image)
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

    @ViewBuilder
    private func rendered(_ image: PlatformImage) -> some View {
        #if os(iOS)
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .cornerRadius(8)
            .clipped()
        #else
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .cornerRadius(8)
            .clipped()
        #endif
    }
}

// MARK: - Data URL decoding

extension String {
    /// Decode a `data:image/jpeg;base64,…` or `data:image/png;base64,…` data URL
    /// into a platform image (UIImage on iOS, NSImage on macOS), or nil on decode failure.
    /// `Any?` — the concrete type varies by platform; callers narrow with `as? PlatformImage`.
    var dataURLImage: Any? {
        guard hasPrefix("data:image/") else { return nil }

        // Strip the prefix to get base64 payload (find the comma separator)
        guard let commaRange = self.range(of: ",") else { return nil }
        let base64String = String(self[commaRange.upperBound...])

        guard let rawBytes = Data(base64Encoded: base64String) else { return nil }

        #if os(iOS)
        // UIImage handles JPEG, PNG, and other common formats directly
        return UIImage(data: rawBytes)
        #else
        // NSImage(data:) handles JPEG, PNG, and other common formats directly
        return NSImage(data: rawBytes)
        #endif
    }
}
