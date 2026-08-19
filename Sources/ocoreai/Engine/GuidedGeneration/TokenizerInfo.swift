// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

#if canImport(CoreAI)

import CXGrammar
import Foundation

@available(macOS 27.0, iOS 27.0, *)
final class TokenizerInfo {
    private let handle: OpaquePointer
    let vocabulary: [String]
    let vocabularySize: Int
    let vocabType: VocabularyType
    let addPrefixSpace: Bool

    /// Extract vocabulary from any tokenizer with a vocabulary property
    init(
        vocabulary: [String],
        vocabType: VocabularyType = .raw,
        addPrefixSpace: Bool = false
    ) {
        self.vocabulary = vocabulary
        self.vocabType = vocabType
        self.addPrefixSpace = addPrefixSpace

        // Convert Swift strings to C string array
        let cStrings = vocabulary.map { strdup($0) }
        defer {
            for ptr in cStrings { free(ptr) }
        }

        let cStringArray = UnsafeMutablePointer<UnsafePointer<Int8>?>.allocate(
            capacity: vocabulary.count)
        defer {
            cStringArray.deallocate()
        }

        for (i, cStr) in cStrings.enumerated() {
            cStringArray[i] = UnsafePointer(cStr)
        }

        // Call C bridge — NULL indicates a programming error (corrupt vocabulary)
        guard
            let handle = xgrammar_tokenizer_info_create(
                cStringArray,
                Int32(vocabulary.count),
                vocabType.cValue,
                addPrefixSpace
            )
        else {
            preconditionFailure(
                "Failed to create xgrammar TokenizerInfo: invalid vocabulary (\(vocabulary.count) tokens)"
            )
        }

        self.handle = handle
        self.vocabularySize = Int(xgrammar_tokenizer_info_get_vocab_size(handle))
    }

    deinit {
        xgrammar_tokenizer_info_free(handle)
    }

    internal var cHandle: OpaquePointer {
        handle
    }
}

// MARK: - Vocabulary Caching

/// Cache for tokenizer info to avoid repeated vocabulary extraction
@available(macOS 27.0, iOS 27.0, *)
actor TokenizerInfoCache {
    private var cache: [String: TokenizerInfo] = [:]

    init() {}

    /// Get or create tokenizer info for a model
    ///
    /// - Parameters:
    ///   - modelName: Name of the model (e.g., "Qwen/Qwen2.5-1.5B")
    ///   - vocabulary: The vocabulary array
    /// - Returns: Cached or newly created TokenizerInfo
    func getOrCreate(
        modelName: String,
        vocabulary: [String],
        vocabType: VocabularyType = .byteLevel
    ) -> TokenizerInfo {
        let cacheKey = "\(modelName)_\(vocabType)_\(vocabulary.count)"
        if let cached = cache[cacheKey] {
            return cached
        }

        let info = TokenizerInfo(
            vocabulary: vocabulary,
            vocabType: vocabType
        )
        cache[cacheKey] = info
        return info
    }

    /// Clear the cache
    func clear() {
        cache.removeAll()
    }
}

@available(macOS 27.0, iOS 27.0, *)
enum VocabularyType: Sendable {
    case raw
    case byteFallback
    case byteLevel

    var cValue: XGrammarVocabType {
        switch self {
        case .raw: return XGRAMMAR_VOCAB_RAW
        case .byteFallback: return XGRAMMAR_VOCAB_BYTE_FALLBACK
        case .byteLevel: return XGRAMMAR_VOCAB_BYTE_LEVEL
        }
    }
}

#endif
