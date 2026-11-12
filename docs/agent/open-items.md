# Open — measured, unresolved

The long form of § Open in `AGENTS.md`, which owes only the address. Nothing here is a capability claim:
where a number is unmeasured it says so, and where a fix is blocked by the host or by upstream it names
which. A resolution goes to `docs/agent/closed-items-log.md`; a decision becomes a rule in `AGENTS.md` or
the area guide, with its gate. Per-item evidence is in `CHANGELOG.md` (grep the symbol).

- **The nameless `tool_reference` exits by silent drop — a guard side-effect, not a picked exit**
  (Models/) — the defect this row described (billed-but-invisible; `111c120f` shipped the instrument, its
  nonce-isolated WHOLE arms landed 905/908/905) closed 11-11: references render `Available tool:
  <tool_name>` at the one accessor the guard and the prompt share (`AnthropicModels.swift:342`), live 15/15
  on probe 07 with the name echoed like the TEXT control; the closed-log row carries the numbers and the
  splash precedent. What the shipped guard chose **without a decision**: a reference with no `tool_name`
  contributes nothing (`AnthropicModels.swift:341`) — Strata's documented drop (a gone MCP server must not
  fail the session, `../references/Strata/serve/frontend.py:664-673`), while sglang's GLM template refuses
  the unresolvable by name; the field's three exits (carry / render / refuse — vllm and sglang cites at
  `07 §2c` header) collapsed to render-and-drop. A face named for the first time, unmeasured: a delivered
  name absent from the turn's `tools[]` still renders `Available tool: <name>` — availability asserted for a
  tool nothing measured. Owner call: keep Strata's drop or refuse by name, and whether an unknown name owes
  a refusal instead of an assertion.
- **A warm re-send of an identical anonymous conversation bills the server's own previous turn**
  (Engine/, Handlers/) — measured 11-10 against a live serve, three `/v1/messages` re-fires of ONE
  stateless conversation: cold `input=899, cache_read=0`; warm `input=59, cache_read=908`, next re-send
  `cache_read=970` — the whole (`input + cache_read`, the identity `AnthropicCacheUsage` declares a
  breakdown may never exceed) reads 967 → 1029 against a 899-token render, growing per re-send, and
  `StdTurn fed=3 of 3 divergence=0 upstreamCached=908…` names the mechanism: the std lane's `:anon:` slot
  treats a re-send as a continuation, so its own previous answer's KV and positions ride into the request's
  account and the conditioning. `PromptTokenAccounting`'s add-back (Handlers guide §"a usage field carries
  the quantity its name claims") is not the site — its numbers are engine-scope truth, correct for a real
  continuation where the caller re-sends the answer as history; the site is upstream's `cachedPromptTokenCount`
  being session-scope where the wire promises request-scope. Repair shape: truncate at the divergence point
  so the cache-read portion is request-scope (and the answer regenerates, as stateless means); the choice to
  gate `:anon:` KV sharing is the owner's — it sits on the loop seams the open rows around Pin 1 call
  sensitive. Instrument: probe 07 §2c's nonce-isolated NOTE lines print each arm's whole; 59-token
  cold-looking arms next to a growing cache_read are this row's return.
- **Sessions carry a TTL promise nobody enforces** (SQLite/, Scheduler/) — every `INSERT INTO sessions`
  writes `ttl_days` (default 180, configurable: `SessionCompressor.swift:114,120,72`; read back at
  `:1073`), and no code enforces it: the enforcer `purgeExpired()` had **zero callers** repo-wide
  (measured 11-09; it, its DTO `ExpiryTask` and the never-read helper `SessionModel.expired` were deleted
  same-round — the sweep that removed the genuinely-dead `MCPCallCache.purgeExpired` uncollided the name
  and `unreferenced_decls_ours` went 0→1, which is the claim catching what three files hiding one name had
  masked). Expired sessions accumulate
  forever. The promise itself (column + config) stays; deleting the never-run enforcer deleted no
  behaviour. Revival is cheap — the TTL SQL is in `git log -S purgeExpired`; the wiring call is
  destructive (it DELETEs messages and sessions) and needs the owner's route: sweep on a tick (which
  seam), on boot, or retire `ttl_days` from schema and config (also a promise change). Until then every
  "retention" claim about sessions reads as unenforced.

