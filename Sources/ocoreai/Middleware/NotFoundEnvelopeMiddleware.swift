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
/// cannot distinguish "route does not exist" from "reverse proxy died"; both
/// wire contracts answer every error with their own envelope, chosen by the
/// path called (`AppError.response`), and this layer feeds that one home rather
/// than owning a second copy of the body.
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

/// Emits ``AppError/routeNotFound(method:path:)`` for every request the trie misses.
///
/// Registered FIRST (before auth/rate-limit and every route): HB composes
/// the notFound responder THROUGH the middleware chain (`Router.swift:70`),
/// so `next()` here bottoms out at `NotFoundResponder`, whose
/// `HTTPError(.notFound)` (nil body) is caught and rethrown as
/// ``AppError/routeNotFound(method:path:)``, which renders through the same
/// envelope builder every other refusal uses. A 404 thrown INSIDE a matched
/// handler (``AppError/modelNotFound(_:)``) is a different condition and keeps
/// its own typed body — verified by the boundary test.
struct NotFoundEnvelopeMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as HTTPError where error.status == .notFound {
            // Thrown, not rendered: the envelope is decided by `AppError.response` off the path
            // the request arrived on, so a miss under `/v1/messages` answers Anthropic's shape
            // like every other refusal there. This file used to build its own flat body, which
            // is how the same 404 said `app_error` while a handler-thrown 404 said
            // `not_found_error` — one fact, two spellings, in one process.
            throw AppError.routeNotFound(
                method: request.method.rawValue, path: request.uri.path)
        }
    }
}
