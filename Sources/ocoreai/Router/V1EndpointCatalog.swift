// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// V1EndpointCatalog.swift — machine-readable index of the HTTP surface.
///
/// Why this exists: the 404 envelope has told clients for weeks to
/// "Enumerate models via GET /v1/models and endpoints via GET /v1/capabilities"
/// (`NotFoundEnvelopeMiddleware.swift:53`), while `CAPayload` published capability
/// rows and `tokenizerBackend` only — no endpoint index. A discovery promise with
/// nothing behind it is the same defect family this repo keeps hitting (an
/// accept-then-deliver contract whose delivery seam is missing), and it costs a
/// real client a real round trip: live 10-13 `POST /v1/messages/count_tokens`
/// answered 404 and the hint sent the client to an endpoint that could not
/// answer which paths DO exist.
///
/// ### Drift control
/// `V1EndpointCatalogTests` scans `ChatCompletionsRouter.swift` for every
/// `routes.<method>("<path>")` registration and asserts set equality with this
/// catalog, plus a floor on the scan's own hit count (a regex that stopped
/// matching would otherwise make the equality pass vacuously — the "a gate must
/// assert its own premises" rule from CONTRIBUTING → "The three questions").
/// Notes are prose and free to change; method+path pairs are the pinned contract.
///
/// ### `auth` is derived, never typed
/// The auth column comes from `AuthMiddleware`'s own public/admin sets, so this
/// file cannot claim a route is public while the middleware blocks it.
///
/// ### Notes carry what a client cannot guess
/// `GET /v1/models` publishes HuggingFace-style ids (`org/name`), while `:model` matches
/// exactly ONE path segment — so the id a client is handed cannot be pasted verbatim into
/// `/v1/models/:model/…`. Measured live on 10-14
/// (`scripts/probes/03-capabilities-models-consistency.sh`): verbatim `org/name` → 404,
/// `org%2Fname` → 200, bare `name` → 404. The route is reachable, but only through an
/// encoding the client has no way to discover, so the requirement is stated in the note the
/// client is already reading. Probe 03 fails if that sentence ever leaves the notes while
/// verbatim ids still 404 — the workaround stops being folklore.

import Foundation

// MARK: - Wire line

/// One entry of `GET /v1/capabilities` → `endpoints: [...]`.
struct EndpointLine: Encodable, Equatable, Sendable {
    /// HTTP method as registered (uppercase).
    let method: String
    /// Route path template; `:param` marks a path parameter (Hummingbird syntax).
    let path: String
    /// `public` | `key` | `admin` — derived from `AuthMiddleware`, not hand-set.
    let auth: String
    /// One-line purpose, written for a client deciding what to call.
    let note: String

    enum CodingKeys: String, CodingKey {
        case method, path, auth, note
    }
}

// MARK: - Catalog

/// The route index published on `/v1/capabilities`.
enum V1EndpointCatalog {
    /// Registration record: what `buildRouter` registers, plus the client-facing note.
    struct RouteSpec: Sendable {
        let method: String
        let path: String
        let note: String
    }

