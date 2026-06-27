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
        .trait(name: "mlx", description: "Enable MLX backend (macOS 15+)"),
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
        // MLX 推理框架 — semver 锁定（原 branch: "main" 会飘）
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3"),
        // HuggingFace Hub SDK — 原生搜索、下载
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.8.1"),
        // swift-transformers: 提供 Tokenizers 库（#huggingFaceTokenizerLoader 宏展开依赖）
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.3"),
        // swift-testing: Swift 6 CLI 工具链需要此包提供 _TestingInternals 模块
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.11.0"),
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
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-warnings-as-errors"])
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ],
        ),
        // NOTE: testing target — uses Xcode Testing framework (@Suite/@Test)
        //       guarded with #if canImport(Testing) so main target builds regardless
        .testTarget(
     	name: "ocoreaiTests",
     	dependencies: [
     		"ocoreai",
     	],
     	swiftSettings: [
     		.swiftLanguageMode(.v6),
     	],
        ),
        ]
        )
