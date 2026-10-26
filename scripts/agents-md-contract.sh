#!/usr/bin/env bash
# agents-md-contract.sh — AGENTS.md is injected into the model's context on every
# session: it is a per-session cost and a contract, not a note to self. This gate
# asserts the contract, because prose that says "grep-reproducible" is not
# reproducible unless something greps it.
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
#   P5 gates         every `make <target>` and scripts/*.sh named is real
#   P6 suites        every XxxTests named is declared under Tests/
#   P11 suite counts  every `XxxTests`(N) claim equals the @Test count in Tests/**/XxxTests.swift
#                    — a numbered gate claim is a promise about how much is covered, and five of
#                    them had already drifted (AGENTS.md 15→16, 6→7, 11→15;
#                    docs/agent/closed-items-log.md 6→9 and 7→6, the last one claiming MORE
#                    coverage than the file holds) before anything read them (invariant 1)
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
#   P13 diary-free    AGENTS.md carries rules, not dated forensics: zero MM-DD stamps and no
#                    line over OCOREAI_AGENTS_MAX_LINE bytes. The file said "Not a diary" while
#                    holding 38 dated stamps and 37 lines over 400 bytes, and P1-P12 stayed green
#                    the whole time — a rule with no gate is a claim (invariant 1, turned on the
#                    file that states it)
#   P14 indexes       the three hand-maintained places that decide where a reader looks next are
#                    compared with the filesystem: scripts/probes/README.md must index exactly the
#                    probe scripts that exist (no gap, no ghost); every markdown table in the repo
#                    must keep one row per line and one column count (the probe README had rows
#                    that wrapped, so everything below the first one rendered as stray prose); and
#                    no docs/agent/*.md may be unreachable from AGENTS.md or an area guide,
#                    because an orphan doc drifts unnoticed
#   P15 corpus shape  P13's shape rule one hop out — no line over OCOREAI_CORPUS_MAX_LINE bytes
#                    outside code fences/comments/tables, corpus total under OCOREAI_CORPUS_MAX_BYTES.
#                    A guide nobody can read is a guide nobody obeys.
#   P18 doc language  docs are English by default and exactly one file is Chinese: README.zh.md, the
#                    mirror of README.md (the owner's rule). Enforced at zero where a newcomer or an
#                    agent reads — root docs, area guides, docs/**, script READMEs. The diary is not
#                    rewritten into a language it was not written in: CHANGELOG/CHECKPOINT/IDEA carry
#                    pinned CJK ceilings, so a *new* Chinese line fails while 137k characters of
#                    history stay intact. The mirror must stay Chinese too — a zh file that stopped
#                    being Chinese is the same defect wearing the other face.
#   P17 guide shape  every Sources/**/AGENTS.md opens `# <Area> — <claim>`, states in its scope
#                    block that the root file still governs and which directories it owns, names
#                    at least two gates, ends its rules with the command that verifies them, and
#                    carries no dated stamp. opencode ships 18 guides that all open with an
#                    ownership line and most name their own validation command; a reader who has
#                    read one knows where to look in the next. "Each area has a guide" is a file
#                    count; a shape is a contract.
#   P16 comparators § Upstream 6 names fourteen trees, and the long-form doc claimed twice that
#                    "the floors below are the gate" while carrying no floors — so the audit column
#                    rotted in silence. This is that floor: every named tree must appear in
#                    CHANGELOG.md, and the file's spelled-out zero-coupling list must equal the set
#                    re-derived by grep, so a tree that gains a cite cannot stay called dead and one
#                    that loses it cannot keep being quoted as consumed.
#                    Two hand-copied lists must equal § 6 too: an entry per named tree, and a
#                    refresh loop that names exactly the registered comparators.
#
# Why (measured 10-14, same session as this file): three "verified" counts had already
# drifted — Engine/*.swift 44 -> 53, precondition 12 sites/9 files -> 14/11 — and the
# Documentation Map pointed at docs/prompt-ocoreai.md, docs/precise-tasks.md and
# docs/plans/*, which are not in git at all (docs/ holds only what came after 11dd586),
# plus a ~/wiki vault that is not on this host.
#
# Usage: bash scripts/agents-md-contract.sh [check|report|budget]
#   check   default; exit 1 on any violation
#   report  same output, always exit 0 (for read-only audits)
#   budget  lower the pinned root cap to the current size (refuses to raise it)
set -uo pipefail
cd "$(dirname "$0")/.."

## ── pinned budgets (a raise must be a visible edit in the diff) ──────────────
# 10-24 raise 30138 -> 30428 (+290): one §Open item with a live instrument behind it —
# `response_format` + `tools[]` on one turn loses the answer (probe 12 §6: keys arrive 3/3 with grammar
# alone, 3/3 with tools alone, 0/3 with both), paid partly by folding a duplicate `required`-strength
# sentence into a §-pointer (-55 B). Debt is stated, not hidden: repay from the dated forensics in
# docs/agent/build-gate-reality.md and the "named, unused" comparator cells (splash, deepseek-harness).
: "${OCOREAI_AGENTS_MAX_ROOT:=30388}"   # pinned 10-25 by `make docs-budget`
                                     # `make docs-budget` may only lower it (B1 stays a ratchet)
