# Live probes

Executable evidence for claims about the HTTP surface. The rule they exist to serve is
AGENTS.md invariant 1 — *a claim is worth exactly the gate that goes red when it breaks* —
and the specific failure they fix is that this repo's live findings were produced by
throwaway scripts in temp dirs (`live24.py` on port 8124, the count-tokens triple on port
8157), so no measurement in `AGENTS.md` or `CHANGELOG.md` could be re-run by anyone after
the session that made it ended.

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

| Script | Question it answers | Fails when |
|---|---|---|
| `01-prefix-accounting.sh` | Does a session-pool HIT actually save a prefill, and does the server admit whether it did? | the wire claims `cached_tokens > 0` that the engine did not deliver, a HIT turn goes unaccounted, the dedupe path was never exercised, or `prefixReuse` on `/v1/models/:model/kv-cache` disagrees with the measured turns |
| `02-count-tokens-shapes.sh` | Can OpenAI *and* Anthropic clients size a request here? | any spec-legal shape 400/404s, an unlabelled count, same-text shapes disagreeing on one endpoint, the pre-flight counting **less** than the caller's own bytes (it sizes the assembled request, not just the payload), the `system` block dropping out of either endpoint's count, or a malformed body answering 200/500 |
| `03-capabilities-models-consistency.sh` | Does the discovery surface answer when a client follows it? | the endpoint index is thin or lists a route the live server 404s, a "ready" model rejects `/v1/count-tokens`, or a model/capability row omits `vlm`/`contextLength`/`available` |
| `04-multimodal-honesty.sh` | Does "can see / can hear / can speak" survive contact with the OS? | the status payload publishes verdicts without the permission/device facts behind them, a capture leg returns `success:true` with no bytes, a capture request blocks on a TCC dialog, empty text reports a successful speak, or a `vlm:true` model fails to answer an inline PNG |
| `05-hearing.sh` | Does 能听 survive contact with the OS, over the wire? — and does the server hold its own `ready` verdict to its word? |
  any refusal for speech arrives as a 500 or without `error_code`/`remediation`, the status payload claims `transcriptionStatus` without the `hearing` block behind it, `transcriptionStatus` and `hearing.verdict` disagree, a `ready` verdict is not backed by `probe: ok`, the two accepted body shapes answer differently for the same bytes, `response_format: text` answers as JSON, a remote `url` is fetched instead of refused, the endpoint index omits the route, or `--probe-hearing` claims success it did not measure |
| `06-chat-audio.sh` | Does `/v1/chat/completions` hear the `audio_url` it accepts, or drop it? |
  HTTP 200 without `audio_input` on a request that carried audio (the silent drop), a refusal without `error_code`/`remediation`, a payload fault answered 503 instead of the 400 the shared status table assigns it, a refusal costing model work, stream and non-stream answering the same audio turn differently, the answer not echoing an utterance the disclosure claims was transcribed, or the endpoint index being silent about what happens to `audio_url` |
| `07-anthropic-blocks.sh` | Does `/v1/messages` honour, or blank, the content blocks a real SDK sends? |
  a spec-legal block array answering 200 while `usage.input_tokens` sits at or under the plain-string baseline (the turn was blanked), a refusal that does not name the block type, `[{type:text}]` itself failing, a 200 with empty content next to an image, or a run whose baseline is unusable (it aborts instead of issuing verdicts built on a missing premise) |
| `08-video-honesty.sh` | Does `/v1/chat/completions` see the video it accepts, keep the bytes its transcript cites, and name what it cannot open? |
  a clip answered 200 without naming its colour or without a prompt-token jump (accepted but never seen), the first plain-text turn after a video turn failing (the transcript cites bytes that were deleted at request end), the spool empty while a live conversation still cites the clip, or a media part naming a missing file answered 200 or 5xx instead of 4xx with `error_code` + `remediation`. A 5xx is never counted as an honest refusal — the first version of this file did exactly that and reported PASS on a broken server |
