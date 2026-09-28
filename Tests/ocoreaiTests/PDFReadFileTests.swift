// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PDFReadFileTests.swift — `read_file` PDF text-layer branch.
///
/// Closes the "开箱即用" gap: `read_file` previously rejected every PDF as
/// "not a text file" (PDF is not a NUL-byte UTF-8 file). Now it extracts the
/// text layer via PDFKit (system framework, no third-party dep) and returns the
/// same numbered `N|line` window as plain files; a scanned/image-only PDF (no
/// text layer) returns an honest, actionable error instead of a fabricated empty.
///
/// Fixtures are inlined as base64 so the suite is self-contained (CI-safe,
/// no external file). Both are hand-rolled valid single-page PDFs; only `real`
/// has a text-layer content stream.
import Foundation
import Logging
import Testing

@testable import ocoreai

@Suite("read_file — PDF text-layer branch")
struct PDFReadFileTests {
    // Single page whose content stream is `BT /F1 24 Tf 72 720 Td (…) Tj ET`.
    private static let realText = "Hello ocoreai PDF text layer 12345"
    private static let realB64 =
        "JVBERi0xLjQKJeLjz9MKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvUmVzb3VyY2VzIDw8IC9Gb250IDw8IC9GMSA0IDAgUiA+PiA+PiAvQ29udGVudHMgNSAwIFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL1R5cGUgL0ZvbnQgL1N1YnR5cGUgL1R5cGUxIC9CYXNlRm9udCAvSGVsdmV0aWNhID4+CmVuZG9iago1IDAgb2JqCjw8IC9MZW5ndGggNjUgPj4Kc3RyZWFtCkJUIC9GMSAyNCBUZiA3MiA3MjAgVGQgKEhlbGxvIG9jb3JlYWkgUERGIHRleHQgbGF5ZXIgMTIzNDUpIFRqIEVUCmVuZHN0cmVhbQplbmRvYmoKeHJlZgowIDYKMDAwMDAwMDAwMCA2NTUzNSBmIAowMDAwMDAwMDE1IDAwMDAwIG4gCjAwMDAwMDAwNjQgMDAwMDAgbiAKMDAwMDAwMDEyMSAwMDAwMCBuIAowMDAwMDAwMjQ3IDAwMDAwIG4gCjAwMDAwMDAzMTcgMDAwMDAgbiAKdHJhaWxlcgo8PCAvU2l6ZSA2IC9Sb290IDEgMCBSID4+CnN0YXJ0eHJlZgo0MzIKJSVFT0YK"
    // Single page, empty content stream, no font → no extractable text.
    private static let notextB64 =
        "JVBERi0xLjQKJeLjz9MKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvQ29udGVudHMgNCAwIFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCAwID4+CnN0cmVhbQoKZW5kc3RyZWFtCmVuZG9iagp4cmVmCjAgNQowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMTUgMDAwMDAgbiAKMDAwMDAwMDA2NCAwMDAwMCBuIAowMDAwMDAwMTIxIDAwMDAwIG4gCjAwMDAwMDAyMDggMDAwMDAgbiAKdHJhaWxlcgo8PCAvU2l6ZSA1IC9Sb290IDEgMCBSID4+CnN0YXJ0eHJlZgoyNTcKJSVFT0YK"

    private var workdir: URL = URL(fileURLWithPath: "pdf_test_\(UUID().uuidString)")

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        workdir = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
    }

    private func seedPDFs() throws {
        guard let real = Data(base64Encoded: type(of: self).realB64) else {
            throw ToolError.invalidParameter("test fixture 'real.pdf' failed to decode")
        }
        guard let notext = Data(base64Encoded: type(of: self).notextB64) else {
            throw ToolError.invalidParameter("test fixture 'notext.pdf' failed to decode")
        }
        // Sanity: both must decode to a real PDF header.
        #expect(String(decoding: real.prefix(4), as: UTF8.self) == "%PDF")
        #expect(String(decoding: notext.prefix(4), as: UTF8.self) == "%PDF")
        try real.write(to: workdir.appendingPathComponent("real.pdf"), options: .atomic)
        try notext.write(to: workdir.appendingPathComponent("notext.pdf"), options: .atomic)
    }

    @Test("read_file extracts the PDF text layer as numbered lines (happy path)")
    func pdfExtractHappy() throws {
        try seedPDFs()
        let out = try FileTools.read(path: workdir.appendingPathComponent("real.pdf").path)
        print("PDBG HAPPY:\n\(out)")
        // The exact text must surface, numbered, with the full footer.
        #expect(out.contains("1|Hello ocoreai PDF text layer 12345"))
        #expect(out.contains("total_lines: 1 (full)"))
        #expect(!out.contains("page 1 of"))
        #expect(!out.contains("no extractable text"))
    }

    @Test("read_file returns an honest error for a scanned/image-only PDF (no text layer)")
    func pdfNoTextLayerHonest() throws {
        try seedPDFs()
        let path = workdir.appendingPathComponent("notext.pdf").path
        // Must not be a success — and the error text must be an honest, actionable hint.
        let out = (try? FileTools.read(path: path))
        #expect(
            out == nil,
            "read_file on a no-text-layer PDF must throw, not return empty: \(out ?? "nil")")
        // Re-read the thrown error directly to assert the exact wording.
        let threw: ToolError? = {
            do {
                _ = try FileTools.read(path: path)
                return nil
            } catch let e as ToolError { return e } catch { return nil }
        }()
        #expect(threw != nil, "expected ToolError")
        if case ToolError.invalidParameter(let message)? = threw {
            print("PDBG NOTEXT-HONEST: \(message.prefix(140))")
            #expect(message.contains("no extractable text"))
            #expect(message.contains("view_image"))
        } else {
            Issue.record("expected .invalidParameter, got \(String(describing: threw))")
        }
    }

    @Test("search_files content mode finds a substring inside a PDF's text layer")
    func pdfSearchContent() throws {
        try seedPDFs()
        let hit = try FileTools.search(
            path: workdir.path, pattern: "ocoreai", target: "content")
        print("PDBG SEARCH-HIT: \(hit.prefix(120))")
        #expect(hit.contains("real.pdf"))
        // notext has no text → must NOT match, and total should be exactly 1.
        #expect(!hit.contains("notext.pdf"))
        #expect(hit.contains("total: 1"))
    }
}
