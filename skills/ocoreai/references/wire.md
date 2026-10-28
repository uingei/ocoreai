# The wire, as this server enumerates it

> Generated from a live `GET /v1/capabilities` on 10-28 (the response's own `endpoints` array, which
> `V1EndpointCatalog` builds and `V1EndpointCatalogTests` fails the build over when router and index
> disagree). Re-generate instead of trusting this table:
> `curl -s http://127.0.0.1:8080/v1/capabilities | python3 -c 'import json,sys;[print(e["method"],e["path"],e["auth"],sep="\t") for e in json.load(sys.stdin)["endpoints"]]'`
> — a hand-copied route list is the drift class this note exists to avoid.

## Endpoint index (34 rows: method, path, auth as served)

| method | path | auth | note |
|---|---|---|---|
| `GET` | `/health` | `public` | Process liveness + engine pool summary |
| `GET` | `/ready` | `public` | Readiness: ready when no session is generating |
| `GET` | `/v1/models` | `public` | Model inventory (vlm, contextLength, defaultModel) |
| `GET` | `/v1/tools` | `public` | Tool registry with JSON schemas |
| `GET` | `/v1/capabilities` | `public` | Backend matrix + tokenizer + instruction budget + this index |
| `GET` | `/v1/stats` | `public` | Structured inference counters and gauges |
| `GET` | `/v1/perception` | `key` | Persistent-perception gauge snapshot |
| `GET` | `/metrics` | `public` | Prometheus text exposition |
| `POST` | `/v1/messages` | `key` | Anthropic Messages API (stream + non-stream; text/image/tool_result blocks carried, any other block type refused by name) |
| `POST` | `/v1/messages/count_tokens` | `key` | Anthropic token pre-flight for a message list |
| `POST` | `/v1/steer` | `key` | Mid-turn steer: tool boundary of the live turn, else head of the next |
| `POST` | `/v1/chat/completions` | `key` | Chat completion (stream + non-stream, tools, structured output; audio_url is heard to text or refused, never dropped) |
| `POST` | `/v1/completions` | `key` | Legacy text completion |
| `POST` | `/v1` | `key` | Auto-route: prompt -> completions, messages -> chat |
| `POST` | `/v1/count-tokens` | `key` | Token count for prompt / input / messages |
| `POST` | `/v1/embeddings` | `key` | Text embeddings |
| `POST` | `/v1/models/train` | `key` | Start a fine-tune run for a model |
| `POST` | `/v1/models/evaluate` | `key` | Evaluate a model against a suite |
| `GET` | `/v1/models/:model/sampling` | `key` | Runtime sampling configuration (a `:model` id containing `/` must be percent-encoded as %2F — verbatim ids 404) |
| `PATCH` | `/v1/models/:model/sampling` | `admin` | Hot-swap sampling parameters (a `:model` id containing `/` must be percent-encoded as %2F — verbatim ids 404) |
| `DELETE` | `/v1/models/:model/sampling` | `admin` | Reset one model's sampling defaults (a `:model` id containing `/` must be percent-encoded as %2F — verbatim ids 404) |
| `DELETE` | `/v1/models/sampling` | `admin` | Reset all sampling defaults |
| `GET` | `/v1/models/:model/kv-cache` | `key` | Planned KV cache topology, capacity disposition, and the measured dispositions — prefix reuse, tool-declaration prose, and which reuse rule turned a warm session away (a `:model` id containing `/` must be percent-encoded as %2F — verbatim ids 404) |
| `POST` | `/v1/models/download` | `key` | Fetch a model into the local cache — `model` is a relative `org/name` (absolute paths and `..` are refused 400 naming the field; `provider` hf/mscope, `revision`/`useLatest` optional) |
| `POST` | `/v1/audio/transcriptions` | `key` | Speech to text, on-device (multipart `file`, or JSON `audio` base64 / `url` file://; `model` and `prompt` accepted and not used by the engine; `verbose_json` and timestamps refused — refusals name the axis: permission, locale, or engine) |
| `POST` | `/v1/multimodal/capture` | `key` | Camera / microphone / screen capture (`success: true` only when bytes came back; the mic is two-phase — first call starts, second returns the sample) |
| `POST` | `/v1/multimodal/speak` | `key` | Text-to-speech (needs speakerEnabled and at least one installed voice) |
| `POST` | `/v1/multimodal/status` | `key` | Multimodal toggles + measured permissions, device/voice counts, screen delivery evidence (ready needs a captured frame), per-channel ready/blocked/unknown/unsupported verdicts and reasons |
| `POST` | `/mcp` | `key` | MCP JSON-RPC (single message per request) |
| `GET` | `/sessions` | `key` | List stored sessions |
| `DELETE` | `/sessions/:id` | `admin` | Delete one session |
| `GET` | `/sessions/:id/memory` | `key` | Hot window (recent messages) of a session |
| `GET` | `/sessions/search` | `key` | FTS5 search over session history |
| `GET` | `/skills` | `key` | Installed skills |

## Capability rows as served (name → available, and the server's own words for why not)

- `agent_loop` — `available` — Tool + turn + recover loop, all 4 OS tiers
- `mlx_inference` — `available` — MLX (Metal GPU) on all 4 OS tiers (14/17, 15/18, 26/26, 27/27)
- `foundationmodels` — `not available` — Requires macOS 26+ / iOS 26+ with FoundationModelsIntegration trait — not on this build
- `coreai_ane` — `not available` — canImport(CoreAI) false on this target (framework not in SDK)
- `local_stt` — `available` — 26+ tier floor only — whether THIS box transcribes is measured (permission + locale + out-of-process engine probe) in `hearing` on POST /v1/multimodal/status; speech enters HTTP at POST /v1/audio/transcriptions. Measured here: supportsOnDeviceRecognition can report true while the engine traps, so no ASR call is made without that measurement
- `tts_speech` — `available` — AVSpeechSynthesizer output is tier-live here; whether this box can talk (installed-voice count) is measured on POST /v1/multimodal/status
- `video_generation` — `not available` — Requires macOS 27 / iOS 27
- `mcp_stdio` — `available` — Subprocess MCP stdio transport — macOS only (no Process on iOS)
- `screenshot_capture` — `available` — macOS tier floor only — whether THIS box has produced a frame is measured as screenStatus/screenDelivery on POST /v1/multimodal/status, and GET /v1/capabilities degrades this row from that record (a ScreenCaptureKit grant is not a frame: measured 10-15 authorized + display present, capture still failed to start)
- `model_fidelity` — `not available` — Model-summarized numbers are NOT trustworthy on default small models (live-verified 0919): 1.8B reported 24582 B for a 6746 B file and claimed full success; 4B reported a real value (9917 B, that file exists) but picked the wrong 'largest' file (true max 254974 B) from a mis-sorted sort. Treat every number you compute or pick out of tool output as unverified: re-derive it with a second independent command and cross-check before stating it; if a check fails, say so rather than reporting success.
- `tool_call_delivery` — `not available` — not_observed — no tool-declaring turn has completed here yet, so this says nothing about whether the models can call functions; per-model verdicts on GET /v1/models (`tool_call_delivery`)
- `video_input` — `not available` — not_observed — no completed turn carrying video has run here yet, so this says nothing about whether the models can see video; per-model verdicts on GET /v1/models (`video_input`)

## Shapes worth pinning before you parse them

Measured on the scripted lane (no weights resident), so they are contract facts, not model behaviour:

- `GET /health` → `{"status":"ok","timestamp":…,"engineSummary":{"loadedModels":…,"activeSessions":…,
  "gpuCacheGB":…,"modelIds":[…],"specializedModels":…}}`
- `GET /ready` → `{"status":"ready","loadedModels":…,"activeSessions":…,"timestamp":…}`
- `GET /v1/models` → `{"object":"list","data":[{id, object, ownedBy, state, contextLength, vlm,
  weightsDir, reasoningEffort, toolCallDelivery, videoInput}]}` — `data` is empty on a machine with no
  cached checkpoint, so **assert structure here and model rows only where a model is ready** (that split
  is exactly how `scripts/probes/39-skill-contract-exec.sh` tiers its assertions).
- `GET /v1/tools` → `{"object":"list","data":[{"type":"function","function":{name, description,
  parameters}}]}` (40 rows today — the number `AGENTS.md` quotes and probe 37 re-reads from a live
  server, so a tool that stops registering goes red there)
- `GET /v1/capabilities` → `{version, arch, os, engineBackend, tokenizerBackend, capabilities[],
  instructionBudget{maxBytes, injectedBytes, docCount, truncatedDocs, droppedDocs,
  docs[{label, bytesTotal, bytesInjected, state}]}, endpoints[]}` — `scripted` / `real` as measured
  here. `instructionBudget.docs[].state` is `whole` | `truncated` | `dropped`, and `label` is
  `<root>/…`: the row says whether the project instructions in your prompt survived the byte cap, and
  no absolute path is served because the endpoint is public.
- `POST /v1/chat/completions` → `{id, object:"chat.completion", created, model, choices[{index,
  message{role,content,tool_calls?}, finish_reason}], usage{prompt_tokens, completion_tokens,
  total_tokens}}`; `prompt_tokens_details` appears **only** when prefix reuse was measured.
- `POST /v1/messages` → `{id, type:"message", role, model, content[{type:"text",text}],
  stop_reason:"end_turn", usage{input_tokens, output_tokens}}`; cache-creation keys stay absent when
  nothing was created.
- `POST /v1` → auto-routes: a `prompt` answers `object:"text_completion"`, `messages` answers
  `chat.completion` (the client does not have to know which).
- `POST /v1/count-tokens` → `{model, prompt_tokens, tokenizer_backend}`;
  `POST /v1/messages/count_tokens` → `{input_tokens, tokenizer_backend}`.
- `GET /sessions` → `[{id, model_id, message_count, token_count, created_at, updated_at, ttl_days}]`.
- `GET /skills` → `["file","memory","search","terminal"]` as measured.

## Errors carry their remedy

- Unknown route → `404` `{"error":{"type":"app_error","code":404,"message":"Route GET /x does not exist.
  Enumerate models via GET /v1/models and endpoints via GET /v1/capabilities","details":{method,path}}}`.
- A bad request → `400` `{"error":{"type":"invalid_request_error","message":"Invalid request: Missing 'q'
  query parameter","code":400}}` — measured on `GET /sessions/search` without `q`.
- Key required → `401` naming both accepted header forms; `/health` still answers `200`.
- A failing MCP server's **stderr travels inside the refusal**, and a knob the loaded checkpoint cannot
  honour is refused with the remedy named (`ReasoningEffortHonestyTests`, probes 04/26/38) — the pattern:
  never 200 with nothing in it.

