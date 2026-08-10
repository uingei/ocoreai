// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PlatformHelpers.swift — Runtime platform capability detection
///
/// Provides synchronous boolean queries for runtime availability of
/// platform features that use compile-time conditionals (#if canImport)
/// but require runtime guards (#if #available). Useful in async/await
/// contexts where #if #available would need unwrapping.

import Foundation

/// Synchronous platform capability queries.
/// P0-fix: CoreAI runtime check decouples compile-time canImport from
/// runtime availability so HardwareRouter emit path stays in sync with
/// _runInference fallback behavior.
enum PlatformHelpers {
    /// Returns true when CoreAI runtime APIs are available (macOS/iOS 27+).
    /// Returns true unconditionally on older platforms where CoreAI is not compiled in at all.
    static var isCoreAIRuntimeAvailable: Bool {
        #if canImport(CoreAI)
        if #available(macOS 27.0, iOS 27.0, *) {
            return true
        }
        return false
        #else
        return false
        #endif
    }
}