# P13: the injected file carries rules, not diary. Longest allowed line in AGENTS.md, in bytes.
: "${OCOREAI_AGENTS_MAX_LINE:=400}"
# P15: the same shape rule for the corpus an agent reads one hop out — area guides,
# docs/agent/*, the probe index, ARCHITECTURE/CONTRIBUTING. Measured 10-22 after the corpus
# pass: 13 files, 152,041 bytes, zero lines over 400 bytes outside code fences. Raising
# either constant must be a visible edit in the diff.
: "${OCOREAI_CORPUS_MAX_LINE:=400}"
: "${OCOREAI_COMPARATOR_FLOOR_TREES:=14}"
# 10-22 re-pin 152041 -> 156559: docs/agent/competitor-iteration-paths.md (+5610, a rules-only
# evidence hop with its dated chronology left in CHANGELOG) broke the ratchet by 4518; 711 bytes
# of stale text went out of comparator-repos.md (its "four of the twelve"/"fifteen directories"
# cells were wrong as of 10-22 — seven trees have zero coupling, and openclaw is a 16th clone).
# The next corpus addition must delete its own weight; the pending owner call on splitting
# CHANGELOG.md into docs/agent/rounds/ changes this baseline again.
# 10-22 (2) lower 156559 -> 142550: ARCHITECTURE.md's 2026-07-26 review body left the corpus
# (-15840 B) — it diagrammed a deleted file, carried line counts wrong by up to 3.7x, and
# contradicted itself about CoreAI grammar. openclaw's measured verdict (+1763 B in
# docs/agent/competitor-iteration-paths.md) is paid by it several times over, which is what
# "text goes in only when text comes out" is for. Earlier same-day raise (152041 -> 156559,
# +5610 for that new doc, -711 stale comparator cells) is now net of: 142550 < 152041.
# 10-22 (3) raise 142550 -> 143578: two capability statements the objective demands went in —
# probe 28's index entry (a refused `serve` must leave: measured 237 s → 1 s with code 1) and
# UI/AGENTS.md's measured GUI scope (900x472 layer-0 window, 846-colour frame, one real completion
# locally; bridge opt-in, Accessibility automation unverified). Same round paid back: probe 26/27's
# duplicated "Measured" tails (−476 B), the dangling `docs/CONTEXT.md` pointer (−41 B) and
# third-party-notices' duplicated disclosure sentences (−245 B, recorded above). Net against the
# 09-27 baseline of 152,041: still −8,463 B, so the ratchet is intact across the day even though
# this constant moved up; a cap edit without this kind of accounting is what the rule forbids.
# 10-22 (4) raise 143578 -> 144942 (+1364): the round's honest index entries — probe 29 (capacity
# refusal: queue measured at the wire, 429 legs still red because lock arrival order is not HTTP
# arrival order) and probe 30 (a repeated prompt answers one token, reproduced sequentially, so
# without overlap), plus the `OCOREAI_ENGINE_BUSY_WAIT` knob row that probe 29's determinism needs.
# Paid for in the same edit: probe 28's "Measured 10-22" tail (−214 B, that story is CHANGELOG's,
# and an index row's job is the question plus its falsifier), and both new entries were written to
# that shape after a first draft 371 B fatter. Net against the 09-27 baseline of 152,041: −7,099 B.
# Re-pinned to the measured value: a cap with slack in it is a cap nobody enforces.
# 10-23 raise 144942 -> 145623 (+681 over the old cap; +735 measured against HEAD): two index
# entries for two gates this round had to add, both for defects found by posting to the running
# server rather than by reading code — probe 34 (`/mcp` answered -32700 to a spec-legal numeric
# JSON-RPC id, so standard SDK clients could not complete one handshake; `params` never decoded, so
# `tools/call` replied with a success-shaped `{}`; `tools/list` described all 39 tools as taking no
# arguments) and probe 33 (the registry synthesizes `required` from Dictionary keys, whose order
# Swift picks per process — the 10-23(8) seed class reaching the prompt through the MCP door).
# Written to the index's own job — the question plus its falsifier — with the reasoning left in each
# script's header, since an index that re-argues is a second home for the same claim. Nothing else
# in the corpus moved (README is the only corpus file in this diff: +735 B, −0). Net against the
# 09-27 baseline of 152,041: −6,418 B, so the ratchet is still negative across the window.
# Re-pinned to the measured value: a cap with slack in it is a cap nobody enforces.
# 10-23 (+116 B, cumulative −6,302 against the 09-27 baseline): the UI guide's defect sentence had
# rotted — it described keyboardShortcut/textSelection/accessibilityLabel as present in 3/3/15 files
# where the greps now say 5/5/17 — and its two markers were `>=` floors, so a defect that grows can
# never go red. Numbers re-measured, both markers turned into ceilings, and `textSelection` given the
# marker it never had (+84 B). A ceiling is the only direction that can catch this class.
# 10-23 re-pin 145739 -> 145966 (+227): one root rule for the write-side echo contract, stated in
# three lines and cited to its gate. A docs/agent/ hop would cost the same bytes and add a hop for
# a rule that has to be in front of anyone writing a file tool, so the text went in at the root and
# nothing came out — the next corpus addition still owes its own weight.
# 10-23 raise 145966 -> 150805 (+4839 net): docs/agent/long-horizon-goal.md and its root pointer,
# minus a duplicate pointer to build-gate-reality.md removed from § Build / Test / Lint (-55 B there).
# Debt is stated, not hidden: repay it by compressing the two host-colour cells in
# docs/agent/comparator-repos.md (harness2, openclaw), whose facts CHANGELOG.md already carries.
# 10-24 raise 150805 -> 154536 (+3731 net): docs/agent/agent-interface-guidelines.md (4284 B) — the
# agent-loop half of the interface contract, which the HIG provably does not carry (102 articles, `agent`
# = 3 hits, all linked video titles) — plus its root pointer and the corrected P13/P15 date claim, minus
# the debt named here on 10-23: harness2/openclaw host-colour cells and a dated ~/references inventory
# compressed out of docs/agent/comparator-repos.md (-539 B).
# Debt is stated, not hidden: repay by compressing the dated forensics in docs/agent/build-gate-reality.md
# (15 MM-DD stamps whose verdicts CHANGELOG.md already carries) and the two "named, unused" comparator
# cells (splash, deepseek-harness) — use those trees or drop them from `AGENTS.md` § Comparators.
# 10-24 raise 154536 -> 155386 (+850): the §Open item above (root is in the corpus) and the §6
# assertions + measured numbers added to scripts/probes/README.md's 12-json-mode-delivery row, so the
# grammar×tools crossing has a documented verdict that outlives this session. No repayment was available
# without deleting the four-defect pairing table in docs/agent/build-gate-reality.md — that table is the
# standing argument for live probes, so it stays and the debt carries forward: the two "named, unused"
# cells (splash, deepseek-harness) or the dated forensics there owe the corpus its bytes.
# 10-26 raise 155386 -> 155597 (+211): the keyboard-contract gate line in
# Sources/ocoreai/UI/AGENTS.md (UIFocusDisciplineTests) — the HIG prose "⌘ coverage ...
# keyboard ownership follows focus" finally names the test that pins it. Debt movement:
# the splash half is repaid (the comparator-repos.md cell now reads Borrow: consumed);
# the deepseek-harness half stays an owner call, and the dated forensics in
# docs/agent/build-gate-reality.md still owe the corpus its bytes.
# Repaid in the next commit of the same round (measured 155575, −6 B): the guide line stopped
# enumerating ⌘ keys once UIFocusDisciplineTests derived their order from AppTab — proof in the
# gate means prose does not have to carry the list. The ceiling stays where the ratchet put it.
# 10-26 raise 155597 -> 157800 (+2203): the payload-and-filter block in
# docs/agent/build-gate-reality.md. It prices two commands every session runs: a test process
# that lets MLX hunt for its shader library dies mid-run and reports neither pass nor fail, and
# `swift test --filter` signals 11 on the Xcode route here, so the filter recipe had to move.
# Debt is the same debt, still named: the dated forensics in that file (verdicts CHANGELOG.md
# already carries) and the deepseek-harness comparator cell.
# 10-26 raise 157800 -> 160694 (+2894). What went in: § *Rung zero* in docs/agent/long-horizon-goal.md
# (+2956) — the field's adoption numbers (seven comparators' stars/forks/rate, and ocoreai's own 1 star /
# 7 DMG downloads, read from api.github.com because a mirror proves content, never HEAD) and the
# distribution ladder that follows. This is the exception the rule names rather than the breach it forbids:
# outside-world measurement that reorders the plan, not a verdict the diary already owns.
# Ledger, each figure re-derivable (sum `git show <ref>:<corpus file> | wc -c` over AGENTS.md,
# ARCHITECTURE.md, CONTRIBUTING.md, scripts/probes/README.md, Sources/**/AGENTS.md, docs/agent/*.md):
# 156885 at f036fc0 (before the round) -> 158778 at P17's peak -> 157738 after 1040 B of repayment (the
# stale `3180/562 in 429 s` CLT counts and two 10-26 narration blocks collapsed into rules + pointers, cap
# unmoved) -> 160694 with Rung zero. Net over the round: +3809, and root itself went the other way (-6363
# to 24025) because the wire rules moved to where they cost context only inside their own subtree. The next
# corpus growth still owes its own weight.
# 10-27 raise 160694 -> 161004 (+310). In: § *The proposition the product is judged on* in
# docs/agent/long-horizon-goal.md (the owner's four axes and the acceptance metrics that are not
# LOC/commits/model-count/complexity) plus the root rule naming `make push-ready` as the gate path (a
# pure reformat moved 19 line-cites and every local gate stayed green, because `round-gates` is not what
# anyone runs before pushing). Out, same edit: the "named, unused" deepseek-harness cell and its registry
# name (-269 B, debt this ledger has named since 10-24), the dated metallib narration and four MM-DD
# stamps in build-gate-reality.md (-213 B, upstream cites and gate kept), and the goal doc's B′/C/rung-1
# figures, which had already drifted (it quoted 52 tasks where the set is 39) and now live only in
# scripts/eval/README.md (-510 B). WARNING for the next editor: § Upstream 6 is P16'S INPUT, not prose —
# collapsing the comparator list into a pointer left P16 parsing 2 "trees" against a floor of 14, and it
# stayed quiet about half of it. Keep the list verbatim; retire a tree by dropping its name from BOTH
# homes (root § Upstream 6 and the refresh loop in comparator-repos.md).
# 10-27 raise 161004 -> 161178 (+174 net, +352 gross). In: two root rules that each name their gate —
# "a gate you did not run is not green" extended with the half this round proved (a stated fix that cannot
# run is no exit: `make format`, the remediation `make format-check` names, died on an apostrophe inside a
# single-quoted awk program and had therefore never executed), and "name a destructive route only where the
# caller's own argument asks for it" (gate: EditMismatchRecoveryTests, both directions). Out, same edit:
# the §Identity pointer that restated the routing table 200 lines below it in this same file (-106 B) and
# the §Docs Contract restatement of what the script header already owns (-60 B). Scripts are not corpus,
# so scripts/makefile-parse-check.sh — the gate that would have caught the Makefile — cost nothing.
: "${OCOREAI_CORPUS_MAX_BYTES:=161178}"

