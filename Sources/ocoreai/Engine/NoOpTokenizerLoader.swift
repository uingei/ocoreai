// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// NoOpTokenizerLoader.swift — Stub tokenizer loader for MTP drafter loading.
///
/// MTPDrafterModelFactory._load() accepts a TokenizerLoader but immediately
/// ignores it — the drafer borrows its target's tokenizer at inference time.
/// This no-op implementation satisfies the protocol requirement.

import Foundation
import MLXLMCommon

/// A TokenizerLoader that throws when asked to load, used for MTP drafters
/// which don't need their own tokenizer.
///
/// MTPDrafterModelFactory._load() accepts a TokenizerLoader but immediately
/// ignores it — the drafer borrows its target's tokenizer at inference time.
final class NoOpTokenizerLoader: TokenizerLoader, Sendable {
    func load(from directory: URL) async throws -> any Tokenizer {
        fatalError("NoOpTokenizerLoader should not be called — MTP drafters borrow the target's tokenizer")
    }
}
