// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SectionHeader — uppercase semibold section labels with optional subtitle and trailing content.
/// 11pt semibold uppercase + kerning + Content: View generic for trailing.

import SwiftUI

struct SectionHeader<Content: View>: View {
    let title: String
    let subtitle: String?
    let trailingContent: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        trailingContent = content()
    }

    @Environment(\.ocoreaiTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.ocoreaiSectionHeader)
                    .foregroundStyle(theme.textSecondary)
                    .textCase(.uppercase)
                    .kerning(0.6)
                Spacer(minLength: 4)
                trailingContent
            }
            if let subtitle {
                Text(subtitle)
                    .font(.ocoreaiText(11.5))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }
}
