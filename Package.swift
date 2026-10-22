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
        // in CHANGELOG.md; AGENTS.md keeps only the current pin and the transferable rules.
        // (docs/agent/upstream-audit-log.md was written once and deleted the same session:
        //  CHANGELOG.md already carries the round-by-round verdicts — one diary, one home.)
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "bb0d5b048"),
        // mlx-swift: pinned exact 0.32.3 (resolved revision 19601207e). This sentence is
        // gated against the pin below and against Package.resolved by
        // DependencyPinStatementTests — this sentence named 0.32.2 as the pin long after
        // 0.32.3 landed (bumped in 0401256), and no check read this file: a statement about
        // the contract that contradicted it (AGENTS.md invariant 1).
        //
        // Why this tag and not 0.32.2: upstream's own 0.32.2 release notes open with "Use
        // release 0.32.3", because an app linking 0.32.2 crashes at launch on macOS/iOS
        // < 26.4 (mlx-swift #491/#493) — which would flatly contradict this package's
        // declared platforms (macOS 14 / iOS 17). The floor argument stands as written
        // when it was about 0.32.2, but the floor has since moved under this sentence:
        // mlx-swift-lm #646 (c043fb3) raised its constraint to .upToNextMinor(from: 0.32.2)
        // and at the lm revision pinned above it reads 0.32.3, so 0.32.2 no longer resolves
        // here at all — lm's floor and this pin are now the same number.
        // anchor:mlx-swift-lm Package.swift:67 .upToNextMinor(from: "0.32.3")
        // DependencyPinStatementTests reads lm's floor out of the resolved checkout and goes
        // red when this sentence, the pin, or lm's constraint stop agreeing with each other.
        // The content that made that floor worth having is
        // in both: #450 (air64 Metal-thread-qualifier fix for steel/attn/mma.h) unblocks
        // IPHONEOS_DEPLOYMENT_TARGET=27, and cd36d17 makes mlx-c custom-io return bytes
        // read/written.
        //
        // Consumer-impact audit. Direct MLX surface = 10 sites / 5 APIs: 8 call+construct
        // sites across 5 APIs plus 2 MLXArray-typed properties. It is not the two calls an
        // earlier verdict here counted — asArray is called 4× (prompt-tail decode, std and
        // MTP paths, and the embedding path), and MLXArray itself is constructed there.
        // Every cite below is anchored, so make anchor-check (which scans this file too)
        // goes red when an edit moves one, instead of a cite drifting 214 lines as this
        // one did; DependencyPinStatementTests re-greps Sources and fails when this audit
        // stops being the set the code actually reaches.
// anchor:. Sources/ocoreai/Engine/EngineInference.swift:3611 asArray(Int32.self) -->
// anchor:. Sources/ocoreai/Engine/EngineInference.swift:3658 Stream.gpu.synchronize -->
// anchor:. Sources/ocoreai/Engine/EngineInference.swift:3871 asArray(Int32.self) -->
// anchor:. Sources/ocoreai/Engine/EngineInference.swift:5074 asArray(Int.self) -->
        // anchor:. Sources/ocoreai/Engine/EngineInferenceSupport.swift:153 MLXArray
// anchor:. Sources/ocoreai/Engine/MLXBridge.swift:1270 MLXArray( -->
// anchor:. Sources/ocoreai/Engine/MLXBridge.swift:1276 MLXArray.zeros -->
// anchor:. Sources/ocoreai/Engine/MLXBridge.swift:1282 result.eval -->
// anchor:. Sources/ocoreai/Engine/MLXBridge.swift:1284 asArray(Float.self) -->
        // All MLX *inference* flows through MLXLLM/MLXNN/MLXLMCommon; these 5 APIs are
        // where an MLX signature change lands in ocoreai's own code, so a bump audits
        // exactly these files. The 0.31→0.32 verdict holds for released versions (zero
        // consumers of the surface changed then: Device/withNewDefaultStream/convolve/
        // Distributed), and the lm #646 `Stream()→Stream.defaultStream()` rename sat in
        // lm's own Evaluate.swift, not here. Commits on unreleased main are a different
        // question: scripts/upstream-drift.sh now reports them per-file against these
        // APIs. Per-bump verdicts live in CHANGELOG.md; AGENTS.md § Upstream Audit
        // Dependencies keeps the current pins.
        .package(
            url: "https://github.com/ml-explore/mlx-swift.git",
            exact: "0.32.3"),
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
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                .linkedFramework("Testing"),
            ],
        ),
    ],
    cxxLanguageStandard: .cxx17
)
