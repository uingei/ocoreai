# Comparator repositories — who is good at what

> Long form behind § *Upstream Audit Dependencies* 5. Cells are a **dated snapshot** read off the
> local clone; re-measure the diary column:
> `for r in vllm sglang vllm-metal omlx mlx-serve MTPLX ollama TensorFold Strata splash openclaw hermes-agent harness2 goose opencode pi deepseek-harness claude-code qwen-code SWE-bench OpenHands Qwen3.8-Flash-Next Qwen3.8; do printf "%s=%s\n" "$r" "$(grep -c -- \"$r\" CHANGELOG.md)"; done`
> — nothing re-derives these lists since 10-28 (P16 was deleted as prose-shape), so a stale cell is
> yours to notice: `git grep -l <tree> -- Sources Tests` re-derives the coupling set in one line. A **pin**
> is a build input (`Package.swift:43`); everything else is a comparator.
> Context economy, ours 10-29/field 10-28, over each tree's own `AGENTS.md` set — root bytes / corpus bytes / **deepest
> root→cwd chain against the 32 768 B the loader injects**: mlx-serve 26 486 / 269 381 / 69 273 (211 % of the
> cap), deepseek-harness 19 113 / 96 369 / 55 362 (169 %), opencode 15 102 / 86 866 / 37 627 (115 %),
> openclaw 19 374 / 113 906 / 34 186 (104 %), **ocoreai 21 453 / 47 484 / 32 753 (100 %, 15 B of headroom)**,
> vllm 6 358 / 48 844 / 31 675, hermes-agent 11 952 / 159 599 / 30 192, pi 8 845, codex 0 / 3 441, ollama 358.
> Re-measure: walk the tree for `AGENTS.md`, sum each file's ancestors up to the root, divide by 32 768 — the
> semantics our loader implements (`Sources/ocoreai/WorkspaceContext.swift:224-233`). Four trees read a
> ruleset their own loader truncates and three never say so; ours is 15 B from that line and names what it
> drops.

Each entry is one clone under `~/references/`: what it holds, the axis worth borrowing, how far the audit got.

- `vllm` — Python serving stack; `entrypoints/serve/utils/tool_calls_utils.py`,
  `entrypoints/anthropic/serving.py`
Contains: OpenAI + Anthropic compatibility — parallel-call filtering, `finish_reason` resolution,
  OpenAI→Anthropic field mapping — plus the **intake policy** an AI-assisted PR must satisfy
  (`AGENTS.md:8,21,27,35,39`; full text: adoption-runbook § The intake machine).
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
Contains: loop shape, tool-result handling. Second axis (10-28): the ops machine behind the number — 57 workflow
  files (itemised in `adoption-runbook.md`) and `SOUL.md` — the voice a user hears is not the discipline a session follows. Its
  `prompt-surface-diff.yml` renders, from production code, the system prompt and `tools[]` a stock install
  sends, per surface and model family, and a stale snapshot fails a test.
Borrow: consumed; `prompt-surface-diff` is the pattern § Documentation Map would use *if* the owner quotes the
  red it must catch — the gate layer is frozen, so it is a named pattern, not a task

- `ollama` — Go server; `LLAMA_CPP_VERSION=b11669`, `MLX_C_VERSION=a341b492…`, a 358 B `AGENTS.md`
Contains: two engine families (llama.cpp + MLX C) behind one local API, each pin versioned separately — the
  closest published analogue to our MLX + CoreAI dual path, and (audited 11-02, mirror `74686a75`) a local AR
  server shipping the Jev axis as `/v1/systemone` on an engine-internal `ScoreRequest`→`ScoreResponse{Logits}`
  lane whose question order is load-bearing (`systemone-decisions.md` § Shape C).
Borrow: consumed for the lane shape (185 660 stars, api.github.com 11-02); the published-logits seam stays the
  owner call — their lane proves it possible, it does not make ours exist

