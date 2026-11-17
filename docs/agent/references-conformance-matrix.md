# References conformance matrix — the whole of `~/references` against ocoreai

> **Why this file exists (11-16):** the owner ruled that the standard is the shipped practice of the
> `~/references` trees (root `AGENTS.md` § Upstream), and then ruled that a local review must not be
> presented as a full one. This is the full one: every domain ocoreai actually ships, adjudicated
> against named trees at named lines, with ocoreai's own site and gate on the other side. The goal is
> the size of the gap, not a clean score — an unverified row says *unverified*.
>
> **Evidence rule for this file:** every upstream cite below was read this session at these HEADs —
> `sglang 8cb94fcc3f` `vllm d07b7db978` `codex 75fc67e8f4` `omlx bf28cd6c` `harmony abd677f`
> (mlx-swift-lm read at the pin `635290754` inside `.build/checkouts`). An ocoreai cite is a `file`
> (+`line` where quoted) or a named gate. Trees move daily: re-read a cite before repeating it
> (memory: comparator cites are content-unverified).
>
> **Verdicts:** ✅ conforms · ⚠️ deviates (priority attached) · ❓ unverified · ⛔ not applicable at
> this scale. **Tiebreaker (owner ruling 11-17):** converged following is the default; a row deviates
> legitimately only when a local or Apple premise carries the deviation, and then the row names it.
> The audited "field" is layered: the six trees this matrix reads at HEAD (live cites), the 49 typed
> dated entries of `comparator-repos.md` (the rest of the disk audited spot-wise), and
> `scripts/comparator-consensus.sh` for field-wide claims — freshly-read-at-HEAD is the six's property,
> never a verdict that the others were un-audited. **Priority:** P1 = a surface can mislead or silently lose content; P2 = shipped behavior
> the field has and we lack; P3 = depth/efficiency — measure before adopting (no blind copying).

## 1. Architecture

| Standard | ocoreai | Verdict |
|---|---|---|
| Serving trees are rebuilding a generated-contract HTTP front over an engine boundary: vllm Rust front-end over the ZMQ engine (`vllm rust/README.md:3,5` self-labels experimental); sglang ships `sglang-server` as PyO3 + **generated** API types (`rust/sglang-api-codegen`) | Single Swift binary; boundaries are logical: HTTP/Handlers → EnginePool (actor) → lane; `/openapi.json` renders off the endpoint index | ⛔ process-splitting does not transfer to a local single-box product; the transferable part (contract generated from one index, not retyped) is ✅ — `Handlers/AGENTS.md` discovery contract |

## 2. Code quality / error taxonomy

