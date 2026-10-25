// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelDownloadDTO.swift â€” DTO types for model download API
///
/// Request/response types for ``POST /v1/models/download`` endpoint.

import Foundation

// MARK: - Request

struct DownloadModelRequest: Codable {
    let model: String
    let provider: String?
    let revision: String?
    let useLatest: Bool
    /// Report what would happen and fetch nothing.
    let dryRun: Bool

    var effectiveProvider: String {
        provider ?? "hf"
    }

    init(
        model: String, provider: String? = nil, revision: String? = nil, useLatest: Bool = false,
        dryRun: Bool = false
    ) {
        self.model = model
        self.provider = provider
        self.revision = revision
        self.useLatest = useLatest
        self.dryRun = dryRun
    }

    enum CodingKeys: String, CodingKey {
        case model, provider, revision, useLatest, dryRun
    }

    /// `model` is the only key the wire requires; the rest carry defaults.
    ///
    /// Measured 10-20 (probe `scripts/probes/20-download-path-traversal.sh`, before the fix):
    /// every body that omitted `useLatest` — which is every body, since it is a refresh override
    /// — answered `400 Coding key \`useLatest\` not found.`, so the endpoint never reached
    /// `validate()` and never streamed. `useLatest: Bool = false` in `init` is Swift-side
    /// convenience; the synthesized decoder still asks for the key (AGENTS.md § Wire DTOs: an
    /// optional field must be Optional in the DTO or hand-decoded with `decodeIfPresent`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        revision = try container.decodeIfPresent(String.self, forKey: .revision)
        useLatest = try container.decodeIfPresent(Bool.self, forKey: .useLatest) ?? false
        dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
    }

    func validate() throws {
        guard !model.isEmpty else {
            throw AppError.invalidRequest("Model identifier must not be empty")
        }
        let p = effectiveProvider
        guard p == "hf" || p == "mscope" else {
            throw AppError.invalidRequest("Provider must be hf or mscope, got \(p)")
        }
        // Both values below end up inside a filesystem path or a URL path, so both are checked
        // as relative paths here — before the handler opens the SSE stream. A client that names
        // `../../anything` gets a 400 naming the field, not a 200 stream of error events.
        // The rule itself lives in Core/HubRelativePath.swift (one home).
        do {
            _ = try HubRelativePath.components(model, field: "model")
            if let revision {
                _ = try HubRelativePath.components(revision, field: "revision")
            }
        } catch let rejection as HubRelativePath.Unsafe {
            throw AppError(hubPathRejected: rejection)
        }
    }
}

// MARK: - Plan

/// What a dry-run answers: the same numbers the pre-flight guard blocks on, measured, with
/// nothing written. `requiredBytes == 0` means every byte the download would fetch is already
/// in the cache dir. A nil side means the hub or the volume did not say, and ocoreai turns
/// silence into neither a fit nor a refusal (AGENTS.md invariant 2).
struct DownloadPlan: Codable {
    let model: String
    let provider: String
    /// Bytes still to fetch.
    let requiredBytes: Int64?
    /// Bytes the matched files weigh at the hub, before cache credit.
    let remoteTotalBytes: Int64?
    /// Bytes this repo already has in its cache dir.
    let cachedBytes: Int64
    /// Free bytes on the volume that would hold it.
    let freeBytes: Int64?
    /// nil when either side is unknown.
    let wouldFit: Bool?
    /// "measured" -- hub sizes minus cache; "locallySatisfied" -- the fetch would be a no-op.
    let basis: String
}

// MARK: - SSE Event

struct DownloadSSEEvent: Codable {
    let downloadId: String
    let eventType: String  // "progress" | "completed" | "error"
    let percentage: Int?
    let totalBytes: Int64?
    let transferredBytes: Int64?
    let cacheDir: String?
    let errorMessage: String?
    let etaSeconds: Int64?
    /// Set only on `eventType: "plan"`; nil on progress/completed/error events.
    let plan: DownloadPlan?

    static func progress(
        _ downloadId: String, percentage: Int, totalBytes: Int64, transferredBytes: Int64,
        eta: Int64?
    ) -> DownloadSSEEvent {
        DownloadSSEEvent(
            downloadId: downloadId, eventType: "progress", percentage: percentage,
            totalBytes: totalBytes, transferredBytes: transferredBytes,
            cacheDir: nil, errorMessage: nil, etaSeconds: eta, plan: nil)
    }

    static func plan(_ downloadId: String, plan: DownloadPlan) -> DownloadSSEEvent {
        DownloadSSEEvent(
            downloadId: downloadId, eventType: "plan", percentage: nil,
            totalBytes: nil, transferredBytes: nil, cacheDir: nil,
            errorMessage: nil, etaSeconds: nil, plan: plan)
    }

    static func completed(_ downloadId: String, cacheDir: String) -> DownloadSSEEvent {
        DownloadSSEEvent(
            downloadId: downloadId, eventType: "completed", percentage: 100,
            totalBytes: nil, transferredBytes: nil, cacheDir: cacheDir,
            errorMessage: nil, etaSeconds: nil, plan: nil)
    }

    static func error(_ downloadId: String, message: String) -> DownloadSSEEvent {
        DownloadSSEEvent(
            downloadId: downloadId, eventType: "error", percentage: nil,
            totalBytes: nil, transferredBytes: nil, cacheDir: nil,
            errorMessage: message, etaSeconds: nil, plan: nil)
    }
}

// MARK: - Status Response

struct DownloadStatusResponse: Codable {
    let downloadId: String
    let status: String  // "downloading" | "completed" | "error" | "not_found"
    let percentage: Int?
    let cacheDir: String?
    let errorMessage: String?
}
