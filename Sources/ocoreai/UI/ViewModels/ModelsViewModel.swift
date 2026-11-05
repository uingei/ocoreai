// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelID — lightweight model identity for EnginePool listing.
///
/// Used by ModelManager and ModelView. The former ModelsState class
/// has been removed (ModelManager provides the same functionality).

import Foundation

/// Simple lightweight model info from EnginePool.
struct ModelID: Identifiable, Hashable {
    let id: String
    let maxContext: Int
    let vocabSize: Int
    let tokenizer: String
    let isVlm: Bool
    var paramsCustomized: Bool = false
    /// Whether this model has non-default sampling params
    /// The pool's own `state == "loading"` at this refresh — engine truth
    /// (`EnginePool.listModels` surfaces prewarms and in-flight loads, including
    /// for models not yet registered). The wait face cannot see a load whose
    /// weights are already on disk (no store row, no window task), so the card
    /// that says "启动中" asks this, not `downloadingModelId`.
    let isPoolLoading: Bool

    init(
        id: String, maxContext: Int = 0, vocabSize: Int = 0, tokenizer: String = "",
        isVlm: Bool = false, paramsCustomized: Bool = false, isPoolLoading: Bool = false
    ) {
        self.id = id
        self.maxContext = maxContext
        self.vocabSize = vocabSize
        self.tokenizer = tokenizer
        self.isVlm = isVlm
        self.paramsCustomized = paramsCustomized
        self.isPoolLoading = isPoolLoading
    }

    static func fromListModels(_ entry: [String: String]) -> ModelID {
        ModelID(
            id: entry["id"] ?? "unknown",
            maxContext: Int(entry["max_context_length"] ?? "0") ?? 0,
            vocabSize: Int(entry["vocab_size"] ?? "0") ?? 0,
            tokenizer: entry["tokenizer"] ?? "",
            // Reads the key the pool actually writes: `"vlm"`
            // (EnginePool.swift:1115). `"specialized"` means CoreAI ANE
            // specialization and is absent on macOS 26, so this parser froze the
            // models list to "not a VLM" for every MLX vision model.
            isVlm: (entry["vlm"] ?? "false") == "true",
            isPoolLoading: (entry["state"] ?? "") == "loading",
        )
    }

    /// Human-readable context window string (e.g. "8K", "128K")
    var contextString: String {
        guard maxContext > 0 else { return "" }
        if maxContext >= 1000 {
            return "\(maxContext / 1000)K"
        }
        return "\(maxContext)"
    }

    /// Human-readable vocab size string (e.g. "32K", "128K")
    var vocabString: String {
        guard vocabSize > 0 else { return "" }
        if vocabSize >= 1000 {
            return "\(vocabSize / 1000)K"
        }
        return "\(vocabSize)"
    }
}
