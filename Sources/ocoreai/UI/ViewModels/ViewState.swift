// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Screen State machine — omlx pattern: .idle → .loading → .success(T) / .failed(Error)
/// All ViewModels share this state progression.

import Foundation
import SwiftUI

// MARK: - ViewState

/// omlx-style screen state machine
enum ViewState<T: Sendable>: Sendable {
    case idle
    case loading
    case success(T)
    case failed(Error)

    var isSuccess: Bool       { if case .success = self { true } else { false } }
    var isLoading: Bool       { if case .loading = self { true } else { false } }
    var data: T?             { if case .success(let d) = self { d } else { nil } }
    var error: Error?        { if case .failed(let e) = self { e } else { nil } }
}

// MARK: - ErrorState View

/// Reusable error state with retry button — omlx style
struct ErrorStateView: View {
    let error: Error
    let retry: () -> Void

    @Environment(\.ocoreaiTheme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.ocoreaiText(32, weight: .light))
                .foregroundStyle(theme.redDot.opacity(0.7))

            Text(StringKey.connectionFailedTitle.l)
                .font(.ocoreaiDisplay(17))

            Text(error.localizedDescription)
                .font(.ocoreaiText(14))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("Try Again") {
                retry()
            }
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))

            Text(StringKey.connectionFailedDesc.l)
                .font(.ocoreaiText(11))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(40)
        .modifier(theme.cardStyle())
    }
}

// MARK: - LoadingState View

/// Reusable loading indicator — omlx style
struct LoadingStateView: View {
    let message: String

    @Environment(\.ocoreaiTheme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
            Text(message)
                .font(.ocoreaiText(14))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