# P14 floor: probe scripts indexed in scripts/probes/README.md (measured 27 on 10-22), so a
# README whose index pattern rotted cannot report "every probe is documented" vacuously.
: "${OCOREAI_PROBE_FLOOR_INDEX:=20}"
# P14 floors for the other two index scans (measured 22 tracked .md, 7 files in docs/agent).
: "${OCOREAI_FLOOR_MD_SCANNED:=15}"
: "${OCOREAI_FLOOR_DOC_FILES:=5}"
: "${OCOREAI_AGENTS_MAX_CHAIN:=78000}" # AGENTS.md + one area guide loaded together
: "${OCOREAI_AGENTS_MAX_AREA:=16000}"  # each Sources/**/AGENTS.md or docs/agent/*.md
# P1 floors: keep just under the measured count so a broken scan is a failure, not a pass.
: "${OCOREAI_AGENTS_FLOOR_REFS:=50}"
: "${OCOREAI_AGENTS_FLOOR_CLAIMS:=8}"
: "${OCOREAI_AGENTS_FLOOR_SUITES:=8}"
: "${OCOREAI_AGENTS_FLOOR_SUITE_COUNTS:=8}"
: "${OCOREAI_AGENTS_FLOOR_ROUTING:=4}"
# P18 floors: the language scan must keep matching real files (measured 26 English .md, 2 436 CJK
# chars in the mirror), and the diary ceilings are pinned with THIS gate's own classifier (Han + CJK
# punctuation + fullwidth) — pinning them from a narrower probe made the gate fail for the wrong
# reason on its first run, and a ceiling with slack in it is drift with an invitation.
: "${OCOREAI_FLOOR_LANG_SCANNED:=20}"
: "${OCOREAI_FLOOR_ZH_MIRROR_CJK:=2000}"
: "${OCOREAI_CJK_MAX_CHANGELOG:=158161}"
: "${OCOREAI_CJK_MAX_CHECKPOINT:=1159}"
: "${OCOREAI_CJK_MAX_IDEA:=6}"

