# Live probes

Executable evidence about the HTTP surface (AGENTS.md invariant 1). They fix the
failure they were born from: live findings were throwaway scripts in temp dirs, so no measurement
outlived the session that made it.

`V1EndpointCatalogTests` and friends pin the wire at **compile time**. These probe a **running
server** — the only place a registered route can still 404 (middleware, ordering, a throwing handler).

## Running

```bash
swift build --scratch-path .build-clt --disable-sandbox   # or: make build
bash scripts/probes/run.sh            # all probes, each boots its own server
bash scripts/probes/run.sh 02        # just one
```

**Needs a real Metal device — except 37**, which loads no model by design, and except **38 §1** /
**39 §1–§1b** / **40 §1**, which are contract tiers written to run without weights; 39 §2 and 40 §2 run the
measured lane when a checkpoint and a working engine are present and print their own reason when they are not.
Inside the agent sandbox MLX logs
`[metal::load_device] No Metal device available`, the engine never reaches ready, and every
probe fails at boot. That is the harness, not a regression — run them unsandboxed, the same
route `make test-clt` uses (see `docs/agent/build-gate-reality.md`).

Each probe boots its own `ocoreai serve` on an OS-assigned free port, so runs are
repeatable and never ride on a GUI instance that happens to be open. Runtime is dominated by
model load — except probe 37, which runs the wire against a replayed script with nothing resident
(`bash scripts/probes/run.sh 37` decides a contract claim in seconds, in the sandbox tier). Three
probes have a CI seat and run on every push from the `Build & Test (macos-26)` leg — `37`
(scripted-engine wire), `38` (§1 `reasoning_effort` honesty, which needs no checkpoint) and `39` (it
executes `skills/ocoreai/SKILL.md` marker by marker against the served wire) — as one step each, run by
`scripts/probes/ci-step.sh`. They were ONE step until 10-29, when that step spent its whole 600 s bound
and the only annotation was "timed out after 10 minutes": a shared bound names the step and never the
probe, and the log that says more sits behind a token. Split, the runner's own per-step duration is the
diagnosis (measured on this host: 37 = 2 s, 38 = 10 s, 39 = 25 s), each bound is its own verdict, and a
failure publishes the probe's words as annotations.

## What is here

Each entry below is one probe's contract: the question it asks, then every assertion it
makes. A clause that stops being asserted turns into a probe that passes for the wrong
reason, so this list is what to read when a probe goes quiet. Round-by-round forensics for
each defect named here lives in `CHANGELOG.md`, at the dated round that found it.

