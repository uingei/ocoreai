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

**Authority ships first, and never finishes.** codex put review/diff, sandbox, macOS
completion-notification and approval configuration inside its first 72 hours (open-sourced
2025-04-16); those four are still the most-trafficked surfaces of its 12,490 commits, while the
behavior-quality axes arrived 3–10 months later and cost far less each. Full dated chronology and
the per-axis fix proxy: `CHANGELOG.md`, the 10-22 round’s comparator-iteration-order entry.
Consequence: the polish
ocoreai keeps investing in — steering, compaction, tool-wire correctness, resume — sits in the
cheap cluster. That is the ticket to play, not the moat; the moat is an authority layer that
survives a year of adversarial use. We claim no sandbox, and the approval cache is byte-exact
payload (`Sources/ocoreai/Agents/Approval.swift:249`), so codex's macOS alias/mount-order fix log
(quoted in `CHANGELOG.md`) is the checklist for the day we do.

**KV reuse is a correctness surface, not a performance one.** ollama's `x/mlxrunner` — the closest
shipping analogue to our dual-path engine — published a nine-month cache-correctness series whose
worst entry is silent: a lazy KV snapshot indexes the cache's *live* buffer, so it must be copied
out before an append reaches the slots it names; they checked only the first append after a rewind
and only that append's own range, so "restoring that snapshot later silently serves the new
request's KV in place of the old conversation's." Two September fixes then dealt with budget
pressure: evict the active conversation's own checkpoints, and keep the reused head of a cached
edge safe from eviction (dated series: `CHANGELOG.md`).

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

**The meta-lesson.** Reading references is not the scarce act; keeping the claims they produce true is.
The gate is `scripts/upstream-cite-check.sh` (in `make anchor-check`): floor 120 on its own scan, every
cite resolves in a clone/checkout/`.upstream-external-cites.json`, line numbers fit, and an out-of-set
cite carries the sha it was verified at.

## openclaw — 116,620 commits, 2025-11-24 → 2026-10-21

The only rival here that is also a native Apple product: 1,591 Swift files,
`apps/{macos,ios,linux,android,macos-mlx-tts,swabble,shared}`, and a `packages/` split where the
agent loop sits behind a gateway protocol (`agent-core`, `gateway-client`, `gateway-protocol`,
`llm-core`, `net-policy`, `memory-host-sdk`, `model-catalog-core`) with the GUIs as clients. Its
axis order at 116k commits is codex's cluster reached twice as fast — authority in week one,
skills and memory inside a month, plan mode effectively absent (3 commits all time). Dated axis
table and fix proxies: `CHANGELOG.md`.

Four takes, ranked by what they change here:

1. **Plan mode is not what makes an agent do things.** codex added it at +278d (23/2 fix proxy);
   openclaw shipped a 392k-star "really does things" product without it. Budget memory, skills and
   subagent reliability before any plan-mode surface — ours is currently unwired, which is fine.
2. **On-device neural TTS is table stakes for a flagship Mac app; ours is OS voices.** openclaw
   isolates MLX audio in its own package + helper executable (`apps/macos-mlx-tts`, exact pin
   `mlx-audio-swift 0.1.5`, macOS 15 floor): streaming `AsyncThrowingStream<[Float], Error>`,
   `voice`/`referenceAudioPath`, a `CachedModel{repo, model}` actor, isolated "so normal macOS app
   tests do not compile the full MLX audio stack". Our `tts_speech` row is honest
   (`AVSpeechSynthesizer` + personal voice, installed voices measured at `POST /v1/multimodal/status`)
   — honest and weak is still weak on the speak axis. Closing it puts MLX audio in the build graph,
   which collides with the "one binary" identity line: bring that collision to the owner, it is the
   real decision.
3. **Char-based estimates break for CJK.** openclaw needed `fix(memory): account for CJK
   characters in QMD memory chunking`; we carry the same arithmetic open
   (`Models/TokenEstimate.swift`, gemma Chinese /3 measured 44–56% high). Two independent hits on
   one formula ⇒ per-model bytes/token stops being a nice-to-have.
4. **Compat faces earn their fix rate.** openclaw's `gate parallel_tool_calls to compatible APIs
   (#39356)` and `raw call to anthropic compatible apis (#21336)` are our two invariants seen from
   a third stack: keep `ToolCallWireContractTests` + `AnthropicToolDeliveryTests` strict, never
   relax per provider.

openclaw is deliberately **not** in `scripts/upstream-drift.sh`'s HEAD axes: at hundreds of
commits a day a HEAD window is permanent noise, and a warning that always fires is a warning nobody
reads when it becomes true. The shape worth adding is a release-tag axis (it publishes Sparkle
`appcast.xml`) — pending the owner's call on axes.

## The release cadence rule (measured 10-28, `api.github.com`)

`/releases?per_page=100` per tree — "≥100" is the page cap, not a count — and the newest release's age:

| tree | releases | newest | assets, last 10 | what the assets are |
|---|---|---|---|---|
| openclaw | ≥100 | 0 d | 103 | per-release `…-dependency-evidence.zip`: the artefact ships its own supply-chain evidence |
| codex | ≥100 | 0 d | **3 116** | platform × arch × variant, ≈312 per release, from **nine** release workflows (`rust-release.yml`, `python-sdk-release.yml`, `rust-release-windows.yml`, `r2-release.yml`, …) — one pipeline per distribution surface |
| opencode | ≥100 | 0 d | 360 | per-platform zips incl. `opencode-darwin-x64-baseline.zip` — degraded-not-failed, on the wire |
| vllm | ≥100 | 9 d | 83 | a wheel per Python × platform |
| omlx | ≥100 | 0 d | 45 | wheels per Python, plus the DMG a stranger drags |
| pi | ≥100 | 6 d | ~10 | install package + source tarball |
| sglang | ≥63 | 9 d | 0 | docs-site route |
| hermes-agent | 44 | 4 d | 0 | canary + stable + desktop-bundled workflows, no assets |
| coreai-models | 2 | 15 d | 0 | the reference-tree shape: consumed as a dependency, never installed |
| **ocoreai** | **1** | 0 d | 1 | the DMG a stranger drags (`ocoreai-0.1.14.dmg`, 25 965 037 B), published 10-29 by the `release` job — one data point, not a cadence |

The rule this implies, ranked by how much it changes spending:

1. **Cadence, not a tag.** Among trees a stranger *installs*, ≥100 releases and a newest-of-today is the
   norm, and the trust signals a first screen can show (a version badge, "released 0 days ago") are outputs
   of that cadence rather than inputs to it. Our `release` job is tag-gated and needs no owner credential,
   so the gap is a **tag-per-merge policy**, not engineering.
2. **Build and publish are different trust levels**
   (`../references/opencode/.github/workflows/release-dry-run.yml:4-9`): build jobs run repository code with
   no secrets and no `id-token`; sign/publish jobs run in a `release` environment, check out only
   `.github/release/`, treat artefacts as *data*, and never execute repository code. Ours does not —
   `.github/workflows/ci.yml:437` builds the app (xcodebuild — repository code) inside the job that holds
   `contents: write` (`:443`). Split them before self-serve publishing, and add a dry-run route so the
   release path runs on a PR without publishing anything.
3. **Ship the evidence with the artefact.** openclaw's per-release `dependency-evidence.zip` answers
   "what is in this binary" before it is asked; we already generate that answer
   (`scripts/collect-third-party-licenses.sh`, 38 notice files) and attach it to nothing.
