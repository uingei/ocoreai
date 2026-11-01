// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// CORSPolicy — the one home for the browser-origin decision on this server.
///
/// Until now a web page could not use this server at all: `fetch` hides a
/// cross-origin response from the page unless that response carries
/// `Access-Control-Allow-Origin`, so every curl/native verdict in this repo was true
/// while the same request from a browser failed with nothing but a console line.
/// The behaviour is upstream's — Hummingbird ships `CORSMiddleware`
/// (`Hummingbird/Middleware/CORSMiddleware.swift:174`: preflight short-circuit,
/// `Vary: Origin`, headers on the error path too) — so this file decides only
/// *whether* and *for whom*, and re-implements nothing.
///
/// Opt-in, because this is a loopback process that may hold no API key at all: an
/// allow-origin header is the one thing that lets an unrelated web page read this
/// user's inference. Unset (the default) registers no middleware, so the wire stays
/// byte-identical to before. `OCOREAI_CORS_ORIGIN` names one origin, or `*`.
///
/// Registered BEFORE `AuthMiddleware`: a preflight carries no `Authorization` — that
/// is what the preflight is *for* — so a chain that demands a key first answers 401
/// to the question the browser asks before it can send the answer.
///
/// Same knob shape as the comparators: ollama `OLLAMA_ORIGINS`, vllm
/// `--allow-origins`, sglang `--cors-allow-origins`.

import Foundation
import HTTPTypes
import Hummingbird
import Logging

enum CORSPolicy {
    /// Who may read a cross-origin response.
    enum Allow: Sendable, Equatable {
        /// Every origin: `Access-Control-Allow-Origin: *`.
        case anyOrigin
        /// Exactly this origin, echoed only to a request that asks from it.
        case origin(String)
    }

    /// What the knob resolved to, including the refusal — a knob that quietly
    /// ignored part of its own value is the defect this file ends, so an
    /// out-of-domain value comes back named instead of truncated.
    enum Decision: Sendable, Equatable {
        case off
        case on(Allow)
        case rejected(value: String, remedy: String)
    }

    /// Pure so the whole decision table is assertable without a server, and without
    /// setting a process-global variable a suite would then leak to its neighbours.
    static func resolve(_ raw: String?) -> Decision {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .off }
        if value.contains(",") {
            return .rejected(
                value: value,
                remedy: "it names more than one origin, and this knob carries one origin or *"
            )
        }
        return value == "*" ? .on(.anyOrigin) : .on(.origin(value))
    }

    /// Read the knob once at boot and hand back the DECISION, not only the middleware it
    /// implies. The same value must answer two questions about one request — who may READ
    /// a cross-origin reply, and whether a browser may WRITE at all (`AuthMiddleware`) —
    /// and a second read of the environment could answer them differently. A substitution
    /// this invisible is only honest if the startup log states what it did.
    static func bootstrap(logger: Logger) -> Decision {
        switch resolve(ProcessInfo.processInfo.environment["OCOREAI_CORS_ORIGIN"]) {
        case .off:
            return .off
        case .rejected(let value, let remedy):
            let why =
                "OCOREAI_CORS_ORIGIN=\"\(value)\" is not usable — \(remedy). "
                + "CORS stays off: cross-origin browser requests stay blocked, native clients are unaffected."
            logger.error("\(why)")
            return .rejected(value: value, remedy: remedy)
        case .on(let allow):
            let decision =
                "CORS on — Access-Control-Allow-Origin: \(describe(allow)). "
                + "Preflight is answered before the API-key gate, which a preflight cannot carry."
            logger.info("\(decision)")
            return .on(allow)
        }
    }

    static func middleware(for allow: Allow) -> CORSMiddleware<OCoreAIContext> {
        // Every method this router actually registers: PATCH/DELETE are live routes
        // (ChatCompletionsRouter.swift:793, :816, :827, :944), HEAD is generated from
        // GET, and OPTIONS is the preflight itself. A method missing here is a route
        // a browser cannot reach even though `curl` reaches it.
        // Every credential this server actually reads must survive the preflight, or the
        // preflight blocks the exact client the security scheme advertised: `api-key`
        // (`AuthMiddleware.extractAPIKey`) and `x-api-key`, the rung the Anthropic SDK
        // fills and the reason `/v1/messages` is reachable from that SDK at all.
        let allowHeaders: [HTTPField.Name] =
            [.accept, .authorization, .contentType, .origin]
            + ["api-key", "x-api-key"].compactMap { HTTPField.Name($0) }
        let allowOrigin: CORSMiddleware<OCoreAIContext>.AllowOriginExtended
        switch allow {
        case .anyOrigin: allowOrigin = .all
        case .origin(let name): allowOrigin = .oneOf(name)
        }
        return CORSMiddleware(
            allowOrigin: allowOrigin,
            allowHeaders: allowHeaders,
            allowMethods: [.get, .post, .patch, .delete, .head, .options],
            // No cookie and no client certificate is involved here: the credential on
            // this wire is a header the page sets itself, so `false` costs nothing.
            allowCredentials: false,
            // A JSON POST with a bearer token is always preflighted, so without a max
            // age every single completion turn pays an extra round trip first.
            maxAge: .seconds(600)
        )
    }

    private static func describe(_ allow: Allow) -> String {
        switch allow {
        case .anyOrigin: return "*"
        case .origin(let name): return name
        }
    }
}

