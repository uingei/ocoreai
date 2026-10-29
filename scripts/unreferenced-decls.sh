#!/usr/bin/env bash
# unreferenced-decls.sh — how many declarations in Sources/ nothing in the tree names?
#
# ### Why this exists (10-29, entry 53)
# A round that deletes 770 unreferenced lines is worthless if the number grows back, and "no line is
# gratuitous" is the kind of sentence that rots silently in a README. So the count is measured and
# floored: `AGENTS.md` carries `<!-- claim:unreferenced_decls<=N -->`, re-run by `make docs-check`
# on this host and by `Text gates (ubuntu)` — the sampled red is the 770 lines this scan found.
#
# ### What counts, and what it cannot see
# A top-level or member `func|struct|enum|protocol|actor|typealias` in `Sources/**.swift` whose name
# occurs exactly ONCE among the tracked NON-`\.md` files — at its own declaration. Text-only, from
# the same answer on any host, with or without a resolved `.build`, with or without `~/references`
# (10-29 learned that a claim reading host state is a claim that goes red on a runner for a reason
# nobody can see). So it cannot see a witness to an *external* protocol — the requirement lives in
# the SDK, not in the tree — and those appear here as false positives: delegate conformance
# (`photoOutput`, `streamDidBecomeActive`), and the `@available(macOS 27)` CoreAI/Video paths that
# a source-only checkout cannot judge. Each one is a name to read, not a licence to grow the number.
#
# Exit 0 always: the verdict belongs to the claim's direction, not to this script.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

python3 - <<'PY'
import os, re, subprocess, collections

TRACKED = [p for p in subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.split("\n")
           if p and os.path.isfile(p)]
WORD = re.compile(r"[A-Za-z_]\w*")
MAX_BYTES = 4_000_000  # a vendored blob is not a reference site, and reading it is not the gate's job

# A reference is a CALLER, not a sentence: prose is excluded from the index, because naming a dead
# name in `CHANGELOG.md` would otherwise retire it from this count (sampled 10-29 — entry 53 named
# `photoOutput` and `streamDidBecomeActive`, and the count fell 24 → 22 with no code deleted).
counts = collections.Counter()
for p in TRACKED:
    if p.endswith(".md"):
        continue
    try:
        if os.path.getsize(p) > MAX_BYTES:
            continue
        text = open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    counts.update(WORD.findall(text))

DECL = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public|internal|private|fileprivate)?\s*"
                  r"(?:static\s+|final\s+|class\s+|override\s+|mutating\s+|nonisolated\s+|indirect\s+)*"
                  r"(?:func|struct|enum|protocol|actor|typealias)\s+([A-Za-z_]\w*)")
DELEGATE_HINT = re.compile(r"@objc|NSObject|Delegate|SCStream|AVCapture|canImport\(CoreAI\)")

dead, hint = [], 0
for p in TRACKED:
    if not p.startswith("Sources/") or not p.endswith(".swift"):
        continue
    try:
        lines = open(p, encoding="utf-8", errors="replace").read().split("\n")
    except OSError:
        continue
    blob = "\n".join(lines)
    maybe_witness = bool(DELEGATE_HINT.search(blob))
    for i, l in enumerate(lines, start=1):
        m = DECL.match(l)
        if not m:
            continue
        name = m.group(1)
        if name in ("init", "deinit"):
            continue
        if counts[name] <= 1:
            dead.append((name, p, i, maybe_witness))
            hint += 1 if maybe_witness else 0

if os.environ.get("OCOREAI_DEAD_VERBOSE", "").lower() in ("1", "true", "yes"):
    for name, path, line, w in sorted(dead, key=lambda x: (x[1], x[2])):
        print("  %-28s %s:%d%s" % (name, path, line, "  [external-witness suspect]" if w else ""))
print(len(dead))
PY
