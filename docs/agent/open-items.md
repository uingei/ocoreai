# Open — measured, unresolved

The long form of § Open in `AGENTS.md`, which owes only the address. Nothing here is a capability claim:
where a number is unmeasured it says so, and where a fix is blocked by the host or by upstream it names
which. A resolution goes to `docs/agent/closed-items-log.md`; a decision becomes a rule in `AGENTS.md` or
the area guide, with its gate. Per-item evidence is in `CHANGELOG.md` (grep the symbol).

- **`/v1/models/:model/…` needs `%2F`** (Handlers/) — accepting a slash costs a second routing truth, so the
  wire shape stays pinned in `Handlers/AGENTS.md`; owner call open.
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
  upstream `WhitespaceTokenBias`, so its exposure is CoreAI-only, unverifiable here). `make drift` reads 0
  un-adjudicated per file today, and the axis since then has moved export-side only — the surface
  § Upstream 2 has none for.
  <!-- claim:fork_verdicts_open=8 :: grep -c '^| .*open\*\*' docs/agent/coreai-fork-adjudication.md -->
- **A turn with no tool call cannot be interrupted** (Engine/) — the drain points are the tool-result tail
  and the MTP loop; a tool-bearing turn provably breaks in-run (probe 21). The seam landed upstream at
  `991266ad3` (`observe(to:using:)` + `GenerationTransformer`);
  what is left is owning what upstream's `ChatSession` loop owns. Owner call.
- **Thinking is uncounted on the tools lane** (Engine/) — probe 44 §2: 550 chars, no
  `reasoning_tokens`. Upstream counts only via the processor that also bounds the thought, and a
  bound there starves the tool call (§2b: 200→500 at 64 tokens). A count-only processor waits
  upstream. Owner call.
- **Rewind is landed; the reserve is a guessed constant** (Engine/) — 1024 rows measured on one checkpoint,
  not tuned to model or memory pressure, so an edit further back than the reserve still pays its full prefix.
  `SessionRewindOnDivergenceTests`(8) + probe 27 hold the wiring and the number.
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

- **A turn's tool surface costs 19 points; one knob is gated, the surface is not.** Measured on
  `gemma-4-e2b-it-4bit`: 6 tools against all 40 ⇒ **−18.8 pp, McNemar exact p < 0.0001** — read it as *what a
  turn is handed*, not "fewer tools everywhere" (two exec faces improved full-surface, every edit/fix face
  collapsed); per-arm rows, the noise floor and the recipe: `scripts/eval/README.md` § the repeat recipe. The
  open half is a product call: the wire is caller-scoped (`Tools/ToolRegistry.swift:135` — no `tools[]`
  declared ⇒ no tools), while the app hands the whole registry over every turn
  (`UI/ViewModels/ChatViewModel.swift:1098`: 40 declarations, 25,092 B, to a 4-bit checkpoint); no comparator
  does that (cites: `comparator-repos.md`). Wants a per-turn shortlist (whose score, who pays a wrong pick)
  plus the composer half. The pattern to extend is the knob already gated: render the checkpoint's template
  with a sentinel at load, record it (`ReasoningEffortLedger`), publish on `/v1/models`, refuse a demanded
  word 400 naming the knob and both exits — codex's `code_mode_warning.rs:6-24` shape, fail-open pinned.
  `ReasoningEffortHonestyTests`(9) + probe 38.
- **Weight-free probes exist; only three hold a CI seat, and no checkpoint tier does.** The scripted lane
  holds 37 (wire contract), 38 §1 (a refusal) and 39 §1/§1b (the skill's markers); §2 of 38/39/40 needs
  weights, so on a runner it takes its skip branch.
  Owner call: which tier the scripted lane may run in, and whether a nightly takes the checkpoint tiers.

- **The chain ceiling, now that the drop speaks** (Skills/, docs/). The disclosure half closed
  10-28 (`closed-items-log.md`): `make docs-check` prints `deepest-chain=N/CAP` and re-derives the
  `comparator-repos.md` row from the tree. Open: (a) whether injection should be **gated by
  capacity** — owner call; (b) the disclosure's own **behaviour verdict** (telling a 2B model its
  instructions were cut may itself cost points; the board has not priced that arm); (c) no UI surface
  reports it yet. The next rule written into `Sources/ocoreai/Engine/AGENTS.md` truncates its own tail
  unless something else leaves: settled by a trim, not a raise, with § *Known defect* and the lane map
  as the candidates.
