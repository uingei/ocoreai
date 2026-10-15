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
| `02-count-tokens-shapes.sh` | Can OpenAI *and* Anthropic clients size a request here? | any spec-legal shape 400/404s, an unlabelled count, shapes disagreeing past tolerance, or a malformed body answering 200/500 |
| `03-capabilities-models-consistency.sh` | Does the discovery surface answer when a client follows it? | the endpoint index is thin or lists a route the live server 404s, a "ready" model rejects `/v1/count-tokens`, or a model/capability row omits `vlm`/`contextLength`/`available` |
| `04-multimodal-honesty.sh` | Does "can see / can hear / can speak" survive contact with the OS? | the status payload publishes verdicts without the permission/device facts behind them, a capture leg returns `success:true` with no bytes, a capture request blocks on a TCC dialog, empty text reports a successful speak, or a `vlm:true` model fails to answer an inline PNG |
| `05-hearing.sh` | Does 能听 survive contact with the OS, over the wire? — and does the server hold its own `ready` verdict to its word? |
  any refusal for speech arrives as a 500 or without `error_code`/`remediation`, the status payload claims `transcriptionStatus` without the `hearing` block behind it, `transcriptionStatus` and `hearing.verdict` disagree, a `ready` verdict is not backed by `probe: ok`, the two accepted body shapes answer differently for the same bytes, `response_format: text` answers as JSON, a remote `url` is fetched instead of refused, the endpoint index omits the route, or `--probe-hearing` claims success it did not measure |
| `06-chat-audio.sh` | Does `/v1/chat/completions` hear the `audio_url` it accepts, or drop it? |
  HTTP 200 without `audio_input` on a request that carried audio (the silent drop), a refusal without `error_code`/`remediation`, a payload fault answered 503 instead of the 400 the shared status table assigns it, a refusal costing model work, stream and non-stream answering the same audio turn differently, the answer not echoing an utterance the disclosure claims was transcribed, or the endpoint index being silent about what happens to `audio_url` |
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
