// Provenance: coreai-models (BSD-3-clause, Apple) — verbatim, absorbed 2026-09-12.
//   swift/Sources/CoreAILanguageModels/InferenceEngines/InputEmbeddings.swift @ HEAD 5716935
// CoreAI dependency (NDArray) — gated.

#if canImport(CoreAI)
import CoreAI
import Foundation

/// Pre-computed embeddings ready for injection into an LLM decoder.
///
/// Used by multimodal engines to pass vision/audio embeddings into the
/// language model. The engine performs scatter-merge: replacing placeholder
/// token positions with these embeddings before the first forward pass.
@available(macOS 27.0, iOS 27.0, *)
struct InputEmbeddings: Sendable {
    /// The embedding tensor, shape [batch, seq_len, hidden_dim].
    /// Scalar type matches the LLM's expected input (float16, bFloat16, etc.).
    let embeddings: NDArray

    /// Positions in the token sequence where embeddings replace placeholders.
    let embeddingPositions: Range<Int>

    init(embeddings: NDArray, embeddingPositions: Range<Int>) throws {
        guard embeddings.shape.count == 3 else {
            throw InferenceRuntimeError.invalidArgument(
                "InputEmbeddings requires 3D embeddings [batch, seq_len, hidden_dim], "
                    + "got shape with \(embeddings.shape.count) dimensions")
        }
        self.embeddings = embeddings
        self.embeddingPositions = embeddingPositions
    }

    /// Number of embedding tokens (seq_len dimension).
    var tokenCount: Int { embeddings.shape[1] }

    // TODO: Multi-turn support — allow multiple image regions per input,
    // persistent across generate() calls (keep in KV cache on reset).
}
#endif