- **The corpus's cost is injection, and the curve is one checkpoint wide.** Four arms, 39 tasks,
  `gemma-4-e2b-it-4bit`, k=3 (all four rows: 10-27(25)): presence is free (absent vs present-but-uninjected,
  p = 0.51), injection is what is paid for (2,442 B: 24.00 → **19.00**, p = 0.0003), and volume beyond that
  is not resolvable at this n. Unanswered, in spending order: does capacity buy context tolerance (needs a
  default-model knob — `EngineConfig.defaultModelId` is hard-defaulted, no `OCOREAI_*` override), and does a
  short per-turn corpus beat a long one on the faces that collapsed? Owner call either way — gate injection
  by capacity, or move the doc behind the base prompt (`MessageBuilder`).

- **The gate layer is frozen; the tag is not.** Measured before cutting: 329 of 1415 commits went to
  docs/CI/gates against `git tag` = empty (the counts and the deleted family: CHANGELOG
  `gate-deletion-10-28`), and `AGENTS.md` § Working here carries the stop rule. What remains open is the
  owner pushing a tag — the only act that makes a surviving gate someone else's problem to run.

- **The release job holds the publish credential while it runs repository code** (CI/) —
  `.github/workflows/ci.yml:402` carries `contents: write` and builds inside that job (`:412` the
  MetalToolchain step, `:426` `build-dmg.sh`), so a compromised dependency in the build holds the
  artefact-upload right in the same step. The dry-run half is paid (`package.yml` builds the same DMG under
  `contents: read`); the rest is the split itself: opencode's shape (`../references/opencode/.github/workflows/release-dry-run.yml:4-9`) runs
  build jobs with no secrets and no `id-token` and publishes from a `release` environment over artefacts.
  Deliberately untouched before a first release lands: it is the one path a rehearsal cannot run.
  Owner call (who/what may publish).