- `01-prefix-accounting.sh` — Does a session-pool HIT actually save a prefill, and does the server admit whether it did?
Fails when: the wire claims `cached_tokens > 0` that the engine did not deliver, a HIT turn goes unaccounted, the dedupe path was never exercised, or `prefixReuse` / `reuseRefusals` on `/v1/models/:model/kv-cache` disagree with the measured turns (including which rule refused a warm session, and the cold turn whose head was already resident in another
    conversation), or the engine's `Prefix cache reused C of T` line disagrees digit-for-digit with that same turn's `cached_tokens`/`prompt_tokens` (the whole-vs-part tie that stayed silent for exactly as long as the wire published the prefilled suffix under the prompt's name), or one streaming turn's `prompt_tokens` and the `/metrics` prompt counter move by
    different amounts (§E: the wire was accounted while the counter was not, so cost and capacity were read from a number ~36x too small)

- `02-count-tokens-shapes.sh` — Can OpenAI *and* Anthropic clients size a request here?
Fails when: any spec-legal shape 400/404s, an unlabelled count, same-text shapes disagreeing on one endpoint, the pre-flight counting **less** than the caller's own bytes (it sizes the assembled request, not just the payload), the `system` block dropping out of either endpoint's count, or a malformed body answering 200/500

- `03-capabilities-models-consistency.sh` — Does the discovery surface answer when a client follows it?
    The probe boots with a workspace it seeds to overflow the project-instruction byte cap, so the one row
    that tells a caller whether *its own instructions* arrived intact is measured under the condition it
    exists to expose, not on an empty chain that would pass by finding nothing.
Fails when: the endpoint index is thin or lists a route the live server 404s, a "ready" model rejects `/v1/count-tokens`, a model/capability row omits `vlm`/`contextLength`/`available`, `instructionBudget` leaves `/v1/capabilities` or disagrees with its own `docs[]` rows (a counter off its rows, `injectedBytes` off their sum, bytes over `maxBytes`), the seeded overflow stops reading as one `truncated` plus one `dropped` doc with exact `bytesTotal`/`bytesInjected`, a `label` is not rooted at `<root>/`, or a doc row carries an absolute path onto this public endpoint. Red-sampled 10-28: reporting the dropped doc as `whole` turned it red on the first assertion

- `04-multimodal-honesty.sh` — Does "can see / can hear / can speak" survive contact with the OS?
Fails when: the status payload publishes verdicts without the permission/device facts behind them, a capture leg returns `success:true` with no bytes, a capture request blocks on a TCC dialog, empty text reports a successful speak, or a `vlm:true` model fails to answer an inline PNG

- `05-hearing.sh` — Does hearing survive contact with the OS, over the wire?
Note: — and does the server hold its own `ready` verdict to its word?
Fails when: any refusal for speech arrives as a 500 or without `error_code`/`remediation`, the status payload claims `transcriptionStatus` without the `hearing` block behind it, `transcriptionStatus` and `hearing.verdict` disagree, a `ready` verdict is not backed by `probe: ok`, the two accepted body shapes answer differently for the same bytes,
    `response_format: text` answers as JSON, a remote `url` is fetched instead of refused, the endpoint index omits the route, or `--probe-hearing` claims success it did not measure

- `06-chat-audio.sh` — Does `/v1/chat/completions` hear the `audio_url` it accepts, or drop it?
Fails when: HTTP 200 without `audio_input` on a request that carried audio (the silent drop), a refusal without `error_code`/`remediation`, a payload fault answered 503 instead of the 400 the shared status table assigns it, a refusal costing model work, stream and non-stream answering the same audio turn differently, the answer not echoing an utterance the
    disclosure claims was transcribed, or the endpoint index being silent about what happens to `audio_url`

- `07-anthropic-blocks.sh` — Does `/v1/messages` honour, or blank, the content blocks a real SDK sends?
Fails when: a spec-legal block array answering 200 while `usage.input_tokens` sits at or under the plain-string baseline (the turn was blanked), a refusal that does not name the block type, `[{type:text}]` itself failing, a 200 with empty content next to an image, or a run whose baseline is unusable (it aborts instead of issuing verdicts built on a missing
    premise)

- `08-video-honesty.sh` — Does `/v1/chat/completions` see the video it accepts, keep the bytes its transcript cites, and name what it cannot open?
Fails when: a clip answered 200 without naming its colour or without a prompt-token jump (accepted but never seen), the first plain-text turn after a video turn failing (the transcript cites bytes that were deleted at request end), the spool empty while a live conversation still cites the clip, or a media part naming a missing file answered 200 or 5xx
    instead of 4xx with `error_code` + `remediation`. A 5xx is never counted as an honest refusal — the first version of this file did exactly that and reported PASS on a broken server

- `09-malformed-request-honesty.sh` — Can one bad number in a request body kill the server?
Fails when: a negative or out-of-range `max_tokens`/`temperature` traps the process, or a payload fault answers 5xx/200 instead of the 4xx the shared status table assigns it, or the error omits the offending field

- `10-sampling-knob-delivery.sh` — Does the engine actually do what the accepted sampling knobs say?
Fails when: a knob is decoded, cascaded and logged yet changes nothing measurable in the output — accepted, and dead on the last hop into the engine

- `11-tool-call-delivery.sh` — Does a declared tool come back as a call the client can run?
Fails when: `tools[]` yields prose instead of `tool_calls`, declaring a tool costs the answer (forcing gated on presence), `tool_choice:"none"` still calls, SSE and JSON disagree, or `toolCallDelivery` says `parsed` without evidence naming the tool

- `12-json-mode-delivery.sh` — Does `response_format` deliver JSON with something inside it, with and without `tools[]` on the same turn?
Fails when: `json_object` fails to parse or disagrees with `json_schema{"type":"object"}`, a schema naming required keys returns none, a caller that pins zero properties stops getting `{}`, or §6's own control collapses —
    the ask must still deliver its keys with tools removed, otherwise §6 blames the crossing for what grammar alone broke. §6 is `probe_fail`, not xfail: the keys arrive 3/3 with the tools still
    declared, on both shapes, the same rate the identical prompt reaches without them — and that ordering was chosen from four measured candidates, since envelope-first lost the answer 0/3, an `anyOf` of both channels
    finished after one brace, and no grammar fenced the JSON in ``` so nothing downstream could parse it. §7 holds the half no ordering can give: a turn that must read a file before answering cannot emit the call under a
    JSON grammar, so 200 comes back with schema-valid integers the file never stated (fixture says 47 by 13; answers said 10/10, twice ran the digits out to `finish=length`). §5 splits by prompt, not by run — 3/3 close
    on one ask, 3/3 run to `finish=length` with a 126-character repeat run on the other.

- `13-anthropic-tool-delivery.sh` — Does the Anthropic face deliver what its wire promises — a call, a result continuation, thinking, the same prompt the OpenAI face sends, and a steer?
Fails when: a demanded call arrives as `end_turn` prose instead of a `tool_use` block (id/name, `input` as an object); the SSE stream opens a block without naming it or leaks the call dialect as text; `message_delta` carries no `tool_use` reason; a declaration without demand loses the answer; `tool_choice:{"type":"none"}` still calls; the shared
    `toolCallDelivery` gauge stays unmoved; `thinking` never reaches `InferenceOptions` (the assembly line must read `enableReasoning=on/off/default`) or `disabled` resolves to ON; `budget_tokens ≥ max_tokens` not refused by name; a `tool_result` turn that re-dispatches the call or ignores the result; the two faces assembling or reporting different numbers for
    one request; `count_tokens` drifting from `usage.input_tokens`; a queued steer swallowed on this face; one declared tool inflating the system message

- `14-parallel-and-terminal-word.sh` — Does a tool turn tell the truth about itself — how many calls it may run, whether the budget cut it, and which chunk is the last?
Fails when: `parallel_tool_calls:false` / `disable_parallel_tool_use:true` still delivers two calls; a turn the budget chopped says `tool_calls` instead of `length` (`completion_tokens == max_tokens`); an SSE delta carries a `finish_reason` or more than one chunk does; a delivered call ends with `stop`; OpenAI's nested `tool_choice` answers 400 `Coding key
    \`name\` not found.` while an unknown word answers 200; a refusal that does not name `tool_choice`. §7 pins that a turn obeys its own `max_tokens` even when the turn before it on the same session was grammar- or tool-constrained (regression pin for the pooled-session leak)

- `15-system-instruction-delivery.sh` — Does the caller's `system`/`developer` text reach the model on both faces, and does rewriting it invalidate the cache that was rendered without it?
Fails when: a ~1k-char `system` message that leaves `usage.prompt_tokens` at the no-system baseline (accepted, counted by the disclosure line, never delivered); `developer` costing different tokens than `system`; the two faces disagreeing on identical content by more than 8 tokens; the disclosure showing two system messages (`[system,system,…]`) or its
    `systemChars=` failing to grow with the client text; unchanged instructions not reusing the prefix (which would make the changed-instructions half vacuous); changed instructions still reusing the pooled session; or a cache dropped without its reason logged at info level

- `16-tool-declaration-duplication.sh` — Does one declared tool reach the model once, or twice — and who writes it?
Fails when: no `Tool prose <mode> for <model>` line at all (the load-time template measurement never ran); mode `injectedUnmeasured` on a loaded model (XFAIL with numbers); under `skippedTemplateRenders` any `## Tool: block(s) written > 0`, or the delivered `prompt_tokens` failing to grow ≥16 for a declared tool (the tool never arrived); under
    `injectedTemplateIgnores` zero blocks written (nothing declared it); the delivered delta failing to scale with the surface; or no `tool_calls` on the premise turn, which makes every later section vacuous. Measured 10-20 post-fix: 0 blocks written, +95 delivered tokens for one tool (+52 per extra tool). §5 adds the surface check: no `toolProse.mode` in the
    kv-cache payload, a mode outside the three-value vocabulary, a wire mode disagreeing with the log's mode, `templateRendersTools` arriving as an absent key rather than `null` when nothing was measured, or an empty `reason`. Measured §5 live: `toolProse.mode=skipped_template_renders`, `templateRendersTools=true`, agreeing with the log's
    `skippedTemplateRenders`

- `17-video-unpooled-lane.sh` — Does a server **with no session pool** still disclose the video it delivered?
Fails when: a turn on that lane naming the clip's colour with a prompt-token jump (measured 712 → 856) while `/v1/models` still reads `video_input=not_observed` — the record used to live inside the pooled release, which never runs here; also fails if the premise is false (log claims the pool enabled, or a second turn reuses a session via
    `cached_tokens`/`Session pool HIT` despite `OCOREAI_SESSION_POOL=0`), and if `delivered` arrives without evidence naming turns and parts

