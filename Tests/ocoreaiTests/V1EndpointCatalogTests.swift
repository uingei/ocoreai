// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// V1EndpointCatalogTests.swift — the published endpoint index must be the
/// router, not a snapshot of it.
///
/// `NotFoundEnvelopeMiddleware` tells every client that hits a 404 to enumerate
/// endpoints via `GET /v1/capabilities`. Until now that sentence had no delivery
/// seam: the payload carried capability rows only. These tests make the promise
/// checked instead of asserted — and check the checker, because a route scan that
/// stopped matching would otherwise make "catalog == routes" pass vacuously
/// (CONTRIBUTING → "The three questions": the gate asserts its own premises).

import Foundation
import Testing

@testable import ocoreai

@Suite("GET /v1/capabilities — endpoint index vs the router")
struct V1EndpointCatalogTests {

    /// `METHOD /path`, the identity of a route.
    private static func key(_ method: String, _ path: String) -> String {
        "\(method.uppercased()) \(path)"
    }

    /// Source of the only file that registers routes.
    ///
    /// Resolves the repo root by walking up until the router is found, rather than by a
    /// fixed number of `deletingLastPathComponent()` hops: a hardcoded hop count broke the
    /// day these tests first actually executed (2 deletions landed on `Tests/`, so every
    /// scan-based assertion threw ENOENT and the suite "failed" without scanning
    /// anything). Finding the file is its own proof of the root.
    private static func routerSource() throws -> String {
        let relative = "Sources/ocoreai/Router/ChatCompletionsRouter.swift"
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 6 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw MissingRepoFile(path: "\(dir.path)/\(relative)")
    }

    /// Distinct error type so a discovery failure never masquerades as a scan failure.
    struct MissingRepoFile: Error, CustomStringConvertible {
        let path: String
        var description: String { "no repo file at \(path) (walked up from \(#filePath))" }
    }

    /// Every `routes.<method>("<path>")` in `buildRouter`, read from source.
    private static func registeredRoutes() throws -> [String] {
        let source = try routerSource()
        let regex = try NSRegularExpression(
            pattern: #"routes\.(get|post|patch|put|delete)\("([^"]+)"\)"#)
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges == 3,
                let method = Range(match.range(at: 1), in: source),
                let path = Range(match.range(at: 2), in: source)
            else { return nil }
            return key(String(source[method]), String(source[path]))
        }
    }

    private static func catalogKeys() -> [String] {
        V1EndpointCatalog.routes.map { key($0.method, $0.path) }
    }

    @Test("the scan itself works: it finds the routes it must find")
    func scanIsAlive() throws {
        let found = try Self.registeredRoutes()
        // Floor: if the pattern or the file ever stops matching, equality below
        // would compare an empty set to an empty set and call it green.
        #expect(found.count >= 30, "route scan found only \(found.count) registrations")
        for must in [
            "GET /health", "GET /v1/models", "POST /v1/chat/completions",
            "POST /v1/count-tokens", "POST /v1/messages/count_tokens",
        ] {
            #expect(found.contains(must), "scan missed \(must) — regex or file layout changed")
        }
    }

