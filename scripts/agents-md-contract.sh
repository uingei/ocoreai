#!/usr/bin/env bash
# agents-md-contract.sh — AGENTS.md is injected into the model's context on every
# session: it is a per-session cost and a contract, not a note to self. This gate
# asserts the contract, because prose that says "grep-reproducible" is not
# reproducible unless something greps it.
#
# One rule decides the tier: a check BLOCKS when a red means a user, a caller or a session was
# acting on something false — a served surface, a quoted number, a license term, a pointer that
# sends an agent to the wrong file. Everything else is deleted. Measured 10-27: 329 of 1415 commits
# went to docs/CI/gates — one gate commit per three product commits — while the repo still had no
# tag, and the corpus had grown to ~170 KB of prose whose only defect was its own shape. Twelve
# same-round shape rules were deleted that day rather than left as warnings: a warning nobody acts
# on is decoration that costs every run, and "we have many gates" is not a claim anyone can verify
# by installing the thing. Checks still COUNTED and printed but no longer verdicted are marked
# "metric only" at their call sites.
#
# Deleted 11-07 by the owner, on the field-generality test (the 38 sampled trees cite suite NAMES,
# never a per-suite count): P11, the `XxxTests`(N) count gate — the claims were stripped from every
# contract surface instead of policed, since the promise the number made ("this much is covered")
# was itself the non-general artefact no stranger reads. Dated logs keep the counts they wrote.
#
# Deleted 10-28, so nobody re-adds them by accident: P13 (dated stamps and line walls inside
# AGENTS.md), P15 (corpus line walls), P16 (comparator coupling), P17 (area-guide scan floors),
# P20 (verbatim-duplicate bullets) and P18's diary CJK ceilings — the diary is excluded from the
# language rule now, not ceilinged. None of them had a red on record; B1 prices the bytes they
#                    policed. A new check names the red it was sampled against and the reader whose action it changes.
#
#   B1 root budget   the injected file stays under the pinned cap (shrink-only: `budget`
#                    lowers the constant, nothing raises it silently)
#   B2 chain budget  root + any area guide that loads with it stays under the chain cap
#   P1 scan floors   the scan proves it still matches content — a regex that stopped
#                    matching must fail loudly, not pass vacuously (V1EndpointCatalogTests
#                    pattern; the reason it exists here is that a repo-root built from two
#                    fixed `deletingLastPathComponent()` hops landed in Tests/ and three
#                    "passed" assertions were really ENOENT)
#   P2 refs resolve  every file the doc names exists here, exists in a local upstream
#                    clone, or is declared absent on the same line
#   P3 anchors       file:line / file#LNNN anchors point at a line that exists
#   P4 claims        <!-- claim:id=N :: shell --> runs and must equal N
#   P4b claim parity the same claim id written in two docs states one number — P4 checks each copy
#                    against its own predicate, so a number re-typed in one home and not the other
#                    leaves every copy green while the sentences above them disagree
#   P5 gates         every `make <target>` and scripts/*.sh named is real
#   P6 suites        every XxxTests named is declared under Tests/
#   P7 routing       every area guide on disk is listed in the root routing table
#   P8 pin agreement the upstream revision AGENTS.md quotes is the revision
#                    Package.swift actually pins — the pin is the contract (§ Upstream),
#                    and a stale SHA in the injected context sends every future session
#                    to audit the wrong commit
#   P9 routing targets are TRACKED, not merely present on this host
#   P10 human surface  README.md/README.zh.md are diffed against the code that serves the
#                    surface: the endpoint table must equal the router's route set, and the
#                    public-route sentence must equal AuthRoutePolicy.publicPaths
#   P12 xrefs      every `§ Name` used by AGENTS.md or a guide names a section that exists.
#                    §-references are how this corpus navigates, and the check's first run here
#                    found two citations of `§ Open` after that block lost its heading in an
#                    earlier trim — green before, because nothing read §-references (invariant 1
#                    again). Anchors include the bold pseudo-headings this corpus really uses.
#   P14 indexes   the probe index is compared with the filesystem: scripts/probes/README.md must
#                    index exactly the probe scripts that exist (no gap, no ghost), because an agent
#                    picks its probe from that index. Table arity and orphan docs are still counted
#                    and printed; their rules are deleted (10-27) — a miscounted column misrenders
#                    our prose, it does not send anyone somewhere wrong.
#   P18 doc language  docs are English by default and exactly one file is Chinese: README.md
#                    holds 0 CJK characters and README.zh.md is that mirror (the owner's
#                    rule). Enforced at zero wherever a newcomer or an agent reads: root docs,
#                    area guides, docs/**, script READMEs. The diary is EXCLUDED, not ceilinged:
#                    it is the owner's own log, and a ratchet that blocks them writing it in
#                    their own language is friction, not a contract. No raw \uXXXX escapes.
#   P21 knobs       every `OCOREAI_*` a human-facing doc names is read in code — the P2 dead-pointer
#                    class on the env axis: the operator exports the knob, nothing changes, the doc
#                    still promises the control. Comments do not count as wiring (a 11-11 manual scan's
#                    first answer was a false positive whose consumer lived in a marker's code line).
# Why this exists at all: three "verified" counts had already drifted and the Documentation Map
# pointed at files that are not in git — nothing read the docs, so nothing knew. The round's
# forensics are in CHANGELOG.md; this file carries the rules.
#
# Usage: bash scripts/agents-md-contract.sh [check|report|budget]
#   check   default; exit 1 on any violation
#   report  same output, always exit 0 (for read-only audits)
#   budget  lower the pinned root cap to the current size (refuses to raise it). Unit is BYTES
#           (wc -c), not characters — the messages used to say "chars", which is how a round of
#           CHANGELOG arithmetic quoted char counts against byte caps
set -uo pipefail
cd "$(dirname "$0")/.."

## ── pinned budgets (a raise must be a visible edit in the diff) ──────────────
# docs/agent/build-gate-reality.md and the "named, unused" comparator cells (splash, deepseek-harness).
: "${OCOREAI_AGENTS_MAX_ROOT:=21461}"   # pinned 10-28 by `make docs-budget`
                                     # `make docs-budget` may only lower it (B1 stays a ratchet)
# Two standing instructions about this corpus, kept here because they decide edits:
#  - docs/agent/build-gate-reality.md's dated block is load-bearing mechanism, not forensics — read it
#    before cutting it.

# P14 floor: probe scripts indexed in scripts/probes/README.md (measured 27 on 10-22), so a
# README whose index pattern rotted cannot report "every probe is documented" vacuously.
: "${OCOREAI_PROBE_FLOOR_INDEX:=20}"
# P14 floors for the other two index scans (measured 22 tracked .md, 7 files in docs/agent).
: "${OCOREAI_FLOOR_MD_SCANNED:=15}"
: "${OCOREAI_URL_FLOOR:=27}"      # P19: outbound URLs P19 must see (measured 10-27: 27 cited, non-loopback)
: "${OCOREAI_FLOOR_DOC_FILES:=5}"
: "${OCOREAI_FLOOR_KNOB_DOCS:=15}"  # P21's premise: knob names the docs promise (measured 20, 11-11)
: "${OCOREAI_FLOOR_KNOB_CODE:=50}"  # P21's walk must find knobs in code (measured 118, 11-11) — a
                                    # stopped consumer-walk would pass the promise scan vacuously
