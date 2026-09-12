// Provenance: coreai-models (BSD-3-clause, Apple) — verbatim, absorbed 2026-09-12.
//   - VideoInput.swift (VideoFrame/VideoFrameSequence/VideoInput/VideoInputError)
//   - FrameSamplingStrategy.swift
//   - VideoFrameExtractor.swift
//   @ coreai-models HEAD 5716935
// Pure Foundation/CoreGraphics/AVFoundation value types — no CoreAI dependency,
// always compiled (unit-testable on any Apple OS at the module floor).

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// A frame produced by video extraction: the decoded image and its position.
struct VideoFrame: Sendable {
    let image: CGImage
    /// Frame index (0-based ordinal within the extraction sequence).
    let index: Int
}

/// Concrete, Sendable async sequence of video frames.
///
/// Wraps an `AsyncThrowingStream` so that `VideoInput` can conform to `Sendable`
/// in Swift 6 strict concurrency (existential `any AsyncSequence` cannot).
struct VideoFrameSequence: AsyncSequence, Sendable {
    typealias Element = VideoFrame

    private let stream: AsyncThrowingStream<VideoFrame, Error>

    init(stream: AsyncThrowingStream<VideoFrame, Error>) {
        self.stream = stream
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(base: stream.makeAsyncIterator())
    }

    struct Iterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<VideoFrame, Error>.AsyncIterator

        mutating func next() async throws -> VideoFrame? {
            try await base.next()
        }
    }
}

/// Default number of frames sampled from a video when no explicit count is provided.
let defaultVideoFrameCount = 8

/// Extracted video frames ready for vision encoding.
///
/// Frames are delivered lazily via `VideoFrameSequence`. The engine processes
/// and releases each frame incrementally, keeping peak memory at 1-2
/// decoded frames plus accumulated embeddings.
struct VideoInput: Sendable {
    /// Number of frames, if known ahead of time (nil for live streams).
    let frameCount: Int?
    /// Video duration in seconds, if known (nil for live streams).
    let duration: Double?
    /// Lazy frame sequence. Throws on extraction errors unless `skipErrors` was set.
    let frames: VideoFrameSequence

    init(
        frameCount: Int?,
        duration: Double?,
        frames: VideoFrameSequence
    ) {
        self.frameCount = frameCount
        self.duration = duration
        self.frames = frames
    }

    /// Extract frames from a local video file.
    ///
    /// - Parameters:
    ///   - url: File URL to a video (MP4, MOV, etc.).
    ///   - sampling: Frame sampling strategy (default: 8 uniform frames).
    ///   - skipErrors: When true, frames that fail to decode are skipped
    ///     instead of throwing. Default is false.
    /// - Throws: ``VideoInputError`` if the file cannot be read or has no video track.
    static func fromURL(
        _ url: URL,
        sampling: FrameSamplingStrategy = .uniform(count: defaultVideoFrameCount),
        skipErrors: Bool = false
    ) async throws -> VideoInput {
        let (count, duration, frames) = try await VideoFrameExtractor.extractFrames(
            from: url, sampling: sampling, skipErrors: skipErrors)
        return VideoInput(frameCount: count, duration: duration, frames: frames)
    }

    /// Wrap pre-extracted frames (e.g. from camera capture).
    static func fromFrames(
        _ images: [CGImage]
    ) -> VideoInput {
        let count = images.count
        let stream = AsyncThrowingStream<VideoFrame, Error> { continuation in
            for (i, image) in images.enumerated() {
                continuation.yield(VideoFrame(image: image, index: i))
            }
            continuation.finish()
        }
        return VideoInput(
            frameCount: count, duration: nil, frames: VideoFrameSequence(stream: stream))
    }
}

/// How to sample frames from a video for vision encoding.
enum FrameSamplingStrategy: Sendable {
    /// N evenly-spaced frames across the video duration.
    case uniform(count: Int)
    /// One frame every `rate` seconds, capped at `maxFrames`.
    case fps(rate: Double, maxFrames: Int)

    /// Return the same strategy with the frame count overridden.
    func withFrameCount(_ count: Int) -> FrameSamplingStrategy {
        switch self {
        case .uniform: .uniform(count: count)
        case .fps(let rate, _): .fps(rate: rate, maxFrames: count)
        }
    }

