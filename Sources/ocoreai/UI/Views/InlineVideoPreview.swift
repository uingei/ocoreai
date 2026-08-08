// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// InlineVideoPreview — inline video player for chat transcript rendering.
///
/// Mirrors upstream MLXChatExample MediaPreviewView — uses AVKit VideoPlayer
/// with AVPlayer for video attachments from VLM multimodal input
/// (Gemma4, Qwen2.5VL video frames, etc.).
///
/// Renders local file URLs and remote HTTP URLs via a fallback placeholder.

import AVFoundation
import AVKit
import SwiftUI

/// Inline video preview view for transcript messages.
struct InlineVideoPreview: View {
    /// Video URL string — could be a local file URL or remote HTTP(s) URL.
    let videoURL: String

    @State private var player: AVPlayer?
    @State private var url: URL?

    var body: some View {
        Group {
            if url != nil, let player {
                VideoPlayer(player: player)
            } else {
                // Fallback placeholder — video not available
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(StringKey.videoPlaceholder.l)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            if let u = URL(string: videoURL) {
                self.url = u
                self.player = AVPlayer(url: u)
            } else if let fileUrl = Bundle.main.url(forResource: videoURL, withExtension: "") {
                self.url = fileUrl
                self.player = AVPlayer(url: fileUrl)
            }
        }
    }
}
