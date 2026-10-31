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

    /// Read the knob and say the decision once, at boot: a substitution this
    /// invisible is only honest if the startup log states what it did.
    static func bootstrap(logger: Logger) -> CORSMiddleware<OCoreAIContext>? {
        switch resolve(ProcessInfo.processInfo.environment["OCOREAI_CORS_ORIGIN"]) {
        case .off:
            return nil
        case .rejected(let value, let remedy):
            let why =
                "OCOREAI_CORS_ORIGIN=\"\(value)\" is not usable — \(remedy). "
                + "CORS stays off: cross-origin browser requests stay blocked, native clients are unaffected."
            logger.error("\(why)")
            return nil
        case .on(let allow):
            let decision =
                "CORS on — Access-Control-Allow-Origin: \(describe(allow)). "
                + "Preflight is answered before the API-key gate, which a preflight cannot carry."
            logger.info("\(decision)")
            return middleware(for: allow)
        }
    }

    static func middleware(for allow: Allow) -> CORSMiddleware<OCoreAIContext> {
        // Every method this router actually registers: PATCH/DELETE are live routes
        // (ChatCompletionsRouter.swift:793, :816, :827, :944), HEAD is generated from
        // GET, and OPTIONS is the preflight itself. A method missing here is a route
        // a browser cannot reach even though `curl` reaches it.
        // `api-key` is a credential this server reads (AuthMiddleware.swift:278) and
        // advertises as a security scheme in openapi.json — a preflight that omits it
        // blocks the exact client that advertisement promised.
        let allowHeaders: [HTTPField.Name] =
            [.accept, .authorization, .contentType, .origin]
            + ["api-key"].compactMap { HTTPField.Name($0) }
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