- `18-auth-surface.sh` — Does the `auth` column `/v1/capabilities` publishes match what the server actually enforces?
Fails when: boots with keys ON and floors that premise first (a disabled middleware makes every refusal pass vacuously at 200), then certifies all 7 public routes answer keyless, all 27 key/admin routes refuse with 401, `GET /v1/perception` by name (401 keyless / 200 keyed — the router's own docstring called it "public" while it was never in
    `AuthRoutePolicy.publicPaths`), and `DELETE /sessions/:id` with a **user** key → 403 `adminKeyRequired` (never a silent 2xx); last, the public set measured on the wire must equal README.md's documented list. A route that never answered counts as a contradiction, never as "open"; red sample — adding
    `/v1/perception` to `publicPaths` fails 3 assertions (keyless 200, and README's 7 paths vs the wire's 8)

- `19-instruction-change-cost.sh` — When the caller's instructions change mid-conversation, are the new ones obeyed — and what does that cost?
Fails when: instructions A still obeyed after B is sent (the stale-instruction defect `instructionsMatch` exists to prevent), a same-instruction warm turn reporting `cached_tokens == 0` (the premise: without reuse there is no baseline to price), the wire's `cached_tokens` disagreeing with the number the engine logged for that conversation, or the changed
    turn claiming the whole prompt was reused when the old prefix described the old instructions— refuse-and-rebuild, priced at one full re-prefill (the owner-call in AGENTS.md § Open, with codex #53872's
    supersede-marker as the alternative)

