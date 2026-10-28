# Comparator repositories — who is good at what

> Long form behind § *Upstream Audit Dependencies* 6. Cells are a **dated snapshot** read off the
> local clone; re-measure the diary column:
> `for r in vllm sglang vllm-metal omlx mlx-serve MTPLX ollama TensorFold Strata splash openclaw hermes-agent harness2 goose opencode pi deepseek-harness; do printf "%s=%s\n" "$r" "$(grep -c -- \"$r\" CHANGELOG.md)"; done`
> — nothing re-derives these lists since 10-28 (P16 was deleted as prose-shape), so a stale cell is
> yours to notice: `git grep -l <tree> -- Sources Tests` re-derives the coupling set in one line. A **pin**
> is a build input (`Package.swift:43`); everything else is a comparator.
> Context economy, ours 10-29/field 10-28, over each tree's own `AGENTS.md` set — root bytes / corpus bytes / **deepest
> root→cwd chain against the 32 768 B the loader injects**: mlx-serve 26 486 / 269 381 / 69 273 (211 % of the
> cap), deepseek-harness 19 113 / 96 369 / 55 362 (169 %), opencode 15 102 / 86 866 / 37 627 (115 %),
> openclaw 19 374 / 113 906 / 34 186 (104 %), **ocoreai 21 246 / 46 357 / 31 875 (97 %, 893 B of headroom)**,
> vllm 6 358 / 48 844 / 31 675, hermes-agent 11 952 / 159 599 / 30 192, pi 8 845, codex 0 / 3 441, ollama 358.
> Re-measure: walk the tree for `AGENTS.md`, sum each file's ancestors up to the root, divide by 32 768 — the
> semantics codex `agents_md.rs:68-92` and our `Sources/ocoreai/WorkspaceContext.swift:221-229` both
> implement. Four trees read a ruleset their own loader truncates and three never say so; ours is 893 B from
> that line and names what it drops.

Each entry is one clone under `~/references/`: what it holds, the axis worth borrowing, how far the audit got.

- `vllm` — Python serving stack; `entrypoints/serve/utils/tool_calls_utils.py`,
  `entrypoints/anthropic/serving.py`
Contains: OpenAI + Anthropic compatibility — parallel-call filtering, `finish_reason` resolution,
  OpenAI→Anthropic field mapping — plus the **intake policy** an AI-assisted PR must satisfy
  (`AGENTS.md:8`, `:21`, `:27`, `:35`, `:39`; full text in `docs/agent/adoption-runbook.md` § The intake machine).
Borrow: consumed, cited by file:line (rounds 19–20); our home for the policy is `CONTRIBUTING.md`

- `sglang` — Python serving stack; `srt/entrypoints/openai/{protocol,serving_chat}.py`,
  `srt/entrypoints/anthropic/protocol.py`
Contains: the same compat axis, second opinion — discriminated `delta.type` unions, `tool_choice`
  vocabularies, `/v1/decisions` (the AR route to typed yes/no・choice・score reads —
  `docs/agent/systemone-decisions.md`), and "upgrade the word only if a call landed **and** it stopped
  naturally". Second axis: **permissions as data** — 123 workflow files driven by
  `.github/CI_PERMISSIONS.json` + `.github/MAINTAINER.md` (cites in `adoption-runbook.md`).
Borrow: consumed, cited by file:line; permission-as-data is the honest shape for CI rights at scale

- `omlx` — MLX serving project, 23 108 stars — the closest published *distribution* analogue to us: a Python
  MLX server in a native SwiftUI menubar app
Contains: per-model serving knobs, and the four-part install machine — DMG, in-app auto-update, a
  `~/.omlx/bin/omlx` shim, a self-serve tap in `Formula/omlx.rb` whose optional-kernel flag degrades instead
  of failing (`README.md:53`, `:58`; mechanics: `adoption-runbook.md` § The install machine).
Borrow: consumed — that quartet is rung 2 of `docs/agent/long-horizon-goal.md`, and degraded-not-failed is
  invariant 2 applied to packaging

