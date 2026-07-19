// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// OCoreaiButtonStyle — unified button styling system.
/// 3 kinds: primary, normal, destructive. 2 sizes: regular, small.
///
/// IMPORTANT: ButtonStyle cannot use @Environment directly. Environment is
/// read by the caller via @Environment(\.ocoreaiTheme) and applied via .modifier().

import SwiftUI

// MARK: - Button Modifiers (read theme here, apply as modifiers)

extension View {
    /// Apply ocoreai button styling
    func ocoreaiButton(
        _ kind: OCoreaiButtonKind,
        size: OCoreaiButtonSize = .regular,
    ) -> some View {
        modifier(OCoreaiButtonModifier(kind: kind, size: size))
    }
}

// MARK: - Modifier (reads theme from view environment)

// Button modifiers — read theme from view environment
struct OCoreaiButtonModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.ocoreaiTheme) private var theme

    let kind: OCoreaiButtonKind
    let size: OCoreaiButtonSize

    func body(content: Content) -> some View {
        content
            .font(.ocoreaiText(size.fontSize, weight: .semibold))
            .fontWeight(.medium)
            .padding(.horizontal, size.hPad)
            .padding(.vertical, size.vPad)
            .background(bgColor())
            .foregroundStyle(fgColor())
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius * 0.65))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isEnabled)
    }

    private func bgColor() -> Color {
        guard isEnabled else { return theme.textTertiary.opacity(0.2) }
        switch kind {
        case .primary:
            return theme.accent
        case .destructive:
            return theme.redDot.opacity(0.85)
        default:
            return theme.cardBg
        }
    }

    private func fgColor() -> Color {
        switch kind {
        case .primary, .destructive:
            theme.accentText
        default:
            theme.text
        }
    }
}

// MARK: - Button Kind

enum OCoreaiButtonKind {
    case primary, normal, destructive
}

// MARK: - Button Size

struct OCoreaiButtonSize {
    static let regular = OCoreaiButtonSize(fontSize: 13, hPad: 14, vPad: 7)
    static let small = OCoreaiButtonSize(fontSize: 11, hPad: 10, vPad: 5)
    let fontSize: CGFloat
    let hPad: CGFloat
    let vPad: CGFloat
}
