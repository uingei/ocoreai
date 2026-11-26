# Open. Measured, unresolved

The long form of § Open in `AGENTS.md`, which owes only the address. Nothing here is a capability claim:
where a number is unmeasured it says so, and where a fix is blocked by the host or by upstream it names
which. A resolution goes to `docs/agent/closed-items-log.md`; a decision becomes a rule in `AGENTS.md` or
the area guide, with its gate. Per-item evidence is in `CHANGELOG.md` (grep the symbol).

- **The ACP face ships what it proves; the model picker landed 11-26, two debts and one witness remain**
  (ACP/, long-horizon-goal rung 7). Shipped 11-24 (`65d8285e`), made v1-conformant 11-25 (request-shaped
  permission, negotiated `initialize`, no un-advertised notices), made durable the same day, against the
  open row's own convicted premise ("load/resume/list is mechanical against `SessionManager`" — the direct
  lane persisted nothing, so there was nothing to load): an answered turn lands in `SessionCompressor`
  before the response goes out, and `session/list` + `session/load` reopen a conversation the editor lost
  (`85f8952c`..`7f0a1893`, plus `2d0c5375`: `bindWorkspace` stamped nanoseconds into a microsecond
  `updated_at`, and rows so stamped pinned every `ORDER BY updated_at DESC`). `loadSession:true` and
  `sessionCapabilities.list` are promises kept, each gate red-sampled against the pre-fix shape; a refused
  or unknown `session/load` no longer moves the process-wide workspace anchor (`1f201c0c`, self-convicted
  from full-suite reds). 11-26 closed the model-choice debt: `session/new` and `session/load` publish one
  v1 `select` option (category `model`) whose list is the union `GET /v1/models` publishes — disk-ready ∪
  resident ∪ configured default, minus the embedder — and `session/set_config_option` moves it, answering
  the complete option state and refusing a value off the list, a boolean, an unknown configId or session
  by name. That round's own red find: one client key spans one row **per model** (`resolveSession`'s
  keying), so the pre-fix load replayed only the newest shard and silently deleted everything before a
  model switch (`199b0df6`, red-sampled: the split test saw only `["switch","on the second model"]`).
  Gated by probe 62 (43 live assertions, scripted lane) and `ACP*Tests` (28 across 9 suites; the config
  suites inject their option list so no host disk enters an assertion). What remains: caller-supplied MCP
  servers (await the MCP child confinement ruling below); `tool_call_update status:"completed"` on a live
  turn only once real dispatch runs inside the ACP turn (replay already closes stored calls by their
  `resultFailed` bit). The turn-side delivery of a chosen id rides the existing `DirectInferenceClient`
  seam the GUI shares — no ACP-side gate re-proves it. `session/resume` stays refused by design: a stdio
  agent's live session cannot outlive the connection, and `load` is the honest re-open. The one thing no
  probe can fake is a real editor driving a real turn. The registry listing stays unreachable by the
  registry's own three-OS + authMethod rules (read 11-24) and is not on anyone's queue.


- **The LSP diagnostics slice is ruled and unfunded; the loop still pays a whole build per edit** (Tools/,
  Engine/). Ruled 11-25, the day design authority moved into this thread: consume `sourcekit-lsp` (the host
  carries it, `xcrun --find sourcekit-lsp` → the Xcode toolchain binary, measured) and expose **one**
  agent-facing diagnostics op behind an opt-in flag. The DAP lane is refused, not deferred: nothing in the
  loop debugs, so it would be a surface with no consumer. Premise measured 11-25: word-boundary grep for
  `lsp`/`sourcekit` in `Sources/ocoreai/Tools/` returns 0 hits, and the case-insensitive sweep's 6 hits are
  `lSp` substrings, so that scan only means anything with `-w` (the lesson consensus § What the corpus did
  not know, bullet 5 already carries). Spend gate: one board arm against the two resident arms
  (`scripts/eval/`), because `ToolSurfaceReachability` is this repo's precedent for machinery that stayed
  dark for want of a priced arm. Evidence home: `references-problem-map.md` § Field-solved here 2 and
  § What this map changes.


- **The full-run reds in the MCP/steer/admission suites do not reproduce filtered; mechanism unproven**
  (Tests/, MCP/). Two full runs on this host lost issues in `MCPStderrDiagnosisTests`,
  `EngineBusyAdmission`, `SleepSteerWake` and `CountTokensEndpoint`; one filtered run over the six
  suites 11-24 passed 53/53, with the suite whose budget is 2.0 s finishing in 2.02 s. This row first
  claimed a fixed-port 8777 collision from a `FATAL: address already in use` log line and was convicted
  the same day: that line is the fixture's planted complaint inside `MCPStderrDiagnosisTests`' python
  heredoc and prints on green runs (an instrument's output read as a bind failure). What survives:
  timing-budget sensitivity under the parallel full run. Owner call: a serial lane or a raised budget
  for those suites, and only after a red-sampled reproduction — an unproven flake is not a gate, and
  raising a budget without one is hiding a claim.


- **The nameless `tool_reference` still exits by silent drop; the availability claim closed 11-26**
  (Models/). The billed-but-invisible defect (`111c120f` shipped the instrument, its nonce-isolated WHOLE
  arms landed 905/908/905) closed 11-11: references render as naming text at the ONE accessor the guard and
  the prompt share (`AnthropicToolResultContent/text`), live 15/15 on probe 07 §2c with the name echoed like
  the TEXT control; the closed-log row carries the numbers and the splash precedent. 11-26 closed the face
  that row had named unmeasured: `Available tool:` renders only for a name the request's `tools[]` declares
  (`AnthropicMessageRequest.declaredToolNames` threaded through both readers — one reference, one
  availability answer), every other reference names itself `Tool reference: <name>` without the claim.
  sglang's refuse-by-name is a REQUEST exit and history never requests (ruled 11-26); vllm and sglang's
  carry-the-name cites stay at the `07 §2c` header. Gates: `AnthropicBlockHonestyTests` (the
  declared/undeclared/mixed arms, the guard↔prompt agreement test, and the wiring test through
  `toChatCompletionRequest` — if the set ever stops being threaded, the declared arm drops to the neutral
  wording and that goes red). What stays open is an exit chosen without a decision: a reference with no
  `tool_name` contributes nothing (the `toolName` guard in `AnthropicToolResultContent/text`). Strata's
  documented drop (a gone MCP server must not fail the session,
  `../references/Strata/serve/frontend.py:664-673`) is the shipped shape, but nothing ruled it. Owner call:
  keep the drop or refuse by name.
- **Sessions carry a TTL promise nobody enforces** (SQLite/, Scheduler/). Every `INSERT INTO sessions`
  writes `ttl_days` (default 180, configurable: `SessionCompressor.swift:114,120,72`; read back at
  `:1073`), and no code enforces it: the enforcer `purgeExpired()` had **zero callers** repo-wide
  (measured 11-09; it, its DTO `ExpiryTask` and the never-read helper `SessionModel.expired` were deleted
  same-round. The sweep that removed the genuinely-dead `MCPCallCache.purgeExpired` uncollided the name
  and `unreferenced_decls_ours` went 0→1, which is the claim catching what three files hiding one name had
  masked). Expired sessions accumulate
  forever. The promise itself (column + config) stays; deleting the never-run enforcer deleted no
  behaviour. Revival is cheap. The TTL SQL is in `git log -S purgeExpired`; the wiring call is
  destructive (it DELETEs messages and sessions) and needs the owner's route: sweep on a tick (which
  seam), on boot, or retire `ttl_days` from schema and config (also a promise change). Until then every
  "retention" claim about sessions reads as unenforced.