# P17 floors: the area-guide scan must keep matching (measured 3 guides, 26 distinct gate names
# on 10-26), else "every guide has a shape" would be a claim about an empty list.
: "${OCOREAI_FLOOR_AREA_GUIDES:=3}"
: "${OCOREAI_FLOOR_GUIDE_GATES:=20}"

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
    echo "❌ AGENTS.md is $size chars > cap $OCOREAI_AGENTS_MAX_ROOT — the ratchet is shrink-only."
    echo "   Move a dated block to docs/agent/*.md and leave a pointer, then re-run."
    exit 1
  fi
  sed -i '' "s/: \"\${OCOREAI_AGENTS_MAX_ROOT:=.*$/\
: \"\${OCOREAI_AGENTS_MAX_ROOT:=$size}\"   # pinned $(date +%m-%d) by \`make docs-budget\`/" \
    scripts/agents-md-contract.sh
  echo "✅ re-pinned root cap $OCOREAI_AGENTS_MAX_ROOT -> $size chars (shrunk $(( OCOREAI_AGENTS_MAX_ROOT - size )))"
  exit 0
fi

OCOREAI_AGENTS_MODE="$MODE" \
OCOREAI_AGENTS_MAX_ROOT="$OCOREAI_AGENTS_MAX_ROOT" \
OCOREAI_AGENTS_MAX_CHAIN="$OCOREAI_AGENTS_MAX_CHAIN" \
OCOREAI_AGENTS_MAX_AREA="$OCOREAI_AGENTS_MAX_AREA" \
OCOREAI_AGENTS_MAX_LINE="$OCOREAI_AGENTS_MAX_LINE" \
OCOREAI_CORPUS_MAX_LINE="$OCOREAI_CORPUS_MAX_LINE" \
OCOREAI_CORPUS_MAX_BYTES="$OCOREAI_CORPUS_MAX_BYTES" \
OCOREAI_COMPARATOR_FLOOR_TREES="$OCOREAI_COMPARATOR_FLOOR_TREES" \
OCOREAI_PROBE_FLOOR_INDEX="$OCOREAI_PROBE_FLOOR_INDEX" \
OCOREAI_FLOOR_MD_SCANNED="$OCOREAI_FLOOR_MD_SCANNED" \
OCOREAI_FLOOR_DOC_FILES="$OCOREAI_FLOOR_DOC_FILES" \
OCOREAI_AGENTS_FLOOR_REFS="$OCOREAI_AGENTS_FLOOR_REFS" \
OCOREAI_AGENTS_FLOOR_CLAIMS="$OCOREAI_AGENTS_FLOOR_CLAIMS" \
OCOREAI_AGENTS_FLOOR_SUITES="$OCOREAI_AGENTS_FLOOR_SUITES" \
OCOREAI_AGENTS_FLOOR_SUITE_COUNTS="$OCOREAI_AGENTS_FLOOR_SUITE_COUNTS" \
OCOREAI_AGENTS_FLOOR_ROUTING="$OCOREAI_AGENTS_FLOOR_ROUTING" \
OCOREAI_AGENTS_FLOOR_XREFS="$OCOREAI_AGENTS_FLOOR_XREFS" \
OCOREAI_FLOOR_LANG_SCANNED="$OCOREAI_FLOOR_LANG_SCANNED" \
OCOREAI_FLOOR_ZH_MIRROR_CJK="$OCOREAI_FLOOR_ZH_MIRROR_CJK" \
OCOREAI_CJK_MAX_CHANGELOG="$OCOREAI_CJK_MAX_CHANGELOG" \
OCOREAI_CJK_MAX_CHECKPOINT="$OCOREAI_CJK_MAX_CHECKPOINT" \
OCOREAI_CJK_MAX_IDEA="$OCOREAI_CJK_MAX_IDEA" \
OCOREAI_FLOOR_AREA_GUIDES="$OCOREAI_FLOOR_AREA_GUIDES" \
OCOREAI_FLOOR_GUIDE_GATES="$OCOREAI_FLOOR_GUIDE_GATES" \
OCOREAI_README_FLOOR_ROUTES="$OCOREAI_README_FLOOR_ROUTES" \
OCOREAI_README_FLOOR_JOBS="$OCOREAI_README_FLOOR_JOBS" \
python3 - <<'PY'
import os, re, subprocess, glob

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
    fail.append("B1 AGENTS.md %d chars > cap %d (shrink-only ratchet: move a dated block "
                "to docs/agent/ and leave a pointer)" % (root_size, env_int("OCOREAI_AGENTS_MAX_ROOT")))
for p in guides:
    n = os.path.getsize(p)
    if n > env_int("OCOREAI_AGENTS_MAX_AREA"):
        fail.append("B2 %s %d chars > per-guide cap %d" % (p, n, env_int("OCOREAI_AGENTS_MAX_AREA")))
    chain = root_size + n
    if chain > env_int("OCOREAI_AGENTS_MAX_CHAIN"):
        fail.append("B2 chain AGENTS.md+%s = %d chars > cap %d" % (p, chain, env_int("OCOREAI_AGENTS_MAX_CHAIN")))

# ── P13 the injected file stays rule-only: no diary, no prose walls ──────────
# 10-22: this file stated "Not a diary. A root rule is <=3 lines: what + evidence + the gate.
# Dates… go to CHANGELOG.md" while carrying 38 dated stamps and 37 lines over 400 bytes. A rule
# nobody can re-run is a claim (invariant 1), so the rule became a gate: zero `MM-DD` stamps and no
# line longer than OCOREAI_AGENTS_MAX_LINE bytes. Content that needs either belongs in
# CHANGELOG.md / docs/agent/, one hop away and out of every session's context.
root_text = read("AGENTS.md")
_stamps = re.findall(r"(?<![\d/.])(?:0[1-9]|1[0-2])-(?:[1-9]|[12]\d|3[01])(?![\d])", root_text)
if _stamps:
    fail.append("P13 AGENTS.md carries %d dated stamp(s) (%s) — dates belong to CHANGELOG.md or "
                "docs/agent/, never to the file injected into every session"
                % (len(_stamps), ", ".join(sorted(set(_stamps))[:6])))
_walls = [(i + 1, len(l.encode("utf-8"))) for i, l in enumerate(root_text.splitlines())
          if len(l.encode("utf-8")) > env_int("OCOREAI_AGENTS_MAX_LINE")]
if _walls:
    fail.append("P13 AGENTS.md has %d line(s) over %d bytes (first L%d = %d) — one rule per line, "
                "evidence one hop away; a 400-byte wall is a paragraph wearing a bullet"
                % (len(_walls), env_int("OCOREAI_AGENTS_MAX_LINE"), _walls[0][0], _walls[0][1]))

