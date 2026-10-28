---
name: ocoreai
description: Drive ocoreai — one binary that is both a local agent and a local inference server for open models on Apple silicon (MLX Metal + CoreAI, offline, no API key). Covers starting the bridge, asking the server what it actually measured, generating through the OpenAI and Anthropic wires, running the tool loop inside its approval boundary, and the honesty fields that say what is NOT measured.
triggers:
  - ocoreai
  - local model server apple silicon
  - offline coding agent
  - mlx inference server
  - openai compatible local server
  - anthropic compatible local server
  - on-device tool calling
  - no api key inference
---

# ocoreai — driving a local model agent from another harness

## 1. What this is, and when to use it

One Swift binary on macOS (Apple Silicon) that is at the same time:

- **an inference server** — OpenAI-compatible (`/v1/chat/completions`, `/v1/completions`,
  `/v1/embeddings`, `/v1/models`) *and* Anthropic-compatible (`/v1/messages`,
  `/v1/messages/count_tokens`), on loopback, no key, no network egress;
- **an agent** — its own tool loop, durable sessions (SQLite + FTS5), and Apple-native I/O (screen,
  camera, speech) that it only uses inside an approval boundary it publishes.

Reach for it when the job must run **offline, on this machine, with an open checkpoint**. Do not treat it
as a cloud proxy: there is no upstream behind it, and it will tell you when it cannot do something.

The load-bearing idiom, and the whole reason this file exists: **ask the server what it measured before
you assume a capability.** Every surface that describes a capability also says how it knows, and answers
`not_observed` rather than staying silent.

## 2. Start the bridge

```bash
swift build -c release && swift run ocoreai serve      # or: .build/release/ocoreai serve
```

`serve` is headless engine + HTTP bridge, default `127.0.0.1:8080`; SIGTERM or stdin-EOF shuts it down
gracefully. `Sources/ocoreai/Core/CLIMode.swift:35-49` is the authority for the environment list
(`OCOREAI_HOST`, `OCOREAI_PORT`, `OCOREAI_ENABLE_HTTP`, `OCOREAI_API_KEYS`, `OCOREAI_DATA_DIR`,
`OCOREAI_MODELS_DIR`). Two facts that change how you configure a client:

- **Loopback is open; anything else is refused, not exposed.** Binding a non-loopback host without
  `OCOREAI_API_KEYS` fails at startup (`Sources/ocoreai/Middleware/ServerAuthGate.swift:107`).
- **Auth is per route, and the server publishes the answer.** `GET /v1/capabilities` → `endpoints[]`
  carries an `auth` column per route (`public` vs key vs admin); the public set is
  `AuthRoutePolicy.publicPaths` (`Sources/ocoreai/Middleware/AuthMiddleware.swift:165`) and
  `PATCH`/`DELETE` additionally want an admin key. Read the column instead of hard-coding the list.

  ```bash
  OCOREAI_API_KEYS=sk-local .build/release/ocoreai serve &
  curl -s -X POST -H "Authorization: Bearer sk-local" -H 'Content-Type: application/json' \
    --data '{"model":"<id from /v1/models>","messages":[{"role":"user","content":"hi"}]}' \
    http://127.0.0.1:8080/v1/chat/completions
  ```

  Unkeyed against a generating route returns `401` naming both accepted header forms, and `/health`
  still answers `200` — asserted by `scripts/probes/39-skill-contract-exec.sh` §1b.

## 3. Discover before you assume

<!-- exec: GET /health 200 | "status":"ok" | engineSummary | loadedModels -->
<!-- exec: GET /v1/models 200 | "object" | "data" -->
<!-- exec: GET /v1/capabilities 200 | engineBackend | tokenizerBackend | endpoints | capabilities | instructionBudget -->
<!-- exec: GET /v1/tools 200 | "object" | "function" | parameters -->
<!-- exec: GET /skills 200 | "terminal" | "file" -->
<!-- exec: GET /v1/stats 200 | totalRequests | avgTTFBSeconds -->
<!-- exec: POST /v1/multimodal/status {} 200 | cameraStatus | hearing -->
<!-- exec: GET /v1/this-route-does-not-exist 404 | does not exist | Enumerate -->

- **`GET /v1/capabilities`** is the one call that tells you the truth about this process: `engineBackend`
  (`mlx` | `coreai` | `scripted`), `tokenizerBackend` (`real` | `heuristic`), `capabilities[]` with a
  `note` giving the reason for every `available: false`, and `endpoints[]` — the machine-readable index
  of the whole HTTP surface. `scripted` means a replay fixture is answering and **no capability claim
  survives it**.
  `instructionBudget` tells you whether **your own instructions** arrived intact: `maxBytes` is the cap
  the injector honoured, `docs[]` is one row per project instruction file with `state`
  `whole` | `truncated` | `dropped`. Non-zero `truncatedDocs` / `droppedDocs` means the project rules in
  your prompt are incomplete — say so rather than acting on a tail you were never given. Paths are
  served as `<root>/…` because this endpoint is public.
- **`GET /v1/models`** is the only list of ids this server offers: local paths, not registry names, so
  resolve them at startup rather than at authoring time. `data` is empty on a machine with no cached
  checkpoint — structure is always true, rows only when something is downloaded.
- **`GET /v1/tools`** is what the agent side can execute, in OpenAI typed form. A caller may send its own
  narrower `tools[]` per turn; the registry is not a promise that the loaded checkpoint can drive all of it.
- That 404 marker is documentation, not noise: an unknown route answers `404` with the offending
  method+path **and** the two routes that enumerate the surface. Treat the body as a pointer.

