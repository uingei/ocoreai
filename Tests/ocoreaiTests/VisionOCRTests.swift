// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// VisionOCR + DocumentOCR — 纯逻辑测试(全离线, 注入闭包, 不触 OCR 引擎)。
///
/// 覆盖:
///   DocumentOCR.render  — 标题/段落/表格/列表 顺序、trim、去重、兜底、多文档(精确形态)
///   VisionOCR.selectFinal — minCharacters 阈值裁决
///   VisionOCR.run       — 26 代优先 → 空回 legacy → 低于阈值不进 legacy(帧仍走图片通道)
import Foundation
import Testing

@testable import ocoreai

// MARK: - DocumentOCR.render — 精确形态

@Suite("DocumentOCR.render — structure → text (pure)")
struct DocumentOCRRenderTests {

    @Test
    func titleParagraphsTableListInOrder() {
        let d = OCRDocument(
            title: "  Title  ",
            paragraphs: ["  para one  ", "para two"],
            tableRows: [["a", "b"], ["", "  "], ["c"]],
            listItems: [
                OCRDocument.ListItem(marker: "x", text: "body"),
                OCRDocument.ListItem(marker: "  ", text: "no visible marker"),
            ],
            fallbackText: "SHOULD NOT APPEAR"
        )
        #expect(
            DocumentOCR.render([d])
                == "Title\npara one\npara two\na\tb\nc\nx body\nno visible marker")
    }

    @Test
    func fallbackUsedOnlyWhenTitleAndParagraphsEmpty() {
        let d = OCRDocument(fallbackText: "  only text  ")
        #expect(DocumentOCR.render([d]) == "only text")
    }

    @Test
    func fallbackIgnoredWhenTitlePresent() {
        let d = OCRDocument(title: "T", fallbackText: "hidden")
        #expect(DocumentOCR.render([d]) == "T")
    }

    @Test
    func titleDuplicatingFirstParagraphIsDeduped() {
        let d = OCRDocument(title: "Same", paragraphs: ["Same", "other"])
        #expect(DocumentOCR.render([d]) == "Same\nother")
    }

    @Test
    func whitespaceOnlyBlocksAreDropped() {
        let d = OCRDocument(
            title: "   ",
            paragraphs: ["   "],
            tableRows: [["  ", ""]],
            listItems: [OCRDocument.ListItem(marker: "m", text: "   ")]
        )
        #expect(DocumentOCR.render([d]) == "")
    }

    @Test
    func tableCellsAreTrimmed() {
        let d = OCRDocument(tableRows: [["  a  ", " b "]])
        #expect(DocumentOCR.render([d]) == "a\tb")
    }

    @Test
    func emptyDocsProducedNothing() {
        let d1 = OCRDocument(title: "Doc One")
        let d2 = OCRDocument()
        let d3 = OCRDocument(fallbackText: "Doc Three")
        #expect(DocumentOCR.render([d1, d2, d3]) == "Doc One\nDoc Three")
        #expect(DocumentOCR.render([]) == "")
    }
}

// MARK: - VisionOCR.selectFinal — 阈值裁决

@Suite("VisionOCR.selectFinal — threshold gate (pure)")
struct VisionOCRSelectFinalTests {

    @MainActor @Test
    func nilCandidateIsNil() {
        #expect(VisionOCR.selectFinal(nil) == nil)
    }

    @MainActor @Test
    func exactlyTenCharsPasses() {
        let ten = String(repeating: "a", count: 10)
        #expect(VisionOCR.selectFinal(ten) == ten)
    }

    @MainActor @Test
    func nineCharsFallsBackToImageChannel() {
        #expect(VisionOCR.selectFinal(String(repeating: "a", count: 9)) == nil)
    }

    @MainActor @Test
    func whitespaceOnlyIsBelowThreshold() {
        #expect(VisionOCR.selectFinal(String(repeating: " ", count: 10)) == nil)
    }

    @MainActor @Test
    func paddedCandidateIsTrimmedForGate() {
        let padded = " " + String(repeating: "a", count: 10) + "  "
        #expect(VisionOCR.selectFinal(padded) == padded)
    }
}

// MARK: - VisionOCR.run — 26 代优先 / legacy 兜底(注入闭包)

@Suite("VisionOCR.run — tiered engine seam (injected)")
struct VisionOCRRunTests {

    @MainActor @Test
    func gen26ResultWinsWhenNonTrivial() async {
        let out = await VisionOCR.run(
            from: Data(),
            recog: { _ in "26 engine text" },
            legacy: { _ in "legacy text" }
        )
        #expect(out == "26 engine text")
    }

    @MainActor @Test
    func legacyUsedWhenNoGen26Engine() async {
        let out = await VisionOCR.run(
            from: Data(),
            recog: nil,
            legacy: { _ in "legacy engine text" }
        )
        #expect(out == "legacy engine text")
    }

    @MainActor @Test
    func emptyGen26ResultFallsBackToLegacy() async {
        let out = await VisionOCR.run(
            from: Data(),
            recog: { _ in "" },
            legacy: { _ in "legacy text" }
        )
        #expect(out == "legacy text")
    }

    /// 契约: 26 代有结果但低于阈值 → 帧仍走图片通道(nil),
    /// 不空跑第二遍 legacy(与 HEAD 单引擎「<minCharacters → nil」同一语义)。
    @MainActor @Test
    func subThresholdGen26ResultDoesNotReRunLegacy() async {
        let sawLegacy = RefBox(false)
        let out = await VisionOCR.run(
            from: Data(),
            recog: { _ in "short" },
            legacy: { _ in
                sawLegacy.value = true
                return "legacy text"
            }
        )
        #expect(out == nil)
        #expect(sawLegacy.value == false)
    }

    @MainActor @Test
    func bothEnginesEmptyIsNil() async {
        let out = await VisionOCR.run(
            from: Data(),
            recog: { _ in nil },
            legacy: { _ in nil }
        )
        #expect(out == nil)
    }
}
