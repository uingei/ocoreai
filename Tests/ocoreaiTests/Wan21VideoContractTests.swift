// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// Exact-value verification of the Wan 2.1 consumption CONTRACT surface
// (`Sources/ocoreai/Video/Wan21VideoContract.swift`), copied value-for-value from
// coreai-models `CoreAIVideoDiffusionPipeline`. Every assertion is an equality
// against a constant pinned to the upstream source — a weak `count > 0` is a defect.
//
// Upstream provenance (exact values these tests pin):
//   QualityPreset        -> VideoConfiguration.swift:9-37 (steps/numFrames/cfgCutoff)
//   VideoConfiguration   -> VideoConfiguration.swift:40-129 (defaults + from(preset:))
//   Wan21 constants      -> WanPipeline.swift:47-50,431,72-76
//   latent-shape math    -> WanPipeline.swift:171-174
//   validation rules     -> WanPipeline.swift:138-161 (exact messages)
//   WanError             -> WanPipeline.swift:672-687

import Foundation
import Testing

@testable import ocoreai

@Suite("Wan 2.1 video contract — QualityPreset")
struct Wan21QualityPresetTests {
    @Test func fastPresetSteps() { #expect(QualityPreset.fast.steps == 12) }
    @Test func balancedPresetSteps() { #expect(QualityPreset.balanced.steps == 30) }
    @Test func bestPresetSteps() { #expect(QualityPreset.best.steps == 50) }

    @Test func fastPresetFrames() { #expect(QualityPreset.fast.numFrames == 33) }
    @Test func balancedPresetFrames() { #expect(QualityPreset.balanced.numFrames == 81) }
    @Test func bestPresetFrames() { #expect(QualityPreset.best.numFrames == 81) }

    @Test func fastCfgCutoff() { #expect(QualityPreset.fast.cfgCutoff == 0.5) }
    @Test func balancedCfgCutoff() { #expect(QualityPreset.balanced.cfgCutoff == 0.5) }
    @Test func bestCfgCutoffDisabled() { #expect(QualityPreset.best.cfgCutoff == nil) }

    @Test func allCasesAreExactlyThree() {
        #expect(QualityPreset.allCases.count == 3)
        #expect(QualityPreset.allCases == [.fast, .balanced, .best])
    }
}

@Suite("Wan 2.1 video contract — VideoConfiguration defaults")
struct Wan21ConfigurationDefaultsTests {
    private static var defaultConfig: VideoConfiguration {
        VideoConfiguration(prompt: "p")
    }

    @Test func seedDefaultsTo42() { #expect(Self.defaultConfig.seed == 42) }
    @Test func stepCountDefaultsTo50() { #expect(Self.defaultConfig.stepCount == 50) }
    @Test func guidanceScaleDefaultsToFive() { #expect(Self.defaultConfig.guidanceScale == 5.0) }
    @Test func numFramesDefaultsTo81() { #expect(Self.defaultConfig.numFrames == 81) }
    @Test func fpsDefaultsTo16() { #expect(Self.defaultConfig.fps == 16) }
    @Test func widthDefaultsTo832() { #expect(Self.defaultConfig.width == 832) }
    @Test func heightDefaultsTo480() { #expect(Self.defaultConfig.height == 480) }
    @Test func negativePromptDefaultsEmpty() { #expect(Self.defaultConfig.negativePrompt == "") }
    @Test func vaeTileOverlapDefaultsTo4() { #expect(Self.defaultConfig.vaeTileOverlap == 4) }
    @Test func vaeTileSizeDefaultsNil() { #expect(Self.defaultConfig.vaeTileSize == nil) }
    @Test func cfgCutoffFractionDefaultsNil() {
        #expect(Self.defaultConfig.cfgCutoffFraction == nil)
    }
    @Test func dumpDirectoryDefaultsNil() { #expect(Self.defaultConfig.dumpDirectory == nil) }
    @Test func loadNoisePathDefaultsNil() { #expect(Self.defaultConfig.loadNoisePath == nil) }
}

@Suite("Wan 2.1 video contract — from(preset:) resolution rules")
struct Wan21PresetResolutionTests {
    @Test func fastPresetResolvesStepsAndFramesAndCutoff() {
        let c = VideoConfiguration.from(preset: .fast, prompt: "p")
        #expect(c.stepCount == 12)
        #expect(c.numFrames == 33)
        #expect(c.cfgCutoffFraction == 0.5)
    }

    @Test func bestPresetResolvesStepsAndFramesCutoffDisabled() {
        let c = VideoConfiguration.from(preset: .best, prompt: "p")
        #expect(c.stepCount == 50)
        #expect(c.numFrames == 81)
        #expect(c.cfgCutoffFraction == nil)
    }

    @Test func explicitStepCountOverrideWinsOverPreset() {
        let c = VideoConfiguration.from(preset: .fast, prompt: "p", stepCount: 20)
        #expect(c.stepCount == 20)  // explicit arg beats preset.steps (12)
        #expect(c.numFrames == 33)  // numFrames still from preset (fast)
    }

    @Test func explicitCfgCutoffOverrideWinsOverPreset() {
        let c = VideoConfiguration.from(preset: .best, prompt: "p", cfgCutoffFraction: 0.3)
        #expect(c.cfgCutoffFraction == 0.3)  // explicit beats preset.best (nil)
    }

    @Test func guidanceScaleIsNeverTakenFromPreset() {
        // All three presets leave guidanceScale at the from(preset:) default of 5.0.
        for preset in QualityPreset.allCases {
            #expect(VideoConfiguration.from(preset: preset, prompt: "p").guidanceScale == 5.0)
        }
    }
}

@Suite("Wan 2.1 video contract — architecture constants")
struct Wan21ConstantsTests {
    @Test func spatialCompressionIs8() { #expect(Wan21.spatialCompression == 8) }
    @Test func temporalCompressionIs4() { #expect(Wan21.temporalCompression == 4) }
    @Test func latentChannelsIs16() { #expect(Wan21.latentChannels == 16) }
    @Test func textSeqLenIs226() { #expect(Wan21.textSeqLen == 226) }
    @Test func vaeTemporalFramesIs21() { #expect(Wan21.vaeTemporalFrames == 21) }
    @Test func vaeTemporalOverlapIs1() { #expect(Wan21.vaeTemporalOverlap == 1) }
    @Test func defaultVideoSizeIs832x480() {
        let size = Wan21.defaultVideoSize
        #expect(size.width == 832)
        #expect(size.height == 480)
    }
    @Test func maxOutputFramesIs81() { #expect(Wan21.maxOutputFrames() == 81) }
}

@Suite("Wan 2.1 video contract — latent shape math")
struct Wan21LatentShapeTests {
    // (n-1)/4+1
    @Test func latentFrames81Yields21() { #expect(Wan21.latentFrames(for: 81) == 21) }
    @Test func latentFrames17Yields5() { #expect(Wan21.latentFrames(for: 17) == 5) }
    @Test func latentFrames33Yields9() { #expect(Wan21.latentFrames(for: 33) == 9) }
    @Test func latentFrames49Yields13() { #expect(Wan21.latentFrames(for: 49) == 13) }
    @Test func latentFrames65Yields17() { #expect(Wan21.latentFrames(for: 65) == 17) }

    // height/8
    @Test func latentHeight480Yields60() { #expect(Wan21.latentHeight(for: 480) == 60) }

    // width/8
    @Test func latentWidth832Yields104() { #expect(Wan21.latentWidth(for: 832) == 104) }

    // 16 * 21 * 60 * 104 = 2,096,640 (default 832x480x81 config)
    @Test func latentSizeForDefaultConfigIsExactly2096640() {
        #expect(Wan21.latentSize(width: 832, height: 480, numFrames: 81) == 2_096_640)
    }
}

@Suite("Wan 2.1 video contract — validation gate")
struct Wan21ValidationTests {
    private static func message(_ config: VideoConfiguration) -> String? {
        guard case .invalidConfiguration(let msg)? = Wan21.validationError(for: config) else {
            return nil
        }
        return msg
    }

    @Test func defaultConfigIsValid() {
        #expect(Wan21.validationError(for: VideoConfiguration(prompt: "p")) == nil)
    }

    @Test func zeroNumFramesRejectedWithExactMessage() {
        let c = VideoConfiguration(prompt: "p", numFrames: 0)
        #expect(Self.message(c) == "numFrames must be > 0")
    }

    @Test func zeroStepsRejectedWithExactMessage() {
        let c = VideoConfiguration(prompt: "p", stepCount: 0)
        #expect(Self.message(c) == "stepCount must be > 0")
    }

    @Test func nonMultipleWidthRejectedWithExactMessage() {
        let c = VideoConfiguration(prompt: "p", width: 830)
        #expect(Self.message(c) == "width (830) must be a multiple of 8")
    }

    @Test func nonMultipleHeightRejectedWithExactMessage() {
        let c = VideoConfiguration(prompt: "p", height: 482)
        #expect(Self.message(c) == "height (482) must be a multiple of 8")
    }

    @Test func numFramesOffStrideRejectedWithExactMessage() {
        // (16-1) % 4 == 3 -> rejected
        let c = VideoConfiguration(prompt: "p", numFrames: 16)
        #expect(
            Self.message(c)
                == "numFrames (16) must satisfy (n-1) mod 4 == 0 (e.g. 17, 33, 49, 65, 81)")
    }

    @Test func overCapacityFramesRejectedWithExactMessage() {
        // 85 > 81 -> VAE capacity violation
        let c = VideoConfiguration(prompt: "p", numFrames: 85)
        #expect(Self.message(c) == "numFrames (85) exceeds VAE capacity (81 frames)")
    }

    @Test func firstViolationWinsInUpstreamOrder() {
        // All four invalid; upstream checks numFrames>0 first -> that message wins.
        let c = VideoConfiguration(prompt: "p", stepCount: 0, numFrames: 0, width: 3, height: 3)
        #expect(Self.message(c) == "numFrames must be > 0")
    }
}

@Suite("Wan 2.1 video contract — WanError LocalizedError surface")
struct Wan21ErrorTests {
    @Test func invalidMetadataDescription() {
        #expect(
            WanError.invalidMetadata("x").errorDescription
                == "Invalid Wan pipeline metadata: x")
    }

    @Test func invalidConfigurationDescription() {
        #expect(
            WanError.invalidConfiguration("y").errorDescription
                == "Invalid video configuration: y")
    }

    @Test func cancelledDescription() {
        #expect(WanError.cancelled.errorDescription == "Video generation was cancelled")
    }
}