: "${OCOREAI_AGENTS_MAX_CHAIN:=32768}" # OUR cap, priced 10-27 and re-adopted as policy 11-03 (owner: codex
#   is no longer an authority). Same 32 KiB the injector spends (`WorkspaceContext.maxDocBytes`) and the
#   same number root's head quotes — `InstructionBudgetSingleSourceTests` goes red if the three homes drift
#   apart. A codex-style loader accepts this shape (`DEFAULT_PROJECT_DOC_MAX_BYTES`, decremented
#   oldest-first), which is why the number is 32 KiB and not invented; its `file:line` cites were dropped
#   11-03 because nothing re-verifies them (`anchor:codex` markers: 0, window unread). What stays is our own
#   measurement: the 36396 this replaced was our own largest root+doc pair, so B2 stayed green while the
#   real loader cut 562 B off the tail of Sources/ocoreai/Engine/AGENTS.md — root 21935 + guide 11395 =
#   33330 (10-27). A cap pinned to what exists is not a limit.
: "${OCOREAI_FLOOR_CHAIN_GUIDES:=3}"   # B2's premise: nested AGENTS.md the host can load (3 today)
: "${OCOREAI_AGENTS_FLOOR_FIGURES:=2}" # B2's premise: figure sites the docs header must still offer
#   (the ocoreai row + its prose tail). A re-derivation whose anchors vanished passes vacuously, so the
#   scan floors its own hit count instead of trusting the header it reads.
: "${OCOREAI_FLOOR_DIARY_PAIRED:=40}"   # CHANGELOG entries whose heading was found above their first bullet
: "${OCOREAI_FLOOR_CLAIM_SHARED_IDS:=3}"  # P4b's premise: claim ids written in more than one doc
#   (5 today — the licence counts, `spm_deps`, `global_rate_set`, mirrored across root + the README pair)
: "${OCOREAI_AGENTS_MAX_AREA:=53197}"  # each Sources/**/AGENTS.md or docs/agent/*.md (measured 10-27:
#   RAISED 10-28, visibly, per the rule at the head of this file: "Rung zero — adoption" plus the 10-28
#   adoption audit (CHANGELOG `adoption-audit-10-28`) carried long-horizon-goal.md to 15,609 B, past the file
#   this cap was pinned to. What binds is our chain budget (B2, 32 KiB) and the root ratchet (B1), and
#   neither moved: an area file is one hop out and is opened on purpose. Most of the detail went to
#   docs/agent/adoption-runbook.md first, and the ladder kept a pointer per rung.
#   build-gate-reality.md). Pinned to the largest file that exists: an area file is one hop out and
#   read on purpose, so the chain budget governs, not the area file.
#   RAISED 11-03, visibly, same rule: three comparator trees were registered (qwen-code, SWE-bench,
#   OpenHands) and comparator-repos.md grew to 18 664 B. Its size is a function of how many trees the
#   audit covers — 24 today, counted by the P1 scan below — so the alternative was deleting measured
#   file:line cites to fit a number no loader of ours charges. B1 (root) and B2 (the injected chain) did
#   not move: a docs/agent file is not in the chain.
#   RAISED 11-03(2), visibly, same rule: tree 25 — the corpus's first MODEL tree (`Qwen3.8-Flash-Next`,
#   README + tech report) — carried comparator-repos.md to 20 502 B, the largest file that exists, so the
#   cap follows its pin. B1 and B2 again untouched; the row is cite-dense by the same argument as above.
#   RAISED 11-04(2) and again 11-04(3), visibly, same rule — written together because the fourth and fifth
#   raises are one round: the whole-corpus direction read corrected four rows that were wrong about their own
#   trees (mlx-serve, TensorFold, qwen-code) and admitted a fifth cloned-but-never-registered (Qwen3.8) → 25 611 B;
#   its second half read five more (Strata, codex, vllm, sglang, plus re-deriving this file's own coupling list)
#   → 27 484 B. The alternative both times was deleting the `file:line` cites that make a claim checkable, the
#   trade 10-28 and 11-03 already refused. B1 (root, the only budget the injector spends) and B2 (the chain)
#   untouched across all five: 21 453/21 461 and 32 753/32 768.
#   RAISED 11-04(4), visibly, same rule — the sixth raise, and the first where the cut came first: the round
#   that content-checked this file's own cites wrote its instrument lesson into comparator-repos.md, then moved
#   it to competitor-iteration-paths.md § The meta-lesson, which already owns "keeping the claims true" (~0.8 KB
#   of second home deleted, not restated). What is left new is four rows getting their first real read —
#   harness2's second axis (five commits on grades), goose's unregistered `goose-local-inference` crate,
#   hermes-agent's two-tier skill catalogue with its consent boundary, and the corpus's one finding about us
#   (the env-inheritance open item's precedent) — over the same 26 trees, so
#   per-tree bytes move 1 057 → 1 244 and the curve is 15 609 → 18 664 → 20 502 → 25 611 → 27 484 → 32 341.
#   RAISED 11-04(5), visibly, the seventh raise, and the cut came first again: the round that read the corpus for
#   cross-tree CONSENSUS put its matrix and verdicts in a new `comparator-consensus.md` + `scripts/comparator-
#   consensus.sh` rather than in this file (~10 KB never landed here), and what did land is one row the corpus was
#   missing (`cline`: 71 277 stars, 855 tags, the tree this file's completeness sentence denied) plus two claims
#   corrected against the code instead of restated (this file's "26 on disk… counted by the P1 scan", which named
#   an instrument that never reads the disk, and Strata's flat "integrity still open", which is true of the `hf:`
#   route and false of the one we fetch ourselves). 27 trees now, so per-tree is 36 221 / 27 = ~1 341 B and the
#   curve is 15 609 → 18 664 → 20 502 → 25 611 → 27 484 → 32 341 → 36 221. B1 and B2 untouched (21 453/21 461,
#   32 753/32 768): this file is not in the injected chain.
#   RAISED 11-04(6), visibly, the eighth raise, cut first again and by more than any round before it: the corpus
#   gained its 28th tree (Rapid-MLX — the one that ships our own sentence, so the row is cite-dense on purpose),
#   and three field-level measurements left comparator-repos.md for comparator-consensus.md where their
#   denominators live (the AGENTS.md context-economy table, the coupling counts, the P1-completeness story) —
#   ~2.3 KB of second home deleted or moved, not restated. Net +1 671 B for a tree with 17 verified file:line
#   cites, so per-tree is 37 892 / 28 = ~1 353 B and the curve is 15 609 → 18 664 → 20 502 → 25 611 → 27 484 →
#   32 341 → 36 221 → 37 892. B1 and B2 untouched (21 453/21 461, 32 753/32 768): still not in the chain.
#   RAISED 11-04(7) the SAME DAY — the ninth, and the second for one and the same row, which is worth writing
#   down rather than glossing. Between the two numbers that row was read deeper: its tree turns out to ship its
#   own agent (12 registered tools, `write_file`/`patch`/`terminal`/`execute_code` among them, each with a risk
#   class that debits its own context cost), which falsified a wedge sentence already committed and moved two
#   rungs of the ladder. A row about the nearest neighbour in the corpus is simply more expensive to describe
#   than one about a distant tree: 4.3 KB of the 38 945 is `Rapid-MLX`, 4 232 files and 24 verified file:line
#   cites. Cut first twice (~3.3 KB moved out or deleted today), refused the alternative (deleting cites), and
#   the structural exit is an owner call, not a silent one: give the two or three nearest trees their own read-doc
#   and let the registry be an index — which costs a routing row each, and root has 18 bytes of B1 headroom, so
#   it cannot absorb the pointers without a cut. Per-tree now 38 945 / 28 = ~1 391 B; curve … → 37 892 → 38 945.
#   B1 and B2 untouched (21 443/21 461, 32 743/32 768).
#   Wider did not beat deeper this round; it went red at 4.9 KB and the owner is the one who decides whether
#   that curve is the shape they want. B1 and B2 untouched again (21 453/21 461, 32 753/32 768): this file is
#   not in the injected chain.
#   What the cap did NOT do, and now should: through its first five raises it forced exactly one cut (11-04(3), where the
#   mlx-serve and Qwen3.8 rows were restating verdicts § Rung zero 4 and § Open already own — 520 B of second
#   homes deleted before any raise was considered). The number worth reading at a glance is per-tree, not
#   per-file: 27 484 / 26 trees = ~1 057 B each, and the cap itself has been carried 15 609 → 18 664 → 20 502 →
#   25 611 → 27 484 by whichever file was largest. An owner deciding "audit deeper vs audit wider" needs that
#   curve; a per-file ceiling that never forces the choice is not how to make it. Turning this into a corpus cap
#   on docs/agent/** is an owner call, not an audit finding, so it is named here and not done here.
#   RAISED 11-06, the tenth, and the first that made per-tree CHEAPER: the 11-06 evolution read registered the
#   ten cloned-but-never-registered trees (llama.cpp, modelcontextprotocol, OSWorld, BrowserGym, terminal-bench,
#   Hybrid-Computer-Use, nanoGPT, llm.c, nanochat, autoresearch) — a distant tree costs ~0.7 KB against a
#   nearest neighbour's 4.3 KB, so per-tree moves 1 391 → 46 082 / 38 = ~1 213 B; the curve is
#   15 609 → 18 664 → 20 502 → 25 611 → 27 484 → 32 341 → 36 221 → 37 892 → 38 945 → 46 082. Cut first found
#   nothing: the only stale mass was the Rapid-MLX row's "org chart" clause, and correcting drift is not a cut.
#   The same read corrected open-items' seam hash (`db2e7bf`, not `991266ad3` — that hash is that day's #710, a
#   prefill buffer-cache commit). B1 21 444/21 461 (root's "28→38 trees" byte-neutral, +5 for the seam hash),
#   B2 32 744/32 768 — the same +5 flows into the chain; neither cap moved.
#   RAISED 11-09, the eleventh, cut-first honoured by this cap's own red: the round registered the two
#   cloned-but-never-registered trees (`claude-skills-official`, `claude-plugins-official`); the rows' first
#   drafts were full read-diaries and B2 went red at 49 327 B, so the diaries moved to CHANGELOG 11-09 and
#   each row kept ident + axis + cites — the alternative was again deleting measured `file:line` cites.
#   40 trees on disk now, per-tree 47 422 / 40 = ~1 186 B; the curve is
#   15 609 → 18 664 → 20 502 → 25 611 → 27 484 → 32 341 → 36 221 → 37 892 → 38 945 → 46 082 → 47 422.
#   B1 and B2 untouched: this file is still not in the injected chain.
#   RAISED 11-09(2), visibly, the twelfth, same rule: the disk sweep for self-improvement guidance surfaced a
#   registered tree's unregistered axis — qwen-code `auto-mode` keeps its own settings/skills/hooks/MCP files
#   off the write-approval fast path even against a `Bash(*)` allow-rule (`auto-mode.md:18-21,63-68`), a
#   comparator-side `autoloop-protected.txt` as a product rule — and the registry is the axis's one home.
#   Cut-first refused: funding a newly measured axis by deleting another tree's audited row is a content call,
#   not a budget one. +662 B → 48 077; per-tree 48 077/40 = ~1 202 B. B1 21 453/21 461 (root −3: the "38 trees"
#   count deleted rather than re-typed — the registry re-derives off disk), B2 32 750/32 768; neither cap moved.
#   RAISED 11-10, visibly, the thirteenth, same rule — and the first where the pin follows a DIFFERENT file:
#   comparator-consensus.md carried the line-ending split (pi/opencode/codex splice vs qwen-code flatten) and
#   two MCP false-positives read out of the spec (`outputSchema` SHOULD, `destructiveHint`) into 50 762 B.
#   Cut-first honoured inside what the round itself wrote (−373 B: the byte-pin and quote tails that restated
#   CHANGELOG 11-10), refused across files as 11-06 and 11-09(2) refused it — the alternative was deleting
#   another round's audited rows. P12 red rode along: the new entry wrote `§ Output Schema` for an EXTERNAL
#   section and the scanner reads § as "our section"; reworded — the sigil is ours, external refs name file+line.
#   Pin now = the largest file that exists: comparator-consensus.md 50 389 B; comparator-repos.md 48 077 B
#   sits 2 312 B under it. B1 21 453/21 461 and B2 chain 32 750/32 768 untouched: neither file is in the chain.
#   RAISED 11-10(2), visibly, the fourteenth, same rule: the disk sweep's five unregistered clones were
#   adjudicated the same morning it named them, and registration is this file's own duty (a disk tree without
#   a row is the open row the round closed) — +5 120 B → 53 197 for five rows, ~1 024 B/tree, the audited rows'
#   density, so further trimming would cut cites not prose. Cut-first honoured inside what the round itself
#   wrote (−81 B of round narration that CHANGELOG carries); refused across files as before. P12 rode along a
#   second time with the SAME class of error (`§ Licenses` for a root section named otherwise) — the 13th's
#   lesson already has its home above; reworded, not re-narrated. Pin now = comparator-repos.md 53 197 B;
#   comparator-consensus.md 50 389 B sits under it. B1 and B2 untouched: neither file is in the chain.
# P1 floors: keep just under the measured count so a broken scan is a failure, not a pass.
: "${OCOREAI_AGENTS_FLOOR_REFS:=50}"
: "${OCOREAI_AGENTS_FLOOR_TREES:=16}"
: "${OCOREAI_AGENTS_FLOOR_CLAIMS:=8}"
: "${OCOREAI_AGENTS_FLOOR_SUITES:=8}"
: "${OCOREAI_AGENTS_FLOOR_ROUTING:=4}"
# P18 floors: the language scan must keep matching real files (measured 26 English .md, 2 436
# CJK chars in the mirror) — a scan that silently finds nothing certifies an empty list.
: "${OCOREAI_FLOOR_LANG_SCANNED:=20}"
: "${OCOREAI_FLOOR_ZH_MIRROR_CJK:=2000}"

# P12 floor: the § cross-reference scan must keep matching, or "every ref resolves" is
# vacuous (measured 23 distinct refs across root + guides on 10-21).
: "${OCOREAI_AGENTS_FLOOR_XREFS:=12}"
# P10 floor: the router route scan must keep matching (measured 34 routes on 10-20), else
# the README-vs-router parity below compares against an empty set and passes vacuously.
: "${OCOREAI_README_FLOOR_ROUTES:=30}"
# P10 floor: CI job ids parsed from the `jobs:` section (measured 6 on 10-20).
: "${OCOREAI_README_FLOOR_JOBS:=5}"

MODE="${1:-check}"
if [ "$MODE" = budget ]; then
  size=$(wc -c < AGENTS.md | tr -d ' ')
  if [ "$size" -gt "$OCOREAI_AGENTS_MAX_ROOT" ]; then
    echo "❌ AGENTS.md is $size bytes > cap $OCOREAI_AGENTS_MAX_ROOT — the ratchet is shrink-only."
    echo "   Move a dated block to docs/agent/*.md and leave a pointer, then re-run."
    exit 1
  fi
  sed -i '' "s/: \"\${OCOREAI_AGENTS_MAX_ROOT:=.*$/\
: \"\${OCOREAI_AGENTS_MAX_ROOT:=$size}\"   # pinned $(date +%m-%d) by \`make docs-budget\`/" \
    scripts/agents-md-contract.sh
  echo "✅ re-pinned root cap $OCOREAI_AGENTS_MAX_ROOT -> $size bytes (shrunk $(( OCOREAI_AGENTS_MAX_ROOT - size )))"
  exit 0
