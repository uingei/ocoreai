// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! OpenAPIDocument.swift — the HTTP surface as an OpenAPI 3.1 contract, **rendered from
//! ``V1EndpointCatalog`` instead of written beside it**.
//!
//! Why it exists: the trees this repo studies publish a machine-readable contract — ollama ships
//! `docs/openapi.yaml`, and the harness trees ship generated clients — while our discovery story
//! was `/v1/capabilities` plus prose. Hand-writing a second description of the same routes is a
//! second home for one decision, and this repo's recurring failure is exactly that copy drifting.
//! So paths, methods, summaries and auth scope are *derived* from the catalog, whose own test
//! (`V1EndpointCatalogTests`) pins it to the router's registrations. What the catalog cannot say —
//! media types, the error envelope, the `%2F` rule for model ids — is stated once here and gated
//! against the code that serves it (`OpenAPIContractTests` + probe 42).
//!
//! Byte-stable by construction: keys keep insertion order, because a `JSONSerialization` dictionary
//! sorts them and a generated artefact that reshuffles on every run cannot be reviewed as a diff.

import Foundation

// MARK: - Ordered JSON

/// Minimal JSON writer whose object key order is the order written.
indirect enum JSONNode: Sendable {
    case string(String)
    case number(Int)
    case bool(Bool)
    case object([(String, JSONNode)])
    case array([JSONNode])

    func serialized(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .string(let s): return Self.quote(s)
        case .number(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n"
                + items.map { inner + $0.serialized(indent: indent + 1) }
                .joined(separator: ",\n") + "\n" + pad + "]"
        case .object(let pairs):
            guard !pairs.isEmpty else { return "{}" }
            return "{\n"
                + pairs.map {
                    inner + Self.quote($0.0) + ": "
                        + $0.1.serialized(indent: indent + 1)
                }
                .joined(separator: ",\n") + "\n" + pad + "}"
        }
    }

    /// Trailing newline included: the committed artefact ends with one, so `git diff` stays clean.
    func documentText() -> String { serialized() + "\n" }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "\""
    }
}

// MARK: - Document

enum OpenAPIDocument {
    /// OpenAPI version this document is written against.
    static let specVersion = "3.1.0"

    /// One-line purpose of each media type the server actually emits. `/metrics` is the reason
    /// this is not "everything is JSON": it answers Prometheus text exposition.
    static func mediaType(method: String, path: String) -> String {
        (method == "GET" && path == "/metrics") ? "text/plain; version=0.0.4" : "application/json"
    }

    /// The document body.
    ///
    /// `servers` is relative on purpose. The four `OCOREAI_PORT ?? "8080"` reads are the bind
    /// truth and none of them is a constant I am allowed to re-type — a fifth copy is exactly
    /// the second home this repo forbids, and a pinned 8080 would describe a deployment that
    /// may not exist. `url: "/"` means "the origin that served this document", which is the
    /// one server this route can actually vouch for.
    static var document: JSONNode {
        .object([
            ("openapi", .string(specVersion)),
            ("info", info),
            (
                "servers",
                .array([
                    .object([
                        ("url", .string("/")),
                        (
                            "description",
                            .string(
                                "The origin this document was served from. Read as a file instead of over "
                                    + "HTTP there is no origin: bind the host and port the process actually "
                                    + "uses (OCOREAI_HOST / OCOREAI_PORT, or the values the GUI shows)."
                            )
                        ),
                    ])
                ])
            ),
            // Nothing is required by default: an unauthenticated server accepts every route, and
            // the schemes below only bite when OCOREAI_API_KEYS is set (AuthMiddleware's own rule).
            ("security", .array([])),
            ("tags", tags),
            ("paths", paths),
            ("components", components),
        ])
    }

    static func render() -> String {
        document.documentText()
    }

    // MARK: Pieces

    private static var info: JSONNode {
        .object([
            ("title", .string("ocoreai")),
            ("version", .string(AppInfo.shortVersion)),
            (
                "license",
                .object([
                    ("name", .string("MIT")),
                    ("url", .string("https://opensource.org/licenses/MIT")),
                ])
            ),
            (
                "description",
                .string(
                    "Local-first HTTP surface for open models on Apple silicon. This document is "
                        + "generated from V1EndpointCatalog — the same index GET /v1/capabilities publishes "
                        + "as `endpoints[]`, pinned to the router's registrations by its own test. Request "
                        + "and response bodies are documented at the type level on purpose: the field-level "
                        + "contracts that matter to a caller live where they are enforced, as JSON Schemas "
                        + "on GET /v1/tools (tools[] for a turn) and in the capability rows on "
                        + "GET /v1/capabilities (what this process actually did, not what its SDK permits)."
                )
            ),
            ("x-generated-from", .string("Sources/ocoreai/Router/V1EndpointCatalog.swift")),
            ("x-regenerate", .string("make openapi")),
        ])
    }

