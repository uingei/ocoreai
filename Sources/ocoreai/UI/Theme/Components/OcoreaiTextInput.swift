// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// OcoreaiTextInput — unified text input component.
/// Theme-driven background/border, auto dark/light adaptation.

import SwiftUI

struct OcoreaiTextInput: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    @FocusState private var focused: Bool

    @Environment(\.ocoreaiTheme) private var theme

    init(_ label: String, text: Binding<String>, placeholder: String = "") {
        self.label = label
        self._text = text
        self.placeholder = placeholder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.ocoreaiText(11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .textCase(.uppercase)
                .kerning(0.3)

            TextField(placeholder, text: $text)
                .font(.ocoreaiText(14))
                .padding(10)
                .background(theme.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            focused ? theme.accent : theme.inputBorder,
                            lineWidth: focused ? 1.5 : 0.5
                        )
                )
                .focused($focused)
        }
    }
}
