// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// StatusPill — dot + label status indicator.
/// 5 built-in states: running, starting, stopping, stopped, error.
/// Compact mode: dot only.

import SwiftUI

// MARK: - StatusPill State

enum SPStatus {
    case running
    case starting
    case stopping
    case stopped
    case error
    case custom(color: Color, label: String, fillBg: Bool)

    var dotColor: Color {
        switch self {
        case .running: .green
        case .starting: .blue
        case .stopping: .orange
        case .stopped: Color.gray
        case .error: .red
        case let .custom(c, _, _): c
        }
    }

    var label: String {
        switch self {
        case .running: StringKey.statusRunning.l
        case .starting: StringKey.statusStarting.l
        case .stopping: StringKey.statusStopping.l
        case .stopped: StringKey.statusStopped.l
        case .error: StringKey.statusError.l
        case let .custom(_, l, _): l
        }
    }

    var fillBg: Bool {
        switch self {
        case let .custom(_, _, f): f
        default: true
        }
    }
}

// MARK: - StatusPill

struct StatusPill: View {
    let status: SPStatus
    var compact: Bool = false

    @Environment(\.ocoreaiTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.dotColor)
                .frame(width: 6, height: 6)
                .shadow(color: status.dotColor.opacity(0.3), radius: 2)

            if !compact {
                Text(status.label)
                    .font(.ocoreaiText(11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(status.dotColor.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
    }
}