    /// Compute sample times (in seconds) for a video of the given duration.
    /// Each time targets the midpoint of its sampling interval.
    ///
    /// - Parameters:
    ///   - duration: Video duration in seconds.
    ///   - videoFrameRate: Native frame rate of the video (e.g. 30.0).
    /// - Returns: Array of sample times in seconds.
    func sampleTimes(forDuration duration: Double, videoFrameRate: Double) -> [Double] {
        guard duration > 0, videoFrameRate > 0 else { return [] }

        let totalFrames = Int(duration * videoFrameRate)
        guard totalFrames > 0 else { return [] }

        switch self {
        case .uniform(let count):
            let n = max(1, min(count, totalFrames))
            if n == 1 {
                return [duration / 2.0]
            }
            let step = duration / Double(n)
            return (0 ..< n).map { step * Double($0) + step / 2.0 }

        case .fps(let rate, let maxFrames):
            guard rate > 0, maxFrames > 0 else { return [] }
            let interval = 1.0 / rate
            var times: [Double] = []
            var t = interval / 2.0
            while t < duration && times.count < maxFrames {
                times.append(t)
                t += interval
            }
            if times.isEmpty {
                times.append(duration / 2.0)
            }
            return times
        }
    }
}

// MARK: - Video Frame Extraction

/// Extracts frames from video files using AVAssetImageGenerator.
struct VideoFrameExtractor {
    /// Extract frames from a video file according to the given sampling strategy.
    ///
    /// - Parameters:
    ///   - url: Local file URL to the video.
    ///   - sampling: How to sample frames from the video.
    ///   - skipErrors: When true, frames that fail to decode are skipped.
    ///     When false (default), the first failure throws.
    /// - Returns: Tuple of (frame count, duration in seconds, lazy frame sequence).
    /// - Throws: ``VideoInputError`` if the video cannot be read.
    static func extractFrames(
        from url: URL,
        sampling: FrameSamplingStrategy,
        skipErrors: Bool = false
    ) async throws -> (count: Int, duration: Double, frames: VideoFrameSequence) {
        let asset = AVURLAsset(url: url)
        let duration = try await CMTimeGetSeconds(asset.load(.duration))

        guard duration > 0, duration.isFinite else {
            throw VideoInputError.invalidVideo("Video has zero or invalid duration")
        }

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoInputError.noVideoTrack
        }

        let frameRate = try await Double(videoTrack.load(.nominalFrameRate))
        guard frameRate > 0 else {
            throw VideoInputError.invalidVideo("Video has invalid frame rate")
        }

        let sampleTimes = sampling.sampleTimes(forDuration: duration, videoFrameRate: frameRate)
        guard !sampleTimes.isEmpty else {
            throw VideoInputError.invalidVideo("No frames to extract")
        }

        let count = sampleTimes.count
        let cmTimes = sampleTimes.map {
            CMTime(seconds: $0, preferredTimescale: 600)
        }

        let seq = VideoFrameSequence(
            stream: AsyncThrowingStream<VideoFrame, Error> { continuation in
                Task {
                    let asset = AVURLAsset(url: url)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.requestedTimeToleranceBefore = CMTime(
                        seconds: 0.1, preferredTimescale: 600)
                    generator.requestedTimeToleranceAfter = CMTime(
                        seconds: 0.1, preferredTimescale: 600)

                    var frameIndex = 0
                    for await result in generator.images(for: cmTimes) {
                        do {
                            let image = try result.image
                            continuation.yield(VideoFrame(image: image, index: frameIndex))
                            frameIndex += 1
                        } catch {
                            if skipErrors {
                                continue
                            }
                            continuation.finish(
                                throwing: VideoInputError.frameExtractionFailed(underlying: error))
                            return
                        }
                    }
                    continuation.finish()
                }
            })

        return (count: count, duration: duration, frames: seq)
    }
}

// MARK: - Errors

enum VideoInputError: Error, LocalizedError {
    case invalidVideo(String)
    case noVideoTrack
    case fileNotFound(URL)
    case frameExtractionFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidVideo(let reason):
            return "Invalid video: \(reason)"
        case .noVideoTrack:
            return "File has no video track (may be audio-only)"
        case .fileNotFound(let url):
            return "Video file not found: \(url.path)"
        case .frameExtractionFailed(let underlying):
            return "Frame extraction failed: \(underlying.localizedDescription)"
        }
    }
}
