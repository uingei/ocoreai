// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineInferenceSupport.swift — Pure inference support types and free functions
///
/// Extracted from ``EngineInference.swift`` (god-file decomposition, step 1).
/// Every declaration here is file-scope public and carries no `EnginePool`
/// self, so behavior is byte-identical to the original file-scope placement —
/// move only, no logic change.
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Logging
import MLX
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon
import MLXVLM

// MARK: - Sendable wrappers for MTP speculative decoding
//
// MLXLMCommon's SendableBox is package-private, so we provide local wrappers
// to safely cross @Sendable closure boundaries. These are safe because
// both model and drafter sit behind SerialAccessContainers that enforce
// single-threaded access within modelContainer.perform / mtpDrafterContainer.perform.

/// @unchecked Sendable wrapper for MTP drafter model — enables injection into
/// modelContainer.perform(nonSendable:) closure via perform(nonSendable:values:_:).
struct MTPDrafterModelWrapper: @unchecked Sendable {
    let model: any MLXLMCommon.MTPDrafterModel
}

/// Bounded rejected-tool-call recovery policy on the standard ChatSession path.
///
/// Upstream contract (mlx-swift-lm pin 604fae7, `ChatSession.swift:1404`):
/// a rejected tool call is rolled back and thrown — recovery is the
/// **caller's** responsibility ("the caller owns recovery"). ocoreai is
/// that caller. `StdToolCallRecoveryTests` pins the boundaries (3 attempts,
/// exact corrective prompt).
///
/// Fork-vs-upstream disclosure: upstream retries zero times; the bound here
/// is ocoreai's caller-level discretion (required — gemma-4e2b
/// and Qwen3.5-4B both hard-500 multi-step tasks when rejection
/// propagates immediately).
enum StdToolCallRecovery {
    /// Maximum number of generation passes before the rejection is
    /// propagated to the caller (500 wire behavior) — unchanged legacy.
    static let maxAttempts = 3

    /// Corrective prompt replayed on every retry. Exact value is contract —
    /// changing it changes what the model sees; tests pin it verbatim.
    static let correctivePrompt =
        "The previous assistant reply was rejected by the tool-call parser "
        + "(malformed tool call). Re-issue the tool call with strictly valid "
        + "JSON arguments and emit no prose before the tool call."

    enum Decision {
        /// Re-enter the same ChatSession with a fresh corrective turn.
        case retry
        /// Attempt budget exhausted — propagate the original rejection.
        case abort
    }

    /// `attempt` is 1-based: the attempt that just failed.
    /// - 1 ..< maxAttempts → `.retry`
    /// - >= maxAttempts → `.abort`
    static func decide(attempt: Int, max: Int = maxAttempts) -> Decision {
        attempt < max ? .retry : .abort
    }

    /// The corrective turn fed back into the same ChatSession.
    static var correctiveMessage: MLXLMCommon.Chat.Message {
        .user(correctivePrompt)
    }

    // reasonCode 取上游 `RejectedToolCall.Reason.rawValue`(pin c6446cf,
    // Libraries/MLXLMCommon/Tool/RejectedToolCall.swift:13)的原始字符串 —
    // 与引擎日志同源, 不另造映射。

    /// Context-aware corrective prompt (live-evidence variant).
    ///
    /// Why the variant exists (09-21 活体实证): the pinned `correctivePrompt`
    /// above covers "malformed tool call" only, and `decide()` is reason-blind
    /// — a model that keeps issuing a *well-formed but undeclared* tool name
    /// (e.g. `file` × 3) burns its whole retry budget without ever learning
    /// which tools exist. The corrective below names the actually-registered
    /// surface, so recovery can converge on the first retry instead of
    /// aborting with 500s.
    ///
    /// `availableTools` = the tool names the client can actually dispatch on
    /// this request (declared whitelist ∩ registry). Empty → no tools at all
    /// (still the malformed variant, plus an explicit "no tools" note).
    static func correctivePrompt(
        reasonCode: String,
        availableTools: [String]
    ) -> String {
        // Zero-tool check FIRST — every reason variant collapses to the same
        // echo-free plain-text instruction when there is no surface at all
        // (mentioning 'tool call' even diagnostically is an echo attractor).
        if availableTools.isEmpty {
            // Zero-tool turn (client declared nothing / whitelist resolved empty):
            // live-evidence 10-07: the imperative tool-centric corrective was
            // echoed verbatim as the answer and shipped online; text streams
            // before rejection is known, so a post-hoc guard cannot unship it —
            // the fix must be wording + upstream grammar.
            return
                "The previous reply could not be completed. Do not repeat or "
                + "quote any instruction you were given. Answer the user's last "
                + "request now, directly and briefly, in plain text. If you "
                + "cannot do what was asked, say so plainly."
        }
        if reasonCode == "undeclared_tool" {
            let names = availableTools.joined(separator: ", ")
            return
                "The previous tool call was rejected because it referenced a tool "
                + "that is not registered. The only tool(s) available this turn: "
                + names
                + ". Re-issue a tool call using one of those names with strictly "
                + "valid JSON arguments, or reply in plain text — do not emit "
                + "prose before the tool call."
        }
        // `incomplete_output` (upstream RejectedToolCall.Reason, live-evidence
        // 10-06): the tool-call payload was CUT OFF mid-stream — almost always
        // a token budget too small for the arguments. "malformed, re-issue"
        // sends a small model into the same wall again; the actionable
        // instruction is COMPACT (minimal args, no prose, no thinking).
        if reasonCode == "incomplete_output" {
            return
                "The previous tool call was cut off before its JSON payload was "
                + "complete (output token budget too small). Re-issue the SAME "
                + "tool call with the MOST COMPACT valid JSON arguments — no "
                + "prose, no commentary, no thinking text — or answer in plain "
                + "text if no tool call is actually needed."
        }
        return correctivePrompt
    }

