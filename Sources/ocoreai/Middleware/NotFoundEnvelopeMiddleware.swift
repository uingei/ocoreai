// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// NotFoundMiddleware — every unmatched request answers with the standard
/// JSON error envelope.
///
/// First-principles: honesty is the product floor, and a machine-readable
/// error body is its lowest layer. Hummingbird's default ``NotFoundResponder``
/// throws `HTTPError(.notFound)` with a NIL body (HTTPError.swift:56 returns
/// a bare `Response(status:)` when body == nil) — the only endpoint class in
/// this service whose 404 body was empty. A client receiving `404 len=0`
/// cannot distinguish "route does not exist" from "reverse proxy died"; the
/// OpenAI wire contract answers every error with `{"error":…}`.
///
/// The hook is structural, not a route-table patch: the router composes the
/// notFound responder THROUGH the middleware chain
/// (`Router.swift:70` — `middlewares.constructResponder(finalResponder:
/// NotFoundResponder())`), so a middleware registered before any route sees
/// unmatched paths too, exactly like the AppError pass-through that gives
/// rate-limit 429 its envelope. One choke, zero route pollution.
///
/// Registered FIRST in buildRouter (before auth/rate-limit and every route)
/// so the whole surface is covered. Matched routes are fully transparent —
/// errors thrown INSIDE a handler still take the AppError path (this layer
/// cannot observe handler throws; it only observes the responder-chain miss).
///
/// Deliberately NOT a 405 + Allow translation: the router exposes no
/// "path matched, method mismatched" signal, and fabricating one from a
/// route scan would invent a second source of routing truth — a worse lie
/// than a well-formed 404 that names the method and path.

import Foundation
import Hummingbird
import NIOCore

/// 404 with the standard flat error envelope (same shape as `AppError`).
struct RouteNotFoundError: Error, HTTPResponseError {
    let method: String
    let path: String

    var status: HTTPResponse.Status { .notFound }

    nonisolated func response(
        from request: Request,
        context: some RequestContext
    ) throws -> Response {
        // Flat envelope, identical keys to AppError.response: message/type/
        // code. `details` names the exact miss so clients can log/repair
        // without re-deriving the request shape; the message points at the
        // canonical discovery routes ("what should I have called" is part of
        // an honest 404).
        let detail: [String: Any] = [
            "message": "Route \(method) \(path) does not exist. "
                + "Enumerate models via GET /v1/models and endpoints via GET /v1/capabilities.",
            "type": "app_error",
            "code": 404,
            "error_code": "route_not_found",
            "details": ["method": method, "path": path],
        ]
        let body =
            (try? JSONSerialization.data(withJSONObject: ["error": detail]))
            ?? Data("{}".utf8)
        return Response(
            status: .notFound,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: body))
        )
    }
}

/// Emits ``RouteNotFoundError`` for every request the trie misses.
///
/// Registered FIRST (before auth/rate-limit and every route): HB composes
/// the notFound responder THROUGH the middleware chain (`Router.swift:70`),
/// so `next()` here bottoms out at `NotFoundResponder`, whose
/// `HTTPError(.notFound)` (nil body) is caught and rethrown as the flat
/// envelope. Matched-route handlers throw ``AppError`` (a distinct type)
/// which passes through untouched — verified by the boundary test.
struct NotFoundEnvelopeMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as HTTPError where error.status == .notFound {
            throw RouteNotFoundError(
                method: request.method.rawValue, path: request.uri.path)
        }
    }
}
