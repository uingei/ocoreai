// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

#if canImport(CXGrammar)
import CXGrammar
#endif
import Foundation

/// The vocabulary encoding xgrammar must be told about when it compiles a grammar.
///
/// Lives outside the CoreAI gate on purpose: this is a property of the tokenizer's vocabulary,
/// not of a backend, and `cValue` needs only CXGrammar (a local C shim). Gating it on CoreAI
/// deleted the one piece of this file that every grammar lane reasons about, and left it
/// untestable on any macOS 26 host.
enum VocabularyType: Sendable, Equatable {
    case raw
    case byteFallback
    case byteLevel

    /// Infers the encoding from the token strings. SentencePiece byte-fallback vocabularies
    /// (Gemma, Llama) carry all 256 `<0xHH>` byte tokens; anything else is treated as
    /// byte-level BPE. A mismatched type makes xgrammar map token ids to the wrong strings,
    /// which presents as valid JSON being rejected mid-generation.
    ///
    /// upstream: coreai-models #359, `swift/Sources/CoreAILanguageModels/GuidedGeneration/TokenizerInfo.swift:113`
    static func detect(vocabulary: [String]) -> VocabularyType {
        var byteTokens = Set<String>()
        for token in vocabulary
        where token.utf8.count == 6 && token.hasPrefix("<0x") && token.hasSuffix(">") {
            byteTokens.insert(token.uppercased())
            if byteTokens.count == 256 { return .byteFallback }
        }
        return .byteLevel
    }
}

#if canImport(CXGrammar)
extension VocabularyType {
    var cValue: XGrammarVocabType {
        switch self {
        case .raw: return XGRAMMAR_VOCAB_RAW
        case .byteFallback: return XGRAMMAR_VOCAB_BYTE_FALLBACK
        case .byteLevel: return XGRAMMAR_VOCAB_BYTE_LEVEL
        }
    }
}
#endif

#if canImport(CoreAI)

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
        vocabType: VocabularyType? = nil,
        addPrefixSpace: Bool = false
    ) {
        // The single resolution point: every grammar entry point reaches xgrammar through here,
        // so a caller that does not state an encoding gets the one inferred from its own
        // vocabulary instead of a constant that is wrong for SentencePiece checkpoints.
        let resolvedType = vocabType ?? VocabularyType.detect(vocabulary: vocabulary)
        self.vocabulary = vocabulary
        self.vocabType = resolvedType
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
                resolvedType.cValue,
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
        vocabType: VocabularyType? = nil
    ) -> TokenizerInfo {
        // Resolve before keying: the encoding is part of what the cached handle encodes, so a
        // key that said `nil` would let a byte-level and a byte-fallback handle share a slot.
        let resolvedType = vocabType ?? VocabularyType.detect(vocabulary: vocabulary)
        let cacheKey = "\(modelName)_\(resolvedType)_\(vocabulary.count)"
        if let cached = cache[cacheKey] {
            return cached
        }

        let info = TokenizerInfo(
            vocabulary: vocabulary,
            vocabType: resolvedType
        )
        cache[cacheKey] = info
        return info
    }

    /// Clear the cache
    func clear() {
        cache.removeAll()
    }
}

#endif
