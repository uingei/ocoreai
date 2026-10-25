#!/usr/bin/env bash
# anchor-check.sh — verify every ANCHORED line cite in this repo's docs, code comments and
# the package manifest against the file it points at: the working tree for local files, the
# pinned revision for upstream ones. A cite written as bare prose (`File.swift:123`, no
# marker) carries no token, so its content cannot be checked here; those are counted and
# their beyond-EOF cases are failed (see the visibility block at the end).
#
# Why this exists. Line numbers are the most load-bearing and most fragile thing in
# AGENTS.md: the agent navigates by them, and they move under every edit and every bump.
# `make docs-check` can only ask whether a cite is inside the file (P3 = EOF), so a cite
# that lands 21 lines off reads as verified. Measured 10-17, in one pass: 15 cites in
# AGENTS.md / Engine AGENTS.md / closed-items-log / build-gate-reality pointed at the
# wrong line — ThinkingBudget `:4119` was 4146 (round 14 inserted ~27 lines above it),
# the steer drains `:2908`/`:3514` were 2933/`:3541`, `sample(from:)` :198 was 207,
# `print(report)` :31 was :38, the pin `Package.swift:41` was :43, upstream
# `KVCacheRuntime.swift:155` had become `KVCacheConfiguration.swift:486`, and a comment
# written the day before cited `ChatSession.swift:1131` for a line that is 1110 at the
# pin AND at the clone HEAD. AGENTS.md invariant 1: a claim is worth exactly the gate
# that goes red when it breaks.
#
# Marker syntax — one per line, legal in Markdown and in Swift comments:
#
#   <!-- anchor:<repo|.> <path>:<line>[-<end>] <token text> -->
#   // anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:1110 templateMessages
#
# `.` means this repo's working tree. For any other repo the revision is what this
# package resolves (Package.resolved pin, else Package.swift `revision:`), read with
# `git show` so the check does not care what that clone happens to have checked out.
#
# Degradation is loud, never silent: an unverifiable anchor prints SKIP with a reason, and
# every run prints `checked=N drift=D skip=S` against a floor on N
# (OCOREAI_ANCHOR_FLOOR, default 6) so a marker regex that stopped matching fails
# instead of passing vacuously.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here" || exit 2

exec "${PYTHON:-python3}" - "$here" "${1:-check}" <<'PY_EOF'
import glob, json, os, re, subprocess, sys

repo_root, mode = sys.argv[1], sys.argv[2]
floor = int(os.environ.get("OCOREAI_ANCHOR_FLOOR", "6"))

MARKER = re.compile(
    r"anchor:([A-Za-z0-9._+-]+)\s+([^\s:]+):(\d{1,6})(?:-(\d{1,6}))?\s+(.+?)\s*(?:-->)?\s*$"
)

# A line that *declares* an anchor (comment marker + repo + a file with a line number) but
# does not parse as MARKER. The shape test stays narrow on purpose — `SwiftUI`'s
# `proxy.scrollTo("bottom", anchor: .bottom)` and prose like "HEAD anchor: 54e6163" must not
# be mistaken for a declaration, and they are not: they neither follow a comment marker nor
# carry `path.ext:<digits>`.
DECLARED = re.compile(
    r"(?:<!--|//|#)\s*anchor:\s*\S+\s+\S+\.[A-Za-z0-9]+\s*:\s*\d"
)

# The docs the agent reads, plus the source comments that cite upstream while being edited
# (that is where the wrong 1131 lived).
SOURCES = (
    # The manifest is a document too: its comments state which pin the project depends on
    # and which two lines of this repo consume it. Measured 10-20: the comment said "pin to
    # the 0.32.2 tag" while the pin read exact 0.32.3 (bumped in 0401256), and its two
    # consumer cites were 214 and 124 lines off. Nothing read this file.
    ["AGENTS.md", "ARCHITECTURE.md", "README.md", "README.zh.md", "Package.swift"]
    + sorted(glob.glob("docs/agent/*.md"))
    + sorted(glob.glob("Sources/**/AGENTS.md", recursive=True))
    + sorted(glob.glob("Sources/**/*.swift", recursive=True))
)