fi

OCOREAI_AGENTS_MODE="$MODE" \
OCOREAI_AGENTS_MAX_ROOT="$OCOREAI_AGENTS_MAX_ROOT" \
OCOREAI_FLOOR_DIARY_PAIRED="$OCOREAI_FLOOR_DIARY_PAIRED" \
OCOREAI_FLOOR_CLAIM_SHARED_IDS="$OCOREAI_FLOOR_CLAIM_SHARED_IDS" \
OCOREAI_AGENTS_MAX_CHAIN="$OCOREAI_AGENTS_MAX_CHAIN" \
OCOREAI_FLOOR_CHAIN_GUIDES="$OCOREAI_FLOOR_CHAIN_GUIDES" \
OCOREAI_AGENTS_FLOOR_FIGURES="$OCOREAI_AGENTS_FLOOR_FIGURES" \
OCOREAI_AGENTS_MAX_AREA="$OCOREAI_AGENTS_MAX_AREA" \
OCOREAI_PROBE_FLOOR_INDEX="$OCOREAI_PROBE_FLOOR_INDEX" \
OCOREAI_FLOOR_MD_SCANNED="$OCOREAI_FLOOR_MD_SCANNED" \
OCOREAI_URL_FLOOR="$OCOREAI_URL_FLOOR" \
OCOREAI_FLOOR_DOC_FILES="$OCOREAI_FLOOR_DOC_FILES" \
OCOREAI_FLOOR_KNOB_DOCS="$OCOREAI_FLOOR_KNOB_DOCS" \
OCOREAI_FLOOR_KNOB_CODE="$OCOREAI_FLOOR_KNOB_CODE" \
OCOREAI_AGENTS_FLOOR_REFS="$OCOREAI_AGENTS_FLOOR_REFS" \
OCOREAI_AGENTS_FLOOR_TREES="$OCOREAI_AGENTS_FLOOR_TREES" \
OCOREAI_AGENTS_FLOOR_CLAIMS="$OCOREAI_AGENTS_FLOOR_CLAIMS" \
OCOREAI_AGENTS_FLOOR_SUITES="$OCOREAI_AGENTS_FLOOR_SUITES" \
OCOREAI_AGENTS_FLOOR_ROUTING="$OCOREAI_AGENTS_FLOOR_ROUTING" \
OCOREAI_AGENTS_FLOOR_XREFS="$OCOREAI_AGENTS_FLOOR_XREFS" \
OCOREAI_FLOOR_LANG_SCANNED="$OCOREAI_FLOOR_LANG_SCANNED" \
OCOREAI_FLOOR_ZH_MIRROR_CJK="$OCOREAI_FLOOR_ZH_MIRROR_CJK" \
OCOREAI_README_FLOOR_ROUTES="$OCOREAI_README_FLOOR_ROUTES" \
OCOREAI_README_FLOOR_JOBS="$OCOREAI_README_FLOOR_JOBS" \
python3 - <<'PY'
import glob, json, os, re, subprocess

repo = os.getcwd()
mode = os.environ.get("OCOREAI_AGENTS_MODE", "check")
fail, warn = [], []


def env_int(k):
    return int(os.environ[k])


def read(p):
    with open(p, encoding="utf-8") as fh:
        return fh.read()


root_text = read("AGENTS.md")
root_size = os.path.getsize("AGENTS.md")

# Locate every area guide by searching, never by a fixed relative hop.
guides = [p for p in glob.glob("Sources/**/AGENTS.md", recursive=True)
          + glob.glob("Tests/**/AGENTS.md", recursive=True)
          + glob.glob("docs/**/AGENTS.md", recursive=True)
          + glob.glob("docs/agent/*.md")]

# ── B1/B2 budgets ────────────────────────────────────────────────────────────
if root_size > env_int("OCOREAI_AGENTS_MAX_ROOT"):
    fail.append("B1 AGENTS.md %d bytes > cap %d (shrink-only ratchet: move a dated block "
                "to docs/agent/ and leave a pointer)" % (root_size, env_int("OCOREAI_AGENTS_MAX_ROOT")))
for p in guides:
    n = os.path.getsize(p)
    if n > env_int("OCOREAI_AGENTS_MAX_AREA"):
        fail.append("B2 %s %d bytes > per-guide cap %d" % (p, n, env_int("OCOREAI_AGENTS_MAX_AREA")))

# What the injector actually injects: AGENTS.md files, root down to the cwd, under one budget. A
# docs/agent file is never in that chain — a reader opens it on purpose and pays for it once — so
# pairing the root with one is what let the real chain rot: root+Engine was 562 B over the loader's
# 32 KiB while B2 measured root+build-gate-reality.md and called it the worst case.
chain_guides = [p for p in guides if os.path.basename(p) == "AGENTS.md" and p != "AGENTS.md"]
if len(chain_guides) < env_int("OCOREAI_FLOOR_CHAIN_GUIDES"):
    fail.append("B2 chain scan matched %d nested AGENTS.md (floor %d) — the file list is the premise, "
                "and a chain check that silently finds nothing passes vacuously"
                % (len(chain_guides), env_int("OCOREAI_FLOOR_CHAIN_GUIDES")))
# Reported (not judged): the number every doc that quotes a chain figure must be re-grepped against.
deepest_chain = 0
for p in chain_guides:
    chain = root_size + os.path.getsize(p)
    deepest_chain = max(deepest_chain, chain)
    if chain > env_int("OCOREAI_AGENTS_MAX_CHAIN"):
        fail.append("B2 chain AGENTS.md+%s = %d bytes > our %d-byte chain budget: %d bytes of this "
                    "guide are never injected — move long form to docs/agent/ and leave a pointer"
                    % (p, chain, env_int("OCOREAI_AGENTS_MAX_CHAIN"),
                       chain - env_int("OCOREAI_AGENTS_MAX_CHAIN")))

# The one place a chain figure is written down for a human is the context-economy table, homed in
# docs/agent/comparator-consensus.md since 11-04 (it is a cross-tree count with a denominator, which is
# that file's question and not comparator-repos.md's — see that file's § How to use 4; the check follows
# the decision's home, not the other way round). Twice on 10-28 a doc restated the number and drifted off
# the tree, and the header disagreed with itself (a 32 037 row beside a 723 B tail), so the row is
# re-derived here rather than trusted. Since 11-07 the row quotes only the PERCENT — the figure a reader
# actually acts on ("are we at our own cap?" decides whether the next root rule fits); the byte-exact
# triple lives at its one home, this check's live output, because no reader's action differs between
# 65 B and 41 B of headroom and a check that re-measures a byte copy exists to defend a second home
# CLAUDE.md says must not exist. The cap itself is still hard-enforced above, so this row can only read
# 100 % while the chain actually fits.
FIG_DOC = "docs/agent/comparator-consensus.md"
FIG_ROW = re.compile(r"\*\*ocoreai (\d+) % of its own cap")
FIG_TAIL = re.compile(r"ours is at (\d+) % of that line")

chain_cap = env_int("OCOREAI_AGENTS_MAX_CHAIN")
agents_corpus = root_size + sum(os.path.getsize(p) for p in chain_guides)
fig_want_pct = int(round(deepest_chain * 100.0 / chain_cap))
fig_sites = [int(m) for m in FIG_ROW.findall(read(FIG_DOC)) + FIG_TAIL.findall(read(FIG_DOC))]
if len(fig_sites) < env_int("OCOREAI_AGENTS_FLOOR_FIGURES"):
    fail.append("B2 re-derived %d figure site(s) in %s (floor %d) — the anchors are this check's premise,"
                " and a header that stopped matching them makes it pass vacuously"
                % (len(fig_sites), FIG_DOC, env_int("OCOREAI_AGENTS_FLOOR_FIGURES")))
for got in fig_sites:
    if got != fig_want_pct:
        fail.append("B2 %s quotes ours at %d %% while the chain reads %d %% of the cap — the percent is"
                    " the reader's figure, re-measure it (`make docs-check` prints the live chain)"
                    % (FIG_DOC, got, fig_want_pct))

# ── reference extraction (root + guides share the contract) ───────────────────
NAME = r"(?:~?/?[A-Za-z0-9_+.\-]+/)*[A-Za-z0-9_+.\-]*[A-Za-z0-9_+\-]"
FILE_RE = re.compile(r"(?<![\w/])(" + NAME + r"\.(?:swift|md|sh|yml|yaml|toml|json|h|hpp|metal|py|plist|txt|entitlements|xcprivacy|resolved))(?![\w.])")
ANCHOR_RE = re.compile(r"(?<![\w/])(" + NAME + r"\.(?:swift|md|sh|yml|yaml|json|h|py))(?::|#L?)(\d{1,5})")
# A verified-anchor marker (`anchor:omlx README.md:410 PagedSSDCacheManager`): its own cite carries
# the tree in `anchor:<tree>`, which P3 cannot resolve — bound by basename it is our README.md again.
ANCHOR_MARK = re.compile(r"anchor:([A-Za-z0-9._+-]+)\s+([^\s:]+):(\d{1,6})")
CLAIM_RE = re.compile(r"<!--\s*claim:([a-z0-9_]+)\s*(<=|>=|=)\s*(\d+)\s*::\s*(.+?)\s*-->")
MAKE_RE = re.compile(r"`make\s+([a-z][a-z0-9-]+)")
SUITE_RE = re.compile(r"\b([A-Z][A-Za-z0-9]*Tests)\b")
# A gate named with a number in parentheses is a claim about how much it covers.
ROUTING_RE = re.compile(r"(?<![\w/])((?:Sources|Tests)/[^\s|`,)]*AGENTS\.md|docs/agent/[A-Za-z0-9_\-]+\.md)")
# The author already said the thing is gone; do not re-report a declared absence.
ABSENT = ("does not exist", "no longer", "deleted", "removed", "absent", "never existed",
          "~~", "dead pointer", "不存在", "已删", "superseded", "0 refs", "0 hits", "0 sites")

on_disk = {p for p in glob.glob("**/*", recursive=True)
           if os.path.isfile(p) and "/.build" not in p and "/.git/" not in p}
tracked = set(subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.split())
by_base = {}
for t in sorted(tracked | on_disk):
    by_base.setdefault(os.path.basename(t), []).append(t)
# OS headers and upstream-tree paths cited as evidence but not carried here. CI has none
# of these, so they are resolves-by-allowlist, never resolves-by-faith: adding one means
# the doc really did cite an outside tree.
SYSTEM_REFS = ("UIPasteboard.h", "arg_reduce.metal", "device.cpp", "GPU+Metal.swift",
               "CoreAIRuntime.swiftinterface", "coreai.json", ".swiftinterface")
# Residual cites into comparator trees: the ones a block does NOT attribute (no tree name ahead of the
# cite), so the doc has to name them here. The corpus-tree set itself is derived from
# docs/agent/comparator-repos.md above, which is why this list is short and shrinks — 19 entr(ies)
# left it on 10-28 once paragraph attribution landed. It rots in both directions on purpose: delete an
# entry whose block still names no tree and its cite goes red; keep one nothing cites, or one whose
# block has learned to name its tree, and the two checks below go red. § Upstream 5 is the policy:
# comparators are not pins, nothing here is redistributed, and a borrowed verdict stays an inference.
COMPARATOR_REFS = (
    "PROVENANCE.md",
    "serving_chat.py")
