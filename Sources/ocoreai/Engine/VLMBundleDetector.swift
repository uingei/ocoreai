// Provenance: coreai-models (BSD-3-clause, Apple) — absorbed 2026-09-16.
//   Upstream:
//     CoreAIShared/Bundle/ModelBundle.swift  — ComponentKey.main/vision/embedding,
//                                              modelURL(for:), requireModelURL(for:),
//                                              resolveAssetURL (.aimodel → .aimodelc)
//     CoreAILanguageModels/Bundle/LanguageBundle.swift — kind == .vlm check (L52-53),
//                                                        visionConfig guard, componentKeys
//   Upstream pin: coreai-models 7359dbc (origin/main, 2026-09-11 sync)
//
// ocoreai is NOT a SwiftPM-dependency on coreai-models (in-tree engine).
//   This file provides the minimal VLM-bundle detection + component-path
//   resolution surface needed by `EngineFactory.createVLMEngine` to dispatch
//   ANE+multimodal requests to `CoreAISequentialVLMEngine` (in-tree, 1241 L).
//
// Pure Foundation (no CoreAI import) — testable on all macOS/iOS versions.
// `VisionConfig` is declared un-gated in `CoreAIVisionConfig.swift` (L14-110).

import Foundation

/// VLM bundle metadata — the minimal subset of the upstream 0.2 `metadata.json`
/// schema needed to detect a VLM bundle and resolve its component asset paths.
///
/// Upstream contract (`coreai-models` `ModelBundle` 0.2 + `LanguageBundle`):
/// A VLM bundle declares THREE asset roles in its `assets` map:
/// `"main"` (LLM decoder), `"vision"` (vision encoder+projector), and
/// `"embedding"` (token-embedding lookup function). The `LanguageBundle`
/// `kind == .vlm` guard (L52-53) is equivalent to requiring BOTH `"vision"`
/// AND `"embedding"` keys to be present in `assets`.
///
/// ```json
/// {
///   "name": "gemma-4-e2b",
///   "assets": {
///     "main":      "gemma4e2b.main.aimodel",
///     "vision":    "gemma4e2b.vision.aimodel",
///     "embedding": "gemma4e2b.embed.aimodel"
///   },
///   "vision": {
///     "image_size": 896,
///     "patch_size": 14,
///     "image_token_count": 256,
///     "image_token_id": 262140
///   }
/// }
/// ```
struct VLMBundleMetadata: Sendable {
    let name: String

    /// Asset role → filename map. A VLM bundle must declare both
    /// `vision` and `embedding` in addition to `main`.
    let assets: [String: String]

    /// Parsed `vision` block from `metadata.json`. May be nil — the VLM
    /// engine falls back to CLIP-default `VisionConfig` defaults.
    ///
    /// Upstream: `LanguageBundle.visionConfig` guard — `kind == .vlm &&
    /// visionConfig == nil` → throws `missingField("vision")`. ocoreai
    /// relaxes this to `nil` so a VLM bundle with a malformed vision block
    /// is still detected and routed; the engine init will surface the error.
    let visionConfig: VisionConfig?

    /// Whether this bundle is a vision-language model
    /// (upstream `LanguageBundle` `kind == .vlm` → both `vision` and
    /// `embedding` asset keys present).
    var isVLMBundle: Bool {
        assets[Self.assetVision] != nil && assets[Self.assetEmbedding] != nil
    }

    // MARK: - Component keys (mirrors upstream `ModelBundle.ComponentKey`)

    static let assetMain = "main"
    static let assetVision = "vision"
    static let assetEmbedding = "embedding"

    /// Resolve a component's file path within the bundle directory.
    ///
    /// Falls back to the compiled (`.aimodelc`) variant if the declared
    /// `.aimodel` path does not exist on disk (post-`coreai-build compile`).
    /// Returns `nil` if no variant is found.
    ///
    /// Mirrors upstream `ModelBundle.modelURL(for:)` (L52-58) +
    /// `resolveAssetURL` (.aimodel → .aimodelc fallback).
    func componentPath(_ key: String, in bundleURL: URL) -> URL? {
        guard let assetName = assets[key] else { return nil }
        let fm = FileManager.default
        let direct = bundleURL.appendingPathComponent(assetName)
        if fm.fileExists(atPath: direct.path) { return direct }
        if assetName.hasSuffix(".aimodel") {
            let compiled = bundleURL.appendingPathComponent(assetName + "c")
            if fm.fileExists(atPath: compiled.path) { return compiled }
        }
        return nil
    }
}

extension VLMBundleMetadata: Decodable {
    private enum CodingKeys: String, CodingKey {
        case name, assets, vision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Each field is decoded independently so a malformed `vision` block
        // doesn't prevent VLM detection (falls back to `visionConfig == nil`).
        name = (try? c.decode(String.self, forKey: .name)) ?? "unknown"
        assets = (try? c.decode([String: String].self, forKey: .assets)) ?? [:]
        do {
            visionConfig = try c.decodeIfPresent(VisionConfig.self, forKey: .vision)
        } catch {
            visionConfig = nil
        }
    }
}

/// VLM bundle detector — reads and validates `metadata.json` in a model directory.
///
/// All methods return `nil` (never throw) when the directory is not a VLM
/// bundle, so callers use an `if let` guard:
///
/// ```swift
/// if let vlmBundle = VLMBundleDetector.load(at: modelURL) {
///     let engine = try await EngineFactory.createVLMEngine(
///         metadata: vlmBundle, bundleURL: modelURL,
///         config: configData, options: engineOptions
///     )
/// }
/// ```
enum VLMBundleDetector {
    static let metadataFilename = "metadata.json"

    /// Attempt to load VLM bundle metadata from a model directory.
    ///
    /// Returns `nil` (does NOT throw) when any of the following is true:
    ///   - `metadata.json` is absent or unreadable
    ///   - `assets` map is absent or empty
    ///   - `assets` does not contain both `vision` and `embedding` keys
    ///
    /// Does NOT validate the presence of the actual `.aimodel` files —
    /// that is `EngineFactory.createVLMEngine`'s job (runtime validation).
    static func load(at bundleURL: URL) -> VLMBundleMetadata? {
        let fm = FileManager.default
        let metaPath = bundleURL.appendingPathComponent(metadataFilename)
        guard fm.fileExists(atPath: metaPath.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: metaPath) } catch { return nil }
        let metadata: VLMBundleMetadata
        do { metadata = try JSONDecoder().decode(VLMBundleMetadata.self, from: data) } catch {
            return nil
        }
        guard metadata.isVLMBundle else { return nil }
        return metadata
    }

    /// Quick predicate: is `url` a VLM bundle directory?
    static func isVLMBundle(at url: URL) -> Bool {
        load(at: url) != nil
    }
}