- **A tool result billed 5 tokens on the default checkpoint. Closed 11-16; three residuals beside it** (Engine/),
  convicted and fixed: the std-reasoning lane (the unconstrained no-tools route) snapshots history
  as `(role, content)` pairs and rebuilds `Chat.Message(role:content:)`, erasing `tool_calls` and
  the result pairing before the template. Whose main loop skips `role:"tool"`. Ever sees them.
  Discriminator: declaring `tools[]` billed the full block; an assistant with `tool_calls` on the
  no-tools route billed zero. Two sites: `mayRunReasoning` now refuses tool-metadata history (the
  media precedent. Refuse the flat lane), and the DTO conversion keeps the assistant's content
  beside its calls. Probe 57 promoted, green: three faces +2 307, control +2 488. The dig also
  convicted a shipped pool belief. A filled tool/media turn returned to the pool behind an empty
  ledger on the word that "ChatSession reconciles it against its own transcript"; it APPENDS, so
  the next `anon:`-key conversation inherited the old KV (measured 3 092 vs a true 736). The
  release site now discards a turn that cannot account for its own KV; probe 57 arm 5 pins it
  (+15). Residuals: (a) guided-gen flattens history the same way. Same class, unquoted, so
  named-not-guarded; (b) the MTP loop still never re-appends its own assistant tool-call turn;
  (c) a tool loop pays cold prefills from turn two, bought against warm-and-wrong (the append is
  measured; the duplicate-loop shape is inference). (b) closed 11-17: the MTP tool loop now enters the
  calling assistant turn before any result (upstream `ChatSession.swift:1959` shape), the boundary
  records an unpaired history loudly, and `MTPToolLoopHistoryTests` gates the pair (incl. the exact
  pre-fix orphan shape); the live arm on a serve with a drafter checkpoint stays the escalation tier,
  this host serves the owner's session and loading a 12B+ mtp checkpoint would contend with it.
  Gate: probe 57, five real arms, plus `MTPToolLoopHistoryTests`.
