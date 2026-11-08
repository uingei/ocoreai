# What the field is evolving into — measured three ways, and refuted twice

Long form beside `comparator-consensus.md`, which answers **does the field agree on Y**. This file answers the
other question — **what is it becoming** — and that needs a time axis, which is why it needs more than one
instrument: each one below sees a different face of the same corpus, and each one has already contradicted a claim
made here.

> **Re-derive:** `bash scripts/comparator-consensus.sh` prints all of it — the axes (presence), the DIFFUSION and
> SEGMENT-AUDIT blocks (whose cut `comparator-innovation.md` reads), TREND and concept heat, the churn block, and
> the ledger block (`OC_TREND_DAYS=60` sets the window). Premise, because it decides
> every number: this box's mirrors at their 11-04 HEADs. No runner has `~/references`, so none of this is a gate; a
> cross-tree count is a direction input and a printed count carries no verdict. The blocks floor themselves rather
> than passing silently: `INSTRUMENT-DEAD` when a bucket matches zero files corpus-wide, `SMALL-N` when fewer than
> four ledgers carry a Fixed/Added verb, a per-tree `unmatched` residual printed instead of absorbed, a
> docs-mirror flag under 25 % source, and `OC_EVIDENCE=1` for one matched line per tree. The false positives these
> blocks produced are filed in one home: `comparator-consensus.md` § The ledger.

**Three instruments, three refutations, one day** — the reason this file exists instead of one more table:
presence/concept heat counts trees, so it saturates at 14/14 and cannot rank (it called confinement a direction);
churn by path counts touches, so it sees effort now but is blind to any mechanism whose filename does not carry it
(it called authority settled) and needs a mirror that contains the engine; release ledgers record what each tree
told a stranger it shipped, in order, and are published by only 15 of 29 trees — and it is this third instrument
that corrected the other two. What survives all three is what § Direction in `comparator-consensus.md` spends
against.

## What the field is evolving into — where the last 60 days of effort went

Cadence says a field is alive; heat says a mechanism is moving. Neither answers the question this file exists to
answer, because both count *trees*. The churn block answers it by counting *touches* (a file edited 200× is 200
touches, not one) and cutting them by what the path says the file is for.

> **Re-derive:** the churn block after TREND, `OC_TREND_DAYS=60`, now over **both** segments — the 13 comparator
> agent trees and the 11 comparator serve trees, us printed once at the end with the same `unmatched` residual the
> comparator rows carry. Three properties a reader needs before trusting any number here: buckets are **non-exclusive**, so
> shares do not sum to 100 % (`codex-rs/core/src/guardian/tests.rs` is authority *and* measurement); `unmatched` is
> printed per tree rather than hidden, and runs 12–59 %, mean 30 %, so every share below is a **floor**, not a
> total; and a path regex is a proxy for intent — which is why each tree's three hottest files print beside the
> shares, since those can be audited without trusting a pattern.

- **The surface is where the effort goes: ≥ 10 % of own churn in 11 of 13 trees, 19–57 % (12 of 13 on the 11-08
  re-derive — `pi` crossed the line, only `harness2` stays below).** `cline` 57, `opencode`
  38, `deepseek-harness` 32, `hermes-agent` 31, `OpenHands`/`goose` 29, `codex` 28 — shares from the older pass.
  On that pass only `pi` (8 %) and `harness2` (0 %) were not surface trees; by 11-08 `pi` crossed.
- **Inside the surface, the hottest file is often a locale table.** `../references/hermes-agent/apps/desktop/src/i18n/en.ts`
  377 touches, `../references/qwen-code/packages/web-shell/client/i18n.tsx` 199, `../references/opencode/packages/app/src/runtime/i18n/en.ts`
  161, `../references/OpenHands/src/i18n/translation.json` 112. Localization is non-zero in 9 of 13 trees (≥ 10 % in
  two). `hermes-agent` carries nine locales on disk — `ar de en es fr ja ru zh zh-hant` — with their own completeness
  gate (`../references/hermes-agent/apps/desktop/src/i18n/catalog-completeness.test.ts`, plus an `overlay-gaps.json`
  that names what is *not* translated). **Refuted an hour later, so it is stated as a split, not a trend:** the same
  corpus's deepest ledger records locale twice in 436 releases, first at #429 (§ What the field's own ledgers). The
  field genuinely disagrees about whether language is a product surface — the localizing half is `hermes-agent`,
  `opencode`, `qwen-code`, `OpenHands`; the other half is the most-installed agent in the list.
