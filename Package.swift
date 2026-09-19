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
        // Pin policy: follow mlx-swift-lm origin/main exactly (no semver -- this repo
        // ships no stable API; we want HEAD, not a floor). Bump protocol:
        // `git log <old>..origin/main` -> audit consumer impact -> bump .revision ->
        // `swift build` + `swift test` (make test-ci). The per-bump audit trail lives
        // in AGENTS.md ("Upstream Audit Dependencies") + CHANGELOG.md, not in this file.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "c6446cf"),
        // mlx-swift: pin to upstream main (pre-release, no tag >0.31.6).
        // #450 "update for mlx v0.32.2" (air64 Metal-thread-qualifier fix for
        // steel/attn/mma.h) is the floor that unblocks IPHONEOS_DEPLOYMENT_TARGET=27
        // (15 Cmlx errors at frag_at/elems address-space binding otherwise).
        // Now bumped to main 90194196 (#477 era) to absorb the runtime hot-path fixes
        // that matter for long-running agentic inference on Apple Silicon:
        //   #472 "pool Streams, fix Device inheritance" (mlx#2118) — Streams are finite
        //         and leak OS/Metal resources; a pool reuses them. Device now Hashable
        //         and `.gpu(index:)` inheritance works in all cases.
        //   #471 "Fix wired-memory ticket lifecycle during cancellation" — avoids
        //         dangling wired-memory tickets when a decode task is cancelled.
        // Consumer-impact audit: ocoreai has ZERO direct consumers of the changed
        // public surface (Device.deviceType, withNewDefaultStream, convolve,
        // Distributed) — all MLX access flows through MLXLM/MLXNN/MLXLMCommon, so
        // the Device-type change (Optional→non-Optional equipmentType, Hashable) is
        // transparent. See AGENTS.md "Upstream Audit Dependencies" + CHANGELOG.md.
        // This is a revision pin (not a fork): once mlx-swift tags >=0.31.7 carrying
        // #450, this line can be deleted and the constraint inherits via
        // mlx-swift-lm's .upToNextMinor(from:"0.31.6").
        .package(
            url: "https://github.com/ml-explore/mlx-swift.git",
            revision: "901941965d82e4a216d4d117231d847d194c563d"),
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
