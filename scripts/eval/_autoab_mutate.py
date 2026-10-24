#!/usr/bin/env python3
"""Break the auto-A/B loop on purpose, thirteen ways, and require the self-test to go red each time.

`_autoab_selftest.py` says the rules hold; this file says the *test of the rules* holds, by
editing each rule out and requiring a failure. A mutation that the self-test does not catch is
printed as ESCAPED and decides the exit code, because an uncaught mutation is a property that was
documented but never gated. Every edit is reverted from an in-memory snapshot and verified by
checksum, so a green run means the tree is byte-for-byte the tree that went in.

    python3 scripts/eval/_autoab_mutate.py          # ~15 s, no GPU, no build
"""

import hashlib
import os
import subprocess
import sys

import _ledger_selftest as ledgerdoc  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"

# (label, file, exact text to remove, replacement) — each line is the mutation, spelled out so the
# README's table and this list cannot drift apart silently.
MUTATIONS = [
    ("protected list loses the frozen task set",
     "autoloop-protected.txt", "scripts/eval/tasks-edit-repair.json\n", ""),
    ("shipped alpha loosened", "_autoab_gate.py", "alpha=0.05, veto_drop=2", "alpha=0.99, veto_drop=2"),
    ("alpha knob unwired", "_autoab_gate.py",
     'float(os.environ.get("OCOREAI_AUTOAB_ALPHA", "0.05"))', "0.05"),
    ("k_min lowered to 1", "_autoab_gate.py", "k_min=6,", "k_min=1,"),
    ("regression veto disabled", "_autoab_gate.py", "veto_drop=2)", "veto_drop=99)"),
    ("discordance relapsed to the A×B cross product", "_repeat_stats.py",
     "        b += sum(1 for x, y in zip(pa, pb) if x and not y)\n"
     "        c += sum(1 for x, y in zip(pa, pb) if y and not x)",
     "        b += sum(pa) * (k - sum(pb))\n"
     "        c += (k - sum(pa)) * sum(pb)"),
    ("matched cells shrunk to one run", "_repeat_stats.py",
     "    k = min(len(ra), len(rb))", "    k = 1"),
    ("allow list emptied", "autoloop-allow.txt", "Sources/\n", ""),
    ("destructive git command reintroduced", "autoab.sh",
     'restore_tree() {\n  local patch="$1"', 'restore_tree() {\n  git checkout -- .\n  local patch="$1"'),
    ("tree snapshot unscoped", "autoab.sh", 'tree_state "$BEFORE"', 'git status --porcelain > "$BEFORE"'),
    ("write scope hardcoded", "autoab.sh",
     'while IFS= read -r prefix; do SCOPE+=("$prefix"); done < <(sed \'s/#.*//\' "$ALLOW"'
     ' | sed \'/^[[:space:]]*$/d\')',
     'SCOPE+=("Sources/")  # hardcoded, no longer derived from the allow list'),
    ("task-set guard unwired from the loop", "_autoab_gate.py",
     "    mismatch = taskset_mismatch(base, variant)", "    mismatch = None"),
    # the guard still exists and is still called — it just always says "same game". A call site that
    # survived while its answer went dead is the failure mode a presence-check alone cannot see.
    ("task-set guard alive but dead", "_repeat_stats.py",
     "    if a == b:\n        return None",
     "    return None\n    if a == b:\n        return None"),
]


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()[:12]


def selftest():
    proc = subprocess.run([sys.executable, os.path.join(HERE, "_autoab_selftest.py")],
                         capture_output=True, text=True, env=os.environ)
    first = proc.stdout.splitlines()[0] if proc.stdout else "<no output>"
    return proc.returncode, first


def main():
    files = sorted({m[1] for m in MUTATIONS})
    snapshot = {f: open(os.path.join(HERE, f), encoding="utf-8").read() for f in files}
    before = {f: sha(os.path.join(HERE, f)) for f in files}

    rc, first = selftest()
    print("clean tree: %s (rc=%d)" % (first, rc))
    if rc != 0:
        print("❌ the self-test is red before any mutation — fix that first")
        return 1

    escaped = []
    for label, name, old, new in MUTATIONS:
        path = os.path.join(HERE, name)
        if old not in snapshot[name]:
            print("  ✗ %-45s mutation pattern absent — this entry is a lie" % label)
            escaped.append(label)
            continue
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(snapshot[name].replace(old, new, 1))
        rc, first = selftest()
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(snapshot[name])
        caught = rc != 0
        if not caught:
            escaped.append(label)
        print("  %s %-45s self-test rc=%d  %s"
              % ("✅" if caught else "🚨", label, rc, "caught" if caught else
                 "ESCAPED — documented, not gated"))

    after = {f: sha(os.path.join(HERE, f)) for f in files}
    dirty = [f for f in files if before[f] != after[f]]
    if dirty:
        print("🚨 %s not restored (was %s, now %s)" % (", ".join(dirty),
                                                        before[dirty[0]], after[dirty[0]]))
        return 1
    rc, first = selftest()
    print("restored:   %s (rc=%d) · %d file(s) verified by checksum" % (first, rc, len(files)))
    if escaped:
        print("❌ %d mutation(s) escaped: %s" % (len(escaped), "; ".join(escaped)))
        return 1
    stale = ledgerdoc.readme_count_defects("mutations", len(MUTATIONS))
    for entry in stale:
        print("❌ %s" % entry)
    if stale:
        return 1
    print("✅ %d mutations, %d caught — every rule the loop's prose claims has something that goes red"
          % (len(MUTATIONS), len(MUTATIONS)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
