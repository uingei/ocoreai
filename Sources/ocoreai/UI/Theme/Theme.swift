// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Theme system — design tokens injected via @Environment.
/// Mirrors omlx pattern: dynamic system colors track macOS appearance.
///
/// Token table covers: surfaces, text, accent, status dots, codeBg, group borders,
/// row separators. All colors derive from semantic SwiftUI system colors — auto dark/light.

import SwiftUI

// MARK: - Token struct

/// Dynamic theme token — no NSColor → safe in test targets cross-platform.
struct OcoreaiTheme: Sendable {
    let isDark: Bool

    // Surfaces
    let windowBg: Color
    let sidebarBg: Color
    let cardBg: Color
    let cardBorder: Color
    let groupBg: Color
    let groupBorder: Color
    let inputBg: Color
    let inputBorder: Color
    let codeBg: Color

    // Text
    let text: Color
    let textSecondary: Color
    let textTertiary: Color

    // Accent
    let accent: Color
    let accentSoft: Color
    let accentText: Color

    // Dashboard metric tints
    let tintPurple: Color
    let tintBlue: Color
    let tintOrange: Color
    let tintGreen: Color
    let tintYellow: Color
    let tintPink: Color
    let tintCyan: Color
    let tintTeal: Color
    let tintRed: Color

    // Status dots
    let greenDot: Color
    let blueDot: Color
    let amberDot: Color
    let redDot: Color

    // Row separator
    let rowSep: Color

    // Metric constants
    let cornerRadius: CGFloat
    let rowRadius: CGFloat
}

// MARK: - Dynamic factory

extension OcoreaiTheme {
    /// Resolves tokens for a given color scheme.
    static func theme(from scheme: ColorScheme) -> OcoreaiTheme {
        let isDark = scheme == .dark

        return OcoreaiTheme(
            isDark:         isDark,
            windowBg:       Color(nsColor: NSColor.windowBackgroundColor),
            sidebarBg:      Color.clear,
            cardBg:         Color.secondary.opacity(isDark ? 0.06 : 0.04),
            cardBorder:     Color.secondary.opacity(isDark ? 0.12 : 0.18),
            groupBg:        Color.secondary.opacity(isDark ? 0.04 : 0.03),
            groupBorder:    Color.secondary.opacity(isDark ? 0.12 : 0.16),
            inputBg:        Color.secondary.opacity(isDark ? 0.08 : 0.06),
            inputBorder:    Color.secondary.opacity(isDark ? 0.12 : 0.18),
            codeBg:         Color.secondary.opacity(isDark ? 0.06 : 0.04),
            text:           .primary,
            textSecondary:  .secondary,
            textTertiary:   Color.secondary.opacity(0.5),
            accent:         .accentColor,
            accentSoft:     Color.accentColor.opacity(isDark ? 0.12 : 0.08),
            accentText:     isDark ? .white : .black,
            tintPurple:     .purple,
            tintBlue:       .blue,
            tintOrange:     .orange,
            tintGreen:      .green,
            tintYellow:     .yellow,
            tintPink:       .pink,
            tintCyan:       .cyan,
            tintTeal:       .mint,
            tintRed:        .red,
            greenDot:       .green,
            blueDot:        Color(red: 0.32, green: 0.58, blue: 0.95),
            amberDot:       .orange,
            redDot:         .red,
            rowSep:         Color.secondary.opacity(isDark ? 0.1 : 0.15),
            cornerRadius:   10,
            rowRadius:      10
        )
    }
}

// MARK: - Environment key

private struct OcoreaiThemeKey: EnvironmentKey {
    static var defaultValue: OcoreaiTheme { .theme(from: .light) }
}

extension EnvironmentValues {
    var ocoreaiTheme: OcoreaiTheme {
        get { self[OcoreaiThemeKey.self] }
        set { self[OcoreaiThemeKey.self] = newValue }
    }
}

// MARK: - Card Modifier (auto-border + cornerRadius)

extension OcoreaiTheme {
    func cardStyle() -> some ViewModifier {
        CardStyleModifier(theme: self)
    }

    /// Grouped-container style: bg + rounded rect + subtle border
    func groupStyle() -> some ViewModifier {
        GroupStyleModifier(theme: self)
    }
}

private struct CardStyleModifier: ViewModifier {
    let theme: OcoreaiTheme

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(theme.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                    .stroke(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
            )
    }
}

private struct GroupStyleModifier: ViewModifier {
    let theme: OcoreaiTheme

    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(theme.groupBg)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                    .stroke(theme.groupBorder, lineWidth: 0.5)
            )
    }
}

// MARK: - Font helpers (omlx pattern)

extension Font {
    static func ocoreaiText(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func ocoreaiDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func ocoreaiMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Section header: uppercase semibold with kerning (11pt default)
    static var ocoreaiSectionHeader: Font {
        .system(size: 11, weight: .semibold, design: .rounded)
    }
}
