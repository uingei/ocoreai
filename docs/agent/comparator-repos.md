# Comparator repositories — who is good at what

> Long form behind § *Upstream Audit Dependencies* 5. Cells are a **dated snapshot** read off the
> local clone; re-measure the diary column **from the disk**, so the command cannot itself go stale — the
> hand-typed list it used to carry named 24 trees while 27 sat in `~/references`, i.e. the instrument that
> exists to catch a stale cell was the stalest thing in the file (11-04):
> `for r in $(ls "$HOME/references"); do printf "%s=%s\n" "$r" "$(grep -c -- "$r" CHANGELOG.md)"; done`
> — nothing re-derives these lists since 10-28 (P16 was deleted as prose-shape), so a stale cell is
> yours to notice. Coupling re-derives two ways and both are printed, because they answer different questions:
> `` git grep -lE '`<tree>`|references/<tree>' -- Sources Tests `` counts **cite coupling** (a backticked name
> or a path into its clone); the looser `git grep -l <tree> -- Sources Tests` counts **name mentions** and is
> substring-naive — 11-04: bare `pi` reports **458** files, all of them `api` and `Float.pi`, and `-w` fixes
> `api` but not `let pi`. A **pin** is a build input (`Package.swift:43`); everything else is a comparator.
> Context economy across the field — each tree's own `AGENTS.md` set against the 32 768 B our loader injects
> at — is a cross-tree claim with a denominator, so per § *How to use* 4 it is not homed here: the table and
> the re-derive command are in `comparator-consensus.md` § The injected ruleset.

Each entry is one clone under `~/references/`: what it holds, the axis worth borrowing, how far the audit got.

- `vllm` — Python serving stack; `entrypoints/serve/utils/tool_calls_utils.py`,
  `entrypoints/anthropic/serving.py`
Contains: OpenAI + Anthropic compatibility — parallel-call filtering, `finish_reason` resolution,
  OpenAI→Anthropic field mapping — plus the **intake policy** an AI-assisted PR must satisfy
  (`AGENTS.md:8,21,27,35,39`; full text: adoption-runbook § The intake machine). And since 11-04, in-tree: a Rust
  front-end whose goal is "to rebuild the northbound serving layer in Rust while still talking to the core
  Python vLLM engine process(es) via ZMQ over the existing engine boundary", self-labelled experimental and not
  feature-complete (`rust/README.md:3`, `:5`) — 596 file-touches in 14 d.
Borrow: consumed, cited by file:line (rounds 19–20); our home for the policy is `CONTRIBUTING.md`

- `sglang` — Python serving stack; `srt/entrypoints/openai/{protocol,serving_chat}.py`,
  `srt/entrypoints/anthropic/protocol.py`
