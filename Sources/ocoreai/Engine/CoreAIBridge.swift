// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// CoreAI bridge — Shared types used by CoreAIModelLoader and CoreAIEngine.
// Compiled only when 'coreai' trait is active.
#if canImport(CoreAI)

import Foundation

// MARK: - Error Types

/// Errors specific to Core AI bridge operations.
///
/// Used by both ``CoreAIModelLoader`` and ``CoreAIEngine``.
enum CoreAIBridgeError: Error, LocalizedError {
    /// The official Core AI specialization failed, fell back to EngineFactory
    case specializationFailed(String)

    /// Model file not found at expected path
    case modelFileNotFound(URL)

    /// Incompatible Core AI version
    case incompatibleCoreAI(String)

    /// Model cache is unavailable
    case cacheUnavailable

    var errorDescription: String? {
        switch self {
        case .specializationFailed(let msg):
            "Core AI specialization failed: \(msg)"
        case .modelFileNotFound(let url):
            "Model file not found at \(url.path)"
        case .incompatibleCoreAI(let msg):
            "Core AI incompatibility: \(msg)"
        case .cacheUnavailable:
            "Model cache unavailable"
        }
    }
}

#endif
