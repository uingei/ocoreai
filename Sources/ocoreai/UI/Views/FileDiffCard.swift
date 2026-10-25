// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
import SwiftUI

/// Inline file-change review card (Bionic-parity "review every change").
///
/// Renders an `edit_file` / `write_file` tool call as a diff: collapsed by
/// default to a compact header (path + +N/−M counts), expandable to line
/// rows. The diff is COMPUTED, never trusted from narration:
/// - `edit_file`: LCS of oldString→newString (ground truth of the patch).
/// - `write_file` on modify: the old content is unrecoverable post-write,
///   so we never fabricate a before/after — we show the honest outcome
///   counts from the verified tool result instead.
///
/// Non-file tool calls must not reach this view (callers keep the badge).
struct FileDiffCard: View {
    let call: ToolCallPart

    @Environment(\.ocoreaiTheme) private var theme
    @State private var expanded: Bool = false

    private enum Kind {
        /// Real old→new diff computed from the patch arguments.
        case computed(FileDiff)
        /// write_file over an existing file: outcome counts only, no fake diff.
        /// (path, new-file line count from the verified result)
        case outcomeOnly(String, Int)
    }

    private var kind: Kind? {
        let path = call.arguments["path"] ?? ""
        switch call.name {
        case "edit_file":
            guard let old = call.arguments["oldString"],
                let new = call.arguments["newString"]
            else { return nil }
            return .computed(FileDiff.between(path: path, old: old, new: new))
        case "write_file":
            guard let content = call.arguments["content"] else { return nil }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
            // The verified tool output says "created" vs "updated" (FileTools
            // appends the verb + byte/line counts); parse the honest outcome.
            let summary = call.resultSummary ?? ""
            if summary.contains("created") {
                return .computed(FileDiff.created(path: path, content: content))
            }
            return .outcomeOnly(path, lines)
        default:
            return nil
        }
    }

    /// Only file tools with real arguments become review cards.
    static func isReviewable(_ tc: ToolCallPart) -> Bool {
        switch tc.name {
        case "edit_file":
            return tc.arguments["oldString"] != nil && tc.arguments["newString"] != nil
        case "write_file":
            return tc.arguments["content"] != nil
        default:
            return false
        }
    }

    var body: some View {
        switch kind {
        case .computed(let diff):
            computedCard(diff)
        case .outcomeOnly(let path, let lines):
            outcomeCard(path: path, lines: lines)
        case nil:
            // Arguments still streaming or malformed — keep the plain badge.
            EmptyView()
        }
    }

    // MARK: - Computed diff (edit_file, created write_file)

    private func computedCard(_ diff: FileDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimationRespectingAccessibility { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.ocoreaiText(10))
                        .foregroundStyle(theme.accent)
                        .frame(width: 20, height: 20)
                        .background(theme.accentSoft, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(diff.path)
                            .font(.ocoreaiMono(11, weight: .medium))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 8) {
                            Text(
                                String(
                                    format: StringKey.diffAddedLines.l, diff.addedCount)
                            )
                            .foregroundStyle(theme.greenDot)
                            Text(
                                String(
                                    format: StringKey.diffRemovedLines.l, diff.removedCount)
                            )
                            .foregroundStyle(theme.redDot)
                        }
                        .font(.ocoreaiMono(10))
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.ocoreaiText(10))
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                diffBody(diff)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(theme.rowSep, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            accessibilityChangeLabel(diff))
    }

    private func diffBody(_ diff: FileDiff) -> some View {
        // Monospace rows; the LCS output is already collapse()-ed to keep
        // ±3 context lines around changes, so the full render stays short.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                lineRow(line)
            }
        }
        .background(
            theme.isDark
                ? Color.black.opacity(0.25) : Color.black.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func lineRow(_ line: FileDiff.Line) -> some View {
        switch line {
        case .added(let text):
            row(text, prefix: "+", color: theme.greenDot, bg: theme.greenDot.opacity(0.12))
        case .removed(let text):
            row(text, prefix: "−", color: theme.redDot, bg: theme.redDot.opacity(0.12))
        case .context(let text):
            row(text, prefix: " ", color: theme.textTertiary, bg: .clear)
        case .elided(let count):
            Text(String(format: StringKey.diffElidedLines.l, count))
                .font(.ocoreaiMono(10))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        }
    }

    private func row(_ text: String, prefix: String, color: Color, bg: Color) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(prefix)
                .foregroundStyle(color)
            Text(text.isEmpty ? " " : text)
                .foregroundStyle(theme.text)
            Spacer(minLength: 0)
        }
        .font(.ocoreaiMono(10))
        .padding(.horizontal, 8)
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
    }

    // MARK: - Honest outcome card (write_file over an existing file)

    private func outcomeCard(path: String, lines: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.ocoreaiText(10))
                .foregroundStyle(theme.accent)
                .frame(width: 20, height: 20)
                .background(theme.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(path)
                    .font(.ocoreaiMono(11, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(
                    StringKey.diffModified.l + " · "
                        + String(format: StringKey.diffAddedLines.l, lines)
                )
                .font(.ocoreaiMono(10))
                .foregroundStyle(theme.greenDot)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(theme.rowSep, lineWidth: 1))
    }

    private func accessibilityChangeLabel(_ diff: FileDiff) -> String {
        let verb = diff.removedCount == 0 ? StringKey.diffCreated.l : StringKey.diffModified.l
        return
            "\(diff.path), \(verb), "
            + String(format: StringKey.diffAddedLines.l, diff.addedCount)
            + ", " + String(format: StringKey.diffRemovedLines.l, diff.removedCount)
    }
}
