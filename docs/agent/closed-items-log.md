# Closed, once — why these are not open items

> Material `AGENTS.md` § *Open* used to carry prose for although it was resolved, retracted or
> judged a phantom gap. An open item is one that can still change a decision; a verdict is
> history, and history kept in the injected layer costs every session.
- **Probe 13 §8's thinking byte-identity gate (11-10, landed and closed the same day).** The gate demanded
  `thinking:{enabled}` == `thinking:{disabled}` byte-for-byte at temp 0 — a 10-19 premise ("no reasoning
  channel ⇒ the knob is inert") that two boot-stable samples convicted the day the escalation tier first ran
  it: enabled 289 tok/`end_turn` vs disabled 512/`max_tokens`, the arms' counts and answer openings
  identical across two boots (sha-equality is measured live by hand on one boot: absent and disabled share
  it, enabled does not) — the flag
  reaches generation even through a channel-less template (the reasoning text lands inside the answer). The
  section now asserts only what is our code: `absent` matches one of the two STATED states byte-identically
  (measured: `disabled`, sha-verified at temp 0; a default matching neither is the third-behavior face of
  the disabled→ON class), and an arm stopping `max_tokens` reaches the request's ceiling, never the thinking
  budget — the `min(max_tokens, budget_tokens)` shape. Whether the knob moves a given checkpoint is that
  checkpoint's reasoning reality: recorded beside the run, gated by the reasoning-channel rows, never by
  this section. The red it last printed measured the probe, not the product — which is the only thing a
  probe may never do.

- **`/v1/models/:model/…` does not need `%2F` (11-06).** The item's stated cost — "accepting a slash costs a
  second routing truth" — was an assumption about the router nobody had run: Hummingbird answers a
  slash-bearing path with a recursive wildcard, so `/v1/models/**/sampling` is ONE registration and
  `resolvedPathModelId` stays the only place an id becomes a storage key. Nothing was doubled, so nothing was
  paid; `:model` and `**` cannot coexist on one prefix (`Route /v1/models/{model} overrides /v1/models/**`),
  so the wildcard replaces rather than joins. The published template keeps the one-segment `:model` spelling —
  it is what clients substitute and what OpenAPI renders as `{model}` — and the note that used to warn about
  encoding now states both spellings instead. Live: verbatim `org/name` → 200, `org%2Fname` → 200, bare `name`
  and an unknown id → 404 raised inside the handler (probe 03). What closed it was measuring the premise, not
  deciding the taste: an item that waits on an owner call is still an item whose premises can be run.
- **Two packaging defects, one of them named by a version line (11-06).** The rehearsal leg's six-day red was
  not one bug. `scripts/toolchain-contract.sh`'s `print-metal-bin` tested the verdict (`METAL != ok`) where its
  consumer needs PATH reachability — `xcrun -f metal` resolves a compiler *inside* a toolchain without putting
  it on PATH — so the delivery route printed "no value", exported no PATH rung, and its own
  `check --require-metal --probe-metal` preflight still passed, because a probe EXECUTES a named binary and
  cannot see a PATH hole. Under that: the macos-26 CLT is `swift=6.3.3`, and native `.metal` compilation is a
  SwiftPM 6.4 capability, so that route builds green, compiles no shader bytes and says nothing (this host on
  6.4: 38 `.air`, a 4 716 496-byte payload) — a missing capability is silent in SwiftPM and loud in
  xcodebuild. Verdict, and it is the durable one: **a build's exit code is not evidence that shader bytes
  exist**, so the shipping payload comes from a producer this repo runs
  (`scripts/ci-materialize-metallib.sh`, whose 10-29 deletion was justified by a 6.4-era measurement the image
  no longer offers), and `build-app.sh` 3b + probe 41 §1 keep judging the artefact. Run 24 (`e0e6b7f2`) proved
  the PATH fix (`metal=ok · metal_on_path=yes`) and falsified it as sufficient; run 25 (`90956d46`) is green
  end to end — producer 999 s, `rung: xcode-derived-data · 4 695 872 bytes` staged into the SwiftPM product
  path, `shader payload after the green build: rung: swiftpm-product · 4 695 872 bytes · scanned 1`, probe 41
  `12 passed, 0 failed, 8 measured`, window proof green. Closed as *not* the cause: the moved SDK, disk space,
  a payload layout the old globs could not see, and the 11-01 blame on `d664f7b` (one sha, green then red —
  retracted); "the image moved" is retracted too, since `api.github.com` lists no `macos-26-arm64` image
  between 20261026 and 20261102 across that boundary.

- **One verdict, two exit codes: the contract was intact, the layer was not (11-05).** `make drift` printed
  the same report twice and exited **10** then **2**, which read as
  `scripts/upstream-drift.sh:6`'s documented 0/1/10 having rotted. It had not: the script answers 10 on that
  report and `make drift` answers 2 on the same one — GNU make re-signals *any* failed recipe as its own 2,
  so the codes that target's own comment documented were unreachable through the entry point sitting under
  them, and the reader who finds that files the instrument, not the makefile. Both halves that were actually
  wrong are fixed: the target now prints `drift-exit=N` (the number's only surviving channel through make, and
  the thing a reader acts on since `CLAUDE.md` § Upstream 2 sends people to `make drift`), and the script's
  `set -e` let a mid-script death leave with *the failing command's* number — a python traceback is 2, the
  SIGPIPE its own header records on 10-29 is 141, a missing tool is 127 — so an ERR trap now normalizes any
  unregistered code to 1 and prints the line, the command and the raw code it replaced. That trap's first live
  run named the row's unnoticed neighbour: a rate-limited subject-list read died inside a command substitution
  and took the process down *after* the verdict had printed, rewriting **10 → 1** and skipping the axes under
  it; a hint read now names itself and falls through (`axis_window`), because only a failed *verdict* moves
  the code (the line it prints is in that file's own Chinese, so grep the function, not the phrase). Measured on the way in, and the reason the trap stays top-level: `set -E` on bash 3.2.57 fires ERR for
  a false `[ -d … ]` sitting on the left of an `&&`, so three fallbacks the script's own `|| …` had already
  swallowed printed lines claiming an abort — a diagnostic that says the opposite of what happened is worse
  than none. Gate: `UpstreamDriftWindowTests`(11), which asks a real top-level command to fail for real through
  the new `abort-code` seam, asserts the success path is untouched, asks `make -n drift` where the number
  lives, and asks `window-read` that a failed hint read neither moves the code nor reports an abort.
  Reproduce: `bash scripts/upstream-drift.sh abort-code 141; echo $?` prints `1`,
  `bash scripts/upstream-drift.sh window-read; echo $?` prints `0` with its named-miss line, and
  `make drift 2>&1 | grep drift-exit=` prints the script's code.

- **A stale release row that said we ship — resolved by shipping (10-29).** Measured 10-28:
  `api.github.com` `/releases/latest` served `v0.1.13` (published 10-11, asset `ocoreai-0.1.13.dmg`
  25 472 769 B) while `git tag -l`, `/tags`, `/releases` and the Releases page reported none and that asset
  URL answered 404 — the endpoint a bot asks first said we ship, the page a human asks said we never had. The
  owner took the second exit: tag `v0.1.14` ran the `release` job end to end and the API now answers one
  release, `v0.1.14`, 0 d old, one asset `ocoreai-0.1.14.dmg` at 25 965 037 B, and `/releases/latest` agrees
  with the page for the first time. What is *not* closed is cadence: one release beside the field's 44 →
  ≥1 254 is a data point, so the rung stays open and `AGENTS.md` § Adoption now states 1 with a
  `tags_published>=1` claim under it, re-run by `make docs-check`. Reproduce: `curl -s
  api.github.com/repos/uingei/ocoreai/releases` and `git tag | wc -l`. Numbers: `CHANGELOG.md` 10-29(50).

- **Probe 12 §6 was never a `tools[]`-enforcement gap — it was the probe's own fixture (11-02).** It read as
  an open instance of "the wire accepts a declared tool the model never calls"; it is not one. §6 reads its
  specs from `GET /v1/tools` (`scripts/probes/12-json-mode-delivery.sh:257-259`) and passes only by
  delivering the declared keys 3/3 **with the tools still declared** (`:358`), failing when that same prompt
  *without* tools answers 3/3 while the one with tools loses the channel (`:367`) — the tool channel is held
  constant, so a pass there means the answer channel survived it. `open-items.md` carried that as a sentence
  rather than a closure until 11-02(104); it moved here when the open guide hit its cap, so the closure now
  has a home that does not cost every session. Reproduce: run probe 12 against a live serve and read §6's
  fail branch, which names the without-tools control it was measured against.

- **The runner's probe stall — the harness walked a path forever (10-29).** `Wire probe 37` died on its 180 s
  step bound while the same box ran 3 210 tests and the headless serve contract green, and the probe log's
  last line predated the harness's first note. Cause: `probe_scratch_for_binary` walks up from the binary
  looking for the build dir, and `${p%/*}` turns `/Users` into `""`, so a product path with no `.build`
  component — every Xcode product, which is what CI builds — left `[ "$p" != "/" ]` true forever. Invisible
  since the harness existed, because a local binary always lives under `.build`. Fixed by terminating the
  walk at the root and naming `SourcePackages` as Xcode's `.build`, which also turns the runner's
  "pin not verifiable" excuse into a checked premise. Gate: `audit.swift_patterns.sh` Class-M, sampled red
  (the bug re-installed returns nothing in 10 s and says so). Numbers and reproduce: `CHANGELOG.md` 10-29(34).
- **The delivery shape's CI verdict — ran, and passed (10-28).** The gap was that no runner had
  ever built the `--traits appStore` shape: `build-appstore` pinned `print-delivery-env` and judged
  the artefact, not the runner's SDK, and the CLT route has no `metal` on PATH. Three rounds closed
  it (CHANGELOG 10-28(20), (22), (23)): the resolver asks cryptexd instead of globbing, the leg
  reports the resolver's facts instead of probing with a toolchain that cannot answer, and the
  delivery route now asks its own Metal question under `DEVELOPER_DIR=$CLT_ROOT`. The runner's own
  line is the verdict: step "Build + judge the delivery shape (release, --traits appStore)"
  `success`, with the route's notice `metal=/private/var/run/com.apple.security.cryptexd/mnt/…`
  beside it. What stays open is not this: only the owner can type the tag (§ Adoption).

- **HTTP token-count surface (`/v1/count-tokens` + `/v1/messages/count_tokens`) — shipped and closed.**
  The gap: only `{model,prompt}` decoded, so OpenAI's `input` and Anthropic's `messages`/`system` got 400,
  `/v1/messages/count_tokens` was a plain 404 (every Anthropic SDK pre-flight budget call died), and the
  404 hint pointed at `/v1/capabilities` with no index behind it. Landing and acceptance are
  `CHANGELOG.md`'s, not this file's — two copies of a verdict drift.
  One part is **still open**, and it is not history: the model's own tokenizer remains the sole authority
  on a count, never cross-checked against a third-party implementation, and the
  `tokenizer_backend: heuristic` branch (tokenizer absent only) has no assertion on its estimate's accuracy.

- **`kvCacheRuntimeReport`** — ~~not consumed~~ → measured: ocoreai already has its own equivalent
  consumer, `Metrics.kvCacheGpuBytes` (`ocoreai_kv_cache_gpu_bytes`, Metrics.swift:91/210) →
  `ServerStatsSnapshot.kvCacheBytes` → Dashboard `kvCacheGB` (DashboardViewModel.swift:107). Upstream `mlx-swift-lm`'s
  `KVCacheRuntimeReport` (KVCacheConfiguration.swift:486) is a second wrapper, and #248 judged the bug
  absent here — adopting it would only build a duplicate local surface. Not done, on purpose.

- **MLXFoundationModels** — the FM lane is wired (`#if FoundationModelsIntegration &&
  canImport(FoundationModels, _version: 2)`, on by default at Package.swift L26).
  ~~lacks per-token callback on FM `.done`~~ → measured phantom gap: per-token delivery runs
  `yieldParserEvents → continuation.yield` over an AsyncStream (EngineInference.swift:430-470, same shape
  as the std MLX lane) and does not depend on `.done`, which is only a terminal signal. Upstream has zero
  `onStreamChunk` concept — retracted as a phantom.

<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/KVCacheConfiguration.swift:486 public struct KVCacheRuntimeReport -->
<!-- anchor:. Sources/ocoreai/Metrics/Metrics.swift:91 private var kvCacheGpuBytes -->

- **Loop claims needed a fake provider, not a Metal load — shipped.** Every comparator tree judged its
  loop against a fake long before we did: codex on a `wiremock` server (`core/tests/suite`, 260 files),
  hermes-agent on per-provider fakes with replay JSONL (`tests/fakes/providers/`), pi on a faux provider
  under "No real provider APIs, keys, or paid tokens" (`packages/coding-agent/test/suite/harness.ts`),
  opencode on recorded HTTP (`packages/http-recorder`). Ours is `Engine/ScriptedInference.swift`: same
  routes, same SSE, deterministic tool calls, `engineBackend: scripted` on `/v1/capabilities`,
  `ScriptedEngineTests`(5) + probe 37, and the scoreboard refuses to score a replayed run. The round and
  its red-samples are `CHANGELOG.md`'s.

- **The bytes the injected corpus spends are priced — measured, not reviewed.** § Documentation Map has
  long demanded "an inference regression" for injected text while no instrument by that name existed, so
  the demand was a claim pointed at the file that states it (pi runs paired `without_docs`/`with_docs`
  containers — `packages/evals/README.md:1-14`). The instrument is now
  `OCOREAI_EVAL_DOCS=none|root` + `_repeat_stats.py --a/--b`, and it produced numbers twice on the first
  day. Recorded pair (artefact built from the tree being scored, root doc 21,529 B, k=3 per arm on the
  same 39 tasks / 6 tools / checkpoint): **25.00 → 16.33/39, Δ −8.67 tasks (−22.2 pp), McNemar exact
  two-sided p < 0.0001**, b = 29 / c = 3. Replicate pair (hours earlier, then-current artefact, 21,548 B):
  **24.67 → 17.00/39, Δ −7.67 (−19.7 pp), p = 0.0003**, b = 31 / c = 8 — so the quote is a range,
  −19.7 to −22.2 pp. The premise floor passed every `root` run (39 assembled prompts, `systemChars`
  24,630–25,587 ≥ the doc's bytes), so the doc demonstrably arrived. Three mechanisms, each read off a
  trace: the doc becomes an *edit target* (`edit-replace-all`: "I failed to replace \"FOO\" with \"BAR\" in
  AGENTS.md", identical in both pairs); long context *degrades the tool call* (`fix-boundary-comparison`
  typed `edit_file(path=…` into the text channel where the doc-free arm passed 3/3); and *narration
  displaces tool use* (mean answer 63 B → 100 B, median 27 → 36, with the workspace unchanged). Improvement
  is not established: two tasks went 0/3 → 3/3 in the replicate and none did in the recorded pair. What it
  settles: the corpus is not free (21.5 KB/turn costs about what all 40 tool declarations cost, −18.8 pp),
  `without_docs` is the board's real history, the artefact now has to be named (`binary=<name>+<mtime>+
  <bytes>`) because a stale one was silently judging a newer tree, and an unpaired run is worth ±2 tasks
  even on identical conditions. What it does not settle is the shape of the curve —
  `docs/agent/open-items.md`. Numbers, red samples, reproduce command: `CHANGELOG.md` 10-27(24),
  `scripts/eval/README.md`.

- **The silence under the instruction-budget ceiling — the drop speaks (10-28, moved here 11-01).**
  One resolver (`WorkspaceContext.swift:204` `assemble`) measures each injected doc's fate and both
  consumers read it: the injected text carries the truncation/drop notice (`noticeLine`) and
  `/v1/capabilities` publishes `instructionBudget` beside `tokenizerBackend`, labelled `<root>/…`
  because it is public. Borrowed, not invented: deepseek-harness states the drop inside the injected
  text and pins the wording as a fixture ("Workspace instruction budget 700 bytes: truncated … from
  1900 to 292 bytes"). Gates: `WorkspaceContextTests`(15) — exact bytes, both states, no notice when
  nothing was cut, no absolute path on the row — and probe 03, which boots a server against a
  workspace seeded to overflow the cap; both were red-sampled by reporting the dropped doc as
  `whole`. What the open item keeps is only what can still change a decision.
- **A pin bump can swallow its own unread window — the ledger exists (11-09).** The mlx axis's baseline is the SPM pin
  itself, so a bump crossing unread commits deleted them from `make drift`'s report at landing (measured: `a70ef531`
  audited only #732 and shipped #731/#745/#746/#740 blind — #731 a correctness fix our guided lane needed). Closed
  as an instrument, not a promise: `pairing_ledger` (`bash scripts/upstream-drift.sh pairing`) — every `revision:`-
  moving commit's crossed commits must be named (`#PR`/sha-prefix) in the bump message or the diary; same 0/10/1
  contract, self-floored premises, the pre-discipline lineage (178 ancestors behind the 10-06 anchor) declared as a
  blind face, not back-filled. Red sampled on `HEAD~2`'s diary (17 names across five windows, founding instance
  included) before the seam was trusted; it then convicted the closing round's own "nothing inside the pin is
  unnumbered" sentence — two more commits (`#669` test-only, `#614` default-impl protocol addition) read, judged
  and named on first run. Full verdict rows: CHANGELOG 11-09 (three entries); the mlx-swift-lm
  `generation_config.json` dormant face travels with them — a future wiring commit lands inside a paired window, where the ledger names it
  and that round pays for it.