# Two home candidate sources, because $HOME is not a stable fact here: the documented
# CLT/sandbox recipe exports HOME=/private/tmp/codexhome, and a resolver that asks $HOME
# where the reference trees live then reports every upstream cite as unresolved. A gate
# that cries wolf for the wrong reason is a gate people learn to ignore — so the passwd
# entry is consulted too, and the run says how many trees it actually searched.
def _homes():
    out = [os.environ["HOME"]] if os.environ.get("HOME") else []
    try:
        import pwd
        out.append(pwd.getpwuid(os.getuid()).pw_dir)
    except Exception:  # noqa: BLE001 - pwd is a nicety, not a premise
        pass
    return sorted({os.path.expanduser(h) for h in out})


HOMES = _homes()
# Which comparator trees exist on this box is exactly what decides a P2 red here, and a premise that
# decides a verdict has to be reproducible on demand, not inherited from what the host happens to
# hold (invariant 1). `OCOREAI_AGENTS_NO_HOST_REFS=1` judges the docs with a runner's premise: no
# ~/references, dependency checkouts and this repo's own files only.
NO_HOST_REFS = os.environ.get("OCOREAI_AGENTS_NO_HOST_REFS") == "1"
clones = [] if NO_HOST_REFS else sorted(
    {p for h in HOMES for p in glob.glob(os.path.join(h, "references/*"))})
# The dependency checkouts this repo actually compiles: on CI there is no ~/references, but
# a leg that resolved the pin can still resolve an upstream basename against real code.
if not NO_HOST_REFS:
    for _base in (".build-clt/checkouts", ".build/checkouts"):
        clones += sorted(glob.glob(os.path.join(repo, _base, "*")))
clones = sorted(set(clones))
clone_index = {}
for c in clones:
    out = subprocess.run(["git", "-C", c, "ls-files"], capture_output=True, text=True).stdout.split() \
        if os.path.isdir(os.path.join(c, ".git")) else []
    for t in out:
        clone_index.setdefault(os.path.basename(t), []).append(os.path.relpath(c, repo))

docs = {"AGENTS.md": root_text, "README.md": read("README.md"), "README.zh.md": read("README.zh.md")}
docs.update({p: read(p) for p in guides})

# ── which trees are outside this repo, derived not hand-written ─────────────────────────
# § Upstream Audit Dependencies 6 says the comparator set IS docs/agent/comparator-repos.md, and each
# entry there opens with a "`<tree>` \u2014" bullet: that file is the declaration home, so this reads it
# instead of keeping a second list here (one home per decision). A cite into one of those trees can
# never resolve on a runner, so the honest question is not "does the file exist" but "does the doc say
# which tree it came from" \u2014 the same evidence a human uses, one wrap away from the cite.
COMPARATOR_DOC = "docs/agent/comparator-repos.md"
TREE_BULLET = re.compile(r"^- ((?:`[A-Za-z0-9][A-Za-z0-9_.-]*`(?: \(pin \d\))?[ ,/and]*)+)\u2014", re.M)
comparator_trees = sorted({t for line in TREE_BULLET.findall(read(COMPARATOR_DOC))
                           for t in re.findall(r"`([A-Za-z][A-Za-z0-9_.-]*)`", line)})
# A dependency is a tree too, and Package.swift is its declaration home: `Sources/HuggingFace/Hub/
# HubClient.swift` lives in swift-huggingface, which no runner has either. Deriving both sets from
# files in this repo keeps the second list at zero.
dep_trees = sorted({m for m in re.findall(r'url: "https?://[^"]+/([A-Za-z0-9_.-]+?)(?:\.git)?"',
                                          read("Package.swift"))})
attribution_trees = sorted(set(comparator_trees) | set(dep_trees))
TREE_AT = {t: re.compile(r"(?<![A-Za-z0-9_./-])" + re.escape(t) + r"(?![A-Za-z0-9_-])")
           for t in attribution_trees}
OUTSIDE_FORM = re.compile(r"^(?:\.\./|~/)?references/([A-Za-z0-9_.-]+)/")

def para_ids(text):
    """The block a human reads when resolving a cite: a prose block, or one bullet of a list \u2014 a
    bullet list with no blank lines between items is NOT one paragraph, or every cite in the corpus
    doc would attribute to every tree in it."""
    ids, pid = [], 0
    for ln in text.split("\n"):
        if not ln.strip() or ln.startswith("- "):
            pid += 1
        ids.append(pid)
    return ids

def paragraphs(text):
    ids = para_ids(text)
    out = {}
    for i, ln in enumerate(text.split("\n")):
        out.setdefault(ids[i], []).append(ln)
    return {k: "\n".join(v) for k, v in out.items()}

def tree_before(para, cite):
    """The tree in force at this cite: the closest tree name ahead of it in the same block, which is how
    a reader resolves it ("**opencode** — intake closed by bots (`triage-close-issues.yml`…)"). A cite
    with no tree name ahead of it in the block is unattributed, and that is the red: a runner has no
    ~/references, so such a cite is a dead pointer there and a puzzle here."""
    best, pos = None, -1
    start = 0
    while True:
        at = para.find(cite, start)
        if at < 0:
            return best
        for t, rx in TREE_AT.items():
            hits = [m.start() for m in rx.finditer(para[:at])]
            if hits and max(hits) > pos:
                best, pos = t, max(hits)
        start = at + len(cite)

refs, anchors, claims, suites, make_targets, routing = set(), set(), set(), set(), set(), set()
marker_cites = set()  # (path, line) inside a foreign `anchor:<tree>` marker — anchor-check's, not P3's
cite_where = {}   # path -> {(doc, paragraph id)} for every cite that is not declared absent
for src, text in docs.items():
    paras = paragraphs(text)
    ids = para_ids(text)
    for raw, pid in zip(text.splitlines(), ids):
        line = re.sub(r"https?://\S+", " ", raw)  # URLs are cites, not repo paths
        exempt = any(m in line for m in ABSENT)
        for m in FILE_RE.finditer(line):
            refs.add((src, m.group(1)))
            if not exempt:
                refs.add(("!", src, m.group(1)))
                cite_where.setdefault(m.group(1), set()).add((src, pid))
        for m in ANCHOR_RE.finditer(line):
            anchors.add((src, m.group(1), int(m.group(2))))
        for m in ANCHOR_MARK.finditer(line):
            if m.group(1) != ".":  # `anchor:.` cites the working tree, which resolves-here can judge
                marker_cites.add((m.group(2), int(m.group(3))))
        # Raw line, not the URL-stripped one: a claim's command may BE a URL fetch, and
        # stripping it silently re-pointed the tag claim at origin's ssh transport (11-11).
        for m in CLAIM_RE.finditer(raw):
            claims.add((src, m.group(1), m.group(2), int(m.group(3)), m.group(4)))
        suites.update((src, s) for s in SUITE_RE.findall(line))
        make_targets.update(MAKE_RE.findall(line))
        routing.update((src, r) for r in ROUTING_RE.findall(line))

hard_refs = sorted({r for t in refs if t and t[0] == "!" for r in t[1:]})
doc_paras = {src: paragraphs(text) for src, text in docs.items()}
if len(comparator_trees) < env_int("OCOREAI_AGENTS_FLOOR_TREES"):
    fail.append("P1 only %d comparator trees derived from %s (floor %d) — the entry regex "
                "stopped matching, so every outside cite below would be judged blind"
                % (len(comparator_trees), COMPARATOR_DOC, env_int("OCOREAI_AGENTS_FLOOR_TREES")))

# ── P1 floors: prove the scan is still scanning ──────────────────────────────
if len(hard_refs) < env_int("OCOREAI_AGENTS_FLOOR_REFS"):
    fail.append("P1 only %d gateable file refs found (< floor %d) — the reference regex "
                "stopped matching, so every other check here is vacuous" % (len(hard_refs), env_int("OCOREAI_AGENTS_FLOOR_REFS")))
if len(claims) < env_int("OCOREAI_AGENTS_FLOOR_CLAIMS"):
    fail.append("P1 only %d <!-- claim:… --> markers (< floor %d) — a doc whose numbers are "
                "not machine-checkable cannot gate itself" % (len(claims), env_int("OCOREAI_AGENTS_FLOOR_CLAIMS")))
if len(suites) < env_int("OCOREAI_AGENTS_FLOOR_SUITES"):
    fail.append("P1 only %d *Tests names (< floor %d)" % (len(suites), env_int("OCOREAI_AGENTS_FLOOR_SUITES")))
if len(routing) < env_int("OCOREAI_AGENTS_FLOOR_ROUTING"):
    fail.append("P1 only %d routing-table rows (< floor %d)" % (len(routing), env_int("OCOREAI_AGENTS_FLOOR_ROUTING")))

# ── P2 refs resolve ──────────────────────────────────────────────────────────
unresolved, ambiguous, upstream = [], [], []
declared_outside, declared_context, attributed = [], [], {}
for r in hard_refs:
    if r.startswith("~/") or r.startswith("/"):
        targets = [os.path.expanduser(r)]
        if r.startswith("~/"):
            targets += [os.path.join(h, r[2:]) for h in HOMES]
        if not any(os.path.exists(t2) for t2 in targets):
            warn.append("P2 host-local path not on this host: %s (must be declared host-local, not project truth)" % r)
        continue
    # A path that carries its tree (`../references/vllm/docs/x.md`) declares itself, and it is matched
    # BEFORE resolves-here so a comparator file cannot borrow the credit of a same-named local one:
    # `AGENTS.md` exists in both trees and only one of them is ours.
    form = OUTSIDE_FORM.match(r)
    if form and form.group(1) in TREE_AT:
        declared_outside.append(r)
        attributed[r] = form.group(1)
        continue
    if (r in tracked or r in on_disk or os.path.exists(r)
            or any(r.endswith(x) for x in SYSTEM_REFS)):
        continue
    base = os.path.basename(r)
    if base in by_base:
        continue
    if base in clone_index:
        trees = sorted(set(clone_index[base]))
        shown = ",".join(trees[:3]) + (",+%d more" % (len(trees) - 3) if len(trees) > 3 else "")
        upstream.append("%s (%s)" % (r, shown))
        continue
    # Per occurrence, not per path: a cite appearing in two different trees' bullets is honest as long
    # as EACH bullet says which tree it means, and dishonest the moment one of them stays silent.
    named, silent = set(), []
    for src, pid in sorted(cite_where.get(r, ())):
        hit = tree_before(doc_paras[src].get(pid, ""), r)
        if hit:
            named.add(hit)
        else:
            silent.append("%s:%d" % (src, pid))
    if r in COMPARATOR_REFS and silent:
        declared_outside.append(r)
        continue
    if named and not silent:
        declared_context.append(r)
        attributed[r] = ",".join(sorted(named))
        continue
    if named:
        ambiguous.append("%s (%s)" % (r, " ".join(silent)))
        unresolved.append(r)
        continue
    if r in COMPARATOR_REFS or base in COMPARATOR_REFS:
        declared_outside.append(r)
        continue
    unresolved.append(r)
if unresolved:
    fail.append("P2 %d unresolved reference(s) — no such file here, no basename match in git, not "
                "in a local upstream clone, and the paragraph that cites it names no comparator tree "
                "(a runner has no ~/references, so an unattributed cite is a dead pointer there): %s"
                % (len(unresolved), ", ".join(unresolved)))
if ambiguous:
    fail.append("P2 %d cite(s) in a block that names no tree ahead of them (%s) — name the tree, or "
                "write the path as `references/<tree>/…`; a reader cannot resolve these either"
                % (len(ambiguous), ", ".join(ambiguous)))
