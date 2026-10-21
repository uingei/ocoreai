// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! LoRAModelSupport.swift — the capability check that keeps `POST /v1/models/train` and
//! `POST /v1/models/evaluate` from killing the process.
//!
//! ### What was measured (10-21, live, this host)
//! `POST /v1/models/evaluate` with a legal dataset (one 10-token sentence, `batch_size:1`,
//! `max_batches:1`) against `mlx-community/gemma-4-e2b-it-4bit` — the id `/v1/models`
//! advertises and `/v1/chat/completions` serves — produced **no response**: the SSE-less
//! request returned `curl: (52) Empty reply from server` and the process died with
//! `Trace/BPT trap: 5`. `POST /v1/models/train` with two well-formed 10-token samples did
//! the same (HTTP 200, stream cut mid-body, `/health` unreachable afterwards). Every other
//! conversation on the box went with it.
//!
//! The crash report names the line, and it is upstream's, not ours:
//!
//! ```text
//!   Swift runtime failure: type cast failed
//!   dynamic_cast_existential_1_unconditional
//!   static LoRATrain.loss(model:inputs:targets:lengths:)
//!   static LoRATrain.evaluate(model:dataset:loss:tokenizer:batchSize:batchCount:)
//! ```
//!
//! `LoraTrain.swift:191` at the pinned revision (`bb0d5b048`) reads `let model = model as!
//! any LLMModel`. This checkpoint loads through `VLMModelFactory`, so its model is a Module
//! that does not conform to `MLXLLM.LLMModel` — the unconditional cast traps. mlx-swift-lm
//! #683 (upstream `bb0d5b0`) added sample-length pre-flights but left this cast alone, so
//! there is no upstream answer to consume yet.
//!
//! ### The rule, at our seam
//! A capability the engine cannot deliver is a refusal that names the requirement and the
//! remedy (AGENTS.md: the surface never claims more than the engine delivered; no wire value
//! may own the process). The check is the cast the loss will perform, stated as `is` before
//! the call rather than `as!` inside it — same predicate, recoverable outcome.

import MLXLLM
import MLXNN

enum LoRAModelSupport {

    /// nil when the LoRA train/eval path can run this model; otherwise the reason to tell
    /// the client, in the client's terms (what is required, what arrived, what to do).
    static func rejection(for model: Module) -> String? {
        if model is (any LLMModel) { return nil }
        let arrived = String(describing: type(of: model))
        let requirement = "LoRA train/evaluate needs an MLXLLM.LLMModel"
        let why = "the LoRA loss casts the model unconditionally (as! any LLMModel)"
        let remedy = "run it against a text LLM, not this checkpoint"
        return
            "\(requirement); this model loads as \(arrived), which does not conform — \(why), so the request would trap the server. \(remedy)."
    }
}