- `mlx-serve` — **the closest whole-product analogue to our own sentence** (audited 11-04, mirror `8d82ebe2`,
  389 commits in 14 d; Zig engine + SwiftUI app): "chat, coding agents, images, video, music, speech and 3D.
  One native app and one local server that speaks the OpenAI, Anthropic and Ollama APIs. It runs offline,
  needs no Python and no account" (`README.md:5`), on five engines (`src/engines/{mlx,llama,ds4,ane,own_thread}`)
  behind ~40 model-family plugins (`src/plugins/`) and one SDK (`src/sdk/{grammar,kv,tokenizer,quant,media}`).
Contains: the convention that a behaviour claim ships as a committed shell probe (the rule behind
  `scripts/probes/`); **native MTP with a runtime acceptance gate** — speculation stops mid-decode once
  per-draft acceptance falls under break-even and stays off for the request (`docs/performance.md:15`, `:20`);
  a **shipping ANE lane** — dense Qwen packs entirely on the Neural Engine to 64K contexts, split across an
  Ultra's two ANEs, a model it cannot run or a load that does not fit serving "on the GPU, logged by name"
  (`docs/cli.md:76`, `docs/reference.md:440`, `:450`); head-to-head decode numbers against LM Studio, oMLX and
  MTPLX **on those trees' own checkpoints**, each on its shipping defaults so there is "no best-config collapse"
  (`docs/performance.md:9`); a complete rung-2 quartet (DMG, cask, self-update, iPhone app); and contracts it
  declares unverified for its embedded engines (`docs/known-issues.md:46`).
Borrow: what it does *not* do is the wedge — it hosts Claude Code and Codex instead of *being* the agent
  (`README.md:49`), takes a pasted screenshot rather than capturing the screen
  (`../references/mlx-serve/app/Sources/MLXServe/Views/ChatView.swift:3472`; no `ScreenCaptureKit`/`SCStream`
  symbol anywhere in its `app/Sources` — absence of symbols, not a run), and its ANE lane **refuses grammars, forced tool calls, a reasoning budget
  and images by name** against a declared `Caps` set (`docs/reference.md:453`). The shortened list is
  `long-horizon-goal.md` § Rung zero 4's, restated there 11-04.

- `harness2` — Python agent harness: `ASSETS.json` (path→sha256), `check_provenance.py` (exit 1 on any
  changed or missing asset), `PINNED.md`
Contains: **release-asset provenance** — every redistributed file pinned by digest in a committed map, with a
  checker that fails on drift.
Borrow: consumed — adopted as manifest schema 2 (`pin` + `licenseSha256` + `verifiedAgainstPin`, `vendored[]`)
  in `docs/agent/third-party-notices.md`

- `TensorFold` — Zig engine, "Metal or CUDA kernels directly" (`README.md:4`; `zig/`, `app/`, HIP docs), 1 843
  commits in 14 d, read 11-04. Its axis is **invariant 1 as a user-facing artefact**: the **receipt**, a
  portable evidence record a measurement travels in.
Contains: `docs/receipts/` holds 16 (MTP chain, KV pages, drafter counts, per-device), each naming its own
  pinned commits (`README.md:221`); a receipt carries hardware and attempt rows and **never** prompt text,
  output, machine names, serials, addresses or local paths (`docs/community-benchmarks.md:16`); a run whose
  reply cannot qualify is still written, "with null fingerprints and exit status 1" (`docs/cache-benchmarks.md:69`);
  draft counts stay local because the published board has no field for them, "since equal timings do not" prove
  a drafter ran (`docs/community-benchmarks.md:16`); a claim from a stale device says "have not been reproduced
  on the maintained tree" (`docs/WINDOWS.md:6`).
Borrow: the shape, not the machinery — `scripts/eval/`'s run dirs are evidence but not a *portable* one, and
  nothing here publishes one. Named pattern only: the gate layer is frozen (10-28), and a published receipt
  needs a consumer that exists today.

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
Contains/Borrow: touched, mostly out of stack for a Swift-native engine; where the Jev axis was first
  found named (`docs/structured_decisions.md:3` → `systemone-decisions.md`).

