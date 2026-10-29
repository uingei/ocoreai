// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// OpenAPIContractTests.swift — the published OpenAPI contract must be the server, not a
/// description of it.
///
/// ### Why each test exists (the red it was sampled against)
/// `GET /openapi.json` is rendered from `V1EndpointCatalog`, and `V1EndpointCatalogTests` pins
/// that catalog to the router. So the *route set* is already honest. What is not derived is
/// everything else in the document — the committed `openapi.json`, the media types, the error
/// envelope, the path parameters — and each of those is a copy that can go stale the moment
/// someone edits the emit site and not the spec. These five tests are the gates for the four
/// ways a generated contract still lies, plus the one that checks the checker.
///
/// ### Whose action changes on red
/// A contributor who added or changed a route and did not run `make openapi`, and a contributor
/// who changed an error emit site so that a documented key is no longer the key a client sees.
/// Both are actions a reader takes: a client generating code from the file, and an SDK branching
/// on `error.type`.

import Foundation
import Testing

@testable import ocoreai

@Suite("GET /openapi.json — contract vs the code that serves it")
struct OpenAPIContractTests {

    // MARK: - Repo access (walk up until the file is found; see V1EndpointCatalogTests)

    private struct MissingRepoFile: Error, CustomStringConvertible {
        let path: String
        var description: String { "no repo file at \(path) (walked up from \(#filePath))" }
    }

    private static func repoRoot() throws -> URL {
        let probe = "Sources/ocoreai/Router/OpenAPIDocument.swift"
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(probe).path)
            {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw MissingRepoFile(path: "\(dir.path)/\(probe)")
    }

    private static func repoFile(_ relative: String) throws -> String {
        let url = try repoRoot().appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MissingRepoFile(path: url.path)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The committed artefact, exactly as a stranger who clones this repo reads it.
    private static func committedArtefact() throws -> String {
        try repoFile("openapi.json")
    }

    /// `info.version` is the running bundle's truth ("dev" for a bare SPM product, the release
    /// number inside a `.app`), so it is the one line that legitimately differs between the
    /// binary that generated the file and the test runner comparing against it. Everything else
    /// is byte-compared; blanking this is the only tolerance, and it is why the probe asserts
    /// the version against the same binary's own `--version` instead of against a constant.
    private static func blankVersion(_ text: String) throws -> String {
        let pattern = try NSRegularExpression(pattern: "\"version\": \"[^\"]*\"")
        return pattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: "\"version\": \"<bundle>\"")
    }

