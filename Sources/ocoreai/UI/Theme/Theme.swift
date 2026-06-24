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
        groupBg:        Color.secondary.opacity(isDark ? 0.04 : 0.03),
        cardBorder:     Color.secondary.opacity(isDark ? 0.12 : 0.18),
        groupBorder:    Color.secondary.opacity(isDark ? 0.12 : 0.16),
        inputBg:        Color.secondary.opacity(isDark ? 0.08 : 0.06),
        inputBorder:    Color.secondary.opacity(isDark ? 0.12 : 0.18),
        codeBg:         Color.secondary.opacity(isDark ? 0.06 : 0.04),
        text:           .primary,
        textSecondary:  .secondary,
        textTertiary:   Color.secondary.opacity(0.5),
        accent:         .accentColor,
        accentSoft:     Color.accentColor.opacity(isDark ? 0.12 : 0.08),
        accentText:     .primary,
        tintPurple:     Color.purple,
        tintBlue:       Color.blue,
        tintOrange:     Color.orange,
        tintGreen:      Color.green,
        tintYellow:     Color.yellow,
        tintPink:       Color.pink,
        tintCyan:       Color.cyan,
        tintTeal:       Color.mint,
        tintRed:        Color.red,
        greenDot:       Color.green,
        blueDot:        Color.blue,
        amberDot:       Color.orange,
        redDot:         Color.red,
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
    /// Map a raw size to the closest SwiftUI TextStep/TextStyle so Dynamic Type scales.
    private static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ...9: return .caption2
        case ...10: return .caption
        case ...12: return .caption
        case ...13: return .subheadline
        case ...14: return .callout
        case ...18: return .body
        case ...22: return .title3
        case ...28: return .title2
        case ...34: return .title
        default: return .largeTitle
        }
    }

    static func ocoreaiText(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(textStyle: textStyle(for: size), weight: weight, design: .rounded)
    }

    static func ocoreaiDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(textStyle: textStyle(for: size), weight: weight, design: .rounded)
    }

    static func ocoreaiMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(textStyle: textStyle(for: size), weight: weight, design: .monospaced)
    }

    /// Section header: uppercase semibold with kerning (caption-style default)
    static var ocoreaiSectionHeader: Font {
        .system(.caption, design: .rounded).bold()
    }
}
