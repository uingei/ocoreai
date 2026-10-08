// Copyright © 2026 uingei@163.com.
// Licensed under MIT.

// MARK: - Approval escape channel (macOS native notifications)
//
// First-principles gap: the approval banner lives in the Chat tab
// (ChatView ApprovalBanner). If the user navigates to Models/Settings while
// the agent waits on a `.interactive` approval, the request is INVISIBLE and
// the agent hangs until timeout or session-end — a silent deadlock.
//
// Apple's answer (Human Interface Guidelines → Notifications): "Notifications
// draw attention to time-sensitive information when your app is in the
// background." This module posts a system notification for every pending
// approval and routes the click back to the Chat tab, where the banner holds
// the ONLY adjudication surface — deliberately: two decision surfaces
// (notification action + banner) would need a second sync protocol and drift.
//
// Honesty constraints:
// • Authorization errors are logged, never fatal — a denied notification
//   permission must not break the in-app banner path.
// • Unsigned/dev binaries: UNUserNotificationCenter.requestAuthorization can
//   error (no bundle identity). That is environment physics — log once,
//   degrade to banner-only, keep working.
// • Headless/`serve` mode has no GUI: callers must skip this module entirely
//   (fail-closed denial path stays, per ToolRegistry contract).

import Foundation
import UserNotifications

#if os(macOS)
import AppKit

/// Posts approval-pending system notifications and routes taps to the chat tab.
/// All entry points are @MainActor: it touches AppState.selectedTab.
@MainActor
enum ApprovalNotifier {
    private static var authorized = false
    private static var authAttempted = false
    /// Delegate retained forever (UN center holds a weak reference).
    private static var delegateInstalled = false

    /// Notification category identifier (single category: one "Open ocoreai"
    /// dismiss action — the banner adjudicates).
    static let categoryIdentifier = "ocoreai.approval"

    /// Install the tap handler (idempotent). Call once at GUI startup.
    static func install() {
        guard !delegateInstalled else { return }
        delegateInstalled = true
        let center = UNUserNotificationCenter.current()
        center.delegate = ApprovalTapHandler.shared
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: categoryIdentifier,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    /// Request authorization lazily on the FIRST pending approval (not at
    /// launch: the prompt belongs to the moment the user can connect "I need
    /// to be told" — HIG timing; and headless never asks).
    static func notifyPendingApproval(toolName: String, snippet: String) {
        install()
        let center = UNUserNotificationCenter.current()
        if !authAttempted {
            authAttempted = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                Task { @MainActor in
                    authorized = granted
                    if let error {
                        // Banner stays the source of truth; log-and-continue.
                        NSLog(
                            "ocoreai approval notification authorization failed: \(error.localizedDescription) — banner-only mode"
                        )
                    }
                    // Re-fetch the singleton instead of sending `center` across
                    // the isolation boundary (region isolation rejects passing a
                    // non-Sendable UN center into an escaping closure; the
                    // class-getter always returns the same process-wide center).
                    deliver(
                        UNUserNotificationCenter.current(), toolName: toolName, snippet: snippet)
                }
            }
            return
        }
        if authorized {
            deliver(center, toolName: toolName, snippet: snippet)
        }
    }

    private static func deliver(
        _ center: UNUserNotificationCenter,
        toolName: String,
        snippet: String
    ) {
        let content = UNMutableNotificationContent()
        // The snippet is the REVIEW surface — same 80-grapheme truncation the
        // banner shows (ApprovalCore.snippet), so notification and banner can
        // never disagree about what the user is being asked to approve.
        content.title = "ocoreai 需要你的批准 · approval needed"
        content.body = "\(toolName): \(snippet)\n点击返回对话裁决 · click to decide in chat"
        content.categoryIdentifier = categoryIdentifier
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "ocoreai-approval-\(UUID().uuidString)",
            content: content,
            trigger: nil  // deliver immediately
        )
        center.add(request) { error in
            if let error {
                NSLog("ocoreai approval notification add failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Tap → jump to Chat tab. The banner there holds the adjudication buttons;
/// this handler does NOT approve/deny (single decision surface by design).
final class ApprovalTapHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ApprovalTapHandler()

    // Foreground presentation: the banner already covers in-chat; the system
    // notification only needs to appear when the app is backgrounded OR the
    // chat tab is not visible — presenting as banner+list keeps it simple and
    // never blocks; the badge is the point.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Tap → chat tab. @MainActor hop: AppState is main-actor isolated.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            AppState.shared.selectedTab = .chat
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }
}
#endif