- `openclaw` — **the #1 repo in this category on GitHub** (393 709 stars 11-02, launched 2025-11-24 at
  1 163/day), TypeScript + 1,596 Swift — and not
  even the only native Apple app here (mlx-serve, MTPLX, omlx ship `@main … App` shells; all four gate their
  GUI harder than we do). What its headline is made of — first-screen privacy contract, install machine,
  appcasts, channels, skills — is itemised in `docs/agent/adoption-runbook.md`; it also states the
  load-bearing line for our wedge: local models are **plugins it swaps**, not a rival it builds. Two of its
  120 workflows have no analogue here: `maturity-scorecard.yml` publishes a maturity score generated from
  committed QA evidence as a PR diff — the score moves only by measurement; `update-migration.yml` exercises
  a user's stored config across the upgrade — our persisted keys declare their scope (§ Working here in
  `AGENTS.md`) but nothing proves they survive one. Iteration shape: `docs/agent/competitor-iteration-paths.md`.
Borrow: consumed — adoption machine audited 10-28 (`docs/agent/long-horizon-goal.md` § Rung zero)

- `splash` — Python MLX server; `dev/tests/server/test_anthropic_contract.py`, `api_shapes.py`
Contains: the usage identity a client sums — `count == input + cache_read` (`:889`) — and the keys a face must
  leave absent when it measured no creation.
Borrow: consumed (`AnthropicCacheUsageTests` + probe 22)

- `codex` — comparator, not authority (owner's ruling 11-03; the policy is root § Upstream 5), Rust. Worth
  copying: how a first-party agent documents itself — 131 273 stars on an **81-line README**, because the
  surface lives in `docs/` (`agents_md.md`, `skills.md`, `execpolicy.md`, `sandbox.md`, `slash_commands.md`,
  `install.md`), with install by script, npm and cask (`README.md:19`, `:47`) and 3 441 B of guides against
  our 21 453 B root.
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
  **cassette replay** (`http-recorder/README.md`: record real HTTP once, replay it) — the axis our harness lacks. Second axis (10-28;
  222 385 stars, 1 126 commits in 14 d, 1 156 tags): the intake and rehearsal-release machine (cites:
  `adoption-runbook.md`).
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
  corpus is a tested surface** — `snapshots/session/agent-instructions-budget*/` pin sessions whose
  system prompt states its own budget (fixture text quoted 10-28; `pin: true`), so what a budget
  drops is a fixture a reviewer diffs and the model is told; (2) **oversize is
  refused, never truncated** (`docs/config-catalog.md:359`) and every result view carries `truncated`/`total`
  "so a UI never presents a partial result as complete" (`docs/subsystems/tools.md:623`); (3) **a translation
  mirror is a record** — `README.i18n.yaml` pairs each heading's en/zh block by hash outside code blocks and
  re-records with one command, while our P18 mandates one zh mirror and pairs nothing; (4) the first screen
  names the preview and the danger (`SAFETY.md`, `BENCHMARK.md`; § The first screen in the runbook).
Borrow: consumed for the honesty gap in `docs/agent/open-items.md` (our injector drops the tail silently at
  `Sources/ocoreai/WorkspaceContext.swift:229`). Policy-as-data and the pairing record are named patterns, not
  tasks — the gate layer is frozen (10-28), and a new check owes the red it was sampled against.

- `claude-code` — first-party CLI ledger, registered 11-02 on the owner's word (154 258 stars api.github.com,
  ~257 release objects; its 1 130 515 B `CHANGELOG.md` is a product-behaviour diary — every Fixed line an observed defect)
Contains: invariant-2 copy as shipped (`CHANGELOG.md:687` failed search ≠ empty search; `:272-273` rewind copy
  over-promising), the dated-deprecation format (`:11`), stall/steer vocabulary beside our terminal-word § Open (`:36`, `:429`).
Borrow: live tracking axis — the track/mine/verify loop and last-read marker live in CHANGELOG 11-02(112); it shows
  field alignment, never behaviour (our gates keep that job). last-read `v2.1.317` (mirror `964d695`)