- `20-download-path-traversal.sh` — Does a model id get to choose where the cache lives?
Fails when: a traversing `model`/`revision` not answering 400 with `error.param` naming the field and echoing the value; a refusal arriving as `text/event-stream` (the stream opened anyway, so the client's SDK already committed to a download); the path the id *would* have joined showing up on disk; a legal `org/name` being refused by shape (the fix must not
    eat real downloads); an SSE stream that emits no `data:` line; either pre-existing refusal losing the field it blames; or the server not answering `/health` afterwards. It also caught the defect it now gates: before the fix every body answered `400 Coding key \`useLatest\` not found.` — and the two "pre-existing validation" legs passed on that run, which
    is why every refusal leg here now asserts *which* field it blamed

- `21-sleep-steer-wake.sh` — Does input for *this* conversation end `clock.sleep`'s wait, does the injected text reach the model in that same turn, and does another conversation's input leave the wait alone? The timing verdict comes from `ocoreai.tool_results[0].duration_ms` (measured), not from the model's echo.
Fails when: a control turn that never spent its requested duration (without a real sleep, "the steered turn was fast" certifies nothing); a steer accepted with `queued_count>=1` while the turn still runs the full duration (no early wake); a steered reply missing `[mid-turn user steering]` (accepted but never delivered into the turn); `Sleep completed.` on a
    turn that was actually woken, or `interrupt` missing when the control proved the checkpoint echoes tool output; a steer aimed at a *different* session ending this session's sleep (cross-session wake — the same leak `SessionIsolationTests` closed on the pool side); `sleep` absent from `/v1/tools`; a `/v1/tools` scan that parsed fewer than 5 names (vacuous
    premise); or any response with `cached_tokens > prompt_tokens` (a breakdown larger than the whole it belongs to)
    or `ocoreai.tool_results` missing on a dispatching turn, or a `duration_ms` contradicting its leg (a wait reported short, a wake that never happened)