def read(path):
    try:
        import io
        return io.open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def git(tree, *args):
    out = subprocess.run(["git", "-C", tree, *args], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


# ── pins: what this package resolves, not what a clone happens to have checked out ──
pins = {}
for cand in ("Package.resolved",
             ".swiftpm/configuration/Package.resolved",
             *glob.glob("*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
             *glob.glob("*.xcworkspace/xcshareddata/swiftpm/Package.resolved")):
    if not os.path.exists(cand):
        continue
    try:
        data = json.load(open(cand, encoding="utf-8"))
    except (OSError, ValueError):
        continue
    for pin in data.get("pins", []):
        rev = (pin.get("state") or {}).get("revision")
        if not rev:
            continue
        ident = str(pin.get("identity") or "").strip()
        if ident:
            pins.setdefault(os.path.basename(ident.rstrip("/")), rev)
        loc = str(pin.get("location", "")).rstrip("/")
        if loc.endswith(".git"):
            pins.setdefault(os.path.basename(loc[:-4]), rev)

manifest = read("Package.swift")
for m in re.finditer(r'([A-Za-z0-9._-]+)\.git"\s*,\s*(?:revision|branch):\s*"([0-9a-zA-Z._/-]+)"', manifest):
    pins.setdefault(m.group(1), m.group(2))

# Home comes from the passwd entry as well as $HOME: the documented CLT/sandbox recipe
# exports HOME to a writable scratch dir, and a gate that locates the reference trees via
# $HOME alone cries wolf under that recipe — and a warning that fires for the wrong reason
# every run is a warning nobody reads when it becomes true.
homes = [h for h in (os.environ.get("OCOREAI_REFS"), os.environ.get("HOME")) if h]
try:
    import pwd
    homes.append(pwd.getpwuid(os.getuid()).pw_dir)
except Exception:  # noqa: BLE001 - pwd is a nicety, not a premise
    pass


def trees(name):
    out = []
    for base in (".build-clt/checkouts", ".build/checkouts"):
        out.append(os.path.join(repo_root, base, name))
    for home in homes:
        out.append(os.path.join(os.path.expanduser(home), "references", name))
        out.append(os.path.join(os.path.expanduser(home), name))
    return out


def resolve(name):
    """(dir, revision, how) — the tree to read `name` from, and why."""
    if name == ".":
        return repo_root, "WORKTREE", "working tree"
    want = pins.get(name)
    fallback = None
    for tree in trees(name):
        if not os.path.isdir(os.path.join(tree, ".git")):
            continue
        head = git(tree, "rev-parse", "HEAD")
        if want and head and (head.startswith(want) or want.startswith(head[:7])):
            return tree, want, "pin==HEAD"
        if want and git(tree, "cat-file", "-e", "%s^{commit}" % want):
            return tree, want, "shown at pin, HEAD=%s" % (head or "?")[:9]
        if fallback is None and head:
            fallback = (tree, "HEAD", "UNPINNED (Package.swift/Package.resolved name no %s)" % name)
    return fallback or (None, None, "no local tree for %s" % name)


cache = {}


def lines_at(tree, rev, path):
    key = (tree, rev, path)
    if key not in cache:
        if rev == "WORKTREE":
            blob = read(path) if tree == repo_root else None
            cache[key] = blob.splitlines() if blob is not None else None
        else:
            blob = git(tree, "show", "%s:%s" % (rev, path))
            cache[key] = blob.splitlines() if blob is not None else None
    return cache[key]


checked = drift = skipped = 0
local_checked = upstream_checked = upstream_skipped = 0
unparsed = []
notes = []
for src in SOURCES:
    for no, raw in enumerate(read(src).splitlines(), 1):
        m = MARKER.search(raw)
        if not m:
            # A line that says `anchor:` but does not parse is not "no anchor" — it is an
            # anchor that silently stopped being checked. Measured 10-20 (same session that
            # wrote this): a re-pin script mangled five markers into
            # `MLXBridge.swift:12141206`, `checked` fell 37 -> 32, drift stayed 0, and the
            # only thing that noticed was a human reading the OK line. The floor on N catches
            # a regex that dies wholesale; this catches one marker at a time.
            if DECLARED.search(raw):
                unparsed.append("%s:%d %s" % (src, no, raw.strip()[:90]))
            continue
        name, path, start, end, token = m.groups()
        start, end = int(start), int(end or 0) or int(start)
        tree, rev, how = resolve(name)
        if not tree:
            skipped += 1
            if name != ".":
                upstream_skipped += 1
            notes.append("SKIP %s %s:%d (%s)" % (src, path, start, how))
            continue
        body = lines_at(tree, rev, path)
        if body is None:
            skipped += 1
            if name != ".":
                upstream_skipped += 1
            notes.append("SKIP %s %s: no such file in %s @%s" % (src, path, name, rev[:9]))
            continue
        token_norm = " ".join(token.split())
        window = " ".join(" ".join(body[start - 1:min(end, len(body))]).split())
        if token_norm.lower() in window.lower():
            checked += 1
            if name == ".":
                local_checked += 1
            else:
                upstream_checked += 1
            notes.append("OK   %s:%d-%d %s@%s [%s]"
                        % (path, start, end, token_norm[:40], rev[:9], how))
            continue
        matches = [i for i, l in enumerate(body, 1)
                   if token_norm.lower() in " ".join(l.split()).lower()]
        drift += 1
        if not matches:
            where = "token absent in a %d-line file" % len(body)
        elif len(matches) == 1:
            where = "really line %d of %d" % (matches[0], len(body))
        else:
            shown = ", ".join(str(m) for m in matches[:4])
            where = ("token appears at line(s) %s%s of %d \u2014 the cite names none of them, "
                     "or the range needs tightening"
                     % (shown, ",+%d more" % (len(matches) - 4) if len(matches) > 4 else "", len(body)))
        notes.append("DRIFT %s:%d %s -> %s:%s %s" % (src, start, token_norm[:40], path,
                                                     ("(%s in %s)" % (name, tree.split("/")[-1])) if name != "." else "", where))

if unparsed:
    print("  UNPARSED %d marker(s) declared `anchor:` but did not parse — they are NOT checked:"
          % len(unparsed))
    for u in unparsed:
        print("    " + u)
    drift += len(unparsed)

for line in notes:
    print("  " + line)
print("  anchors: checked=%d (local=%d, upstream=%d) drift=%d skip=%d  upstream-skipped=%d"
      % (checked, local_checked, upstream_checked, drift, skipped, upstream_skipped))
print("  floor: local>=%d  (upstream anchors only verify where a local tree exists: CI without a "
      "resolved checkout reports them as skipped, and the leg that builds must run this)" % floor)
print("  upstream pins: %s" % ", ".join("%s=%s" % (k, v[:9]) for k, v in sorted(pins.items())
                                        if k in ("mlx-swift-lm", "mlx-swift")))

# ── prose cites: count them, and fail only what is decidable ─────────────────
# A bare `File.swift:123` in prose has no token, so content cannot be verified here.
# Measured 10-25: an edit moved the only `.fork(` site; the marker beside it went red and
# the sentence next to it kept saying `EngineInference.swift:3139`. So the count goes on
# the record, and the one thing that IS provable about a bare cite — a line number past the
# end of its file — fails like P3 does for markers. Nothing else is gated: a ceiling here
# would push prose into markers for shape rather than for meaning.
# Floor on the scan itself, not on the style: measured 10-25 at 296 cites over 317 files.
prose_floor = int(os.environ.get("OCOREAI_PROSE_CITE_FLOOR", "150"))
PROSE_CITE = re.compile(
    r"([A-Za-z0-9_./+-]+\.(?:swift|md|py|rs|yaml|yml|toml)):(\d{1,6})")
prose_total = 0
prose_beyond: list = []
line_counts: dict = {}
for src in SOURCES:
    body = read(src)
    if not body:
        continue
    for no, ln in enumerate(body.split("\n"), 1):
        if MARKER.search(ln) or DECLARED.search(ln):
            continue
        for m in PROSE_CITE.finditer(ln):
            prose_total += 1
            tgt = m.group(1)
            if tgt.startswith("./"):
                tgt = tgt[2:]
            if not os.path.exists(tgt):
                tgt = os.path.join(repo_root, tgt)
                if not os.path.exists(tgt):
                    continue
            if tgt not in line_counts:
                line_counts[tgt] = len(read(tgt).split("\n"))
            if int(m.group(2)) > line_counts[tgt]:
                prose_beyond.append("%s:%d cites %s:%s, past its %d lines"
                                   % (src, no, m.group(1), m.group(2), line_counts[tgt]))

print("  prose cites (no marker, content unverifiable): %d across %d scanned file(s);"
      " beyond-EOF checked=%d  floor>=%d"
      % (prose_total, len(SOURCES), len(line_counts), prose_floor))
if prose_total < prose_floor:
    print("FAIL the prose-cite scan found only %d cite(s) (< %d) — the regex stopped "
          "matching, so 'the unverified set is this big' became a vacuous reassurance "
          "(invariant 1)" % (prose_total, prose_floor))
    drift += 1
for b in prose_beyond:
    print("  PROSE-DRIFT " + b)
    drift += 1

if mode == "print-pin":
    for k, v in sorted(pins.items()):
        print("%s %s" % (k, v))
    sys.exit(0)

if drift:
    print("FAIL %d anchor(s) do not point where the doc says they do. Fix the cite, or "
          "fix the code comment: a cite that moved is a stale claim, never a free pass." % drift)
    sys.exit(1)
# The floor is on LOCAL anchors: those are checkable on every leg, so a marker regex that
# stopped matching fails here even on a runner with no upstream clone. Upstream coverage is
# reported separately and enforced by the legs that build (they resolve the pin).
if local_checked < floor:
    print("FAIL only %d local anchors verified (< floor %d) — the marker regex stopped "
          "matching; a gate that cannot see its own input is vacuous." % (local_checked, floor))
    sys.exit(1)
if skipped:
    print("WARN %d anchor(s) unverifiable on this host (%d upstream: no local tree / revision "
          "absent) — run this on a leg that resolved the pin for full coverage."
          % (skipped, upstream_skipped))
print("OK all %d anchor(s) point at the code they claim." % checked)
PY_EOF