Contains: the same compat axis, second opinion — discriminated `delta.type` unions, `tool_choice`
  vocabularies, `/v1/decisions` (the AR route to typed yes/no・choice・score reads —
  `docs/agent/systemone-decisions.md`), and "upgrade the word only if a call landed **and** it stopped
  naturally". Second axis: **permissions as data** — 123 workflow files driven by
  `.github/CI_PERMISSIONS.json` + `.github/MAINTAINER.md` (cites in `adoption-runbook.md`). Third (11-04): the
  same move vllm made — `sglang-server` "Sglang server in rust" shipped as a PyO3 extension
  (`rust/sglang-server/Cargo.toml:3`) — and a **generated API** (`rust/sglang-api-codegen`, `sglang-api-types`),
  which makes two serving trees generating their HTTP contract beside opencode's codegen package.
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
  files (itemised in `adoption-runbook.md`) and `SOUL.md` (the voice a user hears is not the discipline a
  session follows). Its
  `prompt-surface-diff.yml` renders, from production code, the system prompt and `tools[]` a stock install
  sends, per surface and model family, and a stale snapshot fails a test. Third axis, re-read 11-04 at mirror
  `9302ba9e21`: a **skills tier** — 44 under `skills/`
  against **142** under `optional-skills/`, which "are not copied to `~/.hermes/skills/` during setup" and are
  reached by `hermes skills browse|search|install` (`optional-skills/DESCRIPTION.md`; the consequence is §
  Open's tool-surface row, not restated here). And a capability face that carries its own
  refusal boundary in frontmatter: `unbroker` removes a person's data from broker sites and states what it
  will not do — "does **not** defeat anti-bot systems, does **not** act on anyone without recorded consent,
  does **not** remove public records" (`optional-skills/security/unbroker/SKILL.md:23-24`).
Borrow: consumed; `prompt-surface-diff` is the pattern § Documentation Map would use *if* the owner quotes the
  red it must catch — the gate layer is frozen, so it is a named pattern, not a task. The tier is an axis with
  a consumer today (our one published skill, `skills/ocoreai/`), the refusal block is invariant 2 as shipped
  product copy rather than a guardrail.

- `ollama` — Go server; the root pin files `LLAMA_CPP_VERSION=b11963`, `MLX_C_VERSION=57731b00e8…`, both
  changed since the 11-02 read while this row still quoted the old values (see § How to use 3)
Contains: two engine families (llama.cpp + MLX C) behind one local API, each pin versioned separately — the
  closest published analogue to our MLX + CoreAI dual path, and (mirror `e9fde36d`, re-read 11-04) a local AR
  server shipping the Jev axis as `/v1/systemone` (`api/client.go:449`) on an engine-internal
  `ScoreRequest`→`ScoreResponse{Logits}` lane whose question order is load-bearing (`systemone-decisions.md`
  § Shape C).
Borrow: consumed for the lane shape (stars: the runbook's leaderboard); the published-logits seam stays the
  owner call — their lane proves it possible, it does not make ours exist

- `mlx-serve` — **the closest whole-product analogue to our own sentence** (audited 11-04 at `8d82ebe2`,
  re-read at `6b39f8b8` the same day — three `docs/reference.md` numbers moved +1, no claim did; 388 commits
  in 14 d; Zig engine + SwiftUI app): "chat, coding agents, images, video, music, speech and 3D.
  One native app and one local server that speaks the OpenAI, Anthropic and Ollama APIs. It runs offline,
  needs no Python and no account" (`README.md:5`), on five engines (`src/engines/*`, ane among them) behind ~40
  model-family plugins (`src/plugins/`) and one SDK (`src/sdk/`).
Contains: the convention that a behaviour claim ships as a committed shell probe (the rule behind
  `scripts/probes/`); **native MTP with a runtime acceptance gate** — speculation stops mid-decode once
  per-draft acceptance falls under break-even and stays off for the request (`docs/performance.md:15`, `:20`);
  a **shipping ANE lane** — dense Qwen packs entirely on the Neural Engine to 64K contexts across an Ultra's two
  ANEs, a model it cannot run or a load that does not fit serving "on the GPU, logged by name" (`docs/cli.md:76`,
  `docs/reference.md:441`, `:451`); head-to-head decode numbers against LM Studio, oMLX and MTPLX **on those
  trees' own checkpoints**, each on its shipping defaults, so there is "no best-config collapse"
  (`docs/performance.md:9`); and contracts it declares unverified for its embedded engines
  (`docs/known-issues.md:46`).
Borrow: what it does *not* do is the surviving wedge — it hosts Claude Code and Codex rather than *being* the
  agent (`README.md:49`), pastes a screenshot instead of capturing the screen
  (`../references/mlx-serve/app/Sources/MLXServe/Views/ChatView.swift:3472`; no `ScreenCaptureKit`/`SCStream`
  symbol in its `app/Sources` — absence of symbols, not a run), and its ANE lane **refuses grammars and forced
  tool calls by name** (`docs/reference.md:454`). The part-by-part verdict is `long-horizon-goal.md` § Rung
  zero 4's — one home; this row holds the axes.

- `Rapid-MLX` — **the 28th tree, and the one that ships our own sentence** (`raullenchai/Rapid-MLX`, Apache-2.0,
  Python engine + a 332-file SwiftUI app; 4 097 stars api.github.com 11-04, created 02-25, HEAD `8178a75`
  11-03, 405 commits in 14 d, **290 tags**). Registered the day it was cloned, mid-round. Its first screen is
  an agent launch, not a model: "Run Codex, Claude Code, OpenCode, Pi, Hermes, Crush or Goose with a local
  model on Mac: `rapid-mlx launch <agent>`" (`README.md:7`), over "OpenAI- and Anthropic-compatible LLM
  inference server for Apple Silicon, built on MLX, focused on reliable tool calling for coding agents"
  (`README.md:13`).
Contains: (1) **the harness side, built** — `rapid_mlx/agents/profiles/` holds 17 harness configs, **ten of
  them trees this file tracks**, `isolated.py:23` names the nine it can isolate, `--remove` undoes it, and
  `config_merge.py:1-15` documents the two ways a naive merge deletes the *user's* entries (pi's id-keyed
  `models` list, dsh's `cordis.patch.yml` layers). (2) 29 tool-parser modules with an auto-detect fallback
  (`rapid_mlx/tool_parsers/`) against our `Parsers/*`. (3) spec decode as data —
  `spec_decode/{capability,registry,report}.py` over `mtp/`, `dspark/` and `speculative/{native_mtp,dflash,
  ddtree,suffix_decoding}`, plus a `tensorfold_*` family: this tree *consumes* a tree that is a comparator to
  us. Its rule: "Registry flags are recommendation evidence. They are not permission checks… runtime preflight
  owns compatibility" (`spec_decode/capability.py:4-6`). (4) **a benchmark as a contract** — an immutable
  versioned protocol file per measurement, one JSON-Schema record, runs archived locally and nothing leaves
  the Mac until `share` (`proto/community-benchmark/v1/`), unobserved settings recorded `unknown`, "never
  guessed" (`community-benchmarks/README.md:54`), an explicit never-sent list (`:59`), and the decode formula
  reconciled with llama.cpp `tg` / vLLM TPOT while its own pre-0.13.4 discontinuity is disclosed (`:46`).
  (5) it will not *grade* what it cannot confine: no `sandbox-exec` →
  `Grade(False, 0.0, "coding grader requires macOS sandbox-exec")`
  (`scripts/benchmark_glm53_real_tasks.py:226-228`). (6) an `AGENTS.md` that is an **org chart, not a
  rulebook**: six persistent roles, each with host, worktree prefix, escalation target and definition of done,
  19 438 B in a single root file — 59 % of the 32 768 B our own loader injects at.
  (7) a computer-use lane, and it is not a demo: `rapid_mlx/computer_use/{perception,ax_driver,backend}.py`
  behind `routes/cua.py`, where every element gets a session ref bound to the live AX element (`CFEqual`) and an
  action naming a ref from a stale observation **is refused**, one run at a time because the AX/CGEvent computer
  is a shared resource, with an explicit approval endpoint (`docs/engineering/decisions/
  2026-10-02-cua-hands-background-input.md`: hands that drive a window without taking the user's cursor).
  (7) **its own agent, with hands.** `rapid_mlx/chat_runtime/tools/__init__.py:318-331` registers 12 tools —
  `read_file`/`grep`/`glob`, then `write_file`, `patch`, `terminal`, `execute_code`, `delegate_task`, plus web
  and weather — each carrying a risk class, and the result wrapper debits the context budget for every non-read
  class (`bounded_result`, `:70,81`). They are **on by default**
  (`action_policy.py:26-30`) and the module's own docstring draws the line: "Deterministic approval heuristics,
  **not an OS sandbox**" (`:3`), with the file policy's reason string naming its undo checkpoint. On the wire
  the same runtime is served by `routes/agents.py`, and tool calls are grammar-constrained end to end: an
  llguidance grammar built from `tools` + `tool_choice` "STRUCTURALLY GUARANTEES" the call names a real tool and
  satisfies its schema, while constraining "only the FORM of a call, never the decision"
  (`api/tool_grammar.py:1-8`). Its computer-use lane is item (7) above.
Borrow: four axes, **no home here today** — the reversible harness profile (five of the seven serving trees ship
  theirs: `comparator-consensus.md` § The harness side is already built, on their side), a machine-readable eval
  record with an immutable protocol (`scripts/eval/` has neither), confinement at the child boundary (same file,
  § Where the field confines a child), and a **risk class per tool that prices its own context debit** (ours
  scores 6 of 40 tools and prices bytes per row, never per risk). Against `long-horizon-goal.md` § Rung zero 4
  this tree is the corpus's hardest read: it holds an agent, screen input, speech both ways, image and video,
  MCP and constrained tool calling, so two of the rung's three parts do not survive it — the verdict is the
  rung's (§ Rung zero 4, re-measured 11-04), not this row's. What it does not hold is the *shape*: an app
  bundling a Python sidecar rather than one binary, and no ANE lane anywhere in the tree.

- `harness2` — `google-research/harness2`, Python agent harness (`dependencies/ASSETS.json` path→sha256,
  `scripts/check_provenance.py` exit 1 on any changed or missing asset, `dependencies/PINNED.md`); 21 commits,
  17 of them on 11-01 — re-read at mirror `6868817`
Contains: **release-asset provenance** — every redistributed file pinned by digest in a committed map, with a
  checker that fails on drift. Second axis, new since 10-20: **a day spent making grades unforgeable** —
  incomplete judge output stays *unscored*, not failed (`1f8e95e`); two fenced verdicts in one reply are
  rejected, not first-parsed (`591554d`); a judge exception leaves the grade ungraded (`0865e63`); a runner
  that kept any attempt with a non-empty output dir let "the improver, composer and reflection … read a run
  that looked as if the agent chose to stop" (`6868817` — it appends one error event, and records exit 124 as
  the time limit, `-9`/`137` as SIGKILL). `0a40ff8`: nothing recorded *which task* a cached rollout answered,
  so editing a task's instructions under the same id let resume pass the old answer off as a completed result.
Borrow: consumed — adopted as manifest schema 2 (`pin` + `licenseSha256` + `verifiedAgainstPin`, `vendored[]`)
  in `docs/agent/third-party-notices.md`. The second axis reads as **two confirmations and one gap**: our board
  digests the task bytes and the tool declarations into its conditions line and refuses to compare across a
  difference (`scripts/eval/_conditions.py:46-57`), writes the wire's own `finish` word beside every task
  (`scripts/eval/_eval.py:349`), and never resumes a scored run, so `0a40ff8`'s class cannot arise here. The
  gap is `742d48f`, whose subject is the finding: "Every launcher except the improver passed the whole host
  environment to agent subprocesses, keys included" — we do that at six `Process()` sites; proof, scope and
  the owner call are in `open-items.md`.

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
  (`packaging/ENGINE-COMPONENT.md`); installers fetch the engine for the GPU present. Read again 11-04
  (2 049 commits in 14 d, 71 tags): "No account needed" (`README.md:25`), and it **hosts** the harnesses rather
  than being one — "Claude Code · Codex CLI · OpenCode · oh-my-pi · pi.dev · Hermes Agent · OpenClaw" behind
  `strata connect` (`README.md:168`); the built UI ships with an isolated **simulated-data preview** a stranger
  can open with no model resident (`apps/host/README.md:10`); and a README whose status claims went stale was
  *demoted*, not edited — kept as `docs/README-historical.md`, labelled historical (`apps/host/README.md:12`).
Borrow: consumed for the dry-run (`Models/ModelDownloadDTO.swift` `DownloadPlan` + probe 36). This row's other
  half — "integrity checking of runtime-fetched artefacts is still open" — was stale as written; the honest
  shape is **route-named**. Bytes we fetch ourselves are re-hashed against the digest the hub declared (size
  compare when it declares none; a cache hit is trusted as found, the trade ollama takes), pinned by
  `DownloadIntegrityTests`(10) + probe 43 — `Models/ModelScopeDownloader.swift:1136-1144`, compare at `:1165`.
  What is genuinely open is the `hf:` route, where the bytes arrive through upstream `HubClient`
  (`Engine/MLXBridge.swift:33-34`), whose file record carries an ETag for caching and no weight digest
  (`.build/checkouts/swift-huggingface/Sources/HuggingFace/Hub/File.swift:11`) — § Upstream's to carry, not a
  second local hasher.

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
  even the only native Apple app here (mlx-serve, MTPLX, omlx ship `@main … App` shells and all four gate their
  GUI harder than we do; `Rapid-MLX` ships a fifth behind an explicit `main.swift`
  (`apps/rapid-mac/Sources/Rapid/main.swift:7`) — a hand-typed list, so read it as a floor, not a census). What its headline is made of — first-screen privacy contract, install machine,
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
Contains (11-04): an axis the 81-line README cannot show — `codex-rs/guardian-context`, "shared context sections
  for synchronous Guardian review and asynchronous scoring", where **a contributor that fails aborts collection
  rather than returning partial context** (`src/lib.rs:5`), contributors declare their scope once, and hosts own
  admission/compaction/lifecycle; the section set carries authorization truth (`RootConversationSection`,
  `TrustedUserAnswersSection`) and its own budget module. Fail-closed context assembly is invariant 2 applied to
  the prompt, and it is the one part of this tree worth reading again.
Borrow: the README is a signpost, not a manual; ours is a manual, and this file's header is that finding
  measured on ourselves. Owner ruled codex an ordinary comparator on 11-03 (§ Upstream 5), so this is a
  registered axis, not a debt.

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
  on Range + If-Range identity. Third axis, read 11-04 at mirror `461285bbf`, unregistered until now:
  **`crates/goose-local-inference`** — our dual-engine pool in another stack, with three decisions we have not
  made. `llamacpp` and `mlx` sit behind one trait whose contract includes `available_memory_bytes()`
  (`backend.rs:33`, `:49`), so memory truth belongs to the backend that owns the allocator, not to a router
  reading OS counters; `compact_tools_json` hands a prompt **name + description and no parameter schema**
  (`tool_parsing.rs:4`); and a model without native tool calling gets an emulator path whose fences include
  on-demand discovery (`list_functions`/`get_function_details`, `tool_emulation.rs:5`, `:62`), so the schema
  arrives for the tool asked about rather than all 40 up front. Its honesty is written at the seam: history
  entries the emulator syntax cannot represent are "silently dropped" (`lib.rs:613`).
Borrow: ACP is a new core surface (ladder rung 6) ⇒ an owner call, not an audit. The three are **axes, not
  debt**: no `BackendProtocol` here by decision (root § Architecture), `tools[]` carry schemas because the wire
  promises them (`ToolCallWireContractTests`), and deferred tools already have one home (`pi`'s `tool_search`,
  § Open's tool-surface row.

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
  refused, never truncated** (`docs/config-catalog.md:378`, re-anchored 11-04 — it was `:359` at last read) and
  every result view carries `truncated`/`total`
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

- `cline` — **the 27th tree: cloned here since the corpus began, never registered until 11-04** (the row that
  falsifies this file's last completeness claim — § *How to use* 2). TypeScript monorepo, 71 277 stars,
  82 commits in 14 d against **855 tags**, four publish legs (`cli-`/`desktop-`/`sdk-publish.yml`,
  `ext-vscode-publish.yml`), install by npm, VS Marketplace and JetBrains (`README.md:51`, `:80`, `:92`),
  13 per-provider config pages under `docs/provider-config/`; tracker open with 1 757 issues.
Contains: (1) **the agent published as an SDK** — `sdk/packages/{shared,llms,agents,core,sdk,ui}` carrying its
  own `AGENTS.md`, `ARCHITECTURE.md`, `CHANGELOG.md` and a publish leg, so another product embeds the engine
  instead of hosting it: opencode's codegen rung reached from the other end. (2) **an eval board that says it is
  half-off** — "Smoke tests (Layer 2) are partially disabled while the eval framework is repointed at the new
  SDK CLI", the scenarios kept and the command still run against whatever `cline` is on `$PATH`, the regression
  workflow left off until someone wires the build (`evals/README.md:5`) — invariant 2 applied to a scoreboard,
  which is the failure our board's `tools[]` row is about. (3) **known-reds named inside the injected ruleset**:
  two tests whose failure is a cloud-env artefact are written into `AGENTS.md:14-15` with the cause and the
  instruction not to chase them; ours lives one hop out in `docs/agent/build-gate-reality.md` instead of in the
  model's context. (4) **intake defended against agents** — `repo-strip-agent-badges.yml` and
  `repo-delete-agent-promo-comments.yml` are the only workflows in this corpus that treat AI-generated noise on
  the issue tracker as the surface it is.
Borrow: axis, **no home here today** — we ship no SDK, no package-manager or marketplace route (a DMG and a
  source build: `README.md:23`, `:35`), and nothing machine-defends our intake. Re-read the day we publish a
  client or open intake; (3) already has a home.

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
  here since the corpus began and no row admitted it. The completeness sentence it wrote, and why the scan it
  cited could not see a missing row, live once in `comparator-consensus.md` § What the corpus did not know
  about itself (one home). Sibling of the row above: that one is a flagship's tech report, this one is what the
  family promises.
Contains: the vendor's own acceptance framing — the series is "designed to carry complex, multi-step tasks
  through to completion with greater reliability" (`README.md:19`), scored as "better handling of environment
  feedback" (`:23`) — the four axes of `long-horizon-goal.md` restated by whoever trains the model our board
  runs. Plus two **wire words** the family is trained on: `reasoning_effort`, and `preserve_thinking`, which
  retains "reasoning context from historical messages" (`:25`).
Borrow: `preserve_thinking` is the vendor's name for the cost § Open's thinking-uncounted row already owes;
  the consequence and its owner live there, not twice.

## How to use this file

1. Where a tree has the answer, cite `file:line` rather than authoring a local variant, and land the change
   with its upstream line, our line, and the gate that goes red on regression.
2. Re-derive coupling both ways (§ header) **from the disk's tree list**, with `-w` on the name measure — bare
   `pi` matches `Float.pi` (458 files) and bare `cline` matches "decline" (7), so the count is wrong in both
   directions without it. The dated counts, the trees that score zero, and why this instruction has twice
   disagreed with its own command are a self-measurement with a denominator, so they live once in
   `comparator-consensus.md` § What the corpus did not know about itself (bullet 5).
3. **A resolved cite is not a verified claim.** 11-04 read 64 cites here and in `competitor-iteration-paths.md`
   off their mirrors: no claim about what a tree does was false, five positions were stale, and one had become a
   blank line every gate passed. Which instrument sees which half, and why the answer is an inline quote rather
   than a second scanner: `competitor-iteration-paths.md` § What that gate does not see.
4. **This file answers "what does tree X hold". A claim that the *field* does Y is a different question with a
   different denominator**, so it does not live here: `scripts/comparator-consensus.sh` measures it off the
   same mirrors and `comparator-consensus.md` holds the verdicts. Adding a tree? Add it to the disk, not to a
   typed list, and both instruments pick it up.