# ── reference extraction (root + guides share the contract) ───────────────────
NAME = r"(?:~?/?[A-Za-z0-9_+.\-]+/)*[A-Za-z0-9_+.\-]*[A-Za-z0-9_+\-]"
FILE_RE = re.compile(r"(?<![\w/])(" + NAME + r"\.(?:swift|md|sh|yml|yaml|toml|json|h|hpp|metal|py|plist|txt|entitlements|xcprivacy|resolved))(?![\w.])")
ANCHOR_RE = re.compile(r"(?<![\w/])(" + NAME + r"\.(?:swift|md|sh|yml|yaml|json|h|py))(?::|#L?)(\d{1,5})")
CLAIM_RE = re.compile(r"<!--\s*claim:([a-z0-9_]+)\s*(<=|>=|=)\s*(\d+)\s*::\s*(.+?)\s*-->")
MAKE_RE = re.compile(r"`make\s+([a-z][a-z0-9-]+)")
SUITE_RE = re.compile(r"\b([A-Z][A-Za-z0-9]*Tests)\b")
# A gate named with a number in parentheses is a claim about how much it covers.
SUITE_COUNT_RE = re.compile(r"`([A-Za-z0-9_]*Tests)`\((\d+)\)")
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
# Cites into comparator trees. § Upstream Audit Dependencies 6 is the policy they implement:
# comparators are "not pins; nothing linked or redistributed, and a borrowed verdict stays an
# inference" — so these files exist on a host that cloned them and on no runner, and resolving
# them was never an option. Declaring them is the honest form of that fact, and it rots in both
# directions on purpose: delete an entry and its cite goes red, keep one nothing cites and the
# dead-declaration check below goes red. Adding an entry means a doc really did cite an outside
# tree, and the same check counts them so the list cannot quietly become a general exemption.
COMPARATOR_REFS = (
    "ASSETS.json", "Cargo.toml", "PINNED.md", "PROVENANCE.md", "RELEASE-NOTES-1.0.0.md",
    "RUNBOOK.md", "THIRD_PARTY_NOTICES.md", "ZIG-PREVIEW.md", "api_shapes.py",
    "check_provenance.py", "engine_component.py", "structured_server.py",
    "docs/TERMINAL_LAUNCH.md", "docs/structured_decisions.md", "packaging/ENGINE-COMPONENT.md",
    "dev/tests/server/test_anthropic_contract.py", "entrypoints/anthropic/serving.py",
    "entrypoints/openai/parser/harmony_utils.py", "entrypoints/openai/responses/harmony.py",
    "entrypoints/serve/utils/tool_calls_utils.py", "srt/entrypoints/anthropic/protocol.py",
    "srt/entrypoints/openai/protocol.py", "serving_chat.py")
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
clones = sorted({p for h in HOMES for p in glob.glob(os.path.join(h, "references/*"))})
# The dependency checkouts this repo actually compiles: on CI there is no ~/references, but
# a leg that resolved the pin can still resolve an upstream basename against real code.
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

refs, anchors, claims, suites, make_targets, routing = set(), set(), set(), set(), set(), set()
suite_counts = set()
for src, text in docs.items():
    for raw in text.splitlines():
        line = re.sub(r"https?://\S+", " ", raw)  # URLs are cites, not repo paths
        exempt = any(m in line for m in ABSENT)
        for m in FILE_RE.finditer(line):
            refs.add((src, m.group(1)))
            if not exempt:
                refs.add(("!", src, m.group(1)))
        for m in ANCHOR_RE.finditer(line):
            anchors.add((src, m.group(1), int(m.group(2))))
        for m in CLAIM_RE.finditer(line):
            claims.add((src, m.group(1), m.group(2), int(m.group(3)), m.group(4)))
        suites.update((src, s) for s in SUITE_RE.findall(line))
        suite_counts.update((src, n, int(c)) for n, c in SUITE_COUNT_RE.findall(line))
        make_targets.update(MAKE_RE.findall(line))
        routing.update((src, r) for r in ROUTING_RE.findall(line))

hard_refs = sorted({r for t in refs if t and t[0] == "!" for r in t[1:]})

# ── P1 floors: prove the scan is still scanning ──────────────────────────────
if len(hard_refs) < env_int("OCOREAI_AGENTS_FLOOR_REFS"):
    fail.append("P1 only %d gateable file refs found (< floor %d) — the reference regex "
                "stopped matching, so every other check here is vacuous" % (len(hard_refs), env_int("OCOREAI_AGENTS_FLOOR_REFS")))
if len(claims) < env_int("OCOREAI_AGENTS_FLOOR_CLAIMS"):
    fail.append("P1 only %d <!-- claim:… --> markers (< floor %d) — a doc whose numbers are "
                "not machine-checkable cannot gate itself" % (len(claims), env_int("OCOREAI_AGENTS_FLOOR_CLAIMS")))
if len(suites) < env_int("OCOREAI_AGENTS_FLOOR_SUITES"):
    fail.append("P1 only %d *Tests names (< floor %d)" % (len(suites), env_int("OCOREAI_AGENTS_FLOOR_SUITES")))
if len(suite_counts) < env_int("OCOREAI_AGENTS_FLOOR_SUITE_COUNTS"):
    fail.append("P1 only %d numbered `XxxTests`(N) claims (< floor %d) — the count regex stopped "
                "matching, so P11 would pass vacuously"
                % (len(suite_counts), env_int("OCOREAI_AGENTS_FLOOR_SUITE_COUNTS")))
if len(routing) < env_int("OCOREAI_AGENTS_FLOOR_ROUTING"):
    fail.append("P1 only %d routing-table rows (< floor %d)" % (len(routing), env_int("OCOREAI_AGENTS_FLOOR_ROUTING")))

# ── P2 refs resolve ──────────────────────────────────────────────────────────
unresolved, upstream, declared_outside = [], [], []
for r in hard_refs:
    if r.startswith("~/") or r.startswith("/"):
        targets = [os.path.expanduser(r)]
        if r.startswith("~/"):
            targets += [os.path.join(h, r[2:]) for h in HOMES]
        if not any(os.path.exists(t2) for t2 in targets):
            warn.append("P2 host-local path not on this host: %s (must be declared host-local, not project truth)" % r)
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
    if r in COMPARATOR_REFS or base in COMPARATOR_REFS:
        declared_outside.append(r)
        continue
    unresolved.append(r)
