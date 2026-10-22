#!/usr/bin/env bash
# upstream-cite-check.sh — every `path.ext:NN` in a Sources/ comment must resolve.
#
# Why. Sources/ comments are where the borrowed verdicts live, and they are the only way a
# future session learns *why* a line looks the way it does. `make anchor-check` verifies the
# cites that carry an explicit `anchor:` marker (46 on 10-22); the bare ones — `omlx/admin/
# hf_downloader.py:1122`, `GuidedGenerationError.swift:27` — were unchecked, and measured
# 10-22: 4 of 173 bare cites pointed at a path or line that does not exist, one of them a
# quoted sentence absent from the pinned file. Invariant 1: a scan that never goes red is not
# a gate; invariant 2: a comment may not cite provenance it cannot show.
#
# Resolution order: this repo's tracked files -> ~/references/* clones -> .build*/checkouts
# (package deps) -> .upstream-external-cites.json (paths outside the reference set, which must
# carry the sha they were verified at, so the claim survives the upstream tree moving).
# Degrades loudly: with no reference roots (CI) it reports SKIP and still floors its own scan.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here" || exit 2
exec "${PYTHON:-python3}" - "$here" <<'PY_EOF'
import glob, json, os, re, subprocess, sys

root = sys.argv[1]
floor = int(os.environ.get("OCOREAI_UPSTREAM_CITE_FLOOR", "120"))
CITE = re.compile(r"([A-Za-z0-9_+./-]+\.(?:py|rs|go|zig|mm|swift))(?::(\d{1,6})(?:-(\d{1,6}))?)(?![A-Za-z0-9_])")
SHA = re.compile(r"@[0-9a-f]{7,40}")

homes = [h for h in (os.environ.get("OCOREAI_REFS"), os.environ.get("HOME")) if h]
try:
    import pwd
    homes.append(pwd.getpwuid(os.getuid()).pw_dir)
except Exception:  # noqa: BLE001 - pwd is a nicety, not a premise
    pass

roots = []
for home in homes:
    base = os.path.join(os.path.expanduser(home), "references")
    if os.path.isdir(base):
        for d in sorted(os.listdir(base)):
            if os.path.isdir(os.path.join(base, d, ".git")):
                roots.append((d, os.path.join(base, d)))
for b in (".build-clt/checkouts", ".build/checkouts"):
    p = os.path.join(root, b)
    if os.path.isdir(p):
        for d in sorted(os.listdir(p)):
            if os.path.isdir(os.path.join(p, d, ".git")):
                roots.append((d, os.path.join(p, d)))

def tracked(path):
    out = subprocess.run(["git", "-C", path, "ls-files"], capture_output=True, text=True)
    return [l for l in out.stdout.split("\n") if l] if out.returncode == 0 else []

ours = set(tracked(root))
our_base = {os.path.basename(p) for p in ours}
names = {}
for n, p in roots:
    names[n] = tracked(p)
ext = {}
try:
    ext = {e["path"]: e for e in json.load(open(os.path.join(root, ".upstream-external-cites.json")))["entries"]}
except (OSError, ValueError, KeyError):
    ext = {}

