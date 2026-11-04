# What the field is evolving into — measured three ways, and refuted twice

Long form beside `comparator-consensus.md`, which answers **does the field agree on Y**. This file answers the
other question — **what is it becoming** — and that needs a time axis, which is why it needs more than one
instrument: each one below sees a different face of the same corpus, and each one has already contradicted a claim
made here.

> **Re-derive:** `bash scripts/comparator-consensus.sh` prints all of it — the axes (presence), TREND and concept
> heat, the churn block, and the ledger block (`OC_TREND_DAYS=60` sets the window). Premise, because it decides
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

> **Re-derive:** the churn block after TREND, `OC_TREND_DAYS=60` over the 13 comparator agent trees (us printed
> separately). Three properties a reader needs before trusting any number here: buckets are **non-exclusive**, so
> shares do not sum to 100 % (`codex-rs/core/src/guardian/tests.rs` is authority *and* measurement); `unmatched` is
> printed per tree rather than hidden, and runs 12–59 %, mean 30 %, so every share below is a **floor**, not a
> total; and a path regex is a proxy for intent — which is why each tree's three hottest files print beside the
> shares, since those can be audited without trusting a pattern.

- **The surface is where the effort goes: ≥ 10 % of own churn in 11 of 13 trees, 19–57 %.** `cline` 57, `opencode`
  38, `deepseek-harness` 32, `hermes-agent` 31, `OpenHands`/`goose` 29, `codex` 28. Only `pi` (8 %) and `harness2`
  (0 %) are not surface trees right now.
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
  `packages/sandbox/*` packages, 92 tracked files delivering "the confinement seam, per-platform backends, the
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
**`CHANGELOG.md` (376), `AGENTS.md` (137), `EngineInference.swift` (78)**. In twelve of the thirteen comparators the
most-edited file is something a stranger could click; in ours it is the diary and the rules file — and this round is
more of the same, which is the honest way to end this section. Our `meas` share (23 %) already matches the field's
second bucket, so no new spending is owed there.

Where this axis does *not* put us behind: `Sources/ocoreai/Localization/Localization.swift` holds 463 typed keys with
463 base and 463 zh entries, and `availableLocales` is `[.en, .zhHans]` with the rule "Adding ja/ko/fr/es requires a
full table entry before adding it here" (`:66-70`) — the picker offers only what has a table, and
`LocaleResolutionTests` proves coverage in both directions. Two locales against `hermes-agent`'s nine is a narrow
surface; it is not a false one. The field's advantage here is quantity, which is a translation task, not a design gap.

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
