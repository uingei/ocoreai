// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Models ViewModel — reads loaded models directly from EnginePool (Fast Path, no HTTP).
///
/// @Observable pattern (Swift 5.9+): property-level change tracking.

import Foundation
import SwiftUI

/// Simple lightweight model info from EnginePool.
struct ModelID: Identifiable, Hashable, Sendable {
    let id: String
    let maxContext: Int
    let tokenizer: String
    var paramsCustomized: Bool = false  /// Whether this model has non-default sampling params

    init(id: String, maxContext: Int = 0, tokenizer: String = "", paramsCustomized: Bool = false) {
        self.id = id
        self.maxContext = maxContext
        self.tokenizer = tokenizer
        self.paramsCustomized = paramsCustomized
    }

    static func fromListModels(_ entry: [String: String]) -> ModelID {
        ModelID(
            id: entry["id"] ?? "unknown",
            maxContext: Int(entry["max_context_length"] ?? "0") ?? 0,
            tokenizer: entry["tokenizer"] ?? ""
        )
    }
}

@Observable
@MainActor
final class ModelsState {
    var state: ViewState<[ModelID]> = .idle

    private var enginePool: EnginePool?

    func fetchModels() async {
        state = .loading
        guard let pool = OcoreaiEngine.shared.activeEnginePool ?? enginePool else {
            state = .idle
            return
        }
        let entries = await pool.listModels()
        // Hot-swap persisted sampling configs into engine pool
        let store = SettingsStore.shared
        var models: [ModelID] = []
        for entry in entries {
            let model = ModelID.fromListModels(entry)
            let config = store.loadSamplingConfig(for: model.id)
            // Write to engine pool runtime store
            await pool.updateSamplingConfig(modelId: model.id, config: config)
            // Mark if params are non-default
            var info = model
            info.paramsCustomized = !config.isDefault
            models.append(info)
        }
        state = .success(models)
    }
}