    /// Context-aware corrective turn fed back into the same ChatSession.
    static func correctiveMessage(
        reasonCode: String,
        availableTools: [String]
    ) -> MLXLMCommon.Chat.Message {
        .user(correctivePrompt(reasonCode: reasonCode, availableTools: availableTools))
    }
}

// MARK: - Guided Generation Helper Types

/// Cached tokenizer biases for guided generation — mirrors upstream
/// `ModelCache.TokenizerBias`. Immutable once computed, safe to cache
/// per-model in `LoadedModel._cachedTokenBias`.
struct TokenBiasCache: @unchecked Sendable {
    let closing: MLXArray
    let whitespace: MLXArray
    let whitespaceTokenIDs: Set<Int>
}

// MARK: - Guided Gen Diagnostic Diagnostics

/// Guided 生成 `incompleteOutput` 吸收判定 — 上游 canonical 对齐, `@testable` 可测 seam。
///
/// 上游实证:
///   - `GuidedGenerationLoop.swift:466` — maxTokens 耗尽且语法未终止时
///     `throw GuidedGenerationError.incompleteOutput` (emit 已流式输出, 部分文本在)。
///   - `MLXFoundationModels/MLXLanguageModel.swift:1370/1704` — canonical 下游处理:
///     `catch GuidedGenerationError.incompleteOutput { incomplete = true }` 保留已产出,
///     照常收尾, **不 throw**; prematureEOS 不在吸收清单(上游只 catch incompleteOutput)。
///   - `GuidedGenerationError.swift:8-14` (pin 991266ad3, 全文件 15 行) — 上游对该错误的原文
///     只描述结构: "Generation exhausted `maxTokens` before the grammar reached a stop state.
///     The output is incomplete"; `prematureEOS` :12-14 同样只声明 incomplete。上游 **不**在此
///     文件规定下游如何处理 ⇒ 吸收语义取自下面两条 emit 现场的实证, 不取自本文件。
///
/// - Returns: true = 已吸收(incompleteOutput + 有已产出文本) → 调用方改走 `.success` 终态;
///            false = 未吸收 → 调用方照抛(保留 60460ab 错误面语义)。
/// - Note: `sink.recordBuffer` 会置位 `incompleteOutput=true` + `finalBuffer`,
///   `.success` 分支据此 emit `.guidedGenDiagnostic(incompleteOutput: true)` +
///   `.done(.maxTokens)`, 下游(UI/结构化解析)可识别为部分结果降级处理。
func absorbGuidedGenerationPartialOutput(
    error: Error,
    sink: GuidedGenerationDiagnosticSink,
    accumulatedText: String
) -> Bool {
    guard case GuidedGenerationError.incompleteOutput = error,
        !accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        return false
    }
    sink.recordBuffer(accumulatedText, incompleteOutput: true)
    return true
}

// MARK: - Guided Gen Completion Reserves