# A declaration that no doc uses is an exemption with no owner, and a list nobody trims is how
# allowlists become a way of not looking. Both directions are cheap to check, so both are checked.
dead_declarations = [d for d in COMPARATOR_REFS
                     if not any(h == d or os.path.basename(h) == d for h in hard_refs)]
# The paragraph rule replaces a hand-written name, so an entry that only ever matched cites which
# already name their tree has no job left — and an allowlist entry with no job is how a gate turns
# into a habit of not looking.
redundant = [d for d in COMPARATOR_REFS
             if any(h == d or os.path.basename(h) == d for h in attributed)
             and all(h in attributed for h in hard_refs if h == d or os.path.basename(h) == d)]
if redundant:
    fail.append("P2 %d allowlist entr(ies) the docs no longer need because the cite names its tree (%s)"
                " — delete them" % (len(redundant), ", ".join(redundant)))
if dead_declarations:
    fail.append("P2 %d declared outside-tree cite(s) no longer cited by any doc (%s) — delete "
                "them; an unused declaration is an exemption, not a fact"
                % (len(dead_declarations), ", ".join(dead_declarations)))
# Declaring a file outside-tree while the repo carries it is simply wrong, and that is the only
# "resolved anyway" that means anything: on a host with the comparator trees cloned these cites
# resolve through the clone and never need the declaration (CI is where they do).
unused_cites = sorted({r for r in hard_refs
                       if (r in COMPARATOR_REFS or os.path.basename(r) in COMPARATOR_REFS)
                       and (r in tracked or r in on_disk
                            or os.path.basename(r) in by_base)})
if unused_cites:
    fail.append("P2 %d outside-tree declaration(s) are carried by the repo itself (%s) \u2014 "
                "drop the declaration; the cite resolves here"
                % (len(unused_cites), ", ".join(unused_cites)))

# ── P3 anchors in range ──────────────────────────────────────────────────────
# A cite that carries a known tree (`../references/omlx/README.md:410`) follows P2's rule — judged
# before resolves-here, never by basename, or it borrows the credit of a same-named local file. On a
# runner without the clone the basename fallback measured OUR README.md against THEIR line count:
# red on a valid cite (11-05 CI: omlx:410 against our README's 274 lines) and vacuous on a stale one
# the day ours grows past it. Where the tree exists the line is checked against the real file; where
# it does not, resolvability is P2's and the line truth is `make anchor-check`'s — P3 says nothing,
# and prints how many it stayed silent about, so a scan that went quiet stays visible.
bad_anchors = []
silent_tree = 0
marker_owned = 0
for src, f, ln in sorted(anchors):
    if (f, ln) in marker_cites:
        # A marker's cite carries its tree in `anchor:<tree>`, which P3 cannot resolve — bound by
        # basename a marker's `README.md:410` is our README.md again (same credit-borrow rule as
        # above). `make anchor-check` reads the real file at that tree, so EOF rides with content.
        marker_owned += 1
        continue
    form = OUTSIDE_FORM.match(f)
    if form and form.group(1) in TREE_AT:
        tail = re.sub(r"^(?:\.\./|~/?)", "", f)
        cand = next((c for c in [f, os.path.expanduser(f)]
                     + [os.path.join(h, tail) for h in HOMES] if os.path.isfile(c)), None)
        if cand is None:
            silent_tree += 1
            continue
    else:
        cand = (f if (os.path.exists(f) or f in tracked)
                else (by_base.get(os.path.basename(f)) or [None])[0])
    if not cand:
        continue  # P2 already decided resolvability for this basename
    try:
        n = sum(1 for _ in open(cand, encoding="utf-8", errors="replace"))
    except OSError:
        continue
    if ln > n:
        bad_anchors.append("%s:%d (%s has %d lines)" % (f, ln, cand, n))
if bad_anchors:
    fail.append("P3 %d anchor(s) past end of file: %s" % (len(bad_anchors), "; ".join(bad_anchors)))

# ── P4 claims reproduce ──────────────────────────────────────────────────────
ok_claims, bad_claims = 0, []
for src, cid, op, expect, cmd in sorted(claims):
    try:
        out = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=30)
        got = out.stdout.strip().splitlines()
        got = int(got[-1]) if got else -1
    except Exception as exc:  # noqa: BLE001 - report, never crash the gate
        bad_claims.append("%s: command failed (%s)" % (cid, exc))
        continue
    # Direction is part of the claim: >= guards a floor that must never shrink, <=
    # guards a hygiene ceiling that must never grow, = is for facts that only move
    # when this doc is edited.
    if {"=": got == expect, "<=": got <= expect, ">=": got >= expect}[op]:
        ok_claims += 1
    else:
        bad_claims.append("%s %s %d: command returns %d  [%s]" % (cid, op, expect, got, cmd))

if bad_claims:
    fail.append("P4 %d claim(s) do not reproduce: %s" % (len(bad_claims), "; ".join(bad_claims)))

# ── P4b one claim id, one stated number ──────────────────────────────────────
# P4 judges every copy of a claim against ITS OWN predicate, so a number that moves in one
# home and not another leaves all copies green: five Apple-header files landed 11-05/11-06,
# root's copy moved to `>=49` while the README pair stayed at `>=44`, and the English and
# Chinese sentences above those markers stated 44 and 49 on the same day. The floor is the
# wrong shape for a number a sentence re-types: it can only see a fall. Where the same id is
# written in more than one file, the predicate itself has to agree — nothing new runs here,
# it reads the tuples P4 already collected. The diary is not in `docs` (a CHANGELOG entry
# quotes the number its own round measured), so this compares live pins only.
claim_homes, claim_preds = {}, {}
for _src, cid, op, expect, _cmd in claims:
    claim_homes.setdefault(cid, set()).add(_src)
    claim_preds.setdefault(cid, set()).add((op, expect))
split = sorted(c for c, preds in claim_preds.items() if len(preds) > 1)
if split:
    fail.append("P4b %d claim id(s) state more than one number across their homes: %s — the copy "
                "left behind is the sentence a reader acts on"
                % (len(split), "; ".join(
                    "%s=%s" % (c, "/".join(sorted("%s%d" % (o, e) for o, e in claim_preds[c])))
                    for c in split)))
# Floor the premise: an id shared by two homes is what this rule compares. If the marker regex
# or the file set ever moves so that no id is written twice, the rule above passes by holding an
# empty table — which is how a scan quietly retires while still printing a verdict.
shared = sorted(c for c, hs in claim_homes.items() if len(hs) > 1)
if len(shared) < env_int("OCOREAI_FLOOR_CLAIM_SHARED_IDS"):
    fail.append("P4b only %d claim id(s) are written in more than one doc (< floor %d) — nothing "
                "left for the parity rule to compare, so it is green by finding nothing"
                % (len(shared), env_int("OCOREAI_FLOOR_CLAIM_SHARED_IDS")))
# A claim's command runs on a runner too, and a clean checkout is not this host. 10-29 shipped
# `<!-- claim:tags_published>=1 :: git tag | grep -c '^v' -->` green through every local mode and red
# on two consecutive `Text gates (ubuntu)` runs (`command returns 0`): a depth-1 checkout may hold no
# tags, and `fetch-tags: true` did not change the verdict. Worktree reads (`git grep`, `git ls-files`)
# travel with the checkout; the ref store does not. A claim that asks the remote reds as
# `returns 0` when the ask itself fails (no network) — read the command before the number.
REF_STORE_RE = re.compile(r"\bgit\s+(tag|describe|rev-list|merge-base|branch|remote)\b")
bad_premise = ["%s: `%s` reads the local ref store" % (cid, cmd)
               for _src, cid, _op, _exp, cmd in claims if REF_STORE_RE.search(cmd)]
if bad_premise:
    fail.append("P4 %d claim(s) read a local git ref, which a shallow checkout need not have: %s"
                % (len(bad_premise), "; ".join(bad_premise)))

# ── P5/P6 gates and suites exist ─────────────────────────────────────────────
mk = read("Makefile")
missing_targets = sorted(t for t in make_targets if not re.search(r"^%s:" % re.escape(t), mk, re.M))
if missing_targets:
    fail.append("P5 `make %s` named in the docs but not in Makefile" % ", ".join(missing_targets))

tests_src = "\n".join(read(p) for p in glob.glob("Tests/**/*.swift", recursive=True))
test_files = {os.path.basename(p) for p in glob.glob("Tests/**/*.swift", recursive=True)}
missing_suites = sorted({s for _, s in suites
                         if s not in tests_src and ("%s.swift" % s) not in test_files})
if missing_suites:
    fail.append("P6 %d test suite(s) named but not declared under Tests/: %s"
                % (len(missing_suites), ", ".join(missing_suites)))

# ── metric only (11-07): @Test-file count, no verdict (P11 deleted with its claims) ──
test_fn_counts = {}
for p in glob.glob("Tests/**/*.swift", recursive=True):
    test_fn_counts[os.path.splitext(os.path.basename(p))[0]] = len(
        re.findall(r"^\s*@Test\b", read(p), re.M))

# ── P7 routing covers every guide on disk ───────────────────────────────────
listed = {r for _, r in routing}
unrouted = sorted(p for p in guides if p not in listed)
if unrouted:
    fail.append("P7 area guide(s) exist but no routing row in AGENTS.md: %s" % ", ".join(unrouted))

# ── P9 routing targets are TRACKED, not merely present ──────────────────────
# A routing row is a promise that a fresh clone contains the file. Measured 10-17: `docs/`
# sat in .gitignore (under "Reference repos") while AGENTS.md routed its long-form proof
# into docs/agent/*.md — three guides, ~19 KB of the evidence layer that every session is
# told to read, present on this host and absent in every clone and CI leg. P7 could not see
# it because P7 compares the routing table against the *disk*, which is exactly the
# environment the claim must not be inferred from (invariant 1).
untracked = []
for r in sorted(listed):
    if not (r.startswith("docs/") or r.startswith("Sources/")):
        continue
    if subprocess.run(["git", "ls-files", "--error-unmatch", r],
                      capture_output=True).returncode != 0:
        untracked.append(r)
if untracked:
    fail.append("P9 routing target(s) not tracked in git — the root promises an evidence hop "
                "that a fresh clone does not contain: %s" % ", ".join(untracked))

# ── P8 the pin the doc quotes is the pin the manifest sets ─────────────────
# Measured 10-15: Package.swift pinned mlx-swift-lm at 4cc550451 (and .build-clt
# resolves exactly that) while AGENTS.md still said "Pinned … at 7eb77ef" — one bump
# behind, in the one file every session reads first. The audit protocol keys off that
# sentence, so a stale pin does not merely read badly: it aims the next audit at the
# wrong commit.
pkg = read("Package.swift")
m = re.search(r'mlx-swift-lm\.git",\s*revision:\s*"([0-9a-f]{7,})"', pkg)
if not m:
    fail.append("P8 no mlx-swift-lm `revision:` found in Package.swift — the pin contract is unreadable")
