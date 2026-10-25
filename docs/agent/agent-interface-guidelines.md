# Agent Interface Guidelines — the chapter the HIG does not have

Apple's HIG judges anything user-visible (`AGENTS.md` § Upstream Audit Dependencies 5): components, focus
order, wording, the five non-happy states. It carries no agent chapter, and the gap is structural, not an
oversight — HIG is indexed by **surface** (Foundations … Technologies) times platform, a map of what a person can perceive and touch. An agent is not a surface: it is a **policy
over time** — who decides next, and what the person can see, undo, and believe.

Measured, not asserted. Walk
`https://developer.apple.com/tutorials/data/design/human-interface-guidelines.json` plus the six
`<section>.json` under it: 109 article refs, 7 of them the index pages, so 102 topics (`Generative AI`,
`Machine learning` included) — and the token `agent` in 3, all Generative AI → Videos metadata (1 title,
2 abstracts), none guidance. Framework side, same story: `FoundationModels` says `agent` 5 times
(2 video titles, 2 abstracts, 1 marketing line) and its 15 topics are mechanism — sessions, tools, guided
generation, KV cache, evaluation — never who decides next. The ML chapter's axes (complementary/critical,
data sensitivity, proactive/reactive, visible/invisible, static/dynamic, explicit/implicit feedback)
describe a model that *proposes*; the rows below are that genus one rung further, where software
*executes*. Why nobody publishes it: prose without a gate is a claim, and run-to-run variance needs a
statistical acceptance rule design docs never carried.

## The loop's own contract, priced by the gate that goes red

| # | What the person is owed | Decidable assertion | Goes red here |
|---|---|---|---|
| 1 | Its last sentence is true about what happened | file-change sentences of a self-terminated answer vs the write ledger at `ToolRegistry.call`, which native/MTP/GUI/MCP all pass | `ClaimVsAuditTests`(17) |
| 2 | Your stop word ends the turn | a stop string ends with `finish_reason: stop`; only the last SSE chunk speaks | `StopSequenceDeliveryTests`(13) + probe 10 |
| 3 | You may change your mind mid-turn | steered text merges at the head of the chat handler, pre-assembly | `SteerRequestHeadTests` + probe 21 |
| 4 | A refused edit still tells you where it is | durability and validity in one result (`OK-but-invalid`), quoting the file with its line numbers | `EditLinesContractTests`(9) |
| 5 | Being stuck yields a next step, not a wall | the identical-call cap returns a remedy, not the same refusal | `LoopGuardRemedyTests`(3) |
| 6 | Its own chrome never passes as your content | read-then-write strips the `N` gutter and `total_lines:` footer, repairs what is provable, refuses to guess | `PresentationEchoGuardTests`(16) |

The human-facing **wire** half of the same policy — knobs, usage numbers, capability rows, hub and capture
refusals — is owned by `AGENTS.md` § Endpoint Promises, one gate per row there. Not restated here: a
second copy is where one of them drifts.

## Rows with no gate ⇒ claims, not guidelines

- **A turn with no tool call cannot be interrupted** — `AGENTS.md` § Open names the seam upstream's
  `ChatSession` does not offer; only the tool-bearing half is provable (probe 21).
- **A false failure on a read** — scoreboard-measured: correct bytes came back and the answer said the file
  was missing (`exec-sum-column`, 0/6). Row 1 counts writes, so nothing is red.
- **A voice turn that ends in text** — an HIG duty and a rule in `Sources/ocoreai/UI/AGENTS.md`, zero tests.
- **Which model answered** — no GUI surface discloses it today; if one ever does, it reads `/v1/capabilities`.
- **Focus discipline** — "offer, don't hijack" is prose; the UI guide's ceilings count shortcuts and
  labels, i.e. adoption, not obedience.

## The unit is a distribution, not a screenshot

Same prompt, different answer, so acceptance is k matched runs per task: a task counts once its band agrees
across two windows, and every judge is re-proved against near-misses and mutations. Numbers:
`scripts/eval/README.md`; the ladder they sit on: `docs/agent/long-horizon-goal.md`. Presentation duties
(⌘ coverage, focus order, Dark Mode, Dynamic Type, destructive wording, the five states) belong to
`Sources/ocoreai/UI/AGENTS.md`.
