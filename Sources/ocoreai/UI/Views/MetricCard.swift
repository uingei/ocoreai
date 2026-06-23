// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MetricCard — reusable card for dashboard metrics, theme-driven.
/// Uses theme.cardStyle() modifier for consistent card styling.

import SwiftUI

struct MetricCard: View {
	let title: String
	let value: String

	@Environment(\.ocoreaiTheme) private var theme

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(title)
				.font(.ocoreaiText(11))
				.foregroundStyle(theme.textSecondary)
			Text(value)
				.font(.ocoreaiDisplay(20))
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.modifier(theme.cardStyle())
		.accessibilityLabel("\(title): \(value)")
		.accessibilityAddTraits(.isStaticText)
	}
}
