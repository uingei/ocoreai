# Live probes

Executable evidence for claims about the HTTP surface. They serve AGENTS.md invariant 1 —
*a claim is worth exactly the gate that goes red when it breaks* — and fix the failure they
were born from: live findings used to be throwaway scripts in temp dirs, so no measurement
could be re-run once the session that made it ended.

`V1EndpointCatalogTests` and friends pin the wire at **compile time**. These probes pin it
against a **running server**, which is the only place a route can be registered in the
router and still 404 at runtime (middleware, ordering, a handler that throws).

## Running

```bash
swift build --scratch-path .build-clt --disable-sandbox   # or: make build
bash scripts/probes/run.sh            # all probes, each boots its own server
bash scripts/probes/run.sh 02        # just one
```

**Needs a real Metal device.** Inside the agent sandbox MLX logs
`[metal::load_device] No Metal device available`, the engine never reaches ready, and every
probe fails at boot. That is the harness, not a regression — run them unsandboxed, the same
route `make test-clt` uses (see `docs/agent/build-gate-reality.md`).

Each probe boots its own `ocoreai serve` on an OS-assigned free port, so runs are
repeatable and never ride on a GUI instance that happens to be open. Runtime is dominated by
model load.

## What is here

Each entry below is one probe's contract: the question it asks, then every assertion it
makes. A clause that stops being asserted turns into a probe that passes for the wrong
reason, so this list is what to read when a probe goes quiet. Round-by-round forensics for
each defect named here lives in `CHANGELOG.md`, at the dated round that found it.

- `01-prefix-accounting.sh` — Does a session-pool HIT actually save a prefill, and does the server admit whether it did?
Fails when: the wire claims `cached_tokens > 0` that the engine did not deliver, a HIT turn goes unaccounted, the dedupe path was never exercised, or `prefixReuse` / `reuseRefusals` on `/v1/models/:model/kv-cache` disagree with the measured turns (including which rule refused a warm session, and the cold turn whose head was already resident in another
    conversation), or the engine's `Prefix cache reused C of T` line disagrees digit-for-digit with that same turn's `cached_tokens`/`prompt_tokens` (the whole-vs-part tie that stayed silent for exactly as long as the wire published the prefilled suffix under the prompt's name), or one streaming turn's `prompt_tokens` and the `/metrics` prompt counter move by
    different amounts (§E: the wire was accounted on 10-21 and the counter was not, so cost and capacity were read from a number ~36x too small)

- `02-count-tokens-shapes.sh` — Can OpenAI *and* Anthropic clients size a request here?
Fails when: any spec-legal shape 400/404s, an unlabelled count, same-text shapes disagreeing on one endpoint, the pre-flight counting **less** than the caller's own bytes (it sizes the assembled request, not just the payload), the `system` block dropping out of either endpoint's count, or a malformed body answering 200/500

- `03-capabilities-models-consistency.sh` — Does the discovery surface answer when a client follows it?
Fails when: the endpoint index is thin or lists a route the live server 404s, a "ready" model rejects `/v1/count-tokens`, or a model/capability row omits `vlm`/`contextLength`/`available`

- `04-multimodal-honesty.sh` — Does "can see / can hear / can speak" survive contact with the OS?
Fails when: the status payload publishes verdicts without the permission/device facts behind them, a capture leg returns `success:true` with no bytes, a capture request blocks on a TCC dialog, empty text reports a successful speak, or a `vlm:true` model fails to answer an inline PNG

- `05-hearing.sh` — Does 能听 survive contact with the OS, over the wire?
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

- `12-json-mode-delivery.sh` — Does `response_format` deliver JSON with something inside it?
Fails when: `json_object` fails to parse or disagrees with `json_schema{"type":"object"}`, a schema naming required keys returns none, or a caller that pins zero properties stops getting `{}`

- `13-anthropic-tool-delivery.sh` — Does the Anthropic face deliver what its wire promises — a call, a result continuation, thinking, the same prompt the OpenAI face sends, and a steer?
Fails when: a demanded call arrives as `end_turn` prose instead of a `tool_use` block (id/name, `input` as an object); the SSE stream opens a block without naming it or leaks the call dialect as text; `message_delta` carries no `tool_use` reason; a declaration without demand loses the answer; `tool_choice:{"type":"none"}` still calls; the shared
    `toolCallDelivery` gauge stays unmoved; `thinking` never reaches `InferenceOptions` (the assembly line must read `enableReasoning=on/off/default`) or `disabled` resolves to ON; `budget_tokens ≥ max_tokens` not refused by name; a `tool_result` turn that re-dispatches the call or ignores the result; the two faces assembling or reporting different numbers for
    one request; `count_tokens` drifting from `usage.input_tokens`; a queued steer swallowed on this face; one declared tool inflating the system message

- `14-parallel-and-terminal-word.sh` — Does a tool turn tell the truth about itself — how many calls it may run, whether the budget cut it, and which chunk is the last?
Fails when: `parallel_tool_calls:false` / `disable_parallel_tool_use:true` still delivers two calls; a turn the budget chopped says `tool_calls` instead of `length` (`completion_tokens == max_tokens`); an SSE delta carries a `finish_reason` or more than one chunk does; a delivered call ends with `stop`; OpenAI's nested `tool_choice` answers 400 `Coding key
    \`name\` not found.` while an unknown word answers 200; a refusal that does not name `tool_choice`. §7 pins that a turn obeys its own `max_tokens` even when the turn before it on the same session was grammar- or tool-constrained (regression pin for the 10-19 pooled-session leak, fixed 10-20)

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
    `AuthRoutePolicy.publicPaths`), and `DELETE /sessions/:id` with a **user** key → 403 `adminKeyRequired` (never a silent 2xx); last, the public set measured on the wire must equal README.md's documented list. A route that never answered counts as a contradiction, never as "open". Measured 10-20: **12 passed / 0 failed / 4 measured**; red sample — adding
    `/v1/perception` to `publicPaths` fails 3 assertions (keyless 200, and README's 7 paths vs the wire's 8)