    private static var tags: JSONNode {
        .array([
            .object([
                ("name", .string("v1")),
                (
                    "description",
                    .string(
                        "OpenAI-compatible chat, completions, embeddings, multimodal, model inventory"
                    )
                ),
            ]),
            .object([
                ("name", .string("discovery")),
                (
                    "description",
                    .string("Self-description: models, capabilities, tools, stats, this document")
                ),
            ]),
            .object([
                ("name", .string("operations")),
                ("description", .string("Liveness, readiness, metrics, sessions, skills, MCP")),
            ]),
        ])
    }

    static func tag(for path: String) -> String {
        switch path {
        case "/v1/models", "/v1/capabilities", "/v1/tools", "/v1/stats", "/openapi.json":
            return "discovery"
        case "/health", "/ready", "/metrics", "/sessions", "/skills", "/mcp",
            "/sessions/search":
            return "operations"
        default:
            return path.hasPrefix("/v1/") || path == "/v1" ? "v1" : "operations"
        }
    }

    /// `/sessions/:id` → `/sessions/{id}`, Hummingbird template to OpenAPI template.
    static func templatedPath(_ path: String) -> String {
        guard path.contains(":") else { return path }
        return "/"
            + path.split(separator: "/", omittingEmptySubsequences: true).map { seg in
                seg.first == ":" ? "{\(seg.dropFirst())}" : String(seg)
            }.joined(separator: "/")
    }

