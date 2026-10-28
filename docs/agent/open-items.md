# Open — measured, unresolved

The long form of § Open in `AGENTS.md`, which owes only the address. Nothing here is a capability claim:
where a number is unmeasured it says so, and where a fix is blocked by the host or by upstream it names
which. A resolution goes to `docs/agent/closed-items-log.md`; a decision becomes a rule in `AGENTS.md` or
the area guide, with its gate. Per-item evidence is in `CHANGELOG.md` (grep the symbol).

- **`/v1/models/:model/…` needs `%2F`** (Handlers/) — accepting a slash costs a second routing truth, so the
  wire shape stays pinned in `Handlers/AGENTS.md` § Endpoint Promises and the owner call stays open here.
- **A stall stops MTP hard, the std lane only by consent** (Tools/, Engine/) — the ladder and
  `LoopStallTerminationTests`(6) landed; upstream `mlx-swift-lm`'s `restart:` loop (ChatSession.swift:1154) still has no
  cap, and a std-lane hard stop throws out of `toolDispatch` (:1632) reaching the wire as an error, not a
  finished turn — the terminal word for four faces is the owner call.
- **CoreAI / macOS 27 items unverifiable on this host** (Engine/) — three `@available(macOS 27.0, *)` or
  SDK-gated sites (detail: `docs/agent/build-gate-reality.md`) ⇒ no blind fix and no claim of one; their
  suites now skip on this OS through `PlatformPremise.hasMacOS27` instead of reporting a red.
- **A turn with no tool call cannot be interrupted** (Engine/) — the drain points are the tool-result tail
  and the MTP loop; a tool-bearing turn provably breaks in-run (probe 21). The injection seam landed
  upstream at pin `991266ad3` (`observe(to:using:)` + `GenerationTransformer`), so what is left is
  owning what upstream's `ChatSession` loop owns. Owner call.
- **Rewind is landed; the reserve is a guessed constant** (Engine/) — 1024 rows measured on one checkpoint,
  not tuned to model or memory pressure, so an edit further back than the reserve still pays its full prefix.
  `SessionRewindOnDivergenceTests`(7) + probe 27 hold the wiring and the number.
- **Video publishing is per-checkpoint** (Multimodal/) — one processor reads `input.videos`, the other does
  not, so it is never inferred from architecture; a turn that received frames but never answered is not
  counted, and relaxing that is untested (`VideoDeliveryLedger`).
- **Screen capture cannot start a stream headlessly** (Multimodal/) — authorized, display attached, still
  "cannot start stream", while the camera on the same box delivers: an SCStream-in-no-GUI-session limit,
  not TCC. `screenStatus` is `ready` only after a delivered frame.
- **`tools[]` enforcement has gaps** — scope and open halves: `Sources/ocoreai/UI/AGENTS.md`; the
  `required`-strength bound sits in `Handlers/AGENTS.md` § Endpoint Promises.
- **Two owner questions have data now and no answer** — refresh-vs-refuse when instructions change, and
  cross-conversation prefix sharing. `ReuseRefusalLedger` publishes both; the ledger is opportunity, not a
  capability claim.