if unresolved:
    fail.append("P2 %d unresolved reference(s) — no such file here, no basename match in git, "
                "not in a local upstream clone, not declared absent: %s"
                % (len(unresolved), ", ".join(unresolved)))
# A declaration that no doc uses is an exemption with no owner, and a list nobody trims is how
# allowlists become a way of not looking. Both directions are cheap to check, so both are checked.
dead_declarations = [d for d in COMPARATOR_REFS
                     if not any(h == d or os.path.basename(h) == d for h in hard_refs)]
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
bad_anchors = []
for src, f, ln in sorted(anchors):
    cand = f if (os.path.exists(f) or f in tracked) else (by_base.get(os.path.basename(f)) or [None])[0]
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

# ── P11 numbered suite claims equal what the file holds ──────────────────────
# `ToolProseLedgerTests`(11) is not prose, it is a coverage number. Measured 10-21: five of
# the twelve such claims in the docs had drifted off the files they name, one of them upward
# (`MetalShaderLibraryTests`(7) against a 6-test file) — the shape invariant 1 describes: a
# claim with nothing reading it. The count is @Test declarations in Tests/**/<Name>.swift,
# which is what a `swift test --filter <Name>` run reports (a parameterized @Test is one test
# carrying N cases).
test_fn_counts = {}
for p in glob.glob("Tests/**/*.swift", recursive=True):
    test_fn_counts[os.path.splitext(os.path.basename(p))[0]] = len(
        re.findall(r"^\s*@Test\b", read(p), re.M))
stale_counts, unknown_counts = [], []
# Dated logs are exempt: `closed-items-log.md`/`CHANGELOG.md` record what was true on the day
# they were written, and "correcting" them rewrites the record. The contract surfaces — the root
# and the guides a session is routed into — describe the code as it is, so those numbers chase
# the files.
DIARIES = {"CHANGELOG.md", "docs/agent/closed-items-log.md"}
for src, name, claimed in sorted(suite_counts):
    if src in DIARIES:
        continue
    if name not in test_fn_counts:
        unknown_counts.append("%s %s" % (src, name))
    elif test_fn_counts[name] != claimed:
        stale_counts.append("%s %s(%d) — file holds %d" % (src, name, claimed, test_fn_counts[name]))
if stale_counts:
    fail.append("P11 %d numbered suite claim(s) do not match Tests/: %s"
                % (len(stale_counts), "; ".join(stale_counts)))
if unknown_counts:
    fail.append("P11 %d numbered suite claim(s) name no file under Tests/: %s"
                % (len(unknown_counts), "; ".join(unknown_counts)))

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

