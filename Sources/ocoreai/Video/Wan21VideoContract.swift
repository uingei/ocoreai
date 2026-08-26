// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause
//
// Provenance: derived from coreai-models `CoreAIVideoDiffusionPipeline` (Wan 2.1 text-to-video):
//   - swift/Sources/CoreAIVideoDiffusionPipeline/Pipelines/VideoConfiguration.swift
//       (QualityPreset, VideoConfiguration, VideoConfiguration.from(preset:))
//   - swift/Sources/CoreAIVideoDiffusionPipeline/Pipelines/WanPipeline.swift
//       (compression ratios, VAE temporal constants, latent-shape math,
//        pre-generation validation rules + messages, WanError)
//
// ocoreai 2026-08-26: Wan 2.1 consumption CONTRACT surface — the config / preset /
//   validation / latent-shape / error layer, copied value-for-value from the CoreAI
//   baseline. Pure Foundation (no CoreAI framework, no .aimodel dependency), so it
//   compiles on the macOS 14 floor with NO @available gate and no platform bump.
//   This is the upstream→consumer (S2) slice of the user-named Wan 2.1/2.2 support.
//   The inference runtime (WanPipeline denoise loop + 3D-VAE decode, which requires
//   .aimodel weights + the CoreAI.framework, floor macOS 27) is deferred to the
//   runtime batch — that platform floor is a product decision, not a copy decision.
//
//   Not copied here (runtime-owned, Batch 2): the denoise loop, CFG math,
//   UMT5 encode, 3D-VAE decode, tiled decode, frame extraction — all depend on the
//   system CoreAI framework and a real model directory.

import Foundation

// MARK: - Quality presets (copied verbatim from upstream QualityPreset)

/// Quality presets that trade off speed vs output quality.
///
/// Values are copied verbatim from coreai-models `QualityPreset`.
public enum QualityPreset: String, CaseIterable, Sendable {
    case fast
    case balanced
    case best

    public var steps: Int {
        switch self {
        case .fast: 12
        case .balanced: 30
        case .best: 50
        }
    }

    public var numFrames: Int {
        switch self {
        case .fast: 33
        case .balanced: 81
        case .best: 81
        }
    }

    /// Fraction of final steps to skip the unconditional (negative) CFG pass.
    /// nil = disabled (full CFG for all steps).
    public var cfgCutoff: Float? {
        switch self {
        case .fast: 0.5
        case .balanced: 0.5
        case .best: nil
        }
    }
}

// MARK: - Video generation configuration (copied verbatim from upstream VideoConfiguration)

/// Configuration for Wan 2.1 video generation.
///
/// Field names, defaults, and the `from(preset:)` resolution rules are copied
/// value-for-value from coreai-models `VideoConfiguration` so the ocoreai consumer
/// contract matches the upstream pipeline's input surface exactly.
public struct VideoConfiguration: Sendable {
    public var prompt: String
    public var negativePrompt: String
    public var seed: UInt32
    public var stepCount: Int
    public var guidanceScale: Float
    public var numFrames: Int
    public var fps: Int
    public var width: Int
    public var height: Int
    public var dumpDirectory: String?
    public var loadNoisePath: String?

    /// Tiled VAE decoding tile size. nil = full-sequence decode.
    public var vaeTileSize: Int?

    /// Overlap between adjacent VAE tiles in latent-space units. Default 4 (= 32 px at 8×).
    public var vaeTileOverlap: Int

    /// Fraction of final steps to skip the unconditional CFG pass. nil = full CFG.
    public var cfgCutoffFraction: Float?

    public init(
        prompt: String,
        negativePrompt: String = "",
        seed: UInt32 = 42,
        stepCount: Int = 50,
        guidanceScale: Float = 5.0,
        numFrames: Int = 81,
        fps: Int = 16,
        width: Int = 832,
        height: Int = 480,
        dumpDirectory: String? = nil,
        loadNoisePath: String? = nil,
        vaeTileSize: Int? = nil,
        vaeTileOverlap: Int = 4,
        cfgCutoffFraction: Float? = nil
    ) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.seed = seed
        self.stepCount = stepCount
        self.guidanceScale = guidanceScale
        self.numFrames = numFrames
        self.fps = fps
        self.width = width
        self.height = height
        self.dumpDirectory = dumpDirectory
        self.loadNoisePath = loadNoisePath
        self.vaeTileSize = vaeTileSize
        self.vaeTileOverlap = vaeTileOverlap
        self.cfgCutoffFraction = cfgCutoffFraction
    }

    /// Convenience: create from a quality preset with optional overrides.
    ///
    /// Resolution rules copied verbatim from upstream: `stepCount`, `numFrames`, and
    /// `cfgCutoffFraction` fall back to the preset when nil; `guidanceScale` keeps its
    /// own default (5.0) — it is NOT taken from the preset.
    public static func from(
        preset: QualityPreset,
        prompt: String,
        negativePrompt: String = "",
        seed: UInt32 = 42,
        stepCount: Int? = nil,
        guidanceScale: Float = 5.0,
        numFrames: Int? = nil,
        fps: Int = 16,
        width: Int = 832,
        height: Int = 480,
        vaeTileSize: Int? = nil,
        vaeTileOverlap: Int = 4,
        cfgCutoffFraction: Float? = nil
    ) -> VideoConfiguration {
        VideoConfiguration(
            prompt: prompt,
            negativePrompt: negativePrompt,
            seed: seed,
            stepCount: stepCount ?? preset.steps,
            guidanceScale: guidanceScale,
            numFrames: numFrames ?? preset.numFrames,
            fps: fps,
            width: width,
            height: height,
            vaeTileSize: vaeTileSize,
            vaeTileOverlap: vaeTileOverlap,
            cfgCutoffFraction: cfgCutoffFraction ?? preset.cfgCutoff
        )
    }
}

