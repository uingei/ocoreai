// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineManager.swift — Umbrella module for the engine subsystem
///
/// After the p2-enginemgr refactor this file is intentionally minimal. The real
/// implementation lives in these files:
///
/// | File                | Responsibility                             |
/// |---------------------|--------------------------------------------|
/// | BackendProtocol     | Backend abstraction protocol               |
/// | EngineConfig        | EnginePoolConfig struct                    |
/// | EngineEvents        | InferenceCancellation + InferenceEvent     |
/// | EnginePool          | Actor orchestration + model loading        |
/// | EngineInference     | doInference / _runInference                |
/// | EngineHandle        | Non-blocking facade per request            |
/// | LoadedModel         | Per-model lifecycle (CAS/atomic)           |
/// | MLXBridge           | MLX-specific backend logic                 |
/// | CoreAIBridge        | CoreAI-specific backend logic              |
/// | CoreAIModelLoader   | v15 two-phase CoreAI model loading         |
/// | SessionPool         | MLX ChatSession pooling                    |
/// | KVCacheManager      | GPU cache accounting + eviction            |
