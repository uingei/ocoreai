# Engine line cites — markers, out of the guide

The host injects root `AGENTS.md` plus every `AGENTS.md` to the cwd, truncated at
32 KiB (B2, `scripts/agents-md-contract.sh`). `make anchor-check` and `make docs-check` P3 both
sweep `docs/agent/*.md`, so one hop out loses nothing.

<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:195 Task.sleep(until: deadline -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:1432 Float.leastNormalMagnitude -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:3073 SteerQueue.shared.drain -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:3806 SteerQueue.shared.drain -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInferenceSupport.swift:116 .applyingThinkingBudget -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:4412 components: thinkingComponents -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:4406 answerOnly: true -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:3914 components: mtpGenComponents -->
<!-- anchor:. Sources/ocoreai/Engine/MLXBridge.swift:889 case "affine" -->
<!-- anchor:. Sources/ocoreai/Engine/SessionPool.swift:1566 static func rewindHistoryEnd -->
<!-- anchor:. Sources/ocoreai/Engine/SessionPool.swift:687 Self.rewindHistoryEnd( -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:3266 rewind.source.session.fork( -->
<!-- anchor:. Sources/ocoreai/Engine/MLXBridge.swift:913 let kvCacheRewindReserveTokens = 1024 -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/Chat.swift:14 public struct Message { -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/UserInput.swift:131 public struct Image { -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:2128 func fork(history -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:361 func requirePlan -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/KVCache.swift:997 var maxTrimCount -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:2200 func saveCache -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:1354 templateMessages = leadingMessages -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:1684 reasoning: modelConfiguration.reasoningConfig.map -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/Evaluate.swift:2589 reasoning: context.configuration.reasoningConfig.map -->
<!-- anchor:mlx-swift-lm Libraries/MLXFoundationModels/MLXLanguageModel.swift:37 capabilities: [.guidedGeneration, .toolCalling], -->
<!-- anchor:mlx-swift-lm Libraries/MLXFoundationModels/MLXLanguageModel.swift:326 capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration] -->
<!-- anchor:mlx-swift-lm Libraries/MLXFoundationModels/MLXLanguageModel.swift:722 model.capabilities.contains(.vision) -->