- **A tool result bills 5 tokens on the shipped default checkpoint — the loss is content, and it is upstream of the template** (Engine/, Handlers/) —
  measured live 11-12 by probe 57 with the product's default checkpoint loaded: baseline 872 → 877
  with a ~2 500-token `role:"tool"` result on **all three faces** (OpenAI ladder-name, OpenAI
  caller-name, Anthropic `tool_result`), while the control arm — the same text block as user-role
  content — bills **+2 488**. The model never sees what its own call returned, from the *first*
  iteration, not just from the second as earlier believed. Two claims died getting here: (a) "the
  host holds no LLM weights" — false; they sit at the workspace anchor `~/.ocoreai/models`
  (gemma-4-e2b-it-4bit, 3.3 GB, complete), which is where the 11-09 live numbers already came from
  — the row contradicted its own evidence; (b) name-threading was the smaller leg:
  `ff3e4a66` + `3b7fda25` label the metadata correctly on both lanes (gates green) and move **zero**
  of these tokens, exactly as their own pair-level gates implied. Localization from the checkpoint's
  own `chat_template.jinja`: the main loop *skips* `role:"tool"` (`:217`) — results render only via
  the assistant `tool_calls` forward-scan (`:271`-`:315`), so delta 5 convicts a **lost assistant
  `tool_calls`** between our `Chat.Message.assistant(_:toolCalls:)` conversion and
  `Gemma4MessageGenerator`. Which hop, next round — the cheapest next arm is the raw dict the
  generator actually receives. Gate: probe 57 (control guards the instrument; the three tool arms
  report `probe_xfail open` and XPASS red on the day a fix lands, forcing promotion). Still open
  beside it: the MTP loop never re-appends its own assistant tool-call turn (only think-then-call
  text, steers, results), so the pairing question arrives with the content fix, not after it.