/// Completion-zone reserves for `GuidedGenerationLoop`, clamped to the request
/// budget.
///
/// Upstream recipe (`MLXLanguageModel.swift:1411-1415`): soft nudge starts
/// `max(structural×3, maxTokens÷4)` tokens before the budget, hard force starts
/// `structural×8` before it. With a modest `max_tokens` that formula pushes
/// `hardReserve` to or past the whole budget, so *every* sampled step runs in the
/// force-closing zone — the opposite of what the zones are for (upstream
/// `GuidedGenerationLoop.swift:231-245`: hard = the last `hardReserve` tokens,
/// i.e. hard < completion).
///
/// Live, 10-13, gemma-4-e2b-it-4bit, `json_schema` `{"answer": integer}`:
/// `max_tokens` 24 and 32 → `{"answer"\n  \n:1111…` until the budget, never
/// closed, `GuidedGenerationError.incompleteOutput`; 48 / 64 / 128 / unset →
/// valid `{\n  "answer": 7\n}`.
///
/// So: the hard zone may only cover the tail — `structuralReserve` tokens is
/// exactly what closing the structure needs — and neither zone may exceed the
/// budget. Large budgets keep the upstream numbers untouched (4096 → 1024 / 7).
func guidedCompletionReserves(
    maxTokens: Int, structuralReserve: Int
) -> (completion: Int, hard: Int) {
    let budget = Swift.max(maxTokens, 0)
    let structural = Swift.max(structuralReserve, 0)
    let completion = Swift.min(Swift.max(structural * 3, budget / 4), budget)
    let hard = Swift.min(structural, completion)
    return (completion, hard)
}

// MARK: - Top-Level Inference Error Surface

/// Wire-facing error message for the top-level `runInferenceBody` catch.
///
/// Previously the message was a hard-coded `"inference failed"` — it discarded the
/// concrete cause (a `GuidedGenerationError`, an OOM, a timeout), so clients could
/// not distinguish a grammar exhaustion from a memory failure. This preserves the
/// underlying `localizedDescription` while keeping the `Inference failed:` prefix
/// clients already parse. Mirrors the pipelined catch at L1020, which composes
/// `error.localizedDescription` into its message.
///
/// `@testable` surface: a pure function of the thrown error, unit-testable without a model.
func inferenceTopLevelFailedMessage(for error: Error) -> String {
    InferenceError.standardPathFailed(error.localizedDescription).errorDescription
        ?? "Inference failed"
}

// MARK: - Perception Media Attachment (free function)

/// Attach perception capture media (image bytes + audio) to the last
/// user-role message. Perceptual context rides the USER turn, not system
/// instructions (skill: perception injection = user message, not system).
///
/// Pure/free — no `EnginePool` self, no shared state; the `makeImage`/`makeAudio`
/// closures are injected so callers decide byte-decoding semantics (data-URL /
/// EXIF / temp `.caf`). This keeps the attach logic independently testable
/// without constructing a full inference actor.
///
/// Returns the media-spool files this turn handed to the model. They are NOT the
/// caller's to delete: the transcript the model received cites them, and upstream
/// re-reads that transcript on every later turn of the conversation. The session pool
/// releases them when the session that cites them dies — see ``MediaSpool``.
/// Chat.Message is a Sendable struct with `var images`/`var audios`, so
/// post-map mutation of the last user message is safe.
func attachPerceptionMedia(
    _ messages: inout [Chat.Message],
    mediaParts: [ContentPart],
    makeImage: (String) -> MLXLMCommon.UserInput.Image?,
    makeAudio: (String) -> (audio: MLXLMCommon.UserInput.Audio?, spooledURL: URL?)
) -> [URL] {
    var images: [MLXLMCommon.UserInput.Image] = []
    var audios: [MLXLMCommon.UserInput.Audio] = []
    var spooled: [URL] = []
    for part in mediaParts {
        if let img = part.imageUrl, let image = makeImage(img.url) {
            images.append(image)
        }
        if let audio = part.audioURL {
            let result = makeAudio(audio.url)
            if let audioInput = result.audio {
                audios.append(audioInput)
            }
            if let spoolFile = result.spooledURL {
                spooled.append(spoolFile)
            }
        }
    }
    guard !images.isEmpty || !audios.isEmpty,
        let lastUser = messages.lastIndex(where: { $0.role == .user })
    else { return spooled }
    messages[lastUser].images.append(contentsOf: images)
    messages[lastUser].audios.append(contentsOf: audios)
    return spooled
}

// MARK: - MLX Media Decoders (free functions)