- **Durability is priced twice, and the second price indicts the mechanism, not the message** (Tools/, eval/),
  the pre-write gate (refuses valid→broken syntax, keeps old bytes: **110/110 corruptions stopped, zero silent
  damage**) cost the frozen set **2.17 tasks/52 (p=0.0146)** at bare reason, and still **1.83 (p=0.0266)** with the
  field's best payload. Stated line (codex `lib.rs:353`), the caller's own failing bytes quoted verbatim
  (openclaw `edit-diff.ts` shape), the recovery-proven ordered retry. **Pooled b=35 c=11, p=0.00054**. At this
  checkpoint repair is rewrite-through-broken-states and the refusal, whatever it says, removes the stepping stone;
  this is also why no comparator tree gates writes (11-09 survey). Owner's remaining question, sharpened: pay the
  ~2-task fixed price for zero-corruption anyway (a stranger's script survives), re-measure the same patch on a
  larger checkpoint where repair-by-rewrite may not be load-bearing, or close the trade. Patches + both verdicts +
  the 15-test suite: `scripts/eval/proposals/syntax-regression-gate{,-v2}.patch|.md`; ledgers `20261108-230722`,
  `20261109-001350`.
- **The loop can now price a build; the base it trusts is still the operator's** (scripts/eval/),
  `HYPOTHESIS_AXIS = ("binary",)` is granted only when both arms state the same commit (gates: `_autoab_selftest.py`
  scenario 14, 18/18 mutations), so a base root written before 11-09 is refused, not trusted; the loop still takes
  its base from `OCOREAI_AUTOAB_BASE` rather than measuring one per invocation. Self-baselining costs +k board
  runs per loop and is the owner's call. `edit-noop-split-strip`'s McNemar row (`20261109-213417` refused on the
  old rule) is next round's claim, not this one's. Verify's next rung is harness-side. Owner's
  call (touches the approval promise); three 11-14/15 adjudications pinned the prompt side (`autoloop.tsv`).
- **The frozen board cannot seed a CRLF file, so no byte-fidelity class is priceable there**
  (scripts/eval/), `grep -c '\\r'` is 0 across `tasks.json` (45) and `tasks-edit-repair.json` (52), so
  `edit_file`'s line-ending rung (`FileTools.Endings`, 11-10) has no task that can move: a
  strip-proposal would return "inside noise" because the instrument is blind, not because the change is
  free. Seeding a CRLF fixture means editing a path `autoloop-protected.txt` names a human act, so the
  call is the owner's. Gate meanwhile, and byte-exact: `LineEndingFidelityTests`.
- **A `response_format` turn cannot ground itself; the limit is disclosed, the fix is a call** (Engine/, Handlers/),
  with `tools[]` declared beside `response_format` the answer grammar wins (`OpenAIModels.swift` "the JSON wins",
  four orderings measured there) and the turn cannot emit a tool call first, so it fabricates instead of reading
  (board structured tasks, both arms 11-08, deterministic at temp 0, 3/45 tasks priced). The disclosure shipped
  same day: tier row `structured_output` + probe 54 pins disclosure↔behaviour; sglang treats the pair the same
  (`serving_chat.py:1130`), so staying is defensible. The fix shape is a per-iteration grammar: tool grammar while
  the loop runs, the caller's schema only on the final turn. Engine surgery, and it would DIVERGE from sglang
  while matching the OpenAI spec's final-message semantics. Owner call: stay disclosed or build the final-turn
  constraint.
- **A stall stops MTP hard, the std lane only by consent** (Tools/, Engine/). The ladder and
  `LoopStallTerminationTests` landed; upstream `mlx-swift-lm`'s `restart:` loop (ChatSession.swift:1164) still has no
  cap, and a std-lane hard stop throws out of `toolDispatch` (:1632) reaching the wire as an error, not a
  finished turn. The terminal word for four faces is the owner call; field constraints mined
  11-03: `CHANGELOG` 11-03(1).
- **CoreAI / macOS 27 items unverifiable on this host** (Engine/). Three `@available(macOS 27.0, *)` or
  SDK-gated sites (detail: `docs/agent/build-gate-reality.md`) ⇒ no blind fix and no claim of one; their
  suites now skip on this OS through `PlatformPremise.hasMacOS27` instead of reporting a red.
- **The coreai fork's debt is named open verdicts, not a drift window** (Engine/). The drift window is
  now closed: the full `0bfb548..ca2aecf` (+46) read (§ Window read 11-23 (b) of
  `docs/agent/coreai-fork-window-log.md`) ported three live bugs (#537 sampler cache, #533 gate/span
  leak, #522 grammar-session key + padded mask, plus #524's +inf half), stamped every mirror whose
  window was adjudicated, and adopted the axis. `make drift` reports `coreai-models 0 new`. What
  remains is the verdict debt, one row each with its action in that log: #412's GPU-error stop and
  #490's repetition-penalty carry-in (ports landed 11-12, runtime pending the macOS 27 window), #368's
  whitespace damping (CoreAI-only, unverifiable here), and three names this read surfaced:
  1. **#294 additive penalties are on the wire but off the engine**, `/v1` accepts
     `frequency_penalty`/`presence_penalty`, the CoreAI pipelined GPU sampler never compiled them
     (upstream's additive stage is the missing piece) and the CPU fallback applies neither; the MLX
     lane honors them. Invariant 2 exposure. The wire promises, the engine silently drops. Waiting
     the same host.
  2. **#530 bundle-declared `eos_token_ids`** (Gemma 4's `<|tool_response|>` = 50). The CoreAI lane
     reads no bundle stop-ids (0 hits in `Sources/`); stop semantics ride the wire `stop` field alone.
  3. **#509's `maxConsecutiveUnknownIds`**. Their decoder trips when sampling repeatedly lands in a
     padded vocabulary; our decoder has no such guard, so a stuck sampler runs silently to maxTokens.
  The ledger's other face, re-measured after the adopt: of 57 candidates **15** remain no-baseline
  (was 25). Files this window never touched, whose full absorption history stays unverified rather
  than stamped into a false green; `Handlers/DecisionsHandler.swift` is honestly one of them (an MIT
  in-tree file whose only sha is another mirror's cite). One of them is a rename blind spot, because
  upstream `Samplers/CompositeSampler.swift` became `ReferenceSampler.swift` (#545) and the ledger
  maps by the cited path, so our CPU-sampler copy tracks a dead path. The manual instrument is in
  the window log. `make drift` prints both counts every round.
- **The mlx-swift-lm window (+9 at 11-23; the `+6` below is the 11-05 reading) hands us a truth we
  cannot read until the bump** (Engine/). Read 11-05 in
  a local clone at `c8dabc6`: `GenerateCompletionInfo` gains `speculativeDecodingFallbackReason`
  (`Evaluate.swift:3083`) naming the five reasons a session with speculation configured ran plain
  generation. We already consume that struct's siblings (`passthroughReason`,
  `speculativeDecodingTelemetry` → `EngineEvents.swift:88`), so the traditional-SDC lane's silent fallback
  is the one face still unnamed. Same window: #747's `RotatingKVCache` mask fix is **inert here** while
  `keep == 0`, which is every path we reach, `makeKVCacheConfiguration` (`MLXBridge.swift:896`) passes
  `strategy` + `rewind` only, and `Capacity.init` is the sole route to `keep > 0`, defaulting to 4, so
  setting a capacity silently pins 4 tokens. Upstream `mlx-swift-lm`'s `restart:` tool loop is still
  uncapped (`ChatSession.swift:1226`), so the stall item above keeps its premise. Instrument: `make drift` prints
  the axis; the markers for the files #581 touched live in `docs/agent/engine-line-cites.md` (the anchor gate retired 11-16), 13 per
  `api.github.com` pulls/581, of which our cites reach two: 27 markers into `ChatSession.swift`, 9 into
  `Evaluate.swift` (re-grepped 11-06; re-grep before repeating).
  Premise flipped 11-06, the same day it was written: Metal is restored (that day's `toolchain-check` →
  `metal=ok-probed`), and git-over-https. Read dead (curl 28/HTTP2 framing) earlier the same day. Answered
  again that evening (`git ls-remote --heads https://github.com/ml-explore/mlx-swift-lm` exit 0, refs listed).
  A flapping host premise, so re-test that one line before the hand; nothing was re-resolved blind. Owner call
  unchanged: the bump is a hand, not a gate.

  **The header's "+9 at 11-23" is a stale count, convicted 11-26 against the instrument.** `make drift` now
  reads `mlx-swift-lm HEAD=6759555f2 +9 vs base=bf5a5d438` (mirror `~/references/mlx-swift-lm` is AT
  `6759555f2`, 11-19; `git merge-base --is-ancestor` says the pin is 9 behind main), and that live +9 is a
  *different* set than the one this row read 11-23 — re-enumerated `pin..HEAD` oldest→newest:
  `#733 7517abc, #800/#803 5a14024, #802 ca661dc, #772 cb59e9a, #812 4c21c84, #809 5a4418c, #716 4daac23,
  #817 f764e2b, #813 6759555` (11-17→11-19), **none of them an ancestor of the pin** (all pending). #747
  (`2775ddd`) IS an ancestor of `bf5a5d438`, so this row's "#747 inert here at keep==0" stays true — it is
  consumed, just inert; the stale number was the header, not that finding. Two of the live +9 are ours-shaped,
  both read at the mirror this round, both **consume-at-bump** (owner push window, § Upstream 1), not local
  defects: **#733** adds optional `logitSampler:`/`logitProcessor:` to `GuidedGenerationLoop.run` (nil keeps
  greedy; a sampler picking a grammar-excluded token throws) — the guided-gen primitive the "thinking is
  uncounted on the tools lane" row and the per-iteration-grammar shape would ride, once the pin carries it;
  **#812** first half fixes the Qwen XML `<parameter>` scan — a value left unclosed is now ended by the next
  line-initial `<parameter=` (Qwen's own reference-parser shape; the shipped bug swallowed every later
  parameter into the first argument and replayed four times in a live multi-turn run), second half reclassifies
  a well-formed call to an undeclared tool from `malformedSyntax` to `undeclaredTool` **naming it** — the same
  refuse-by-name shape our `settings.toolsSurface.enforce` row wants, so the undeclared-tool face should read
  this parser's behavior at the bump, not re-derive it.
- **A no-tool turn steers and stops, both halves flag-staged** (Engine/). Upstream #608/#798 at the
  `bf5a5d438` pin owns mid-turn input: `steer(_:policy:)` ends a step at the next safe point *inside a
  thought* (upstream-app measured 0.22-0.30 s steer-to-new-text vs 6.9-8.1 s pre-#798), and
  `interrupt(response:)` ends a response there with the reply recorded, no rollback,
  `GenerateStopReason.interrupted`. Both halves reached the std `ChatSession` lane behind one opt-in
  (`InferenceOptions.midTurnSteer`): steers submit at any generation boundary (11-18), and a user stop
  calls `interrupt()` from the consuming loop and drains to the stream's normal end (11-20), so the
  retain-vs-rollback split landed as **retain**. The pooled release books a turn whose KV matches the
  transcript upstream recorded, where consumer-cancel had rolled the transcript back under a pool
  history the release had already extended (shape read of both sites, not a live number). Still open,
  none of it decision: the flip-to-default is the owner's (paired board verdict + probe 21 `chat`-arm
  green, loser deleted whole. The 11-11 adopt ruling); the wire lane has no `midTurnSteer` caller
  (GUI only today); the queued-input guard (codex's second tier) stays ours to design; and the lanes
  that bypass `ChatSession` (MTP, the flat token route) keep consumer-cancel's rollback. Their
  `.interrupted` arms are permanent shape, not unwired. The stall row's terminal word stays the owner's.
- **Thinking is uncounted on the tools lane** (Engine/). Probe 44 §2: 550 chars, no
  `reasoning_tokens`. Upstream counts only via the processor that also bounds the thought, and a
  bound there starves the tool call (§2b: 200→500 at 64 tokens). A count-only processor waits
  upstream. Owner call. Datum 11-07 (the wedge's own task prices it): of 4 §2 runs on the shipping
  tree at Qwen3.6-35B, **1 died `finish=length` mid-work**. First-person narration ate the harness's
  900 tokens after 4 executed `exec_command` calls, and 3 passed (`finish=stop`); the pre-bump
  v0.1.14 artefact went red on its own k=1 with a different mechanism, so the flip is at the budget
  boundary and predates the +13 window, not a regression from it. The pass rate is unmeasured; the
  flip is. Sample lines: CHANGELOG 11-07 (wedge re-check). Datum 11-04: the model family ships a wire word for this cost,
  `preserve_thinking` retains "reasoning context from historical messages"
  (`../references/Qwen3.8/README.md:25`), so a caller that retains thinking pays tokens we cannot price
  for it (inference from a README, not a measured interaction).
- **Pin 1's window is taken, so the two ours-shaped commits are now unconsumed, not pending** (Engine/),
  `mlx-swift-lm` bump 11-07 `b8d4935ab → 4ab267996` (+13) carried #581 (resumable MTP *inside* `ChatSession`), #608
  (mid-turn steering) and #747 (`RotatingKVCache` pinned prefix in multi-token masks). All three compile in
  and change **nothing** until consumed: our MTP lane still drives its own token loop and `SteerQueue` still
  drains at the tool-result tail, so the MTP row, the stall row and the interrupt row above all wait on one
  decision. *adopt what upstream's `ChatSession` loop now owns, or keep maintaining the local lane beside
  it*. **ruled adopt-then-retire 11-11**, staged through the interrupt row's flag; what remains is
  execution (the owner's push window per § Upstream 1), not decision.
  The MTP half still deserves the acceptance row's read: a *resumable* drafter changes what that gate
  would measure. The window moved again 11-10 (+2 → `ec4c966`) and both commits were adjudicated the same
  round, and the same evening convicted half of that reading: `#774` (logprobs during speculative decoding)
  does stay unconsumed. Our lane never requests them, but `#724` (greedy MTP verify batched to one GPU
  readback) lands **on a consumed path**: the MTP branch of `EngineInference.swift` calls upstream
  `generate(mtpDrafter:)` (checkout `Evaluate.swift:2627`), whose verify loop IS the
  `MTPSpeculativeTokenIterator` #724 rewrote. "drives its own token loop" meant the tool-loop wrapper, not
  the verify. The window later moved to +8 (api.github-authoritative HEAD `635290754`), its tail (+6)
  judged 11-13. The four new public symbols (`PythonLiteralParser`/`ModelTypeRegistry`/
  `EmbeddingGemma2`/`MLXLogger`) have zero consumers under `Sources/`, the two `Evaluate.swift` commits
  touch no line of the `generate()` signature, `#711` changes only the load side of the Qwen3.5-family
  targets (helpful side), and 11-13 **took the bump**: pin `635290754`, both lockfiles paired, notices
  regenerated, its 24 shifted upstream anchors repointed; #724's verify speedup (e2e
  27.7→28.5 tok/s Qwen3.5-4B-4bit block-2, M2) is consumed by this. Resolve never used raw https: the
  project-local mirror (gitignored `.swiftpm/configuration/mirrors.json` → `~/references/mlx-swift-lm`)
  is this host's resolve path and stays out of `Package.resolved` (canonical location + full sha
  recorded). The host's raw github-https did break 11-13. It reaches consumers like docs-check's
  `tags_published` claim (honest host-red, runners unaffected); `test-ci` stays the CI-tier
  authority (owner's push window). #724 simultaneously weighs the adopt-vs-keep call: upstream's loop is not just owning more, it is owning more
  *faster*. coreai-models' +3 window judged
  same round too: an RNG file-move (our `Video/RandomSource`/`TorchRandomSource`/`SeededRandomNumberGenerator`
  mirrors' come-from relabels to `CoreAIShared/RNG` at next re-read), a python packaging chore, and a
  python export-side RoPE precision fix. None touches a consumed surface. Third axis clean:
  `mlx-swift tag=0.33.0 pin=0.33.0`. (Instrument note this row carried. One
  verdict, exit **10** then **2**. Closed: `closed-items-log.md`.)
- **MTP acceptance is threaded and unused as a signal; its sounding suites are deleted** (Engine/, Tests/),
  found by reading, not by a scan. ① The counters are real: `proposedDraftTokens`/`acceptedDraftTokens`
  (`EngineEvents.swift:105`) are threaded at `EngineInference.swift:3432`, `:4229` and read by
  `ChatViewModel.swift:1189`. ② Resolved 11-11: `b1cfb64`'s two "behavioral" suites (14+13), which
  *sounded* like this gate, were independently re-read and deleted. Every assertion judged its own
  literals, none called production; the closed-log row carries that proof plus the real guided-gen gates
  that stand. The threading's one emit + one read landed 11-19 weight-free: the script may declare
  `proposedDraftTokens`/`acceptedDraftTokens`/`passthroughReason` and `ScriptedInference.stream()`
  rides them as-is into the same three `.done` slots the real engine fills and `DirectInferenceClient`
  destructures; `ScriptedEngineTests` pins both boundaries (declared arrives verbatim, undeclared
  stays nil. A script that names no drafter owns no acceptance). Measured, still ungated: the REAL
  engine's fill of those slots (it needs the live drafter named below); what stays open is lane policy
  on acceptance, which the ruling keeps with the loop-flag flip.
  ③ The field spends that same counter as lane *policy*, not a published number: `mlx-serve` stops speculation
  mid-decode once per-draft acceptance falls under break-even and stays off for the request
  (`../references/mlx-serve/docs/performance.md:20`, re-read at site 11-26 — the gate is there, sticky per
  request, plus a prompt-time repetition gate ahead of it). `MTPLX`, the tree our own lane is measured
  against, was carried here as "32 d quiet, no new drafter behaviour pending" — **the quiet-month is dead;
  it came from a stale window count, not from the tree** (this file's own registry row read the live product
  on 11-20). Re-measured 11-26 at `b16e30ee` (11-24): 490 commits/30 d, tags `v2.12.3`→`v2.13.3`, the 2.13.x
  run 11-22→11-24, and the releases are MTP-lane movement: `2.13.2` makes three draft proposals the
  Inkling-2-Mini default depth, `2.12.3` resumes a saved prompt after the last committed token and answers an
  uncovered restore by name (`no_snapshot_coverage`), and the tree ships a **demotion ledger**
  (`mtplx/demotions.py`, "Nothing goes slow in silence": every exit from the lane the engine was built to run
  records a count and one plain line, read by `/health`, the request log and `doctor --explain`). What was
  NOT read today: whether its lane stops speculation on per-draft acceptance — the three-proposal default is
  a depth choice read off a release note, not a cutoff. **Ruled 11-11:** the 27 are
  deleted (②); whether the lane acts on acceptance *at all* rides the loop-flag flip. Lane policy written
  for a loop being retired pays twice, and the scripted engine makes the real gate one emit and one read
  on the surviving seam, not a new surface. Why no scan owns this: two attempts on 11-04 failed in opposite directions (one flagged 233 tests,
  the other zero) because `extension String` in `Sources` makes a plain `String?` annotation look like a
  production reach, only reading, or a mutation that must go red, decides it.
- **Rewind is landed; the reserve is visible and overridable, still untuned** (Engine/), 1024 rows measured on
  one checkpoint, not tuned to model or memory pressure, so an edit further back than the reserve still pays its
  full prefix. Since 11-11 the number is not hidden: the kv-cache endpoint publishes `rewindReserve` with its
  `basis`, and `OCOREAI_KV_REWIND_RESERVE_TOKENS` overrides once at boot (0=off; a negative or unparseable value
  keeps the default and says so on the wire). Tuning can now be priced against a number the operator can set.
  `SessionRewindOnDivergenceTests` + `KVCacheRewindReserveTests` + probe 27 hold the wiring and the number.
- **Reasoning-lane traffic is priced, still not warm** (Engine/). The no-tools lane pays its own
  turn into `KVCachePriceLedger` (never the never-fed session); residency honestly stays
  `not_observed`. Probe 35 §2-3. The owner's pooling call covers the rest: the lane frees its
  cache, so no-tools traffic cold-prefills every turn (probe 19 red) and writes none of the
  pooled branch's per-turn lines. Probe 31's `StdTurn` control and probe 32's `promptHash`
  read exactly those. Probe 29 is green since 11-14: its two reds were the instrument's own
  blindness (header read off the wrong response, a busy turn that was a token budget not physical
  work), not the wire. guided/MTP lanes log `not priced`, not a price.
- **The video record still trusts the processor consumed the frames** (Multimodal/). The 11-07 over-report
  is closed at its root (media turns had been routed onto the std-reasoning lane, whose `(role, content)`
  rebuild drops `Chat.Message.media`; probes 08/17 flipped green with the routing fix). Residual: the rule
  itself. Decodable parts in a completed turn, not tokens received. Can still over-publish on a
  checkpoint whose `processor_class` ignores `input.videos`; the color-naming gate covers only the probe
  checkpoints (next row; `VideoDeliveryLedger`).
- **Video publishing is per-checkpoint** (Multimodal/). One processor reads `input.videos`, the other does
  not, so it is never inferred from architecture; a turn that got frames but never answered is not
  counted; relaxing that is untested (`VideoDeliveryLedger`).
- **Screen capture cannot start a stream headlessly** (Multimodal/). Authorized, display attached, still
  "cannot start stream", while the camera on the same box delivers: an SCStream-in-no-GUI-session limit,
  not TCC. `screenStatus` is `ready` only after a delivered frame.
- **GUI e2e proves the window, not the driving**. The completion leg stays the escalation tier's:
  the field ships model-backed agent gates on self-hosted silicon only (Rapid-MLX's `agent-gate.yml`).
  Accessibility control unverified. Scope: `UI/AGENTS.md` § GUI end-to-end.
- **Prefix questions ruled by the field's shipped shape**. Sglang keys identity in, so a cross-
  conversation share misses, never collides (`hicache_key_scheme.py:34`), and no serving tree refuses
  a changed instruction. Vllm logs and degrades to a standard completion (`message_assembly.py:99`).

- **A turn's tool surface costs 19 points; one knob is gated, the surface is not.** Measured on
  `gemma-4-e2b-it-4bit`: 6 tools against all 40 ⇒ **−18.8 pp, McNemar exact p < 0.0001**. Read it as *what a
  turn is handed*, not "fewer tools everywhere" (two exec faces improved full-surface, every edit/fix face
  collapsed); per-arm rows, the noise floor and the recipe: `scripts/eval/README.md` § the repeat recipe. The
  open half is a product call: the wire is caller-scoped (`Tools/ToolRegistry.swift:135`, no `tools[]`
  declared ⇒ no tools), while the app hands the whole registry over every turn
  (`UI/ViewModels/ChatViewModel.swift` `toToolDefs()`: 40 declarations, 25,092 B, to a 4-bit checkpoint); no comparator
  does that (cites: `comparator-repos.md`). Wiring read 11-19: `ToolSurfaceCuration.apply` has one caller, the GUI view
  model, and the board drives the wire lane (`GET /v1/tools`), never `SettingsStore`. A paired board verdict on the
  flag is structurally unreachable, so the flip waits on the owner accepting the wire-lane arms (same checkpoint, same
  six names) as evidence, or on the GUI-driving harness the repo does not have (§ "GUI e2e proves the window, not the
  driving"). The field's answer, read 11-04, is not a smarter shortlist but a
  surface that is **reachable rather than resident**, and three trees reached for it independently. That next
  unit landed 11-25 behind `settings.toolSurface.reachable.enabled` (default OFF): `tool_search` registers at
  boot only while the flag was on (the `update_plan` route), `ToolSurfaceDiscovery` keys the discovered set by
  the dispatch's conversation key (GUI: `inferenceSessionId`; ACP: its session id), and both registry-building
  seams compose core ∪ search ∪ discovered through `ToolSurfaceCuration.apply(reachable:discovered:)`, so a
  hit declares itself on the next turn; an off build differs by exactly the absent tool name
  (`ToolSearchWiringTests`, incl. the scan of one flag seat per lane). The rank's byte-determinism promise was
  funded the same day: its query dedup iterated a per-instance-salted `Set`, so scores drifted in the last
  bits between identical calls (the committed equality assertion read 3/5 red); dedup now runs in
  first-occurrence order. What the flag still does not do: inject the deferred tools' `compactListing` into
  any prompt (that text is an agent-facing behaviour verdict the board arm owns), and the default stays off
  until that arm prices it. Three trees reached for it independently: hermes
  ships 142 skills in `optional-skills/` that "are not copied to `~/.hermes/skills/` during setup" and are
  installed by a `hermes skills install` verb
  (`../references/hermes-agent/optional-skills/DESCRIPTION.md`; row: `comparator-repos.md`),
  goose's emulator asks for one schema at a time (`tool_emulation.rs:62`), `pi` ranks deferred tools with BM25
  and keeps them offered across compaction. Three trees, one shape, which changes the owner question from
  "what shortlist" to "what is installed, and who pays for the fetch". Wants a per-turn shortlist (whose
  score, who pays a wrong pick) plus the composer half. **Fetch cost, measured 11-24 against a live
  `GET /v1/tools`** (the 25 092 B figure above is the rendered GUI surface; the wire document is 24 130 B):
  40 declarations = 23 997 B, the measured 6-tool arm = 4 302 B, the 34 deferred tools as
  `name: description` = 9 060 B; all 40 compacted that way would be 10 380 B, 43.3 % of full (the shape
  read at goose's `tool_parsing.rs:4`). The
  pure half of the mechanism landed 11-24 dark: `ToolSurfaceReachability` (tokenizer, BM25 rank with a
  name-ascending tie-break, `residentSurface` = core ∪ discovered, `compactListing`) with
  `ToolSurfaceReachabilityTests` (8, exact ranks) — landed with zero call sites, so it changed no turn;
  the `tool_search` entry, its opt-in flag and the per-session discovered set joined them 11-25 (status
  above), and the default stays off until a board arm prices it against the two resident arms. The wiring decision was
  measured, not picked: 11-24 against a live scripted-lane serve, a call for a name the request never
  declared still comes back on the wire (the lane hands calls to the caller, so declaration is the
  contract there), and on a native lane a real model cannot emit what its template never carried. So a
  hit must become a **declaration** on the next turn (pi's load), and because `ToolEntry.handler` takes
  only its argument string, the discovered set belongs to the lane that builds the defs (GUI:
  `inferenceSessionId`; ACP: its own session id), not to the tool. The pattern to extend is the knob already gated: render the checkpoint's template
  with a sentinel at load, record it (`ReasoningEffortLedger`), publish on `/v1/models`, refuse a demanded
  word 400 naming the knob and both exits. Codex's `code_mode_warning.rs:6-24` shape, fail-open pinned.
  `ReasoningEffortHonestyTests` + probe 38. Refusal half built 11-21 behind `settings.toolsSurface.enforce`
  (default OFF), asked from all three declaring lanes (both `/v1/chat/completions` routes and `/v1/messages`,
  the face whose turns feed the same ledger) at one home: a declaring request against a model this server
  measured `prose_only` gets the 400 naming both exits; the flag flip and the shortlist question above stay
  the owner's (`ToolSurfaceHonestyTests`).
- **Weight-free probes exist; only three hold a CI seat, and no checkpoint tier does.** The scripted lane
  holds 37 (wire contract), 38 §1 (a refusal) and 39 §1/§1b (the skill's markers); §2 of 38/39/40 needs
  weights, so on a runner it takes its skip branch.
  Owner call: which tier the scripted lane may run in, and whether a nightly takes the checkpoint tiers.

- **The chain ceiling, now that the drop speaks** (Skills/, docs/). The disclosure half closed
  10-28 (`closed-items-log.md`); the gate that printed `deepest-chain=N/CAP` retired 11-16 and the cap
  now reports itself at runtime, `WorkspaceContext` names every cut. Open: (a) whether injection should be **gated by
  capacity**. Owner call; (b) the disclosure's own **behaviour verdict** (telling a 2B model its
  instructions were cut may itself cost points; the board has not priced that arm); (c) no UI surface
  reports it yet. The next rule written into `Sources/ocoreai/Engine/AGENTS.md` truncates its own tail
  unless something else leaves: settled by a trim, not a raise, with § *Known defect* and the lane map
  as the candidates.
- **The corpus's cost is injection, and the curve is one checkpoint wide.** Four arms, 39 tasks,
  `gemma-4-e2b-it-4bit`, k=3 (all four rows: 10-27(25)): presence is free (absent vs present-but-uninjected,
  p = 0.51), injection is what is paid for (2,442 B: 24.00 → **19.00**, p = 0.0003), and volume beyond that
  is not resolvable at this n. Unanswered, in spending order: does capacity buy context tolerance (needs a
  default-model knob, `EngineConfig.defaultModelId` is hard-defaulted, no `OCOREAI_*` override), and does a
  short per-turn corpus beat a long one on the faces that collapsed? Owner call either way. Gate injection
  by capacity, or move the doc behind the base prompt (`MessageBuilder`). The direction this curve widens
  toward is measured (11-03, the model axis: `comparator-repos.md`. Hybrid-GDN + native-MTP + 256K; the
  prerequisite is an owner download decision, not gate work).

- **The gate layer is frozen; the tag is not.** Measured before cutting: 329 of 1415 commits went to
  docs/CI/gates against `git tag` = empty (the counts and the deleted family: CHANGELOG
  `gate-deletion-10-28`), and `AGENTS.md` § Working here carries the stop rule. What remains open is the
  owner pushing a tag. The only act that makes a surviving gate someone else's problem to run.

- **The release job holds the publish credential while it runs repository code** (CI/),
  `.github/workflows/ci.yml:402` carries `contents: write` and builds inside that job (`:412` the
  MetalToolchain step, `:426` `build-dmg.sh`), so a compromised dependency in the build holds the
  artefact-upload right in the same step. The dry-run half is paid (`package.yml` builds the same DMG under
  `contents: read`); the rest is the split itself: opencode's shape (`../references/opencode/.github/workflows/release-dry-run.yml:4-9`) runs
  build jobs with no secrets and no `id-token` and publishes from a `release` environment over artefacts.
  Deliberately untouched before a first release lands: it is the one path a rehearsal cannot run.
  Owner call (who/what may publish).
- **A caller's one-token `stop` can starve a constrained turn** (Engine/, Handlers/). Naming a stop id
  takes it out of xgrammar's alphabet (`TokenizerInfo.swift`, at the create call), so a `stop` the schema
  needs empties the mask where it was needed and `nextTokenBitmask()` reads empty as finished: truncated
  JSON, no error, CoreAI lane only. Measured at the C layer (11-02(104)), Swift face read not run.
  Owner call: refuse such a `stop` at `ConstrainedDecodingStrategy.createSession`, or say so on the wire.

- **A cold first run is 794 s of download, at hub speed** (packaging/, Config/). Bytes, rate, the paired
  `curl` and the cache-path correction have one home: diary 11-01(97), re-measured by 11-01(101). The
  surviving verdict: the hub path is the limit, so no harness change reaches the 5-min budget with a
  3.58 GB default, and nothing is notarised, so Gatekeeper and the cask stay outside every figure.
  Owner: notarisation + the first-run checkpoint.
- **The request that triggers a load waits out the whole load** (Engine/, Config/, UI/). A waiter is
  released at 120 s with `AppError.modelLoading` while the *owning* request waits out the ~13 min fetch
  (diary 11-01(99), re-measured (101)). Closed since: the measurement crosses the wire (11-02(107),
  `loadProgress` on the one `loading` row, the same keys in the 503; `ModelLoadProgressHonestyTests`,
  `EnginePoolLoadingGateTests`), and the GUI renders a wait with a route instead of "Generation failed"
  (11-03(12), `ChatState.failureFace`, `ChatFailureFaceTests`). Open: a pool-owned load task, so the
  caller that triggered a load gets the same bounded pollable answer as every other caller. Two owner calls
  beside it. The 503 carries no `Retry-After` though both 429 families do (`AppError.response` sets it for
  `engineBusy` and a measured rate-limit wait only), and a poll cadence is policy, not a measurement, so
  none is guessed here; and whether a human caller should be held or refused at all.
- **The Models page now shows every wait; an engine-started one has no Stop yet** (UI/, Engine/). The
  render keys on `ModelWaitFace` ∥ the pool's own `state:"loading"` (`ModelWaitFaceHonestyTests`,
  CHANGELOG 11-05), and only the transfer lane may open/close a progress row, so a waiter's 120 s poll-out can no
  longer evict the live row the wire's `loadProgress` reads. The row's duplicate-fetch premise is closed
  by reading, not measured: `prewarmDefaultModel` holds the pool's `loadingModels` slot (`beginLoad`) and
  both download paths lease `DownloadSemaphore` per repo id, no second 794 s fetch is reachable through
  either seam. Open: the prewarm task has no cancel affordance anywhere, so its ring renders without a
  Stop (honest, but a wait the user can only watch); the pixels half stays unverifiable on this host
  (`screencapture` refused. § UI guide); owner call: a pool-owned cancel route for prewarm.
- **The audit infers a write, it never reads the workspace** (Models/, Tools/). The process-wide
  key closed 11-10: the wire handlers mint a turn key, the engine threads it to the chokepoint, and
  `since(_:turnToken:)` credits only that turn's dispatches (`ClaimVsAuditTurnKeyTests` pins the
  filter, the equality direction, and the wiring scan). What the key does not fake: a shell success
  is still `.unobserved`, an unknown MCP tool still counts as a writer. No lane is left unkeyed:
  the FM proxies forward the key (compile-verified here and on the SDK-27 legs; the runtime half
  waits the macOS-27 window, where `PlatformPremise` springs the suites), and the CoreAI/ANE
  engines hold no `ToolRegistry` reference at all. They never dispatch in-process, nothing to key.
  Wanted: turn-scoped effect off the filesystem (codex, per turn:
  `../references/codex/codex-rs/core/src/turn_diff_tracker.rs:46`).
- **A demanded tool call is reported, not forced** (Engine/, Handlers/). The unmet demand now rides in
  the result at all four sites; the engine still answers `required` with zero tokens, where sglang
  constrains it to a call
  (`../references/sglang/python/sglang/srt/entrypoints/openai/serving_chat.py:1937-1945`); qwen-code's
  exact-id face (`71119c6`, cell in `comparator-repos.md`) is the third.
- **A measured gallery is the one adoption surface we can win outright** (README/, Handlers/). The leaders
  advertise model support as adjectives while `/v1/models` already publishes per-checkpoint measured verdicts
  (`vlm`, `max_model_len`, `toolCallDelivery`, `reasoningEffort`, `videoInput`) and `scripts/eval/` scores a
  task board (count: `_eval.py count`, never re-typed here). The artefact landed 11-19: the README carries a
  gallery section, `scripts/gen-model-gallery.sh` is its refresh command (it copies one `GET /v1/models`
  verbatim and refuses an unmeasured server, so a row the server never measured cannot be written), and
  `ModelGallerySyncTests` gates the committed pair (README block vs `models.json`, cell-for-cell, verdict
  words bound to the ledger sources, placeholder-or-consistent never half, comparator witnessed against
  synthetic drift). Owed: the rows themselves. A refresh run against a server that has measured checkpoints
  (this host has no resident measured set and no server on 8080 as of 11-19), which is an owner act beside
  publishing, since publishing a catalog is promising it stays true.

- **`/v1/embeddings` had no probe seat; its declared fields have one now** (Handlers/, Engine/),
  measured 11-05 against the cached canonical embedder with real weights, on a live server. What is sound:
  1024-dim, l2 norm 1.000183 (the pooler normalizes before its layer norm, so exactly-1 was never the
  promise), `usage.prompt_tokens` are the embedder tokenizer's own counts (3 for "hello world", 1 202
  for a sentence repeated 120 times, and the batch total is their sum), batch `index`es and the summed
  `usage` are exact, and the three refusals
  name themselves (empty array, empty string, token-id array). What is open, none of it observed as an
  incident: ① **closed 11-22, owner opened the queue**: the named model is now consulted before
  anything runs. A name this server does not serve as an embedder gets an actionable 400 naming
  what does serve (`EmbeddingService.embedRefusal`, the mirror of `generationRefusal` at the
  generation faces; absent `model` stays consent). A caller that persisted vectors by
  request-name could no longer mix two spaces blind. Gates: `EmbedderRefusalHomeTests.embedFaceMirror`,
  `embedFaceRefusesBeforeTheGuard` (boots without an embedder, so the 400 proves precedence),
  probe 51 §2's new arm with the refusals floor raised to 4.
  ② **closed for the two fields 11-06 named, open for the third face**: `encoding_format` is honored
  and `dimensions` is refused by name (`embeddingsWireEncoding`; gates `EmbeddingsWireTests` + probe
  51), with the base64 string riding `embedding`. The fetched spec says `Embedding.embedding` is
  `anyOf: [array<float>, string(base64)]` (`openai/openai-openapi` ~:51627, read through
  `api.github.com` because platform.openai.com is unreachable from this host) and all four comparators
  that implement the parameter agree (ollama `openai/openai.go:533-549`, vllm
  `pooling/embed/protocol.py:206-209` + its own example, sglang `serving_embedding.py:270-279`,
  Rapid-MLX `routes/embeddings.py:323-336`); `b64_json` exists in that spec only on images. What stays
  open: an *unknown* top-level field is still accepted where OpenAI answers "Unsupported parameter",
  sglang's own `EmbeddingRequest` ignores extras too, so the yardstick itself diverges from the spec
  here and root § Upstream's "spec, their implementation, real requests, observed behaviour" has no
  majority to read off. ③ batch composition moves a vector: the identical string
  reads max-component-diff 1.7e-3 (cos 0.99987) beside a 3-short batch and 1.5e-3 (cos 0.99990) beside
  a 1 202-token sibling. The deviation does not grow with pad length, so it is reduction order in the padded
  batched 4-bit matmul, not pooling over pads; negligible for ranking, named because the query path
  embeds alone while the index embeds in batches. ④ `/v1/stats` got its seat on 11-05 in probe 37 §10;
  `/ready` followed 11-11 in §11. Idle predicate, current stamp, `loadedModels` parity, all weight-free.
  Its busy face has no scripted-lane seat *by construction*: the lane resolves turns with nothing
  resident (`EnginePool.swift:519-523`; 10 concurrent streamed turns read zero busy across 300 polls),
  so that witness waits on the tier question below. Probe 51's §1-§2 run weight-free (a scripted boot answers them at the request boundary); only
  its §3 needs the embedder's weights, so that leg waits on the tier question below and prints that it
  skipped when they are absent.

- **P18 was priced against the wrong enemy** (docs/). Its sibling `OCOREAI_AGENTS_MAX_AREA`, the retired
  contract script's per-guide cap, left with the bespoke docs gates 11-16; its surviving question is the
  'No byte cap reaches the two largest docs' row. P18 keeps docs
  English by default with exactly one Chinese file (the owner's rule, and why this tree has no translation
  drift), but opencode ships 22 README locales (`../references/opencode/README.md:17-32`) and hermes-agent 3
  badge-linked, so the rule is a priced cap on a distribution channel, not a neutrality: deepseek-harness
  pairs each heading's en/zh block by hash in `README.i18n.yaml` so drift is machine-visible. Recorded so the
  owner prices it deliberately.

- **Seven prose cites into the file the 11-03 pin window rewrote were not all re-measured** (Engine/),
  the bump `128f49f1d → b8d4935ab` changed mlx-swift-lm's `MLXFoundationModels/MLXLanguageModel.swift`,
  and three cites into it (`EnginePool.swift` :313 / :558 / :667) had drifted *before* the bump too: the
  referents are :37 (the doc example), :307 (the `[.guidedGeneration]` default) and :675 (the `.vision`
  gate). Those three now read `anchor:mlx-swift-lm` markers in `docs/agent/engine-line-cites.md`;
  the anchor gate that owned them retired 11-16 (last full pass: checked 80, drift 0). Sampled the rest rather than trusting them:
  `MLXBridge.swift:188` still resolves exactly (`:130` is the `configureGPUCacheOnce` it names), while
  `EngineInferenceSupport.swift:305` points at `:1427-1431` for a soft-nudge recipe and those lines are
  `runSchemaGeneration`. The sentence and the line disagree today, and no gate reads either. Settled
  11-11: OpenAIModels/PromptTokenAccountingTests re-measured and de-numbered (two cited ranges were
  inverted outright), and `EngineInferenceSupport.swift`'s six sites re-read. Two claims convicted:
  its quoted recovery phrase is gone upstream, and the sha that "landed" the contract is not an
  ancestor of the pin (merge-base exit 1; object present), so provenance shas left the prose and the
  live contract is the Throw-before-dispatch its anchor pins; four new anchors own every surviving
  number. Both `EngineInference.swift` sites were adjudicated against HEAD: claims TRUE, pointers
  stale; the de-numbering is mechanical, waiting on the file's live copy, not on knowledge.

- **Upstream already ships a scripted engine; ours has to be re-judged when the planned half lands**
  (Engine/), `MLXScriptedLM` is a published product at the pin, and its scripted tokenizer implements
  upstream's own `Tokenizer` protocol
  <!-- anchor:mlx-swift-lm Libraries/MLXScriptedLM/Tokenizer/ScriptedTokenizer.swift public struct ScriptedTokenizer -->
  while its library README still lists tool calls and reasoning in transcripts as *Planned*
  <!-- anchor:mlx-swift-lm Libraries/MLXScriptedLM/README.md Planned -->
. Exactly the half `Engine/ScriptedInference.swift` exists to decide at k=1, so today's lane is no
  duplicate of delivered upstream capability. Re-open: upstream shipping transcript tool calls; check the
  pin diff on that library at the next bump.

- **No weight-free witness for MTP drafter mixing** (Engine/). The drafter belongs to one model now
  (`Engine/LoadedModel.swift:112`, read at `Engine/EngineInference.swift:3452`); until 10-29(55) it sat
  unkeyed in the pool, so a refused family could route on another family's drafter. Keying is
  compile-enforced; the wire proof wants two checkpoints live. Owner call.

- **Memory is read by every request, written only behind `self_correction`** (SQLite/), `ChatHandler.swift:944` reads, `addMemory` writes. Owner call: publish the flag, or gate the recall.

- **Loaded-host reds rotate cast; wall-clock is one class, the anchor another** (Tests/). Magnitudes
  11-02(106), 11-03(3). ① wall-clock bounds bet on the ~618-suite cooperative pool;
  `instant+control` does not fence it. Production behaviour, not a test premise; the median is
  measurable, the tail is not. ② production writes the anchor outside every lease
  (`SessionWorkspace.swift:114`, `SessionManager.swift:138`); 11-03(3) lost a content suite that way
  once (inferred. The lease scan only sees test-file writes). Closed: the ledger's cross-suite half
  (11-02(105)). 11-11(8): four passes (5/3/8/8 issues), no cast repeated, every red green in isolation,
  and the fourth pass owned the box exclusively (my earlier "box load" attribution is corrected: the
  suite-internal pool alone suffices). Wanted: a controlled clock (`ClockToolsTests`), a quiet lane
  (`make test-clt`), or the anchor's scope. Owner.
- **The 11-02 compat sweep left one owner call and one seatless surface; its dated debt is paid**
  (Middleware/, Router/, Security/). The swept axes landed (spec-name `error.type`; `max_model_len`
  aliased one release, 11-02(110), and the alias deleted 11-22 on its stated date. Wire DTO, gallery
  script/test keys, published-skill prose all read `max_model_len`; probe 03 fails on the alias
  *returning*, `ModelsWireShapeTests` on the retired key reaching the wire); ① the eight hand-built error bodies render through
  `AppError.response` since 11-03 (probe 50, `MiddlewareEnvelopeDisciplineTests`), though the keyword
  guard sharing that family reaches no wire still, `SafetyConfig` defaults `enabled: false`, so a
  config seat is the owner's. ② Jev's answer half is read from both stacks, unwritten until the answer
  position scores (probe 49; `systemone-decisions.md` § Shape C). ③ paid 11-22, see the row header.
- **An MCP child is confined by nothing; its env was the closed half** (Tools/, MCP/, Security/),
  the handover that survives the scrub: an MCP server is third-party code holding whatever argv and
  working directory its config hands it, started by `MCPBridge.connectEndpoint`
  (`MCP/MCPBridge.swift:931`, reached at `:286`) with no approval concept in its path; the server's
  keys now leave its env (`Security/ChildProcessEnv`, and the closed-log row names its two test
  gates), but no file or network boundary confines the child. Shipped shapes read off the mirrors
  (cites re-read at their trees 11-18): TensorFold starts the MCP child under a platform sandbox and
  throws when no profile can be built, naming the way out
  (`../references/TensorFold/app/electron/agent/mcp-process.ts:173-186`); deepseek-harness makes the
  boundary a product surface, `read-only` / `workspace-write` / `danger-full-access` with a
  user-approved one-time escalation for a denied call, and states its own limit in the same
  paragraph ("Confinement is same-world only",
  `../references/deepseek-harness/packages/sandbox/README.md:12`). Owner call (§ Working here:
  mode = a user registers an MCP server the way the READMEs tell them to; likelihood = deterministic
  once a server misbehaves. The child holds whatever filesystem the server process holds; cost =
  one boundary at the one launcher that starts third-party code). None of it observed as an
  incident, so this stays an address, not a diff.
- **A wire route can point this box's camera, microphone and screen at a caller** (Handlers/, Multimodal/,
  Security/). The same authority question as the bullet above, inbound instead of outbound. `POST
  /v1/multimodal/capture` takes `camera | microphone | screen` (`Handlers/MultimodalHandler.swift:24-28`), is keyed
  rather than public (`Middleware/AuthMiddleware.swift:146-154`), and is held by 3 of 12 serving trees in the mirrors
  with all three editing it now, 1 of 12 for the live-input half, so it is a direction by this corpus's own test,
  not an eccentricity (§ *The wire that points the box at the world* in `comparator-innovation.md`, which carries
  every comparator cite). Three faces, read off our own code paths, none of them observed as an incident:
  **(a) caller identity stops at the bind**, `ServerAuthGate` refuses a keyless server any non-loopback bind
  (`Middleware/ServerAuthGate.swift:9-35`), so once a key exists a caller on the LAN and a harness on this box are
  the same caller; `Rapid-MLX` discriminates **per request** where we discriminate at boot, 403ing a non-loopback
  client on `POST /v1/cua/permissions/request` behind a config flag
  (`../references/Rapid-MLX/rapid_mlx/routes/cua.py:574-600`). **(b) the user's own off-toggle is not on the wire
  path**. The toggles start `false` (`UI/Models/MultimodalState.swift:42,51`) and gate the perception engine, while
  `captureGate` asks only what TCC measured (`MultimodalHandler.swift:160-176,275-295`) and the camera leg will
  `startCapture()` for the caller (`:177-179`); the comparator's equivalent is a server-side default-off flag whose
  refusal names itself and carries a `recovery` array (`rapid_mlx/routes/cua.py:429-431,925-936`). **(c) a frame has
  no ceiling and no cache directive**. It caps one observation at 4 MiB and answers a named 413 (`:426,988`) and
  stamps `Cache-Control: no-store` on the frame and on the error alike (`:510,918-919`), where our capture response
  sets no cache header anywhere (the only `no-cache` in `Sources/**` is `SSEHelpers.swift:74`).
  Owner call, not a task (§ Working here: a speculative edge names mode, likelihood and cost before anything is
  written): mode = a caller holding a key asks for `screen` or `microphone` from another machine, or the person at the
  box has toggled that channel off; likelihood = deterministic once the key exists, not a race; cost = three small
  decisions at one gate (`captureGate` plus the response builder), each with a shipped shape above and none of them a
  new subsystem. Not claimed: that any caller has done this, no consumer has a name here, which is why this is an
  address and not a diff.
- **No byte cap reaches the two largest docs in the repo now** (scripts/eval/, scripts/probes/),
  the per-guide cap retired 11-16 with the contract script (`git show` has its four-glob set), so `scripts/eval/README.md` and `scripts/probes/README.md` are uncapped and
  dwarf the peer norm for a dev-tooling README (~9–26 KB across the 14 peers that have one; one 385 KB outlier, measured 11-05).
  Both stayed on the 11-05 deletion pass, and for the invariant-1 reason: they are the declared single home of the
  noise band, set size and paired-flip floor. Owner call: cut them, or record that their length is the deliberate cost
  of being the declared single home. Leaving the two numbers unreadable as either normal or not.
- **The pin serves 2 of 3 Qwen generations; Flash-Next is the missing architecture, not a missing config**
  (Engine/, Upstream Pin-1). Measured at `4ab2679`, re-read 11-26 at the pin `bf5a5d438`: `qwen3_8*` is
  registered (`LLMModelFactory.swift:73-75`), so Qwen3.8-27B loads today with its companion drafter
  `mlx-community/Qwen3.8-27B-MTP-4bit` (`MTPDrafterModelFactory.swift:41`). The only gap is weights never
  fetched on this host (owner action); 3.6-35B-A3B already serves with a native MTP head (its config
  `mtp_num_hidden_layers: 1`; `Qwen35TextMTPRegistration.swift:26` keyed on `qwen3_5_moe`; registered at
  `EnginePool.swift:460`). **Flash-Next cannot load**: the checkpoint advertises outer `model_type:
  qwen4_exp` (live-fetched via hf-mirror — `Qwen4ExpForConditionalGeneration`, `indexer_budget`,
  `ple_layer_ids`) and `qwen4` appears nowhere in the pin tree (re-measured 11-26 at `bf5a5d438`:
  case-insensitive `qwen4` is 0 hits across the whole checkout); the failure is honest by name
  (`ModelFactoryError.unsupportedModelType`, checkout `ModelFactory.swift:11`).
  **"No owner call while upstream lacks it" died 11-26: the sentence priced our pin and named it the field.**
  `qwen4_exp` serves on Apple silicon inside this corpus today — on the MLX route (ollama `mlxrunner`,
  Rapid-MLX) and on a native Metal route (TensorFold `zig/src/families/flashnext/`, under its CHANGELOG
  1.3.5's own M5 Ultra receipt; that weight is 79 GiB TFQ3, outside this product's 4-bit envelope, so the
  receipt prices distribution, not parity). Ruled 11-26: keep consuming upstream. The local port becomes a
  filed engine project when a pin checkout taken after 12-15 still greps `qwen4` zero — the same instrument
  as this sentence — and then the three mechanisms of `comparator-innovation.md` § *Diffusion observed*
  case 7 (inherit the 3.5 contract + QSA indexer + host-backed PLE + native MTP head) are its acceptance
  checklist. The rejected shortcut
  is filed because it is cheap: aliasing `qwen4_exp` onto `Qwen35Configuration` would silently drop the
  `indexer_*/ple_*` weights and answer anyway. The surface claiming more than the engine delivered
  (invariant 2).
- **The MTP branch's decomposition is frozen; its gate is one fetch away** (Engine/). Step 4 of the
  decomposition whose steps 2-3/5 landed. A 750-line read (11-13) says the branch is not move-only: it
  nils and writes back the outer `chatSession`/`pooledSession` across the pool handoff, and its two early
  returns skip the tail's seven-variable writeback, so an honest move needs an outcome-struct and a
  pool-slot contract, beyond the compiler-verified move-only recipe the other cuts used. The deeper
  blocker is the gate: the lane's honest proof is a live drafter verifying on this host, and the weights
  were never here. The pin row above names the way out exactly. The pin tree registers `qwen3_8*`, so
  fetching `mlx-community/Qwen3.8-27B-MTP-4bit` + Qwen3.8-27B (owner action) gives the lane its first
  live gate, after which the branch moves the way the guided lane did. Until then it stays nested: a big
  move that cannot run its own gate is a claim, not a fix (invariant 1).
- **The prose layer is under owner suspension until repair, one surface per round** (docs/, owner ruling 11-17). After two
  same-day false claims in committed prose (the DependencyPin root-reads fiction; the registry-absence list in `ecc5f6cb`,
  convicted by the owner's "六棵树外有"), the owner ruled docs and comments are claims and pointers, not evidence, until
  they say repaired. The repair is not a full sweep (matrix § Maintenance names that as owner-sized): one surface per
  round with its named instrument. Live prose through `make audit` (`docs-type-existence`; the cite-check and
  anchor-check legs retired 11-16 with their scripts);
  matrix rows by re-reading the cite at its tree's HEAD, one domain deep; registry cells by site re-read, the post-11-04
  additions (aider, SWE-agent, mini-swe-agent, unsloth, nginx, llm.c, nanochat, autoresearch) never swept; CHANGELOG
  stays a dated diary whose live claims only the named instruments re-derive. Every red found is reported, not repaired
  silently. Restoration is the owner's declaration only. "done" is never self-declared (invariant 2).
