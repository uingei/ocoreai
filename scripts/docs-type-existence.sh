#!/usr/bin/env bash
# docs-type-existence.sh — a type named in the architecture docs must exist.
#
# Why. ARCHITECTURE.md was a 2026-07-26 review that survived its own subject: it diagrammed
# `BackendProtocol.swift` after that file had been deleted (2123143), and recommended a CoreAI
# capability matrix with `supportsGrammar: false` in §7 while §5 recorded CoreAI-native grammar.
# Line numbers have `make anchor-check`; nothing checked *names*. A doc that names a dead type
# teaches the next session an architecture that does not exist.
#
# Rule: every CamelCase identifier in the architecture docs ending in Protocol|Bridge|Pool|Manager|
# Cache|Guard|Ticket|Ledger|Accounting must resolve in Sources/ (ours) or in a primary reference
# clone. A name on a line that says it was removed/deleted/superseded is allowed, but is counted
# and printed as `historical` — recording a death is legitimate, silently skipping one is not.
# Floors its own scan so a rotted regex fails instead of passing vacuously.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$here" || exit 2
exec "${PYTHON:-python3}" - "$here" <<'PY_EOF'
import os, re, subprocess, sys
root = sys.argv[1]
floor = int(os.environ.get("OCOREAI_DOC_TYPE_FLOOR", "8"))
NAME = re.compile(r"`([A-Z][A-Za-z0-9]{3,}(?:Protocol|Bridge|Pool|Manager|Cache|Guard|Ticket|Ledger|Accounting))`")
DEAD = re.compile(r"removed|deleted|removal|superseded|no longer|\bno\b|\bnot\b|gone|obsolete", re.I)
refs = os.environ.get("OCOREAI_REFS") or os.path.expanduser("~/references")
clones = [os.path.join(refs, n) for n in
          ("mlx-swift-lm", "mlx-swift", "coreai-models", "codex", "ollama", "vllm", "sglang")]
clones = [c for c in clones if os.path.isdir(os.path.join(c, ".git"))]
files = [p for p in ("ARCHITECTURE.md", "AGENTS.md") if os.path.exists(p)]

def found_here(n):
    return subprocess.run(["git", "-C", root, "grep", "-l", "-w", n, "--", "Sources"],
                          capture_output=True, text=True).returncode == 0

def found_upstream(n):
    for c in clones:
        if subprocess.run(["git", "-C", c, "grep", "-l", "-w", "--max-count=1", n],
                          capture_output=True, text=True).returncode == 0:
            return os.path.basename(c)
    return None

dead_ok = local = upstream = 0
bad = []
names = set()
for f in files:
    for no, raw in enumerate(open(f, encoding="utf-8", errors="replace").read().splitlines(), 1):
        for n in NAME.findall(raw):
            names.add(n)
            if found_here(n):
                local += 1
            elif found_upstream(n):
                upstream += 1
            elif DEAD.search(raw):
                dead_ok += 1
                print("  historical %s — named on a removal line (%s:%d), accepted" % (n, f, no))
            else:
                bad.append("%s (%s:%d)" % (n, f, no))
scanned = local + upstream + dead_ok + len(bad)
print("  doc type names: distinct=%d scanned=%d local=%d upstream=%d historical=%d unresolved=%d (floor %d)"
      % (len(names), scanned, local, upstream, dead_ok, len(bad), floor))
if scanned < floor:
    print("  ❌ scan matched only %d name(s) (< floor %d) — the pattern rotted, so 'every name exists' is vacuous" % (scanned, floor))
    sys.exit(1)
if bad:
    print("  ❌ %d type name(s) in the architecture docs exist in no checkout:" % len(bad))
    for x in bad[:12]:
        print("     ", x)
    sys.exit(1)
print("  ✅ every type named in the architecture docs exists (or is recorded as removed)")
PY_EOF
