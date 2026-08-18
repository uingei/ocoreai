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
        // then bump .revision + test. Current pin: 2026-08-18 — @ 7871b09.
        //
        // d667610→d7dc03d was blocked by upstream #512 self-injury: d7dc03d added
        // `.rejectedToolCall` to `TokenStreamEvent`, but MLXLanguageModel.swift:1890/:1943
        // `switch event` sites omitted it (build-fail under FoundationModelsIntegration
        // + macOS 27 SDK). Upstream a72fcec (#538, "Handle Generation.rejectedToolCall
        // and add an Xcode 27 compile check", 2026-08-17) fixed all ten exhaustive
        // switches across Generation/TokenStreamEvent and added CI job
        // `integration_build_xcode27`. d7dc03d..7871b09 also: #531 tool call parser
        // hardening, #546 Qwen3.5 VLM fallback, #509 Qwen2.5-VL cuSeqlens, #527 nested
        // tool grammar test, #538 above.
        //
        // Consequence for ocoreai (consumed at this pin):
        //   - `Generation` gained case `.rejectedToolCall(RejectedToolCall)` —
        //     handled at EngineInference.swift:2981 (MTP path) and :3590
        //     (standard ChatSession path); logged, not thrown: a rejected call is
        //     a protocol anomaly on the no-tools path, surfacing it as a fatal
        //     error would drop legitimate text output.
        //   - `GenerateCompletionInfo` + `rejectedToolCallCount: Int = 0`
        //     (defaulted init — existing call sites unaffected).
        //   - `ChatSession.stream(to:)`/`stream(messages:)` now throw
        //     `RejectedToolCallError` internally (failOnRejectedToolCall: true);
        //     ocoreai uses `streamDetails` (emits the case in-stream) — fine.
        //   - `ModelConfiguration` + `messageGenerator` (defaulted nil) + `==`
        //     rewrite — both uses in ocoreai (EnginePool:495, MLXBridge:519/534)
        //     use `ModelConfiguration(id:)` — unaffected.
        // Re-evaluate at each upstream main bump: re-grep `Generation` switch
        // sites and confirm exhaustiveness before building.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "7871b09"),
        // HuggingFace Hub SDK — native search & download
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        // swift-transformers: Tokenizers library (required for @huggingFaceTokenizerLoader)
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.3"),
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
                // Gated by #if FoundationModelsIntegration + canImport(FoundationModels, _version: 2).
                // On macOS 26 SDK this compiles to an empty library — zero impact.
                // On macOS 27 SDK it brings in MLXLanguageModel, MLXDownloadProgress,
                // AllowedToolOutputRouter, TranscriptConverter, SchemaConverter, SamplingModeMapper,
                // ModelConfigurationResolver, and ModelDescriptor.
                .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
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
    ]
)
