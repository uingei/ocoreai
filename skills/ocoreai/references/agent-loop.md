# The agent loop, from the caller's side

Everything here is what a client can observe on the wire or in a result; the gates that hold each rule are
named at the rule, because "documented" is not a guarantee in this repo.

## Turn shape

1. `POST /v1/chat/completions` with `messages`, optional `tools[]`, optional `session_id`.
2. If the model wants a tool: `choices[0].finish_reason == "tool_calls"` and
   `choices[0].message.tool_calls[]` carries `{id, type:"function", function:{name, arguments}}` —
   `arguments` is a JSON *string*, parse it defensively.
3. Execute, then append one message per call: `{"role":"tool","tool_call_id":…,"content":…}` and post
   again on the same `session_id`.
4. The loop ends on `finish_reason:"stop"` (or `length` when `max_tokens` cut it — a cut turn is not an
   answer).

`session_id` is the continuity field (`Sources/ocoreai/Models/OpenAIModels.swift:186`). Sessions are
durable (SQLite + FTS5): `GET /sessions`, `GET /sessions/:id/memory`, `GET /sessions/search?q=…`
(400 naming the missing parameter if you forget `q`), `DELETE /sessions/:id`.
`POST /v1/steer {"session_id":"…","text":"…"}` reaches a turn that is still generating
(`Sources/ocoreai/Router/ChatCompletionsRouter.swift:549`); when a steer contradicts what the model
already committed to, the session rewinds rather than pretending (`SessionRewindOnDivergenceTests`).

## Read the checkpoint before you drive it

`GET /v1/models` per row:

| field | values | what to do with it |
|---|---|---|
| `toolCallDelivery` | `parsed` \| `prose_only` \| `not_observed` | `prose_only` ⇒ this checkpoint writes tool calls as *text*: expect no `tool_calls` array and parse or don't use tools. `not_observed` ⇒ no turn like this has run yet. `ToolCallDeliveryLedger.swift:78-80` |
| `reasoningEffort` | `honored` \| `template_ignores` \| `not_observed` | `template_ignores` ⇒ a `reasoning_effort` word you send is dropped by the checkpoint's own template; asking anyway is refused with the remedy (`EnginePool.swift:237`, probe 38) |
| `videoInput` | `delivered` \| `not_observed` | per checkpoint, not global: `delivered` means a turn here actually carried frames (`VideoDeliveryLedger.swift:68-69`) |
| `vlm`, `contextLength` | bool, int | the ceiling you must fit prompts under |

## The approval boundary

- Policy is `interactive` | `auto` | `never` (`Sources/ocoreai/Agents/Approval.swift:45`), env
  `OCOREAI_APPROVAL_POLICY`, falling back to `~/.ocoreai/config.yaml`, then the GUI's recorded value
  (`Sources/ocoreai/UI/ViewModels/SettingsStore.swift:386`). A headless caller that wants deterministic
  behaviour **must set the env var**: probes pin it for exactly this reason
  (`scripts/probes/_lib.sh` — an unpinned serve adopts whatever the GUI recorded).
- Destructiveness has one source: `ToolEntry.isDestructive`, and `securityPrecheck` asks from it
  (∪ a blacklist for names nothing registers). Gate: `DestructiveApprovalGateTests`(5).
- `edit_file` offers `rm` **only** when its own `newString` is empty, so a mismatch typo never arrives with
  an unrecoverable delete next to it. Gate: `EditMismatchRecoveryTests`(10).
- A refusal names its cause. A failing MCP server's stderr travels inside the refusal
  (probes 04/26); nothing answers 200 with an empty promise.

## What a tool result does *not* mean

- `OK` from a file tool means the bytes were written, not that they are valid — the verdict travels in the
  same result (`OK-but-invalid`). Read it; re-read the file when it matters.
- A model echoing a tool name is not a dispatch. Delivery evidence lives in the ledgers and in the
  `screenStatus` / `videoInput` fields (`Sources/ocoreai/Engine/EngineInference.swift:4902`).
- Tool registry ≠ per-turn surface: the server advertises the registry (`GET /v1/tools`) and a caller may
  send a narrower `tools[]`; whether 40 declarations is right for a 4-bit checkpoint is an open, priced
  question (`docs/agent/open-items.md`), not a settled fact.

## Skills and MCP, on this side

`GET /skills` lists the agent's own skill names; skills are loaded from disk by
`Sources/ocoreai/Skills/SkillLoader.swift`. Extra tools arrive through MCP (`POST /mcp` routes manage
servers) and their startup failure is surfaced, not swallowed.
