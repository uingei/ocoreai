# Engine line cites. Markers, out of the guide

The host injects root `AGENTS.md` plus every `AGENTS.md` to the cwd, truncated at
32 KiB (`WorkspaceContext.maxDocBytes`). The gates that checked these cites retired 11-16 with the bespoke docs contract,
sweep `docs/agent/*.md`, so one hop out loses nothing. Markers carry `anchor:<tree> <path> <quoted sentence>`, no line
number: a re-number measured 11-27 found 19 of 28 live `anchor:mlx-swift-lm` numbers (and 8 of 13 in-tree ones) already
wrong at pin `bf5a5d438` while no reader checked them — the quoted sentence is the part a re-read greps (the ruling the
marker convention already states, `competitor-iteration-paths.md`); `Package.swift` keeps its numbered form (its
premise-floor reader is live, `DependencyPinStatementTests`) and `closed-items-log.md` stays frozen.

<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift Task.sleep(until: deadline -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift Float.leastNormalMagnitude -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift SteerQueue.shared.drain -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift SteerQueue.shared.drain -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInferenceSupport.swift .applyingThinkingBudget -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift components: thinkingComponents -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift answerOnly: true -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift components: mtpGenComponents -->
<!-- anchor:. Sources/ocoreai/Engine/MLXBridge.swift case "affine" -->
<!-- anchor:. Sources/ocoreai/Engine/SessionPool.swift static func rewindHistoryEnd -->
<!-- anchor:. Sources/ocoreai/Engine/SessionPool.swift Self.rewindHistoryEnd( -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift rewind.source.session.fork( -->
<!-- anchor:. Sources/ocoreai/Engine/MLXBridge.swift let kvCacheRewindReserveTokens = kvCacheRewindReserveResolution -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/Chat.swift public struct Message { -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/UserInput.swift public struct Image { -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift func fork(history -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift func requirePlan -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/KVCache.swift var maxTrimCount -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift func saveCache -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift templateMessages = leadingMessages -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift reasoning: modelConfiguration.reasoningConfig.map -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift restart: while !pendingMessages.isEmpty { -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift public func steer( -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift throw RejectedToolCallError(rejection) -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/Evaluate.swift reasoning: context.configuration.reasoningConfig.map -->
<!-- anchor:mlx-swift-lm Libraries/MLXFoundationModels/MLXLanguageModel.swift capabilities: [.guidedGeneration, .toolCalling], -->
<!-- anchor:mlx-swift-lm Libraries/MLXFoundationModels/MLXLanguageModel.swift capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration] -->
<!-- anchor:mlx-swift-lm Libraries/MLXFoundationModels/MLXLanguageModel.swift model.capabilities.contains(.vision) -->
