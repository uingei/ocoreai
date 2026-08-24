// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ViewImageToolTests — `view_image` (codex baseline) unit gate.
///
/// Coverage (exact-value assertions):
/// - real PNG → verified 12x8 px, mime/bytes/size echo, exact report shape
/// - `detail` vocabulary: `high` (default) / `original` / unknown → clamps to `high`
/// - rejects: data: URL, directory, non-image extension, text mis-tagged as .png,
///   empty file, missing file
/// - `~` expansion
/// - registration: `view_image` lands in the bootstrap registry
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ocoreai

// MARK: - fixture — writes a tiny real PNG to disk for the tool to inspect.

private func writeImageRGBA(width: Int, height: Int, at path: String) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard
        let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return nil }
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let cg = ctx.makeImage() else { return nil }
    guard
        let dst = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil
        )
    else { return nil }
    CGImageDestinationAddImage(dst, cg, nil)
    return CGImageDestinationFinalize(dst) ? cg : nil
}

private func makePNG(width: Int, height: Int, at path: String) {
    guard writeImageRGBA(width: width, height: height, at: path) != nil else {
        Issue.record("view_image test fixture could not write a PNG")
        return
    }
}

@Suite("ViewImage — pre-flight image inspection (exact values)")
struct ViewImageRunTests {

    private var tmpDir: String {
        NSTemporaryDirectory() + "ocoreai_viewimage_\(UUID().uuidString)"
    }

    @Test("real PNG → exact 12x8, bytes echo, report shape")
    func realPNG() {
        let dir = tmpDir
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = dir + "/shot.png"
        makePNG(width: 12, height: 8, at: p)
        guard FileManager.default.fileExists(atPath: p) else {
            Issue.record("fixture did not create the PNG")
            return
        }
        guard let r = try? ViewImage.run(path: p) else {
            #expect(Bool(false), "run() unexpectedly failed")
            return
        }
        let s = ViewImage.reportString(r)
        #expect(r.width == 12, "width must be exact: \(r.width)")
        #expect(r.height == 8, "height must be exact: \(r.height)")
        #expect(r.mime == "image/png")
        #expect(r.ext == "png")
        #expect(r.bytes > 0)
        #expect(r.expandedPath == p)
        #expect(s.hasPrefix("view_image OK — path=\(p) ext=png mime=image/png bytes=\(r.bytes) "))
        #expect(s.contains("12x8px detail=high"))
        #expect(s.contains("attach the file in the chat to inspect pixels"))
    }

    @Test("detail: original (echo); unknown → clamps to high")
    func detailVocabulary() {
        let dir = tmpDir
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = dir + "/d.png"
        makePNG(width: 4, height: 4, at: p)
        guard FileManager.default.fileExists(atPath: p) else {
            Issue.record("fixture did not create the PNG")
            return
        }
        #expect((try? ViewImage.run(path: p, detail: "original"))?.detail == "original")
        #expect((try? ViewImage.run(path: p, detail: "bogus"))?.detail == "high")
        #expect((try? ViewImage.run(path: p, detail: "High"))?.detail == "high")
        #expect((try? ViewImage.run(path: p))?.detail == "high")
    }

    private func expectError(_ path: String, _ caseCheck: (ViewImage.Error) -> Bool, _ what: String)
    {
        do {
            _ = try ViewImage.run(path: path)
            #expect(Bool(false), "expected an error: \(what)")
        } catch {
            guard let e = error as? ViewImage.Error else {
                #expect(Bool(false), "not a ViewImage.Error (got \(type(of: error))): \(what)")
                return
            }
            #expect(caseCheck(e), "wrong error case for \(what): \(e)")
        }
    }

    @Test("data: URL → readable error, not a crash")
    func dataURLRejected() {
        expectError(
            "data:image/png;base64,AAAA",
            {
                if case .unreadable(let why) = $0 { return why.contains("data:") }
                return false
            },
            "data: URL")
    }

    @Test("directory → notAFile")
    func directoryRejected() {
        let dir = tmpDir
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        expectError(
            dir,
            {
                if case .notAFile = $0 { return true }
                return false
            }, "directory")
    }

    @Test("unsupported extension (.txt) → unsupportedExtension")
    func badExtension() {
        let dir = tmpDir
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = dir + "/note.txt"
        try? "hello".write(toFile: p, atomically: true, encoding: .utf8)
        expectError(
            p,
            {
                if case .unsupportedExtension(let ext) = $0 { return ext == "txt" }
                return false
            },
            ".txt")
    }

    @Test("text masquerading as .png → notARealImage (ImageIO decode gate)")
    func misTaggedPayload() {
        let dir = tmpDir
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = dir + "/fake.png"
        try? "this is not a png at all".write(toFile: p, atomically: true, encoding: .utf8)
        expectError(
            p,
            {
                if case .notARealImage = $0 { return true }
                return false
            }, "text as .png")
    }

    @Test("empty file → unreadable(0 bytes)")
    func emptyFile() {
        let dir = tmpDir
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = dir + "/empty.png"
        FileManager.default.createFile(atPath: p, contents: Data())
        expectError(
            p,
            {
                if case .unreadable(let why) = $0 { return why.contains("0 bytes") }
                return false
            },
            "empty file")
    }

    @Test("missing file → notAFile")
    func missingFile() {
        expectError(
            "/no/such/image_\(UUID().uuidString).png",
            {
                if case .notAFile = $0 { return true }
                return false
            },
            "missing file")
    }

    @Test("~ expansion in path")
    func tildeExpansion() {
        let home = NSHomeDirectory()
        let sub = home + "/.ocoreai_vitmp_" + UUID().uuidString
        try? FileManager.default.createDirectory(
            atPath: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: sub) }
        let abs = sub + "/t.png"
        makePNG(width: 3, height: 2, at: abs)
        guard FileManager.default.fileExists(atPath: abs) else {
            Issue.record("fixture did not create the PNG")
            return
        }
        // `~<suffix>` form exercises NSString.expandingTildeInPath in ViewImage.run.
        let relative = "~" + sub.dropFirst(home.count) + "/t.png"
        guard let r = try? ViewImage.run(path: relative) else {
            #expect(Bool(false), "run() failed on ~ path")
            return
        }
        #expect(r.expandedPath == abs)
        #expect(r.width == 3)
        #expect(r.height == 2)
    }
}

@Suite("ViewImage — registration")
struct ViewImageRegistrationTests {

    @MainActor
    @Test("bootstrap registers view_image with path+detail schema")
    func registered() async {
        let registry = ToolRegistry()
        await bootstrapBuiltInTools(registry: registry)
        let entry = await registry.lookup("view_image")
        #expect(entry?.name == "view_image")
        let s = await registry.schema(for: "view_image")
        #expect(s?.parameters["path"] != nil)
        #expect(s?.parameters["detail"] != nil)
    }
}