- **Measurement is the second universal — 9 of 13 — and it is productized, not internal.** `pi` 36 %, `hermes-agent`
  29 %, `harness2` 27 % (nothing else), `claude-code` 26 %, `Strata` 25 %. The single most-edited file in the largest
  tree in this corpus is `../references/openclaw/config/assertion-safety-baseline.txt` — 1 623 touches, 2 381 lines,
  header: *"Per-file counts of production type assertions without a `// SAFETY: invariant`. Ratchet: counts may only
  shrink."*, read by `../references/openclaw/test/scripts/check-assertion-safety-ratchet.test.ts`. That is our own
  B1 shrink-only-ratchet shape (`scripts/agents-md-contract.sh`) turned on a code property: the debt is a number, the
  number may only fall, and a test owns the direction.
- **The loop is a minority of effort now.** `loop/context` — context compaction, memory, sessions, rewind, budget —
  clears 10 % in **3 of 13**: `deepseek-harness` 14, `opencode` 12, `openclaw` 11. Not dead: `codex` sits at 9 % and
  its hottest source file is still the loop, `../references/codex/codex-rs/core/src/session/mod.rs` (193 touches).
  But 23–57 % goes to the surface while 6–14 % goes to the loop, and that ratio is the evolution: the loop has
  converged enough that the race moved around it.
- **Authority is invisible to churn in both directions, so nothing about it may be concluded from churn.** With the
  bucket split (see below) `approval` scores ≥ 10 % of own churn in **0 of 13** — high-water `codex` at 2 % — and
  `confinement` in **0 of 13**, with `deepseek-harness` at 0 % despite shipping the machinery: four
  `packages/sandbox/*` packages, 95 tracked files delivering "the confinement seam, per-platform backends, the
  shared policy resolver, and the Windows write-restriction rung", confining a subprocess to `read-only`,
  `workspace-write` or `danger-full-access` and naming its own ceiling in the same paragraph: *"Confinement is
  same-world only: it shares the host kernel and filesystem"*
  (`../references/deepseek-harness/packages/sandbox/README.md:12`). Shipped, and quiet — that half holds. The other
  half does not: the deepest ledger in this corpus records `permissions/approval` in **196 of 436 releases**
  and cost 15 % of every bullet that ledger has ever carried, which path shares cannot see because the work lands in
  `session/mod.rs`, `guardian/tests.rs` and `prompt.rs` — files named for structure, not for the mechanism. `codex`
  is the proof of the limit rather than an exception to it: it is the one tree that named its approval subsystem its
  own directory, and even there the churn sits in that directory's `tests.rs`, `mod.rs` and `runtime.rs`, so the
  bucket reads 2 %. **A share that cannot see a mechanism must not be quoted as its absence** — invariant 1, and this
  file wrote the wrong sentence anyway (§ The ledger).
- **Docs are a generated product surface, not a prose tax.** `deepseek-harness` spends 30 % of churn on docs/spec;
  its hottest docs files are `docs/config-catalog.md` (579) and `docs/config-catalog.zh.md` (566), both *generated
  from source* and — in the file's own words — "verified fresh by `pnpm run verify-config-catalog` (part of
  `doc-sync`)", where the generator cross-checks the runtime schema against the pasted declaration "so the paste
  cannot hide a loader-accepted field"
  (`../references/deepseek-harness/docs/config-catalog.md:8`). That is invariant 2 implemented as a doc build: the
  catalog cannot claim a knob the runtime refuses. Bilingual, generated, verified-fresh — our `make docs-check`
  re-derives figures in prose but does not generate a surface from code.