| Standard | ocoreai | Verdict |
|---|---|---|
| vllm keeps one exception taxonomy for the whole server — 16 typed classes in `vllm/exceptions.py`, mapped to HTTP at the boundary | `AppError` is the one taxonomy; refusals carry `param:` field-paths (this round's `tool_history_unpaired` follows it); tiered warning logs with `error_code` metadata | ✅ same shape |
| Cites in living comments must reproduce | **Convicted this audit:** `Approval.swift:53` cites `protocol.rs:4053` for `ReviewDecision`; upstream at `75fc67e8f4` has it at `:4583` (`:4053` is an exec-event struct). Fixed this round | ✅ after fix (paid-in-example of the principle) |

## 3. Agent loop — interrupt / steer / stall

| Standard | ocoreai | Verdict |
|---|---|---|
| codex defines a **two-tier interrupt**: `Interrupt` unconditional, `InterruptIfNoPendingInput { turn_id }` only if nothing is queued (`codex protocol.rs:729-734`) | `/v1/steer` merges at turn head; a **no-tool turn cannot be interrupted** by our wiring yet, but the pin moved under the claim: #798 at `bf5a5d438` ships safe-point steer inside thoughts plus `interrupt(response:)` (reply recorded, no rollback), verified upstream on M5 Max at 0.22-0.30 s (`open-items.md` steer row; adopt-then-retire ruled, flag-staged — `AGENTS.md` § Open); stall termination owned by `LoopStallTerminationTests` awaiting the terminal-word call | ⚠️ P2 — upstream's half of the two tiers now exists at our pin; codex's queued-input guard stays the half we must author, wire it as the second tier, not as an unconditional cancel |

## 4. Tool calling

| Standard | ocoreai | Verdict |
|---|---|---|
| History pairing rejected on the OpenAI face: orphan / id-not-pending / non-tool-while-pending; trailing unanswered legal (`sglang serving_chat.py:300-330`, walker head re-read `:300-303` today: `pending`/`unpaired_ids`) | `ToolHistory.pairingViolation` both faces, refusal at both handlers; `ToolHistoryPairingTests` + probe 57 arm 6 | ✅ (this round) |
| `parallel_tool_calls:false` filters to index 0 **only when explicitly false** (`vllm tool_calls_utils.py:22-38`) | `ToolCallWire.limitsToSingleCall` (`== false`, not nil) + Anthropic-face `disable_parallel_tool_use` mapping | ✅ same rule, both faces |
| finish_reason resolution: calls made + engine "stop" → `tool_calls` (`vllm tool_calls_utils.py:41-59`) | `ToolCallWire.resolveFinishReason` called at `ChatHandler.swift:1235` | ✅ |
| Per-format **streaming** tool-call detectors, 40+ formats incl. a dedicated gemma4 detector with its own marker syntax (`sglang function_call/gemma4_detector.py:15-18` `<|tool_call>` / `<tool_call|>` / `<|"|>`) | MLX/ChatSession lane consumes upstream's declared format (`Gemma4.swift:2872,2880 toolCallFormat: .gemma4`, pin `635290754`); CoreAI lane uses the vendored `ToolCallParser`; **MTP lane's calling turn is re-appended at the tool boundary 11-17** (upstream `ChatSession.swift:1959` shape; `MTPToolLoopHistoryTests`) | ✅ for the marker/pairing shape across the three lanes; the live MTP arm on a drafter checkpoint stays the escalation tier (`open-items.md` tool-result row) |

## 5. Model adaptation

| Standard | ocoreai | Verdict |
|---|---|---|
| Role vocabulary is closed at 5 (user/assistant/system/developer/tool) (`harmony src/chat.rs:44-52`, read at `abd677f`) | `MessageBuilder` developer-channel decision cites harmony as primary (registry confirms, cite re-verified today) | ✅ |
| A stubbed component stays runtime-detectable (the tokenizer-backend pattern) | `tokenizerBackend: real\|heuristic` on `/v1/capabilities` + assertion tests | ✅ (ours is the pattern § Code Conventions names) |
| Lane must not silently erase tool metadata before the template | tool-metadata history refuses the flat std lane (11-16), probe 57 arms 2–4 bill it | ✅ |

## 6. Context management

| Standard | ocoreai | Verdict |
|---|---|---|
| Compaction is model-summarized, hook-wrapped, pending-input-retaining (`codex core/src/compact.rs:1-30`: `CompactionSummary`, pre/post-compact hooks, `is_retained_pending_mail`) | `ConversationCompaction.swift` is deterministic rule-based (header documents the deliberate no-LLM-round-trip choice) and keeps tool-call units atomic (`ConversationCompactionTests:143`) | ⚠️ P3 — a real divergence with a stated reason (hot-path cost). Settle it on the board (`scripts/eval`), not by taste; rule-not-summary may also be *better* locally — measure both directions |
| KV prefix sharing is the engine's core asset: `sglang mem_cache/radix_cache.py` (839 lines), cross-request prefix hits | Pool keyed by leading-user hash + per-session KV; **cold prefills from turn two** are the disclosed residual (`open-items.md` tool-result row); cross-conversation pollution closed 11-16 (probe 57 arm 5, +15) | ⚠️ P2 — we hold sessions, we do not share prefixes; the honest ceiling is set (residual row named), the fix is a real build |

## 7. Inference / scheduler

| Standard | ocoreai | Verdict |
|---|---|---|
| sglang: continuous batching, decode-retract stress switches (`scheduler.py:460-462` `TEST_RETRACT*`), and — directly comparable — a **native MLX/MPS backend with an overlap scheduler** (`is_mps()` + `SchedulerMlxOverlapMixin`, `scheduler.py:438-447`) | SchedulerActor + AdmissionGate + MemoryTracker (`MemoryTracker.swift:36`) + OOMGuard; sessions run serially through the pool | ⚠️ P3 (investigate, don't port): overlap-between-schedule-and-execute is the one scheduler idea with an Apple-GPU proof in the field; our lanes are single-stream by design. Measure GPU-idle on a realistic long coding turn before deciding |

## 8. Computer use / approvals

| Standard | ocoreai | Verdict |
|---|---|---|
| Four-tier approval policy with a **model-decides** default: `AskForApproval::{UnlessTrusted, OnRequest(default), Granular(fields), Never}` (`codex protocol.rs:1191-1213`); per-decision `ReviewDecision` incl. approve-for-session (`:4583`) | `ApprovalPolicy{interactive, auto, never}` maps the codex axes explicitly — `interactive`≈OnRequest (ask only on high-risk), `auto`≈sandbox-allow, `never`≈Never — and states *why* `untrusted`/`granular` are deliberately unbuilt (no subprocess sandbox or rule surface to hang them on; `Approval.swift:40-44`); decision enum aligns `ReviewDecision` incl. session scope; destructive truth has one home (`isDestructive` → `securityPrecheck`, `DestructiveApprovalGateTests`) | ✅ with one residual: codex's OnRequest lets **the model** raise the ask; ours raises it from the rule (`isDestructive`) — a smaller divergence than first assessed, and this audit's own lesson (read the exact site before convicting). Residual P3 |

## 9. Media

| Standard | ocoreai | Verdict |
|---|---|---|
| Refuse-by-name what the engine cannot carry (the invariant-2 rule the trees enforce via typed validation errors) | `ChatMedia.uncarried` refuses, audio refusal typed, `MediaSpool` lifetime + probe 08, video publishes per-checkpoint | ✅ on the enforcement pattern |
| Deep multimodal parity (image fetch limits, per-modality token budgets) vs sglang's multimodal pipeline | not compared side-by-side this round | ❓ unverified |

## 10. API compatibility

| Standard | ocoreai | Verdict |
|---|---|---|
| **Anthropic-face tool_result conversion is lenient in both trees:** `vllm anthropic/serving.py:687 "tool_call_id": block.tool_use_id or ""`, `sglang anthropic/serving.py:507 block.tool_use_id or block.id or ""`; third independent vote 11-17 — omlx takes an orphaned tool_result and falls back to the call id as the name instead of rejecting (`tests/test_gemma4_messages.py:130-132`, read at today's HEAD; chosen because its lineage is local-MLX, not the two servers' shared spec world) — none of the three runs the OpenAI-face pairing rejection on this face | We refuse unpaired pairing on **both** faces (this round), which matches Anthropic's *own* published rule (every `tool_use` answered by `tool_result` in the next user turn) but is **stricter than both comparator servers** | ⚠️ P3, owner-visible: stricter ≠ unsafe (it prevents the silent-fold 200), but it is a deliberate divergence from the trees' observed behavior. Keep until a real client complains; then this row is the decision record |
| OpenAI-face compat judged by spec + trees + live requests | probes 01–57 + wire suites cover the faces at this pin | ✅ breadth gated; row-level spec audit of rarely-hit fields ❓ |

## 11. Testing

| Standard | ocoreai | Verdict |
|---|---|---|
| Two serving trees: permissions-as-data CI (sglang `CI_PERMISSIONS.json`, 123 workflows), big e2e suites | 349 test files, 57 live-`/v1/*` probes + runner (65 files in `scripts/probes/`), tiered gate discipline, `make audit` | ✅ — and the live-probe harness is at least field-equal; CI rights are single-owner scale (not the 123-workflow shape) |

## 12. Reliability

| Standard | ocoreai | Verdict |
|---|---|---|
| sglang ships a soft/hard **watchdog** with explicit feed/disable (`utils/watchdog.py:26-57`) — a stuck loop is *detected*, not just bounded | Deadline discipline is a project rule and real (poll-capped ticks, `EnginePool.swift:741-759`); watchdog-named code exists in HeadlessServer/App sites | ✅ bounded-wait shape present; whether every generation loop feeds or dies loudly end-to-end ❓ spot-verified at the pool only |

## 13. Performance

Row 6 (prefix sharing) and row 7 (overlap) carry the two real gaps. Cold prefill and pool accounting are measured, not guessed (probe 57). Warmup parity with `_prewarm_*` paths (sglang `scheduler.py:454-457`): ❓ unverified for our Metal path.

## 14. UX

| Standard | ocoreai | Verdict |
|---|---|---|
| The closest distribution analogue runs DMG + in-app auto-update + `~/.omlx/bin/omlx` shim + brew tap whose optional-kernel flag **degrades instead of failing** (`omlx README.md:50-58`, re-read today) | `UpdateCheck` only notifies; build/publish split is the open cadence item; App-Store trait route exists | ⚠️ P2 = the standing ladder (rung 2), not a new finding — this audit re-confirms the four parts are real and we ship none of them end-to-end yet. **11-17 category collision:** LM Studio shipped Bionic, a separate app self-labeled "the AI agent for getting real work done with open models — coding, research, complex work with documents and files" (`lmstudio.ai/docs-md/bionic`, read 11-17) — the closest category rival to our tagline in the field; it carries a cloud escape hatch (Secure Cloud, ZDR, credits), which is their promise-choice against our natively-local one and is **not** a gap to close (owner's local axis) |
| HIG is authority on anything user-visible | five non-happy states gated per `UI/AGENTS.md` | ✅ pattern |

## 15. DX

`skills/ocoreai/` published + probe 39, `/v1/capabilities` + `/openapi.json` — ✅ present. No canonical client ships (open § Adoption) vs ollama/omlx single-binary-command ergonomics and the two trees' generated API packages: ⚠️ P2, ledgered, bounded by distribution.

## 16. Accessibility (SwiftUI a11y) — not to be confused with the docs-AX axis in § 17

No GUI comparator in the trees (codex is a TUI; servers are headless) — HIG is the only authority. ocoreai's SwiftUI carries 127 `accessibility*` call sites (counted today); per-screen VoiceOver reality is **❓ unverified** — no gate walks it. P3.

## 17. The docs themselves — UX / DX / AX (owner ruling 11-16: the doc suite is a product surface with three readers)

> **The principle in full (owner, 11-16, elevated from audit axis to standing rule — root § Three
> readers carries the ≤3-line form):** UX, DX and AX are core dimensions of ocoreai's whole product
> and engineering quality, running through design, architecture, implementation, interaction,
> documentation, testing, release and maintenance. Every significant design and engineering decision
> must weigh its real effect on all three. Pursue their joint improvement — not local optimization,
> and not a surface gain for one bought by sacrificing another. Judge quality by real usage
> experience, development efficiency, agent execution capability and verifiable results. Do not
> introduce unnecessary complexity for the sake of formal UX/DX/AX completeness. They are not
> add-on features; they are the baseline from design to delivery.

| Axis | Standard (tree@line, read today) | ocoreai (site/gate) | Verdict |
|---|---|---|---|
| **UX** — a stranger reads | the install quartet is real and degrades not fails (`omlx README.md:50-58`); privacy contract verifiable on the first screen (adoption-runbook's rule, from the trees' intake practice) | README: DMG double-click + `curl … install.sh` + `uninstall.sh` **dry-run by default** (`README.md:24-31,77`); README-vs-served-surface is kept re-greppable by convention (the P10 diff retired 11-16 with the bespoke docs gates) | ⚠️ P2 — structure ✅, but the README promises a DMG whose surviving release is ad-hoc signed and Gatekeeper-unjudged (row 14's open item): the doc currently claims more Gatekeeper-trust than measured. Same ledger row, now flagged as a **doc** promise too |
| **DX** — a contributor reads | intake rules live in-tree, cited (vllm `AGENTS.md` intake — registry cites `:8,21,27,35,39`); onboarding is a contract, not folklore | `CONTRIBUTING.md` (three questions, floor/ceiling), `docs-map.md` audience table, `make push-ready`/`make audit` as the single onboarding verb; refusals carry field-path + remediation so a wire error is self-teaching (this round's `tool_history_unpaired`) | ✅ |
| **AX** — an agent reads | codex's loader: hierarchy walk that stops at the project root (`agents_md.rs:10-18`), a byte budget that when cut **says so to the model** with trim-or-raise guidance (`:51`, `:162-166`), zero-budget/untrusted gates (`:65`) | `WorkspaceContext` implements the same discovery/order/budget semantics by name ("codex-style loader", `:16,:186`); per-doc fate `whole\|truncated\|dropped` is named, "the last two used to be silent" (`:167`) — silent-cut is fixed, the same rule invariant 2 states; budget equality test-bound (`InstructionBudgetSingleSourceTests`, code ↔ root prose since the 11-16 gate retirement); `skills/ocoreai/SKILL.md:2-5` routes on name+description (the field's only fields a router reads) | ✅ with the disclosed pressure: deepest chain 32 298/32 768 = **99% spent**; the cost is disclosed to the model and on `/v1/capabilities`, gated only as a capacity question (`AGENTS.md` § Open — owner item) |

## What this audit convicted (fixed or routed this round)

1. **Fixed:** stale upstream cite `Approval.swift:53` (`protocol.rs:4053` → `:4583`).
2. **Recorded divergence, decision kept:** both faces' pairing refusal is stricter than vllm/sglang's Anthropic-face leniency — kept, documented at row 10.
3. **Priority queue the matrix generates, in order:** ① interrupt two-tier semantics with the steer pin (row 3), ② `tools[]`-vs-model gate (already ledgered; row 10's honesty family; **field evidence 11-17:** LM Studio Bionic gates its session model picker by task fit — tool and image support the task needs (`lmstudio.ai/docs-md/bionic/models`, read 11-17, web-only source, overview tier); the owner's call stands), ③ prefix-sharing/prewarm measurement (rows 6/13), ④ MTP marker-literal verification (row 4 — **closed 11-17**: the defect was not a drifted literal but the missing calling-turn append; fixed and gated, live arm escalated), ⑤ eval head-to-head: rule-compaction vs summary-compaction (row 6), ⑥ model-raised approval asks (row 8 residual), ⑦ AX walk + ⑧ the distribution quartet (row 14).
4. **Rows left ❓ on purpose:** deep multimodal parity, rarely-hit wire fields, whole-pipeline watchdog coverage, Metal warmup, per-screen AX — *unverified is a verdict, not a pass*.

## Maintenance

This file is a dated snapshot, not a ratchet: refresh a row's cites when you touch its area; a
row whose upstream cite nobody re-read this quarter is inference (root § Upstream). Keeping its
pointers alive is the touching reader's job (the bespoke docs gates retired 11-16); re-measuring
the whole matrix is an owner-sized task, and the honest cadence is one-domain-deep per round, not
a quarterly sweep.
