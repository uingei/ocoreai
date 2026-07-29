// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ocoreai",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "ocoreai", targets: ["ocoreai"]),
    ],
    traits: [
        .trait(name: "appStore", description: "App Store build: disable HTTP server, use direct inference only"),
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
        // then bump .revision + test. Current pin: 2026-07-28 — guided gen comma-drop fix (#465),
        // GLM4MOE routing tests (#463), FoundationModels test gating (#478), TurboQuant KV cache,
        // Gemma 4 MTP spec decode, Qwen3.5 M-RoPE, Gemma3 surface, EOS nesting, memory leak fixes.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "a65e78f"),
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
                .process("PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // MLX is always enabled — it's a hard dependency, not an optional trait.
                // .define("mlx") kept for backward compatibility with any #if mlx guards
                // that may still exist in source.
                .define("mlx"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ],
        ),
        // Shared test utilities — mocks, fixtures, helpers, tags
        .target(
            name: "ocoreaiTestUtilities",
            dependencies: [
                "ocoreai",
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
                .unsafeFlags(["-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"]),
                .linkedFramework("Testing"),
            ],
        ),
    ]
)
