import Foundation
import MLXLMCommon
import Testing

@testable import ocoreai

/// A caller's KV capacity reaches the engine as a typed capacity, and never as a legacy field.
///
/// Why this exists (measured 11-28, live `serve`): `max_kv_size` is a wire field on both chat
/// faces and the GUI's per-model "Max KV" box, and every request that set it died before the
/// first token with HTTP 500 quoting upstream's own sentence, "Set either
/// GenerateParameters.kvCache or the legacy KV-cache fields, not both". `makeGenerateParameters`
/// set `params.maxKVSize` beside the typed `kvCache` that `8f83f42e` (10-22) made unconditional,
/// and upstream's `resolvedKVCacheConfiguration` refuses the pair. A model whose stored sampling
/// config carried `max_kv_size: 0` failed every turn after that, because the model-sampling PATCH
/// face accepts the value without a domain check.
///
/// The gates that existed here all decoded the field (`ChatCompletionRequestWireCompletenessTests`,
/// `ModelSamplingPatchDecodeMapTests`) and none ever sent it, which is how a dead field stayed
/// green for five weeks. So this asserts the object our code hands upstream: capacity typed, no
/// legacy field beside it. Weight-free.
struct KVCapacityDeliveryTests {

    private func parameters(_ sampling: SamplingConfiguration) -> GenerateParameters {
        makeGenerateParameters(from: sampling, maxTokens: 16)
    }

    @Test(
        "a requested capacity arrives typed, with upstream's own prefix mapping",
        arguments: [(1, 0), (3, 2), (5, 4), (2048, 4), (65_536, 4)]
    )
    func capacityArrivesTyped(requested: Int, preservedPrefix: Int) {
        let params = parameters(SamplingConfiguration(temperature: 0, maxKVSize: requested))
        #expect(params.kvCache?.capacity?.maxTokens == requested)
        // `KVCachePlan.legacyKVCacheCapacity` maps maxKVSize to min(4, maxKVSize-1); matching it
        // keeps the restored field's semantics what the field had before it broke.
        #expect(params.kvCache?.capacity?.preservedPrefixTokens == preservedPrefix)
    }

    @Test(
        "no legacy KV field is ever set beside the typed configuration",
        arguments: [nil, 1, 512, 2048]
    )
    func legacyFieldsStayUnset(maxKVSize: Int?) {
        let params = parameters(SamplingConfiguration(temperature: 0, maxKVSize: maxKVSize))
        #expect(params.kvCache != nil)
        #expect(params.maxKVSize == nil)
        #expect(params.kvBits == nil)
        #expect(params.kvScheme == nil)
        #expect(params.kvGroupSize == 64)
        #expect(params.quantizedKVStart == 0)
    }

    @Test("an absent request invents no capacity")
    func absentCapacityStaysAbsent() {
        let params = parameters(SamplingConfiguration(temperature: 0))
        #expect(params.kvCache?.capacity == nil)
    }

    /// A bounded cache makes every attention layer rotating, and a rotating cache satisfies
    /// no compression strategy, so a request that bounds the cache has nothing left to
    /// compress. Upstream's own legacy route answered that with partial application; the
    /// strict policy would turn it into a 500 ("KV-cache strategy turbo-quant is not
    /// supported by any attention layer", measured 11-28 the first time this pair ran).
    @Test(
        "a bounded cache accepts partial compression; an unbounded one demands it",
        arguments: [
            (
                Knob.unbounded,
                MLXLMCommon.KVCacheConfiguration.CompatibilityPolicy
                    .requireAtLeastOneLayer
            ),
            (Knob.bounded, MLXLMCommon.KVCacheConfiguration.CompatibilityPolicy.allowPartial),
        ]
    )
    func compatibilityFollowsCapacity(
        capacity: Knob, expectedPolicy: MLXLMCommon.KVCacheConfiguration.CompatibilityPolicy
    ) throws {
        let resolved = try #require(
            makeKVCacheConfiguration(
                kvCacheQuant: KVCacheQuantizationConfig(enabled: true),
                fallbackBits: nil,
                fallbackGroupSize: 64,
                fallbackQuantizedKVStart: 0,
                fallbackScheme: "turbo4",
                capacityTokens: capacity.tokens
            ))
        #expect(resolved.compatibility == expectedPolicy)
    }

    enum Knob: CaseIterable {
        case unbounded, bounded
        var tokens: Int? { self == .bounded ? 2048 : nil }
    }

    /// The exit that used to `return nil`: compression switched off globally. Dropping the
    /// configuration there would drop the caller's capacity with it, silently.
    @Test("compression switched off still carries the requested capacity")
    func disabledQuantizationKeepsCapacity() throws {
        let config = KVCacheQuantizationConfig(enabled: false)
        let resolved = makeKVCacheConfiguration(
            kvCacheQuant: config,
            fallbackBits: nil,
            fallbackGroupSize: 64,
            fallbackQuantizedKVStart: 0,
            fallbackScheme: nil,
            capacityTokens: 1536
        )
        #expect(resolved?.capacity?.maxTokens == 1536)
        #expect(resolved?.strategy.identifier.rawValue == "full-precision")
        // Without a requested capacity this exit is what it always was: nothing configured.
        let unrequested = makeKVCacheConfiguration(
            kvCacheQuant: config,
            fallbackBits: nil,
            fallbackGroupSize: 64,
            fallbackQuantizedKVStart: 0,
            fallbackScheme: nil
        )
        #expect(unrequested == nil)
    }

    /// Three exits from the resolver (authored config, sampling-level `kvBits`, unquantized);
    /// each must carry both the reserve and the capacity, so the pair is asserted per exit
    /// rather than counted in source text.
    @Test(
        "every resolver exit carries the capacity and the reserve",
        arguments: [ResolverExit.authored, .fallbackBits, .unquantized]
    )
    func everyExitCarriesBoth(exit: ResolverExit) {
        let resolved = makeKVCacheConfiguration(
            kvCacheQuant: exit.kvCacheQuant,
            fallbackBits: exit.fallbackBits,
            fallbackGroupSize: 64,
            fallbackQuantizedKVStart: 0,
            fallbackScheme: exit.kvCacheQuant?.kvScheme,
            capacityTokens: 777
        )
        #expect(resolved?.capacity?.maxTokens == 777)
        #expect(resolved?.rewind?.maxTokens == kvCacheRewindReserveTokens)
    }

    enum ResolverExit: CaseIterable {
        case authored, fallbackBits, unquantized

        var kvCacheQuant: KVCacheQuantizationConfig? {
            switch self {
            case .authored: KVCacheQuantizationConfig(enabled: true)
            case .fallbackBits, .unquantized: nil
            }
        }

        var fallbackBits: Int? {
            switch self {
            case .authored, .unquantized: nil
            case .fallbackBits: 4
            }
        }
    }
}
