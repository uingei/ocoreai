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
: "${OCOREAI_AGENTS_MAX_ROOT:=30138}"   # pinned 10-22 by `make docs-budget`
                                     # `make docs-budget` may only lower it (B1 stays a ratchet)
# P13: the injected file carries rules, not diary. Longest allowed line in AGENTS.md, in bytes.
: "${OCOREAI_AGENTS_MAX_LINE:=400}"
# P15: the same shape rule for the corpus an agent reads one hop out — area guides,
# docs/agent/*, the probe index, ARCHITECTURE/CONTRIBUTING. Measured 10-22 after the corpus
# pass: 13 files, 152,041 bytes, zero lines over 400 bytes outside code fences. Raising
# either constant must be a visible edit in the diff.
: "${OCOREAI_CORPUS_MAX_LINE:=400}"
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
: "${OCOREAI_CORPUS_MAX_BYTES:=144942}"
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
OCOREAI_PROBE_FLOOR_INDEX="$OCOREAI_PROBE_FLOOR_INDEX" \
OCOREAI_FLOOR_MD_SCANNED="$OCOREAI_FLOOR_MD_SCANNED" \
OCOREAI_FLOOR_DOC_FILES="$OCOREAI_FLOOR_DOC_FILES" \
OCOREAI_AGENTS_FLOOR_REFS="$OCOREAI_AGENTS_FLOOR_REFS" \
OCOREAI_AGENTS_FLOOR_CLAIMS="$OCOREAI_AGENTS_FLOOR_CLAIMS" \
OCOREAI_AGENTS_FLOOR_SUITES="$OCOREAI_AGENTS_FLOOR_SUITES" \
OCOREAI_AGENTS_FLOOR_SUITE_COUNTS="$OCOREAI_AGENTS_FLOOR_SUITE_COUNTS" \
OCOREAI_AGENTS_FLOOR_ROUTING="$OCOREAI_AGENTS_FLOOR_ROUTING" \
OCOREAI_AGENTS_FLOOR_XREFS="$OCOREAI_AGENTS_FLOOR_XREFS" \
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
unresolved, upstream = [], []
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
    unresolved.append(r)
if unresolved:
    fail.append("P2 %d unresolved reference(s) — no such file here, no basename match in git, "
                "not in a local upstream clone, not declared absent: %s"
                % (len(unresolved), ", ".join(unresolved)))

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

# ── report ───────────────────────────────────────────────────────────────────
print("AGENTS.md contract (%s)" % mode)
print("  xrefs     §-refs=%d (floor %d)  anchors=%d  dangling=%d"
      % (len(refs), env_int("OCOREAI_AGENTS_FLOOR_XREFS"), len(anchors), len(dead_refs)))
print("  corpus    files=%d bytes=%d/%d  walls=%d  probe-index=%d/%d  doc-orphans=%d  table-defects=%d"
      % (len(sorted(set(CORPUS))), corpus_bytes, env_int("OCOREAI_CORPUS_MAX_BYTES"),
         len(corpus_walls), len(probe_indexed), len(probe_scripts), len(doc_orphans), len(table_bad)))
print("  budgets   root=%d/%d chars  guides=%d  chain-cap=%d"
      % (root_size, env_int("OCOREAI_AGENTS_MAX_ROOT"), len(guides), env_int("OCOREAI_AGENTS_MAX_CHAIN")))
print("  scan      gateable-refs=%d (floor %d)  claims=%d/%d ok (floor %d)  suites=%d  routing=%d  upstream-trees=%d"
      % (len(hard_refs), env_int("OCOREAI_AGENTS_FLOOR_REFS"), ok_claims, len(claims),
         env_int("OCOREAI_AGENTS_FLOOR_CLAIMS"), len(suites), len(routing), len(clones)))
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
    print("  upstream  %d ref(s) resolved in a dependency checkout or ~/references "
          "(line numbers inside them are what `make anchor-check` verifies): %s"
          % (len(upstream), ", ".join(sorted(set(upstream))[:6])))
for w in warn:
    print("  ⚠ %s" % w)
if fail:
    print("\n❌ %d violation(s):" % len(fail))
    for f in fail:
        print("   • %s" % f)
    raise SystemExit(1 if mode == "check" else 0)
print("\n✅ AGENTS.md contract holds (budgets, refs, anchors, claims, gates, routing)")
PY
