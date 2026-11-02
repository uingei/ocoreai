// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelLoadProgress — what this process has measured about a model load in flight.
///
/// ### Why this exists
/// A cold first run fetches the shipping default checkpoint — 3 550 670 554 B of
/// `model.safetensors` — in **794 s at 4.5 MB/s**, and a `curl` of the same object at the same
/// instant got 4.37 MB/s, so the wait is the hub's, not ours (CHANGELOG 11-01(101)). None of
/// that reached the client: a waiter was released at the wait window with a 503 saying only
/// "still loading — retry", while the request that owned the load kept waiting out the fetch.
/// The bytes were already measured — `OcoreaiDownloadProgress` holds them per id, because the
/// GUI draws a progress bar from them — they simply never crossed the wire. This is the shape
/// that measurement takes on `/v1/models` and in the 503 body.
///
/// ### What is NOT here
/// No phase machine, no percent, no ETA without the two numbers that earn it. `bytesTotal` is
/// absent rather than zero when nothing declared a size (a `Progress` that reports bytes but no
/// total is common on the HF lane, where progress is polled off the cache directory), and
/// `secondsRemainingEstimate` is absent unless bytes/sec AND a total are both measured — an ETA
/// off a single sample is a guess wearing a number, and § *The surface never claims more than
/// the engine delivered* is the whole reason this type exists.
///
/// ### One home
/// Downloaded bytes live in ``OcoreaiDownloadProgress`` and nowhere else; this type reads it and
/// adds only what only ``EnginePool`` can know — when the load started (§ `elapsedSeconds`).

import Foundation

struct ModelLoadProgress: Sendable, Codable {
    /// Seconds this process has been loading this id, clocked by ``EnginePool`` at the moment the
    /// id entered the load slot. Pool-clocked because the download store starts at the first
    /// reported byte: a load whose weights are already on disk never enters it at all, and one
    /// that spends time resolving config before it fetches under-reports by exactly that time.
    var elapsedSeconds: Int
    /// Whether a hub transfer is in flight for this id — read off the store's own active entry,
    /// which the downloader opens at `start` and closes at `finish`. `false` means the load is
    /// reading what is already on disk (map / specialize / warm), NOT that it is stuck.
    var downloading: Bool
    /// Bytes landed for this id. Present whenever the store tracks the id at all, including a
    /// measured `0` — a fetch that has landed nothing yet is a fact, not a missing field.
    var bytesDownload: Int64?
    /// Bytes this load is expected to land, when the transport declared a size. Absent = unknown,
    /// never 0.
    var bytesTotal: Int64?
    /// Rolling throughput over the store's own ~5 s window (bytes/s), once two samples span a
    /// meaningful interval.
    var bytesPerSecond: Int?
    /// `(bytesTotal − bytesDownload) / bytesPerSecond`, rounded up — extrapolated from the two
    /// measured numbers above and named as an estimate. Absent when either is unknown.
    var secondsRemainingEstimate: Int?

    /// One sentence naming exactly what has been measured, so no surface can word the wait
    /// differently from any other (the pattern ``VideoDeliveryRecord/evidenceLine`` sets).
    /// Numbers only — a load that has reported nothing says so rather than reading as stalled.
    var disclosureLine: String {
        var parts: [String] = ["\(elapsedSeconds)s elapsed"]
        if downloading, let done = bytesDownload {
            if let total = bytesTotal {
                parts.append("\(done) of \(total) B")
            } else {
                parts.append("\(done) B")
            }
            if let rate = bytesPerSecond {
                parts.append("\(rate) B/s")
            }
        } else if !downloading {
            parts.append("weights on disk, no transfer in flight")
        }
        if let remaining = secondsRemainingEstimate {
            parts.append("~\(remaining)s remaining")
        }
        return parts.joined(separator: ", ")
    }

    /// The same measurement as the keys the 503 `model_loading` envelope carries.
    ///
    /// Spelled here and not at the emit site because this type is the measurement's only home:
    /// a key added at the emit site could name a number this type never proved, and the snake_case
    /// is that envelope's own convention (`type`/`code`/`error_code`), not `/v1/models`' camelCase.
    /// Unmeasured fields are absent, never zero.
    var refusalDetailKeys: [String: Any] {
        var out: [String: Any] = [
            "downloading": downloading,
            "elapsed_seconds": elapsedSeconds,
        ]
        if let done = bytesDownload { out["bytes_download"] = done }
        if let total = bytesTotal { out["bytes_total"] = total }
        if let rate = bytesPerSecond { out["bytes_per_second"] = rate }
        if let remaining = secondsRemainingEstimate {
            out["seconds_remaining_estimate"] = remaining
        }
        return out
    }

    /// Read the two measurements that exist for ``modelId`` and say nothing about the rest.
    ///
    /// - Parameter enteredAt: the instant ``EnginePool`` put this id into the load slot.
    static func measure(
        modelId: String,
        enteredAt: ContinuousClock.Instant,
        store: OcoreaiDownloadProgress = .shared,
    ) -> ModelLoadProgress {
        // The downloader keys the store on the PREFIX-STRIPPED id (`MLXBridge.loadFromHub`
        // strips `mscope:`/`hf:`/`huggingface:` so the GUI can query by plain repo id), so the
        // reader normalizes the same way or it finds nothing and reports silence as absence.
        let key = ModelStore.normalizeModelId(modelId)
        let state = store.progress(for: key)
        let elapsed = Int(enteredAt.duration(to: .now).components.seconds)

        var out = ModelLoadProgress(
            elapsedSeconds: elapsed,
            downloading: state?.active == true,
            bytesDownload: state.map { $0.completedBytes },
            bytesTotal: (state?.totalBytes ?? 0) > 0 ? state.map(\.totalBytes) : nil,
            bytesPerSecond: nil,
            secondsRemainingEstimate: nil
        )
        if let throughput = state?.throughputBytesPerSec, throughput > 0 {
            let rate = Int(throughput)
            out.bytesPerSecond = rate > 0 ? rate : nil
        }
        if let total = out.bytesTotal, let done = out.bytesDownload, let rate = out.bytesPerSecond,
            total >= done, rate > 0
        {
            out.secondsRemainingEstimate =
                Int((Double(total - done) / Double(rate)).rounded(.up))
        }
        return out
    }
}
