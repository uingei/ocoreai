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
  finished turn — the terminal word for four faces is the owner call; field constraints mined
  11-03: `CHANGELOG` 11-03(1).
- **CoreAI / macOS 27 items unverifiable on this host** (Engine/) — three `@available(macOS 27.0, *)` or
  SDK-gated sites (detail: `docs/agent/build-gate-reality.md`) ⇒ no blind fix and no claim of one; their
  suites now skip on this OS through `PlatformPremise.hasMacOS27` instead of reporting a red.
- **The coreai fork's debt is 14 named open verdicts, not a drift window** (Engine/) — 8 of them from
  77a122f reading all 36 commits behind the four engine windows (7 absorbed, 21 n/a), 3 from the #388/#374
  read, 3 added by the 11-05 window read; one row each with its action in
  `docs/agent/coreai-fork-window-log.md` (#368 measured 10-30 by probe 12 §5b: the shipping lane damps whitespace via
  upstream `WhitespaceTokenBias`, so its exposure is CoreAI-only, unverifiable here). `make drift` reads 0
  un-adjudicated per file today. The axis since has moved export-side **and** through two Swift commits in
  `CoreAILanguageModels/SpeculativeDecoding/` — a target this tree mirrors nothing of (rows: that log's
  § Window read 11-05), so § Upstream 2 still has no surface for it. The ledger's other face is the bigger
  half: of 56 candidates it calls **36** mirrors unread — **25** carry no sha at all, **11** carry one in
  prose the reader will not guess at (two of those would be read *wrong*), so their window is not empty, it
  is unmeasurable until someone writes the canonical read-point; `make drift` prints both counts every
  round, and the eleven are listed with their sentences in that log's § Window read 11-05 (b).
  <!-- claim:fork_verdicts_open=14 :: grep -c '^|.*\*\*open' docs/agent/coreai-fork-window-log.md -->
- **The `+6` mlx-swift-lm window hands us a truth we cannot read until the bump** (Engine/) — read 11-05 in
  a local clone at `c8dabc6`: `GenerateCompletionInfo` gains `speculativeDecodingFallbackReason`
  (`Evaluate.swift:3083`) naming the five reasons a session with speculation configured ran plain
  generation. We already consume that struct's siblings (`passthroughReason`,
  `speculativeDecodingTelemetry` → `EngineEvents.swift:88`), so the traditional-SDC lane's silent fallback
  is the one face still unnamed. Same window: #747's `RotatingKVCache` mask fix is **inert here** while
  `keep == 0`, which is every path we reach — `makeKVCacheConfiguration` (`MLXBridge.swift:896`) passes
  `strategy` + `rewind` only, and `Capacity.init` is the sole route to `keep > 0`, defaulting to 4, so
  setting a capacity silently pins 4 tokens. Upstream's `restart:` tool loop is still uncapped
  (`ChatSession.swift:1226`), so the stall item above keeps its premise. Instrument: `make drift` prints
  the axis; `make anchor-check` re-points the markers into the files #581 touched — 13 of them per
  `api.github.com` pulls/581, of which our cites reach two: 27 markers into `ChatSession.swift`, 9 into
  `Evaluate.swift` (re-grepped 11-06; anchor-check prints the set).
  Blocked: the bump owes `make test-ci`, whose Metal Toolchain component this host reports `uninstalled`,
  and git-over-https to github fails here (curl 28) while `api.github.com` answers — so an SPM re-resolve
  is not safe to attempt blind. Owner call: the bump is a hand, not a gate.
- **A turn with no tool call cannot be interrupted** (Engine/) — the drain points are the tool-result tail
  and the MTP loop; a tool-bearing turn provably breaks in-run (probe 21). The seam landed upstream at
  `991266ad3` (`observe(to:using:)` + `GenerationTransformer`);
  what is left is owning what upstream's `ChatSession` loop owns. Owner call.
- **Thinking is uncounted on the tools lane** (Engine/) — probe 44 §2: 550 chars, no
  `reasoning_tokens`. Upstream counts only via the processor that also bounds the thought, and a
  bound there starves the tool call (§2b: 200→500 at 64 tokens). A count-only processor waits
  upstream. Owner call. Datum 11-04: the model family ships a wire word for this cost —
  `preserve_thinking` retains "reasoning context from historical messages"
  (`../references/Qwen3.8/README.md:25`) — so a caller that retains thinking pays tokens we cannot price
  for it (inference from a README, not a measured interaction).
