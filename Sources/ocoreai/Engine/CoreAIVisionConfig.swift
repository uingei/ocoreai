// Provenance: coreai-models (BSD-3-clause, Apple) — absorbed 2026-09-12.
//   - VisionConfig: swift/Sources/CoreAILanguageModels/Bundle/LanguageConfig.swift L184-279
//   - VLMModelConfig: swift/Sources/CoreAILanguageModels/InferenceEngines/CoreAISequentialVLMEngine.swift L21-38
//   - upstream pin: coreai-models HEAD 5716935 (#245)
// Adapted: `VLMModelConfig.base` uses ocoreai `InternalModelConfig` (ocoreai
// InferenceConfiguration conformance — CoreAIEngine.swift L267) instead of the
// upstream `ModelConfig`. VisionConfig is verbatim (pure value type, no CoreAI
// dependency).

import Foundation

/// Vision transformer configuration for a VLM `.aimodel` bundle.
/// Verbatim from upstream coreai-models (LanguageConfig.swift).
struct VisionConfig: Codable, Sendable, Equatable {
    /// Input image size (square). Vision encoder expects this resolution.
    let imageSize: Int

    /// Patch size for the vision transformer.
    let patchSize: Int

    /// Number of embedding tokens produced per image after projection.
    let imageTokenCount: Int

    /// Token ID used as a placeholder in the text sequence for image positions.
    let imageTokenId: Int32

    /// Per-channel normalization mean (RGB). Defaults to CLIP values when omitted.
    let imageMean: [Double]

    /// Per-channel normalization std (RGB). Defaults to CLIP values when omitted.
    let imageStd: [Double]

    /// Pixel rescale factor applied before normalization. Defaults to 1.0 when omitted.
    let rescaleFactor: Double

    /// Image preprocessing strategy. Defaults to stretch when omitted.
    let imageStrategy: ImageStrategy

    /// Whether to include original image dimensions in the text prompt. Defaults to false.
    let includeImageInfo: Bool

    /// Whether this model supports video (multi-frame) input.
    var supportsVideo: Bool { maxVideoFrames != nil }

    /// Maximum number of video frames for multi-frame models. Nil for image-only models.
    let maxVideoFrames: Int?

    /// Visual tokens produced per frame. Nil defaults to `imageTokenCount`.
    let tokensPerFrame: Int?

    /// CLIP normalization (Qwen VL, Pixtral, InternVL, Phi-3.5-vision).
    static let clipMean = [0.48145466, 0.4578275, 0.40821073]
    static let clipStd = [0.26862954, 0.26130258, 0.27577711]

    init(
        imageSize: Int,
        patchSize: Int,
        imageTokenCount: Int,
        imageTokenId: Int32,
        imageMean: [Double]? = nil,
        imageStd: [Double]? = nil,
        rescaleFactor: Double? = nil,
        imageStrategy: ImageStrategy? = nil,
        includeImageInfo: Bool? = nil,
        maxVideoFrames: Int? = nil,
        tokensPerFrame: Int? = nil
    ) {
        self.imageSize = imageSize
        self.patchSize = patchSize
        self.imageTokenCount = imageTokenCount
        self.imageTokenId = imageTokenId
        self.imageMean = imageMean ?? Self.clipMean
        self.imageStd = imageStd ?? Self.clipStd
        self.rescaleFactor = rescaleFactor ?? 1.0
        self.imageStrategy = imageStrategy ?? .stretch
        self.includeImageInfo = includeImageInfo ?? false
        self.maxVideoFrames = maxVideoFrames
        self.tokensPerFrame = tokensPerFrame
    }

    enum CodingKeys: String, CodingKey {
        case imageSize = "image_size"
        case patchSize = "patch_size"
        case imageTokenCount = "image_token_count"
        case imageTokenId = "image_token_id"
        case imageMean = "image_mean"
        case imageStd = "image_std"
        case rescaleFactor = "rescale_factor"
        case imageStrategy = "image_strategy"
        case includeImageInfo = "include_image_info"
        case maxVideoFrames = "max_video_frames"
        case tokensPerFrame = "tokens_per_frame"
    }

    init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.imageSize = try c.decode(Int.self, forKey: .imageSize)
        self.patchSize = try c.decode(Int.self, forKey: .patchSize)
        self.imageTokenCount = try c.decode(Int.self, forKey: .imageTokenCount)
        self.imageTokenId = try c.decode(Int32.self, forKey: .imageTokenId)
        self.imageMean = try c.decodeIfPresent([Double].self, forKey: .imageMean) ?? Self.clipMean
        self.imageStd = try c.decodeIfPresent([Double].self, forKey: .imageStd) ?? Self.clipStd
        self.rescaleFactor = try c.decodeIfPresent(Double.self, forKey: .rescaleFactor) ?? 1.0
        self.imageStrategy =
            try c.decodeIfPresent(ImageStrategy.self, forKey: .imageStrategy) ?? .stretch
        self.includeImageInfo = try c.decodeIfPresent(Bool.self, forKey: .includeImageInfo) ?? false
        self.maxVideoFrames = try c.decodeIfPresent(Int.self, forKey: .maxVideoFrames)
        self.tokensPerFrame = try c.decodeIfPresent(Int.self, forKey: .tokensPerFrame)
    }
}

#if canImport(CoreAI)
/// VLM configuration: text-side LLM config (ocoreai `InternalModelConfig`) +
/// vision-side `VisionConfig`. Mirrors upstream `VLMModelConfig`
/// (CoreAISequentialVLMEngine.swift L21-38), re-based on ocoreai's
/// `InferenceConfiguration` protocol (CoreAIEngine.swift L267).
@available(macOS 27.0, iOS 27.0, *)
struct VLMModelConfig: Codable, Sendable, InferenceConfiguration {
    let base: InternalModelConfig
    let visionConfig: VisionConfig

    var maxContextLength: Int { base.maxContextLength }
    var vocabSize: Int { base.vocabSize }
    var function: String { base.function }
    var name: String { base.name }
    var eosTokenId: Int32 { base.eosTokenId }

    var prefillChunkSize: Int { base.prefillChunkSize }
    var chunkThreshold: Int { base.chunkThreshold }

    /// Runtime override (applied by the engine init; ocoreai idiom — upstream
    /// `applyChunkingOverrides` mutates a `var` base config, but ocoreai's
    /// `InternalModelConfig` is `let`-based, so the override lives here).
    var prefillChunkSizeOverride: Int?
    var prefillChunkThresholdOverride: Int?

    /// Prefill chunk size — override wins, else base model config.
    var effectivePrefillChunkSize: Int { prefillChunkSizeOverride ?? prefillChunkSize }
    /// Chunk threshold — override wins, else base model config.
    var effectiveChunkThreshold: Int { prefillChunkThresholdOverride ?? chunkThreshold }

    init(
        base: InternalModelConfig,
        visionConfig: VisionConfig,
        prefillChunkSizeOverride: Int? = nil,
        prefillChunkThresholdOverride: Int? = nil
    ) {
        self.base = base
        self.visionConfig = visionConfig
        self.prefillChunkSizeOverride = prefillChunkSizeOverride
        self.prefillChunkThresholdOverride = prefillChunkThresholdOverride
    }
}
#endif  // canImport(CoreAI)