- **One CI leg red since `d664f7b`, and it is now made to name itself** (CI/) — xcode-27 went green on 11-02
  once the grammar suite asserted what was measured (11-02(104)); both stop-token suites ran there for the
  first time. The *Build the DMG* leg's public annotation says only exit-1 with both artefacts missing, and
  its log needs a token this host has not, while `build-dmg.sh` yields a 27 932 392-byte DMG here (11-02) — a
  clean-runner premise, candidates inferred: the metal route, the SPM cache, the headless GUI. The step now
  tees its log and republishes the tail as annotations (`ci-step.sh:84`'s shape), and touching package.yml
  re-triggers that lane.
- **A caller's one-token `stop` can starve a constrained turn** (Engine/, Handlers/) — naming a stop id
  takes it out of xgrammar's alphabet (`TokenizerInfo.swift`, at the create call), so a `stop` the schema
  needs empties the mask where it was needed and `nextTokenBitmask()` reads empty as finished: truncated
  JSON, no error, CoreAI lane only. Measured at the C layer (11-02(104)), Swift face read not run.
  Owner call: refuse such a `stop` at `ConstrainedDecodingStrategy.createSession`, or say so on the wire.

- **A cold first run is 794 s of download, at hub speed** (packaging/, Config/) — bytes, rate, the paired
  `curl` and the cache-path correction have one home: diary 11-01(97), re-measured by 11-01(101). The
  surviving verdict: the hub path is the limit, so no harness change reaches the 5-min budget with a
  3.58 GB default, and nothing is notarised, so Gatekeeper and the cask stay outside every figure.
  Owner: notarisation + the first-run checkpoint.
- **The request that triggers a load waits out the whole load** (Engine/, Config/) — the fetch is honest
  hub-limited and nothing about it reaches the client: a waiter gets
  `AppError.modelLoading` at
  120 s while the *owning* request waits ~13 min, and no byte count or percent travels on the wire although
  `OcoreaiDownloadProgress` holds it. Wanted: a pool-owned load task, so every caller gets the same bounded
  pollable answer, with progress in the body. Gate: none yet (diary 11-01(99), re-measured by (101)).
- **The audit infers a write, it never reads the workspace** (Models/, Tools/) — a shell success is
  `.unobserved`; an unknown MCP tool still counts as a writer; the key is process-wide. Wanted:
  turn-scoped effect off the filesystem (codex, per turn:
  `../references/codex/codex-rs/core/src/turn_diff_tracker.rs:46`).
- **A demanded tool call is reported, not forced** (Engine/, Handlers/) — the unmet demand now rides in
  the result at all four sites; the engine still answers `required` with zero tokens, where sglang
  constrains it to a call
  (`../references/sglang/python/sglang/srt/entrypoints/openai/serving_chat.py:1937-1945`).
- **A measured gallery is the one adoption surface we can win outright** (README/, Handlers/) — the leaders
  advertise model support as adjectives while `/v1/models` already publishes per-checkpoint measured verdicts
  (`vlm`, `contextLength`, `toolCallDelivery`, `reasoningEffort`, `videoInput`) and `scripts/eval/` scores a
  task board (count: `_eval.py count`, never re-typed here); owed is the artefact — a generated README table
  plus `models.json` (absent), refreshed by a probe with its
  command beside it (precedent: pi publishes its catalog from CI behind a compatibility gate,
  `../references/pi/.github/workflows/publish-model-catalog.yml:1-14`). Owner call: publishing a catalog is
  promising it stays true, and the refresh probe going red on a stale row is the instrument.

- **`OCOREAI_AGENTS_MAX_AREA` and P18 were both priced against the wrong enemy** (docs/) — P18 keeps docs
  English by default with exactly one Chinese file (the owner's rule, and why this tree has no translation
  drift), but opencode ships 22 README locales (`../references/opencode/README.md:17-32`) and hermes-agent 3
  badge-linked, so the rule is a priced cap on a distribution channel, not a neutrality: deepseek-harness
  pairs each heading's en/zh block by hash in `README.i18n.yaml` so drift is machine-visible. Recorded so the
  owner prices it deliberately.

- **Upstream already ships a scripted engine; ours has to be re-judged when the planned half lands**
  (Engine/) — `MLXScriptedLM` is a published product at the pin, and its scripted tokenizer implements
  upstream's own `Tokenizer` protocol
  <!-- anchor:mlx-swift-lm Libraries/MLXScriptedLM/Tokenizer/ScriptedTokenizer.swift:11 public struct ScriptedTokenizer -->
  while its library README still lists tool calls and reasoning in transcripts as *Planned*
  <!-- anchor:mlx-swift-lm Libraries/MLXScriptedLM/README.md:20 Planned -->
  — exactly the half `Engine/ScriptedInference.swift` exists to decide at k=1, so today's lane is no
  duplicate of delivered upstream capability. Re-open: upstream shipping transcript tool calls; check the
  pin diff on that library at the next bump.

- **No weight-free witness for MTP drafter mixing** (Engine/) — the drafter belongs to one model now
  (`Engine/LoadedModel.swift:112`, read at `Engine/EngineInference.swift:3452`); until 10-29(55) it sat
  unkeyed in the pool, so a refused family could route on another family's drafter. Keying is
  compile-enforced; the wire proof wants two checkpoints live — owner call.

- **`durationMs` charges the human's approval to the tool** (Engine/, UI/) — the clock starts at
  `Engine/EngineInference.swift:2955` and `Tools/ToolRegistry.swift:604` awaits the approval inside that
  window, so a slow answer renders as a slow tool in the transcript
  (`UI/Views/ChatView.swift:1473`). Codex #57207 attributes approval waits apart; paying it needs the wait
  measured where it is awaited. Owner call: which number the chip owes.

- **Memory is read by every request, written only behind `self_correction`** (SQLite/) — `ChatHandler.swift:944` reads, `addMemory` writes. Owner call: publish the flag, or gate the recall.

- **The loaded-host reds rotate cast; the pool tail beats every control term** (Tests/) — casts: 5 issues on 11-01(100),
  5 and 10 on 11-02, names rotate; mechanism: 11-02(106). One class: wall-clock
  bounds bet on the single cooperative pool 615 suites share, and the instant+control pattern does not fence
  it (a wake 6 382 ms late against a 301 ms control — magnitudes: 11-02(106)) — production behaviour,
  not a test premise. The median is measurable, the tail is not. Closed: the ledger's cross-suite
  half (11-02(105)). Wanted: a clock the tests control (`ClockToolsTests`) or an uncontended lane
  (`make test-clt`'s split); whose call: the owner.
- **The 11-02 compat sweep left two owner calls and one dated debt** (Middleware/, Wire/, Router/) —
  the swept axes landed (spec-name `error.type`; ceiling as `max_model_len`, old key aliased one
  release, 11-02(110)). ① Three sites build literal error bodies
  (`RateLimitMiddleware`, `NotFoundEnvelopeMiddleware`, `ContentGuard` — lines in 11-02(109)), so a
  middleware refusal on `/v1/messages` still answers the OpenAI envelope; porting them onto
  `AppError.response` must carry `Retry-After`, `route_not_found` + the endpoint index and
  `content_policy_violation`. ② Jev's answer half is read from both stacks and unwritten until the
  answer position can be scored (probe 49); the seam and its lane are the call. ③ drop the
  `contextLength` alias (and probe 03's clash check with it) the release after it landed.