    @Test("catalog == registered routes (nothing published that is not wired)")
    func catalogMatchesRouter() throws {
        let found = Set(try Self.registeredRoutes())
        let published = Set(Self.catalogKeys())
        #expect(
            published.subtracting(found) == [], "catalog lists routes the router does not register")
        #expect(
            found.subtracting(published) == [], "router registers routes the index does not publish"
        )
    }

    @Test("catalog is unique and every line says what it is for")
    func catalogIsWellFormed() {
        let keys = Self.catalogKeys()
        #expect(Set(keys).count == keys.count, "duplicate method+path in the index")
        #expect(V1EndpointCatalog.lines.count == V1EndpointCatalog.routes.count)
        for route in V1EndpointCatalog.routes {
            #expect(!route.path.hasSuffix("/"), "trailing slash in \(route.path)")
            #expect(!route.note.isEmpty, "\(route.method) \(route.path) has an empty note")
        }
    }

    @Test("auth column comes from the middleware's own policy")
    func authColumnIsDerived() {
        #expect(V1EndpointCatalog.auth(method: "GET", path: "/health") == "public")
        #expect(V1EndpointCatalog.auth(method: "GET", path: "/v1/capabilities") == "public")
        #expect(V1EndpointCatalog.auth(method: "POST", path: "/v1/count-tokens") == "key")
        #expect(V1EndpointCatalog.auth(method: "POST", path: "/v1/messages/count_tokens") == "key")
        #expect(
            V1EndpointCatalog.auth(method: "PATCH", path: "/v1/models/:model/sampling") == "admin")
        #expect(V1EndpointCatalog.auth(method: "DELETE", path: "/sessions/:id") == "admin")
    }

    @Test("every path the middleware treats as public is in the index")
    func publicSurfaceIsIndexed() {
        let publishedGET = Set(
            V1EndpointCatalog.routes.filter { $0.method == "GET" }.map(\.path))
        for path in AuthRoutePolicy.publicPaths {
            #expect(publishedGET.contains(path), "\(path) is public but missing from the index")
        }
    }

    @Test("the 404 hint's promise is actually wired into the payload")
    func capabilitiesPayloadPublishesTheIndex() throws {
        let source = try Self.routerSource()
        #expect(
            source.contains("endpoints: V1EndpointCatalog.lines"),
            "GET /v1/capabilities no longer publishes `endpoints` — the 404 hint is a lie again")
    }

    // ── auth is one home ─────────────────────────────────────────────────────
    // Measured 10-20: four places stated which routes are public — `AuthRoutePolicy
    // .publicPaths` (the set `AuthMiddleware` consults), `/v1/capabilities` (derived, the
    // only correct copy), README.md/README.zh.md (hand-copied), and this router's own header
    // comment. The header was wrong: it named 5 of the 7 public paths and asserted "All
    // other endpoints require valid API key", false for `/v1/tools` and
    // `/v1/capabilities`; and a docstring on `/v1/perception` called that route "public"
    // while the enforced set never contained it. `authColumnIsDerived` cannot catch any of
    // it — it proves the column is derived, not that the set is the documented one.

    @Test("the public set is exactly the documented discovery surface")
    func publicSetIsTheDocumentedSurface() {
        // Pinning membership (not just derivation): adding a path to publicPaths widens the
        // unauthenticated surface, and dropping one breaks clients that were told to expect
        // it open. Either way this must be a deliberate edit, in the same change as the
        // README rows that publish it.
        let documented: Set<String> = [
            "/health", "/ready", "/metrics", "/v1/models", "/v1/tools", "/v1/capabilities",
            "/v1/stats",
        ]
        #expect(
            AuthRoutePolicy.publicPaths == documented,
            """
            publicPaths changed shape — re-rule this pin and both READMEs' public-route lines
            in the same change; this set is the unauthenticated surface clients rely on.
            """)
    }

    @Test("the perception gauge is keyed, as the READMEs now state")
    func perceptionGaugeIsKeyed() {
        #expect(
            V1EndpointCatalog.auth(method: "GET", path: "/v1/perception") == "key",
            """
            /v1/perception changed auth status: the router docstring, both READMEs and this pin
            must be re-ruled together — widening auth is an owner decision, not a doc fix.
            """)
    }

    @Test("no auth-scope comment re-lists the public paths")
    func authScopeIsNotCopiedIntoTheRouter() throws {
        let source = try Self.routerSource()
        let mentions = source.split(separator: "\n").filter { $0.contains("AuthMiddleware") }
        // Floor: prove this scan still has something to look at.
        #expect(!mentions.isEmpty, "no AuthMiddleware mention left in the router — scan rotted")
        let literal = try NSRegularExpression(
            pattern: #"(get|post|patch|delete) /"#, options: [.caseInsensitive])
        for line in mentions {
            let lineString = String(line)
            let hits = literal.matches(
                in: lineString, range: NSRange(lineString.startIndex..., in: lineString)
            ).count
            #expect(
                hits < 2,
                """
                auth-scope comment enumerates \(hits) routes instead of pointing at
                AuthRoutePolicy.publicPaths — a second copy of auth drifts, and this one did
                """)
        }
    }
}