**The mirror, because the instrument scores us too:** ours is 3 579 touches across 783 files — `meas` 23 %, `engi`
17 %, `docs` 11 %, `deps` 10 %, `surf` 9 %, `tool` 8 %, `loop` 2 %. Our three hottest files over 60 days are
**`CHANGELOG.md` (376), `AGENTS.md` (137), `EngineInference.swift` (78)**. In twelve of the thirteen agent
comparators the most-edited file is something a stranger could click; in ours it is the diary and the rules file. The
serve cut below shows that sentence was about harnesses, not about the field — § What our own segment spends on. Our
`meas` share (23 %) already matches the field's second bucket, so no new spending is owed there.

Where this axis does *not* put us behind: `Sources/ocoreai/Localization/Localization.swift` holds 463 typed keys with
463 base and 463 zh entries, and `availableLocales` is `[.en, .zhHans]` with the rule "Adding ja/ko/fr/es requires a
full table entry before adding it here" (`:66-70`) — the picker offers only what has a table, and
`LocaleResolutionTests` proves coverage in both directions. Two locales against `hermes-agent`'s nine is a narrow
surface; it is not a false one. The field's advantage here is quantity, which is a translation task, not a design gap.

## What our own segment spends on — the serve cut, which inverts the headline above

The section above counts 13 harnesses and concludes the surface is where the field is going. This file's own premise
says a claim is worth the reading that goes red when it breaks, and the segment that carries **our** sentence — a
local model server on Apple silicon — had never been churned at all. Same buckets, same 60-day window, same code:

- **The two segments are near-mirrors.** `engine` clears 10 % of own churn in **10 of 11 serve trees** and in **1 of
  13 agent trees** (`Strata`, alone); `surface` in **7 of 11** serve against 11 of 13 agent; `meas` in 9 of each. So
  "the surface is where the effort goes" was an agent-segment sentence wearing a field-wide hat. It also says the
  buckets are not broken: a pattern that scores 10/11 here and 1/13 there is measuring a real shape difference
  between servers and harnesses, not a vocabulary accident.
- **Where the engine effort sits, per tree:** `splash` 69 %, `vllm` 47, `sglang` 34, `ollama` 32, `mlx-serve` 28,
  `TensorFold` 22, `Strata` 22, `MTPLX` 18, `Rapid-MLX` 18, **ours 17**, `omlx` 16, `openclaw` 7.
- **We clear our segment's floor and sit low in its distribution — and the distribution is not decidable yet.**
  17 % ≥ 10 %, so we belong to the 10/11 (the tally excludes us by construction); the eleven's median is ~22 %.
  Before that reads as a deficit, read the pattern: `model|engine|infer|kv|cache|kernel|serve|api|routes|server`. A
  Swift layout names those things otherwise, and `Sources/ocoreai/Handlers` (3.7 % of our churn), `Router` (1.5),
  `Multimodal` (1.0) and `Scheduler` (0.6) are wire-and-engine work the bucket cannot see — 6.8 % of our touches, on
  top of the 25 % `unmatched` our row now prints like every comparator's. Count those dirs as engine and we are near
  24 %, i.e. at the median. The honest statement is that we clear the floor and the **ranking** waits for a bucket
  that can read a Swift tree; the blindness is the same class this file documents elsewhere, met in our own row.
- **The one bucket where we lead the segment is the diary.** `deps/release` clears 10 % in **0 of 11** comparators
  and 10 % of ours, and that bucket's nouns are `changelog|version|manifest|*-lock`: our hottest file is
  `CHANGELOG.md`, 379 of 3 590 touches (10.6 %) — more of our churn in one prose file than any serve tree spends on
  the whole bucket. `docs/spec` at 11 % ties us with `Rapid-MLX` and `ollama` for the segment lead. (The row above
  reads 3 579 touches / 783 files and this one 3 590 / 785 because the 60-day window slid between the two runs an
  hour apart — stated because a reader who spots the difference should not have to wonder.)
- **Authority reads 0/11 here too, and in this segment that is partly absence, not blindness.** A server has no
  approval surface to edit; `openclaw` — the tree in both segments, and the one that resolves `sandbox-exec` in its
  macOS app — still scores 0 %. That is consistent with the ledger's ~15 % rather than contradicting it: governance
  work lives in the harness that asks, not in the server that answers.

