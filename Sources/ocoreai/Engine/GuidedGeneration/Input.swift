// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause
//
// Absorbed from coreai-models TextGeneration/TextGenerator.swift (Input + PromptUtils),
// as required by the DecodingStrategy protocol family (#146 absorption, aligned #170).

#if canImport(CoreAI)

import Foundation
import Tokenizers

// MARK: - LLM Input Specification

/// Represents different types of input that can be provided to a language model
///
/// Use this enum to specify whether input text should be processed as raw text
/// or formatted as a prompt with template application.
@available(macOS 27.0, iOS 27.0, *)
enum Input: Sendable {
    /// Raw text input without any template formatting
    /// - Parameter String: The unformatted text to process
    case rawText(String)

    /// Prompt input that may be formatted using a chat template
    /// - Parameter String: The prompt text to be formatted
    case prompt(String)

    /// Pre-tokenized input - bypasses tokenization entirely
    /// - Parameter [Int]: Array of token IDs
    case tokens([Int])
}

// MARK: - Prompt Utilities

/// Utility functions for prompt formatting
@available(macOS 27.0, iOS 27.0, *)
struct PromptUtils {
    /// Apply chat template using tokenizer's built-in functionality
    /// This method tries to use the tokenizer's applyChatTemplate method, falling back to direct encoding
    static func maybeApplyTokenizerChatTemplate(_ input: Input, tokenizer: any Tokenizer)
        throws
        -> [Int]
    {
        switch input {
        case .rawText(let text):
            return tokenizer.encode(text: text)
        case .prompt(let prompt):
            // Try to use tokenizer's applyChatTemplate for proper chat formatting
            let messages = [["role": "user", "content": prompt]]
            let promptTokens = try tokenizer.applyChatTemplate(messages: messages)

            CLILogger.log(
                "Applied chat template using tokenizer.applyChatTemplate()", component: "Tokenizer")

            return promptTokens
        case .tokens(let tokenIds):
            // Already tokenized - return as-is
            return tokenIds
        }
    }
}

#endif
