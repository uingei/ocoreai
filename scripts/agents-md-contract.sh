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
#   P7 routing       every area guide on disk is listed in the root routing table
#   P8 pin agreement the upstream revision AGENTS.md quotes is the revision
#                    Package.swift actually pins — the pin is the contract (§ Upstream),
#                    and a stale SHA in the injected context sends every future session
#                    to audit the wrong commit
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
: "${OCOREAI_AGENTS_MAX_ROOT:=50668}"   # pinned 10-20 by `make docs-budget`
: "${OCOREAI_AGENTS_MAX_CHAIN:=78000}" # AGENTS.md + one area guide loaded together
: "${OCOREAI_AGENTS_MAX_AREA:=16000}"  # each Sources/**/AGENTS.md or docs/agent/*.md
# P1 floors: keep just under the measured count so a broken scan is a failure, not a pass.
: "${OCOREAI_AGENTS_FLOOR_REFS:=50}"
: "${OCOREAI_AGENTS_FLOOR_CLAIMS:=8}"
: "${OCOREAI_AGENTS_FLOOR_SUITES:=8}"
: "${OCOREAI_AGENTS_FLOOR_ROUTING:=4}"

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
OCOREAI_AGENTS_FLOOR_REFS="$OCOREAI_AGENTS_FLOOR_REFS" \
OCOREAI_AGENTS_FLOOR_CLAIMS="$OCOREAI_AGENTS_FLOOR_CLAIMS" \
OCOREAI_AGENTS_FLOOR_SUITES="$OCOREAI_AGENTS_FLOOR_SUITES" \
OCOREAI_AGENTS_FLOOR_ROUTING="$OCOREAI_AGENTS_FLOOR_ROUTING" \
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

# ── reference extraction (root + guides share the contract) ───────────────────
NAME = r"(?:~?/?[A-Za-z0-9_+.\-]+/)*[A-Za-z0-9_+.\-]*[A-Za-z0-9_+\-]"
FILE_RE = re.compile(r"(?<![\w/])(" + NAME + r"\.(?:swift|md|sh|yml|yaml|toml|json|h|hpp|metal|py|plist|txt|entitlements|xcprivacy|resolved))(?![\w.])")
ANCHOR_RE = re.compile(r"(?<![\w/])(" + NAME + r"\.(?:swift|md|sh|yml|yaml|json|h|py))(?::|#L?)(\d{1,5})")
CLAIM_RE = re.compile(r"<!--\s*claim:([a-z0-9_]+)\s*(<=|>=|=)\s*(\d+)\s*::\s*(.+?)\s*-->")
MAKE_RE = re.compile(r"`make\s+([a-z][a-z0-9-]+)")
SUITE_RE = re.compile(r"\b([A-Z][A-Za-z0-9]*Tests)\b")
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

docs = {"AGENTS.md": root_text}
docs.update({p: read(p) for p in guides})

refs, anchors, claims, suites, make_targets, routing = set(), set(), set(), set(), set(), set()
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
    quoted = set(re.findall(r"Pinned upstream `mlx-swift-lm` at `([0-9a-f]{7,})`", read("AGENTS.md")))
    if not quoted:
        fail.append("P8 AGENTS.md no longer states the mlx-swift-lm pin in the form the gate reads")
    elif not any(q == pin or pin.startswith(q) or q.startswith(pin) for q in quoted):
        fail.append("P8 AGENTS.md quotes pin %s but Package.swift pins %s — the injected context "
                    "names a stale upstream contract" % ("/".join(sorted(quoted)), pin))

# ── report ───────────────────────────────────────────────────────────────────
print("AGENTS.md contract (%s)" % mode)
print("  budgets   root=%d/%d chars  guides=%d  chain-cap=%d"
      % (root_size, env_int("OCOREAI_AGENTS_MAX_ROOT"), len(guides), env_int("OCOREAI_AGENTS_MAX_CHAIN")))
print("  scan      gateable-refs=%d (floor %d)  claims=%d/%d ok (floor %d)  suites=%d  routing=%d  upstream-trees=%d"
      % (len(hard_refs), env_int("OCOREAI_AGENTS_FLOOR_REFS"), ok_claims, len(claims),
         env_int("OCOREAI_AGENTS_FLOOR_CLAIMS"), len(suites), len(routing), len(clones)))
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