| `09-malformed-request-honesty.sh` | Can one bad number in a request body kill the server? | a negative or out-of-range `max_tokens`/`temperature` traps the process, or a payload fault answers 5xx/200 instead of the 4xx the shared status table assigns it, or the error omits the offending field |
| `10-sampling-knob-delivery.sh` | Does the engine actually do what the accepted sampling knobs say? | a knob is decoded, cascaded and logged yet changes nothing measurable in the output — accepted, and dead on the last hop into the engine |
| `11-tool-call-delivery.sh` | Does a declared tool come back as a call the client can run? | `tools[]` yields prose instead of `tool_calls`, declaring a tool costs the answer (forcing gated on presence), `tool_choice:"none"` still calls, SSE and JSON disagree, or `toolCallDelivery` says `parsed` without evidence naming the tool |
| `12-json-mode-delivery.sh` | Does `response_format` deliver JSON with something inside it? | `json_object` fails to parse or disagrees with `json_schema{"type":"object"}`, a schema naming required keys returns none, or a caller that pins zero properties stops getting `{}` |
| `13-anthropic-tool-delivery.sh` | Does the Anthropic face deliver what its wire promises — a call, a result continuation, thinking, the same prompt the OpenAI face sends, and a steer? | a demanded call arrives as `end_turn` prose instead of a `tool_use` block (id/name, `input` as an object); the SSE stream opens a block without naming it or leaks the call dialect as text; `message_delta` carries no `tool_use` reason; a declaration without demand loses the answer; `tool_choice:{"type":"none"}` still calls; the shared `toolCallDelivery` gauge stays unmoved; `thinking` never reaches `InferenceOptions` (the assembly line must read `enableReasoning=on/off/default`) or `disabled` resolves to ON; `budget_tokens ≥ max_tokens` not refused by name; a `tool_result` turn that re-dispatches the call or ignores the result; the two faces assembling or reporting different numbers for one request; `count_tokens` drifting from `usage.input_tokens`; a queued steer swallowed on this face; one declared tool inflating the system message |
| `14-parallel-and-terminal-word.sh` | Does a tool turn tell the truth about itself — how many calls it may run, whether the budget cut it, and which chunk is the last? | `parallel_tool_calls:false` / `disable_parallel_tool_use:true` still delivers two calls; a turn the budget chopped says `tool_calls` instead of `length` (`completion_tokens == max_tokens`); an SSE delta carries a `finish_reason` or more than one chunk does; a delivered call ends with `stop`; OpenAI's nested `tool_choice` answers 400 `Coding key \`name\` not found.` while an unknown word answers 200; a refusal that does not name `tool_choice`. §7 pins that a turn obeys its own `max_tokens` even when the turn before it on the same session was grammar- or tool-constrained (regression pin for the 10-19 pooled-session leak, fixed 10-20) |
| `15-system-instruction-delivery.sh` | Does the caller's `system`/`developer` text reach the model on both faces, and does rewriting it invalidate the cache that was rendered without it? |
  a ~1k-char `system` message that leaves `usage.prompt_tokens` at the no-system baseline (accepted, counted by the disclosure line, never delivered); `developer` costing different tokens than `system`; the two faces disagreeing on identical content by more than 8 tokens; the disclosure showing two system messages (`[system,system,…]`) or its `systemChars=` failing to grow with the client text; unchanged instructions not reusing the prefix (which would make the changed-instructions half vacuous); changed instructions still reusing the pooled session; or a cache dropped without its reason logged at info level |
| `16-tool-declaration-duplication.sh` | Does one declared tool reach the model once, or twice — and who writes it? | no `Tool prose <mode> for <model>` line at all (the load-time template measurement never ran); mode `injectedUnmeasured` on a loaded model (XFAIL with numbers); under `skippedTemplateRenders` any `## Tool: block(s) written > 0`, or the delivered `prompt_tokens` failing to grow ≥16 for a declared tool (the tool never arrived); under `injectedTemplateIgnores` zero blocks written (nothing declared it); the delivered delta failing to scale with the surface; or no `tool_calls` on the premise turn, which makes every later section vacuous. Measured 10-20 post-fix: 0 blocks written, +95 delivered tokens for one tool (+52 per extra tool) |
| `_lib.sh` | shared harness | — |

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

## Knobs

| Variable | Effect |
|---|---|
| `OCOREAI_BIN` | binary to probe (default: newest of `.build-clt/debug`, `.build/debug`, `.build/release`) |
| `OCOREAI_PROBE_PORT` | port to bind (default: free port) |
| `OCOREAI_READY_TIMEOUT` | seconds to wait for `/health` (default 240) |
| `OCOREAI_API_KEYS` | passed to the server; probes then send `Authorization: Bearer <first key>` like real clients |
| `OCOREAI_PROBE_MODEL_LIMIT` | how many ready models `03` cross-checks (default 2) |
| `OCOREAI_PROBE_PAD_UNITS` | length of the filler prompt in `01`/`02` (default 40 sentences) |
| `OCOREAI_REQUIRE_PREFIX_REUSE` | `1` turns the P1 measurement into a hard assertion |
| `OCOREAI_PROBE_KEEP_LOGS` | `1` keeps the server log and prints its path |
