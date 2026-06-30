// swift-tools-version: 6.3

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
        .trait(name: "coreai", description: "Enable CoreAI backend (macOS 27+)"),
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
        // not SwiftPM packages — imported directly in source via `#if coreai` guards
        // Pinned to exact revision — upstream main branch drifts; update via `swift package update`
        // then bump .revision + test. Current pin: 2026-06-29 build-verified commit.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57"),
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
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // MLX is always enabled — it's a real dependency, not an optional trait.
                // The `mlx` swift flag keeps existing `#if mlx` guards functional.
                .define("mlx"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ],
        ),
        .testTarget(
            name: "ocoreaiTests",
            dependencies: [
                "ocoreai",
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
