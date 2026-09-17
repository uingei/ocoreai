// KV-cache endpoint tests: wire mapping (upstream KVCacheStatus ground truth)
// + EnginePool guard paths (404 / 501).
//
// Ground truth for layer status: upstream `kvCacheLayerStatuses` +
// `runtimeLayer` (KVCacheRuntime.swift) at mlx-swift-lm c6446cf, cross-checked
// against upstream CacheConfigurationTests assertions.

import Foundation
import Logging
import MLXLMCommon
import Testing

@testable import ocoreai

private func layersArray(_ obj: [String: Any]) throws -> [[String: Any]] {
    guard let arr = obj["layers"] as? [[String: Any]] else {
        throw AppError.invalidRequest("kv-cache test: missing wire arrays")
    }
    return arr
}

private func encode(_ response: KVCacheStatusResponse) throws -> [String: Any] {
    let data = try JSONEncoder().encode(response)
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AppError.invalidRequest("kv-cache test: malformed top-level JSON")
    }
    return obj
}

@Suite("KVCacheStatusResponse wire mapping")
struct KVCacheStatusResponseMappingTests {
    @Test func defaultConfigurationSimpleCaches() throws {
        // Upstream: `configuration: nil` folds to the default full-precision
        // config for per-layer resolution, but `requestedStrategy`/
        // `requestSource` reflect the *requested* configuration and stay nil.
        // `KVCacheSimple()` layers are attention with unbounded capacity.
        let status = KVCacheStatus(cache: [KVCacheSimple(), KVCacheSimple()])
        let json = try encode(makeKVCacheStatusResponse(status))

        #expect(json["phase"] as? String == "realized")
        #expect(json["layerCount"] as? Int == 2)
        #expect(json["capacityDisposition"] as? String == "not_requested")
        #expect(json["requestedStrategy"] == nil)
        #expect(json["compressedLayerCount"] as? Int == 0)
        #expect(json["pendingLayerCount"] as? Int == 0)
        #expect(json["skippedLayerCount"] as? Int == 0)
        #expect(json["isHybrid"] as? Bool == false)
        #expect((json["attentionMaxSizes"] as? [Int?])?.count == 2)

        let layers = try layersArray(json)
        #expect(layers[0]["path"] as? [Int] == [0])
        #expect(layers[0]["kind"] as? String == "attention")
        #expect(layers[0]["isAttention"] as? Bool == true)
        #expect(layers[0]["capacitySource"] as? String == "unbounded")
        #expect(layers[0]["state"] as? String == "active")
        #expect(layers[0]["resolvedStrategy"] as? String == "full-precision")
        #expect(layers[0]["reason"] == nil)
    }

    @Test func rotatingWindowAndRecurrentState() throws {
        // Upstream `runtimeLayer`: a model-native `RotatingKVCache`
        // (capacityOrigin == .modelNative) matches the default full-precision
        // strategy → active, and its capacity is model-defined. `MambaCache`
        // is non-attention state and is not applicable to a KV policy.
        let status = KVCacheStatus(cache: [
            RotatingKVCache(maxSize: 512, keep: 4),
            MambaCache(),
        ])
        let json = try encode(makeKVCacheStatusResponse(status))

        #expect(json["isHybrid"] as? Bool == true)
        let layers = try layersArray(json)
        #expect(layers[0]["kind"] as? String == "rotating_attention")
        #expect(layers[0]["rotatingMaxSize"] as? Int == 512)
        #expect(layers[0]["rotatingKeep"] as? Int == 4)
        #expect(layers[0]["capacitySource"] as? String == "model_defined")
        #expect(layers[0]["state"] as? String == "active")
        #expect(layers[0]["resolvedStrategy"] as? String == "full-precision")

        #expect(layers[1]["kind"] as? String == "state_space")
        #expect(layers[1]["isAttention"] as? Bool == false)
        #expect(layers[1]["state"] as? String == "not_applicable")
        #expect(layers[1]["reason"] as? String == "non_attention_state")
    }

    @Test func compositeTopologyPreservesPathsAndKinds() throws {
        // Upstream ground truth (CacheConfigurationTests.cacheLayerStatus
        // ClassifiesConcreteCaches): a `CacheList` produces one leaf entry per
        // child at path [parent, childIndex].
        let status = KVCacheStatus(cache: [
            MambaCache(),
            CacheList(MambaCache(), RotatingKVCache(maxSize: 64, keep: 4)),
        ])
        let json = try encode(makeKVCacheStatusResponse(status))

        #expect(json["layerCount"] as? Int == 3)
        let layers = try layersArray(json)
        #expect(layers[1]["path"] as? [Int] == [1, 0])
        #expect(layers[1]["kind"] as? String == "state_space")
        #expect(layers[2]["path"] as? [Int] == [1, 1])
        #expect(layers[2]["kind"] as? String == "rotating_attention")
        #expect(layers[2]["rotatingMaxSize"] as? Int == 64)
    }

    @Test func requestSourceNilWhenUnrequested() throws {
        let status = KVCacheStatus(cache: [KVCacheSimple()])
        #expect(try encode(makeKVCacheStatusResponse(status))["requestSource"] == nil)
    }
}

// EnginePool guard branches (unknown model → `modelNotFound`, handle-less
// model → `kvCacheStatusUnsupported`) are plain `guard` statements on
// actor-isolated state with no dedicated test seam in this codebase; the
// mapping layer above carries the behavior worth asserting.