- `qwen-code` — `Qwen-Coder/qwen-code`, TypeScript coding-agent CLI, registered 11-03 (mirror refreshed 11-04 to
  `35aa4b76ae`, 689 commits in 14 d); peer of `claude-code`/`codex`/`opencode`/`goose`/`pi`
Contains: **the computer-use axis as a vendored dependency** — `packages/cua-driver` is a vendored Rust CUA
  runtime whose MCP interface "exposes 19 Computer Use tools", plus a one-shot CLI and in-process Python/TS
  SDKs, with the upstream snapshot in `.vendored-from` and every local difference written in
  `.vendored-patches.md` (`packages/cua-driver/README.md:4`, `:8`, `:147`) — a *patch ledger* beside our
  per-file-header baseline + `make drift`; the same problem, one home each. Its hottest directory is a hosted
  control plane (`packages/managed-agent-server`, 3 357 touches in 14 d): loopback by default, and "with the
  default `auto` mode a non-loopback address refuses to start" (`README.md:15`), the CLI fetching a server JAR
  into "the verified versioned cache" (`:25`).
Contains (11-03): the trust axis written down the day it landed — `Config.isExplicitlyTrustedFolder()` separates
  *folder trust* from *authorisation to run what the repository supplied*: project skill/subagent hooks,
  project skill permission grants and workspace `.lsp.json` commands need the affirmative signal, an IDE
  denial wins, disabled trust denies, a lost signal cannot leave grants alive through the legacy default,
  and only the loader — never the JSON — decides whether a config came from the workspace
  (`docs/design/2026-11-03-project-execution-trust.md`).
Borrow: axis, **no home here today** — measured absence: disk skills load only from the directory the
  caller hands over and the app hands `nil` (`Skills/SkillRegistry.swift:65`, `App.swift:391`), the three
  skill tools are read-only (`Tools/BuiltInTools.swift:73,111,142`), and an MCP command reaches a process
  only through an endpoint built in-process (`MCP/MCPBridge.swift:941` → `MCP/MCPStdioClient.swift:247`).
  Re-read this entry the day we add workspace-scope MCP, hooks or skills.

- `SWE-bench` — `princeton-nlp/SWE-bench`, Python benchmark harness, registered 11-03 (HEAD `02e7a74`,
  09-02); the big sibling of our own `scripts/eval/`
Contains: a vacuity floor argued in our own words — `SUITE_RAN` (`swebench/harness/grading.py:31`) demands
  a *non-zero* run count as evidence, because karma prints `Executed 0 of 0` and under `FAIL_ONLY` an empty
  status map scores every test resolved; no parsed results **and** no sign of running ⇒ invalid, not a pass
  (`:142`, `:160`), and the parsed verdict is cross-checked against the test command's exit status since a
  patch can print its own `PASSED` lines (`:163`).
Borrow: confirmation, nothing to take — our halves already bite: an empty `expect_cmd` is a harness fault
  (`scripts/eval/run.sh:323`), an empty artefact snapshot fails the run (`:342`), and a verifier is a shell
  rc rather than parsed text, so an answer cannot forge its own evidence.

- `OpenHands` — the Agent Canvas React/TypeScript frontend, registered 11-03 (`AGENTS.md:5`; HEAD 11-03)
Contains: two mechanisms this repo already gates harder. i18n: `src/i18n/translation.json` generates
  `declaration.ts` and `scripts/check-translation-completeness.cjs` confirms locale coverage
  (`AGENTS.md:8-10`) — ours requires each delivered table to span every `StringKey` exactly once, with no
  orphan, no blank value, real CJK where expected and matching format-specifier arity
  (`Tests/ocoreaiTests/LocaleResolutionTests.swift:31,43,55,74,92`) plus no copy outside the table (`:116`).
  And a harness note that corroborates ours: "the persistent shell can garble long multi-line `commit -m`
  bodies … use `git commit -F <file>`" (`AGENTS.md:16-18`) — the incident class our `-F -` habit exists for.