- `hermes-agent` — agent-loop reference (#2 in the category: 257 756 stars, 5 714 commits in 14 d, 234 tags)
Contains: loop shape, tool-result handling. Second axis (10-28): the ops machine behind the number — 57
  workflow files incl. `install-e2e.yml` (per-OS) with its red-path twin, `skills-index-freshness.yml`,
  `plugin-catalog-ci.yml`, canary vs stable publication, `osv-scanner.yml` + `lockfile-diff.yml` +
  `blob-size-check.yml`, and `SOUL.md` — the voice a user hears is not the discipline a session follows. Its
  `prompt-surface-diff.yml` renders, from production code, the system prompt and `tools[]` a stock install
  sends, per surface and model family, and a stale snapshot fails a test.
Borrow: consumed; `prompt-surface-diff` is the pattern § Documentation Map would use *if* the owner quotes the
  red it must catch — the gate layer is frozen, so it is a named pattern, not a task

- `ollama` — Go server; `LLAMA_CPP_VERSION=b11669`, `MLX_C_VERSION=a341b492…`, a 358 B `AGENTS.md`
Contains: two engine families (llama.cpp + MLX C) behind one local API, each pin versioned separately — the
  closest published analogue to our MLX + CoreAI dual path.
Borrow: touched, not audited (185 027 stars, 719 tags)

- `mlx-serve` — MLX serving project with `tests/test_*.sh`
Contains: The convention that a behaviour claim ships as a committed shell probe (the rule behind `scripts/probes/`)
Borrow: convention adopted; API audit open

- `harness2` — Python agent harness: `ASSETS.json` (path→sha256), `check_provenance.py` (exit 1 on any
  changed or missing asset), `PINNED.md`
Contains: **release-asset provenance** — every redistributed file pinned by digest in a committed map, with a
  checker that fails on drift.
Borrow: consumed — adopted as manifest schema 2 (`pin` + `licenseSha256` + `verifiedAgainstPin`, `vendored[]`)
  in `docs/agent/third-party-notices.md`

- `TensorFold` — Zig engine (`metal/`, `packaging/`); `NOTICE`, `THIRD_PARTY_NOTICES.md`, `LICENSES/`, `RUNBOOK.md`
Contains: the notice set we already ship, and a runbook/release-notes habit we already have
  (`scripts/release-artifact-check.sh`, `scripts/verify-installed-release.sh`). Nothing left here.
Borrow: consumed once; no second axis measured

- `Strata` — local-AI product: desktop app, agent terminal, C++ engine across CUDA/HIP/SYCL/Metal, and the
  closest *product* shape to ours in growth terms — 34 577 stars in 34 days (1 016/day; 2 381 commits in 14 d)
Contains: `launch --plan` prints a multi-GB mutation before doing it, then exits untouched
  (`docs/TERMINAL_LAUNCH.md:110`); engine packages carry a manifest `engine_component.py` checks before start
  (`packaging/ENGINE-COMPONENT.md`); installers fetch the engine for the GPU present.
Borrow: consumed for the dry-run (`Models/ModelDownloadDTO.swift` `DownloadPlan` + probe 36); integrity
  checking of runtime-fetched artefacts is still open.

- `MTPLX` — MTP speculative decoding for MLX
Contains: MTP drafter/acceptance behaviour against our `_runInferenceWithMessages` →
  `generate(::mtpDrafter:)` path, and a per-seat memory policy: `ee9cca4f` prices a family's prefill from
  measurement (MLX peak over each chunk's end state, reset per prompt) and narrows the width before refusing.
Borrow: consumed — pricing from measurement landed as `Engine/KVCacheResidency.swift` + probe 35 (bytes read
  off the cache, not a constant); narrow-before-refuse still has no ocoreai seam

- `vllm-metal` — Metal backend for vllm
Contains: how a Python server reaches Metal — mostly out of stack for a Swift-native engine. Where this repo
  first found the **Jev / System 1 decision** axis named (`docs/structured_decisions.md:3` →
  `docs/agent/systemone-decisions.md`).
Borrow: touched

- `openclaw` — **the #1 repo in this category on GitHub** (393 221 stars / 82 663 forks, created 2025-11-24 —
  1 163 stars/day; the *rate* record is deepseek-harness's below), TypeScript + 1,596 Swift. **Not** the only
  native Apple app here — mlx-serve, MTPLX and omlx ship `@main … App` shells, and all four gate their GUI
  harder than we do (CHANGELOG). What the headline is made of (`README.md:20`, `:30`) — privacy
  contract in the first screen, installer that provisions its runtime, Sparkle appcasts so updates run
  in-app, the 20+ channels the user already has plus 6 native apps, 189 `extensions/` and 51 `skills/`,
  `VISION.md`, a 501(c)(3) that employs the team ("OpenAI is a donor, not an owner") — is itemised in
  `docs/agent/adoption-runbook.md`. Two of its 120 workflows have no analogue here:
  `maturity-scorecard.yml` generates a published maturity score from committed QA evidence and opens the diff
  as a PR, so the score moves only by measurement; `update-migration.yml` exercises a user's stored config
  across the upgrade — our persisted keys declare their scope (§ Working here in `AGENTS.md`) and nothing
  proves they survive one. It also states the load-bearing line for our wedge: local models are **plugins it
  swaps**, not a rival it builds. Iteration shape: `docs/agent/competitor-iteration-paths.md`.
Borrow: consumed — adoption machine audited 10-28 (`docs/agent/long-horizon-goal.md` § Rung zero)

- `splash` — Python MLX server; `dev/tests/server/test_anthropic_contract.py`, `api_shapes.py`
Contains: the usage identity a client sums — `count == input + cache_read` (`:889`) — and the keys a face must
  leave absent when it measured no creation.
Borrow: consumed (`AnthropicCacheUsageTests` + probe 22)

- `codex` — § Upstream 3 (semantic axis, Rust), and the second thing worth copying: how a first-party agent
  documents itself — 131 273 stars on an **81-line README**, because the surface lives in `docs/`
  (`agents_md.md`, `skills.md`, `execpolicy.md`, `sandbox.md`, `slash_commands.md`, `install.md`), with
  install by script, npm and cask (`README.md:19`, `:47`) and 3 441 B of guides in total against our
  21 446 B root.
Borrow: the README is a signpost, not a manual; ours is a manual, and the context-economy line at the top of
  this file is that finding measured on ourselves

- `mlx-swift-lm` (pin 1) and `coreai-models` (pin 2) — engineering consumption is § Upstream 1–2; the practice
  axis is in both and missing here: **the repo ships the skill that teaches an outside agent its API** —
  `mlx-swift-lm/skills/` + `skills/README.md` (install steps for another vendor's agent) and
  `coreai-models/skills/skills/{working-with-coreai,model-authoring,model-compression-exploration}`, packaged
  for a second host via `skills/gemini-extension.json`. `mlx-swift-lm/AGENTS.md` carries the AI-usage policy
  with scripted refusals (`:5`, `:24` — draft a PR description yes, open the PR on the author's behalf no).
Borrow: a published skill for `/v1` is rung 6 of `docs/agent/long-horizon-goal.md`; the policy belongs to
  `CONTRIBUTING.md` when outside intake exists to apply it to

- `goose` — Rust agent platform; `crates/goose-{context-management,download-manager}`,
  `ui/{desktop,goose-acp}`, `agent-client-protocol = 2.2.0` (`Cargo.toml:23`)
Contains: ACP as a third surface (editors as clients); compaction as its own crate
  (`context-management/lib.rs:49`). Downloads are *not* a gap — `Models/ModelScopeDownloader.swift` resumes
  on Range + If-Range identity.
Borrow: ACP is a new core surface (ladder rung 6) ⇒ an owner call, not an audit

- `opencode` — TypeScript monorepo; `packages/{protocol,schema,httpapi-codegen,http-recorder,session-ui,desktop,tui}`
Contains: contract-first wire — the HTTP API is a spec and the SDK is generated from it
  (`packages/httpapi-codegen`), which is how a server project ends up inside other people's products — and
  **cassette replay** (`http-recorder/README.md`: record real HTTP/WS once, replay deterministic JSON), the
  axis our harness lacks, since every `scripts/probes/` claim needs a live Metal server. Second axis (10-28;
  222 385 stars, 1 126 commits in 14 d, 1 156 tags): install script + 5 package managers + cask + desktop app,
  22 bot-kept README locales, bot-closed intake, `nightly-beta.yml` + `release-dry-run.yml` so a release is
  rehearsed before it ships (cites: `adoption-runbook.md`).
Borrow: consumed; replay is for harness regressions, never for capability claims

- `pi` — TypeScript monorepo, 11 packages (`agent`, `coding-agent`, `codemode`, `durable`, `evals`, `mcp`,
  `tui`); the leanest injected surface in the set — one 8 845 B `AGENTS.md`, no area guides (118 294 stars)
Contains: **deferred tools** — `tool_search` ranks them with BM25 and loads matches into the conversation's
  `modelTools`, so a loaded tool stays offered after compaction
  (`packages/durable/src/tool-search/tool-search.ts:1-13`); **code mode** — tools called from a program rather
  than a JSON call (`packages/codemode`); a **faux-provider** suite whose package rule is "No real provider
  APIs, keys, or paid tokens" (`packages/coding-agent/test/suite/harness.ts`); **docs-lift evals** — each case
  runs in isolated `without_docs`/`with_docs` containers and reports lift (`packages/evals/README.md:1-14`):
  that tree *prices* the instructions it injects.
Borrow: consumed — three of those are § Open items in `AGENTS.md` (per-turn tool surface, scripted engine,
  docs lift); shipping less, honestly, is how the category's #5 got there

- `deepseek-harness` — `deepseek-ai/deepseek-harness`, TypeScript, developer preview since 2026-08-13:
  **263 687 stars in 76 days** (api.github.com 10-28 — 3 469/day), the fastest mover here and the tree that
  falsified the ladder's growth ceiling (`long-horizon-goal.md` § Rung zero). Its tracker is **off** at 263 k
  (`has_issues: false`, Discussions on) while intake and review run as *code with its own tests*:
  `.github/issue-management/{policy,rules,lifecycle}.mjs` + `policy.test.mjs`, and
  `.github/review-ownership/approval-policy.json` — reviewer **weight** from blame ownership, points
  delegable, published by `weighted-approval.yml`. Four axes, all new to this corpus: (1) **the injected
  corpus is a tested surface** — `snapshots/session/agent-instructions-budget/`, `-budget-chains/` and
  `-group-failure/` pin sessions whose system prompt states its own budget ("Workspace instruction budget 700
  bytes: truncated $DSH_HOME/AGENTS.md from 1900 to 292 bytes", `agent-instructions-budget/session.v4.jsonl`,
  `pin: true`), so what a budget drops is a fixture a reviewer diffs and the model is told; (2) **oversize is
  refused, never truncated** (`docs/config-catalog.md:359`) and every result view carries `truncated`/`total`
  "so a UI never presents a partial result as complete" (`docs/subsystems/tools.md:623`); (3) **a translation
  mirror is a record** — `README.i18n.yaml` pairs each heading's en/zh block by hash outside code blocks and
  re-records with one command, while our P18 mandates one zh mirror and pairs nothing; (4) the first screen
  names the preview and the danger (`SAFETY.md`, `BENCHMARK.md`; § The first screen in the runbook).
Borrow: consumed for the honesty gap in `docs/agent/open-items.md` (our injector drops the tail silently at
  `Sources/ocoreai/WorkspaceContext.swift:229`). Policy-as-data and the pairing record are named patterns, not
  tasks — the gate layer is frozen (10-28), and a new check owes the red it was sampled against.

## How to use this file

1. Where a tree has the answer, cite `file:line` rather than authoring a local variant, and land the change
   with its upstream line, our line, and the gate that goes red on regression.
2. Refresh with the one-liner above, and re-derive the coupling set by hand (`git grep -l <tree> -- Sources
   Tests`): seven trees have zero *tree* coupling — MTPLX, TensorFold, Strata, mlx-serve, opencode, harness2,
   deepseek-harness — so a row left "named, unused" is decoration: use it or drop the name. `make drift`
   checks every bare upstream cite resolves, which is the half a reader acts on.