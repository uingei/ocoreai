// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// StatusPill — dot + label status indicator, omlx-style.
/// 5 built-in states: running, starting, stopping, stopped, error.
/// Compact mode: dot only.

import SwiftUI

// MARK: - StatusPill State

enum SPStatus: Sendable {
    case running
    case starting
    case stopping
    case stopped
    case `error`
    case custom(color: Color, label: String, fillBg: Bool)

    var dotColor: Color {
        switch self {
        case .running:  return .green
        case .starting: return .blue
        case .stopping: return .orange
        case .stopped:  return Color.gray
        case .error:    return .red
        case .custom(let c, _, _): return c
        }
    }

    var label: String {
        switch self {
        case .running:  return StringKey.statusRunning.l
        case .starting: return StringKey.statusStarting.l
        case .stopping: return StringKey.statusStopping.l
        case .stopped:  return StringKey.statusStopped.l
        case .error:    return StringKey.statusError.l
        case .custom(_, let l, _): return l
        }
    }

    var fillBg: Bool {
        switch self {
        case .custom(_, _, let f): return f
        default: return true
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