Borrow: axis only, no new gate. No engine here, so its axes are UI state and locale, not serving.

- `Qwen3.8-Flash-Next` — `QwenLM` README + 28-page tech report, registered 11-03 (HEAD `6988587`, 08-27);
  the corpus's first **model** tree — the other 24 are engines, harnesses and products, and nothing read the
  axis of what the next twelve months will run on.
Contains: 125B-A6B MoE, a 3×Gated DeltaNet + 1 full-attention layer schedule (QSA from CPT on) — 7.6× prefill
/ 4.9× decode at 1M kernel level, RULER >512K 90.08 → 93.00 — plus a **native MTP module** reusing QSA
top-k indices across draft steps (mean accepted length **4.06** at four steps, Tab. 4: the number our lane owes
at rung 3's acceptance gap); +51B N-gram embedding tables prefetched from host memory — the capacity route
unified memory is built for, rung 4's wedge made concrete; 256K native (`../references/Qwen3.8-Flash-Next/README.md:115`);
and a NoPE ablation whose post-training endless-generation rate jumps (§2.1.1) — the field's stalls are
trained-in, one more datum on the terminal-word call. At pin `b8d4935ab`: `Libraries/MLXVLM/VLMModelFactory.swift:95-98`
registers `qwen3_5|qwen3_5_moe|qwen3_8|qwen3_8_moe` onto `Qwen35` (`GatedDeltaNet`, `HybridAttentionSchedule`)
and `Qwen35MTP` (`Libraries/MLXVLM/Models/Qwen35MTP.swift:99`); QSA and N-gram appear **zero** times pin-wide
⇒ the flagship will not load there (inference by absence, not run); dense `Qwen3.8-27B-4bit` does
(`VLMModelFactory.swift:286`); the on-disk `Jundot` `…-mtp` cache entries are 12 KB README stubs — entry
presence, not weight presence.
Borrow: the priced shape the board's one-checkpoint curve aims at (§ Open in `open-items.md`); what it cannot
price is exactly what this family is: MTP acceptance, GDN cache economics, 256K tool calls. Closing it is an
owner download decision plus an upstream QSA/N-gram port — not gate work.

- `Qwen3.8` — the **series umbrella** (`QwenLM/Qwen3.8`, five tracked files: README, LICENSE, two issue forms,
  `inactive.yml`; HEAD `2ea10dc`, 08-17, 0 commits in 14 d). Registered 11-04 because the tree has been cloned
  here since the corpus began and no row admitted it — 26 on disk, 26 rows here, counted by the P1 scan.
  Sibling of the row above: that one is a flagship's tech report, this one is what the family promises.
Contains: the vendor's own acceptance framing — the series is "designed to carry complex, multi-step tasks
  through to completion with greater reliability" (`README.md:19`), scored as "better handling of environment
  feedback" (`:23`) — the four axes of `long-horizon-goal.md` restated by whoever trains the model our board
  runs. Plus two **wire words** the family is trained on: `reasoning_effort`, and `preserve_thinking`, which
  retains "reasoning context from historical messages" (`:25`).
Borrow: `preserve_thinking` names a cost we owe and do not count — § Open's thinking-uncounted row (probe 44
  §2, no `reasoning_tokens`) means a caller that retains thinking pays tokens we cannot price for it. Inference
  from a README, not a measured interaction; the probe line that would settle it belongs to whoever owns
  `reasoning_effort`'s gate (`ReasoningEffortHonestyTests`(9) + probe 38).

## How to use this file

1. Where a tree has the answer, cite `file:line` rather than authoring a local variant, and land the change
   with its upstream line, our line, and the gate that goes red on regression.
2. Refresh with the one-liner above, and re-derive the coupling set by hand (`git grep -l <tree> -- Sources
   Tests`): seven trees have zero *tree* coupling — MTPLX, TensorFold, Strata, mlx-serve, opencode, harness2,
   deepseek-harness — so a row left "named, unused" is decoration: use it or drop the name. `make drift`
   checks every bare upstream cite resolves, which is the half a reader acts on.
