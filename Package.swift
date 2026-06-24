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
        // MLX 推理框架 — 始终追踪 main 分支最新
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main"),
        // HuggingFace Hub SDK + Tokenizers — 原生搜索、下载、tokenizer 加载
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.8.1"),
        // NOTE: swift-testing 0.x requires swift-syntax 600.x, incompatible with
        //       MLX's swift-syntax 602-604 requirement. Testing tests are guarded
        //       with #if canImport(Testing) so main target builds regardless.
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
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            // NOTE: PrivacyInfo.xcprivacy resource removed — file does not exist yet.
            //            resources: [
            //                .process("PrivacyInfo.xcprivacy"),
            //            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-warnings-as-errors"])
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ],
        ),
        // NOTE: testTarget temporarily removed — Tests/ directory is empty.
        //        Add back when test files land in Tests/ocoreaiTests/.
    ]
)