Deep table, capability rows and error envelopes: `skills/ocoreai/references/wire.md`.

## 4. Generate (no weights required — the contract lane)

<!-- exec: POST /v1/chat/completions {"model":"scripted-model","messages":[{"role":"user","content":"hi"}],"max_tokens":8} 200 | "finish_reason" | usage | completion_tokens -->
<!-- exec: POST /v1/chat/completions {"model":"scripted-model","messages":[{"role":"user","content":"hi"}],"stream":true} 200 | data: | [DONE] -->
<!-- exec: POST /v1/messages {"model":"scripted-model","max_tokens":8,"messages":[{"role":"user","content":"hi"}]} 200 | "stop_reason" | input_tokens | output_tokens -->
<!-- exec: POST /v1 {"model":"scripted-model","prompt":"hi","max_tokens":4} 200 | "text_completion" -->
<!-- exec: POST /v1/count-tokens {"model":"scripted-model","input":"hello world"} 200 | prompt_tokens | tokenizer_backend -->
<!-- exec: POST /v1/messages/count_tokens {"model":"scripted-model","messages":[{"role":"user","content":"hi"}]} 200 | input_tokens | tokenizer_backend -->

- `stream: true` on either chat route yields SSE `data:` frames ending in `[DONE]`, reasoning deltas
  before text, a terminal frame carrying `finish_reason` (probe 37 pins the framing byte-for-byte).
- **`tokenizer_backend` is a hedge or a fact.** `real` = a real tokenizer counted it; `heuristic` = an
  estimate. Budget a context window from the flag, not from the number alone.
- `prompt_tokens_details` appears **only** when prefix reuse was measured; absent is honest, zero is a
  claim (`AnthropicCacheUsageTests`).
- Session continuity is a field, not a header: send `"session_id"`
  (`Sources/ocoreai/Models/OpenAIModels.swift:186`) and the turn appends to that durable session;
  `POST /v1/steer {"session_id":"…","text":"…"}` injects mid-turn
  (`Sources/ocoreai/Router/ChatCompletionsRouter.swift:549`).

## 4b. With a checkpoint resident (the measured lane)

These need one ready model; probe 39 runs them when it has one and prints its own skip note when it
does not, so nobody reads the contract lane as a measurement. `@model` is replaced by the first
`state:"ready"` id from `/v1/models`.

<!-- exec-model: GET /v1/models 200 | state | contextLength | reasoningEffort | toolCallDelivery | videoInput -->
<!-- exec-model: POST /v1/chat/completions {"model":"@model","messages":[{"role":"user","content":"Say OK."}],"max_tokens":16} 200 | "finish_reason" | total_tokens -->
<!-- exec-model: POST /v1/chat/completions {"model":"@model","messages":[{"role":"user","content":"List the files."}],"tools":[{"type":"function","function":{"name":"read_file","description":"Read a file","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}],"max_tokens":64} 200 | "choices" -->
<!-- exec-model: POST /v1/messages {"model":"@model","max_tokens":16,"messages":[{"role":"user","content":"Say OK."}]} 200 | "stop_reason" | content -->
<!-- exec-model: POST /v1/count-tokens {"model":"@model","input":"hello world"} 200 | prompt_tokens | tokenizer_backend -->

Read the row's `toolCallDelivery` before you send `tools[]` to a small checkpoint, and read
`reasoningEffort` before you demand a thinking knob: a word the checkpoint's template never names is
refused with the reason, not silently dropped.

## 5. The tool loop, and the boundary it runs inside

Send `tools[]` in OpenAI typed form; the answer comes back `finish_reason:"tool_calls"` with
`message.tool_calls[]`; you execute, append the tool results, and let it finish. Three rules that are
gated rather than merely documented:

- **One destructive truth.** A tool is destructive iff `ToolEntry.isDestructive` says so, and the approval
  gate asks from exactly that — never from a hand-copied name list. Policy is
  `interactive` | `auto` | `never` (`Sources/ocoreai/Agents/Approval.swift:45`, env
  `OCOREAI_APPROVAL_POLICY`); a caller that sets `never` gets refusals that name their cause, not silence.
- **A file tool's `OK` is durability, not validity.** The verdict rides in the same result
  (`OK-but-invalid`): re-read what you wrote when it matters.
- **Delivery ≠ dispatch.** The model echoing a tool call is not evidence it ran. Read the tool result; on
  the multimodal faces read `screenStatus` / `videoInput` instead of assuming a frame arrived.

More: `skills/ocoreai/references/agent-loop.md`.

## 6. What this build has NOT measured — say these, don't imply them

- `engineBackend: scripted` ⇒ a fixture answered; no capability claim of any kind survives it, and
  `scripts/eval/run.sh` refuses to score such a run.
- iOS is compile-validated only: no iOS runtime has been executed by this project.
- Screen capture cannot stream headlessly; video publishes per checkpoint, so `videoInput` is per-model.
- CoreAI / macOS 27 surfaces are unverifiable on a host without that SDK (`PlatformPremise.hasMacOS27`).
- The task scoreboard exercises a subset of the advertised tools, so a score is not "all tools work".

Evidence per item: `docs/agent/open-items.md`; wire consequences:
`skills/ocoreai/references/honesty-and-limits.md`.

## 7. Re-proving this file

```bash
bash scripts/probes/run.sh 39      # boots its own server and executes every marker above
```

A marker that stops matching is a red probe; a probe that finds no markers fails on its own floor. Change
the marker in the same commit as the behaviour, or the doc becomes a lie with a green suite.