- **Pin 1's pending window carries two commits on axes this repo has open** (Engine/) — `make drift` 11-04:
  `mlx-swift-lm HEAD=ffe7647b0, +3 vs base=b8d4935ab`, and two of the three are ours-shaped: *"Add resumable
  Qwen MTP speculative decoding to ChatSession (#581)"* (the MTP lane *and* the interrupt/stall rows, which both
  wait on what upstream's `ChatSession` loop owns) and *"RotatingKVCache: keep the pinned prefix visible in
  multi-token masks (#747)"* (KV/prefix accounting); the third (`#692`, EmbeddingGemma 2 image orientation) reads
  n/a. The third pin axis is clean: `mlx-swift tag=0.33.0 pin=0.33.0`, 0 new. `coreai-models` is +1
  (`#404`, CI-only per its subject). Owner call is § Upstream 1's bump protocol, not an audit finding — but the
  MTP half deserves the same read as the acceptance row below, because a *resumable* drafter changes what that
  gate would even measure. (The instrument note this row carried — one verdict, exit **10** then **2** — is
  closed: `closed-items-log.md`.)
- **MTP acceptance is threaded, unused as a signal, and its named suite gates nothing** (Engine/, Tests/) —
  found by reading, not by a scan. ① The counters are real: `proposedDraftTokens`/`acceptedDraftTokens`
  (`EngineEvents.swift:105`) are threaded at `EngineInference.swift:3432`, `:4229` and read by
  `ChatViewModel.swift:1189`. ② The suite that *sounds* like the gate is not one: `MTPAcceptanceRateTests.swift`
  (14 tests in 3 suites, landed 08-05 as "behavioral tests" in `b1cfb64`) asserts arithmetic on literals declared
  lines above
  its own `#expect` (`:103-109` asserts a non-nil literal is non-nil), and its sibling
  `GuidedGenerationIntegrationTests.swift` (13) asserts `!schema.isEmpty` on a schema literal it wrote and,
  twice, asserts the literal `true` with the claim carried in the *message* —
  `#expect(true, "GuidedGenerationLoop is a separate generation loop")` (`:137`, `:177`).
  **27 tests read by hand; none calls production.** No doc, probe or CHANGELOG cites either name, so no claim
  rests on them today — but they sit in the green `swift test` count the instrument's own S term reads.
  ③ The field spends that same counter as lane *policy*, not a published number: `mlx-serve` stops speculation
  mid-decode once per-draft acceptance falls under break-even and stays off for the request
  (`../references/mlx-serve/docs/performance.md:20`). Nobody else is moving on it: `MTPLX` — the tree our own
  lane is measured against, and the only comparator here whose HEAD was asked of the remote rather than the
  clone (`git ls-remote`, 11-04) — sits at `9882703f`, dated **10-03**, 32 d quiet with 0 commits in 14 d, so
  its row is current rather than stale and no new drafter behaviour is pending there. The movement is on our
  own side of the boundary: pin 1's `#581` resumable Qwen MTP, one row above. Owner call, two halves: delete or repair the 27, and
  whether our MTP lane should act on acceptance at all — the scripted engine already exists
  (`Engine/ScriptedInference.swift` + probe 37), so a real gate is one emit and one read away, not a new
  surface. Why no scan owns this: two attempts on 11-04 failed in opposite directions (one flagged 233 tests,
  the other zero) because `extension String` in `Sources` makes a plain `String?` annotation look like a
  production reach — only reading, or a mutation that must go red, decides it.
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
  does that (cites: `comparator-repos.md`). The field's answer, read 11-04, is not a smarter shortlist but a
  surface that is **reachable rather than resident**, and three trees reached for it independently: hermes
  ships 142 skills in `optional-skills/` that "are not copied to `~/.hermes/skills/` during setup" and are
  installed by a `hermes skills install` verb
  (`../references/hermes-agent/optional-skills/DESCRIPTION.md`; row: `comparator-repos.md`),
  goose's emulator asks for one schema at a time (`tool_emulation.rs:62`), `pi` ranks deferred tools with BM25
  and keeps them offered across compaction. Three trees, one shape — which changes the owner question from
  "what shortlist" to "what is installed, and who pays for the fetch". Wants a per-turn shortlist (whose
  score, who pays a wrong pick) plus the composer half. The pattern to extend is the knob already gated: render the checkpoint's template
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
  by capacity, or move the doc behind the base prompt (`MessageBuilder`). The direction this curve widens
  toward is measured (11-03, the model axis: `comparator-repos.md` — hybrid-GDN + native-MTP + 256K; the
  prerequisite is an owner download decision, not gate work).

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
- **The request that triggers a load waits out the whole load** (Engine/, Config/, UI/) — a waiter is
  released at 120 s with `AppError.modelLoading` while the *owning* request waits out the ~13 min fetch
  (diary 11-01(99), re-measured (101)). Closed since: the measurement crosses the wire (11-02(107) —
  `loadProgress` on the one `loading` row, the same keys in the 503; `ModelLoadProgressHonestyTests`(11),
  `EnginePoolLoadingGateTests`(5)), and the GUI renders a wait with a route instead of "Generation failed"
  (11-03(12) — `ChatState.failureFace`, `ChatFailureFaceTests`(5)). Open: a pool-owned load task, so the
  caller that triggered a load gets the same bounded pollable answer as every other caller. Two owner calls
  beside it — the 503 carries no `Retry-After` though both 429 families do (`AppError.response` sets it for
  `engineBusy` and a measured rate-limit wait only), and a poll cadence is policy, not a measurement, so
  none is guessed here; and whether a human caller should be held or refused at all.
- **The Models page now shows every wait; an engine-started one has no Stop yet** (UI/, Engine/) — the
  render keys on `ModelWaitFace` ∥ the pool's own `state:"loading"` (`ModelWaitFaceHonestyTests`(7),
  CHANGELOG 11-05), and only the transfer lane may open/close a progress row, so a waiter's 120 s poll-out can no
  longer evict the live row the wire's `loadProgress` reads. The row's duplicate-fetch premise is closed
  by reading, not measured: `prewarmDefaultModel` holds the pool's `loadingModels` slot (`beginLoad`) and
  both download paths lease `DownloadSemaphore` per repo id — no second 794 s fetch is reachable through
  either seam. Open: the prewarm task has no cancel affordance anywhere, so its ring renders without a
  Stop (honest, but a wait the user can only watch); the pixels half stays unverifiable on this host
  (`screencapture` refused — § UI guide); owner call: a pool-owned cancel route for prewarm.
- **The audit infers a write, it never reads the workspace** (Models/, Tools/) — a shell success is
  `.unobserved`; an unknown MCP tool still counts as a writer; the key is process-wide. Wanted:
  turn-scoped effect off the filesystem (codex, per turn:
  `../references/codex/codex-rs/core/src/turn_diff_tracker.rs:46`).
- **A demanded tool call is reported, not forced** (Engine/, Handlers/) — the unmet demand now rides in
  the result at all four sites; the engine still answers `required` with zero tokens, where sglang
  constrains it to a call
  (`../references/sglang/python/sglang/srt/entrypoints/openai/serving_chat.py:1937-1945`); qwen-code's
  exact-id face (`71119c6`, cell in `comparator-repos.md`) is the third.
- **A measured gallery is the one adoption surface we can win outright** (README/, Handlers/) — the leaders
  advertise model support as adjectives while `/v1/models` already publishes per-checkpoint measured verdicts
  (`vlm`, `contextLength`, `toolCallDelivery`, `reasoningEffort`, `videoInput`) and `scripts/eval/` scores a
  task board (count: `_eval.py count`, never re-typed here); owed is the artefact — a generated README table
  plus `models.json` (absent), refreshed by a probe with its
  command beside it (precedent: pi publishes its catalog from CI behind a compatibility gate,
  `../references/pi/.github/workflows/publish-model-catalog.yml:1-14`). Owner call: publishing a catalog is
  promising it stays true, and the refresh probe going red on a stale row is the instrument.

- **`/v1/embeddings` had no probe seat; its declared fields have one now** (Handlers/, Engine/) —
  measured 11-05 against the cached canonical embedder with real weights, on a live server. What is sound:
  1024-dim, l2 norm 1.000183 (the pooler normalizes before its layer norm, so exactly-1 was never the
  promise), `usage.prompt_tokens` are the embedder tokenizer's own counts (3 for "hello world", 1 202
  for a sentence repeated 120 times, and the batch total is their sum), batch `index`es and the summed
  `usage` are exact, and the three refusals
  name themselves (empty array, empty string, token-id array). What is open, none of it observed as an
  incident: ① the request's `model` is never consulted — `text-embedding-3-small` *and* a resident
  chat id both answer 200 with the canonical embedder's vectors, while the mirror case (a chat turn
  naming an embedder) refuses with an actionable 400 at `Handlers/ChatHandler.swift:219`; the response
  does name the model that ran, and this server has exactly one embedder, so no vector store can
  silently mix two spaces — the owner call is whether a named-but-unavailable model owes a 400.
  ② **closed for the two fields 11-06 named, open for the third face**: `encoding_format` is honored
  and `dimensions` is refused by name (`embeddingsWireEncoding`; gates `EmbeddingsWireTests`(13) + probe
  51), with the base64 string riding `embedding` — the fetched spec says `Embedding.embedding` is
  `anyOf: [array<float>, string(base64)]` (`openai/openai-openapi` ~:51627, read through
  `api.github.com` because platform.openai.com is unreachable from this host) and all four comparators
  that implement the parameter agree (ollama `openai/openai.go:533-549`, vllm
  `pooling/embed/protocol.py:206-209` + its own example, sglang `serving_embedding.py:270-279`,
  Rapid-MLX `routes/embeddings.py:323-336`); `b64_json` exists in that spec only on images. What stays
  open: an *unknown* top-level field is still accepted where OpenAI answers "Unsupported parameter" —
  sglang's own `EmbeddingRequest` ignores extras too, so the yardstick itself diverges from the spec
  here and root § Upstream's "spec, their implementation, real requests, observed behaviour" has no
  majority to read off. ③ batch composition moves a vector: the identical string
  reads max-component-diff 1.7e-3 (cos 0.99987) beside a 3-short batch and 1.5e-3 (cos 0.99990) beside
  a 1 202-token sibling — the deviation does not grow with pad length, so it is reduction order in the padded
  batched 4-bit matmul, not pooling over pads; negligible for ranking, named because the query path
  embeds alone while the index embeds in batches. ④ `/ready` shares the unread seat (advertised on
  `/v1/capabilities`, in `openapi.json`, never probed); `/v1/stats` got its seat on 11-05 in probe 37
  §10. Probe 51's §1-§2 run weight-free (a scripted boot answers them at the request boundary); only
  its §3 needs the embedder's weights, so that leg waits on the tier question below and prints that it
  skipped when they are absent.

