// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `view_screen` 工具 — 精确值测试(全离线, fake backend, 不触 OS 截屏).
///
/// 覆盖三类 seam:
///   1. `ScreenCapture.build`     — OCR on/off、maxOCRChars clamp(200...8000)、0=off。
///   2. `ScreenCapturePure`       — dataURL→JPEG 解码、pixelSize、OCR trim+cap、报告精确形态。
///   3. `ScreenCaptureClient.runForTool` — fake backend: 成功(有/无 OCR)、
///      后端失败→error 文本、非 JPEG 载荷→error 文本。

import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import ocoreai

/// 文件级假 backend — parser/client 测试复用(离线, 不发真实截屏).
struct FakeScreenBackend: ScreenCaptureBackend {
    let dataURL: String?
    nonisolated func captureScreen() async -> String? { dataURL }
}

@Suite("view_screen request construction")
struct ScreenCaptureRequestTests {

    @Test
    func defaultOCRIsOnWithDefaultCap() throws {
        let b = ScreenCapture.build(includeOCR: true, maxOCRChars: nil)
        #expect(b.includeOCR == true)
        #expect(b.maxOCRChars == 4000)
    }

    @Test
    func zeroCapTurnsOCRoff() throws {
        let b = ScreenCapture.build(includeOCR: true, maxOCRChars: 0)
        #expect(b.includeOCR == false)
    }

    @Test
    func negativeCapTurnsOCRoff() throws {
        let b = ScreenCapture.build(includeOCR: true, maxOCRChars: -5)
        #expect(b.includeOCR == false)
    }

    @Test
    func clampsBelowMinTo200() throws {
        let b = ScreenCapture.build(includeOCR: true, maxOCRChars: 1)
        #expect(b.includeOCR == true)
        #expect(b.maxOCRChars == 200)
    }

    @Test
    func clampsAboveMaxTo8000() throws {
        let b = ScreenCapture.build(includeOCR: true, maxOCRChars: 100_000)
        #expect(b.includeOCR == true)
        #expect(b.maxOCRChars == 8000)
    }

    @Test
    func preservesInRangeValue() throws {
        let b = ScreenCapture.build(includeOCR: true, maxOCRChars: 1234)
        #expect(b.maxOCRChars == 1234)
    }

    @Test
    func explicitOCRoffRespected() throws {
        let b = ScreenCapture.build(includeOCR: false, maxOCRChars: 5000)
        #expect(b.includeOCR == false)
        #expect(b.maxOCRChars == 5000)
    }
}

@Suite("view_screen pure decode/parse/report")
struct ScreenCapturePureTests {

