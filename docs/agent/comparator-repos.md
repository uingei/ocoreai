# Comparator repositories — who is good at what

> Long form behind § *Upstream Audit Dependencies* 6. Cells are a **dated snapshot** read off the
> local clone (`ls` + README head); re-measure the diary column:
> `for r in vllm sglang vllm-metal omlx mlx-serve MTPLX ollama TensorFold Strata splash openclaw hermes-agent deepseek-harness harness2 goose opencode; do printf "%s=%s\n" "$r" "$(grep -c -- \"$r\" CHANGELOG.md)"; done`
> — P16 re-derives both lists, so a trimmed diary or a stale cell goes
> red. A **pin** is a build input (`Package.swift:43` — `mlx-swift-lm`, plus `coreai-models` for
> derivation); everything here is a comparator.

Each entry is one clone under `~/references/`: what it holds, the axis worth borrowing,
and how far the audit got. A borrowed verdict is an inference until a `file:line` in our
build carries it.

- `vllm` — Python serving stack; `entrypoints/serve/utils/tool_calls_utils.py`, `entrypoints/anthropic/serving.py`
Contains: OpenAI + Anthropic compatibility: parallel-call filtering, `finish_reason` resolution, OpenAI→Anthropic field mapping
Borrow: consumed, cited by file:line through rounds 19–20

- `sglang` — Python serving stack; `srt/entrypoints/openai/{protocol,serving_chat}.py`, `srt/entrypoints/anthropic/protocol.py`
Contains: The same compat axis, second opinion: discriminated `delta.type` unions, `tool_choice` vocabularies, `/v1/decisions` (the AR route to typed yes/no・choice・score reads — `docs/agent/systemone-decisions.md`), "upgrade the word only if a call landed **and** it stopped naturally"
Borrow: consumed, cited by file:line

- `omlx` — MLX serving project (config surface, per-model overrides)
Contains: Serving knobs that a local MLX server publishes per model (context-window caps, model-level config)
Borrow: consumed

- `hermes-agent` — Agent-loop reference
Contains: Loop shape, tool-result handling
Borrow: consumed

- `ollama` — Go server; `LLAMA_CPP_VERSION=b11669`, `MLX_C_VERSION=a341b492…`, plus its own `AGENTS.md`
Contains: Multiplexing two engine families (llama.cpp + MLX C) behind one local API and versioning each pin separately — the closest published analogue to ocoreai's MLX + CoreAI dual path; also model management/download UX
Borrow: touched, not audited, no file:line verdict yet

- `mlx-serve` — MLX serving project with `tests/test_*.sh`
Contains: The convention that a behaviour claim ships as a committed shell probe (the rule behind `scripts/probes/`)
Borrow: convention adopted; deeper API audit open

- `harness2` — Python agent harness: `ASSETS.json` (path→sha256), `check_provenance.py` (exit 1 on any changed/missing asset), per-runner `PROVENANCE.md`, `PINNED.md`
Contains: **Release-asset provenance** — every redistributed file pinned by digest in a committed map, with a checker that fails on drift. Adopted as manifest schema 2 (`pin`+`licenseSha256`+`verifiedAgainstPin`, `vendored[]` rows): `docs/agent/third-party-notices.md`
Borrow: consumed

- `TensorFold` — Zig engine (`metal/`, `include/`, `packaging/`), `NOTICE` + `THIRD_PARTY_NOTICES.md` + `LICENSES/`, `RUNBOOK.md`, `RELEASE-NOTES-1.0.0.md`, `SECURITY.md`, `ZIG-PREVIEW.md`
Contains: Distribution discipline next to ours: a third-party notice set that ships with the binary (our `THIRD-PARTY-LICENSES/` + `ThirdPartyNoticesTests`), plus a runbook/release-notes habit we do not have
Borrow: named, unused (the designation line); use it or drop it from `AGENTS.md`

