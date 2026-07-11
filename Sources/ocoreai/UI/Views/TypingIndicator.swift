// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// TypingIndicator — three-dot bouncing animation (Apple HIG pattern).
///
/// Shown during streaming inference to signal "thinking" state.
/// Respects .accessibilityReduceMotion — falls back to static dots.
///
/// Pattern source: Apple HIG Chat Examples — animated read receipt dots.
/// Each dot animates opacity in sequence with staggered delays.
///

import SwiftUI

/// Three-dot typing indicator with bouncing animation.
struct TypingIndicator: View {
	@Environment(\.ocoreaiTheme) private var theme
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	// Animation timing — three dots staggered at 0.3s intervals
	@State private var dot1Opacity: Double = 0.3
	@State private var dot2Opacity: Double = 0.3
	@State private var dot3Opacity: Double = 0.3

	var body: some View {
		HStack(spacing: 6) {
			typingDot(opacity: $dot1Opacity)
			typingDot(opacity: $dot2Opacity)
			typingDot(opacity: $dot3Opacity)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.background(theme.cardBg)
		.clipShape(RoundedRectangle(cornerRadius: 14))
		.accessibilityLabel(StringKey.assistantTyping.l)
		// Animate only when reduced motion is off
		.task {
			guard !reduceMotion else { return }
			await animateDots()
		}
	}

	@ViewBuilder
	@inline(__always)
	private func typingDot(opacity: Binding<Double>) -> some View {
		Circle()
			.fill(theme.accent.opacity(opacity.wrappedValue))
			.frame(width: 8, height: 8)
	}

	/// Infinite loop: pulse each dot with 0.3s stagger, 1.2s cycle.
	private func animateDots() async {
		while !Task.isCancelled {
			// Dot 1 rises
			withAnimation(.easeInOut(duration: 0.3)) {
				dot1Opacity = 1.0
			}
			try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s

			// Dot 2 rises
			withAnimation(.easeInOut(duration: 0.3)) {
				dot2Opacity = 1.0
			}
			try? await Task.sleep(nanoseconds: 200_000_000)

			// Dot 3 rises
			withAnimation(.easeInOut(duration: 0.3)) {
				dot3Opacity = 1.0
			}
			try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s

			// All fade
			withAnimation(.easeInOut(duration: 0.3)) {
				dot1Opacity = 0.3
				dot2Opacity = 0.3
				dot3Opacity = 0.3
			}
			try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
		}
	}
}

// MARK: - Preview

/// #Preview requires Xcode PreviewsMacros plugin — disabled for swift build.
/// For live previews open the project in Xcode instead.