    private static func parse(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw MissingRepoFile(path: "document is not a JSON object")
        }
        return root
    }

    // MARK: - 1. The committed file is the render

    @Test("openapi.json in git is what the binary renders (minus the bundle version)")
    func committedArtefactIsTheRenderedDocument() throws {
        let onDisk = try Self.committedArtefact()
        let rendered = OpenAPIDocument.render()
        // Floor: a truncated or empty artefact would make any comparison below look plausible.
        #expect(onDisk.count > 10_000, "openapi.json is \(onDisk.count) bytes — regenerate")
        let onDiskBody = try Self.blankVersion(onDisk)
        let renderedBody = try Self.blankVersion(rendered)
        #expect(
            onDiskBody == renderedBody,
            """
            openapi.json in git is stale: the renderer and the committed artefact differ beyond \
            the version line. Run `make openapi` and commit openapi.json in the same change — a \
            generated file that nobody regenerates is documentation, not a contract.
            """)
    }

    // MARK: - 2. Every route the server answers is in the document

    @Test("the spec's paths+methods are exactly the registered route set")
    func specPathsAreTheRouteSet() throws {
        let paths = try Self.parse(OpenAPIDocument.render())["paths"] as? [String: Any]
        let specKeys = Set(
            paths?.flatMap { path, ops in
                (ops as? [String: Any])?
                    .filter { ["get", "post", "patch", "put", "delete"].contains($0.key) }
                    .map { "\($0.key.uppercased()) \(path)" } ?? []
            } ?? [])
        let catalogKeys = Set(
            V1EndpointCatalog.routes.map {
                "\($0.method.uppercased()) \(OpenAPIDocument.templatedPath($0.path))"
            })
        // Floor: an empty `paths` object would make both set differences empty and the test
        // would pass on a document that documents nothing.
        #expect(specKeys.count >= 30, "spec carries only \(specKeys.count) operations")
        #expect(
            specKeys == catalogKeys,
            """
            the contract and the catalog disagree; missing from spec: \(catalogKeys.subtracting(specKeys).sorted()), \
            extra in spec: \(specKeys.subtracting(catalogKeys).sorted())
            """)
    }

    // MARK: - 3. A templated path declares its parameters

    @Test("every {parameter} in a path is declared, with the %2F rule where it belongs")
    func templatedPathsDeclareTheirParameters() throws {
        let paths = try Self.parse(OpenAPIDocument.render())["paths"] as? [String: Any] ?? [:]
        let templated = paths.filter { $0.key.contains("{") }
        // Floor: this repo has four templated paths; zero here means the scan rotted, not that
        // the surface got simpler.
        #expect(
            templated.count >= 4, "only \(templated.count) templated paths — did routing change?")
        for (path, ops) in templated {
            let declared = Set(
                ((ops as? [String: Any])?["parameters"] as? [[String: Any]])?
                    .compactMap { $0["name"] as? String } ?? [])
            let wanted = Self.placeholders(in: path)
            #expect(
                wanted.isSubset(of: declared),
                "\(path) uses \(wanted.sorted()) but declares \(declared.sorted())")
            if wanted.contains("model") {
                let described =
                    ((ops as? [String: Any])?["parameters"] as? [[String: Any]])?
                    .first { $0["name"] as? String == "model" }?["description"] as? String ?? ""
                #expect(
                    described.contains("%2F"),
                    "\(path)'s `model` parameter stopped stating the encoding rule probe 03 measured"
                )
            }
        }
    }

    private static func placeholders(in path: String) -> Set<String> {
        Set(
            path.split(separator: "/").compactMap { segment in
                guard segment.hasPrefix("{"), segment.hasSuffix("}") else { return nil }
                return String(segment.dropFirst().dropLast())
            })
    }

    // MARK: - 4. The error envelope is the envelope

    @Test("the documented required keys are the keys both emit sites always write")
    func errorEnvelopeRequiredMatchesEmitSites() throws {
        let appError = try Self.repoFile("Sources/ocoreai/Models/OpenAIModels.swift")
        let notFound = try Self.repoFile(
            "Sources/ocoreai/Middleware/NotFoundEnvelopeMiddleware.swift")

        // The keys are read out of the literals the emit sites build, not typed in here: a
        // required key that stopped being emitted is a validator that rejects a real response.
        let emitted = ["message", "type", "code"]
        for key in emitted {
            #expect(
                appError.contains("\"\(key)\":"),
                "AppError.response no longer writes a literal `\(key)` — re-derive required[]")
            #expect(
                notFound.contains("\"\(key)\":"),
                "RouteNotFoundError no longer writes `\(key)` — the 404 envelope changed shape")
        }

        let schemas =
            try Self.parse(OpenAPIDocument.render())["components"]
            .flatMap { $0 as? [String: Any] }?["schemas"] as? [String: Any]
        let envelope = schemas?["ErrorEnvelope"] as? [String: Any]
        let error = (envelope?["properties"] as? [String: Any])?["error"] as? [String: Any]
        let required = (error?["required"] as? [Any])?.compactMap { $0 as? String } ?? []
        #expect(
            Set(required) == Set(emitted),
            "spec requires \(required.sorted()); the emit sites guarantee \(emitted.sorted())")

        // `type` is not one constant: the two SDK-named variants are what a client branches on,
        // so a spec that pins only "app_error" hides the values that matter.
        let typeSchema = (error?["properties"] as? [String: Any])?["type"] as? [String: Any]
        let types = (typeSchema?["enum"] as? [Any])?.compactMap { $0 as? String } ?? []
        for variant in ["app_error", "invalid_request_error", "rate_limit_error"] {
            #expect(
                appError.contains("\"\(variant)\""),
                "`\(variant)` is no longer a literal in the emit site — trim the spec's enum")
            #expect(types.contains(variant), "spec's error.type enum is missing \(variant)")
        }
    }

    // MARK: - 5. The document does not invent a deployment

    @Test("the document binds nothing: no host literal, no port, and it parses")
    func documentCarriesNoBindAssumption() throws {
        let text = OpenAPIDocument.render()
        let root = try Self.parse(text)
        #expect(root["openapi"] as? String == OpenAPIDocument.specVersion)
        // The bind truth lives in four `OCOREAI_PORT ?? "8080"` reads, none of which is a
        // constant the spec is allowed to re-type; `servers: ["/"]` is the only origin this
        // route can vouch for. A host or port appearing here is a fifth home for that number.
        for forbidden in ["127.0.0.1", "localhost", ":8080"] {
            #expect(!text.contains(forbidden), "spec hardcodes \(forbidden)")
        }
        let servers = root["servers"] as? [[String: Any]] ?? []
        #expect(servers.first?["url"] as? String == "/")
    }
}
