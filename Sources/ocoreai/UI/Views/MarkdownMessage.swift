// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MarkdownMessage — renders chat message content with code block support.
///
/// Renders:
/// - Basic text content with code block support
/// - Fenced code blocks with language label + copy button
/// - Code block background uses theme.codeBg
///
/// Accessibility: raw text exposed via accessibilityLabel, VoiceOver compatible.

import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Renders message content with code block highlighting and copy support.
struct MarkdownMessage: View {
    let content: String
    @Environment(\.ocoreaiTheme) private var theme

    @State private var copiedIndex = -1

    var body: some View {
        ContentRouter(
            content: content,
            codeBg: theme.codeBg,
            textColor: theme.text,
            textSecondaryColor: theme.textSecondary,
            textTertiaryColor: theme.textTertiary,
            copiedIndex: $copiedIndex
        )
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Content Router

/// Routes between plain-text and code-block parsing.
/// If content contains fenced code blocks (```), splits into segments;
/// otherwise renders as plain Text.
struct ContentRouter: View {
    let content: String
    let codeBg: Color
    let textColor: Color
    let textSecondaryColor: Color
    let textTertiaryColor: Color
    @Binding var copiedIndex: Int

    private var hasFencedBlocks: Bool {
        content.contains("```")
    }

    var body: some View {
        Group {
            if hasFencedBlocks {
                SegmentedContent(
                    content: content,
                    codeBg: codeBg,
                    textColor: textColor,
                    textSecondaryColor: textSecondaryColor,
                    textTertiaryColor: textTertiaryColor,
                    copiedIndex: $copiedIndex
                )
            } else {
                Text(content)
                    .font(.ocoreaiText(15))
                    .lineSpacing(3)
            }
        }
    }
}

// MARK: - Segmented Renderer (with code blocks)

struct SegmentedContent: View {
    let content: String
    let codeBg: Color
    let textColor: Color
    let textSecondaryColor: Color
    let textTertiaryColor: Color
    @Binding var copiedIndex: Int

    private var segments: [(type: SegmentType, text: String, language: String)] {
        parseSegments(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                switch segment.type {
                case .text:
                    Text(segment.text)
                        .font(.ocoreaiText(15))
                        .lineSpacing(3)
                case .code(let lang):
                    CodeBlock(
                        code: segment.text,
                        language: lang,
                        codeBg: codeBg,
                        textTertiaryColor: textTertiaryColor,
                        copiedIndex: $copiedIndex,
                        blockIndex: idx
                    )
                }
            }
        }
    }

    private enum SegmentType {
        case text
        case code(language: String)
    }

    private func parseSegments(_ text: String) -> [(SegmentType, String, String)] {
        var result: [(SegmentType, String, String)] = []
        let parts = text.split(separator: "```", omittingEmptySubsequences: false)

        var isCode = false
        for part in parts {
            let trimmed = String(part).trimmingCharacters(in: .newlines)
            if trimmed.isEmpty { continue }

            if isCode {
                let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                let language = lines.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                let code = (lines.count > 1) ? String(lines[1]).trimmingCharacters(in: .newlines) : trimmed
                result.append((.code(language: language), code, language))
            } else {
                result.append((.text, trimmed, ""))
            }
            isCode.toggle()
        }

        return result
    }
}

// MARK: - Code Block

struct CodeBlock: View {
    let code: String
    let language: String
    let codeBg: Color
    let textTertiaryColor: Color
    @Binding var copiedIndex: Int
    let blockIndex: Int

    @Environment(\.ocoreaiTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !language.isEmpty, language != "\n" {
                    Text(language)
                        .font(.ocoreaiMono(10))
                        .foregroundStyle(textTertiaryColor)
                        .textCase(.uppercase)
                } else {
                    Text("code")
                        .font(.ocoreaiMono(10))
                        .foregroundStyle(textTertiaryColor)
                        .textCase(.uppercase)
                }
                Spacer()

            #if os(macOS)
                Button(StringKey.copyCode.l) {
                    NSPasteboard.general.setString(code, forType: .string)
                    copiedIndex = blockIndex
                    // Use MainActor.run to safely capture state
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copiedIndex = -1
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(copiedIndex == blockIndex ? theme.greenDot : textTertiaryColor)
                .font(.ocoreaiMono(10))
                .accessibilityLabel(StringKey.copyCode.l)
            #endif
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(codeBg.opacity(0.5))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.ocoreaiMono(13))
                    .foregroundStyle(theme.text)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(codeBg.opacity(0.8))
            .clipShape(Rectangle())
        }
        .background(codeBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.cardBorder, lineWidth: 0.5),
        )
        .accessibilityLabel("Code block: \(code)")
    }
}

// MARK: - Preview

/// #Preview requires Xcode PreviewsMacros plugin — disabled for swift build.
