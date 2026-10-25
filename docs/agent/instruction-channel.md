# The instructions channel — who delivers the caller's `system` message, and who pays for it

Long form for the AGENTS.md § Endpoint Promises rule *"the caller's instructions have one delivery
seam, and instruction identity gates cache reuse."* Root carries the rule; the measurements, the
upstream comparison and the cost of the fix live here.

All numbers below are from one session on this host (macOS 26, `mlx-community/gemma-4-e2b-it-4bit`,
`temperature: 0`), reproduced by `bash scripts/probes/run.sh 15` (probe 15, 9 checks green).

## 1. The defect: counted here, dropped there

| Request | delivered `prompt_tokens` (before fix) | after fix |
|---|---|---|
| `messages:[user]` only | 705 | 705 |
| same + `messages[0] = {role:"system", content: 996 chars}` | **705** (differential 0) | **886** (+181) |
| same with `role:"developer"` instead | — | **886** (+181) |
| `/v1/messages` with `system:` = same 996 chars | 887 (+182) | 886 |
| `/v1/messages` without `system:` | 705 | 705 |

The OpenAI face accepted the most-used instruction field on its wire and delivered none of it,
while its own disclosure line claimed the text had been counted (`systemChars=` included it,
`promptTokens=` was 838 against a delivered 705). The Anthropic face — whose spec carries
`system` as a *top-level field* rather than a message — delivered the same text. Same server,
two answers, and the surface that most clients use was the one that lied.

## 2. Why it was structural, not a parsing miss

The engine reads standing instructions from exactly one place: the **first** `system` message it
finds (`Sources/ocoreai/Engine/EngineInference.swift:1823`), which becomes
`ChatSession(instructions:)` (`:3117`, `:3175`). Every `system` role is then filtered out of the
message feed it renders (`:1805`), and the role switch under that filter admits `assistant`,
`tool`, and everything else as `.user` (`:1808-1812`) — mlx-swift-lm's `Chat.Message.Role` has no
`developer` case (`Chat.swift:120-124`), so `developer` never matched either: it arrived as
something the *user* said.

<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:1823 switch messages.first(where: -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:1837 nonSystemMessages = messages.filter -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:1844 default: .user -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/Chat.swift:120-124 public enum Role -->

`MessageBuilder.buildMessages` inserted this server's own prompt at index 0 and left the client's
message in the list, so the client's text sat at index 1: counted by the estimator, invisible to
the renderer. Disclosure roles before the fix: `[system, system, user]`.

## 3. What the fix does

- `Handlers/MessageBuilder.swift` — `instructionMessageRoles = ["system","developer"]` and
  `splitInstructionMessages(_:)` take instruction-role messages out of the conversation, in the
  caller's own order, and join them (empty ones dropped rather than turned into blank turns).
  `buildMessages` starts from the remaining conversation; Phase 3 composes
  `clientInstructions = ([top-level system field] + inline) → joined`, ahead of workspace /
  skills / memory, into the **one** system message generation actually reads. Phase 7's
  fallback reads the filtered conversation, so a system-only request can no longer be scored as
  if the system text were the user's question.
- `Engine/SessionPool.swift` — `canReusePooledSession(cachedMessageCount:commonPrefixCount:
  instructionsMatch:)` gained the second premise. `ChatSession.instructions` is a stored property
  the processor prepends at prefill, so a session that survives into a turn with different
  instructions answers under instructions this turn never sent. The disk path had refused on this
  identity from the start (`SnapshotRefusal.instructionsChanged`); the in-memory path now consults
  the same function, so the rule has one home. A refusal logs *why*, at info level:
  `Session pool entry <key> not reusable: instructions changed — building a clean session`.

## 4. Upstream

vllm routes both roles into the developer channel and never counts instructions it does not send
(`entrypoints/openai/responses/harmony.py:128`,
`entrypoints/openai/parser/harmony_utils.py:436`); sglang admits both as generic message roles
(`srt/entrypoints/openai/protocol.py:727-729`). Neither strips instructions from the render, and
neither has a session-scoped instruction object whose identity must be checked before reuse.

## 5. What this proves, and what it does not

Proven, by token differential (probe 15 §1–§4): the client's text reaches the prefill; the two
faces agree on the same content within 0 tokens; exactly one system message is assembled
(`[system,user]`, never `[system,system,…]`); `systemChars` grew 998 for 996 chars of client
text; and reuse is refused when instructions change (probe 15 §5: 728 `cached_tokens` kept on an
unchanged replay, 0 kept after the caller rewrote them, with the reason line logged once).

Not proven:
- **Instruction compliance.** A token differential shows the text entered the prompt, not that the
  model obeyed it. `gemma-4-e2b-it-4bit` ignores persona wording at temp 0 on this host, so
  "the instructions arrived" is as far as this instrument reaches.
- **The cost of the refusal is real and repeated.** A changed instruction set throws away the
  prefix: measured 728 cached tokens → 0, i.e. one full re-prefill (~754 prompt tokens paid
  instead of 22). This is correctness bought with performance, and it is the same rule the disk
  path already enforced.
- **Our own instructions vary per turn.** The merged system message grows when the request
  declares tools — measured +299 chars of schema-less `## Tool:` prose for one declared tool
  (probe 13 §11, 3026 → 3325 chars) — so a conversation that alternates tool-declaring and
  non-declaring turns now loses its cache every time. Narrowing that text is the open item on
  the `tools[]` surface in AGENTS.md § Open, not this rule.
- Order/merge semantics: several instruction messages are joined into one block with `\n\n`.
  vllm keeps each in its own harmony channel. Whether per-message separation changes behaviour
  is unmeasured here.

## 6. Gates

- `Tests/ocoreaiTests/SystemInstructionDeliveryTests.swift` (9) — split semantics (order,
  casing, empty text, tool/function roles stay put, the role set itself) plus two premise-floored
  source scans: `splitInstructionMessages(context.rawMessages)` exactly once, and
  `var messages = context.rawMessages` zero times (the unfiltered feed must stay gone).
- `Tests/ocoreaiTests/SessionIsolationTests.swift` — the reuse gate with `instructionsMatch`,
  including the empty-transcript case that only the instruction premise can refuse, and that
  `KVCacheManifest.reuseDecision` reports `.instructionsChanged` rather than `.notAPrefix`.
- `scripts/probes/15-system-instruction-delivery.sh` — the live half, including the log-reason
  assertion with its own premise floor (a grep that matched nothing fails the run).