    /// 6x4 RGB JPEG, 真像素 6x4 — 构造于测试内, 离线可用.
    /// 注意: JPEG 重采样可能微调尺寸, 故断言用 >= 且 >0, 形态精确断言在 report 层。
    private func makeTinyJPEG() -> Data {
        let w = 6
        let h = 4
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 200, count: w * h * 4)
        let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else {
            fatalError("test: failed to build CGImage")
        }
        let rep = NSBitmapImageRep(cgImage: img)
        return rep.representation(using: .jpeg, properties: [:])!
    }

    @Test
    func jpegDataFromDataURLRoundTrips() {
        let data = makeTinyJPEG()
        let url = "data:image/jpeg;base64,\(data.base64EncodedString())"
        #expect(ScreenCapturePure.jpegData(fromDataURL: url) == data)
    }

    @Test
    func jpegDataRejectsNonJPEGDataURL() {
        #expect(ScreenCapturePure.jpegData(fromDataURL: "data:text/plain;base64,aGk=") == nil)
        #expect(ScreenCapturePure.jpegData(fromDataURL: "https://x.com/a.jpg") == nil)
        #expect(ScreenCapturePure.jpegData(fromDataURL: "") == nil)
    }

    @Test
    func pixelSizeOfTinyJPEGIsPositiveAndBounded() {
        let (w, h) = ScreenCapturePure.pixelSize(makeTinyJPEG())
        #expect(w > 0, "width must be positive, got \(w)")
        #expect(h > 0, "height must be positive, got \(h)")
        #expect(w <= 8, "unexpected upscale: \(w)")
        #expect(h <= 6, "unexpected upscale: \(h)")
    }

    @Test
    func pixelSizeOfGarbageIsZero() {
        let (w, h) = ScreenCapturePure.pixelSize(Data("not-an-image".utf8))
        #expect(w == 0)
        #expect(h == 0)
    }

    @Test
    func trimmedOCRTrimsAndCapsExact() {
        let raw = "  hi   " + String(repeating: "a", count: 500)
        let out = ScreenCapturePure.trimmedOCRText(raw, maxChars: 100)
        // exact shape: 100 chars of content + one trailing ellipsis (101 chars total)
        #expect(out.count == 101)
        #expect(out.hasSuffix("…"))
        // trim 只去首尾: "hi" 后 3 个空格是内部的,保留 → 前缀 "hi   a"
        #expect(out.hasPrefix("hi   a"))
    }

    @Test
    func trimmedOCRBlankBecomesEmpty() {
        #expect(ScreenCapturePure.trimmedOCRText("   \n\t ", maxChars: 100) == "")
    }

    @Test
    func trimmedOCRNilBecomesEmpty() {
        #expect(ScreenCapturePure.trimmedOCRText(nil, maxChars: 100) == "")
    }

    @Test
    func trimmedOCRZeroCapBecomesEmpty() {
        #expect(ScreenCapturePure.trimmedOCRText("hello", maxChars: 0) == "")
    }

    @Test
    func reportWithOCRIsExactTwoLines() {
        let r = ScreenCapturePure.report(
            width: 1512, height: 982, jpegBytes: 123456,
            ocrText: "Press ⌘N to start", ocrAvailable: true)
        #expect(r == "view_screen OK — 1512x982px jpeg (123456 bytes)\ntext=Press ⌘N to start")
    }

    @Test
    func reportNoOCRTextHasHonestNote() {
        let r = ScreenCapturePure.report(
            width: 1512, height: 982, jpegBytes: 1, ocrText: "", ocrAvailable: true)
        #expect(
            r
                == "view_screen OK — 1512x982px jpeg (1 bytes)\ntext= (no significant on-screen text; attach a screenshot in chat for pixels)"
        )
    }

    @Test
    func reportOCRoffIsSingleLine() {
        let r = ScreenCapturePure.report(
            width: 2, height: 3, jpegBytes: 9, ocrText: "ignored", ocrAvailable: false)
        #expect(r == "view_screen OK — 2x3px jpeg (9 bytes)")
    }

    @Test
    func reportUndecodableImageIsErrorText() {
        let r = ScreenCapturePure.report(
            width: 0, height: 0, jpegBytes: 1, ocrText: "", ocrAvailable: true)
        #expect(r == "view_screen: error: capture returned no decodable image")
    }
}

@Suite("view_screen client contract (fake backend)")
struct ScreenCaptureClientTests {

    /// 最小可解码 JPEG dataURL(离线自构造).
    private func tinyJPEGDataURL() -> String {
        let w = 4
        let h = 4
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 128, count: w * h * 4)
        let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let img = ctx.makeImage()!
        let rep = NSBitmapImageRep(cgImage: img)
        return
            "data:image/jpeg;base64,\(rep.representation(using: .jpeg, properties: [:])!.base64EncodedString())"
    }

    @Test
    func successReturnsOKReportWithSize() async {
        let url = tinyJPEGDataURL()
        let out = await ScreenCaptureClient.runForTool(
            includeOCR: false, maxOCRChars: nil,
            backend: FakeScreenBackend(dataURL: url))
        #expect(out.hasPrefix("view_screen OK — "))
        #expect(out.contains("px jpeg ("))
        #expect(!out.contains("error:"))
    }

    @Test
    func backendFailureYieldsErrorText() async {
        let out = await ScreenCaptureClient.runForTool(
            includeOCR: true, maxOCRChars: nil,
            backend: FakeScreenBackend(dataURL: nil))
        #expect(
            out
                == "view_screen: error: screen capture unavailable (no screen access / unsupported platform)"
        )
    }

    @Test
    func nonJPEGPayloadYieldsErrorText() async {
        let out = await ScreenCaptureClient.runForTool(
            includeOCR: true, maxOCRChars: nil,
            backend: FakeScreenBackend(dataURL: "data:text/plain;base64,aGk="))
        #expect(out == "view_screen: error: capture returned a non-JPEG payload")
    }
}