- **Durability is priced twice, and the second price indicts the mechanism, not the message** (Tools/, eval/) —
  the pre-write gate (refuses valid→broken syntax, keeps old bytes: **110/110 corruptions stopped, zero silent
  damage**) cost the frozen set **2.17 tasks/52 (p=0.0146)** at bare reason, and still **1.83 (p=0.0266)** with the
  field's best payload — stated line (codex `lib.rs:353`), the caller's own failing bytes quoted verbatim
  (openclaw `edit-diff.ts` shape), the recovery-proven ordered retry. **Pooled b=35 c=11, p=0.00054** — at this
  checkpoint repair is rewrite-through-broken-states and the refusal, whatever it says, removes the stepping stone;
  this is also why no comparator tree gates writes (11-09 survey). Owner's remaining question, sharpened: pay the
  ~2-task fixed price for zero-corruption anyway (a stranger's script survives), re-measure the same patch on a
  larger checkpoint where repair-by-rewrite may not be load-bearing, or close the trade. Patches + both verdicts +
  the 15-test suite: `scripts/eval/proposals/syntax-regression-gate{,-v2}.patch|.md`; ledgers `20261108-230722`,
  `20261109-001350`.
- **The loop can now price a build; the base it trusts is still the operator's** (scripts/eval/) —
  `HYPOTHESIS_AXIS = ("binary",)` is granted only when both arms state the same commit (gates: `_autoab_selftest.py`
  scenario 14, 18/18 mutations), so a base root written before 11-09 is refused, not trusted; the loop still takes
  its base from `OCOREAI_AUTOAB_BASE` rather than measuring one per invocation — self-baselining costs +k board
  runs per loop and is the owner's call. `edit-noop-split-strip`'s McNemar row (`20261109-213417` refused on the
  old rule) is next round's claim, not this one's.
- **The frozen board cannot seed a CRLF file, so no byte-fidelity class is priceable there**
  (scripts/eval/) — `grep -c '\\r'` is 0 across `tasks.json` (45) and `tasks-edit-repair.json` (52), so
  `edit_file`'s line-ending rung (`FileTools.Endings`, 11-10) has no task that can move: a
  strip-proposal would return "inside noise" because the instrument is blind, not because the change is
  free. Seeding a CRLF fixture means editing a path `autoloop-protected.txt` names a human act, so the
  call is the owner's. Gate meanwhile, and byte-exact: `LineEndingFidelityTests`.
- **A `response_format` turn cannot ground itself; the limit is disclosed, the fix is a call** (Engine/, Handlers/) —
  with `tools[]` declared beside `response_format` the answer grammar wins (`OpenAIModels.swift` "the JSON wins",
  four orderings measured there) and the turn cannot emit a tool call first, so it fabricates instead of reading
  (board structured tasks, both arms 11-08, deterministic at temp 0 — 3/45 tasks priced). The disclosure shipped
  same day: tier row `structured_output` + probe 54 pins disclosure↔behaviour; sglang treats the pair the same
  (`serving_chat.py:1130`), so staying is defensible. The fix shape is a per-iteration grammar: tool grammar while
  the loop runs, the caller's schema only on the final turn — engine surgery, and it would DIVERGE from sglang
  while matching the OpenAI spec's final-message semantics. Owner call: stay disclosed or build the final-turn
  constraint.
- **A stall stops MTP hard, the std lane only by consent** (Tools/, Engine/) — the ladder and
  `LoopStallTerminationTests` landed; upstream `mlx-swift-lm`'s `restart:` loop (ChatSession.swift:1164) still has no
  cap, and a std-lane hard stop throws out of `toolDispatch` (:1632) reaching the wire as an error, not a
  finished turn — the terminal word for four faces is the owner call; field constraints mined
  11-03: `CHANGELOG` 11-03(1).
- **CoreAI / macOS 27 items unverifiable on this host** (Engine/) — three `@available(macOS 27.0, *)` or
  SDK-gated sites (detail: `docs/agent/build-gate-reality.md`) ⇒ no blind fix and no claim of one; their
  suites now skip on this OS through `PlatformPremise.hasMacOS27` instead of reporting a red.
- **The coreai fork's debt is named open verdicts, not a drift window** (Engine/) — 8 of them from
  77a122f reading all 36 commits behind the four engine windows (7 absorbed, 21 n/a), 3 from the #388/#374
  read, 3 from the 11-05 read, 2 from the 11-06/11-09 reads (#412's GPU-error stop and #490's
  repetition-penalty carry-in: our `CoreAIPipelinedEngine.swift` still carries the pre-fix yield shape
  (`:1050`) and the pre-fix lazy-penalty shape (`:859,:1387`), both ports wait the macOS 27 window);
  one row each with its action in
  `docs/agent/coreai-fork-window-log.md` (#368 measured 10-30 by probe 12 §5b: the shipping lane damps whitespace via
  upstream `WhitespaceTokenBias`, so its exposure is CoreAI-only, unverifiable here). `make drift` reads 0
  un-adjudicated per file since the 11-09 window read. The axis since has moved export-side **and** through two Swift commits in
  `CoreAILanguageModels/SpeculativeDecoding/` — a target this tree mirrors nothing of (rows: that log's
  § Window read 11-05), so § Upstream 2 still has no surface for it. The ledger's other face is the bigger
  half: of 56 candidates it calls **36** mirrors unread — **25** carry no sha at all, **11** carry one in
  prose the reader will not guess at (two of those would be read *wrong*), so their window is not empty, it
  is unmeasurable until someone writes the canonical read-point; `make drift` prints both counts every
  round, and the eleven are listed with their sentences in that log's § Window read 11-05 (b).
- **The `+6` mlx-swift-lm window hands us a truth we cannot read until the bump** (Engine/) — read 11-05 in
  a local clone at `c8dabc6`: `GenerateCompletionInfo` gains `speculativeDecodingFallbackReason`
  (`Evaluate.swift:3083`) naming the five reasons a session with speculation configured ran plain
  generation. We already consume that struct's siblings (`passthroughReason`,
  `speculativeDecodingTelemetry` → `EngineEvents.swift:88`), so the traditional-SDC lane's silent fallback
  is the one face still unnamed. Same window: #747's `RotatingKVCache` mask fix is **inert here** while
  `keep == 0`, which is every path we reach — `makeKVCacheConfiguration` (`MLXBridge.swift:896`) passes
  `strategy` + `rewind` only, and `Capacity.init` is the sole route to `keep > 0`, defaulting to 4, so
  setting a capacity silently pins 4 tokens. Upstream `mlx-swift-lm`'s `restart:` tool loop is still
  uncapped (`ChatSession.swift:1226`), so the stall item above keeps its premise. Instrument: `make drift` prints
  the axis; `make anchor-check` re-points the markers into the files #581 touched — 13 of them per
  `api.github.com` pulls/581, of which our cites reach two: 27 markers into `ChatSession.swift`, 9 into
  `Evaluate.swift` (re-grepped 11-06; anchor-check prints the set).
  Premise flipped 11-06, the same day it was written: Metal is restored (that day's `toolchain-check` →
  `metal=ok-probed`), and git-over-https — read dead (curl 28/HTTP2 framing) earlier the same day — answered
  again that evening (`git ls-remote --heads https://github.com/ml-explore/mlx-swift-lm` exit 0, refs listed).
  A flapping host premise, so re-test that one line before the hand; nothing was re-resolved blind. Owner call
  unchanged: the bump is a hand, not a gate.