- **A turn's tool surface costs 19 points; one knob is gated, the surface is not.** 10-27(21) built the
  instrument (`OCOREAI_EVAL_TOOLS=all` + the `# surface` line); 10-27(22) ran k=3 per arm on
  `gemma-4-e2b-it-4bit`, temp 0, one serve per run: 6 tools / **4,510 B** ⇒ **24/21/23** (mean 22.67),
  all 40 / **25,092 B** ⇒ **16/15/15** (mean 15.33) — **−18.8 pp, McNemar exact p < 0.0001** (25 tasks win on
  the small surface, 3 on the large). Read it as *what a turn is handed*, not "fewer tools everywhere":
  `exec-sum-column` 0/3 → 2/3 and `exec-report-two-numbers` 2/3 → 3/3 improved on the full surface while every
  edit/fix face collapsed (`fix-syntax-error`, `fix-typo-variable`, `read-and-report`,
  `fix-boundary-comparison` 3/3 → 0/3). Noise floor from the same runs lives in `scripts/eval/README.md`
  (±6 tasks single-run; ≥9 unpaired, 6 clean flips paired). Reproduce:
  `OCOREAI_EVAL_REPEAT_ROOT=/tmp/board6 OCOREAI_EVAL_REPEATS=3 bash scripts/eval/repeat.sh`, again with
  `OCOREAI_EVAL_TOOLS=all` into a second root, then `python3 scripts/eval/_repeat_stats.py --a /tmp/board6
  --b /tmp/board40`. The open half is a product decision, not a measurement: the wire is caller-scoped
  (`Tools/ToolRegistry.swift:135`: no `tools[]` declared ⇒ no tools) while the app's own loop hands the whole
  registry over every turn (`UI/ViewModels/ChatViewModel.swift:1098`) — 40 declarations, 25,092 B, to a 4-bit
  checkpoint. Every comparator refuses that shape: codex declares 13 specs and defers the tail behind
  `tool_search` (`codex-rs/core/src/tools/handlers/tool_search_spec.rs:19`), hermes-agent runs 38 modules
  behind a reserved three-name bridge (`tools/tool_search_catalog.py:15-21`), pi loads deferred matches into
  the conversation's `modelTools` (`packages/durable/src/tool-search/tool-search.ts:1-13`). Settled by a
  per-turn shortlist (whose score, which shortlist, who pays for a wrong pick) plus the composer half — what
  the GUI may offer once `/v1/models` says `template_ignores`. The one knob already gated is the pattern to
  extend: `reasoning_effort` renders the checkpoint's own template with a sentinel at load, records
  `honored`/`template_ignores`/`not_observed` (`ReasoningEffortLedger`), publishes it on `/v1/models`, and
  refuses a demanded word 400 naming the knob, the evidence and both exits — codex's
  `unsupported_code_mode_warning` shape (`core/src/session/code_mode_warning.rs:6-24`), with fail-open pinned
  too (unmeasured is never refused). On this host `gemma-4-e2b-it-4bit` renders identically with and without
  the kwarg, so the word was dropped before generation while the caller got 200
  (`ReasoningEffortHonestyTests`(9) + probe 38, both tiers red-sampled); probe 12 §6 is *not* an open
  instance — it was fixed earlier and its README now requires keys 3/3 with the tools still declared.

