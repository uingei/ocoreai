// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Vision OCR processor — on-device text recognition.
///
/// Tiered engines(均为 Apple 原生,不本地解析版面):
///
///   26 代 (macOS 26 / iOS 26+): `RecognizeDocumentsRequest`
///        — 结构化文档识别(标题 / 段落 / 表格行×列 / 带 marker 列表)。
///        由 `DocumentOCR` 消费。
///   基线 (macOS 10.15 / iOS 13+, 部署 floor): `VNRecognizeTextRequest`
///        — 扁平文本观察;floor 代引擎,兼作 26 路无结果时的兜底。
///
/// 双路都 ANE 加速。帧内文本 ≥ minCharacters → 返回结构化文本(省 ~97% token),
/// 否则 nil(走图片通道)。
///
/// `run(from:recog:legacy:)` + `selectFinal(_:)` 为纯函数(无 OS I/O)——
/// 用注入的识别器闭包单测「26 代优先 → legacy 兜底 → 阈值裁决」行为。
/// 基线解码走 ImageIO(`CGImageSourceCreateWithData`)——与 HEAD 提交一致,
/// 不依赖 `CGImage(data:)` 扩展。

import CoreGraphics
import Foundation
import Vision

/// 基线代识别器(macOS 10.15 / iOS 13)—— 26 代兜底 + OS < 26 的引擎。
/// 解码 + 平文提取,逻辑与 HEAD 提交逐行一致(已实证可编译)。
struct LegacyOCR {
    static let minCharacters = 10

    static func recognize(from data: Data) -> String? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, nil)
        else {
            return nil
        }
        let request = VNRecognizeTextRequest()
        request.automaticallyDetectsLanguage = true
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let observations = request.results else { return nil }
        var lines: [String] = []
        for observation in observations {
            if let text = observation.topCandidates(1).first?.string,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                lines.append(text)
            }
        }
        let fullText = lines.joined(separator: "\n")
        return fullText.count >= minCharacters ? fullText : nil
    }
}

/// On-device Vision OCR — ANE-accelerated text recognition.
@MainActor
struct VisionOCR {
    /// Minimum number of recognized characters to consider the OCR result
    /// "significant" — frames below this threshold still go as images to VLM.
    static let minCharacters = 10

    /// 默认引擎:OS ≥ 26 时 26 代文档路优先,否则基线代(recog = nil)。
    static func extractText(from data: Data) async -> String? {
        let recog: ((Data) async -> String?)?
        if #available(macOS 26.0, iOS 26.0, *) {
            recog = { d in await DocumentOCR.recognize(from: d) }
        } else {
            recog = nil
        }
        let legacy: (Data) async -> String? = { d in LegacyOCR.recognize(from: d) }
        return await run(from: data, recog: recog, legacy: legacy)
    }

    /// 纯接缝(无 OS 依赖):26 代候选 → 空则 legacy 候选 → 阈值裁决。
    static func run(
        from data: Data,
        recog: ((Data) async -> String?)?,
        legacy: ((Data) async -> String?)
    ) async -> String? {
        if let recog {
            let doc26 = await recog(data)
            if let doc26, !doc26.isEmpty {
                return selectFinal(doc26)
            }
        }
        return selectFinal(await legacy(data))
    }

    // MARK: - Pure decision (unit-testable, no I/O)

    /// 纯裁决:候选过 `minCharacters` 阈值才用;否则 nil(帧仍走图片通道)。
    static func selectFinal(_ candidates: String?) -> String? {
        guard let candidate = candidates,
            candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                .count >= minCharacters
        else { return nil }
        return candidate
    }
}
