// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// OcoreaiList — reusable grouped list layout.
/// Wraps content in a card-styled group with consistent spacing.

import SwiftUI

struct OcoreaiListGroup<Content: View>: View {
	@ViewBuilder let content: Content

	@Environment(\.ocoreaiTheme) private var theme

	var body: some View {
		content
			.padding(12)
			.background(theme.groupBg)
			.clipShape(RoundedRectangle(cornerRadius: 16))
	}
}