- `19-instruction-change-cost.sh` — When the caller's instructions change mid-conversation, are the new ones obeyed — and what does that cost?
Fails when: instructions A still obeyed after B is sent (the stale-instruction defect `instructionsMatch` exists to prevent), a same-instruction warm turn reporting `cached_tokens == 0` (the premise: without reuse there is no baseline to price), the wire's `cached_tokens` disagreeing with the number the engine logged for that conversation, or the changed
    turn claiming the whole prompt was reused when the old prefix described the old instructions. Measured 10-20: turn1 `prompt=1456 cached=0` · same-instruction warm `prompt=12 cached=1458` · changed-instruction `prompt=1438 cached=0` — refuse-and-rebuild, priced at one full re-prefill (the owner-call in AGENTS.md § Open, with codex #53872's
    supersede-marker as the alternative)

- `20-download-path-traversal.sh` — Does a model id get to choose where the cache lives?
Fails when: a traversing `model`/`revision` not answering 400 with `error.param` naming the field and echoing the value; a refusal arriving as `text/event-stream` (the stream opened anyway, so the client's SDK already committed to a download); the path the id *would* have joined showing up on disk; a legal `org/name` being refused by shape (the fix must not
    eat real downloads); an SSE stream that emits no `data:` line; either pre-existing refusal losing the field it blames; or the server not answering `/health` afterwards. It also caught the defect it now gates: before the fix every body answered `400 Coding key \`useLatest\` not found.` — and the two "pre-existing validation" legs passed on that run, which
    is why every refusal leg here now asserts *which* field it blamed

