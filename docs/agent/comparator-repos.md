# Comparator repositories — who is good at what

> The long form behind § *Upstream Audit Dependencies* item 6 in `AGENTS.md`.
> Every structural fact below was read off the local clone on 10-20 (`ls` + README head);
> the audit column is `grep -c -- <name> CHANGELOG.md`, re-runnable as
> `for r in vllm sglang vllm-metal omlx mlx-serve MTPLX ollama TensorFold Strata hermes-agent deepseek-harness; do printf "%s=%s\n" "$r" "$(grep -c -- "$r" CHANGELOG.md)"; done`.
> A **pin** is a build input (`Package.swift:43` `revision:` — only `mlx-swift-lm` and, for
> derivation, `coreai-models`). Everything else here is a comparator: nothing is linked, nothing
> is redistributed, and a borrowed verdict stays an inference until a `file:line` in *our* build
> carries it (AGENTS.md policy 3 + 4).

| Tree | What the clone actually contains (measured 10-20) | The axis it is worth borrowing from | Audit state (CHANGELOG hits) |
|---|---|---|---|
| `vllm` | Python serving stack; `entrypoints/serve/utils/tool_calls_utils.py`, `entrypoints/anthropic/serving.py` | OpenAI + Anthropic compatibility: parallel-call filtering, `finish_reason` resolution, OpenAI→Anthropic field mapping | consumed — 15 hits, cited by file:line through rounds 19–20 |
| `sglang` | Python serving stack; `srt/entrypoints/openai/{protocol,serving_chat}.py`, `srt/entrypoints/anthropic/protocol.py` | The same compat axis, second opinion: discriminated `delta.type` unions, `tool_choice` vocabularies, "upgrade the word only if a call landed **and** it stopped naturally" | consumed — 12 hits, cited by file:line |
| `omlx` | MLX serving project (config surface, per-model overrides) | Serving knobs that a local MLX server publishes per model (context-window caps, model-level config) | consumed — 11 hits |
| `hermes-agent` | Agent-loop reference | Loop shape, tool-result handling | consumed — 5 hits |
| `ollama` | Go server; `LLAMA_CPP_VERSION=b11669`, `MLX_C_VERSION=a341b492…`, plus its own `AGENTS.md` | Multiplexing two engine families (llama.cpp + MLX C) behind one local API and versioning each pin separately — the closest published analogue to ocoreai's MLX + CoreAI dual path; also model management/download UX | touched, not audited — 4 hits, no file:line verdict yet |
| `mlx-serve` | MLX serving project with `tests/test_*.sh` | The convention that a behaviour claim ships as a committed shell probe (the rule behind `scripts/probes/`) | convention adopted — 2 hits; deeper API audit open |
| `TensorFold` | Zig engine (`metal/`, `include/`, `packaging/`), `NOTICE` + `THIRD_PARTY_NOTICES.md` + `LICENSES/`, `RUNBOOK.md`, `RELEASE-NOTES-1.0.0.md`, `SECURITY.md`, `ZIG-PREVIEW.md` | Distribution discipline next to ours: a third-party notice set that ships with the binary (our `THIRD-PARTY-LICENSES/` + `ThirdPartyNoticesTests`), plus a runbook/release-notes habit we do not have | untouched — 0 hits |
| `Strata` | C++/Metal host: `apps/host`, `apps/desktop`, `metal/`, `packaging/`, `bench/`, `docs/{BENCHMARK_PROTOCOL,COMMUNITY_BENCHMARKS,BATCHING,BATCHED_DMA,AMD_HIP}.md`, 7 README localizations | A written benchmark protocol (how a number is produced, before it is quoted) and app packaging for a local model host; AMD/HIP + DMA batching are outside our hardware envelope | untouched — 0 hits |
| `MTPLX` | MTP speculative decoding for MLX | MTP drafter/acceptance behaviour against our `_runInferenceWithMessages` → `generate(::mtpDrafter:)` path | untouched — 0 hits (rounds 9–15 audited mlx-swift-lm's own MTP instead) |
| `vllm-metal` | Metal backend for vllm | How a Python server reaches Metal; mostly out of stack for a Swift-native engine | touched — 1 hit |
| `deepseek-harness` | `dsh`, "everything-is-a-plugin" agent harness powered by Cordis | Skill/plugin surface design and how a harness declares capabilities — the axis `codex` covers for us in Rust | untouched — 0 hits |

## Not on this host

- **`harness2`** — designated by the owner on 10-20 but **absent from `~/references/`** (14 trees
  exist, none by that name). No claim about it can be made, cited, or gated until it is cloned;
  map it here first when it lands.

## How to use this file

1. Pick the axis you are on (compat, MTP, packaging, harness) and read that tree's relevant module
   before designing — if it has an answer, reference it instead of authoring a local variant.
2. Any borrowed verdict needs three things before it is a change: the upstream `file:line`, the
   line in ocoreai that implements it, and the gate that goes red when it regresses.
3. Update the audit column by re-running the one-liner above; a repo that stays at 0 hits for
   several rounds is a named-but-unused reference, which is a thing to either use or drop from
   `AGENTS.md` rather than keep as decoration.