- **A turn with no tool call cannot be interrupted** (Engine/) — the drain points are the tool-result tail
  and the MTP loop; a tool-bearing turn provably breaks in-run (probe 21). Upstream `mlx-swift-lm`
  answered the rest at the 11-07 pin: #608 put mid-turn steering *in* `ChatSession` (`steer(_:policy:)` applies at a complete-text or
  step boundary, keeps emitted output and completed tools, reports `GenerateStopReason.steered` per yielded
  step plus a `Generation.steering` event; the `db2e7bf`/`observe(to:using:)` seam this row cited yesterday
  was only the hook — and `991266ad3`, which an earlier copy named, is that same day's #710, a prefill-buffer
  cache). Nothing of ours calls it: the four switch arms the bump added are inert until `SteerQueue` reaches
  `session.steer` on the session's owning actor and the wire can take a steer mid-stream.
  **Adjudicated 11-11 by the lane read: adopt, staged.** Upstream owns the loop the wrapper duplicates:
  `restart:` at `ChatSession.swift:1319` threads `mtpDrafterContinuation` stepwise; `steer` is public
  (`:1106`). Landing: an opt-in loop-selection flag (default local), flip on a paired board verdict plus
  probe 21 `chat`-arm green, loser deleted whole. The stall row's terminal word stays the owner's.
