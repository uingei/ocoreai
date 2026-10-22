# Comparator repositories — who is good at what

> Long form behind § *Upstream Audit Dependencies* item 6 in `AGENTS.md`. The "what the clone
> contains" column was read off the local clone on 10-20 (`ls` + README head). The audit column is
> CHANGELOG lines naming the tree, re-measurable with:
> `for r in vllm sglang vllm-metal omlx mlx-serve MTPLX ollama TensorFold Strata splash hermes-agent deepseek-harness harness2; do printf "%s=%s\n" "$r" "$(grep -c -- \"$r\" CHANGELOG.md)"; done`
> — cells are a **dated snapshot**; the floor block at the bottom is the gate, so a trimmed
> CHANGELOG goes red in `make docs-check` instead of leaving a stale claim. A **pin** is a build
> input (`Package.swift:43` `revision:` — only `mlx-swift-lm`, and `coreai-models` for
> derivation); everything here is a comparator. Iteration order and per-axis fix-cost for the two
> agent-product rivals: `docs/agent/competitor-iteration-paths.md`.

Each entry is one clone under `~/references/`: what it holds, the axis worth borrowing,
and how far the audit got. A borrowed verdict is an inference until a `file:line` in our
build carries it.

- `vllm` — Python serving stack; `entrypoints/serve/utils/tool_calls_utils.py`, `entrypoints/anthropic/serving.py`
Contains: OpenAI + Anthropic compatibility: parallel-call filtering, `finish_reason` resolution, OpenAI→Anthropic field mapping
Borrow: consumed — 21, cited by file:line through rounds 19–20

- `sglang` — Python serving stack; `srt/entrypoints/openai/{protocol,serving_chat}.py`, `srt/entrypoints/anthropic/protocol.py`
Contains: The same compat axis, second opinion: discriminated `delta.type` unions, `tool_choice` vocabularies, `/v1/decisions` (the AR route to typed yes/no・choice・score reads — `docs/agent/systemone-decisions.md`), "upgrade the word only if a call landed **and** it stopped naturally"
Borrow: consumed — 17, cited by file:line

- `omlx` — MLX serving project (config surface, per-model overrides)
Contains: Serving knobs that a local MLX server publishes per model (context-window caps, model-level config)
Borrow: consumed — 12

- `hermes-agent` — Agent-loop reference
Contains: Loop shape, tool-result handling
Borrow: consumed — 6

- `ollama` — Go server; `LLAMA_CPP_VERSION=b11669`, `MLX_C_VERSION=a341b492…`, plus its own `AGENTS.md`
Contains: Multiplexing two engine families (llama.cpp + MLX C) behind one local API and versioning each pin separately — the closest published analogue to ocoreai's MLX + CoreAI dual path; also model management/download UX
Borrow: touched, not audited — 5, no file:line verdict yet

- `mlx-serve` — MLX serving project with `tests/test_*.sh`
Contains: The convention that a behaviour claim ships as a committed shell probe (the rule behind `scripts/probes/`)
Borrow: convention adopted — 3; deeper API audit open

- `harness2` — Python agent harness (`harness2/{core,benchmarks,cli,substrate}`); `third_party/{jb_runner,lab_runner,wb_runner,patches,licenses}` each with `PROVENANCE.md`; `ASSETS.json` = 47 path→sha256 entries; `check_provenance.py` (exit 1 on any changed/missing asset); `PINNED.md` pin table; `docs/{BENCHMARKS,EXPERIMENTS,SETUP}.md`
Contains: **Release-asset provenance**: every redistributed file pinned by digest in a committed map, a checker that fails on drift, and a written line between "vendored asset" and "release code we rewrote". Adopted 10-20 as manifest schema 2 (Apple `pin`+`licenseSha256`+`verifiedAgainstPin`, `vendored[]` rows) — see `docs/agent/third-party-notices.md`
Borrow: consumed — 3 (designated + this round's two borrowings)

- `TensorFold` — Zig engine (`metal/`, `include/`, `packaging/`), `NOTICE` + `THIRD_PARTY_NOTICES.md` + `LICENSES/`, `RUNBOOK.md`, `RELEASE-NOTES-1.0.0.md`, `SECURITY.md`, `ZIG-PREVIEW.md`
Contains: Distribution discipline next to ours: a third-party notice set that ships with the binary (our `THIRD-PARTY-LICENSES/` + `ThirdPartyNoticesTests`), plus a runbook/release-notes habit we do not have
Borrow: named, unused — 1 (the designation line); use it or drop it from `AGENTS.md`

- `Strata` — C++/Metal host: `apps/host`, `apps/desktop`, `metal/`, `packaging/`, `bench/`, `docs/{BENCHMARK_PROTOCOL,COMMUNITY_BENCHMARKS,BATCHING,BATCHED_DMA,AMD_HIP}.md`, 7 README localizations
Contains: A written benchmark protocol (how a number is produced, before it is quoted) and app packaging for a local model host; AMD/HIP + DMA batching are outside our hardware envelope
Borrow: named, unused — 1; same call pending

- `MTPLX` — MTP speculative decoding for MLX
Contains: MTP drafter/acceptance behaviour against our `_runInferenceWithMessages` → `generate(::mtpDrafter:)` path
Borrow: named, unused — 1 (rounds 9–15 audited mlx-swift-lm's own MTP instead)

- `vllm-metal` — Metal backend for vllm
Contains: How a Python server reaches Metal; mostly out of stack for a Swift-native engine. 10-20: it is also where this repo first found the **Jev / System 1 decision** axis named (`docs/structured_decisions.md:3`) → `docs/agent/systemone-decisions.md`
Borrow: touched — 2

- `openclaw` — TypeScript, 392k stars on 10-22, "The AI that really does things. Any OS. Any
Platform." Designated 10-22; `git clone` times out from this host (github.com is unreachable,
api.github.com answers) ⇒ **unread, no verdict claimed** here or in AGENTS.md.

- `deepseek-harness` — `dsh`, "everything-is-a-plugin" agent harness powered by Cordis
Contains: Skill/plugin surface design and how a harness declares capabilities — the axis `codex` covers for us in Rust
Borrow: named, unused — 1; same call pending


## How to use this file

1. Pick the axis (compat, MTP, packaging, harness, provenance) and read that tree's module before
   designing — if it has an answer, cite it instead of authoring a local variant. A borrowed
   verdict becomes a change only with three things: the upstream `file:line`, the ocoreai line that
   implements it, and the gate that goes red if it regresses.
2. Refresh the audit column with the one-liner above; the floors below are the gate, so change
   both together. A tree that stays "named, unused" is decoration: use it or drop it from
   `AGENTS.md`. Measured 10-22 (cites in `Sources/` + `Tests/`, `scripts/competitor-path-scan.sh`
   territory): seven trees have zero coupling — MTPLX, TensorFold, Strata, mlx-serve,
   deepseek-harness, harness2, splash — and openclaw is designated but unread.
3. Sixteen directories sit under `~/references/` as of 10-22: the thirteen comparators above plus
   `mlx-swift-lm`, `coreai-models` and `codex`, which are § Upstream Audit Dependencies 1–3, not
   comparators. A clone proves *content*, never HEAD.