else:
    pin = m.group(1)
    # Form was "Pinned upstream `mlx-swift-lm` at `…`" until 10-22, when the root rewrite moved the
    # sentence into the numbered upstream list. The gate's job is the comparison, not the wording:
    # match any hex token quoted near the repo name (still a token in backticks, so prose that merely
    # names the repo does not satisfy it).
    quoted = set(re.findall(r"`mlx-swift-lm`[^\n]{0,120}?`([0-9a-f]{7,})`", read("AGENTS.md")))
    if not quoted:
        fail.append("P8 AGENTS.md no longer states the mlx-swift-lm pin in the form the gate reads")
    elif not any(q == pin or pin.startswith(q) or q.startswith(pin) for q in quoted):
        fail.append("P8 AGENTS.md quotes pin %s but Package.swift pins %s — the injected context "
                    "names a stale upstream contract" % ("/".join(sorted(quoted)), pin))

# ── P10 the human-facing surface matches the code that serves it ─────────────
# Until now the READMEs' only gate was "a human reads them" — the root Documentation Map
# said so out loud (row README.md/README.zh.md, gate "Human"). Measured 10-20: both
# READMEs listed 32 endpoints while the router registers 34 (GET /v1/perception and
# POST /v1/audio/transcriptions undocumented, in BOTH languages), and the two files
# disagreed with each other about whether the xcode-27 CI leg was green. A hand-copied
# list is a second truth with no owner (§ Endpoint Promises: the auth column comes from
# AuthRoutePolicy, never a hand-copied list) — so the two lists a human actually reads
# are now diffed against the code that produces them.
ROUTER_SRC = "Sources/ocoreai/Router/ChatCompletionsRouter.swift"
AUTH_SRC = "Sources/ocoreai/Middleware/AuthMiddleware.swift"
HUMAN_DOCS = ["README.md", "README.zh.md"]

# The router registers the slash-id family with a recursive wildcard (`/v1/models/**/sampling`,
# so a verbatim `org/name` reaches it), while every published surface — the capabilities index,
# openapi.json, the READMEs — keeps the one-segment `:model` spelling a client already sends.
# The mapping's decision home is V1EndpointCatalogTests.publishedNotation; this is the shell half
# reading the same decision, and the test's floor goes red if the registration stops being a wildcard.
router_routes = {
    "%s %s" % (m.group(1).upper(), m.group(2).replace("/**/", "/:model/"))
    for m in re.finditer(r'routes\.(get|post|patch|delete)\("([^"]+)"', read(ROUTER_SRC))
}
if len(router_routes) < env_int("OCOREAI_README_FLOOR_ROUTES"):
    fail.append("P10 router scan found only %d route(s) (< floor %d) — the regex stopped "
                "matching %s, so every parity below is vacuous"
                % (len(router_routes), env_int("OCOREAI_README_FLOOR_ROUTES"), ROUTER_SRC))

mpub = re.search(r"static let publicPaths: Set<String> = \[(.*?)\]", read(AUTH_SRC), re.S)
if not mpub:
    fail.append("P10 `AuthRoutePolicy.publicPaths` not found in %s — the public-route parity "
                "has no source of truth, so it cannot gate anything" % AUTH_SRC)
public_paths = set(re.findall(r'"([^"]+)"', mpub.group(1))) if mpub else set()

# CI job ids are code identifiers, identical in both languages, so the leg list a human
# reads can be diffed against the workflow without parsing prose. Measured 10-20: README.md
# said both legs pass, README.zh.md line 55 said xcode-27 is red and line 183 said it is
# green — three statements, two files, one of them true, none of them re-checkable.
ci = read(".github/workflows/ci.yml")
ci_jobs = re.findall(r"^  ([a-z][a-z-]+):$", ci.split("jobs:")[-1], re.M)
if len(ci_jobs) < env_int("OCOREAI_README_FLOOR_JOBS"):
    fail.append("P10 the CI workflow yielded only %d job id(s) (< floor %d) — the scan stopped "
                "matching, so the leg list below is vacuous"
                % (len(ci_jobs), env_int("OCOREAI_README_FLOOR_JOBS")))

ROW_RE = re.compile(r"^\|\s*`(GET|POST|PATCH|DELETE)`\s*\|\s*`(/[^`]+)`\s*\|", re.M)
for doc in HUMAN_DOCS:
    text = read(doc)
    listed = {"%s %s" % (m.group(1), m.group(2)) for m in ROW_RE.finditer(text)}
    if len(listed) < env_int("OCOREAI_README_FLOOR_ROUTES"):
        fail.append("P10 %s endpoint table has only %d row(s) (< floor %d) — either the table "
                    "or its regex rotted, and a doc that lists nothing looks tidy"
                    % (doc, len(listed), env_int("OCOREAI_README_FLOOR_ROUTES")))
    missing = sorted(router_routes - listed)
    extra = sorted(listed - router_routes)
    if missing:
        fail.append("P10 %s omits %d endpoint(s) the router serves: %s"
                    % (doc, len(missing), ", ".join(missing)))
    if extra:
        fail.append("P10 %s advertises %d endpoint(s) the router does not register: %s"
                    % (doc, len(extra), ", ".join(extra)))
    no_leg = sorted(j for j in ci_jobs if "`%s`" % j not in text)
    if no_leg:
        fail.append("P10 %s never names CI leg(s) %s — a reader cannot tell which gates exist "
                    "if the entry point only claims 'CI is green'" % (doc, ", ".join(no_leg)))
    # The public-route sentence is prose and differs by language, so it is found by what
    # it must contain (the two ends of the set), not by a translated keyword.
    notes = [ln for ln in text.splitlines() if "/health" in ln and "/metrics" in ln]
    if len(mpub.group(0)) and not notes:
        fail.append("P10 %s no longer states which routes are public — the discovery surface "
                    "is undocumented where users look for it" % doc)
    for ln in notes:
        asserted = set(re.findall(r"`(/[^`]+)`", ln))
        if asserted != public_paths:
            miss = sorted(public_paths - asserted)
            over = sorted(asserted - public_paths)
            fail.append("P10 %s public-route list != AuthRoutePolicy.publicPaths (missing: %s; "
                        "extra: %s) — auth is one home, and this copy already drifted"
                        % (doc, ",".join(miss) or "none", ",".join(over) or "none"))

# ── P10b the scoreboard's size, where a user reads it ────────────────────────
# Both READMEs said "36-task scoreboard" while scripts/eval/tasks.json held 39 tasks, none disabled
# (measured 10-27, three rounds after the set grew): the mission's unit, stated on the human surface,
# with nothing re-greping it — and the mirror copied the stale figure, so agreement between the two
# files proved nothing. scripts/eval/README.md is excluded on purpose: its counts are dated rows.
try:
    board_size = len(json.loads(read("scripts/eval/tasks.json"))["tasks"])
except Exception as exc:  # noqa: BLE001 - a missing board is a premise failure, not a pass
    board_size = None
    fail.append("P10b scripts/eval/tasks.json unreadable (%s) — the board is the mission's unit, "
                "and a check that cannot read it must not report quiet success" % exc)
if board_size is not None:
    for doc in HUMAN_DOCS:
        text = read(doc)
        board_claims = [int(n) for n in re.findall(r"(\d{2,3})(?:[ -]task\b|\s*题)", text)]
        if not board_claims:
            fail.append("P10b %s states no scoreboard size (floor 1) — the pattern that prices the "
                        "board stopped matching, which is how a stale count becomes invisible" % doc)
        wrong = sorted({c for c in board_claims if c != board_size})
        if wrong:
            fail.append("P10b %s claims scoreboard task count(s) %s, tasks.json holds %d — the board "
                        "row a stranger reads must be the board the machine runs"
                        % (doc, ", ".join(map(str, wrong)), board_size))

# ── P12 internal § cross-references name a section that exists ───────────────
# `§ Endpoint Promises` is how this corpus navigates: a reader — human or model — jumps by
# section name, so a reference to a section that is no longer there is a dead link inside the
# one document every session loads first. Measured 10-21 (the session that added this check):
# the open-items block lost its heading in an earlier trim, while `§ Open` was still cited from
# the SessionPool row and from the closed-items map row — pointed at nothing, with the contract
# green because nothing read §-references at all (invariant 1: a claim nobody re-runs).
# Anchors = the headings of the contract surfaces plus the bold pseudo-headings this corpus
# really uses to label a block (`**Upstream alignment:**`). A ref may name a prefix of its
# target ("§ Routing" → "Routing table — working in X → read this first"), and prose that runs
# on after the name is trimmed by trying the longest prefix first ("§ Routing table names those
# with their own guide" is a ref to "Routing table", not to a 7-word section).
ANCHOR_SRC = ["AGENTS.md"] + guides
anchors = []
for p in ANCHOR_SRC:
    t = read(p)
    anchors += [h.strip() for h in re.findall(r"^#{1,6}[ \t]+(.+?)[ \t]*$", t, re.M)]
    anchors += [b.strip() for b in re.findall(r"^\*\*([^*\n]{2,60}?)[*:]", t, re.M)]
anchors = [a for a in anchors if a]

XREF = re.compile(r"§[ \t]*([A-Z][A-Za-z0-9][A-Za-z0-9 ]{0,40})")
refs = set()
for p in ANCHOR_SRC:
    refs |= {m.strip() for m in XREF.findall(read(p))}


def xref_resolves(ref):
    words = ref.lower().split()
    for n in range(min(len(words), 5), 0, -1):
        cand = " ".join(words[:n])
        for a in anchors:
            al = a.lower()
            if al == cand or al.startswith(cand + " ") or cand.startswith(al):
                return True
    return False


dead_refs = sorted(r for r in refs if not xref_resolves(r))
if len(refs) < env_int("OCOREAI_AGENTS_FLOOR_XREFS"):
    fail.append("P12 only %d § cross-reference(s) scanned (floor %d) — the pattern rotted, so "
                "\"all refs resolve\" would pass vacuously"
                % (len(refs), env_int("OCOREAI_AGENTS_FLOOR_XREFS")))
if dead_refs:
    fail.append("P12 %d dangling § cross-reference(s) — no section by that name in AGENTS.md or "
                "any guide: %s" % (len(dead_refs), ", ".join("§ " + r for r in dead_refs)))

# ── P14: index surfaces match the filesystem ─────────────────────────────────
# Three hand-maintained indexes decide where a reader looks next. Each is compared with the
# filesystem and floors its own scan, so "every probe documented" and "every guide routed"
# mean what they meant the day they were written (V1EndpointCatalogTests' pattern, aimed at
# the docs instead of the router).
PROBE_DIR = "scripts/probes"
probe_scripts = sorted(f for f in os.listdir(PROBE_DIR) if re.match(r"^\d\d-[a-z0-9-]+\.sh$", f))
probe_indexed = sorted(set(re.findall(r"^- `(\d\d-[a-z0-9-]+\.sh)`", read(PROBE_DIR + "/README.md"), re.M)))
probe_missing = sorted(set(probe_scripts) - set(probe_indexed))
probe_ghosts = sorted(set(probe_indexed) - set(probe_scripts))
if len(probe_indexed) < env_int("OCOREAI_PROBE_FLOOR_INDEX"):
    fail.append("P14 the probe index scan matched only %d entries (floor %d) — the pattern in "
                "scripts/probes/README.md rotted, so a missing probe would pass unseen"
                % (len(probe_indexed), env_int("OCOREAI_PROBE_FLOOR_INDEX")))
if probe_missing:
    fail.append("P14 %d probe script(s) exist but are not indexed in scripts/probes/README.md: %s"
                % (len(probe_missing), ", ".join(probe_missing)))
if probe_ghosts:
    fail.append("P14 scripts/probes/README.md indexes %d script(s) that do not exist: %s"
                % (len(probe_ghosts), ", ".join(probe_ghosts)))


