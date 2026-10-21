// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ClaimVsAudit.swift — a turn's last sentence about itself has to match what its tools did.
///
/// Invariant 2 ("the surface never claims more than the engine delivered") has a hole at the
/// end of a turn: the loop stops when the model stops, and nothing compares the final sentence
/// with the tool record. Both directions were measured 2026-10-22 in `scripts/eval/run.sh`
/// against `mlx-community/gemma-4-e2b-it-4bit`:
///   • `multi-step-nested-write` answered "File created." with **zero** tool calls in the turn
///     (`finish_reason: stop`, `tool_calls: null`) while `build/report.txt` did not exist;
///   • `fix-off-by-one` answered "I failed to fix the code…" although an `edit_file` had
///     already succeeded and the verifier judged the workspace correct.
/// The first is a GUI lying to a user; the second talks the user out of finished work. Both
/// ride into session memory, FTS and `/sessions` and stay there.
///
/// The audit side of the comparison is `ToolMutationLedger`, fed from the single dispatch
/// chokepoint (`ToolRegistry.call`), so it counts what actually executed — not what the model
/// said, and not what the wire echoed (native tool turns echo nothing: the loop runs inside
/// `ChatSession`, which is why `usage` reports `tool_calls: null` on turns that edited files).

import Foundation

/// A file-changing tool call that returned successfully during this process' lifetime.
struct SuccessfulMutation: Equatable, Sendable {
    /// Tool that performed it (`write_file`, `edit_file`, `exec_command`, …).
    let tool: String
    /// The path or command it named, when its arguments carried one — the part a user acts on.
    let target: String?
}

/// Process-wide counter of successful file-changing tool calls.
///
/// Monotonic counter + snapshot-at-turn-head is deliberate: the wire can run several turns
/// concurrently, and a per-conversation ledger needs a conversation key at the dispatch site
/// that only the engine has (`EngineInference`'s `convKey`). The skew is one-directional and
/// safe: another client's successful write can only *inflate* this turn's mutation set, which
/// suppresses a notice — it can never invent a contradiction that was not there.
actor ToolMutationLedger {
    static let shared = ToolMutationLedger()

    /// How many recent mutations to keep for naming in a notice (turn-local windows are
    /// tiny; the cap exists so a long-lived server does not grow this without bound).
    private static let window = 32

    private var total: UInt64 = 0
    private var recent: [(seq: UInt64, mutation: SuccessfulMutation)] = []

    /// A successful call counts as mutating unless the registry calls the tool read-only —
    /// `readOnlyWhitelist` is that truth's home (`ToolRegistry`), so a new read tool cannot
    /// silently start producing "nothing was written" notices, and an unknown external (MCP)
    /// tool is treated as mutating, which stays the safe direction.
    static func countsAsMutation(isReadOnly: Bool) -> Bool {
        !isReadOnly
    }

    func record(_ mutation: SuccessfulMutation) {
        total &+= 1
        recent.append((total, mutation))
        if recent.count > Self.window {
            recent.removeFirst(recent.count - Self.window)
        }
    }

    /// Baseline for one turn: take this at the turn head, ask `since(_:)` at its finalize.
    func snapshot() -> UInt64 {
        total
    }

    /// Everything that succeeded after `baseline`, oldest first.
    func since(_ baseline: UInt64) -> [SuccessfulMutation] {
        recent.filter { $0.seq > baseline }.map(\.mutation)
    }
}

/// Decides whether a final answer contradicts its own turn's tool record.
enum ClaimVsAudit {

    /// Verbs asserting a file got changed, for a **success** claim. Broad on purpose: "fixed",
    /// "implemented" and "replaced" are how a coding agent reports done work.
    private static let changeVerbs = [
        "creat", "writ", "sav", "updat", "modif", "patch", "delet", "append", "edit",
        "fix", "chang", "refactor", "implement", "replac",
        "创建", "写入", "保存", "更新", "修改", "删除", "新增", "修复", "替换", "实现", "改",
    ]