- **`OCOREAI_AGENTS_MAX_AREA` and P18 were both priced against the wrong enemy** (docs/) — P18 keeps docs
  English by default with exactly one Chinese file (the owner's rule, and why this tree has no translation
  drift), but opencode ships 22 README locales (`../references/opencode/README.md:17-32`) and hermes-agent 3
  badge-linked, so the rule is a priced cap on a distribution channel, not a neutrality: deepseek-harness
  pairs each heading's en/zh block by hash in `README.i18n.yaml` so drift is machine-visible. Recorded so the
  owner prices it deliberately.

- **Seven prose cites into the file the 11-03 pin window rewrote were not all re-measured** (Engine/) —
  the bump `128f49f1d → b8d4935ab` changed mlx-swift-lm's `MLXFoundationModels/MLXLanguageModel.swift`,
  and three cites into it (`EnginePool.swift` :313 / :558 / :667) had drifted *before* the bump too: the
  referents are :37 (the doc example), :307 (the `[.guidedGeneration]` default) and :675 (the `.vision`
  gate). Those three now read `anchor:mlx-swift-lm` markers in `docs/agent/engine-line-cites.md`, so
  `make anchor-check` owns them (checked 77 → 80, drift 0). Sampled the rest rather than trusting them:
  `MLXBridge.swift:188` still resolves exactly (`:130` is the `configureGPUCacheOnce` it names), while
  `EngineInferenceSupport.swift:305` points at `:1427-1431` for a soft-nudge recipe and those lines are
  `runSchemaGeneration` — the sentence and the line disagree today, and no gate reads either. Remaining
  sites: `OpenAIModels.swift:1212`, `EngineInference.swift:2284`, `:2714`, `EngineInferenceSupport.swift:273`,
  `PromptTokenAccountingTests.swift:24`, plus that one. The fix is the same marker conversion, one cite per
  edit, in files on the hot path; owner call on spending that diff. Interim instrument at every bump that
  touches this file: `make anchor-check` plus a grep of these seven.

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