- `21-sleep-steer-wake.sh` — Does input for *this* conversation end `clock.sleep`'s wait, does the injected text reach the model in that same turn, and does another conversation's input leave the wait alone?
Fails when: a control turn that never spent its requested duration (without a real sleep, "the steered turn was fast" certifies nothing); a steer accepted with `queued_count>=1` while the turn still runs the full duration (no early wake); a steered reply missing `[mid-turn user steering]` (accepted but never delivered into the turn); `Sleep completed.` on a
    turn that was actually woken, or `interrupt` missing when the control proved the checkpoint echoes tool output; a steer aimed at a *different* session ending this session's sleep (cross-session wake — the same leak `SessionIsolationTests` closed on the pool side); `sleep` absent from `/v1/tools`; a `/v1/tools` scan that parsed fewer than 5 names (vacuous
    premise); or any response with `cached_tokens > prompt_tokens` (a breakdown larger than the whole it belongs to). Measured 10-21: control 10807 ms for 9000 ms asked · steered 2651 ms for 8000 ms (`sleep` itself 1086 ms) · foreign-steered 8628 ms for 7000 ms · usage pairs 957/987, 957/1006, 957/987

- `22-session-memory-identity.sh` — Does one `session_id` (and one Anthropic `metadata.session_id`) become one session in memory, does a message row hold its own tokens, and does a re-sent history get stored once?
Fails when: a conversation key splitting into a second `sessions` row (measured before the fix: 3 turns ⇒ 3 rows of `message_count=2`), the turns not accumulating in that one row, a user row costing more than its own content (before the fix: 34 characters stored as `token_count: 705` = the turn's whole prompt), or the session total exceeding 1.5× one
    turn's `prompt_tokens` — the signature of charging history again every turn against the 128k prune rule

- `23-lora-seam-honesty.sh` — Does one LoRA request take the box down, and does an id `/v1/models` advertises ever reach the engine?
Fails when: silence or a dead server on `/v1/models/evaluate` or `/v1/models/train` (measured 10-21 before the fix: legal datasets killed the process — `Trace/BPT trap: 5`, `Swift runtime failure: type cast failed` inside upstream `LoRATrain.loss`'s `model as! any LLMModel`, `LoraTrain.swift:165` at pin `48114eedf`); a refusal that does not name the
    capability it needs; a train stream that opens and then cuts without an `error` chunk; an SSE error carrying no message; the box not answering `/health`, or a normal chat turn losing its code word, afterwards. **Gated hard since the same session** (`HubReachability`): an unresolvable id must now be answered within 30 s — HTTP 404 when a hub said the repo
    is not there, HTTP 503 when a hub could not be asked, naming the id in both, and the 503 also naming both hubs plus the `HF_ENDPOINT` lever. Measured 10-21 post-fix: both legs **8 s / HTTP 503**, `/health` and the chat code word alive afterwards (`10 passed, 0 failed, 4 measured, 1 known-open`; pre-fix this same probe carried 2 known-open silences). The
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
    then the flip — kill the stub, send the *same* id, and it must come back HTTP 503 naming that id inside 15 s. Two verdicts from one id, decided by what the hub said, not by how long the caller waited. Measured 10-21: `7 passed, 0 failed, 3 measured` — the stub log shows `/api/models/<repo>` followed by `/revision/main?` and `/tree/main?recursive=true`
    (the request went through to the hub client), and the same id is refused in 0 s once the hub is gone.

- `27-edited-history-honesty.sh` — When a caller rewrites the past, does the answer come from the history it actually sent — and what does that turn pay?
Fails when: the replaced fact appearing in the reply after an edited resend (the leak `canReusePooledSession` refuses to answer from, and now the leak the KV trim must not reintroduce — until this probe it was a rule believed, not observed); an appended warm turn that reuses nothing (no baseline ⇒ "this edit costs X" certifies nothing); the edited turn
    re-prefilling everything (`cached_tokens == 0` — the fork or the reserve silently stopped working and only latency would notice); `prompt_tokens < cached_tokens`, or the edited turn claiming more reuse than the appended turn got (a breakdown larger than its whole); and either half of the ledger lying — `historyDiverged > 0` books a rewound turn as
    refused-and-rebuilt, or `prefixReuse` disagreeing with the usage field the client saw. Measured 10-21 (gemma-4-e2b-it-4bit, one session, 4 turns): turn1 `708/0` · turn2 `732/710` · turn3 appended `758/734` · turn4 edited `758/718` and answers the NEW code word with the OLD one absent (`14 passed, 0 failed, 4 measured, 0 known-open`). Pre-fix the same turn

- `28-single-instance-refusal.sh` — When another instance holds the lock, does the refused `serve` actually leave?
Fails when: instance B stays alive until someone signals it (a refusal the caller must kill is a hang wearing one), exits 0
    (a startup that never happened must not look clean to launchd), or its log omits the holder pid / `OCOREAI_ALLOW_MULTI_INSTANCE`.

- `29-engine-busy-429.sh` — When the engine is occupied, does the wire say 429 + `Retry-After`, or 500?
Fails when: the capacity refusal is a 500 `app_error`, lacks `engine_busy`/`rate_limit_error` or `Retry-After`, the turn in flight is
    disturbed, or a short overlap is refused instead of waited out. Leg 1 gates on the long turn's first SSE token: lock order is not
    HTTP arrival order.

- `30-repeated-prompt-delivery.sh` — Ask the same thing twice: does the second answer arrive?
Fails when: a one-token `.eos` turn lacks its `Degenerate generation` line (leg 4). Its run-to-run
    collapse rate was explained on 10-23 — the prompt was not byte-identical across boots (probe 32);
    the numbers and the dead mechanism stories are in `CHANGELOG.md`.
- `31-client-abort-cancellation.sh` — When a client walks away mid-turn, does the engine stop?
Fails when: a turn whose client left still leaves a completion record with >8 tokens XFAIL-open until fixed:
    nothing detects disconnect (no HB liveness handle). Leg 1 = positive control.

- `32-prompt-byte-determinism.sh` — Same request, different boot: same prompt bytes?
Fails when: one shape yields more than one `promptHash` across boots (a Dictionary/Set or unsorted JSON
    reached the prompt), or declaring a tool changes nothing at all. No unit test can see this class:
    Swift fixes the hash seed per process.

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
| `OCOREAI_READY_TIMEOUT` | seconds to wait for `/health` (default 240) |
| `OCOREAI_API_KEYS` | passed to the server; probes then send `Authorization: Bearer <first key>` like real clients |
| `OCOREAI_PROBE_MODEL_LIMIT` | how many ready models `03` cross-checks (default 2) |
| `OCOREAI_PROBE_PAD_UNITS` | length of the filler prompt in `01`/`02` (default 40 sentences) |
| `OCOREAI_PROBE_SLEEP_MS` | base duration for `21` (default 9000 — the three legs step down 1000 ms each so no two `(tool, args)` pairs are identical and the loop net cannot confound the timing legs) |
| `OCOREAI_PROBE_STEER_DELAY` | seconds `21` waits before injecting its steer (default 1.5 — after the request started, so the head-of-handler drain has already run and a fast steered turn can only come from the wake path) |
| `OCOREAI_REQUIRE_PREFIX_REUSE` | `1` turns the P1 measurement into a hard assertion |
| `OCOREAI_SESSION_POOL` | `0`/`false`/`off`/`no` starts the engine with no session pool — `17` uses it to reach the degraded lane on demand (memory pressure cannot be scheduled); the boot log must name it |
| `OCOREAI_ENGINE_BUSY_WAIT` | seconds a second request waits for the inference lock before it is refused with 429 + `Retry-After` (default 20, clamp 0–120; `0` restores fail-fast) — `29` sets 3 so a 512-token turn overruns the window and an 8-token turn fits inside it |
| `OCOREAI_PROBE_KEEP_LOGS` | `1` keeps the server log and prints its path |