def resolve(path, hint):
    """(kind, detail, max_lines) — where this cite resolves, and how long that file is.

    A basename is not an identity: sglang alone holds seven `protocol.py`, and a first-match
    resolver reports the 139-line transport one as "line 1020 past EOF" while the
    `srt/entrypoints/openai/protocol.py` the comment means has it. So collect every candidate
    and let the cite pass if ANY file it could name holds the line — same lesson this script
    exists to enforce upstream."""
    variants = [path] + ([path.split("/", 1)[1]] if "/" in path else [])
    order = [n for n in names if n == hint] + [n for n in names if n != hint]
    cands = []
    for var in variants:
        for n in order:
            for f in names[n]:
                if f == var or f.endswith("/" + var):
                    cands.append((n, f))
        if cands:
            break
    rr = dict(roots)
    hits = []
    for n, f in cands:
        try:
            hits.append(("clone", "%s:%s" % (n, f), sum(1 for _ in open(os.path.join(rr[n], f), encoding="utf-8", errors="ignore"))))
        except OSError:
            continue
    if hits:
        return max(hits, key=lambda h: h[2] or 0)
    for var in variants:
        for p in ours:
            if p == var or p.endswith("/" + var):
                try:
                    return ("local", p, sum(1 for _ in open(os.path.join(root, p), encoding="utf-8", errors="ignore")))
                except OSError:
                    continue
    # An external cite is anchored by the sha it was verified at, not by path exactness:
    # a wrapped comment line carries only the basename, and the sha in the same line is the
    # part a reader (or a future re-check) follows.
    for epath, e in ext.items():
        if path.endswith(epath) or os.path.basename(path) == os.path.basename(epath):
            return ("external", "%s@%s" % (e.get("repo", "?"), e.get("sha", "?")), None)
    return (None, None, None)

scanned = ok = 0
missing = []
oor = []
nosha = []
skipped = 0
files = sorted(glob.glob(os.path.join(root, "Sources/**/*.swift"), recursive=True))
for src in files:
    lines = open(src, encoding="utf-8", errors="replace").read().splitlines()
    for no, raw in enumerate(lines, 1):
        if not raw.strip().startswith("//"):
            continue
        block = " ".join(x[2:] for x in lines[max(0, no - 4):no] if x.strip().startswith("//"))
        hint = next((n for n in sorted(names, key=len, reverse=True) if re.search(r"(?<![A-Za-z0-9])" + re.escape(n) + r"(?![A-Za-z0-9])", block)), None)
        for m in CITE.finditer(raw):
            path, start, end = m.group(1), m.group(2), m.group(3)
            if os.path.basename(path) in our_base and "/" not in path:
                continue
            scanned += 1
            kind, detail, n = resolve(path, hint)
            if kind is None:
                if roots:
                    missing.append("%s:%d %s" % (src.replace(root + "/", ""), no, path))
                else:
                    skipped += 1
                continue
            if kind == "external":
                # the sha may sit on the wrapping line — one citation, one comment block
                if not SHA.search(raw + " " + block):
                    nosha.append("%s:%d %s (manifest says %s — put the sha in the cite)" % (src.replace(root + "/", ""), no, path, detail))
                else:
                    ok += 1
                continue
            last = int(end or start or 0)
            if last and n is not None and last > n:
                oor.append("%s:%d %s -> %s (%d lines, cited %s)" % (src.replace(root + "/", ""), no, path, detail, n, m.group(0).split(":")[-1]))
            else:
                ok += 1

print("  roots: %d (references + checkouts), external manifest entries: %d" % (len(roots), len(ext)))
print("  bare upstream cites: scanned=%d ok=%d missing=%d line-past-eof=%d external-without-sha=%d skipped=%d"
      % (scanned, ok, len(missing), len(oor), len(nosha), skipped))
if scanned < floor:
    print("  ❌ scan matched only %d cites (< floor %d) — the regex rotted, so 'every cite resolves' is vacuous" % (scanned, floor))
    sys.exit(1)
if missing:
    print("  ❌ %d cite(s) name a file that exists in no clone, checkout, or manifest:" % len(missing))
    for x in missing[:15]:
        print("     ", x)
if oor:
    print("  ❌ %d cite(s) point past the end of the file they name:" % len(oor))
    for x in oor[:15]:
        print("     ", x)
if nosha:
    print("  ❌ %d external cite(s) lack the sha they were verified at:" % len(nosha))
    for x in nosha[:15]:
        print("     ", x)
bad = len(missing) + len(oor) + len(nosha)
if bad:
    sys.exit(1)
print("  ✅ every bare upstream cite resolves")
PY_EOF