def row_cells(row):
    return row.strip().strip("|").replace("\\|", "\x00").split("|")


def table_problems(path):
    out = []
    lines = read(path).split("\n")
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if s.startswith("|") and i + 1 < len(lines) and re.match(r"^\|[\s:|\-]+\|$", lines[i + 1].strip()):
            ncol = len(row_cells(lines[i]))
            j = i + 2
            while j < len(lines) and lines[j].strip().startswith("|"):
                c = len(row_cells(lines[j]))
                if c != ncol:
                    out.append("%s:%d has %d column(s), the header has %d" % (path, j + 1, c, ncol))
                j += 1
            if j < len(lines):
                nxt = lines[j].strip()
                if nxt and not nxt.startswith(("|", "#", ">", "-", "*", "`", "!", "[", "<!--")):
                    out.append("%s:%d continues a table row — the table stops rendering there" % (path, j + 1))
            i = j
        else:
            i += 1
    return out


md_tracked = [q for q in subprocess.check_output(["git", "ls-files", "*.md"]).decode().split("\n") if q]
table_bad = []
for q in md_tracked:
    table_bad += table_problems(q)
if len(md_tracked) < env_int("OCOREAI_FLOOR_MD_SCANNED"):
    fail.append("P14 only %d tracked .md file(s) scanned for table validity (floor %d) — the file "
                "list is the premise, and a premise that shrinks silently voids the check"
                % (len(md_tracked), env_int("OCOREAI_FLOOR_MD_SCANNED")))
if table_bad:
    # metric only, printed on the `corpus` line: a miscounted column misrenders our prose, it does
    # not send a reader or a caller somewhere wrong. The rule is deleted (10-27), not downgraded --
    # a warning nobody acts on is decoration that costs every run.
    pass

AREA_GUIDES = [q for q in glob.glob("Sources/**/AGENTS.md", recursive=True)
               + glob.glob("Tests/**/AGENTS.md", recursive=True)]
doc_files = sorted(glob.glob("docs/agent/*.md"))
reachable = read("AGENTS.md") + "".join(read(q) for q in AREA_GUIDES)
doc_orphans = [q for q in doc_files if os.path.basename(q) not in reachable]
if len(doc_files) < env_int("OCOREAI_FLOOR_DOC_FILES"):
    fail.append("P14 only %d docs/agent/*.md found (floor %d) — sweeping orphans away would look "
                "like a clean pass" % (len(doc_files), env_int("OCOREAI_FLOOR_DOC_FILES")))
if doc_orphans:
    # metric only: an unreachable doc is wasted prose, not a false promise (deleted 10-27)
    pass

# ── P21: a knob the human surface names is wired somewhere ────────────────────
# An `OCOREAI_*` name a human-facing doc promises that no code reads is a dead pointer on the
# env axis (the P2 class): the operator exports it, nothing changes, and the docs keep claiming
# a control that does not exist. The class's red was sampled from the producer side
# (`MetricProducerWiringTests`: a series that exports a permanent zero); the docs side was
# adjudicated by hand on 11-06 and again 11-11 — the first scan round answered
# `OCOREAI_HEARING_PROBE` as unwired when its consumer lived in a marker's code line, and the
# second round's first answer was wrong three more ways (script-consumed knobs outside Sources,
# an output sentinel that is not a knob at all, a knob whose reader lives in Tests/). This scan
# counts only code lines — a comment naming a knob is not wiring — and walks the whole tracked
# tree so a scripts-consumed knob credits its real consumer.
KNOB_NAME = re.compile(r"OCOREAI_[A-Z0-9_]+")
knob_doc_named = set()
for q in md_tracked:
    if q == "CHANGELOG.md" or q.startswith(".agents/"):
        continue  # the diary names knobs its rounds measured; it promises nothing forward
    knob_doc_named.update(KNOB_NAME.findall(read(q)))
knob_code = set()
KNOB_EXTS = (".swift", ".sh", ".py", ".yaml", ".yml", ".json")
for q in tracked:
    ext = os.path.splitext(q)[1]
    if not (q.endswith(KNOB_EXTS) or os.path.basename(q) == "Makefile"):
        continue
    try:
        text = read(q)
    except OSError:
        continue
    for line in text.splitlines():
        stripped = line.strip()
        if ext == ".swift" and stripped.startswith("//"):
            continue
        if ext in (".sh", ".py", ".yaml", ".yml", "") and stripped.startswith("#"):
            continue
        for m in KNOB_NAME.finditer(line):
            before = line[:m.start()]
            if "//" in before:
                continue
            if (ext in (".sh", ".py", ".yaml", ".yml", "")
                    and "#" in before.split('"')[-1].split("'")[-1]):
                continue
            knob_code.add(m.group())
if len(knob_doc_named) < env_int("OCOREAI_FLOOR_KNOB_DOCS"):
    fail.append("P21 the docs named only %d knob(s) (floor %d) — the doc-side premise rotted, so "
                "an empty promise scan would pass vacuously"
                % (len(knob_doc_named), env_int("OCOREAI_FLOOR_KNOB_DOCS")))
if len(knob_code) < env_int("OCOREAI_FLOOR_KNOB_CODE"):
    fail.append("P21 the consumer walk found only %d knob(s) in code (floor %d) — a walk that "
                "stopped matching cannot clear any promise" % (len(knob_code),
                                                               env_int("OCOREAI_FLOOR_KNOB_CODE")))
knob_unwired = sorted(knob_doc_named - knob_code)
if knob_unwired:
    fail.append("P21 %d knob(s) a human-facing doc names but no code reads: %s"
                % (len(knob_unwired), ", ".join(knob_unwired)))
knob_pairs = len(knob_doc_named) - len(knob_unwired)

# ── P19: every outbound link a doc points at was verified to resolve ─────────────────────────
# Why this is offline: the live probe (scripts/link-check.sh, `make links`) is honest but cannot be
# a blocking gate here — egress to github.com from this host is flaky, and on the day this gate was
# written a throttled run answered 13 of 28 URLs and an earlier version of the probe called that
# GREEN, hiding the two dead links it existed to catch. A lock that needs the network to know it is
# red is the gitleaks pattern. So the network part stays opt-in, and what CI checks is decidable
# offline: a doc may only cite a URL a human confirmed, on a stated date.
#
# The defect that started it (verified, same host, 10-27): README.md and README.zh.md both cited
# github.com/omlx-ai/omlx (the tree is jundot/omlx) and github.com/steipete/clawd (it is
# openclaw/openclaw) — 404 in the front door, in both languages.
#
# It rots in both directions on purpose, like COMPARATOR_REFS above: cite a URL that is not listed
# and it is red; keep a listed URL nothing cites and that is red too. A date of "unverified" is
# allowed for a host no available machine can reach (huggingface.co refuses curl here), under a
# ceiling, so the exception cannot quietly become the rule.
VERIFIED_URLS = {
    "https://developer.apple.com/design/human-interface-guidelines": "10-27",
    "https://developer.apple.com/documentation/": "10-27",
    "https://developer.apple.com/documentation/foundationmodels": "10-27",
    "https://developer.apple.com/tutorials/data/design/human-interface-guidelines.json": "10-27",
    "https://www.apple.com": "10-27",
    "https://www.swift.org": "10-27",
    "https://mlx.studio/": "10-27",
    "https://modelscope.cn": "10-27",
    "https://modelscope.cn/": "10-27",
    "https://img.shields.io/badge/License-MIT-yellow.svg": "10-27",
    "https://img.shields.io/badge/Swift-6.2-orange.svg": "10-27",
    "https://img.shields.io/badge/macOS%2014%20%7C%20iOS%2017-blue.svg": "10-27",
    "https://github.com/uingei/ocoreai.git": "10-27",
    "https://github.com/uingei/ocoreai/issues": "10-27",
    "https://github.com/uingei/ocoreai/releases": "10-27",
    "https://img.shields.io/github/v/release/uingei/ocoreai": "11-07",
    "https://raw.githubusercontent.com/uingei/ocoreai/main/scripts/install.sh": "11-07",
    "https://github.com/uingei/ocoreai/actions/workflows/ci.yml": "10-27",
    "https://github.com/uingei/ocoreai/actions/workflows/ci.yml/badge.svg": "10-27",
    # Fetched 10-29. Two earlier attempts from this host returned no answer at 75 s and one answered
    # in 68 s, so a stall here is github.com throttling, not a dead path — the same reading
    # scripts/link-check.sh records for its own serial setting.
    "https://github.com/uingei/ocoreai/actions/workflows/package.yml": "10-29",
    "https://github.com/uingei/ocoreai/actions/workflows/package.yml/badge.svg": "10-29",
    "https://github.com/uingei/ocoreai/security/advisories/new": "10-27",
    "https://github.com/apple/coreai-models": "10-27",
    "https://github.com/ml-explore/mlx-swift-lm": "10-27",
    "https://github.com/openai/codex": "10-27",
    "https://github.com/vllm-project/vllm": "10-27",
    "https://github.com/vllm-project/vllm-metal": "10-27",
    "https://github.com/sgl-project/sglang": "10-27",
    "https://github.com/jundot/omlx": "10-27",
    "https://github.com/openclaw/openclaw": "10-27",
    "https://github.com/NousResearch/hermes-agent": "10-27",
    # Refused by every machine this repo can reach (curl and the browser disagree); the URL itself
    # is the service root, so a stale entry here would mean Hugging Face stopped existing.
    "https://huggingface.co": "unverified",
}
UNVERIFIED_CEILING = 2            # one deliberate exception is a fact; a pile of them is an escape hatch
LOOPBACK_RE_URL = re.compile(r"^https?://(127\.0\.0\.1|localhost|0\.0\.0\.0|192\.168\.[0-9]+\.[0-9]+)")
cited_urls = set()
for _q in md_tracked:
    for _u in re.findall(r"https?://[A-Za-z0-9._/:%#?=&+-]+", read(_q)):
        _u = _u.rstrip(").,`\"'>")
        if not LOOPBACK_RE_URL.match(_u):      # documented examples of a local server, not citations
            cited_urls.add(_u)
print("  links     outbound=%d verified=%d unverified=%d (floor %d)"
      % (len(cited_urls), len(cited_urls) - len([u for u in cited_urls if u not in VERIFIED_URLS]),
          len([u for u, d in VERIFIED_URLS.items() if d == "unverified"]), env_int("OCOREAI_URL_FLOOR")))
if len(cited_urls) < env_int("OCOREAI_URL_FLOOR"):
    fail.append("P19 only %d outbound URL(s) scanned (< floor %d) — the extraction is the premise, "
                "and a scan that shrinks silently voids the check"
                % (len(cited_urls), env_int("OCOREAI_URL_FLOOR")))
_unlisted = sorted(u for u in cited_urls if u not in VERIFIED_URLS)
if _unlisted:
    fail.append("P19 %d outbound link(s) in the docs were never verified to resolve: %s — check them "
                "with `make links` (needs egress) and add the ones that resolve, with today's date"
                % (len(_unlisted), ", ".join(_unlisted[:5])))
_stale = sorted(u for u in VERIFIED_URLS if u not in cited_urls)
if _stale:
    fail.append("P19 %d verified-URL entr(y|ies) no doc cites: %s — the table is a record of what the "
                "docs claim, so an entry nothing cites is a record of nothing"
                % (len(_stale), ", ".join(_stale[:5])))