- **Loaded-host reds rotate cast; wall-clock is one class, the anchor another** (Tests/) — magnitudes
  11-02(106), 11-03(3). ① wall-clock bounds bet on the ~618-suite cooperative pool;
  `instant+control` does not fence it — production behaviour, not a test premise; the median is
  measurable, the tail is not. ② production writes the anchor outside every lease
  (`SessionWorkspace.swift:114`, `SessionManager.swift:138`); 11-03(3) lost a content suite that way
  once (inferred — the lease scan only sees test-file writes). Closed: the ledger's cross-suite half
  (11-02(105)). Wanted: a controlled clock (`ClockToolsTests`), a quiet lane (`make test-clt`), or
  the anchor's scope. Owner.
- **The 11-02 compat sweep left one owner call, one dated debt and one seatless surface**
  (Middleware/, Router/, Security/) — the swept axes landed (spec-name `error.type`; `max_model_len`
  aliased one release, 11-02(110)); ① the eight hand-built error bodies render through
  `AppError.response` since 11-03 (probe 50, `MiddlewareEnvelopeDisciplineTests`), though the keyword
  guard sharing that family reaches no wire still — `SafetyConfig` defaults `enabled: false`, so a
  config seat is the owner's. ② Jev's answer half is read from both stacks, unwritten until the answer
  position scores (probe 49; `systemone-decisions.md` § Shape C). ③ drop the `contextLength` alias
  (+ probe 03's clash check) the release after it landed.
- **A child process inherits the server's whole environment, keys included** (Tools/, MCP/, Security/) —
  found by reading the seven `Process()` sites, and the premise proved by running it: a Foundation `Process`
  whose `environment` is never set hands the parent's env to the child (sentinel set here, `env | grep -c` in
  the child printed 1). Six sites leave it unset — `Tools/ExecTools.swift:191`, `Tools/ExecSessions.swift:278`,
  `Tools/PostWriteSyntax.swift:123`, `SQLite/SessionWorkspace.swift:209`, `App.swift:677`,
  `MCP/MCPStdioClient.swift:246` — and the seventh starts *from* the full parent env and adds a marker
  (`Multimodal/HearingEngineProbe.swift:170-172`). In reach: this server's own bearer keys
  (`OCOREAI_API_KEYS`/`OCOREAI_ADMIN_KEYS`, `Middleware/AuthMiddleware.swift:48-49`) and whatever the launching
  shell exported. What is already held: the shell faces are approval-gated (`ExecTools.swift:26` →
  ApprovalBroker) and every tool result is redacted on the **return** path (`Security/SecretRedactor.swift`,
  applied at `Tools/ToolRegistry.swift:697`, gated by `SecretRedactorTests` + `ToolResultWireDeliveryTests`).
  Redaction cannot cover the **handover**: an MCP server is third-party code that holds the bytes the moment it
  starts, from a command handed to `MCPBridge.connectEndpoint` (`MCP/MCPBridge.swift:931`, reached at `:286`)
  with no approval concept in its path. Precedent, same defect class: harness2 `742d48f` — "Every launcher
  except the improver passed the whole host environment to agent subprocesses, keys included" — fixed by
  scrubbing at every launcher with per-launcher exceptions named in the message and in `docs/SETUP.md`.
  Three shipped precedents for the same boundary, read off the mirrors 11-04 (§ *Where the field confines a child*
  in `comparator-consensus.md` holds the axis): TensorFold spawns the MCP child under `/usr/bin/sandbox-exec -p
  <profile>` with per-config read roots and **refuses** when no profile can be built, naming the way out, while the
  spawn spec itself carries `sandboxed: true|false` (`TensorFold/app/electron/agent/mcp-process.ts:173-186`);
  Rapid-MLX declines to *grade* an agent it cannot confine
  (`Rapid-MLX/scripts/benchmark_glm53_real_tasks.py:226-228`); and deepseek-harness is the one that treats it as a
  product surface — four `packages/sandbox/*` packages (95 tracked files today) confining a subprocess to a
  **file-effect** policy of `read-only` / `workspace-write` / `danger-full-access` with per-platform backends, where
  a denied call "can retry through a user-approved one-time escalation" and the same paragraph states the limit
  instead of hiding it: *"Confinement is same-world only: it shares the host kernel and filesystem"*
  (`../references/deepseek-harness/packages/sandbox/README.md:12`). None is a scrubber, so none answers the
  handover alone — the third one is the shape of the boundary, the first two are the shape of the refusal.
  Owner call (§ Working here: a security edge names mode, likelihood and cost first, and no guard gets written
  on an unobserved failure): mode = a user registers an MCP server the way READMEs tell them to; likelihood =
  deterministic, not a race — the child receives the env at exec; cost = one scrub policy at the launchers that
  own a value plus the exception each needs (the probe needs its marker, the syntax checker needs `PATH`).
  Not claimed: that any checkpoint here has been observed reading a key — the finding is the code path and the
  proved premise, not an incident. No root § Open line: the cap has 8 B of headroom, so the address stays here.
