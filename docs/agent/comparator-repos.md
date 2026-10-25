# Comparator repositories — who is good at what

> Long form behind § *Upstream Audit Dependencies* 6. Cells are a **dated snapshot** read off the
> local clone; re-measure the diary column:
> `for r in vllm sglang vllm-metal omlx mlx-serve MTPLX ollama TensorFold Strata splash openclaw hermes-agent deepseek-harness harness2 goose opencode; do printf "%s=%s\n" "$r" "$(grep -c -- \"$r\" CHANGELOG.md)"; done`
> — P16 re-derives both lists, so a stale cell goes red. A **pin** is a build input (`Package.swift:43`); everything else is a comparator.

Each entry is one clone under `~/references/`: what it holds, the axis worth borrowing, and
how far the audit got.

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
Contains: the same notice set we ship with the binary (`THIRD-PARTY-LICENSES/` +
  `ThirdPartyNoticesTests`). Its `RUNBOOK.md`/release-notes are not a habit we lack: versioned
  `CHANGELOG.md` sections, `scripts/release-artifact-check.sh` and
  `scripts/verify-installed-release.sh` are ours. Nothing left on this axis.
Borrow: none measured (the designation line); keep the name only if a new axis appears

- `Strata` — local-AI product: desktop app, agent terminal, C++ engine across CUDA/HIP/SYCL/Metal.
Contains: `launch --plan` prints a multi-GB mutation before doing it, then exits untouched
  (`docs/TERMINAL_LAUNCH.md:110`); engine packages carry a manifest `engine_component.py` checks before
  start (`packaging/ENGINE-COMPONENT.md`); installers fetch the engine for the GPU present. Cadence:
  2337 of 4196 commits in 14 days.
Borrow: consumed for the dry-run (`Models/ModelDownloadDTO.swift` `DownloadPlan` + probe 36);
  integrity checking of runtime-fetched artifacts is still open.

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

1. Read that tree's module before designing: where it has the answer, cite `file:line` rather
   than authoring a local variant, and land the change with upstream line, our line, and the gate
   that goes red on regression.
2. Refresh with the one-liner above; P16 re-derives both lists from `Sources/` + `Tests/`,
   where six trees have zero coupling — MTPLX, TensorFold, Strata, mlx-serve, opencode,
   harness2 — so a row left "named, unused" is decoration: use it or drop the name.
