#!/usr/bin/env bash
# unreferenced-decls.sh — how many declarations in Sources/ nothing in the tree names?
#
# ### Why this exists (10-29, entry 53)
# A round that deletes 770 unreferenced lines is worthless if the number grows back, and "no line is
# gratuitous" is the kind of sentence that rots silently in a README. So the count is measured and
# floored: `AGENTS.md` carries `<!-- claim:unreferenced_decls_ours<=N -->`, re-run by `make docs-check`
# on this host and by `Text gates (ubuntu)` — the sampled red is the 770 lines this scan found.
#
# ### What counts as a reference
# A name occurs in the INDEX, which is every tracked file minus comments. A reference is a CALLER, not
# a sentence, and that holds for every file type, not just Markdown: entry 54 skipped `*.md` after this
# script's own header comment retired two names from its result (10-29, entry 56 sampled the same trick
# in `scripts/*.sh` — `*.md` was the half-measure, comments were the whole thing).
#
# ### Two buckets, because the author differs
# Files whose header carries Apple's copyright are absorbed upstream source (BSD-3, see
# `docs/agent/third-party-notices.md`): their dead members are upstream's shape, and deleting them buys
# a worse bump diff on the next `coreai-models` sync. So the verdict number is OURS, and `vendored=` is
# printed beside it rather than hidden. Vendored names are not free: they are a `file:line` read at each
# upstream bump, which is where the consumer either shows up or does not.
#
# ### What it still cannot see
# A witness to an *external* protocol lives in the SDK, not in the tree, so the compiler cannot catch a
# deletion here either. `EXEMPT` below names each such declaration with the framework that calls it, and
# a stale exemption is an error: an exemption for a name that is not currently a hit is dead weight in
# the gate itself.
#
# Exit 0 on a counted tree: the verdict belongs to the claim's direction, not to this script.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

python3 - <<'PY'
import os, re, subprocess, collections, sys

TRACKED = [p for p in subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.split("\n")
           if p and os.path.isfile(p)]
WORD = re.compile(r"[A-Za-z_]\w*")
MAX_BYTES = 4_000_000  # a vendored blob is not a reference site, and reading it is not the gate's job
APPLE_HEADER = "Copyright 2026 Apple"

# Comment shapes are language-specific, and a wrong rule here is worse than no rule: `#` leads a comment
# in shell, Python and YAML, and is CODE in Swift (`#expect`, `#selector`, `#if`) — one shared rule ate
# every `#expect(await pool.isModelLoading(id))` line and reported a live method as dead, which is the
# scan lying in the direction that deletes working code. The wire formats have no comments at all, so a
# name in `openapi.json` or a probe's expected JSON stays a witness (a client reads it).
HASH_COMMENT_LANGS = {".sh", ".bash", ".zsh", ".py", ".yml", ".yaml", ".toml", ".rb"}
COMMENT_C = re.compile(r"^\s*(?://|/\*|\*|<!--|\{%)")
COMMENT_HASH = re.compile(r"^\s*(?://|#|/\*|\*|<!--)")
TAIL_C = re.compile(r"//.*$")
TAIL_HASH = re.compile(r"(?<!:)\s#.*$")
# Framework callbacks: the only witness is an Objective-C selector the SDK sends, so neither this index
# nor the compiler can name it. Keep this list one line per name, with the framework in the reason.
EXEMPT = {
    "photoOutput": "AVCapturePhotoCaptureDelegate — AVFoundation sends didFinishProcessingPhoto by selector",
}

SELF = "scripts/unreferenced-decls.sh"
counts = collections.Counter()
for p in TRACKED:
    if p.endswith(".md") or p == SELF:
        # `*.md` is prose; and the gate's own source holds EXEMPT, whose keys are the names they
        # exempt — a table that retires the thing it is written about is not a reference site.
        continue
    ext = os.path.splitext(p)[1]
    hashed = ext in HASH_COMMENT_LANGS
    comment = COMMENT_HASH if hashed else COMMENT_C
    tail = (TAIL_HASH if hashed else TAIL_C) if ext in HASH_COMMENT_LANGS | {".swift"} else None
    try:
        if os.path.getsize(p) > MAX_BYTES:
            continue
        text = open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    kept = []
    for line in text.split("\n"):
        if comment.match(line):
            continue
        kept.append(tail.sub("", line) if tail else line)
    counts.update(WORD.findall("\n".join(kept)))

DECL = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public|internal|private|fileprivate)?\s*"
                  r"(?:static\s+|final\s+|class\s+|override\s+|mutating\s+|nonisolated\s+|indirect\s+)*"
                  r"(?:func|struct|enum|protocol|actor|typealias)\s+([A-Za-z_]\w*)")
DELEGATE_HINT = re.compile(r"@objc|NSObject|Delegate|SCStream|AVCapture|canImport\(CoreAI\)")
VERBOSE = os.environ.get("OCOREAI_DEAD_VERBOSE", "").lower() in ("1", "true", "yes")

ours, vendored, hit_names = [], [], set()
for p in TRACKED:
    if not p.startswith("Sources/") or not p.endswith(".swift"):
        continue
    try:
        lines = open(p, encoding="utf-8", errors="replace").read().split("\n")
    except OSError:
        continue
    blob = "\n".join(lines)
    upstream = any(APPLE_HEADER in l for l in lines[:10])
    maybe_witness = bool(DELEGATE_HINT.search(blob))
    for i, l in enumerate(lines, start=1):
        m = DECL.match(l)
        if not m:
            continue
        name = m.group(1)
        if name in ("init", "deinit"):
            continue
        if counts[name] > 1:
            continue
        if name in EXEMPT:
            hit_names.add(name)
            continue
        hit_names.add(name)
        (vendored if upstream else ours).append((name, p, i, maybe_witness))

stale = [n for n in EXEMPT if n not in hit_names]
if stale:
    print("stale exemption(s) — the name is not dead any more, so the exemption is: %s"
          % ", ".join(sorted(stale)), file=sys.stderr)
    raise SystemExit(1)

if VERBOSE:
    for label, bucket in (("ours", ours), ("vendored (Apple header)", vendored)):
        print("  ── %s: %d" % (label, len(bucket)))
        for name, path, line, w in sorted(bucket, key=lambda x: (x[1], x[2])):
            print("  %-28s %s:%d%s" % (name, path, line, "  [external-witness suspect]" if w else ""))
    print("  exempt (framework witness): %d" % len(EXEMPT))
print(len(ours))
PY