    /// Narrower set for a **failure** claim: only file-operation verbs. "the test fails" and
    /// "it cannot compile" are verification statements — a successful edit does not refute
    /// them, so calling them contradicted would over-claim in the other direction.
    private static let operationVerbs = [
        "creat", "writ", "sav", "updat", "modif", "patch", "delet", "append", "edit",
        "创建", "写入", "保存", "更新", "修改", "删除", "新增",
    ]

    /// Markers that the same sentence says the thing did *not* happen.
    private static let failureMarkers = [
        "fail", "could not", "couldn\u{2019}t", "unable", "not possible", "refus", "denied",
        "error", "not found", "does not exist", "no such",
        "失败", "无法", "未能", "不能", "没", "未成功", "报错", "不存在", "找不到",
    ]

    /// A claim has to be about a file/artifact, not just contain a verb: "creative writing"
    /// and "let me fix that later" are not completion claims.
    private static let fileContextMarkers = [
        "file", "path", "director", "folder", "config", "code", "script", "sourc", "function",
        "document", "note", "report", "test", "readme", "output",
        "文件", "目录", "代码", "配置", "脚本", "函数", "文档", "笔记", "报告", "测试",
    ]

    /// Extension-ish token (`.py`, `.toml`, `.md`) — a file named without saying "file".
    private static let extensionPattern = try? NSRegularExpression(
        pattern: "\\.[A-Za-z][A-Za-z0-9]{1,5}\\b")

    /// Intent, not completion: "I will create the file" is a plan, and a turn cut mid-plan is
    /// not a false report. A sentence carrying one of these never counts as a claim.
    private static let intentMarkers = [
        "will ", "i'll ", "would like to", "going to", "let me", "now creat", "now writ",
        "next, ",
        "将", "接下来", "马上", "现在创", "现在写", "我来创", "我来写", "准备创", "准备写",
    ]

    private static let sentenceSeparators: CharacterSet = {
        var set = CharacterSet.newlines
        set.insert(charactersIn: "。！？!?")
        return set
    }()

    private static func hasFileContext(_ text: String) -> Bool {
        if fileContextMarkers.contains(where: { text.contains($0) }) {
            return true
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return extensionPattern?.firstMatch(in: text, range: range) != nil
    }

    /// A sentence that says a file operation did not happen.
    static func claimsFailure(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        return operationVerbs.contains { lower.contains($0) }
            && failureMarkers.contains { lower.contains($0) }
            && hasFileContext(lower)
    }

    /// A sentence that asserts a file got changed, with no denial in the same sentence.
    static func claimsSuccess(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        return changeVerbs.contains { lower.contains($0) }
            && !failureMarkers.contains { lower.contains($0) }
            && !intentMarkers.contains { lower.contains($0) }
            && hasFileContext(lower)
    }

    /// The corrective line, or nil when the turn's story and its tool record agree.
    ///
    /// Two firings, both conservative:
    ///   • claims success, mutated nothing → say so, and name what did run;
    ///   • claims failure, did mutate → name the files that changed.
    /// A turn containing both kinds (or a grammar/tool termination) is ambiguous and stays quiet.
    static func notice(text: String, mutations: [SuccessfulMutation]) -> String? {
        var successClaims = 0
        var failureClaims = 0
        for sentence in text.components(separatedBy: sentenceSeparators) {
            if claimsFailure(sentence) {
                failureClaims += 1
            } else if claimsSuccess(sentence) {
                successClaims += 1
            }
        }
        if successClaims > 0, failureClaims == 0, mutations.isEmpty {
            return "[audit] Nothing was written or edited in this turn (0 successful file-"
                + "changing tool calls), so the completion claim above is not backed by the "
                + "workspace. Verify the path before treating it as done."
        }
        if failureClaims > 0, !mutations.isEmpty {
            let named = mutations.compactMap(\.target).prefix(4).joined(separator: ", ")
            let what =
                named.isEmpty
                ? mutations.map(\.tool).joined(separator: ", ")
                : "\(mutations.count) successful change(s): \(named)"
            return "[audit] This turn did change files — \(what). The failure reported above "
                + "does not match the audit trail; re-read the file before redoing the work."
        }
        return nil
    }
}