extension CORSPolicy {

    /// Whether a browser could make this method mutate something. `GET`/`HEAD` answer
    /// the same either way and a browser cannot read a cross-origin reply we do not
    /// label, so only the writes need an origin decision; `OPTIONS` is the preflight,
    /// whose whole purpose is to arrive without a credential.
    static func mutates(_ method: HTTPRequest.Method) -> Bool {
        method != .get && method != .head && method != .options
    }

    /// Whether a request carrying `origin` may mutate this server.
    ///
    /// A browser puts `Origin` on every cross-origin write; a native client puts none —
    /// measured, not assumed: a `URLSession` POST on this host sent Host, Content-Type,
    /// Accept, UA, Content-Length and nothing named Origin. Nothing here serves a page
    /// (the only `WKWebView` in the tree is the outbound `web_fetch` tool), so an Origin
    /// on a write is some other page reaching this process, and CORS is not what stops
    /// it: a `text/plain` JSON-RPC POST is a *simple* request, so the browser sends it
    /// unpreflighted and only hides the reply. `POST /mcp` reaches `tools/call`, and by
    /// default no key is configured, so the mutation would land.
    ///
    /// The same rule is what the field shipped rather than what this file reasoned to:
    /// MCP's HTTP transport answers an invalid Origin with 403, codex refuses Origin
    /// outright on its local listeners (`app-server-transport/src/transport/websocket.rs:107`),
    /// and splash (same posture: loopback, key off by default, destructive tools) admits
    /// no origin at all until one is named — its `--allowed-origin` default is literally
    /// "No other origin" (`docs/server.md:85`, `OriginRefused` at `server/http_security.py:45`).
    ///
    /// Pure, so the whole table is assertable without a server and without setting an
    /// environment variable a suite would then leak to its neighbours.
    static func admitsMutation(origin: String?, against decision: Decision) -> Bool {
        guard let origin, !origin.isEmpty else { return true }
        switch decision {
        // A knob whose value was rejected behaves as if unset, exactly as `bootstrap`
        // registers no middleware for it: an unusable value never widens a door.
        case .off, .rejected:
            return false
        case .on(.anyOrigin):
            return true
        case .on(.origin(let admitted)):
            return origin == admitted
        }
    }
}

extension CORSPolicy.Decision {

    /// The middleware this decision registers. `nil` for both `.off` and `.rejected`, so
    /// an unusable knob never widens a door twice over: no allow-origin header, and no
    /// admitted browser write.
    var corsMiddleware: CORSMiddleware<OCoreAIContext>? {
        switch self {
        case .off, .rejected:
            return nil
        case .on(let allow):
            return CORSPolicy.middleware(for: allow)
        }
    }
}
