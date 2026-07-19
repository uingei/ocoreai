// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// OcoreaiErrorBanner — lightweight inline error banner for all model-related views.
///
/// Replaces three separate error patterns:
///   1. ChatView: localError + errorSection() — red warning + dismiss
///   2. ModelView: downloadError — red alert Button
///   3. ModelSearchSheetView: ModelSearchState.errorMessage — errorSection
///
/// Usage within a Form/Section:
///   if let error = repositoryState.currentError {
///       OcoreaiErrorBanner(error: error) { repositoryState.currentError = nil }
///   }

import SwiftUI

struct OcoreaiErrorBanner: View {
    let error: any LocalizedError
    let onDismiss: () -> Void

    @Environment(\.ocoreaiTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.redDot)
                .font(.ocoreaiText(13))
                .accessibilityHidden(true)

            Text(error.errorDescription ?? StringKey.modelSearchNoResults.l)
                .font(.ocoreaiText(13))
                .foregroundStyle(theme.redDot)
                .accessibilityAddTraits(.isStaticText)

            Spacer()

            Button(StringKey.modelSearchDismiss.l, action: onDismiss)
                .buttonStyle(.plain)
                .font(.ocoreaiText(12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.vertical, 4)
    }
}
