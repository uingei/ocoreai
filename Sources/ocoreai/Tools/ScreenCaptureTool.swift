import CoreGraphics
// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `view_screen` — agent-side "see the current screen" tool (视觉感知轴的可触面).
///
/// Positioning (empirically bounded, not self-declared):
/// - ocoreai already owns the screen pipeline — `ScreenshotService`
///   (ScreenCaptureKit one-shot, macOS) and `VisionOCR` (Vision text
///   recognition, macOS/iOS) — and `PerceptionEngine` already consumes both on
///   the *passive/UI* side. This tool is the *agent-callable* half: the same
///   verified capture + OCR path, wired into the tool surface the model dispatches.
/// - The MLX tool channel is text-only (same binding as `view_image` /
///   `web_fetch`): a tool result cannot ship pixels to a VLM. So the value
///   is the screen's **textual state** (Vision OCR) plus true WxH geometry —
///   the same ~97% token-saving image→text bridge PerceptionEngine relies on,
///   delivered where the model can actually reach it.
/// - Baseline axis: Apple-native (ScreenCaptureKit + Vision). `view_image`'s
///   codex-baseline shape (pre-flight half, verified facts, honest errors) is
///   the form precedent; codex itself ships no screen tool (16-commit diff
///   audited), so no benchmark fork is introduced.
import Foundation

#if canImport(ImageIO)
import ImageIO
#endif

// MARK: - Request

enum ScreenCapture {
    /// OCR text length bounds — clamped to a bounded, honest token budget.
    static let defaultMaxOCRChars = 4000
    static let minMaxOCRChars = 200
    static let maxMaxOCRChars = 8000

    /// Normalized capture request. Pure — unit-testable, no I/O.
    struct Built: Equatable {
        let includeOCR: Bool
        let maxOCRChars: Int
    }

    /// Build + clamp a capture request.
    ///
    /// - `max_ocr_chars`: `nil` → default 4000; `0` → disabled (OCR off);
    ///   `>0` → clamped into `[200, 8000]`.
    static func build(includeOCR: Bool, maxOCRChars: Int?) -> Built {
        var ocr = includeOCR
        var cap = defaultMaxOCRChars
        if let raw = maxOCRChars {
            if raw <= 0 {
                ocr = false
            } else {
                cap = min(max(raw, minMaxOCRChars), maxMaxOCRChars)
            }
        }
        return Built(includeOCR: ocr, maxOCRChars: cap)
    }
}

// MARK: - Capture backend seam (offline-testable)

/// Capture seam — the one real I/O boundary. Platform impl wraps
/// `ScreenshotService`; tests inject a fake without touching the OS.
protocol ScreenCaptureBackend: Sendable {
    func captureScreen() async -> String?
}

/// Real capture via `ScreenshotService` (macOS: ScreenCaptureKit one-shot;
/// iOS: unimplemented → `nil` → honest `error:` text, never a silent pass).
struct PlatformScreenCapture: ScreenCaptureBackend, @unchecked Sendable {
    nonisolated func captureScreen() async -> String? {
        await ScreenshotService.shared.captureScreen()
    }
}

// MARK: - Pure decode / parse / report

enum ScreenCapturePure {

    /// `data:image/jpeg;base64,<b64>` → JPEG bytes; anything else → nil.
    static func jpegData(fromDataURL url: String) -> Data? {
        guard url.hasPrefix("data:image/jpeg;base64,") else { return nil }
        let b64 = String(url.dropFirst("data:image/jpeg;base64,".count))
        return Data(base64Encoded: b64)
    }

    /// Decode JPEG bytes → true pixel WxH (0,0 if not a decodable image).
    static func pixelSize(_ data: Data) -> (width: Int, height: Int) {
        #if canImport(ImageIO)
        guard
            let src = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Double,
            let h = props[kCGImagePropertyPixelHeight] as? Double
        else { return (0, 0) }
        return (Int(w), Int(h))
        #else
        _ = data
        return (0, 0)
        #endif
    }

    /// Vision-OCR output → the bounded text block we put in the report.
    /// Trims and clamps to `maxChars`; `maxChars <= 0` or blank → empty.
    static func trimmedOCRText(_ raw: String?, maxChars: Int) -> String {
        guard maxChars > 0, let raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let capped = trimmed.prefix(maxChars)
        return String(capped) + (trimmed.count > maxChars ? "…" : "")
    }

    /// Exact two-line report (testable shape):
    /// ```
    /// view_screen OK — 1512x982px jpeg
    /// text=…OCR…            (or `text= (no significant on-screen text; attach a screenshot in chat for pixels)`)
    /// ```
    static func report(
        width: Int, height: Int, jpegBytes: Int, ocrText: String, ocrAvailable: Bool
    ) -> String {
        guard width > 0, height > 0 else {
            return "view_screen: error: capture returned no decodable image"
        }
        let line1 = "view_screen OK — \(width)x\(height)px jpeg (\(jpegBytes) bytes)"
        if ocrAvailable && !ocrText.isEmpty {
            return line1 + "\ntext=" + ocrText
        }
        if ocrAvailable {
            return line1
                + "\ntext= (no significant on-screen text; attach a screenshot in chat for pixels)"
        }
        return line1
    }
}

// MARK: - Client (seam + args binding)

enum ScreenCaptureClient {

    static let toolName = "view_screen"

    static func toolEntry(
        backend: ScreenCaptureBackend = PlatformScreenCapture()
    ) -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "screen",
            argsType: Args.self,
            description:
                "See the current screen: capture it and return its true size plus the on-screen text (OCR). "
                + "Use to inspect the current UI state, an error message, or what an app is showing before acting.",
            schema: ToolSchema(parameters: [
                "include_ocr": ToolParameter(
                    type: .boolean, description: "Run OCR to extract on-screen text (default true)."
                ),
                "max_ocr_chars": ToolParameter(
                    type: .integer,
                    description:
                        "Cap on OCR text length (default 4000; 0 = OCR off; clamped 200...8000)."),
            ])
        ) { args in
            await runForTool(
                includeOCR: args.include_ocr, maxOCRChars: args.max_ocr_chars, backend: backend)
        }
    }

    /// Typed tool args.
    struct Args: Codable, Sendable {
        let include_ocr: Bool?
        let max_ocr_chars: Int?
    }

    static func runForTool(
        includeOCR: Bool?, maxOCRChars: Int?,
        backend: ScreenCaptureBackend = PlatformScreenCapture()
    ) async -> String {
        let built = ScreenCapture.build(includeOCR: includeOCR ?? true, maxOCRChars: maxOCRChars)
        guard let url = await backend.captureScreen() else {
            return
                "view_screen: error: screen capture unavailable (no screen access / unsupported platform)"
        }
        guard let jpeg = ScreenCapturePure.jpegData(fromDataURL: url) else {
            return "view_screen: error: capture returned a non-JPEG payload"
        }
        let (w, h) = ScreenCapturePure.pixelSize(jpeg)
        let ocrAvailable = built.includeOCR
        let rawOCR: String? = ocrAvailable ? await VisionOCR.extractText(from: jpeg) : nil
        let text = ScreenCapturePure.trimmedOCRText(rawOCR, maxChars: built.maxOCRChars)
        return ScreenCapturePure.report(
            width: w, height: h, jpegBytes: jpeg.count, ocrText: text, ocrAvailable: ocrAvailable)
    }
}
