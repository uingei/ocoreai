// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Shared animation helpers — reduce motion guard for all SwiftUI animations
/// Centralized so P1 HIG compliance is enforced app-wide, not per-view.

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Whether the user prefers reduced motion (Apple Accessibility → Reduce Motion).
/// True = safe to suppress all non-essential animation.
///
/// HIG compliance: every `.animation(...)` and `withAnimation { }` in the app
/// should gate through this property.
public var reduceMotion: Bool {
	#if os(macOS)
	NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
	#else
	UIAccessibility.isReduceMotionEnabled
	#endif
}

/// Execute a closure with animation automatically suppressed for reduced-motion users.
/// Convenience wrapper: `withAnimationRespectingAccessibility { contentChanges }`
///
/// Usage:
///     .onChange(of: count) {
///         withAnimationRespectingAccessibility {
///             proxy.scrollTo("bottom", anchor: .bottom)
///         }
///     }
public func withAnimationRespectingAccessibility(_ animation: Animation = .easeInOut(duration: 0.2), _ actions: () -> Void) {
	if reduceMotion {
		actions()
	} else {
		withAnimation(animation, actions)
	}
}