**Consequence, stated as a retraction rather than a task.** "The field spends on the surface and we are behind on
it" is no longer available: 7 of 11 serving trees do, we sit at 9 % and our segment's majority bucket is the engine,
which we clear. This cut therefore licenses neither surface spending nor engine spending. What it does say is that in
our segment the field's touches are on the engine (10/11), that our row's only outlier is prose, and that `Strata`
and `openclaw` — members of both segments — vote twice with different denominators, which is what an honest segment
costs.

## What the field walked back of itself — 90 d of changelog reversals (11-08)

Consensus counts additions, churn counts flow; neither counts **removals**, and a retreat tells you what the ground
it stood on turned out to be. The mine: each tree's tracked changelog files, `+`-lines added in the window, the
removal verbs — then the matched lines **read by hand**, because of the ~1 000 hits essentially all were bug-fix
phrasing ("remove the case where X hangs") and five were something else. Re-derive the candidate pool with:

```
for t in ~/references/*/; do echo "$t $(git -C "$t" log --since=90.days -p --format= -- '*CHANGELOG*' |
  grep -icE '^\+.\s*(removed|deleted|dropped|disabled|reverted|retired|no longer)')"; done
```

(the pool is only the envelope; the verdicts below are what reading the matched lines produced, and the reading
is the claim).

