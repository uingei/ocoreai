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
///   - `GuidedGenerationError.swift:27` — "Downstream code should catch this case
///     to emit partial results if needed."
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
/// Returns temp audio file URLs the caller must clean up after inference.
/// Chat.Message is a Sendable struct with `var images`/`var audios`, so
/// post-map mutation of the last user message is safe.
func attachPerceptionMedia(
    _ messages: inout [Chat.Message],
    mediaParts: [ContentPart],
    makeImage: (String) -> MLXLMCommon.UserInput.Image?,
    makeAudio: (String) -> (audio: MLXLMCommon.UserInput.Audio?, tempURL: URL?)
) -> [URL] {
    var images: [MLXLMCommon.UserInput.Image] = []
    var audios: [MLXLMCommon.UserInput.Audio] = []
    var tempURLs: [URL] = []
    for part in mediaParts {
        if let img = part.imageUrl, let image = makeImage(img.url) {
            images.append(image)
        }
        if let audio = part.audioURL {
            let result = makeAudio(audio.url)
            if let audioInput = result.audio {
                audios.append(audioInput)
            }
            if let tempFile = result.tempURL {
                tempURLs.append(tempFile)
            }
        }
    }
    guard !images.isEmpty || !audios.isEmpty,
        let lastUser = messages.lastIndex(where: { $0.role == .user })
    else { return tempURLs }
    messages[lastUser].images.append(contentsOf: images)
    messages[lastUser].audios.append(contentsOf: audios)
    return tempURLs
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
/// Data URLs are decoded to a temp `.caf` file; remote/local URLs are passed through.
/// Free function — returns (audio, tempURL) so callers can clean up the temp file
/// after inference. Independently testable (b4).
func makeMLXAudio(from urlString: String) -> (
    audio: MLXLMCommon.UserInput.Audio?, tempURL: URL?
) {
    // Handle data: URIs (recordings come as base64 data URLs)
    if urlString.hasPrefix("data:") {
        // Use the LAST comma — base64 payload may contain commas
        guard let lastComma = urlString.lastIndex(of: ",") else { return (nil, nil) }
        let base64Data = String(urlString[urlString.index(after: lastComma)...])
        guard let data = Data(base64Encoded: base64Data) else { return (nil, nil) }
        // Write to temp file so AVAssetReader can decode it
        let tmpName = "ocoreai_audio_\(UUID().uuidString.prefix(8)).caf"
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(tmpName)
        do {
            try data.write(to: tmpURL)
            return (.url(tmpURL), tmpURL)
        } catch {
            return (nil, nil)
        }
    }

    // Fallback: regular URL (http, file, etc.) — no temp file created
    if let url = URL(string: urlString) {
        return (.url(url), nil)
    }

    return (nil, nil)
}

/// Convert a string that may be a data URL (`data:video/…;base64,…`) or a
/// regular URL into an ``MLXLMCommon/UserInput/Video``.
/// Data URLs are decoded to a temp `.mp4` file (AVAsset cannot read data:
/// URLs); remote/local URLs are passed through unchanged.
/// Mirror of ``makeMLXAudio(from:)`` — same data-URI contract, same (input,
/// tempURL) shape so callers reuse the same temp-cleanup path (L1635-1638).
///
/// Why this exists: before this, the extraction at L1704-1708 did
/// `URL(string: videoUrl)` → `.url(dataURL)` directly. Upstream
/// `MediaProcessing.asProcessedSequence` wraps it in `AVAsset(url:)`, which
/// cannot decode a data: URL — the video is silently dropped (zero video
/// tokens; the model answers boilerplate as if no video is present). Decoding
/// to a real temp file makes the
/// bytes reachable by AVFoundation — the same fix the audio path already had.
func makeMLXVideo(from urlString: String) -> (
    video: MLXLMCommon.UserInput.Video?, tempURL: URL?
) {
    if urlString.hasPrefix("data:") {
        guard let lastComma = urlString.lastIndex(of: ",") else { return (nil, nil) }
        let base64Data = String(urlString[urlString.index(after: lastComma)...])
        guard let data = Data(base64Encoded: base64Data) else { return (nil, nil) }
        let tmpName = "ocoreai_video_\(UUID().uuidString.prefix(8)).mp4"
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(tmpName)
        do {
            try data.write(to: tmpURL)
            return (.url(tmpURL), tmpURL)
        } catch {
            return (nil, nil)
        }
    }

    if let url = URL(string: urlString) {
        return (.url(url), nil)
    }

    return (nil, nil)
}