- `Strata` — C++/Metal host: `apps/host`, `apps/desktop`, `metal/`, `packaging/`, `bench/`, `docs/{BENCHMARK_PROTOCOL,COMMUNITY_BENCHMARKS,BATCHING,BATCHED_DMA,AMD_HIP}.md`, 7 README localizations
Contains: A written benchmark protocol (how a number is produced, before it is quoted) and app packaging for a local model host; AMD/HIP + DMA batching are outside our hardware envelope
Borrow: consumed — the rule now runs as `scripts/eval/_conditions.py`, which writes what produced every
scoreboard number into `results.tsv` and gives `_repeat_stats.py` the fields to refuse on

- `MTPLX` — MTP speculative decoding for MLX
Contains: MTP drafter/acceptance behaviour against our `_runInferenceWithMessages` → `generate(::mtpDrafter:)` path. Also a per-seat memory policy: `ee9cca4f` prices a family's prefill from measurement (MLX peak over each chunk's end state, peak reset per prompt) and narrows the prefill width before it refuses.
Borrow: consumed — pricing from measurement landed as `Engine/KVCacheResidency.swift` + probe 35 (bytes read off the cache, not a constant); narrow-before-refuse still has no ocoreai seam

- `vllm-metal` — Metal backend for vllm
Contains: How a Python server reaches Metal; mostly out of stack for a Swift-native engine. It is also where this repo first found the **Jev / System 1 decision** axis named (`docs/structured_decisions.md:3`) → `docs/agent/systemone-decisions.md`
Borrow: touched

- `openclaw` — TypeScript + 1,596 Swift, the fastest mover in the set; **not** the only native Apple app here —
  mlx-serve, MTPLX and omlx ship an `@main … App` shell too, and all four gate their GUI harder than we do
  (measured; CHANGELOG). Iteration shape + what it changes here: `docs/agent/competitor-iteration-paths.md`
Borrow: consumed

- `splash` — Python MLX server; `dev/tests/server/test_anthropic_contract.py`, `api_shapes.py`
Contains: the usage identity a client sums — `count == input + cache_read` (`:889`) — and the keys a face
must leave absent when it measured no creation. Borrow: consumed (`AnthropicCacheUsageTests` + probe 22)

- `goose` — Rust agent platform; `crates/goose-{context-management,download-manager}`, `ui/{desktop,goose-acp}`,
`agent-client-protocol = 2.2.0` (`Cargo.toml:23`)
Contains: ACP as a third surface (editors as clients); compaction as its own crate (`context-management/lib.rs:49`).
Downloads are *not* a gap — `Models/ModelScopeDownloader.swift` resumes on Range + If-Range identity.
Borrow: ACP is a new core surface (ladder rung 6) ⇒ an owner call, not an audit

- `opencode` — TypeScript monorepo; `packages/{protocol,schema,httpapi-codegen,http-recorder,session-ui,desktop,tui}`
Contains: contract-first wire (one spec → generated SDK and docs) and **cassette replay** (`http-recorder/README.md`:
record real HTTP/WS once, replay deterministic JSON) — the axis our harness lacks, since every `scripts/probes/` claim
needs a live Metal server. Borrow: named; replay for harness regressions, never for capability claims

- `deepseek-harness` — `dsh`, "everything-is-a-plugin" agent harness powered by Cordis
Contains: Skill/plugin surface design and how a harness declares capabilities — the axis `codex` covers for us in Rust
Borrow: named, unused; same call pending


## How to use this file

1. Pick the axis (compat, MTP, packaging, harness, provenance) and read that tree's module before
   designing — if it has an answer, cite it instead of authoring a local variant. A borrowed
   verdict becomes a change only with three things: the upstream `file:line`, the ocoreai line that
   implements it, and the gate that goes red if it regresses.
2. Refresh the audit column with the one-liner above; P16 re-derives both lists, so change the
   two together. A tree that stays "named, unused" is decoration: use it or drop it from
   `AGENTS.md`. P16 re-derives it from `Sources/` + `Tests/`: six trees have zero coupling —
   MTPLX, TensorFold, Strata, mlx-serve, opencode, harness2 — and openclaw is designated
   but unread.
3. `~/references/` holds the comparators above plus `mlx-swift-lm`, `coreai-models` and `codex`
   (§ Upstream Audit Dependencies 1–3, not comparators). A clone proves *content*, never HEAD.