// MARK: - Wan 2.1 errors (copied verbatim from upstream WanError)

public enum WanError: Error, LocalizedError {
    case invalidMetadata(String)
    case invalidConfiguration(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidMetadata(let msg):
            return "Invalid Wan pipeline metadata: \(msg)"
        case .invalidConfiguration(let msg):
            return "Invalid video configuration: \(msg)"
        case .cancelled:
            return "Video generation was cancelled"
        }
    }
}

// MARK: - Wan 2.1 architecture constants + latent-shape math + validation

/// Wan 2.1 architecture constants, latent-shape math, and the pre-generation
/// validation gate — copied value-for-value from coreai-models `WanPipeline`.
///
/// These are the deterministic, runtime-free parts of the pipeline: the compression
/// ratios, the VAE temporal export shape, the pixel→latent shape, and the config
/// validation rules (with their exact error messages) that upstream runs before any
/// model load.
public enum Wan21 {
    // MARK: - Compression ratios (WanPipeline.swift:47-48)

    /// Spatial (H,W) compression: pixel units per latent unit.
    public static let spatialCompression = 8
    /// Temporal (T) compression: pixel frames per latent frame (causal 3D VAE).
    public static let temporalCompression = 4
    /// Latent channel count (`z_dim`).
    public static let latentChannels = 16
    /// Fixed UMT5 text sequence length (`textSeqLen`).
    public static let textSeqLen = 226
    /// Latent frames the VAE was exported with (`vaeTemporalFrames`).
    public static let vaeTemporalFrames = 21
    /// Temporal overlap between VAE chunks, in latent frames.
    public static let vaeTemporalOverlap = 1

    // MARK: - Defaults (WanPipeline.swift init defaults)

    public static let defaultSteps = 50
    public static let defaultGuidanceScale: Float = 5.0
    public static let defaultShift: Float = 3.0
    public static let defaultFrameCount = 81
    public static let defaultWidth = 832
    public static let defaultHeight = 480
    public static let defaultSeed: UInt32 = 42
    public static let defaultFps = 16
    public static let defaultVAETileOverlap = 4

    public static var defaultVideoSize: (width: Int, height: Int) { (832, 480) }

    // MARK: - Latent-shape math (WanPipeline.swift:171-174)

    /// Latent frames for a given pixel-frame count: `(n - 1) / 4 + 1`.
    public static func latentFrames(for numFrames: Int) -> Int {
        (numFrames - 1) / temporalCompression + 1
    }

    /// Latent height for a given pixel height.
    public static func latentHeight(for height: Int) -> Int {
        height / spatialCompression
    }

    /// Latent width for a given pixel width.
    public static func latentWidth(for width: Int) -> Int {
        width / spatialCompression
    }

    /// Flat latent element count: `C * T' * H' * W'`.
    public static func latentSize(width: Int, height: Int, numFrames: Int) -> Int {
        latentChannels * latentFrames(for: numFrames) * latentHeight(for: height)
            * latentWidth(for: width)
    }

    /// Maximum pixel-frame count the VAE supports (WanPipeline.swift:157):
    /// `(vaeTemporalFrames - 1) * 4 + 1` == 81.
    public static func maxOutputFrames() -> Int {
        (vaeTemporalFrames - 1) * temporalCompression + 1
    }

    // MARK: - Validation gate (WanPipeline.swift:138-161, exact rules + messages)

    /// Validate a `VideoConfiguration` against the Wan 2.1 VAE/architectural
    /// constraints, in upstream order, with upstream's exact messages.
    ///
    /// Returns nil if the configuration is valid (safe to proceed), otherwise the
    /// first violated rule as `WanError.invalidConfiguration`. No model is loaded
    /// and no side effect occurs — a pure, total predicate.
    public static func validationError(for config: VideoConfiguration) -> WanError? {
        if config.numFrames <= 0 {
            return WanError.invalidConfiguration("numFrames must be > 0")
        }
        if config.stepCount <= 0 {
            return WanError.invalidConfiguration("stepCount must be > 0")
        }
        if config.width % spatialCompression != 0 {
            return WanError.invalidConfiguration(
                "width (\(config.width)) must be a multiple of \(spatialCompression)")
        }
        if config.height % spatialCompression != 0 {
            return WanError.invalidConfiguration(
                "height (\(config.height)) must be a multiple of \(spatialCompression)")
        }
        if (config.numFrames - 1) % temporalCompression != 0 {
            return WanError.invalidConfiguration(
                "numFrames (\(config.numFrames)) must satisfy (n-1) mod \(temporalCompression) == 0 (e.g. 17, 33, 49, 65, 81)"
            )
        }
        let maxFrames = maxOutputFrames()
        if config.numFrames > maxFrames {
            return WanError.invalidConfiguration(
                "numFrames (\(config.numFrames)) exceeds VAE capacity (\(maxFrames) frames)")
        }
        return nil
    }
}
