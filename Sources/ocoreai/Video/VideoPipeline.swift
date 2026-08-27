// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import CoreGraphics
import Foundation

/// Result of a video generation run.
public struct VideoGenerationResult: Sendable {
    public let frames: [CGImage]
    public let fps: Int
    public let seed: UInt32

    public init(frames: [CGImage], fps: Int, seed: UInt32) {
        self.frames = frames
        self.fps = fps
        self.seed = seed
    }
}

/// Progress update during video generation.
public struct VideoProgress: Sendable {
    public enum Phase: Sendable {
        case encoding
        case denoising
        case decoding
        case assembling
    }

    public let step: Int
    public let totalSteps: Int
    public let phase: Phase

    public init(step: Int, totalSteps: Int, phase: Phase) {
        self.step = step
        self.totalSteps = totalSteps
        self.phase = phase
    }
}

/// Protocol for video generation pipelines.
///
/// This is the upstream `VideoPipeline` protocol — copied verbatim so the
/// future `WanPipeline` runtime (Batch 2, requires CoreAI.framework +
/// `.aimodel` weights + floor macOS 27) can conform with zero signature
/// drift from coreai-models. Declaring it now (rather than together with its
/// conformer) lets the ocoreai public surface be inspected, tested, and
/// reasoned about BEFORE the runtime dependency lands.
public protocol VideoPipeline {
    var defaultVideoSize: (width: Int, height: Int) { get }
    var defaultFrameCount: Int { get }

    func generateVideo(
        configuration: VideoConfiguration,
        progressHandler: @Sendable (VideoProgress) -> Bool
    ) async throws -> VideoGenerationResult
}
