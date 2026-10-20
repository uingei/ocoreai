# Comparator repositories — who is good at what

> The long form behind § *Upstream Audit Dependencies* item 6 in `AGENTS.md`.
> The "what the clone contains" column was read off the local clone on 10-20 (`ls` + README head).
> The audit column is CHANGELOG lines naming the tree, re-measurable with:
> `for r in vllm sglang vllm-metal omlx mlx-serve MTPLX ollama TensorFold Strata hermes-agent deepseek-harness harness2; do printf "%s=%s\n" "$r" "$(grep -c -- "$r" CHANGELOG.md)"; done`
> — the numbers in the cells are a **dated snapshot**; what actually gates is the floor block at the
> bottom, so a trimmed CHANGELOG goes red in `make docs-check` instead of leaving a stale claim.
> A **pin** is a build input (`Package.swift:43` `revision:` — only `mlx-swift-lm` and, for
> derivation, `coreai-models`). Everything else here is a comparator: nothing is linked, nothing
> is redistributed, and a borrowed verdict stays an inference until a `file:line` in *our* build
> carries it (AGENTS.md policy 3 + 4).

| Tree | What the clone actually contains (measured 10-20) | The axis it is worth borrowing from | Audit state (CHANGELOG lines, 10-20) |
|---|---|---|---|
| `vllm` | Python serving stack; `entrypoints/serve/utils/tool_calls_utils.py`, `entrypoints/anthropic/serving.py` | OpenAI + Anthropic compatibility: parallel-call filtering, `finish_reason` resolution, OpenAI→Anthropic field mapping | consumed — 21, cited by file:line through rounds 19–20 |
| `sglang` | Python serving stack; `srt/entrypoints/openai/{protocol,serving_chat}.py`, `srt/entrypoints/anthropic/protocol.py` | The same compat axis, second opinion: discriminated `delta.type` unions, `tool_choice` vocabularies, `/v1/decisions` (the AR route to typed yes/no・choice・score reads — `docs/agent/systemone-decisions.md`), "upgrade the word only if a call landed **and** it stopped naturally" | consumed — 17, cited by file:line |
| `omlx` | MLX serving project (config surface, per-model overrides) | Serving knobs that a local MLX server publishes per model (context-window caps, model-level config) | consumed — 12 |
| `hermes-agent` | Agent-loop reference | Loop shape, tool-result handling | consumed — 6 |
| `ollama` | Go server; `LLAMA_CPP_VERSION=b11669`, `MLX_C_VERSION=a341b492…`, plus its own `AGENTS.md` | Multiplexing two engine families (llama.cpp + MLX C) behind one local API and versioning each pin separately — the closest published analogue to ocoreai's MLX + CoreAI dual path; also model management/download UX | touched, not audited — 5, no file:line verdict yet |
| `mlx-serve` | MLX serving project with `tests/test_*.sh` | The convention that a behaviour claim ships as a committed shell probe (the rule behind `scripts/probes/`) | convention adopted — 3; deeper API audit open |
| `harness2` | Python agent harness (`harness2/{core,benchmarks,cli,substrate}`); `third_party/{jb_runner,lab_runner,wb_runner,patches,licenses}` each with `PROVENANCE.md`; `ASSETS.json` = 47 path→sha256 entries; `check_provenance.py` (exit 1 on any changed/missing asset); `PINNED.md` pin table; `docs/{BENCHMARKS,EXPERIMENTS,SETUP}.md` | **Release-asset provenance**: every redistributed file pinned by digest in a committed map, a checker that fails on drift, and a written line between "vendored asset" and "release code we rewrote". Adopted 10-20 as manifest schema 2 (Apple `pin`+`licenseSha256`+`verifiedAgainstPin`, `vendored[]` rows) — see `docs/agent/third-party-notices.md` | consumed — 3 (designated + this round's two borrowings) |
| `TensorFold` | Zig engine (`metal/`, `include/`, `packaging/`), `NOTICE` + `THIRD_PARTY_NOTICES.md` + `LICENSES/`, `RUNBOOK.md`, `RELEASE-NOTES-1.0.0.md`, `SECURITY.md`, `ZIG-PREVIEW.md` | Distribution discipline next to ours: a third-party notice set that ships with the binary (our `THIRD-PARTY-LICENSES/` + `ThirdPartyNoticesTests`), plus a runbook/release-notes habit we do not have | named, unused — 1 (the designation line); use it or drop it from `AGENTS.md` |
| `Strata` | C++/Metal host: `apps/host`, `apps/desktop`, `metal/`, `packaging/`, `bench/`, `docs/{BENCHMARK_PROTOCOL,COMMUNITY_BENCHMARKS,BATCHING,BATCHED_DMA,AMD_HIP}.md`, 7 README localizations | A written benchmark protocol (how a number is produced, before it is quoted) and app packaging for a local model host; AMD/HIP + DMA batching are outside our hardware envelope | named, unused — 1; same call pending |
| `MTPLX` | MTP speculative decoding for MLX | MTP drafter/acceptance behaviour against our `_runInferenceWithMessages` → `generate(::mtpDrafter:)` path | named, unused — 1 (rounds 9–15 audited mlx-swift-lm's own MTP instead) |
| `vllm-metal` | Metal backend for vllm | How a Python server reaches Metal; mostly out of stack for a Swift-native engine. 10-20: it is also where this repo first found the **Jev / System 1 decision** axis named (`docs/structured_decisions.md:3`) → `docs/agent/systemone-decisions.md` | touched — 2 |
| `deepseek-harness` | `dsh`, "everything-is-a-plugin" agent harness powered by Cordis | Skill/plugin surface design and how a harness declares capabilities — the axis `codex` covers for us in Rust | named, unused — 1; same call pending |

## How to use this file

1. Pick the axis you are on (compat, MTP, packaging, harness, provenance) and read that tree's
   relevant module before designing — if it has an answer, reference it instead of authoring a
   local variant.
2. Any borrowed verdict needs three things before it is a change: the upstream `file:line`, the
   line in ocoreai that implements it, and the gate that goes red when it regresses.
3. Update the audit column by re-running the one-liner above (the floors below are the gate, so
   refresh both together). A tree that stays at "named, unused" for several rounds is a
   named-but-unused reference: use it or drop it from `AGENTS.md` rather than keep it as
   decoration — four of the twelve are in that state as of 10-20.
4. All twelve designated trees are present under `~/references/` as of 10-20 (15 directories total
   — `mlx-swift-lm`, `coreai-models` and `codex` are the axes in § Upstream Audit Dependencies
   1–3, not comparators). A clone proves *content*, never HEAD (see the mirror caveat there).

<!-- claim:cmp_matrix_rows>=12 :: grep -c '^| `' docs/agent/comparator-repos.md -->
<!-- claim:cmp_named_trees>=12 :: grep -oE '\| `[A-Za-z0-9._-]+` \|' docs/agent/comparator-repos.md | wc -l -->
<!-- claim:cmp_vllm_changelog_lines>=21 :: grep -c -- vllm CHANGELOG.md -->
<!-- claim:cmp_sglang_changelog_lines>=17 :: grep -c -- sglang CHANGELOG.md -->
<!-- claim:cmp_omlx_changelog_lines>=12 :: grep -c -- omlx CHANGELOG.md -->
<!-- claim:cmp_hermes_changelog_lines>=6 :: grep -c -- hermes-agent CHANGELOG.md -->
<!-- claim:cmp_ollama_changelog_lines>=5 :: grep -c -- ollama CHANGELOG.md -->
<!-- claim:cmp_mlx_serve_changelog_lines>=3 :: grep -c -- mlx-serve CHANGELOG.md -->
<!-- claim:cmp_vllm_metal_changelog_lines>=2 :: grep -c -- vllm-metal CHANGELOG.md -->
<!-- claim:cmp_harness2_changelog_lines>=3 :: grep -c -- harness2 CHANGELOG.md -->
<!-- claim:cmp_designation_line_exists=1 :: grep -c 'Auxiliary references (owner-designated 10-15, extended 10-20)' AGENTS.md -->
