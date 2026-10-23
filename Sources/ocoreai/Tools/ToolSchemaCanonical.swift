// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ToolSchemaCanonical.swift — the one home for the order of a *synthesized* schema list.
///
/// ### Why this exists (10-23: the dictionary-seed class came back through MCP)
/// `required` is a JSON Schema **set**: member order means nothing to the model, to the OpenAI or
/// Anthropic wire, to vllm/sglang, or to our own dispatch. It was built as
/// `Array(schema.parameters.keys)` — the iteration order of a Swift `Dictionary`, which Swift picks
/// from a per-process hash seed — at `ToolRegistry.toToolSpecs` (the specs that reach the prompt)
/// and `ToolEntry.toToolDef` (which the outbound MCP face publishes). Same request, two cold
/// boots, two different `required` orders,
/// two different prompt hashes: the defect that closed as 10-23(8) for skill blocks, arriving again
/// through a different door. Any byte a turn feeds that comes from dictionary iteration is a coin
/// flip on whether the task gets a fair chance to run, and no unit test inside one process can see
/// it, because Swift fixes the seed for the process's lifetime.
///
/// ### Rule
/// Sort what **we synthesize**; leave what the caller sent alone. A caller's own `required` order
/// is request-determined — therefore already deterministic — and rewriting it would alter bytes the
/// client authored. So the fallback branches sort and the passthrough branches do not: the fix
/// removes seed dependence, it does not normalize the wire.
///
/// ### Precedent (both compat rivals do exactly this)
/// sglang `python/sglang/srt/entrypoints/systemone/joint_schema.py:48` and vllm
/// `vllm/entrypoints/openai/decisions/strategies.py:902` canonicalize schema-shaped values with
/// `sort_keys=True` before those bytes are used.
///
/// ### The half this cannot fix, stated rather than hidden
/// `properties` travels upstream as `ToolSpec = [String: any Sendable]`
/// (`mlx-swift-lm Libraries/MLXLMCommon/Tool/Tool.swift:5`) — a dictionary — so its serialized
/// order is decided by whoever renders it, not by us. Measured 10-23: gemma-4's own template sorts
/// property names (`order_id,status,limit` → `limit,order_id,status`), so this host shows no leak
/// there; a checkpoint whose renderer preserves dictionary order would still vary across boots, and
/// that belongs upstream in `prepare()`/the template, not in a local copy of the renderer. The
/// half we do own is pinned by probe 33, byte for byte, across cold boots.
enum ToolSchemaCanonical {
    /// Deterministic order for a `required` list we synthesized from a parameter dictionary.
    ///
    /// Parameter names are ASCII identifiers in practice; `sorted()` on `String` is the same
    /// comparison the rivals' `sort_keys=True` applies, so the two sides agree without a shared
    /// collation table.
    static func sortedRequired(_ keys: some Sequence<String>) -> [String] {
        Array(keys).sorted()
    }
}
