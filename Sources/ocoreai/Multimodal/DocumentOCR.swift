// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DocumentOCR — 结构化文档识别 (macOS 26 / iOS 26 代).
///
/// `RecognizeDocumentsRequest`(Vision.swiftinterface, 27.0 SDK 逐字:
/// `@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)`,
/// `typealias Result = [DocumentObservation]`,
/// `perform(on: Data)` async — ImageProcessingRequest L620)——
/// `VNRecognizeTextRequest`(10.15/13)的 26 代后继:返回**结构**
/// (标题 / 有序段落 / 表格行×列 / 带 marker 的列表),不是扁平观察列表。
/// 对以代码 / 文档 / 表格为输入的 coding agent,结构就是价值。
/// 消费 Apple 自带模型,不本地解析版面(不造轮子)。
///
/// 三层(接缝按可测性切):
///   `recognize(from:)`  OS 接缝 — 执行请求、结构→DTO
///   `document(from:)`   OS 接缝 — `DocumentObservation` → `OCRDocument`(无渲染逻辑)
///   `render(_:)`        纯函数  — `[OCRDocument]` → 结构化文本(可单测;
///                              SDK 的 `DocumentObservation` 无 public init,
///                              DTO 是唯一可构造的测试面)

import Foundation
import Vision

/// 结构化文档元素(DTO)— 一个 `DocumentObservation` 里渲染所需的最小投影。
/// 渲染器只依赖它,不依赖 Vision 类型 → 离线可测、平台无关(不受 26 门控)。
struct OCRDocument: Equatable, Sendable {
    struct ListItem: Equatable, Sendable {
        var marker: String
        var text: String
    }

    var title: String?
    var paragraphs: [String]
    var tableRows: [[String]]
    var listItems: [ListItem]
    var fallbackText: String

    init(
        title: String? = nil,
        paragraphs: [String] = [],
        tableRows: [[String]] = [],
        listItems: [ListItem] = [],
        fallbackText: String = ""
    ) {
        self.title = title
        self.paragraphs = paragraphs
        self.tableRows = tableRows
        self.listItems = listItems
        self.fallbackText = fallbackText
    }
}

enum DocumentOCR {

    /// 26 代文档识别:原始图片字节 → 结构化文本。
    /// 解码失败 / OS 错误 / 全空 → nil(调用方回落 legacy 层)。
    @available(macOS 26.0, iOS 26.0, *)
    static func recognize(from data: Data) async -> String? {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.maximumCandidateCount = 1
        do {
            let observations = try await request.perform(on: data)
            let docs = observations.map { Self.document(from: $0) }
            let text = Self.render(docs)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    /// OS 接缝:结构化观察 → DTO(纯提取,无渲染决策)。
    /// 分步 + 显式类型标注:三层嵌套闭包表达式会触发编译器类型检查溢出
    /// (ICE "failed to produce diagnostic"),拆开即消。
    @available(macOS 26.0, iOS 26.0, *)
    static func document(from observation: DocumentObservation) -> OCRDocument {
        let doc = observation.document
        let title: String? = doc.title?.transcript
        let paragraphs: [String] = doc.paragraphs.map { $0.transcript }
        let tableRows: [[String]] = doc.tables.flatMap { table in
            table.rows.map { row in
                row.map { cell in cell.content.text.transcript }
            }
        }
        let listItems: [OCRDocument.ListItem] = doc.lists.flatMap { list in
            list.items.map { item in
                OCRDocument.ListItem(marker: item.markerString, text: item.itemString)
            }
        }
        let fallbackText: String = doc.text.transcript
        return OCRDocument(
            title: title,
            paragraphs: paragraphs,
            tableRows: tableRows,
            listItems: listItems,
            fallbackText: fallbackText
        )
    }

    /// 纯渲染:DTO → 可读结构化文本(无 I/O, 可单测)。
    /// 文档间 `\n` 分隔;每文档内顺序与去重见 `renderOne`。
    static func render(_ documents: [OCRDocument]) -> String {
        documents.map { Self.renderOne($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 单文档内顺序:
    ///   标题 → 段落(原序)→ 表格(行优先, 单元格 tab 分隔; 全空行剔除)→ 列表(marker + 项)
    /// 标题/段落皆空 → 兜底 `fallbackText`(不丢整块文本)。
    /// 保序去空行去重(标题常同时是首个段落, 不念两遍);
    /// 不同文档的合法重复文本保留(只去重单文档内)。
    private static func renderOne(_ d: OCRDocument) -> String {
        var blocks: [String] = []
        if let title = d.title, !title.isBlank {
            blocks.append(title.trimmed())
        }
        for paragraph in d.paragraphs where !paragraph.isBlank {
            blocks.append(paragraph.trimmed())
        }
        if blocks.isEmpty, !d.fallbackText.isBlank {
            blocks.append(d.fallbackText.trimmed())
        }
        for row in d.tableRows {
            if !row.allSatisfy({ $0.trimmed().isEmpty }) {
                blocks.append(row.map { $0.trimmed() }.joined(separator: "\t"))
            }
        }
        for item in d.listItems where !item.text.isBlank {
            let body = item.text.trimmed()
            let marker = item.marker.trimmed()
            blocks.append(marker.isEmpty ? body : marker + " " + body)
        }
        return Self.deduped(blocks)
    }

    /// 保序去空行去重。
    private static func deduped(_ blocks: [String]) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for block in blocks where !block.isEmpty {
            if seen.insert(block).inserted {
                out.append(block)
            }
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Small string helpers(26 门控文件内私有, 不扩散公共面)

extension String {
    fileprivate var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    fileprivate func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