router_routes = {
    "%s %s" % (m.group(1).upper(), m.group(2))
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
    fail.append("P14 %d markdown table defect(s) (one row per line, one column count): %s"
                % (len(table_bad), "; ".join(table_bad[:6])))

AREA_GUIDES = [q for q in glob.glob("Sources/**/AGENTS.md", recursive=True)
               + glob.glob("Tests/**/AGENTS.md", recursive=True)]
doc_files = sorted(glob.glob("docs/agent/*.md"))
reachable = read("AGENTS.md") + "".join(read(q) for q in AREA_GUIDES)
doc_orphans = [q for q in doc_files if os.path.basename(q) not in reachable]
if len(doc_files) < env_int("OCOREAI_FLOOR_DOC_FILES"):
    fail.append("P14 only %d docs/agent/*.md found (floor %d) — sweeping orphans away would look "
                "like a clean pass" % (len(doc_files), env_int("OCOREAI_FLOOR_DOC_FILES")))
if doc_orphans:
    fail.append("P14 %d file(s) in docs/agent/ are named by neither AGENTS.md nor an area guide, so "
                "nothing routes a reader to them: %s" % (len(doc_orphans), ", ".join(doc_orphans)))

# ── P15: corpus shape ────────────────────────────────────────────────────────
# The one-hop corpus is not injected, so it does not cost every session — but it is where an
# agent goes when AGENTS.md sends it somewhere, and the same failure modes apply: a 1,200-byte
# line nobody reads, a file that grows because nothing priced it. Code fences, HTML comments and
# table rows are exempt (a command line may be long; a claim inside a comment must stay on the
# line its parser reads it from, and table arity is P14's job).
CMP_DOC = "docs/agent/comparator-repos.md"
CORPUS = (["AGENTS.md", "ARCHITECTURE.md", "CONTRIBUTING.md", "scripts/probes/README.md"]
          + AREA_GUIDES + doc_files)
corpus_bytes = 0
corpus_walls = []
for q in sorted(set(CORPUS)):
    if not os.path.exists(q):
        fail.append("P15 corpus file missing: %s" % q)
        continue
    txt = read(q)
    corpus_bytes += len(txt.encode("utf-8"))
    fence = False
    for n, l in enumerate(txt.split("\n"), 1):
        if l.strip().startswith("```"):
            fence = not fence
            continue
        if fence or l.lstrip().startswith(("|", "#", "<!--")):
            continue
        b = len(l.encode("utf-8"))
        if b > env_int("OCOREAI_CORPUS_MAX_LINE"):
            corpus_walls.append("%s:%d (%d bytes)" % (q, n, b))
if corpus_bytes > env_int("OCOREAI_CORPUS_MAX_BYTES"):
    fail.append("P15 the agent-facing corpus is %d bytes > cap %d — text goes in only when text "
                "comes out (B1's ratchet, applied to the corpus; a legitimate growth must be a "
                "visible edit of the constant)" % (corpus_bytes, env_int("OCOREAI_CORPUS_MAX_BYTES")))
if corpus_walls:
    fail.append("P15 %d line(s) over %d bytes in the agent-facing corpus (outside code fences, "
                "comments and tables): %s"
                % (len(corpus_walls), env_int("OCOREAI_CORPUS_MAX_LINE"), "; ".join(corpus_walls[:6])))

# ── P16 comparator coupling ──────────────────────────────────────────────────
# A comparator is a dependency you chose to read, not a folder you own. The floor below prices the
# choice twice: named in the diary, and coupled (or honestly declared uncoupled) in the build.
cmp_floor = env_int("OCOREAI_COMPARATOR_FLOOR_TREES")
cmp_block = re.search(r"\*\*Comparators\*\* \u2014([^:]*):", root_text, re.S)
comparators = [c.strip() for c in cmp_block.group(1).replace("\n", " ").split(",")] if cmp_block else []
comparators = [c for c in comparators if c]
changelog = read("CHANGELOG.md")
cmp_silent, cmp_coupled = [], []
for name in comparators:
    if not re.search(re.escape(name), changelog, re.I):
        cmp_silent.append(name)
    hits = subprocess.run(["git", "grep", "-l", "-i", "-F", name, "--", "Sources", "Tests"],
                          capture_output=True, text=True)
    if hits.stdout.strip():
        cmp_coupled.append(name)
cmp_derived = sorted(n.lower() for n in comparators if n not in cmp_coupled)
if len(comparators) < cmp_floor:
    fail.append("P16 only %d comparator tree(s) parsed from \u00a7 Upstream Audit Dependencies 6 "
                "(floor %d) \u2014 a list that stopped matching passes vacuously"
                % (len(comparators), cmp_floor))
if cmp_silent:
    fail.append("P16 %d comparator(s) named in \u00a7 Upstream 6 never appear in CHANGELOG.md (%s) \u2014 "
                "a tree that was never audited is decoration, not a comparator: use it or drop the name"
                % (len(cmp_silent), ", ".join(cmp_silent)))
NUM_WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
             "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14}
stated = []
stated_block = re.search(r"([a-z]+) trees have zero coupling\s*\u2014\s*(.+?)\s*\u2014", read(CMP_DOC), re.S)
if not stated_block:
    fail.append("P16 %s no longer states its zero-coupling list \u2014 the premise of the claim is gone"
                % CMP_DOC)
else:
    stated = [x.strip().strip("`").lower() for x in stated_block.group(2).replace("\n", " ").split(",")]
    stated = [x for x in stated if x]
    if NUM_WORDS.get(stated_block.group(1), -1) != len(cmp_derived):
        fail.append("P16 %s says \"%s trees have zero coupling\", grep says %d (%s)"
                   % (CMP_DOC, stated_block.group(1), len(cmp_derived), ", ".join(cmp_derived)))
    if sorted(stated) != cmp_derived:
        fail.append("P16 %s lists zero-coupling as (%s) but grep over Sources/Tests derives (%s) \u2014 "
                   "a tree that gained a cite cannot stay declared dead, and one that lost it cannot be "
                   "quoted as consumed" % (CMP_DOC, ", ".join(sorted(stated)), ", ".join(cmp_derived)))
    # Two more hand-copied lists are checked against § 6 rather than trusted: the long-form doc can
    # name a tree it never describes (splash was registered for rounds with no entry), and its
    # diary-refresh loop can quietly drop one while claiming to re-measure every cell (openclaw was).
    cmp_text = read(CMP_DOC)
    entry_missing = [n for n in comparators if not re.search("^- `" + re.escape(n) + "`", cmp_text, re.M)]
    if entry_missing:
        fail.append("P16 § Upstream 6 names %s but %s carries no entry for it \u2014 an index that"
                   " points at a description which was never written" % (", ".join(entry_missing), CMP_DOC))
    loop_m = re.search("for r in ([A-Za-z0-9 -]+); do", cmp_text)
    if not loop_m:
        fail.append("P16 %s no longer states its diary-refresh loop \u2014 the cell values quoted in"
                   " this file would have no reproducible source" % CMP_DOC)
    else:
        registered = sorted({c.lower() for c in comparators})
        loop_set = sorted({t.lower() for t in loop_m.group(1).split()})
        if loop_set != registered:
            fail.append("P16 %s's refresh loop covers %d tree(s) while § Upstream 6 registers %d \u2014"
                       " a hand-copied list drifts silently; it must name exactly the registered set"
                       " (differing: %s)" % (CMP_DOC, len(loop_set), len(registered),
                                            ", ".join(sorted(set(loop_set) ^ set(registered)))))

# ── P17 area-guide shape ─────────────────────────────────────────────────────
# An area guide is injected into the context of every session that works inside its subtree, so it
# owes the root file's discipline *and* a predictable shape: a rule with no command to run is a
# claim about how to check it, a guide that never says root still governs reads as a replacement
# for it, and a dated stamp inside an injected file is the diary P13 forbids wearing a subtree
# pass. Floors first, or an empty glob makes every assertion below vacuous (P1's pattern).
H1_RE = re.compile(r"^# [A-Z][^—]{2,60}— \S")
CMD_RE = re.compile(r"`(make [a-z-]+[^`]*|swift (build|test)[^`]*)`")
if len(AREA_GUIDES) < env_int("OCOREAI_FLOOR_AREA_GUIDES"):
    fail.append("P17 only %d area guide(s) scanned (floor %d) \u2014 the glob rotted, so every "
                "shape rule below would pass vacuously"
                % (len(AREA_GUIDES), env_int("OCOREAI_FLOOR_AREA_GUIDES")))
guide_gates = set()
for g in sorted(set(AREA_GUIDES)):
    txt = read(g)
    lines = txt.split("\n")
    head = "\n".join(lines[:8])
    if not H1_RE.match(lines[0]):
        fail.append("P17 %s line 1 must be `# <Area> \u2014 <one-line claim>`: uniform openings are "
                    "what let a reader scan the Nth guide like the first" % g)
    elif len(lines[0].encode("utf-8")) > 90:
        fail.append("P17 %s title is %d bytes \u2014 the claim is one line"
                    % (g, len(lines[0].encode("utf-8"))))
    if not re.search(r"AGENTS\.md`?[^\n]{0,30}governs", head):
        fail.append("P17 %s does not state in its first 8 lines that the root AGENTS.md governs "
                    "\u2014 a guide that stays silent reads like it replaced the root file" % g)
    if not re.search(r"`[A-Za-z0-9_/]+/`", head):
        fail.append("P17 %s scope block names no directory it owns, so nothing says where its "
                    "rules stop and root's resume" % g)
    gates = set(re.findall(r"`([A-Za-z0-9_]*Tests)`", txt))
    guide_gates |= gates
    if len(gates) < 2:
        fail.append("P17 %s names %d gate(s); a rule here that no gate goes red for is a claim "
                    "(invariant 1 applies inside a subtree too)" % (g, len(gates)))
    vsec = re.search(r"^## (Verification|Validation)[^\n]*$", txt, re.M)
    if not vsec:
        fail.append("P17 %s has no `## Verification\u2026` section \u2014 the commands that check "
                    "this subtree belong where the work is being read" % g)
    else:
        tail = txt[vsec.end():]
        nxt = re.search(r"^## ", tail, re.M)
        if not CMD_RE.search(tail[:nxt.start()] if nxt else tail):
            fail.append("P17 %s's Verification section names no `make …` / `swift …` command" % g)
    stamps = re.findall(r"(?<![\d/.])(?:0[1-9]|1[0-2])-(?:[1-9]|[12]\d|3[01])(?![\d])", txt)
    if stamps:
        fail.append("P17 %s carries %d dated stamp(s) (%s) \u2014 P13's diary rule reaches inside a "
                    "subtree: an injected file holds rules, the date belongs to CHANGELOG.md"
                    % (g, len(stamps), ", ".join(sorted(set(stamps))[:4])))
if len(guide_gates) < env_int("OCOREAI_FLOOR_GUIDE_GATES"):
    fail.append("P17 only %d distinct gate name(s) across area guides (floor %d) \u2014 guides whose "
                "rules are not wired to a test" % (len(guide_gates), env_int("OCOREAI_FLOOR_GUIDE_GATES")))

# ── P18 documentation language ────────────────────────────────────────────────
# README.md holds 0 CJK characters and README.zh.md 2 436 on the day this gate was written; before it,
# the English README carried a Chinese install block that the zh mirror already held, and four
# agent-facing docs each leaked a phrase. Nothing could see that, because nothing counted.
CJK_RE = re.compile(r"[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]")
ESC_RE = re.compile(r"\\u[0-9a-fA-F]{4}")
MIRROR = "README.zh.md"
DIARY = {"CHANGELOG.md": env_int("OCOREAI_CJK_MAX_CHANGELOG"),
         "CHECKPOINT.md": env_int("OCOREAI_CJK_MAX_CHECKPOINT"),
         "IDEA.md": env_int("OCOREAI_CJK_MAX_IDEA")}
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

for f, ceiling in sorted(DIARY.items()):
    if f not in tracked_md:
        continue
    n = len(CJK_RE.findall(read(f)))
    if n > ceiling:
        fail.append("P18 %s grew to %d CJK characters, ceiling %d \u2014 the diary is not rewritten for "
                    "the rule, but new prose under it is English; raise the ceiling only by deleting "
                    "history you actually mean to keep in Chinese" % (f, n, ceiling))

# ── report ───────────────────────────────────────────────────────────────────
print("AGENTS.md contract (%s)" % mode)
print("  xrefs     §-refs=%d (floor %d)  anchors=%d  dangling=%d"
      % (len(refs), env_int("OCOREAI_AGENTS_FLOOR_XREFS"), len(anchors), len(dead_refs)))
print("  corpus    files=%d bytes=%d/%d  walls=%d  probe-index=%d/%d  doc-orphans=%d  table-defects=%d"
      % (len(sorted(set(CORPUS))), corpus_bytes, env_int("OCOREAI_CORPUS_MAX_BYTES"),
         len(corpus_walls), len(probe_indexed), len(probe_scripts), len(doc_orphans), len(table_bad)))
print("  budgets   root=%d/%d chars  guides=%d  chain-cap=%d"
      % (root_size, env_int("OCOREAI_AGENTS_MAX_ROOT"), len(guides), env_int("OCOREAI_AGENTS_MAX_CHAIN")))
print("  language  english-md=%d (floor %d)  mirror-cjk=%d (floor %d)  diary=%s"
      % (len(lang_zero), env_int("OCOREAI_FLOOR_LANG_SCANNED"),
         len(CJK_RE.findall(read(MIRROR))) if os.path.exists(MIRROR) else -1,
         env_int("OCOREAI_FLOOR_ZH_MIRROR_CJK"),
         ",".join("%s:%d/%d" % (f.split(".")[0], len(CJK_RE.findall(read(f))), c)
                  for f, c in sorted(DIARY.items()) if f in tracked_md)))
print("  guides    area=%d (floor %d)  gate-names=%d (floor %d)"
      % (len(set(AREA_GUIDES)), env_int("OCOREAI_FLOOR_AREA_GUIDES"),
         len(guide_gates), env_int("OCOREAI_FLOOR_GUIDE_GATES")))
print("  scan      gateable-refs=%d (floor %d)  claims=%d/%d ok (floor %d)  suites=%d  routing=%d  upstream-trees=%d"
      % (len(hard_refs), env_int("OCOREAI_AGENTS_FLOOR_REFS"), ok_claims, len(claims),
         env_int("OCOREAI_AGENTS_FLOOR_CLAIMS"), len(suites), len(routing), len(clones)))
print("  comparators trees=%d (floor %d) diary-silent=%d coupled=%d zero-coupling=%d/%d=%s"
      % (len(comparators), cmp_floor, len(cmp_silent), len(cmp_coupled), len(cmp_derived),
         len(stated), sorted(stated) == cmp_derived))
print("  human     router-routes=%d (floor %d)  public-paths=%d  README tables=%s"
      % (len(router_routes), env_int("OCOREAI_README_FLOOR_ROUTES"), len(public_paths),
         ",".join("%d rows" % len({("%s %s" % (m.group(1), m.group(2)))
                                  for m in ROW_RE.finditer(read(d))}) for d in HUMAN_DOCS)))
print("  suites    numbered-claims=%d/%d ok (floor %d)  files-with-@Test=%d"
      % (len([1 for s, _, _ in suite_counts if s not in DIARIES])
         - len(stale_counts) - len(unknown_counts),
         len([1 for s, _, _ in suite_counts if s not in DIARIES]),
         env_int("OCOREAI_AGENTS_FLOOR_SUITE_COUNTS"), len(test_fn_counts)))
if upstream:
    print("  outside   %d/%d comparator-tree cite(s) declared (host trees, never on a runner)"
      % (len(declared_outside), len(COMPARATOR_REFS)))
print("  upstream  %d ref(s) resolved in a dependency checkout or ~/references "
          "(line numbers inside them are what `make anchor-check` verifies): %s"
          % (len(upstream), ", ".join(sorted(set(upstream))[:6])))
for w in warn:
    print("  ⚠ %s" % w)
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
