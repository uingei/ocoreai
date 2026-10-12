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
        // HIG: text the user can read is text they can select. Before this, the
        // only selection in the transcript lived in MarkdownMessage's decoded
        // branch and FileDiffCard — so user bubbles (a path or an error string you
        // typed yourself) and every assistant message whose markdown failed to
        // decode were silently unselectable, recoverable only by re-typing. The
        // whole-message Copy action does not help when you want three words out of
        // six lines. Applied on the container so both branches inherit it.
        .textSelection(.enabled)
        .padding(12)
        .background(
            isUser ? theme.accentSoft : theme.cardBg,
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