    static func operationId(method: String, path: String) -> String {
        let joined = path.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.first == ":" ? "by_\(dropColon($0))" : String($0) }
            .joined(separator: "_")
            .replacingOccurrences(of: "-", with: "_")
        let verb = method.lowercased()
        return joined.isEmpty ? verb : "\(verb)_\(joined)"
    }

    private static func dropColon(_ s: Substring) -> String {
        String(s.dropFirst()).replacingOccurrences(of: "-", with: "_")
    }

    private static var paths: JSONNode {
        var byPath: [(String, [(EndpointLine)])] = []
        for line in V1EndpointCatalog.lines {
            let key = templatedPath(line.path)
            if let idx = byPath.firstIndex(where: { $0.0 == key }) {
                byPath[idx].1.append(line)
            } else {
                byPath.append((key, [line]))
            }
        }
        return .object(
            byPath.map { path, lines -> (String, JSONNode) in
                // One path object: the parameters it declares, then one member per registered method.
                var members: [(String, JSONNode)] = [("parameters", pathParameters(path))]
                members += lines.map { ($0.method.lowercased(), operation($0)) }
                return (path, .object(members))
            })
    }

    /// Path parameters, declared once per path. `:model` carries the encoding rule a client
    /// cannot guess: ids published as `org/name` must arrive percent-encoded, measured live by
    /// probe 03 (verbatim → 404, `org%2Fname` → 200).
    private static func pathParameters(_ path: String) -> JSONNode {
        let names = path.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0.first == "{" }
            .map { String($0.dropFirst().dropLast()) }
        guard !names.isEmpty else { return .array([]) }
        return .array(
            names.map { name in
                .object([
                    ("name", .string(name)),
                    ("in", .string("path")),
                    ("required", .bool(true)),
                    ("schema", .object([("type", .string("string"))])),
                    (
                        "description",
                        .string(
                            name == "model"
                                ? "Model id exactly as GET /v1/models publishes it. One path segment: ids "
                                    + "shaped `org/name` must be percent-encoded (%2F) here — measured, "
                                    + "verbatim 404s, encoded 200s."
                                : "Path parameter as registered by the router."
                        )
                    ),
                ])
            })
    }

    private static func operation(_ line: EndpointLine) -> JSONNode {
        let media = mediaType(method: line.method, path: line.path)
        var pairs: [(String, JSONNode)] = [
            ("operationId", .string(operationId(method: line.method, path: line.path))),
            ("summary", .string(line.note)),
            ("tags", .array([.string(tag(for: line.path))])),
            ("security", security(line.auth)),
        ]
        if line.method == "POST" || line.method == "PATCH" {
            pairs.append(
                (
                    "requestBody",
                    .object([
                        ("required", .bool(true)),
                        (
                            "content",
                            .object([
                                (
                                    media,
                                    .object([
                                        (
                                            "schema",
                                            .object([
                                                ("type", .string("object")),
                                                ("additionalProperties", .bool(true)),
                                            ])
                                        )
                                    ])
                                )
                            ])
                        ),
                    ])
                ))
        }
        pairs.append(("responses", responses(media, auth: line.auth)))
        return .object(pairs)
    }

    /// Derived from the same ``AuthRoutePolicy`` sets the middleware enforces with.
    private static func security(_ auth: String) -> JSONNode {
        guard auth != "public" else { return .array([]) }
        return .array([
            .object([("bearerAuth", .object([]))]),
            .object([("apiKeyHeader", .object([]))]),
            .object([("apiKeyQuery", .object([]))]),
        ])
    }

    private static func responses(_ media: String, auth: String) -> JSONNode {
        var out: [(String, JSONNode)] = [
            (
                "200",
                .object([
                    ("description", .string("Success.")),
                    (
                        "content",
                        .object([
                            (
                                media,
                                .object([
                                    (
                                        "schema",
                                        .object([
                                            (
                                                "type",
                                                .string(
                                                    media.hasPrefix("text/") ? "string" : "object")
                                            ),
                                            ("additionalProperties", .bool(true)),
                                        ])
                                    )
                                ])
                            )
                        ])
                    ),
                ])
            )
        ]
        if auth != "public" {
            out.append(("401", .object([("$ref", .string("#/components/responses/AppError"))])))
        }
        if auth == "admin" {
            out.append(("403", .object([("$ref", .string("#/components/responses/AppError"))])))
        }
        out.append(("404", .object([("$ref", .string("#/components/responses/AppError"))])))
        return .object(out)
    }

    private static var components: JSONNode {
        .object([
            (
                "securitySchemes",
                .object([
                    (
                        "bearerAuth",
                        .object([
                            ("type", .string("http")),
                            ("scheme", .string("bearer")),
                            (
                                "description",
                                .string("Authorization: Bearer <key> — the primary route.")
                            ),
                        ])
                    ),
                    (
                        "apiKeyHeader",
                        .object([
                            ("type", .string("apiKey")),
                            ("in", .string("header")),
                            ("name", .string("api-key")),
                            ("description", .string("OpenAI-compatible fallback, checked second.")),
                        ])
                    ),
                    (
                        "apiKeyQuery",
                        .object([
                            ("type", .string("apiKey")),
                            ("in", .string("query")),
                            ("name", .string("api_key")),
                            ("description", .string("Debug convenience, checked last.")),
                        ])
                    ),
                ])
            ),
            (
                "responses",
                .object([
                    (
                        "AppError",
                        .object([
                            (
                                "description",
                                .string(
                                    "Envelope emitted by AppError.response and RouteNotFoundError: always "
                                        + "`message`, `type`, `code`, plus the typed keys the failure earns "
                                        + "(`error_code`, `remediation`, `param`, `value`, `details`, "
                                        + "`retry_after_seconds`, `post_tokens`/`cap`, `used_gb`/`budget_gb`)."
                                )
                            ),
                            (
                                "content",
                                .object([
                                    (
                                        "application/json",
                                        .object([
                                            (
                                                "schema",
                                                .object([
                                                    (
                                                        "$ref",
                                                        .string(
                                                            "#/components/schemas/ErrorEnvelope")
                                                    )
                                                ])
                                            )
                                        ])
                                    )
                                ])
                            ),
                        ])
                    )
                ])
            ),
            (
                "schemas",
                .object([
                    (
                        "ErrorEnvelope",
                        .object([
                            ("type", .string("object")),
                            ("required", .array([.string("error")])),
                            (
                                "properties",
                                .object([
                                    (
                                        "error",
                                        .object([
                                            ("type", .string("object")),
                                            (
                                                "required",
                                                .array([
                                                    .string("message"), .string("type"),
                                                    .string("code"),
                                                ])
                                            ),
                                            // Explicit, not left to the JSON Schema default: the typed keys
                                            // named in AppError's description are conditional, and a closed
                                            // object here would call the ones a client sees invalid.
                                            ("additionalProperties", .bool(true)),
                                            // `type` is not one constant: the emit site overwrites it with the
                                            // SDK-named variants for the two classes a client branches on, so
                                            // pinning "app_error" alone would hide the values that matter.
                                            (
                                                "properties",
                                                .object([
                                                    ("message", stringNode),
                                                    (
                                                        "type",
                                                        .object([
                                                            ("type", .string("string")),
                                                            (
                                                                "enum",
                                                                .array([
                                                                    .string("app_error"),
                                                                    .string(
                                                                        "invalid_request_error"),
                                                                    .string("rate_limit_error"),
                                                                ])
                                                            ),
                                                        ])
                                                    ),
                                                    (
                                                        "code",
                                                        .object([("type", .string("integer"))])
                                                    ),
                                                    ("error_code", stringNode),
                                                ])
                                            ),
                                        ])
                                    )
                                ])
                            ),
                        ])
                    )
                ])
            ),
        ])
    }

    /// `{"type":"string"}` as a node. A property value must be a schema; a bare word is the
    /// difference between a spec a generator accepts and one that fails at the first field.
    private static var stringNode: JSONNode {
        .object([("type", .string("string"))])
    }
}
