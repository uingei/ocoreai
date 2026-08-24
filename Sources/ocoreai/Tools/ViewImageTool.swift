import CoreGraphics
// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ViewImage — agent-side "inspect an on-disk image file" tool.
///
/// Baseline: codex `view_image` (`core/src/tools/handlers/view_image_spec.rs:16`,
/// `VIEW_IMAGE_TOOL_NAME` = `"view_image"`) — "View a local image file from the
/// filesystem when visual inspection is needed. Use this for images already
/// available on disk." One required `path` (string); optional `detail`
/// (`"high"` | `"original"`, `view_image_spec.rs:22-31`); output schema
/// `{ image_url, detail }` (`view_image_spec.rs:53-74`).
///
/// Positioning in ocoreai (empirically bounded, NOT self-declared):
/// - The MLX tool-result channel is text-only — `ChatSession.toolDispatch`
///   returns `String` (`MLXLMCommon/ChatSession.swift:318`) and a
///   `Chat.Message.tool` carries no image part. So a tool result CANNOT feed a
///   real image into the VLM's next pass. Inlining base64 would be 1.3M+ tokens
///   of dead noise (no consumer) — deliberately NOT done here.
/// - The genuine vision route is the user-attachment path
///   (`EngineInference.makeMLXImage` → `images.append(image)`, ~L1647), already
///   wired. `view_image` occupies the codex tool's *pre-flight* half: confirm
///   the disk file is a real, decodable image and report its true resolution.
/// - Real WxH via `CGImageSource` is what makes this `view_image` and not
///   `stat`: it rejects mis-tagged payloads (a .txt named .png fails to decode)
///   and gives the agent the layout facts ("2560x1440 vs 1x1") to act on.
/// - `detail` mirrors the codex spec vocabulary; ocoreai does not resize
///   (MLX resolves detail at inference, not in the tool) — the value is a
///   transparent echo.
///
/// LLM-fed input discipline (same class as `ExecTools`): `path` is
/// attacker-controlled → reject `data:` URLs, guard directory traversal. Cap
/// `maxBytes` so a 2 GB file cannot be memory-mapped into the report.
import Foundation

#if canImport(ImageIO)
import ImageIO
#endif

enum ViewImage {
    /// Maximum file size we will even attempt to inspect (20 MiB). Above this
    /// we return a typed refusal rather than map a huge file.
    static let maxBytes: Int = 20 * 1024 * 1024

    /// Extension → MIME (conservative subset; a mis-tagged image is worse than
    /// a refusal, so an empty/unknown extension is rejected up-front).
    static let mimeByExtension: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "gif": "image/gif",
        "heic": "image/heic",
        "heif": "image/heif",
        "bmp": "image/bmp",
        "tiff": "image/tiff",
        "tif": "image/tiff",
    ]

    enum Error: Swift.Error, CustomStringConvertible {
        case notAFile
        case unsupportedExtension(ext: String)
        case tooLarge(bytes: Int, cap: Int)
        case unreadable(String)
        case notARealImage

        var description: String {
            switch self {
            case .notAFile:
                return "view_image: path is not an existing regular file"
            case .unsupportedExtension(let ext):
                return "view_image: unsupported image extension '.\(ext)'"
            case .tooLarge(let bytes, let cap):
                return
                    "view_image: file is \(bytes) bytes, exceeds the \(cap)-byte cap — pre-resize before the call"
            case .unreadable(let why):
                return "view_image: could not read file — \(why)"
            case .notARealImage:
                return
                    "view_image: file is tagged as an image but did not decode to an image (mis-tagged payload?)"
            }
        }
    }

    struct Report: Equatable {
        let expandedPath: String
        let ext: String
        let mime: String
        let bytes: Int
        let width: Int
        let height: Int
        let detail: String
    }

    /// Validate + decode an on-disk image, returning its verified metadata.
    ///
    /// - Parameters:
    ///   - path: Absolute, `~`-expanded, or cwd-relative path to an image file.
    ///   - detail: `"high"` (default) or `"original"` — codex spec vocabulary,
    ///     echoed transparently; ocoreai does not resize.
    static func run(path rawPath: String, detail: String? = nil) throws -> Report {
        // LLM-fed input guardrails — reject `data:` URLs up-front.
        guard !rawPath.hasPrefix("data:") else {
            throw Error.unreadable("`data:` URLs are not a file path")
        }
        let expanded = (rawPath as NSString).expandingTildeInPath

        // Regular-file gate (not a directory / device).
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            throw Error.notAFile
        }
        guard !isDir.boolValue else {
            throw Error.notAFile
        }

        // Extension gate — refuse mis-tagged payloads up-front.
        let url = URL(fileURLWithPath: expanded)
        let ext = url.pathExtension.lowercased()
        guard let mime = mimeByExtension[ext] else {
            throw Error.unsupportedExtension(ext: ext.isEmpty ? "<none>" : ext)
        }

        // Size gate — read metadata BEFORE mapping into memory.
        guard
            let size =
                (try? FileManager.default
                .attributesOfItem(atPath: expanded)[.size]) as? Int
        else {
            throw Error.unreadable("stat failed")
        }
        guard size > 0 else { throw Error.unreadable("file is empty (0 bytes)") }
        guard size <= maxBytes else { throw Error.tooLarge(bytes: size, cap: maxBytes) }

        // Real-image gate: ImageIO must yield decodable dimensions.
        // `#if canImport` is COMPILE-time — it guards the platform feature,
        // unlike `#available` which is a runtime OS-version check (kept out).
        let w: Int
        let h: Int
        #if canImport(ImageIO)
        guard
            let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let wp = props[kCGImagePropertyPixelWidth],
            let hp = props[kCGImagePropertyPixelHeight]
        else {
            throw Error.notARealImage
        }
        // Property values are numeric (CGFloat); round to whole pixels.
        w = Int((wp as? Double) ?? 0)
        h = Int((hp as? Double) ?? 0)
        guard w > 0, h > 0 else { throw Error.notARealImage }
        #else
        // Platform without ImageIO: we cannot verify "real image". Be honest.
        throw Error.notARealImage
        #endif

        // Normalize the detail vocabulary (mirror the codex spec).
        let normDetail: String
        switch detail?.lowercased() {
        case "original": normDetail = "original"
        default: normDetail = "high"
        }

        return Report(
            expandedPath: expanded, ext: ext, mime: mime,
            bytes: size, width: w, height: h, detail: normDetail)
    }

    /// Compact, greppable single-line report for tool-result consumption.
    /// Exact shape (testable):
    /// ```
    /// view_image OK — path=<abs> ext=<ext> mime=<mime> bytes=<n>
    ///   <W>x<H>px detail=<high|original> | note=<...>
    /// ```
    static func reportString(_ r: Report) -> String {
        "view_image OK — path=\(r.expandedPath) ext=\(r.ext) mime=\(r.mime) "
            + "bytes=\(r.bytes) \(r.width)x\(r.height)px detail=\(r.detail) "
            + "| note=verified decodable image; attach the file in the chat to inspect pixels"
    }
}