- **A wire route can point this box's camera, microphone and screen at a caller** (Handlers/, Multimodal/,
  Security/) — the same authority question as the bullet above, inbound instead of outbound. `POST
  /v1/multimodal/capture` takes `camera | microphone | screen` (`Handlers/MultimodalHandler.swift:24-28`), is keyed
  rather than public (`Middleware/AuthMiddleware.swift:146-154`), and is held by 3 of 12 serving trees in the mirrors
  with all three editing it now — 1 of 12 for the live-input half — so it is a direction by this corpus's own test,
  not an eccentricity (§ *The wire that points the box at the world* in `comparator-innovation.md`, which carries
  every comparator cite). Three faces, read off our own code paths, none of them observed as an incident:
  **(a) caller identity stops at the bind** — `ServerAuthGate` refuses a keyless server any non-loopback bind
  (`Middleware/ServerAuthGate.swift:9-35`), so once a key exists a caller on the LAN and a harness on this box are
  the same caller; `Rapid-MLX` discriminates **per request** where we discriminate at boot, 403ing a non-loopback
  client on `POST /v1/cua/permissions/request` behind a config flag
  (`../references/Rapid-MLX/rapid_mlx/routes/cua.py:574-600`). **(b) the user's own off-toggle is not on the wire
  path** — the toggles start `false` (`UI/Models/MultimodalState.swift:42,51`) and gate the perception engine, while
  `captureGate` asks only what TCC measured (`MultimodalHandler.swift:160-176,275-295`) and the camera leg will
  `startCapture()` for the caller (`:177-179`); the comparator's equivalent is a server-side default-off flag whose
  refusal names itself and carries a `recovery` array (`rapid_mlx/routes/cua.py:429-431,925-936`). **(c) a frame has
  no ceiling and no cache directive** — it caps one observation at 4 MiB and answers a named 413 (`:426,988`) and
  stamps `Cache-Control: no-store` on the frame and on the error alike (`:510,918-919`), where our capture response
  sets no cache header anywhere (the only `no-cache` in `Sources/**` is `SSEHelpers.swift:74`).
  Owner call, not a task (§ Working here: a speculative edge names mode, likelihood and cost before anything is
  written): mode = a caller holding a key asks for `screen` or `microphone` from another machine, or the person at the
  box has toggled that channel off; likelihood = deterministic once the key exists, not a race; cost = three small
  decisions at one gate (`captureGate` plus the response builder), each with a shipped shape above and none of them a
  new subsystem. Not claimed: that any caller has done this — no consumer has a name here, which is why this is an
  address and not a diff.- **The per-guide byte cap does not reach the two largest docs in the repo** (scripts/eval/, scripts/probes/) —
  `scripts/agents-md-contract.sh:258-261` builds the capped set from four globs (`Sources/**` + `Tests/**` +
  `docs/**` AGENTS.md, plus `docs/agent/*.md`) at 38 945 B, so `scripts/eval/README.md` (77 077 B) and `scripts/probes/README.md` (54 644 B) are uncapped and are
  3–8× the peer norm for a dev-tooling README (~9–26 KB across the 14 peers that have one; one 385 KB outlier).
  Both stayed on the 11-05 deletion pass, and for the invariant-1 reason: they are the declared single home of the
  noise band, set size and paired-flip floor. Owner call: extend the cap to tooling READMEs, or record that it
  deliberately does not reach them — the silence is what makes the two numbers unreadable as either normal or not.