- **Thinking is uncounted on the tools lane** (Engine/) — probe 44 §2: 550 chars, no
  `reasoning_tokens`. Upstream counts only via the processor that also bounds the thought, and a
  bound there starves the tool call (§2b: 200→500 at 64 tokens). A count-only processor waits
  upstream. Owner call. Datum 11-07 (the wedge's own task prices it): of 4 §2 runs on the shipping
  tree at Qwen3.6-35B, **1 died `finish=length` mid-work** — first-person narration ate the harness's
  900 tokens after 4 executed `exec_command` calls — and 3 passed (`finish=stop`); the pre-bump
  v0.1.14 artefact went red on its own k=1 with a different mechanism, so the flip is at the budget
  boundary and predates the +13 window, not a regression from it. The pass rate is unmeasured; the
  flip is. Sample lines: CHANGELOG 11-07 (wedge re-check). Datum 11-04: the model family ships a wire word for this cost —
  `preserve_thinking` retains "reasoning context from historical messages"
  (`../references/Qwen3.8/README.md:25`) — so a caller that retains thinking pays tokens we cannot price
  for it (inference from a README, not a measured interaction).
- **Pin 1's window is taken, so the two ours-shaped commits are now unconsumed, not pending** (Engine/) —
  `mlx-swift-lm` bump 11-07 `b8d4935ab → 4ab267996` (+13) carried #581 (resumable MTP *inside* `ChatSession`), #608
  (mid-turn steering) and #747 (`RotatingKVCache` pinned prefix in multi-token masks). All three compile in
  and change **nothing** until consumed: our MTP lane still drives its own token loop and `SteerQueue` still
  drains at the tool-result tail, so the MTP row, the stall row and the interrupt row above all wait on one
  decision — *adopt what upstream's `ChatSession` loop now owns, or keep maintaining the local lane beside
  it* — **ruled adopt-then-retire 11-11**, staged through the interrupt row's flag; what remains is
  execution (the owner's push window per § Upstream 1), not decision.
  The MTP half still deserves the acceptance row's read: a *resumable* drafter changes what that gate
  would measure. The window moved again 11-10 (+2 → `ec4c966`) and both commits were adjudicated the same
  round, and the same evening convicted half of that reading: `#774` (logprobs during speculative decoding)
  does stay unconsumed — our lane never requests them — but `#724` (greedy MTP verify batched to one GPU
  readback) lands **on a consumed path**: `EngineInference.swift:3914` calls upstream
  `generate(mtpDrafter:)` (checkout `Evaluate.swift:2559`), whose verify loop IS the
  `MTPSpeculativeTokenIterator` #724 rewrote — "drives its own token loop" meant the tool-loop wrapper, not
  the verify. So the next bump carries a measured 1.25–6.4× verify speedup (greedy + stateless processor —
  the board's and eval's temperature), e2e 27.7→28.5 tok/s Qwen3.5-4B-4bit block-2 (M2), parity claims
  exact; the bump itself waits its protocol turn (test-ci is the CI tier — owner's push window). #724
  simultaneously weighs the adopt-vs-keep call: upstream's loop is not just owning more, it is owning more
  *faster*. coreai-models' +3 window judged
  same round too: an RNG file-move (our `Video/RandomSource`/`TorchRandomSource`/`SeededRandomNumberGenerator`
  mirrors' come-from relabels to `CoreAIShared/RNG` at next re-read), a python packaging chore, and a
  python export-side RoPE precision fix — none touches a consumed surface. Third axis clean:
  `mlx-swift tag=0.33.0 pin=0.33.0`. (Instrument note this row carried — one
  verdict, exit **10** then **2** — closed: `closed-items-log.md`.)
- **MTP acceptance is threaded and unused as a signal; its sounding suites are deleted** (Engine/, Tests/) —
  found by reading, not by a scan. ① The counters are real: `proposedDraftTokens`/`acceptedDraftTokens`
  (`EngineEvents.swift:105`) are threaded at `EngineInference.swift:3432`, `:4229` and read by
  `ChatViewModel.swift:1189`. ② Resolved 11-11: `b1cfb64`'s two "behavioral" suites (14+13), which
  *sounded* like this gate, were independently re-read and deleted — every assertion judged its own
  literals, none called production; the closed-log row carries that proof plus the real guided-gen gates
  that stand. What stays ungated exactly as before the deletion: the threading itself — the flag row
  below owes the one emit + one read.
  ③ The field spends that same counter as lane *policy*, not a published number: `mlx-serve` stops speculation
  mid-decode once per-draft acceptance falls under break-even and stays off for the request
  (`../references/mlx-serve/docs/performance.md:20`). Nobody else is moving on it: `MTPLX` — the tree our own
  lane is measured against, and the only comparator here whose HEAD was asked of the remote rather than the
  clone (`git ls-remote`, 11-04) — sits at `9882703f`, dated **10-03**, 32 d quiet with 0 commits in 14 d, so
  its row is current rather than stale and no new drafter behaviour is pending there. The movement is on our
  own side of the boundary: pin 1's `#581` resumable Qwen MTP, one row above. **Ruled 11-11:** the 27 are
  deleted (②); whether the lane acts on acceptance *at all* rides the loop-flag flip — lane policy written
  for a loop being retired pays twice — and the scripted engine makes the real gate one emit and one read
  on the surviving seam, not a new surface. Why no scan owns this: two attempts on 11-04 failed in opposite directions (one flagged 233 tests,
  the other zero) because `extension String` in `Sources` makes a plain `String?` annotation look like a
  production reach — only reading, or a mutation that must go red, decides it.
- **Rewind is landed; the reserve is visible and overridable, still untuned** (Engine/) — 1024 rows measured on
  one checkpoint, not tuned to model or memory pressure, so an edit further back than the reserve still pays its
  full prefix. Since 11-11 the number is not hidden: the kv-cache endpoint publishes `rewindReserve` with its
  `basis`, and `OCOREAI_KV_REWIND_RESERVE_TOKENS` overrides once at boot (0=off; a negative or unparseable value
  keeps the default and says so on the wire) — tuning can now be priced against a number the operator can set.
  `SessionRewindOnDivergenceTests` + `KVCacheRewindReserveTests` + probe 27 hold the wiring and the number.
- **Reasoning-lane traffic is unaccounted** (Engine/) — the no-tools lane (`"Routing through reasoning
  path"`) never realizes the pooled session's cache: release reads `cacheStatus()` at zero, so gauge,
  `/kv-cache` residency and the admission price all stay `not_observed`/fallback for it, while a
  tools-bearing turn on the same server prices 26.7 MB/1651 tok (measured 11-11, one boot three shapes;
  green 10-25 on the same shape puts the window at the 11-07 bump). Corroborated by probes 19/29/31/32/35
  (attribution: 35 measured, the rest inferred — `CHANGELOG.md` sweep entry; all five counts re-measured
  identical on the 11-11 HEAD after the media/wire fixes — the class sits untouched below them). Price the lane from its own
  turn or refuse to pool it as warm is the owner's design call; the reds state which traffic the surfaces
  cannot price.
- **The video record still trusts the processor consumed the frames** (Multimodal/) — the 11-07 over-report
  is closed at its root (media turns had been routed onto the std-reasoning lane, whose `(role, content)`
  rebuild drops `Chat.Message.media`; probes 08/17 flipped green with the routing fix). Residual: the rule
  itself — decodable parts in a completed turn, not tokens received — can still over-publish on a
  checkpoint whose `processor_class` ignores `input.videos`; the color-naming gate covers only the probe
  checkpoints (next row; `VideoDeliveryLedger`).
- **Video publishing is per-checkpoint** (Multimodal/) — one processor reads `input.videos`, the other does
  not, so it is never inferred from architecture; a turn that got frames but never answered is not
  counted; relaxing that is untested (`VideoDeliveryLedger`).
- **Screen capture cannot start a stream headlessly** (Multimodal/) — authorized, display attached, still
  "cannot start stream", while the camera on the same box delivers: an SCStream-in-no-GUI-session limit,
  not TCC. `screenStatus` is `ready` only after a delivered frame.
- **GUI e2e proves the window, not the driving** — the completion leg stays the escalation tier's:
  the field ships model-backed agent gates on self-hosted silicon only (Rapid-MLX's `agent-gate.yml`).
  Accessibility control unverified. Scope: `UI/AGENTS.md` § GUI end-to-end.
- **Prefix questions ruled by the field's shipped shape** — sglang keys identity in, so a cross-
  conversation share misses, never collides (`hicache_key_scheme.py:34`), and no serving tree refuses
  a changed instruction — vllm logs and degrades to a standard completion (`message_assembly.py:99`).

- **A turn's tool surface costs 19 points; one knob is gated, the surface is not.** Measured on
  `gemma-4-e2b-it-4bit`: 6 tools against all 40 ⇒ **−18.8 pp, McNemar exact p < 0.0001** — read it as *what a
  turn is handed*, not "fewer tools everywhere" (two exec faces improved full-surface, every edit/fix face
  collapsed); per-arm rows, the noise floor and the recipe: `scripts/eval/README.md` § the repeat recipe. The
  open half is a product call: the wire is caller-scoped (`Tools/ToolRegistry.swift:135` — no `tools[]`
  declared ⇒ no tools), while the app hands the whole registry over every turn
  (`UI/ViewModels/ChatViewModel.swift` `toToolDefs()`: 40 declarations, 25,092 B, to a 4-bit checkpoint); no comparator
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
  `ReasoningEffortHonestyTests` + probe 38.
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
  `loadProgress` on the one `loading` row, the same keys in the 503; `ModelLoadProgressHonestyTests`,
  `EnginePoolLoadingGateTests`), and the GUI renders a wait with a route instead of "Generation failed"
  (11-03(12) — `ChatState.failureFace`, `ChatFailureFaceTests`). Open: a pool-owned load task, so the
  caller that triggered a load gets the same bounded pollable answer as every other caller. Two owner calls
  beside it — the 503 carries no `Retry-After` though both 429 families do (`AppError.response` sets it for
  `engineBusy` and a measured rate-limit wait only), and a poll cadence is policy, not a measurement, so
  none is guessed here; and whether a human caller should be held or refused at all.
- **The Models page now shows every wait; an engine-started one has no Stop yet** (UI/, Engine/) — the
  render keys on `ModelWaitFace` ∥ the pool's own `state:"loading"` (`ModelWaitFaceHonestyTests`,
  CHANGELOG 11-05), and only the transfer lane may open/close a progress row, so a waiter's 120 s poll-out can no
  longer evict the live row the wire's `loadProgress` reads. The row's duplicate-fetch premise is closed
  by reading, not measured: `prewarmDefaultModel` holds the pool's `loadingModels` slot (`beginLoad`) and
  both download paths lease `DownloadSemaphore` per repo id — no second 794 s fetch is reachable through
  either seam. Open: the prewarm task has no cancel affordance anywhere, so its ring renders without a
  Stop (honest, but a wait the user can only watch); the pixels half stays unverifiable on this host
  (`screencapture` refused — § UI guide); owner call: a pool-owned cancel route for prewarm.
- **The audit infers a write, it never reads the workspace** (Models/, Tools/) — the process-wide
  key closed 11-10: the wire handlers mint a turn key, the engine threads it to the chokepoint, and
  `since(_:turnToken:)` credits only that turn's dispatches (`ClaimVsAuditTurnKeyTests` pins the
  filter, the equality direction, and the wiring scan). What the key does not fake: a shell success
  is still `.unobserved`, an unknown MCP tool still counts as a writer. No lane is left unkeyed:
  the FM proxies forward the key (compile-verified here and on the SDK-27 legs; the runtime half
  waits the macOS-27 window, where `PlatformPremise` springs the suites), and the CoreAI/ANE
  engines hold no `ToolRegistry` reference at all — they never dispatch in-process, nothing to key.
  Wanted: turn-scoped effect off the filesystem (codex, per turn:
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
  and `dimensions` is refused by name (`embeddingsWireEncoding`; gates `EmbeddingsWireTests` + probe
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
  embeds alone while the index embeds in batches. ④ `/v1/stats` got its seat on 11-05 in probe 37 §10;
  `/ready` followed 11-11 in §11 — idle predicate, current stamp, `loadedModels` parity, all weight-free.
  Its busy face has no scripted-lane seat *by construction*: the lane resolves turns with nothing
  resident (`EnginePool.swift:519-523`; 10 concurrent streamed turns read zero busy across 300 polls),
  so that witness waits on the tier question below. Probe 51's §1-§2 run weight-free (a scripted boot answers them at the request boundary); only
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
  `runSchemaGeneration` — the sentence and the line disagree today, and no gate reads either. Settled
  11-11: OpenAIModels/PromptTokenAccountingTests re-measured and de-numbered (two cited ranges were
  inverted outright), and `EngineInferenceSupport.swift`'s six sites re-read — two claims convicted:
  its quoted recovery phrase is gone upstream, and the sha that "landed" the contract is not an
  ancestor of the pin (merge-base exit 1; object present), so provenance shas left the prose and the
  live contract is the Throw-before-dispatch its anchor pins; four new anchors own every surviving
  number. Both `EngineInference.swift` sites were adjudicated against HEAD: claims TRUE, pointers
  stale; the de-numbering is mechanical, waiting on the file's live copy, not on knowledge.

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
  (11-02(105)). 11-11(8): four passes (5/3/8/8 issues), no cast repeated, every red green in isolation —
  and the fourth pass owned the box exclusively (my earlier "box load" attribution is corrected: the
  suite-internal pool alone suffices). Wanted: a controlled clock (`ClockToolsTests`), a quiet lane
  (`make test-clt`), or the anchor's scope. Owner.
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
  proved premise, not an incident. No root § Open line: the cap has no headroom to spare, so the address stays here.
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
  address and not a diff.
- **The per-guide byte cap does not reach the two largest docs in the repo** (scripts/eval/, scripts/probes/) —
  `scripts/agents-md-contract.sh:309-312` builds the capped set from four globs (`Sources/**` + `Tests/**` +
  `docs/**` AGENTS.md, plus `docs/agent/*.md`), so `scripts/eval/README.md` and `scripts/probes/README.md` are uncapped and
  dwarf the peer norm for a dev-tooling README (~9–26 KB across the 14 peers that have one; one 385 KB outlier, measured 11-05).
  Both stayed on the 11-05 deletion pass, and for the invariant-1 reason: they are the declared single home of the
  noise band, set size and paired-flip floor. Owner call: extend the cap to tooling READMEs, or record that it
  deliberately does not reach them — the silence is what makes the two numbers unreadable as either normal or not.
- **The pin serves 2 of 3 Qwen generations; Flash-Next is the missing architecture, not a missing config**
  (Engine/, Upstream Pin-1) — measured at the `mlx-swift-lm` checkout `4ab2679`: `qwen3_8*` is registered
  (`LLMModelFactory.swift:73-75`), so Qwen3.8-27B loads today with its companion drafter
  `mlx-community/Qwen3.8-27B-MTP-4bit` (`MTPDrafterModelFactory.swift:41`) — the only gap is weights never
  fetched on this host (owner action); 3.6-35B-A3B already serves with a native MTP head (its config
  `mtp_num_hidden_layers: 1`; `Qwen35TextMTPRegistration.swift:26` keyed on `qwen3_5_moe`; registered at
  `EnginePool.swift:460`). **Flash-Next cannot load**: the checkpoint advertises outer `model_type:
  qwen4_exp` (live-fetched via hf-mirror — `Qwen4ExpForConditionalGeneration`, `indexer_budget`,
  `ple_layer_ids`) and `qwen4` appears nowhere in the pin tree; the failure is honest by name
  (`ModelFactoryError.unsupportedModelType`, checkout `ModelFactory.swift:11`). No owner call while upstream
  lacks it — four comparator trees converged on the shape it would have (inherit the 3.5 contract + QSA
  indexer + host-backed PLE + native MTP head; cites in `comparator-innovation.md` § *Diffusion observed*
  case 7), and that paragraph doubles as the Pin-1 bump audit's acceptance checklist. The rejected shortcut
  is filed because it is cheap: aliasing `qwen4_exp` onto `Qwen35Configuration` would silently drop the
  `indexer_*/ple_*` weights and answer anyway — the surface claiming more than the engine delivered
  (invariant 2).
- **The MTP branch's decomposition is frozen; its gate is one fetch away** (Engine/) — step 4 of the
  decomposition whose steps 2-3/5 landed. A 750-line read (11-13) says the branch is not move-only: it
  nils and writes back the outer `chatSession`/`pooledSession` across the pool handoff, and its two early
  returns skip the tail's seven-variable writeback, so an honest move needs an outcome-struct and a
  pool-slot contract, beyond the compiler-verified move-only recipe the other cuts used. The deeper
  blocker is the gate: the lane's honest proof is a live drafter verifying on this host, and the weights
  were never here. The pin row above names the way out exactly — the pin tree registers `qwen3_8*`, so
  fetching `mlx-community/Qwen3.8-27B-MTP-4bit` + Qwen3.8-27B (owner action) gives the lane its first
  live gate, after which the branch moves the way the guided lane did. Until then it stays nested: a big
  move that cannot run its own gate is a claim, not a fix (invariant 1).