- **The one that concerns us: the nearest tree walked part of our road and stepped back.** `Rapid-MLX` deleted its
  "Personal Intelligence": *"Local file and command tools are gone from Chat; the built-in tools are Web Search,
  Browse Web Page, Weather, and Read Attached Document again"*, with `/v1/models` dropping the
  `personal_intelligence_profile` field with it (its #4860, #4865). The serving tree closest to us — the one that
  ships our `launch <agent>` shape and reversible-merge safety — removed from its chat product the exact half our
  identity is made of. This does not falsify the fused product; it falsifies the half-fused one: what ours has and
  that Chat lacked is the approval gate (`DestructiveApprovalGateTests`), the one destructive truth
  (`ToolEntry.isDestructive` → `securityPrecheck`), the stall bound. It is the corpus's only field-tested negative
  about *file-and-command tools in a chat UI without that machinery*, and the tested verdict was deletion.
- **Where sequence is visible, a retreat names its destination.** `goose`'s "Delete the legacy agent loop" (its
  #12760) sits in the same window as two lines about the new loop owning tool-call checks (#12865) and ending runs
  promptly on Stop (#12765) — the deletion reads as a move, not an amputation.
- **Retirement gained manners, and they converge on ours.** `openclaw`'s retired synchronous methods "now name
  their awaited or V2 replacement before rejecting calls" (its #169750), and five SDK names that were *never
  stable* got pruned before they could become load-bearing (#170034): refuse-and-name-the-exit, plus
  prune-before-blessing — the copy shape root demands of our own refusals, independently adopted.
- **What the check discarded:** one `TensorFold` hit read as product retreat from its own checkpoint page-cache but
  is an A/B-harness hygiene line whose cited path does not exist at the mirror's HEAD — dropped as wrong-role; and
  `claude-code`'s three plugin-removal hits are fixes. Wrong-role is the whole disease; reading matched lines is
  the only cure that has ever worked here.

The verdict on the standing question — does following the field make it right: the reversals cluster exactly where
the form-consensus was thinnest, and they do not persist either. A crowd tells you which forms are cheap to buy;
it has never told anybody what to be, and its own additions are not durable.

## What the field's own ledgers say — the only source here that carries sequence

Churn measures *now* and cannot see a decision that stopped being edited. A per-version changelog is the other
instrument: written for the person deciding whether to install, it records what the tree *says* it shipped and in
what order. `claude-code/CHANGELOG.md` is the deepest such document in this corpus — 1.15 MB, **436 versions,
8 668 bullets** — and reading it, rather than counting how often it was edited, refuted two claims this file made
an hour earlier.

> **Re-derive:** the ledger block (runs before the trend block; `OC_NO_TREND=1` still prints it). It walks each
> tree's tracked `*CHANGELOG*` files, takes the one with the most version headings, and splits it into releases.
> Two self-checks print rather than pass silently: `SMALL-N` when fewer than 4 ledgers use a Fixed/Added verb,
> and the count of trees publishing no ledger at all.

- **Most of the field tells nobody what it shipped: 14 of 29 trees track no changelog anywhere** — including
  `hermes-agent`, `deepseek-harness`, `pi`, `ollama`, `omlx`, `sglang`, `vllm` and `Strata`. Of the rest, only
  **3** use a verb a machine can count, so the shares below are `claude-code` plus two, and the script says
  `SMALL-N` rather than letting it read as consensus.
- **Where a ledger exists, it is a list of things that broke.** `claude-code`: Fixed 66 %, Added 11 %,
  Improved 12 % — **fix:add 5.7 : 1** over 8 668 bullets. `cline`: 65 / 24, **2.7 : 1**. `opencode`: 26 / 64,
  **0.4 : 1**. Read against size — 436, 85 and 16 versions — the ratio tracks *age*, not diligence: a young tree
  ships capability, an old one ships correctness. The per-release fix share in claude-code's newest twelve
  releases runs 48 54 43 52 33 51 19 49 0 44 %, so it is not decaying, and the quintiles over the whole file show
  Added collapsing 12 → 15 → 14 → 7 → 6 % while Fixed climbs 11 → 24 → 54 → 62 → 50 % (verb counts 252 / 397 /
  1 606 / 1 932 / 4 481; the early "other" share is large because the ledger's own phrasing conventions changed,
  which is why those two columns are read as a trend and never as a level).
- **The order it recorded things in is the ladder** — release ordinal (of 436, oldest first) at which each axis
  first appears: **permissions/approval #2**, MCP #4, model/effort/thinking #10, compaction/memory #11, context
  budget #30, update/install #42, headless + SDK #50, plan mode #59, hooks/mods #67, subagents/background #75,
  tests/evals #118, plugins/marketplace #127, **sandbox #136 and skills #136 together**, remote/cloud #179,
  **localization #429**. Approval predates MCP by two releases and predates the extension surface by over a
  hundred; skills and OS confinement arrive in the same release (2.0.24); language is 8 releases from the end of a
  436-release ledger and appears twice.
- **Authority is not settled; it is permanent, and my "0 of 13" was a filename artifact.** The newest 10 releases
  spend 104 of 625 bullets (16 %) on auth/credential/permission/approval/consent/trust language; all 436 spend
  1 314 of 8 668 (15 %) — **flat across the whole life of the product**, and 19 % of its newest Adds are the same
  category (of 2.1.318's five Adds, three are credential-lifecycle or consent work: a record of the user's answer
  when asked to enable mods, a stored sign-in's expiry surfaced in `claude auth status`, a warning starting 10 days
  before it expires). The reconciliation is mechanical, and it says the instrument is blind rather than the field
  idle: authority work lands inside the files of the thing being guarded, so a path pattern only catches it when a
  *filename* carries the word — and even `codex`, the one tree that gave its approval subsystem its own directory
  (`guardian/`, holding `approval_request.rs`, `permissions.rs`, `decision.rs`, `score_authorization.rs`), spends
  that churn in the directory's `tests.rs`, `mod.rs` and `runtime.rs`, which is why it scores 2 % and not 15 %. A
  tool that cannot see a mechanism must not be allowed to report its absence; that is invariant 1 again, and this
  file wrote the wrong sentence anyway.
- **The mirror limit that makes the ledger load-bearing here:** `../references/claude-code` is not the engine — 1
  383 of its 1 473 tracked files are under `mods/` (1 353 `.ts`), i.e. the mod SDK, examples and issue surface. Its
  churn row therefore measures the *plugin API*, and its CHANGELOG is the only view of the loop itself that this
  box has. The churn block now flags any tree under 25 % source rather than letting a non-engine mirror vote on
  where effort goes, though `claude-code` passes that test on `.ts` — so the honest statement stays in prose.

**Consequence for us, stated where it belongs:** a public ledger is a minority practice (15/29 publish anything,
3 verb-labelled), so this axis adds no new adoption debt — and our `CHANGELOG.md` is deliberately a diary whose own
header says a person deciding what to install should read the release note instead. The ladder is the useful part
for us, because it prices *sequence*: approval before connectors, connectors before the extension surface, language
after 400 releases. Our own order — engine honesty, an approval gate that asks, 40 advertised tools, two complete
locale tables — does not match a field that recorded consent as its second-ever entry and language as its
next-to-last chapter.
