// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

#if canImport(CoreAI)

import CXGrammar
import Foundation

// MARK: - Compiled Grammar

@available(macOS 27.0, iOS 27.0, *)
final class CompiledGrammar {
    private let handle: OpaquePointer
    let tokenizerInfo: TokenizerInfo

    fileprivate init(handle: OpaquePointer, tokenizerInfo: TokenizerInfo) {
        self.handle = handle
        self.tokenizerInfo = tokenizerInfo
    }

    deinit {
        xgrammar_compiled_grammar_free(handle)
    }

    var memorySizeBytes: Int {
        Int(xgrammar_compiled_grammar_memory_size(handle))
    }

    internal var cHandle: OpaquePointer {
        handle
    }
}

// MARK: - Grammar Compiler

@available(macOS 27.0, iOS 27.0, *)
final class GrammarCompiler {
    private let handle: OpaquePointer
    private let tokenizerInfo: TokenizerInfo

    init(
        tokenizerInfo: TokenizerInfo,
        maxThreads: Int = 8,
        cacheEnabled: Bool = true
    ) {
        self.tokenizerInfo = tokenizerInfo

        guard
            let handle = xgrammar_compiler_create(
                tokenizerInfo.cHandle,
                Int32(maxThreads),
                cacheEnabled
            )
        else {
            preconditionFailure("Failed to create xgrammar GrammarCompiler")
        }

        self.handle = handle
    }

    deinit {
        xgrammar_compiler_free(handle)
    }

    func compileJSONSchema(
        _ schema: String,
        anyWhitespace: Bool = true,
        strictMode: Bool = true
    ) throws -> CompiledGrammar {
        guard
            let grammarHandle = xgrammar_compile_json_schema(
                handle,
                schema,
                anyWhitespace,
                strictMode
            )
        else {
            throw XGrammarError.schemaCompilationFailed(schema)
        }

        return CompiledGrammar(handle: grammarHandle, tokenizerInfo: tokenizerInfo)
    }
}

// MARK: - Grammar Matcher

@available(macOS 27.0, iOS 27.0, *)
final class GrammarMatcher {
    private let handle: OpaquePointer
    private let vocabularySize: Int

    init(
        compiledGrammar: CompiledGrammar,
        maxRollbackTokens: Int = 0
    ) {
        self.vocabularySize = compiledGrammar.tokenizerInfo.vocabularySize

        guard
            let handle = xgrammar_matcher_create(
                compiledGrammar.cHandle,
                Int32(maxRollbackTokens)
            )
        else {
            preconditionFailure("Failed to create xgrammar GrammarMatcher")
        }

        self.handle = handle
    }

    deinit {
        xgrammar_matcher_free(handle)
    }

    func fillNextTokenBitmask(_ bitmask: UnsafeMutablePointer<Int32>) -> Bool {
        // Create DLTensor for the bitmask
        let bitmaskSize = (vocabularySize + 31) / 32
        var shape = Int64(bitmaskSize)

        return withUnsafeMutablePointer(to: &shape) { shapePtr in
            var dlTensor = DLTensor(
                data: UnsafeMutableRawPointer(bitmask),
                device: DLDevice(device_type: kDLCPU, device_id: 0),
                ndim: 1,
                dtype: DLDataType(code: UInt8(kDLInt.rawValue), bits: 32, lanes: 1),
                shape: shapePtr,
                strides: nil,
                byte_offset: 0
            )

            return xgrammar_matcher_fill_next_token_bitmask(handle, &dlTensor)
        }
    }

    func acceptToken(_ tokenId: Int32) -> Bool {
        return xgrammar_matcher_accept_token(handle, tokenId)
    }

    var isTerminated: Bool {
        return xgrammar_matcher_is_terminated(handle)
    }

    var isCompleted: Bool {
        return xgrammar_matcher_is_completed(handle)
    }

    func reset() {
        xgrammar_matcher_reset(handle)
    }

    @discardableResult
    func rollback(_ numTokens: Int = 1) -> Bool {
        xgrammar_matcher_rollback(handle, Int32(numTokens))
    }

    /// Returns the longest deterministic string from the current grammar state,
    /// or nil if no jump-forward is possible. Does not change matcher state.
    func findJumpForwardString() -> String? {
        guard let cStr = xgrammar_matcher_find_jump_forward_string(handle) else {
            return nil
        }
        let result = String(cString: cStr)
        free(UnsafeMutablePointer(mutating: cStr))
        return result.isEmpty ? nil : result
    }
}

// MARK: - Errors

@available(macOS 27.0, iOS 27.0, *)
enum XGrammarError: Error, LocalizedError {
    case schemaCompilationFailed(String)

    var errorDescription: String? {
        switch self {
        case .schemaCompilationFailed(let schema):
            return "Failed to compile JSON schema: \(schema.prefix(200))"
        }
    }
}

#endif
