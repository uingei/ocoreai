// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ocoreai",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "ocoreai", targets: ["ocoreai"])
    ],
    traits: [
        .trait(
            name: "appStore",
            description: "App Store build: disable HTTP server, use direct inference only"),
        // MLXFoundationModels adapter for Apple's FoundationModels framework.
        // Default-on. macOS 27 SDK: brings MLXLanguageModel/Executor etc;
        // macOS 15/26 SDK: compiles to empty — zero impact.
        .trait(
            name: "FoundationModelsIntegration",
            description:
                "Enables the MLXLanguageModel adapter for Apple's FoundationModels framework."
        ),
        .default(enabledTraits: ["FoundationModelsIntegration"]),
    ],
    dependencies: [
        // Hummingbird 2.x API (respond/to/passing: pattern)
        // ServiceLifecycle comes as transitive dependency — no need to declare explicitly
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.25.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.0"),
        // YAML config support
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        // NOTE: CoreAI, CoreAILanguageModels, CoreAIShared are macOS system frameworks,
        // not SwiftPM packages — imported directly in source via `#if canImport(CoreAI)` guards
        // Pinned to exact revision — upstream main branch drifts; update via `swift package update`
        // then bump .revision + test. Current pin: 2026-08-25 — @ 626516b.
        //
        // 1441444..626516b (4 commits, all verified consumer-transparent / free riders):
        //   - #564 (1970177): Fix mixed-precision QLoRA output promotion —
        //     LoRA+Layers.swift +8L internal promotion fix; no API change.
        //   - #570 (d3f28a8): Tune TurboFlash query grouping for short decode —
        //     TurboQuantKernels.swift internal kernel tuning; `.turboQuant`
        //     path ocoreai consumes gains it for free (no opt-in needed).
        //   - #565 (60985ee): Extensible VLM processor loading rules —
        //     NEW VLMProcessorLoadingRegistry (opt-in; default `.shared`
        //     resolution unchanged) + VLMModelFactory init gains defaulted
        //     `processorLoadingRegistry:` param. ocoreai's
        //     `VLMModelFactory.shared.loadContainer` call sites (MLXBridge
        //     L128/L547) are signature-compatible — no ocoreai change.
        //   - #567 (626516b): Share fused Qwen3.5 router top-k across LLM/VLM —
        //     new MLXLMCommon/MoERouterTopK.swift + Qwen35.swift refactor;
        //     model-specific internals, no ocoreai-facing API change.
        //   Exhaustiveness sweep: none of the 4 adds a public enum case on a
        //   type ocoreai switches over (grep `case .` in Sources/ vs
        //   Libraries/MLXLMCommon diff — no new Generation/TokenStreamEvent
        //   cases in range).
        //
        // d661402..1441444 (1 commit):
        //   - #544 (1441444): Fix MLXFoundationModels compilation against the
        //     Xcode 27 beta 5 SDK — `LanguageModelCapabilities(capabilities:)`
        //     label spelling (:565) + `ConvertibleToGeneratedContent` metadata
        //     dict type (:718). ocoreai has 0 true consumers of either symbol
        //     (grep-verified), but the module must COMPILE for ocoreai to build:
        //     β5 standalone builds prove d661402 FAILS (2 errors, above) and
        //     1441444 PASSES (Build complete). Unblocks local `swift build` /
        //     `swift test` verification on the macOS 27 beta SDK.
        //
        // b6ba48d..d661402 (2 commits, both verified consumer-transparent):
        //   - #375 (b6ba48d→130e3f0): reranker API — new MLXEmbedders/MLXRerankers
        //     surface + Reranker.swift; ocoreai has ZERO reranker references
        //     (grep-verified), pure free rider.
        //   - #562 (d661402): load weight files a safetensors index leaves out —
        //     additive weight-loading behavior (Load.swift +147); no signature
        //     break in any API ocoreai consumes.
        //
        // 7871b09..b6ba48d (7 commits, all verified consumer-transparent or free riders):
        //   - #556 (95cc8b8): Muse Glimmer honors requested KV-cache capacity —
        //     also fixes upstream #544 (MLXLanguageModel.swift:1890/:1943 no longer
        //     die on Xcode 27 beta 5 SDK) — unblocks local build verification.
        //   - #559 (99c0e5f): GenerateCompletionInfo + `cachedPromptTokenCount` /
        //     `totalPromptTokenCount` (defaulted init — existing call sites unaffected).
        //     NEW consumer-facing metric: prompt tokens served by a reused KV prefix.
        //   - #549 (72d9fdb): SessionPool prompt-cache reuse for text-only inputs —
        //     upstream-internal reuse activation; ocoreai's pool slots gain it for free.
        //   - #507 (2b39bab): opt-in q4_0 lattice calibration (model conversion only —
        //     new `ModelConversionError.incompatibleCalibration` case; ocoreai does no
        //     model conversion, never switches this enum).
        //   - #555 (4c21bf6): Helium (Kyutai) LLM port — model-specific, no API change.
        //   - #557 (3c5805a): Gemma brace-form object/array value parsing — model-specific.
        //   - #541 (b6ba48d): LoRA dropout + training mode — LoRA public signatures
        //     unchanged (LoRAContainer.from / LoRATrain.train / Parameters all
        //     backward-compatible; `Parameters.completedIterations` added with default).
        //     ModelContext now normalizes the module tree to eval mode at the
        //     inference boundary (model.train(false)) — free correctness fix for
        //     LoRA+dropout inference in LLMLifecycleHandler.
        // Re-evaluate at each upstream main bump: re-grep `Generation` switch
        // sites and confirm exhaustiveness before building.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "626516b"),
        // HuggingFace Hub SDK — native search & download
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        // swift-transformers: Tokenizers library (required for @huggingFaceTokenizerLoader)
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.3"),
        // xgrammar: GPU grammar bitmask source (C++ core; consumed via local CXGrammar C bridge).
        // Same pin as coreai-models upstream (absorbed #146 0bc7bc3 + #170 031cb54).
        .package(url: "https://github.com/mlc-ai/xgrammar", exact: "0.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "ocoreai",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Yams", package: "yams"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
                // MLXFoundationModels: bridges Apple's FoundationModels framework to MLX.
                // Trait-conditional (upstream precedent: mlx-swift-lm Package.swift L173/258/272
                // use the same `condition: .when(traits:)` inside its own targets): the product
                // is linked ONLY when FoundationModelsIntegration is enabled, so
                // `swift build --traits -FoundationModelsIntegration` builds ocoreai without
                // touching the FM adapter — the opt-out is real, not decorative.
                // On macOS 26 SDK the adapter compiles to an empty library; on the 27 SDK it
                // brings MLXLanguageModel, MLXDownloadProgress, AllowedToolOutputRouter,
                // TranscriptConverter, SchemaConverter, SamplingModeMapper,
                // ModelConfigurationResolver, and ModelDescriptor.
                .product(
                    name: "MLXFoundationModels",
                    package: "mlx-swift-lm",
                    condition: .when(traits: ["FoundationModelsIntegration"])
                ),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                "CXGrammar",
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // MLX is always enabled — it's a hard dependency, not an optional trait.
                // .define("mlx") kept for backward compatibility with any #if mlx guards
                // that may still exist in source.
                .define("mlx"),
                // Lifetimes required for CoreAI @_lifetime attributes in StateHandler+MTLBuffer
                .enableExperimentalFeature("Lifetimes"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
                // CoreAI and FoundationModels are #if canImport-guarded in source,
                // so the compiler drops them when the SDK lacks the framework —
                // no -weak_framework linker flag needed (aligned with mlx-swift-lm).
            ],
        ),
        // CXGrammar C bridge — Apple-authored C shim over the xgrammar C++ core
        // (copied from coreai-models swift/Sources/lib/CXGrammar, byte-identical).
        .target(
            name: "CXGrammar",
            dependencies: [
                .product(name: "XGrammar", package: "xgrammar")
            ],
            path: "Sources/lib/CXGrammar",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("c++")
            ]
        ),
        // Shared test utilities — mocks, fixtures, helpers, tags
        .target(
            name: "ocoreaiTestUtilities",
            dependencies: [
                "ocoreai"
            ],
            path: "Tests/ocoreaiTestUtilities",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .define("mlx"),
            ],
        ),
        .testTarget(
            name: "ocoreaiTests",
            dependencies: [
                "ocoreai",
                "ocoreaiTestUtilities",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks"]
                ),
            ],
            linkerSettings: [
                .unsafeFlags(["-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks"]
                ),
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
                .linkedFramework("Testing"),
            ],
        ),
    ],
    cxxLanguageStandard: .cxx17
)
