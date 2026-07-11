// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ChatMessageInner — content wrapper for chat message bubbles.
///
/// Renders user messages as plain text, assistant messages through
/// MarkdownMessage which adds code block rendering.

import SwiftUI

/// Inner content view for a chat message bubble.
struct ChatMessageInner: View {
	let text: String
	let isUser: Bool

	@Environment(\.ocoreaiTheme) private var theme

	var body: some View {
		Group {
			if isUser {
				Text(text)
					.font(.ocoreaiText(15))
					.lineSpacing(3)
			} else {
				MarkdownMessage(content: text)
			}
		}
		.multilineTextAlignment(isUser ? .trailing : .leading)
		.padding(12)
		.background(
			isUser ? theme.accentSoft : theme.cardBg,
		)
		.clipShape(RoundedRectangle(cornerRadius: 14))
	}
}
