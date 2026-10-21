// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! HubReachability.swift — ask a hub whether it can answer at all, before a request gets
//! handed to a hub client whose network timeouts are not ours to bound.
//!
//! ### Why (measured 10-21, this host)
//! `huggingface.co` is a black hole here: `curl` to its API times out even for a repo that
//! exists (`HTTP=000 t=8.0s`), while ModelScope answers a real 404 in 0.18 s. So a request
//! for an id that ModelScope does not have fell through `MLXBridge.loadFromHubWithFallback`
//! to the HF client and never came back: no answer after 300 s, and the id stayed in
//! `EnginePool.loadingModels` while it waited. A refusal is allowed; silence is not — the
//! other conversations on the box deserve an answer.
//!
//! ### Why a probe instead of a deadline on the download
//! A real download legitimately takes minutes, so "bound the whole load" would cut off the
//! thing users wait for. Existence, though, is cheap and decidable: a reachable hub answers
//! `/api/models/<repo>` in well under a second, a blocked one never answers. Getting that
//! answer first costs ~1 s on the happy path and turns minutes of silence into a named
//! refusal on this network. Bytes already flowing are never cut.

import Foundation

enum HubReachability {

    /// A reachable hub answers in well under a second (measured: ModelScope 404 in 0.18 s);
    /// 8 s leaves room for a slow-but-alive endpoint. The cost of guessing wrong is one
    /// refused-but-retryable request, not a stalled conversation.
    static let probeTimeoutSeconds: TimeInterval = 8

    enum Hub: Equatable, Sendable {
        case modelScope
        case huggingFace

        var name: String {
            switch self {
            case .modelScope: return "ModelScope"
            case .huggingFace: return "Hugging Face"
            }
        }
    }

    /// What the transport produced. Kept as raw material so the classification below is
    /// unit-testable without touching a network.
    enum Response: Equatable, Sendable {
        case status(Int)
        case transport(String)
    }

    enum Verdict: Equatable, Sendable {
        /// The hub has it — or gates it: 401/403 must not refuse a repo the caller's own
        /// token can fetch, so an auth challenge counts as reachable-and-present.
        case present
        /// The hub answered definitively: this repo is not here.
        case absent(status: Int)
        /// The hub could not be asked at all: black hole, reset, throttle, server error.
        case unreachable(reason: String)
    }

    /// One rule for "which base do I ask": honour the operator's endpoint lever when there is
    /// one, strip a trailing slash, else take the canonical host. Both hubs get the same
    /// treatment — a mirror that was configured but not probed is the bug `HFMirrorPolicy`
    /// exists to kill, and it would be just as wrong on the ModelScope side.
    private static func base(_ endpoint: String?, canonical: String) -> String {
        let trimmed = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return canonical }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    /// Existence endpoint for a repo. Endpoints arrive from the caller's side of each lever
    /// (`MODELSCOPE_ENDPOINT` / `HF_ENDPOINT`); `ModelStore.modelScopeDefaultBaseURL` is the
    /// single source for the ModelScope host, so this file names no hub host of its own.
    static func apiURL(
        hub: Hub,
        repoId: String,
        modelScopeEndpoint: String? = ModelStore.modelScopeDefaultBaseURL,
        hfEndpoint: String? = HFMirrorPolicy.canonical
    ) -> URL? {
        switch hub {
        case .modelScope:
            return URL(
                string:
                    "\(base(modelScopeEndpoint, canonical: ModelStore.modelScopeDefaultBaseURL))/api/v1/models/\(repoId)"
            )
        case .huggingFace:
            return URL(
                string:
                    "\(base(hfEndpoint, canonical: HFMirrorPolicy.canonical))/api/models/\(repoId)")
        }
    }

    /// The whole decision, pure. 2xx and auth challenges count as present; 404/422 count as
    /// definitive absence; everything else (429, 5xx, transport failure) counts as
    /// "could not be asked" — transient, and the client is told so rather than being told
    /// the model does not exist.
    static func classify(_ response: Response) -> Verdict {
        switch response {
        case .status(let code) where (200 ... 299).contains(code):
            return .present
        case .status(401), .status(403):
            return .present
        case .status(let code) where code == 404 || code == 422:
            return .absent(status: code)
        case .status(let code):
            return .unreachable(reason: "HTTP \(code)")
        case .transport(let reason):
            return .unreachable(reason: reason)
        }
    }

    /// Ask, with a hard timeout, and classify what came back. Never throws: the caller's
    /// choices are proceed / refuse, and a failure to ask is itself an answer.
    static func probe(
        hub: Hub, repoId: String,
        modelScopeEndpoint: String? = nil,
        hfEndpoint: String? = nil,
        timeout: TimeInterval = probeTimeoutSeconds
    ) async -> Verdict {
        let environment = ProcessInfo.processInfo.environment
        guard
            let url = apiURL(
                hub: hub,
                repoId: repoId,
                modelScopeEndpoint:
                    modelScopeEndpoint ?? environment["MODELSCOPE_ENDPOINT"],
                hfEndpoint: hfEndpoint ?? HFMirrorPolicy.current().endpoint
            )
        else {
            return .unreachable(reason: "could not build a hub URL for \(repoId)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        do {
            let (_, response) = try await URLSession(configuration: configuration).data(
                for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable(reason: "no HTTP response")
            }
            return classify(.status(http.statusCode))
        } catch {
            return classify(.transport(String(describing: error)))
        }
    }
}