    /// Every route registered in `ChatCompletionsRouter.buildRouter`, in
    /// registration order. Keep this in sync — `V1EndpointCatalogTests` fails
    /// the build if a route is added, renamed, or removed here and not there
    /// (or vice versa).
    static let routes: [RouteSpec] = [
        RouteSpec(method: "GET", path: "/health", note: "Process liveness + engine pool summary"),
        RouteSpec(
            method: "GET", path: "/ready", note: "Readiness: ready when no session is generating"),
        RouteSpec(
            method: "GET", path: "/v1/models",
            note: "Model inventory (vlm, contextLength, defaultModel)"),
        RouteSpec(method: "GET", path: "/v1/tools", note: "Tool registry with JSON schemas"),
        RouteSpec(
            method: "GET", path: "/v1/capabilities",
            note: "Backend matrix + tokenizer backend + this index"),
        RouteSpec(
            method: "GET", path: "/v1/stats", note: "Structured inference counters and gauges"),
        RouteSpec(
            method: "GET", path: "/v1/perception", note: "Persistent-perception gauge snapshot"),
        RouteSpec(method: "GET", path: "/metrics", note: "Prometheus text exposition"),
        RouteSpec(
            method: "POST", path: "/v1/messages",
            note:
                "Anthropic Messages API (stream + non-stream; text/image/tool_result blocks carried, any other block type refused by name)"
        ),
        RouteSpec(
            method: "POST", path: "/v1/messages/count_tokens",
            note: "Anthropic token pre-flight for a message list"),
        RouteSpec(
            method: "POST", path: "/v1/steer",
            note: "Mid-turn steer: tool boundary of the live turn, else head of the next"),
        RouteSpec(
            method: "POST", path: "/v1/chat/completions",
            note:
                "Chat completion (stream + non-stream, tools, structured output; audio_url is heard to text or refused, never dropped)"
        ),
        RouteSpec(method: "POST", path: "/v1/completions", note: "Legacy text completion"),
        RouteSpec(
            method: "POST", path: "/v1", note: "Auto-route: prompt -> completions, messages -> chat"
        ),
        RouteSpec(
            method: "POST", path: "/v1/count-tokens",
            note: "Token count for prompt | input | messages"),
        RouteSpec(method: "POST", path: "/v1/embeddings", note: "Text embeddings"),
        RouteSpec(
            method: "POST", path: "/v1/models/train", note: "Start a fine-tune run for a model"),
        RouteSpec(
            method: "POST", path: "/v1/models/evaluate", note: "Evaluate a model against a suite"),
        RouteSpec(
            method: "GET", path: "/v1/models/:model/sampling",
            note:
                "Runtime sampling configuration (a `:model` id containing `/` must be percent-encoded as %2F — verbatim ids 404)"
        ),
        RouteSpec(
            method: "PATCH", path: "/v1/models/:model/sampling",
            note:
                "Hot-swap sampling parameters (a `:model` id containing `/` must be percent-encoded as %2F — verbatim ids 404)"
        ),
        RouteSpec(
            method: "DELETE", path: "/v1/models/:model/sampling",
            note:
                "Reset one model's sampling defaults (a `:model` id containing `/` must be percent-encoded as %2F — verbatim ids 404)"
        ),
        RouteSpec(
            method: "DELETE", path: "/v1/models/sampling", note: "Reset all sampling defaults"),
        RouteSpec(
            method: "GET", path: "/v1/models/:model/kv-cache",
            note:
                "Planned KV cache topology, capacity disposition, and the measured dispositions — prefix reuse, tool-declaration prose, and which reuse rule turned a warm session away (a `:model` id containing `/` must be percent-encoded as %2F — verbatim ids 404)"
        ),
        RouteSpec(
            method: "POST", path: "/v1/models/download",
            note:
                "Fetch a model into the local cache — `model` is a relative `org/name` "
                + "(absolute paths and `..` are refused 400 naming the field; `provider` hf|mscope, "
                + "`revision`/`useLatest` optional)"
        ),
        RouteSpec(
            method: "POST", path: "/v1/audio/transcriptions",
            note:
                "Speech to text, on-device (multipart `file`, or JSON `audio` base64 / `url` file://; `model` and `prompt` accepted and not used by the engine; `verbose_json` and timestamps refused — refusals name the axis: permission, locale, or engine)"
        ),
        RouteSpec(
            method: "POST", path: "/v1/multimodal/capture",
            note:
                "Camera / microphone / screen capture (`success: true` only when bytes came back; the mic is two-phase — first call starts, second returns the sample)"
        ),
        RouteSpec(
            method: "POST", path: "/v1/multimodal/speak",
            note: "Text-to-speech (needs speakerEnabled and at least one installed voice)"),
        RouteSpec(
            method: "POST", path: "/v1/multimodal/status",
            note:
                "Multimodal toggles + measured permissions, device/voice counts, screen delivery evidence (ready needs a captured frame), per-channel ready|blocked|unknown|unsupported verdicts and reasons"
        ),
        RouteSpec(method: "POST", path: "/mcp", note: "MCP JSON-RPC (single message per request)"),
        RouteSpec(method: "GET", path: "/sessions", note: "List stored sessions"),
        RouteSpec(method: "DELETE", path: "/sessions/:id", note: "Delete one session"),
        RouteSpec(
            method: "GET", path: "/sessions/:id/memory",
            note: "Hot window (recent messages) of a session"),
        RouteSpec(
            method: "GET", path: "/sessions/search", note: "FTS5 search over session history"),
        RouteSpec(method: "GET", path: "/skills", note: "Installed skills"),
    ]

    /// Wire lines with `auth` resolved against the middleware that enforces it.
    static var lines: [EndpointLine] {
        routes.map {
            EndpointLine(
                method: $0.method,
                path: $0.path,
                auth: auth(method: $0.method, path: $0.path),
                note: $0.note)
        }
    }

    /// `public` (bypasses auth), `admin` (PATCH/DELETE need an admin key), else `key`.
    ///
    /// Derived from ``AuthRoutePolicy`` — the same sets `AuthMiddleware` enforces
    /// with — so the published index cannot drift from the enforcement it
    /// describes.
    static func auth(method: String, path: String) -> String {
        if AuthRoutePolicy.publicPaths.contains(path) {
            return "public"
        }
        if AuthRoutePolicy.requiresAdmin(method: method) {
            return "admin"
        }
        return "key"
    }
}
