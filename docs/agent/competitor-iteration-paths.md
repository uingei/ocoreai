# Competitor iteration paths — the rules their histories imply

> Long form behind `AGENTS.md` § *Upstream Audit Dependencies*. Question: in what order did the
> leading agent products ship capability, and what did each axis cost them — so ocoreai spends its
> quarters on the expensive things instead of rediscovering them.
>
> **Re-runnable method:** `bash scripts/competitor-path-scan.sh "codex ollama"` reads only
> `git log` subjects from `~/references` (no network); per axis it prints the oldest matching
> subject plus `later=` and `fixes=` (the repair subset). The dated tables it produced live in
> `CHANGELOG.md` (dated evidence = diary); only what transfers stays here. **Limits:** a subject
> is a first *mention*, not a GA date; matching is heuristic; a mirror proves content, never HEAD;
> and a borrowed verdict stays an inference until a `file:line` in our build carries it.

## What the order says

**Authority ships first, and never finishes.** codex put sandbox, approval configuration,
macOS completion-notification and the review/diff recipe inside its first 72 hours (open-sourced
2025-04-16), and those four are still the most-trafficked surfaces in 12,490 commits — mcp 671
later commits / 108 fixes, sandbox 485/94, approvals 279/104, review 257/120 (47%, the highest
fix ratio measured). Behavior-quality axes came months later and cost far less each: resume +71d
(21/4), mid-turn steer +93d (43/13), structured output +114d (6/5), compact +131d (35/5),
checkpoint/undo +160d (26/11), parallel tools +172d (12/4), skills +229d (361/34), subagents
+267d (89/15), plan mode +278d (23/2), hooks +295d (138/12).

Consequence: the polish ocoreai keeps investing in — steering, compaction, tool-wire correctness,
resume — sits in the cheap cluster. That is the ticket to play, not the moat; the moat is an
authority layer that survives a year of adversarial use. codex's macOS fix log is the free
checklist for the day we claim a sandbox: system-alias matching in patch permission checks,
read-only mount ordering for nested writable roots, approved escalation that still preserves denied
reads. We claim no sandbox, and the approval cache is byte-exact payload
(`Sources/ocoreai/Agents/Approval.swift:249`), so the alias hole does not exist here.

**KV reuse is a correctness surface, not a performance one.** ollama's `x/mlxrunner` — the
closest shipping analogue to our dual-path engine — published a nine-month cache-correctness
series whose worst entry is silent: a lazy KV snapshot indexes the cache's *live* buffer, so it
must be copied out before an append reaches the slots it names; they checked only the first append
after a rewind and only that append's own range, so "restoring that snapshot later silently serves
the new request's KV in place of the old conversation's." Two September fixes then dealt with
budget pressure: evict the active conversation's own checkpoints, and keep the reused head of a
cached edge safe from eviction.

## The five things ocoreai changes, ranked

1. **Do not wire `KVCacheConfiguration.rewind` before the invariant is asserted for our pool:**
   *a snapshot still in lazy state has never been overwritten*. Instrument: a rewind turn may
   never report a reused prefix longer than the prompt it was restored for (extend probe 01), plus
   a `SessionPool` test that a snapshot referenced by a live session is not evictable.
2. **Pressure eviction must be per-conversation, not per-model.** Our pressure path is model-level
   LRU (`Sources/ocoreai/Engine/EnginePool.swift:373`, `:730`), so one HardwareRouter event can
   drop a cache active sessions are reusing. Instrument: `prefixReuse` must not zero for a session
   still active across a pressure event.
3. **Cancellation has cache consequences.** A cancelled prefill must settle draft/KV state; ours is
   the `.cancelled` / `maxTokens` terminal path. Instrument: cached-token accounting after a
   cancelled turn must not claim reuse it did not earn.
4. **Undo rides git, not KV.** codex shipped undo as git tooling (#3914), not as cache rewind.
   Our sessions are SQLite over a git workspace, so "rewind the work" is separable, user-visible
   and testable today — do that before chasing token-level rewind.
5. **Do not widen MCP without a gate.** It is the most expensive integration in the set (671/108);
   we hold stdio lifecycle tests and will not add transport breadth without one. Skills, hooks and
   subagents arrived late and cheap for every rival — we are already ahead of that order, so spend
   nothing extra there.

**The meta-lesson, aimed at ourselves.** Reading references is not the scarce act; keeping the
claims they produce true is. On 10-22, 4 of our own 173 bare upstream cites in `Sources/` named a
path or line that did not exist — one a quoted sentence absent from the pinned file. Now gated by
`scripts/upstream-cite-check.sh` (in `make anchor-check`): floor 120 on its own scan, every cite
resolves in a clone/checkout/`.upstream-external-cites.json`, line numbers fit the file, and a
cite outside the reference set must carry the sha it was verified at.

## openclaw — designated, unread

`openclaw/openclaw` (TypeScript, 392k stars on 10-22, "The AI that really does things. Any OS.
Any Platform."). `git clone` from this host times out on git-over-https — `api.github.com` answers,
`github.com` does not — so the tree is being fetched by the owner. **No lesson is claimed for it
here.** A designated reference that nobody has read is not evidence; when the clone lands, run the
scan above and let it reorder this list or not.