- `22-session-memory-identity.sh` — Does one `session_id` (and one Anthropic `metadata.session_id`) become one session in memory, does a message row hold its own tokens, and does a re-sent history get stored once?
Fails when: a conversation key splitting into a second `sessions` row (measured before the fix: 3 turns ⇒ 3 rows of `message_count=2`), the turns not accumulating in that one row, a user row costing more than its own content (before the fix: 34 characters stored as `token_count: 705` = the turn's whole prompt), or the session total exceeding 1.5× one
    turn's `prompt_tokens` — the signature of charging history again every turn against the 128k prune rule

- `23-lora-seam-honesty.sh` — Does one LoRA request take the box down, and does an id `/v1/models` advertises ever reach the engine?
Fails when: silence or a dead server on `/v1/models/evaluate` or `/v1/models/train` (before the fix legal datasets killed the process inside upstream `LoRATrain.loss`'s `model as! any LLMModel` — the trap, the file:line and the pin are in CHANGELOG); a refusal that does not name the
    capability it needs; a train stream that opens and then cuts without an `error` chunk; an SSE error carrying no message; the box not answering `/health`, or a normal chat turn losing its code word, afterwards. **Gated hard since the same session** (`HubReachability`): an unresolvable id must now be answered within 30 s — HTTP 404 when a hub said the repo
    is not there, HTTP 503 when a hub could not be asked, naming the id in both, and the 503 also naming both hubs plus the `HF_ENDPOINT` lever. Both legs refused at the hub ceiling with the code word alive afterwards; pre-fix the same probe carried two known-open silences. The
    residual stays xfail: nothing caches a failed resolution, so retrying a dead id re-pays the probe window (8 s → 8 s). The 1-token-sample rule is unit-pinned (`LoRASampleDomainTests`) because this box's checkpoint is refused earlier by capability — the probe says so rather than claiming it checked

- `24-hub-existence-gate.sh` — Does the hub reachability gate refuse only what it actually asked?
Note: The `.present` half of `HubReachability` cannot be measured against a real hub here (huggingface.co is a black hole on this host), so the probe stands its own stub hub — 200 for `/api/models/<repo>`, 404 for everything else — with `HF_ENDPOINT` pointed at it.

- `25-mcp-timeout-budget.sh` — Does an external MCP server's response budget equal the number this server publishes?
Note: `$bridge/status` must state 30s startup / 300s tool; `tool_timeout_sec:-5` must come back inside a second as JSON-RPC -32602 naming field + range + value sent (never a clamped number, never a wait); connecting a real stdio stub with `startup_timeout_sec:12` must make `$bridge/endpoint/list` publish 12 beside the untouched 300 — the ledger reads the
    budget the client was actually built with, so an override that stops reaching the engine shows up where an operator looks. Pre-fix, a documented 10s knob had zero consumers while the code enforced a hardcoded 15s in two places.

- `26-mcp-stderr-diagnosis.sh` — When an external MCP server fails, does this server say *why*?
Note: A stdio stub that writes a traceback and exits 3 must produce a `-32603` naming **both** the exit status and `ModuleNotFoundError`, with exactly one `stderr:` clause (the client wraps the error twice — a doubled clause is a bug); a stub that complains then hangs must say `did not answer within 2s` **and** carry its `address already in use`, so the
    two failure modes stay distinguishable rather than collapsing into "it failed"; `$bridge/endpoint/list` must still hold that evidence in `lastError` (the row the GUI reads after the response scrolled past); and a healthy stub must still connect, with `/health` and a chat code word alive afterwards — capturing stderr costs a behaving server nothing.
   Fails when: first the premise: the stub must record the existence request, or every later assertion is vacuous (`HF_ENDPOINT` ignored ⇒ unmeasured, not proven); then pass-through — with the hub answering 200 the answer may be a download failure (the stub holds no weights) but must not be the reachability refusal, and the box must still answer `/health`;
    then the flip — kill the stub, send the *same* id, and it must come back HTTP 503 naming that id inside 15 s. Two verdicts from one id, decided by what the hub said, not by how long the caller waited — the stub log shows `/api/models/<repo>` followed by `/revision/main?` and `/tree/main?recursive=true`
    (the request went through to the hub client), and the same id is refused in 0 s once the hub is gone.

- `27-edited-history-honesty.sh` — When a caller rewrites the past, does the answer come from the history it actually sent — and what does that turn pay?
Fails when: the replaced fact appearing in the reply after an edited resend (the leak `canReusePooledSession` refuses to answer from, and now the leak the KV trim must not reintroduce — until this probe it was a rule believed, not observed); an appended warm turn that reuses nothing (no baseline ⇒ "this edit costs X" certifies nothing); the edited turn
    re-prefilling everything (`cached_tokens == 0` — the fork or the reserve silently stopped working and only latency would notice); `prompt_tokens < cached_tokens`, or the edited turn claiming more reuse than the appended turn got (a breakdown larger than its whole); and either half of the ledger lying — `historyDiverged > 0` books a rewound turn as
    refused-and-rebuilt, or `prefixReuse` disagreeing with the usage field the client saw. The four-turn usage ladder and its pass count belong to the run, recorded in CHANGELOG. Pre-fix the same turn

- `28-single-instance-refusal.sh` — When another instance holds the lock, does the refused `serve` actually leave?
Fails when: instance B stays alive until someone signals it (a refusal the caller must kill is a hang wearing one), exits 0
    (a startup that never happened must not look clean to launchd), or its log omits the holder pid / `OCOREAI_ALLOW_MULTI_INSTANCE`.

- `29-engine-busy-429.sh` — When the engine is occupied, does the wire say 429 + `Retry-After`, or 500?
Fails when: the capacity refusal is a 500 `app_error`, lacks `engine_busy`/`rate_limit_error` or `Retry-After`, the turn in flight is
    disturbed, or a short overlap is refused instead of waited out. Leg 1 gates on the long turn's first SSE token: lock order is not
    HTTP arrival order.

- `30-repeated-prompt-delivery.sh` — Ask the same thing twice: does the second answer arrive?
Fails when: a one-token `.eos` turn lacks its `Degenerate generation` line (leg 4). Its run-to-run
    the collapse rate is explained: the prompt was not byte-identical across boots (probe 32);
    the numbers and the dead mechanism stories are in `CHANGELOG.md`.
- `31-client-abort-cancellation.sh` — When a client walks away mid-turn, does the engine stop?
Fails when: a turn whose client left still leaves a completion record with >8 tokens XFAIL-open until fixed:
    nothing detects disconnect (no HB liveness handle). Leg 1 = positive control.

- `32-prompt-byte-determinism.sh` — Same request, different boot: same prompt bytes?
Fails when: one shape yields more than one `promptHash` across boots (a Dictionary/Set or unsorted JSON
    reached the prompt), or declaring a tool changes nothing at all. No unit test can see this class:
    Swift fixes the hash seed per process.

- `33-mcp-required-byte-determinism.sh` — A tool whose server declares no `required`: same bytes, and a sorted list?
Fails when: the tool is not local (then no schema byte entered the prompt and any byte claim is vacuous), the
    declaration or `promptHash` differs across boots, or the synthesized `required:` is not name-sorted.

- `34-mcp-server-wire-conformance.sh` — Does the advertised `/mcp` face answer what the specs allow?
Fails when: a numeric JSON-RPC id is refused or echoed as a string, `tools/list` publishes tools without
    properties/descriptions, `tools/call` answers a success-shaped `{}` because params never decoded, a malformed
    call is not refused by name, or the box stops serving after MCP traffic.

- `35-kv-cache-residency.sh` — Does the KV byte figure the surfaces publish ever become real,
  and does admission learn its price from that measurement?
    Fails when: `/metrics` reads non-zero before any cache exists, stays zero after a 3K-token
    turn, disagrees with the endpoint's `residency.residentBytes`, reports a `bytesPerToken`
    outside 256..1048575, or after a turn has priced the model no reservation logs
    `@ measured <that price> B/token` (§6 — the 1024 B/token floor is for the unpriced model only).
- `36-download-plan-dry-run.sh` — can a client size a download before committing to one?
    Fails when: `dryRun: true` writes anything under `~/.ocoreai/models`, the plan disagrees
    with the stub hub's sizes (1000150 on an empty cache), a 404'd repo publishes
    `requiredBytes`/`wouldFit`, a seeded repo plans anything but `0` + `locallySatisfied`, or
    an escaping id is planned instead of refused.

- `37-scripted-engine-wire.sh` — can the wire's contract be decided with **no model resident**?
    The only probe here that needs neither Metal nor a checkpoint: it points
    `OCOREAI_SCRIPTED_ENGINE` at a script, and `ScriptedInference` replays it through the real
    handlers, parsers, SSE writer and dispatch path.
    Fails when: `/v1/capabilities` stops answering `engineBackend: scripted`, `/health` reports a
    resident model (prewarm would be loading weights the tier exists to avoid), `/v1/models`
    advertises the fixture id `scripted-model` that cannot load, streamed text leaves out of order
    or without its reasoning delta / tool call / terminal frame / `[DONE]`, an aggregated turn
    publishes a `finish_reason`, `tool_calls` id, function name or `usage` count other than the
    declared 7/12/19, `usage` grows a `prompt_tokens_details` cache claim a replay never earned, a
    broken script answers 200 with an empty turn instead of naming its cause, or
    `scripts/eval/run.sh` stops refusing to score a scripted run, or AGENTS.md's quoted advertised-tool
    count (40) stops matching `GET /v1/tools` — the injected file's number about the tool surface is the
    only one a runner can check, and `make docs-check` has no server to check it against.

- `38-reasoning-effort-honesty.sh` — does a demanded `reasoning_effort` reach the checkpoint, or only the log?
    Two tiers, because only one runs without weights. §1 (scripted lane, CI seat, no Metal, no download):
    an **unmeasured** checkpoint must never be refused and `/v1/models` must publish `not_observed` rather
    than omit the question. §2 (needs one ready checkpoint; prints a skip note otherwise): the load-time
    template probe must have recorded something for the loaded model, and on a measured `template_ignores`
    the demanded word gets 400 naming knob + checkpoint + value + both exits, with the next request served.
    Fails when: the load probe rots (a loaded model reporting `not_observed` — the face would read as
    honesty), a measured-negative checkpoint delivers 200 with the word silently dropped (the exact
    failure this gate exists for), the refusal stops naming one of the five things a client acts on, a
    `honored` checkpoint gets refused anyway, a `/v1/models` row leaves `honored|template_ignores|not_observed`,
    or the refusal costs the server its next request. Red-sampled 10-27: pinning the load measurement to
    `nil` and pinning the refusal rule to `false` each turned §2 red.

- `39-skill-contract-exec.sh` — does the published skill survive being executed?
    `skills/ocoreai/SKILL.md` is what another harness reads to drive `/v1`, so its sentences are a contract
    and a contract that rots is a wrong action taken somewhere else. The skill carries its own assertions as
    markers in the paragraph they belong to (`<!-- exec: METHOD PATH [body] STATUS | substring | … -->`), and
    this probe boots a server and runs every one: §0 the clone itself (no server) — every backticked path the
    skill cites must be tracked by git and nothing under `skills/` may be ignored, floor 3 cites, added 10-28
    when an unanchored `references/` rule in `.gitignore` shipped a skill whose three reference files existed
    only on the author's disk; §1 the contract lane (scripted, no weights, no Metal),
    §1b the key boundary the skill tells callers to expect (401 naming the fix / bearer accepted / `/health`
    still public), §2 the measured lane against a real checkpoint — `@model` resolved from `/v1/models`, and
    the tier's premise (one real generation must complete) established **before** any assertion, so a host
    that cannot generate gets a printed reason instead of a pass or a fake red. Both tiers floor their own
    marker counts (12 and 4), because a scan that finds nothing must not read as success.
    Fails when: a documented field leaves a served body, a status changes, a marker line is re-formatted out
    of recognition, a marker becomes unparseable (balanced-brace scan, loud exit), the marker set shrinks
    under its floor, the key boundary stops matching what §2 of the skill says, or the measured lane's
    sentence stops being true of a real checkpoint, a path the skill cites is not tracked by git, or an ignore
    rule swallows a file under `skills/` (§0; red-sampled 10-28 against the three reference files `.gitignore`
    was hiding, green after `git add`). Red-sampled 10-28 while it was being written: a
    dotted-path assertion (`engineSummary.loadedModels`) and a body written before the status each turned it
    red against the real served bytes — the skill was wrong twice before it was shipped, which is the point.

- `40-stranger-agent-skill-task.sh` — Can an agent whose only knowledge of this server is `skills/ocoreai/` finish a real job?
    Probe 39 *executes* the artefact; here a model has to be **read by** it, which is how a stranger's harness meets us. The server
    is seeded per run with a searchable `KEY` and a `VALUE`, and the task names only the `KEY`, so the sole route to the answer is a
    live call chain: find the search surface inside the artefact, query it, read the snippet, write the file. §1 the instrument (any
    host, no weights, no server) — the artefact must inject whole (floor 12 000 bytes, the real count printed), the task text must
    leak no answer, route, method+path pair or query parameter, and the verifier runs against a wrong **and** a correct deliverable,
    because a lenient checker would turn every §2 green into a measurement of itself. §2 the agent (needs a ready checkpoint) —
    premise first: the note must be storable and retrievable by the server's own `/sessions/search`; then one turn whose system text
    is the artefact verbatim and whose `tools[]` is `exec_command` as served by `GET /v1/tools`, never a local copy of a schema.
    Fails when: the artefact shrinks under the floor, the task hands the agent what it is supposed to find, the verifier accepts a
    wrong token or rejects a right one, the seeded note is not retrievable, the served tool list lacks `exec_command`, or a fresh
    agent holding only the skill never writes the token. Green 10-28 on a real checkpoint: 29 240 injected bytes across 4 files, and
    the secret token came back in the deliverable — the wedge claim measured rather than asserted. Those 4
    files are now gated as tracked by probe 39 §0: on 10-28 the figure was real and the clone did not have it
    (`git ls-tree -r 61bb4b0 -- skills` listed 2 of the 4).

- `_lib.sh` — shared harness
Fails when: —


## Rules for adding a probe

Every file here keeps the contract `_lib.sh` documents:

1. Boot your own server; never assume one is running.
2. A server that never became ready is a **failure with the remedy**, never a silent skip.
3. Floor your own premises — an assertion block that produced no verdict fails the run
   (the vacuous-pass family; see `V1EndpointCatalogTests`).
4. Print the raw measured numbers, not just a verdict, so a doc claim can be re-checked
   against a run instead of re-argued.
5. No hardcoded model ids — read `GET /v1/models` and use a ready model.
6. An unfixed defect is a `NOTE` with the measurement, not a permanently red gate. Give it
   an opt-in flag so the day it is fixed the probe becomes its regression gate — cf.
   `OCOREAI_REQUIRE_PREFIX_REUSE=1` in `01-prefix-accounting.sh`.
7. **A refusal leg must name the field it blames.** Asserting only "400" lets a probe pass on
   an endpoint that is broken for a different reason: on `20-download-path-traversal.sh`'s first
   run the two "pre-existing validation" legs were **green** while every request died at
   `Coding key \`useLatest\` not found.` — a 400 arrived, just not for the field under test. So
   assert the field appears in the body (case-insensitively — refusals are prose: "Model
   identifier must not be empty"), and where the wire carries `error.param`, assert that too.
   A refusal that does not say what it refused is not evidence.

## Knobs

| Variable | Effect |
|---|---|
| `OCOREAI_BIN` | binary to probe (default: newest of `.build-clt/debug`, `.build/debug`, `.build/release`) |
| `OCOREAI_PROBE_PORT` | port to bind (default: free port) |
| `OCOREAI_READY_TIMEOUT` | **wall-clock** seconds to wait for `/health` (default 240). It is a time budget, not a poll count: one poll costs up to 4 s (its own 3 s curl deadline plus the 1 s sleep), and counting iterations instead spent ~4x the advertised window — measured 10-28, a "10 s" budget against a server that accepts and never answered took 38 s, and three probes at the CI window then overran the step bound that exists to name them. A failure prints both numbers (`in 13s wall (budget 10s)`) |
| `OCOREAI_PROBE_CURL_TIMEOUT` | deadline on `probe_api`'s requests and the SSE leg of `37` (default 180 s — sized for a local model's first token; CI's smoke step sets 60 because those probes download nothing). Class-L of `make audit` floors that every request site under `scripts/probes/` carries a `-m` |
| `OCOREAI_CI_HEARTBEAT` | CI seat only (`ci-step.sh`): seconds between `::notice::` lines carrying the probe's last log line (default 30). A step killed on its timeout leaves nothing else behind, and annotations are the one CI channel readable without a token |
| `OCOREAI_API_KEYS` | passed to the server; probes then send `Authorization: Bearer <first key>` like real clients |
| `OCOREAI_PROBE_MODEL_LIMIT` | how many ready models `03` cross-checks (default 2) |
| `OCOREAI_PROBE_PAD_UNITS` | length of the filler prompt in `01`/`02` (default 40 sentences) |
| `OCOREAI_PROBE_SLEEP_MS` | base duration for `21` (default 9000 — the three legs step down 1000 ms each so no two `(tool, args)` pairs are identical and the loop net cannot confound the timing legs) |
| `OCOREAI_PROBE_STEER_DELAY` | seconds `21` waits before injecting its steer (default 1.5 — after the request started, so the head-of-handler drain has already run and a fast steered turn can only come from the wake path) |
| `OCOREAI_REQUIRE_PREFIX_REUSE` | `1` turns the P1 measurement into a hard assertion |
| `OCOREAI_SESSION_POOL` | `0`/`false`/`off`/`no` starts the engine with no session pool — `17` uses it to reach the degraded lane on demand (memory pressure cannot be scheduled); the boot log must name it |
| `OCOREAI_ENGINE_BUSY_WAIT` | seconds a second request waits for the inference lock before it is refused with 429 + `Retry-After` (default 20, clamp 0–120; `0` restores fail-fast) — `29` sets 3 so a 512-token turn overruns the window and an 8-token turn fits inside it |
| `OCOREAI_PROBE_KEEP_LOGS` | `1` keeps the server log and prints its path |