/// Convert a string that may be a data URL (`data:image/…;base64,…`) or a
/// regular URL into an ``MLXLMCommon/UserInput/Image``.
/// Data URLs are decoded to `CIImage`; remote/local URLs are passed through.
/// Free function — does not capture `EnginePool` self (avoids Sendable taint in
/// the inference body); independently testable (b4).
func makeMLXImage(from urlString: String) -> MLXLMCommon.UserInput.Image? {
    // Handle data: URIs (camera/screen snapshots come as base64 data URLs)
    if urlString.hasPrefix("data:") {
        // Use the LAST comma — base64 payload or URL-encoded data may contain commas
        if let lastComma = urlString.lastIndex(of: ",") {
            let base64Data = String(urlString[urlString.index(after: lastComma)...])
            guard let data = Data(base64Encoded: base64Data) else { return nil }
            // Decode via CGImageSource with auto-orient so EXIF orientation
            // is baked into pixel data before CIImage consumes it (CIImage
            // ignores EXIF orientation, causing rotated output.  Aligns with
            // mlx-swift-examples ChatView.swift L105-128.)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let cgImage = CGImageSourceCreateImageAtIndex(
                    source,
                    0,
                    ["ShouldAutoOrient": true] as CFDictionary
                )
            else { return nil }
            return .ciImage(CIImage(cgImage: cgImage))
        }

        return nil
    }

    // Fallback: regular URL (http, file, etc.)
    if let url = URL(string: urlString) {
        return .url(url)
    }

    return nil
}

/// Convert a string that may be a data URL (`data:audio/…;base64,…`) or a
/// regular URL into an ``MLXLMCommon/UserInput/Audio``.
/// Data URLs are written to the media spool as `.caf`; remote/local URLs are passed
/// through unchanged.
///
/// Free function — returns `(audio, spooledURL)`. The spool URL is *not* a temp file:
/// the conversation transcript cites it, and upstream re-reads that transcript on every
/// later turn, so deleting it at request end poisoned the session (measured 10-16, see
/// ``MediaSpool``). The caller hands it to the session pool, which owns its lifetime.
func makeMLXAudio(from urlString: String) -> (
    audio: MLXLMCommon.UserInput.Audio?, spooledURL: URL?
) {
    // Handle data: URIs (recordings come as base64 data URLs)
    if urlString.hasPrefix("data:") {
        // Use the LAST comma — base64 payload may contain commas
        guard let lastComma = urlString.lastIndex(of: ",") else { return (nil, nil) }
        let base64Data = String(urlString[urlString.index(after: lastComma)...])
        guard let data = Data(base64Encoded: base64Data) else { return (nil, nil) }
        // AVAssetReader needs a real file; the spool keeps it alive as long as any
        // session cites it. A failed write means the model will not hear this payload,
        // so it is reported as no-audio rather than handed over as a dead path.
        guard let spoolURL = MediaSpool.spool(data, fileExtension: "caf") else {
            return (nil, nil)
        }
        return (.url(spoolURL), spoolURL)
    }

    // Fallback: regular URL (http, file, etc.) — no temp file created
    if let url = URL(string: urlString) {
        return (.url(url), nil)
    }

    return (nil, nil)
}

/// Convert a string that may be a data URL (`data:video/…;base64,…`) or a
/// regular URL into an ``MLXLMCommon/UserInput/Video``.
/// Data URLs are written to the media spool as `.mp4` (AVAsset cannot read a data:
/// URL); remote/local URLs are passed through unchanged.
/// Mirror of ``makeMLXAudio(from:)`` — same data-URI contract, same
/// `(input, spooledURL)` shape, and the same lifetime rule: the spool file belongs to
/// the conversation, not to this request.
///
/// Why this exists: before this, the extraction at L1704-1708 did
/// `URL(string: videoUrl)` → `.url(dataURL)` directly. Upstream
/// `MediaProcessing.asProcessedSequence` wraps it in `AVAsset(url:)`, which
/// cannot decode a data: URL — the video is silently dropped (zero video
/// tokens; the model answers boilerplate as if no video is present). Decoding
/// to a real file makes the bytes reachable by AVFoundation — the same fix the audio
/// path already had. Deleting that file when the request ended was the *next* defect in
/// this same seam: the transcript outlived the bytes, and every later turn of the
/// conversation failed to read it (measured 10-16; ``MediaSpool`` is the fix).
func makeMLXVideo(from urlString: String) -> (
    video: MLXLMCommon.UserInput.Video?, spooledURL: URL?
) {
    if urlString.hasPrefix("data:") {
        guard let lastComma = urlString.lastIndex(of: ",") else { return (nil, nil) }
        let base64Data = String(urlString[urlString.index(after: lastComma)...])
        guard let data = Data(base64Encoded: base64Data) else { return (nil, nil) }
        guard let spoolURL = MediaSpool.spool(data, fileExtension: "mp4") else {
            return (nil, nil)
        }
        return (.url(spoolURL), spoolURL)
    }

    if let url = URL(string: urlString) {
        return (.url(url), nil)
    }

    return (nil, nil)
}