- **Four of 41 probes answer without weights; no checkpoint tier has a CI seat.** The scripted lane holds
  three — 37 (wire contract), 38 §1 (a refusal), 39 §1/§1b (the skill executed marker by marker) — one
  step each in `Build & Test (macos-26)`, first runner pass green 10-29 (4 / 3 / 7 s; each step's tier
  counts are printed as annotations, because a runner holds no weights and 38 §2 / 39 §2 / 40 §2 took
  their skip branch). Open: 36 probes' claims are about the engine (prefix reuse, sampling delivery, KV
  residency) and move cheap only when one turns out to be a frame claim. Owner call: which tier the
  scripted lane may run in, and whether a nightly takes the checkpoint tiers (`package.yml`, added 10-29,
  is this repo's first non-push seat).

- **The chain ceiling, now that the drop speaks** (Skills/, docs/). `make docs-check` prints
  `budgets … deepest-chain=N/CAP`, and B2 both prices each root→guide chain against the host's 32,768 and
  re-derives the `ocoreai` row of `docs/agent/comparator-repos.md` from the tree: that header is the one
  home of a chain figure, so a stale number goes red there instead of drifting (it drifted twice on 10-28,
  and this file used to restate it). The deepest chain is root + `Engine/AGENTS.md`, and the headroom that
  field reports is what stands between a new root rule and never being injected at all; four comparator
  trees already read rulesets their own loader cut. The next rule written into
  `Sources/ocoreai/Engine/AGENTS.md` truncates its own tail unless something else leaves; settled by a trim,
  not a raise, with § *Known defect* (a macOS 27 face no host here can execute) and the lane map (it
  duplicates § *Architecture*'s route to the wire) as the candidates. The silence under the ceiling closed
  10-28: one resolver (`WorkspaceContext.swift:204` `assemble`) measures each doc's fate and both consumers
  read it — the injected text now carries `Workspace instruction budget N bytes: truncated <path> from A to B
  bytes` / `dropped <path> (A bytes)` (`noticeLine`, `:272`), and `/v1/capabilities` publishes
  `instructionBudget` beside `tokenizerBackend`, labelled `<root>/…` because that endpoint is public. The
  borrow is not invented: deepseek-harness states the drop inside the injected text and pins the wording as a
  fixture
  <!-- anchor:deepseek-harness snapshots/session/agent-instructions-budget/snapshot.yml:2 scenario: agent-instructions-budget -->
  ("Workspace instruction budget 700 bytes: truncated … from 1900 to 292 bytes"). Gates: `WorkspaceContextTests`(15)
  — exact bytes, both states, no notice when nothing was cut, no absolute path on the row — and probe 03,
  which boots a server against a workspace it seeds to overflow the cap; both were red-sampled by reporting
  the dropped doc as `whole`. What stays open is not a disclosure question: (a) whether injection should be
  **gated by capacity** (the curve below, one checkpoint wide) — owner call; (b) the disclosure's own
  **behaviour verdict**, since telling a 2B model its instructions were cut may itself cost points and the
  board has not priced that arm; (c) no UI surface reports it yet.
- **The corpus's cost is injection, and the curve is one checkpoint wide.** Four arms, 39 tasks,
  `gemma-4-e2b-it-4bit`, k=3 (10-27(25)): doc absent **25.00**, the same 2,442 B present but *not* injected
  **24.00** (p = 0.51), 2,442 B injected **19.00** (p = 0.0003), root 21.5 KB injected **16.33** (p = 0.12
  against the distillate) — presence is free, injection is what is paid for, and volume beyond that is not
  resolvable at this n. Unanswered, in spending order: does capacity buy context tolerance (needs a
  default-model knob — `EngineConfig.defaultModelId` is hard-defaulted, no `OCOREAI_*` override), and does a
  short per-turn corpus beat a long one on the faces that collapsed? Owner call either way — gate injection
  by capacity, or move the doc behind the base prompt (`MessageBuilder`).

- **The gate layer is frozen; the tag is not.** Measured before cutting: 329 of 1415 commits went to
  docs/CI/gates against `git tag` = empty (the counts and the deleted family: CHANGELOG
  `gate-deletion-10-28`), and `AGENTS.md` § Working here carries the stop rule — a new check names the red it
  was sampled against and the reader whose action it changes, or it does not get written. What remains open
  is not a measurement and not an audit — it is the owner pushing a tag, the only act here that makes a
  surviving gate someone else's problem to run.

- **A stale release row that says we ship** (docs/, adoption/) — `api.github.com` `/releases/latest` still
  serves `v0.1.13` (published 10-11, asset `ocoreai-0.1.13.dmg` 25 472 769 B) while `git tag -l`, `/tags`,
  `/releases` and the Releases page report none and that asset URL answers **404**. The endpoint a bot asks
  first says we ship; the page a human asks says we never have. Owner call: delete the orphan object, or
  land `v0.1.14` so the page lists a newest within days. Measured 10-28, and why § Adoption of `AGENTS.md`
  now reads "0 *listed* releases".

- **The delivery shape's CI verdict has never run on a runner** (CI/, Engine/) —
  `LoadedModel.isCoreAIAsset` was declared inside `#if canImport(CoreAI)` and used ungated at
  `EnginePool.swift:1468`, so an SDK that carries the framework compiled it green while the
  CoreAI-free delivery build died. The declaration moved outside the gate (the CoreAI body stays
  gated; `false` is the measured answer where the framework is absent) and the route now has one home:
  `scripts/toolchain-contract.sh print-delivery-env`, consumed by `make release` and by
  `scripts/build-app.sh` — through it by `build-dmg.sh`, which had been unbuildable on any host whose
  newest SDK carries CoreAI. `build-appstore` pins that route and judges the binary with
  `release-artifact-check.sh delivery`. Instrument: the next push's *App Store trait compile* leg; if
  the runner has no CoreAI-free SDK it fails with the resolver's remedy and the verdict moves to the
  leg that does. Same sweep found a second drift: probe 37 §8 extracted the tool count from
  `AGENTS.md` with a phrase-locked regex that matched nothing once the sentence was rewritten — it now
  matches the shape, and the live server confirms 40. Two holes stay open beside this one:
  *clean machine → first completion* is unmeasured with the download included (the 22.1 s figure had
  cached weights), and nothing is notarised, so the cask rung cannot be floored yet.

- **The release job holds the publish credential while it runs repository code** (CI/) —
  `.github/workflows/ci.yml:437` builds the app (xcodebuild, repository code) inside the job that carries
  `contents: write` (`:443`), so a compromised dependency in the build has the artefact-upload right in the
  same step. The pattern to copy is opencode's split
  (`../references/opencode/.github/workflows/release-dry-run.yml:4-9`): build jobs run repo code with no
  secrets and no `id-token`; sign/publish run in a `release` environment, check out only the release
  directory, and treat artefacts as data. Owner call, because it changes who/what may publish, and it wants
  a dry-run route so the release path is exercised on a PR. Instrument owed: a red when a job that uploads
  also executes repository code.
- **A measured gallery is the one adoption surface we can win outright** (README/, Handlers/) — the leaders
  advertise model support as adjectives while `/v1/models` already publishes per-checkpoint measured verdicts
  (`vlm`, `contextLength`, `toolCallDelivery`, `reasoningEffort`, `videoInput`) and `scripts/eval/` scores 39
  tasks; owed is the artefact — a generated README table plus `models.json` (absent), refreshed by a probe with its
  command beside it (precedent: pi publishes its catalog from CI behind a compatibility gate,
  `../references/pi/.github/workflows/publish-model-catalog.yml:1-14`). Owner call: publishing a catalog is
  promising it stays true, and the refresh probe going red on a stale row is the instrument.

- **`OCOREAI_AGENTS_MAX_AREA` and P18 were both priced against the wrong enemy** (docs/) — P18 keeps docs
  English by default with exactly one Chinese file (the owner's rule, and why this tree has no translation
  drift), but opencode ships 22 README locales (`../references/opencode/README.md:17-32`) and hermes-agent 3
  badge-linked, so the rule is a priced cap on a distribution channel, not a neutrality: deepseek-harness
  pairs each heading's en/zh block by hash in `README.i18n.yaml` so drift is machine-visible. Recorded so the
  owner prices it deliberately; nothing here changes the rule.

- **Upstream already ships a scripted engine; ours has to be re-judged when the planned half lands**
  (Engine/) — `MLXScriptedLM` is a published product at the pin, and its scripted tokenizer implements
  upstream's own `Tokenizer` protocol
  <!-- anchor:mlx-swift-lm Libraries/MLXScriptedLM/Tokenizer/ScriptedTokenizer.swift:11 public struct ScriptedTokenizer -->
  while its library README still lists tool calls and reasoning in transcripts as *Planned*
  <!-- anchor:mlx-swift-lm Libraries/MLXScriptedLM/README.md:20 Planned -->
  — which is exactly the half `Engine/ScriptedInference.swift` exists to decide at k=1. So today's local
  lane is not a duplicate of delivered upstream capability, but the footprint ladder's first rung says
  consume before author: the trigger to re-open this is upstream delivering transcript tool calls, and the
  check is the pin diff on that library at the next bump.
