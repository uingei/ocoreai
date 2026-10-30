# Open — measured, unresolved

The long form of § Open in `AGENTS.md`, which owes only the address. Nothing here is a capability claim:
where a number is unmeasured it says so, and where a fix is blocked by the host or by upstream it names
which. A resolution goes to `docs/agent/closed-items-log.md`; a decision becomes a rule in `AGENTS.md` or
the area guide, with its gate. Per-item evidence is in `CHANGELOG.md` (grep the symbol).

- **`/v1/models/:model/…` needs `%2F`** (Handlers/) — accepting a slash costs a second routing truth, so the
  wire shape stays pinned in `Handlers/AGENTS.md`; the owner call is open here.
- **A stall stops MTP hard, the std lane only by consent** (Tools/, Engine/) — the ladder and
  `LoopStallTerminationTests`(6) landed; upstream `mlx-swift-lm`'s `restart:` loop (ChatSession.swift:1164) still has no
  cap, and a std-lane hard stop throws out of `toolDispatch` (:1632) reaching the wire as an error, not a
  finished turn — the terminal word for four faces is the owner call.
- **CoreAI / macOS 27 items unverifiable on this host** (Engine/) — three `@available(macOS 27.0, *)` or
  SDK-gated sites (detail: `docs/agent/build-gate-reality.md`) ⇒ no blind fix and no claim of one; their
  suites now skip on this OS through `PlatformPremise.hasMacOS27` instead of reporting a red.
- **The coreai fork's debt is 8 named verdicts, not a drift window** (Engine/) — 77a122f read all 36 commits
  behind the four engine windows: 7 absorbed, 21 n/a, **8 open**, one row each with its action in
  `docs/agent/coreai-fork-adjudication.md` (#368 measured 10-30 by probe 12 §5b: the shipping lane damps whitespace via
  upstream `WhitespaceTokenBias`, so its exposure is CoreAI-only, unverifiable here). `make drift` reads 0 un-adjudicated per file today; the axis moved once since,
  `db7823e` (#389), 2 Python files and 0 Swift — export-side, the axis § Upstream 2 has no surface for.
  <!-- claim:fork_verdicts_open=8 :: grep -c '^| .*open\*\*' docs/agent/coreai-fork-adjudication.md -->
- **A turn with no tool call cannot be interrupted** (Engine/) — the drain points are the tool-result tail
  and the MTP loop; a tool-bearing turn provably breaks in-run (probe 21). The seam landed upstream at
  `991266ad3` (`observe(to:using:)` + `GenerationTransformer`);
  what is left is owning what upstream's `ChatSession` loop owns. Owner call.
- **Thinking reaches the wire uncounted on the ChatSession lane** (Engine/) — probe 44 §2 delivered 550
  chars of `reasoning_content`, no `reasoning_tokens`; upstream counts it through
  `ThinkingBudgetProcessor`, which also *bounds* thinking. Owner call.
- **Rewind is landed; the reserve is a guessed constant** (Engine/) — 1024 rows measured on one checkpoint,
  not tuned to model or memory pressure, so an edit further back than the reserve still pays its full prefix.
  `SessionRewindOnDivergenceTests`(7) + probe 27 hold the wiring and the number.
- **Video publishing is per-checkpoint** (Multimodal/) — one processor reads `input.videos`, the other does
  not, so it is never inferred from architecture; a turn that got frames but never answered is not
  counted; relaxing that is untested (`VideoDeliveryLedger`).
- **Screen capture cannot start a stream headlessly** (Multimodal/) — authorized, display attached, still
  "cannot start stream", while the camera on the same box delivers: an SCStream-in-no-GUI-session limit,
  not TCC. `screenStatus` is `ready` only after a delivered frame.
- **`tools[]` enforcement has gaps** — scope and open halves: `Sources/ocoreai/UI/AGENTS.md`; the
  `required`-strength bound sits in `Handlers/AGENTS.md`.
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
  (±6 tasks single-run; ≥9 unpaired, 6 clean flips paired). Reproduce: `scripts/eval/README.md` § the
  repeat recipe, both arms into separate roots. The open half is a product decision, not a measurement: the wire is caller-scoped
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

- **Weight-free probes exist; only three hold a CI seat, and no checkpoint tier does.** The scripted lane holds
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
  read it — the injected text carries the truncation/drop notice (`noticeLine`) and `/v1/capabilities`
  publishes `instructionBudget` beside `tokenizerBackend`, labelled `<root>/…` because it is public. The
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
  `gate-deletion-10-28`), and `AGENTS.md` § Working here carries the stop rule. What remains open is the
  owner pushing a tag — the only act that makes a surviving gate someone else's problem to run.

- **The release job holds the publish credential while it runs repository code** (CI/) —
  `.github/workflows/ci.yml:403` carries `contents: write` (`:410`) and builds inside that job (`:414`
  metallib, `:424` `build-dmg.sh`, and the GUI proof under them), so a compromised dependency in the build holds the
  artefact-upload right in the same step. The dry-run half of the ask is paid: `.github/workflows/package.yml`
  builds and judges the same DMG under `permissions: contents: read` (metallib 777 s, DMG 1187 s on a clean
  runner, 10-29), so the credential no longer has to *prove* the build — it still runs it. The rest is the
  split itself: opencode's shape (`../references/opencode/.github/workflows/release-dry-run.yml:4-9`) runs
  build jobs with no secrets and no `id-token` and publishes from a `release` environment over artefacts.
  Deliberately untouched before a first release lands: it is the one path a rehearsal cannot run.
  Owner call (who/what may publish).
- **The one latency figure we quote is not the metric we want** (packaging/) — *clean machine → first
  completion* is unmeasured with the model download included: the 22.1 s figure ran with weights already on
  disk, and nothing is notarised, so neither the metric nor the cask rung can be floored yet
  (rung 2, `docs/agent/long-horizon-goal.md`).

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
  lane is not a duplicate of delivered upstream capability. Re-open trigger: upstream delivering transcript
  tool calls; check: the pin diff on that library at the next bump.

- **No weight-free witness for MTP drafter mixing** (Engine/) — the drafter belongs to one model now
  (`Engine/LoadedModel.swift:112`, read at `Engine/EngineInference.swift:3452`); until 10-29(55) it sat
  unkeyed in the pool, so a refused family could route on another family's drafter. Keying is
  compile-enforced; the wire proof wants two checkpoints live — owner call.

- **`durationMs` charges the human's approval to the tool** (Engine/, UI/) — the clock starts at
  `Engine/EngineInference.swift:2955` and `Tools/ToolRegistry.swift:604` awaits the approval inside that
  window, so a slow answer renders as a slow tool in the transcript
  (`UI/Views/ChatView.swift:1473`). Codex #57207 attributes approval waits apart; paying it needs the wait
  measured where it is awaited. Owner call: which number the chip owes.

- **`memory_events` outlived its API** (SQLite/) — 10-29(53) deleted the last of it, leaving a table,
  FTS index and 3 triggers (`SQLite/SQLiteStore.swift:670`) nothing writes. Old databases keep the rows
  a migration call: drop at the next schema bump, or name the consumer.
