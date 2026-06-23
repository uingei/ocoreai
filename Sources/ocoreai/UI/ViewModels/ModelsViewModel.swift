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
    
    init(id: String, maxContext: Int = 0, tokenizer: String = "") {
        self.id = id
        self.maxContext = maxContext
        self.tokenizer = tokenizer
    }
    
    static func fromListModels(_ entry: [String: String]) -> ModelID {
        ModelID(
            id: entry["id"] ?? "unknown",
            maxContext: Int(entry["max_context_length"] ?? "0") ?? 0,
            tokenizer: entry["tokenizer"] ?? ""
        )
    }
}

@MainActor
final class ModelsState: Observable {
    var state: ViewState<[ModelID]> = .idle
    
    private var enginePool: EnginePool?

    func fetchModels() async {
        state = .loading
        guard let pool = OcoreaiEngine.shared.activeEnginePool ?? enginePool else {
            state = .idle
            return
        }
        let entries = await pool.listModels()
        let models = entries.map { ModelID.fromListModels($0) }
        state = .success(models)
    }
}