_unver = sorted(u for u, d in VERIFIED_URLS.items() if d == "unverified")
if len(_unver) > UNVERIFIED_CEILING:
    fail.append("P19 %d entries are marked unverified (> ceiling %d) — an exception that grows is a hole"
                % (len(_unver), UNVERIFIED_CEILING))

# ── P18 documentation language ────────────────────────────────────────────────
# README.md holds 0 CJK characters and README.zh.md 2 436 on the day this gate was written; before it,
# the English README carried a Chinese install block that the zh mirror already held, and four
# agent-facing docs each leaked a phrase. Nothing could see that, because nothing counted.
CJK_RE = re.compile(r"[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]")
ESC_RE = re.compile(r"\\u[0-9a-fA-F]{4}")
MIRROR = "README.zh.md"
DIARY = {"CHANGELOG.md", "IDEA.md"}  # excluded from the English rule
tracked_md = subprocess.run(["git", "ls-files", "*.md"], capture_output=True, text=True).stdout.split()
lang_zero = [f for f in tracked_md if f != MIRROR and f not in DIARY and not f.endswith(".zh.md")]
if len(lang_zero) < env_int("OCOREAI_FLOOR_LANG_SCANNED"):
    fail.append("P18 only %d English-default .md file(s) scanned (floor %d) \u2014 the file list rotted, "
                "so \u201call docs are English\u201d would pass vacuously"
                % (len(lang_zero), env_int("OCOREAI_FLOOR_LANG_SCANNED")))
for f in sorted(lang_zero):
    n = len(CJK_RE.findall(read(f)))
    if n:
        fail.append("P18 %s carries %d CJK character(s) \u2014 docs are English by default and the one "
                    "Chinese surface is %s (a diary file gets a ceiling, an English-facing one gets zero)"
                    % (f, n, MIRROR))
if not os.path.exists(MIRROR):
    fail.append("P18 %s is missing \u2014 the rule names exactly one Chinese mirror of README.md" % MIRROR)
else:
    n = len(CJK_RE.findall(read(MIRROR)))
    if n < env_int("OCOREAI_FLOOR_ZH_MIRROR_CJK"):
        fail.append("P18 %s holds %d CJK characters (floor %d) \u2014 a mirror that stopped being "
                    "Chinese mirrors nothing" % (MIRROR, n, env_int("OCOREAI_FLOOR_ZH_MIRROR_CJK")))
# No raw escape sequences in prose. A Markdown file carrying `\u2014` is not styling, it is a
# generator that wrote its own source: 25 of these landed in CHANGELOG.md and one in a guide when
# heredoc strings double-escaped them, and the commits shipped green because nothing read the text.
for f in sorted(set(tracked_md)):
    if not f.endswith(".md"):
        continue
    raw = ESC_RE.findall(read(f))
    if raw:
        fail.append("P18 %s carries %d raw \\uXXXX escape(s) (%s) — markdown holds characters, "
                    "not source escapes; the generator that wrote them is the bug"
                    % (f, len(raw), ", ".join(sorted(set(raw))[:4])))
# ── P20: every diary entry keeps its heading ────────────────────────────────
# A diary entry whose heading is gone is four labelled bullets with no number and no title, so the
# pointers other text makes to it ("see 10-29(46)") stop resolving. Sampled 10-29 the bad way: one of
# my own splices ate the heading of 10-29(46), it reached main, and every gate stayed green. Decidable
# offline, no prose judgement: the first `- **What improved.**` of an entry must have a heading line
# above it that post-dates the previous entry's first bullet.
DIARY_HEAD_RE = re.compile(r"^\*\*\S")  # any bold-led line: `**10-29(46) …**` or a `**B. …**` part-head
# Colon-or-dot, both counted: the label moved to `What improved:` and the startswith carried a literal
# dot, blinding the scan to every modern-style entry (widening found +6 such entries; the remaining
# entries/196 gap is older diary styles that carry no `What improved` bullet at all, not victims).
DIARY_IMPR_RE = re.compile(r"^- \*\*What improved[.:]")
last_head = last_impr = 0
diary_orphans, diary_paired = [], 0
for _i, _ln in enumerate(read("CHANGELOG.md").split("\n"), 1):
    if DIARY_HEAD_RE.match(_ln):
        last_head = _i
    elif DIARY_IMPR_RE.match(_ln):
        if last_head > last_impr:
            diary_paired += 1
        else:
            diary_orphans.append(_i)
        last_impr = _i
if diary_orphans:
    fail.append("CHANGELOG.md has %d bullet block(s) with no entry heading above them (line(s) %s) — "
                "an entry without its heading cannot be cited by number, and `make docs-check` did not "
                "see this until 10-29" % (len(diary_orphans), diary_orphans[:4]))
if diary_paired < env_int("OCOREAI_FLOOR_DIARY_PAIRED"):
    fail.append("P20 paired only %d diary entries (floor %d) — a scan that matches nothing reports a "
                "clean diary" % (diary_paired, env_int("OCOREAI_FLOOR_DIARY_PAIRED")))
# P20's second face, sampled 11-10 the same bad way: a splice of c332ae84 ate the live
# `## [Unreleased]` umbrella while leaving every ENTRY heading intact — P20's pairing passed, and
# the loss surfaced an hour later as a mis-landed append. One home extends rather than a second gate:
# exactly one umbrella heading, above the first entry heading. Exact count, no floor — a live
# period is one heading by definition.
unrels = [i for i, ln in enumerate(read("CHANGELOG.md").split("\n"), 1)
          if ln.startswith("## [Unreleased]")]
first_entry = next((i for i, ln in enumerate(read("CHANGELOG.md").split("\n"), 1)
                    if DIARY_HEAD_RE.match(ln)), 0)
if len(unrels) != 1:
    fail.append("P20 CHANGELOG.md has %d `## [Unreleased]` heading(s) (line(s) %s) — appends anchor on it, "
                "and a diary whose live period is unnamed ships a map with no you-are-here"
                % (len(unrels), unrels[:4]))
elif first_entry and first_entry < unrels[0]:
    fail.append("P20 CHANGELOG.md's first entry (line %d) sits above the [Unreleased] umbrella (line %d) — "
                "newest-first means below the live heading, not before it" % (first_entry, unrels[0]))

# ── report ───────────────────────────────────────────────────────────────────
print("AGENTS.md contract (%s)" % mode)
print("  xrefs     §-refs=%d (floor %d)  anchors=%d (tree absent here=%d, marker-owned=%d)  dangling=%d"
      % (len(refs), env_int("OCOREAI_AGENTS_FLOOR_XREFS"), len(anchors), silent_tree, marker_owned,
         len(dead_refs)))
corpus_bytes = sum(os.path.getsize(q) for q in sorted(set(
    ["AGENTS.md", "ARCHITECTURE.md", "CONTRIBUTING.md", "scripts/probes/README.md"]
    + guides + doc_files)) if os.path.exists(q))
print("  corpus    bytes=%d (reported, not judged)  probe-index=%d/%d  doc-orphans=%d  table-defects=%d"
      % (corpus_bytes, len(probe_indexed), len(probe_scripts), len(doc_orphans), len(table_bad)))
print("  diary     entries=%d paired=%d (floor %d)  headingless=%d"
      % (len([1 for _l in read("CHANGELOG.md").split("\n") if DIARY_HEAD_RE.match(_l)]),
         diary_paired, env_int("OCOREAI_FLOOR_DIARY_PAIRED"), len(diary_orphans)))
print("  budgets   root=%d/%d bytes guides=%d  chain-cap=%d  injected=%d nested AGENTS.md"
      "  deepest-chain=%d/%d  chain-corpus=%d  docs-figures=%d site(s) re-derived"
      % (root_size, env_int("OCOREAI_AGENTS_MAX_ROOT"), len(guides),
         env_int("OCOREAI_AGENTS_MAX_CHAIN"), len(chain_guides),
         deepest_chain, env_int("OCOREAI_AGENTS_MAX_CHAIN"),
         agents_corpus, len(fig_sites)))
print("  language  english-md=%d (floor %d)  mirror-cjk=%d (floor %d)  diary-excluded=%d"
      % (len(lang_zero), env_int("OCOREAI_FLOOR_LANG_SCANNED"),
         len(CJK_RE.findall(read(MIRROR))) if os.path.exists(MIRROR) else -1,
         env_int("OCOREAI_FLOOR_ZH_MIRROR_CJK"), len(DIARY)))
print("  scan      gateable-refs=%d (floor %d)  claims=%d/%d ok (floor %d)  suites=%d  routing=%d  upstream-trees=%d  knobs=%d/%d (floors %d/%d)"
      % (len(hard_refs), env_int("OCOREAI_AGENTS_FLOOR_REFS"), ok_claims, len(claims),
         env_int("OCOREAI_AGENTS_FLOOR_CLAIMS"), len(suites), len(routing), len(clones),
         knob_pairs, len(knob_doc_named), env_int("OCOREAI_FLOOR_KNOB_DOCS"),
         env_int("OCOREAI_FLOOR_KNOB_CODE")))
print("  human     router-routes=%d (floor %d)  public-paths=%d  README tables=%s"
      % (len(router_routes), env_int("OCOREAI_README_FLOOR_ROUTES"), len(public_paths),
         ",".join("%d rows" % len({("%s %s" % (m.group(1), m.group(2)))
                                  for m in ROW_RE.finditer(read(d))}) for d in HUMAN_DOCS)))
print("  suites    files-with-@Test=%d (metric only)" % len(test_fn_counts))
if upstream:
    print("  outside   %d cite(s) into trees no runner has (path=%d paragraph=%d) over %d comparator"
          " + %d dependency trees, declared in %s / Package.swift; residual allowlist %d entr(ies)"
      % (len(declared_outside) + len(declared_context), len(declared_outside), len(declared_context),
         len(comparator_trees), len(dep_trees), COMPARATOR_DOC, len(COMPARATOR_REFS)))
print("  upstream  %d ref(s) resolved in a dependency checkout or ~/references "
          "(line numbers inside them are what `make anchor-check` verifies): %s"
          % (len(upstream), ", ".join(sorted(set(upstream))[:6])))
if warn:
    # Signals print one line per check, not one paragraph per finding: a wall of advisories is how
    # gate fatigue starts, and nobody re-runs a gate they learned to skim. Nothing in this block
    # means a user or a caller is acting on something false — that is what the violation list is for.
    grouped = {}
    for w in warn:
        grouped.setdefault(w.split(" ", 1)[0], []).append(w)
    print("\n  signals (%d, not blocking)" % len(warn))
    for key in sorted(grouped):
        print("   · %s ×%d — %s" % (key, len(grouped[key]), grouped[key][0].split(" ", 1)[1]))
if fail:
    print("\n❌ %d violation(s):" % len(fail))
    for f in fail:
        print("   • %s" % f)
    # On Actions the job log needs a token to read and annotations do not, so a red docs gate
    # on a runner would be a red nobody could diagnose (it sat red for four pushes with only
    # "failed step: AGENTS.md contract" to go on). Each violation therefore also leaves as a
    # workflow command, the shape the xctest step already uses for failing cases.
    if os.environ.get("GITHUB_ACTIONS") == "true":
        for f in fail[:10]:
            print("::error::docs gate: %s" % f.replace("%", "%25").replace("\n", "%0A"))
    raise SystemExit(1 if mode == "check" else 0)
print("\n✅ AGENTS.md contract holds (budgets, refs, anchors, claims, gates, routing)")
PY
