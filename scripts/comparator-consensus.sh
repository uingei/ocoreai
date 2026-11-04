#!/usr/bin/env bash
# comparator-consensus.sh — what the field agrees on, counted off the local mirrors; plus where it is
# moving.
#
# Prints, per axis, the trees that show the mechanism and the count, then a trend block (cadence, tags
# minted, and which concepts the field is editing *this quarter* rather than merely carrying). It is
# ADVISORY: it exits 0 and judges nothing, because a cross-tree count is a direction input, not a
# verdict about us (root § Working here: "counts printed carry no verdict"). What it does floor is
# itself — an axis whose column is all zeros prints DEAD, and a pattern that the regex engine cannot
# honour refuses to run at all (§ the lint below).
#
# Instrument honesty, stated once here instead of per axis in the prose:
#   PATH   the mechanism has to be a committed file a reader can open
#   CODE   a hit must land in a source file, so a CHANGELOG that merely mentions a word cannot pass
#   README a stranger-facing install claim, judged only on the root README (a localized mirror, a
#          docs/ page or a workflow's brew line is not the first screen a stranger reads)
#   GIT    measured from the clone (tags)
# Absence here means the instrument found nothing; it does not prove the mechanism is missing (a
# Swift idiom a JS-shaped pattern cannot see is exactly that case — check the tree before quoting).
#
# THE PATTERN LINT, and why it is in a script that gates nothing. Every CODE/README pattern below is
# handed to `git grep -E`, whose engine is POSIX ERE — where \b \w \s \d and every lookaround are
# undefined and quietly match nothing. Two of those landed here: `\.dmg\b` scored our own DMG route as
# absent, and `\bmd5\b` silently dropped md5 from the digest axis, while both axes still printed a
# confident non-zero count because their other alternatives matched. That is root invariant 1 with the
# volume turned down: a scan that stopped matching, reporting as if it were scanning. So the escapes
# are refused at startup, by name, before any tree is read.
#
# usage: scripts/comparator-consensus.sh [parent-dir-of-references]   # default ~/references
#        OC_AXES="substring,…"      re-run one axis after a correction, without paying for the sweep
#        OC_TREND_DAYS=60           the "moving now" window for the trend block
#        OC_NO_TREND=1              skip the trend block (HEAD-presence axes only)
#        OC_EVIDENCE=1              print one matched file:line per in-segment tree
#
# Why OC_EVIDENCE exists: every count below is a candidate list, and this instrument has twice turned a
# count into a false claim by matching the right word in the wrong role (`job.?object` in a Windows
# kill-on-close path read as "this harness sandboxes its shell"; the word `.dmg` anywhere in a README
# read as "a package-manager route"). The count cannot tell you which; one line per tree can, and the
# reader should not have to re-run 28 git greps by hand to look.
set -uo pipefail

PARENT="${1:-$HOME/references}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OC_PARENT="$PARENT" OC_REPO="$REPO"
export OC_AXES="${OC_AXES:-}" OC_TREND_DAYS="${OC_TREND_DAYS:-60}" OC_NO_TREND="${OC_NO_TREND:-}"
export OC_EVIDENCE="${OC_EVIDENCE:-}"

# -u: this sweep reads ~28 mirrors over ~30 axes and takes minutes. Block-buffered stdout meant a
# running instrument looked dead, and a reader who cannot watch an instrument either kills it or
# starts a second one.
python3 -u - <<'PY'
import os, re, subprocess, time

parent, repo = os.environ["OC_PARENT"], os.environ["OC_REPO"]
trend_days = int(os.environ["OC_TREND_DAYS"])
trees = sorted(d for d in os.listdir(parent) if os.path.isdir(os.path.join(parent, d)))
# Scored against the same patterns, once: pointing the instrument at a scratch parent that already
# holds an ocoreai (a symlink, say) used to score us twice and print the same row twice.
if "ocoreai" not in trees:
    trees.append("ocoreai")

# Shape segments, declared as data because a denominator is a claim. A row that is not in a segment is
# still measured; it just never owes that axis's denominator.
SEG = {
    "serve": ["vllm", "sglang", "ollama", "omlx", "mlx-serve", "splash", "ocoreai"],
    "agent": ["hermes-agent", "openclaw", "codex", "claude-code", "qwen-code", "opencode",
              "goose", "pi", "cline", "deepseek-harness", "harness2", "Strata", "OpenHands", "ocoreai"],
    # Ships something a stranger installs or runs: everything except the trees that are a model's
    # README, a benchmark for other people's code, or a pin we compile rather than distribute.
    "shippable": [t for t in trees if t not in
                  {"Qwen3.8", "Qwen3.8-Flash-Next", "SWE-bench", "mlx-swift-lm", "coreai-models"}],
}
CODE = r"\.(py|ts|tsx|js|jsx|go|rs|swift|kt|java|zig|c|cpp|hpp|m|mm|rb|dart|scala)$"
ROOT_README = r"^README\.(md|rst|markdown)$"
DL = (r"(^|/)(download|models?|blob|cache|weights?|image|hub|installer|snapshot|artifact)(s)?(/|$)"
      r"|download[-_a-z0-9]*\.(py|ts|go|rs|swift)|model[-_a-z0-9]*\.(py|go|rs|ts|swift)|images\.go"
      r"|IntegrityDigest|checksums?\.(txt|json)$")

# Install routes, three separate questions, because conflating them is how a doc tells itself a story.
# (a) a stranger can *type* it: a command-shaped package-manager line in the root README. Command-shaped
#     means a command position (line start, after a backtick or a `$ `), not the phrase anywhere in prose
#     — "Homebrew's `brew install opencode` formula currently installs V2" is a warning, not a route.
# (b) a store carries it: decided by the store's own URL or an obtain-verb, never by the words "App
#     Store" in a caveat (our README says "an App Store build installed from the DMG …", which is a
#     build fact, not a shelf a stranger can reach).
# (c) a built artefact: fetch it and open it.
CMD_POS = r"(^|[ `\$_]| {2,})(brew (install|tap)|npm (i|install) -g|npx [a-z@]|pnpm add -g|yarn global add" \
          r"|pipx install|uv tool install|cargo install|go install|flatpak install|snap install|yay -S)"
STORE = (r"apps\.apple\.com|marketplace\.visualstudio\.com|plugins\.jetbrains\.com|open-vsx\.org"
         r"|flathub\.org|snapcraft\.io|microsoft\.com/store|(get|download|available|search|install)"
         r"[^.\n|]{0,30}(the )?(app store|marketplace)")
# `\.dmg\b` is the bug this file's lint exists for: ERE eats the anchor, so the axis reported our own
# release artefact as absent for a whole round.
ARTIFACT = (r"curl [^|]*\| *(ba)?sh|curl -fsSL|install\.(sh|ps1)|releases/download"
            r"|\.dmg($|[^a-z0-9])|\.msi($|[^a-z0-9])|\.pkg($|[^a-z0-9])")

AXES = [
    # name, kind, segment, pattern, path-filter, trended?
    ("release tags (GIT count)",        "GIT",    "shippable", None, None, False),
    ("typed install command (README)",  "README", "shippable", CMD_POS, ROOT_README, False),
    ("store route (README)",            "README", "shippable", STORE, ROOT_README, False),
    ("artefact route (README)",         "README", "shippable", ARTIFACT, ROOT_README, False),
    ("ANY install route (README)",      "README", "shippable",
     CMD_POS + "|" + STORE + "|" + ARTIFACT, ROOT_README, False),
    ("committed HTTP contract",         "PATH",   "serve",     r"(^|/)openapi[^/]*\.(json|ya?ml)$|swagger\.json", None, False),
    # A directory named sdk/client/codegen is only a published client if it is a PACKAGE — a manifest or
    # a README sitting in it, at any nesting (a monorepo puts them at sdk/packages/x/package.json, which
    # the one-level form missed, so cline's six published packages scored as nothing). Without the
    # package half, any internal folder called Client/ counts, which is exactly how our own in-process
    # DirectInferenceClient once scored as a published SDK.
    ("published client package",        "PATH",   "serve",
     r"(^|/)(sdk|client|api-client|httpapi-codegen|[a-z-]*api-codegen|[a-z-]*-sdk)(/[^/]+)*/"
     r"(package\.json|pyproject\.toml|Cargo\.toml|setup\.py|Package\.swift|README\.md)$", None, False),
    ("third-party notice manifest",     "PATH",   "shippable",
     r"THIRD.?PARTY|NOTICE(\.txt|\.md|\.json)$|\.vendored-(from|patches)|(^|/)licenses/|spdx", None, False),
    ("asset -> digest provenance",      "PATH",   "shippable",
     r"ASSETS\.json|checksums?\.(txt|json|sha256)$|SHA256SUMS|\.sha256$|lockfiles?/|\.lock$|CARGO\.LOCK|Package\.resolved", None, False),
    ("live-probe / smoke scripts",      "PATH",   "shippable", r"(^|/)(probes?|smoke)(/|-)|probe[0-9_]|smoke[-_]", None, False),
    ("SKILL.md files (count)",          "COUNT",  "agent",     r"(^|/)skills?/.*SKILL\.md$", None, False),
    ("evals / benchmark tree",          "PATH",   "shippable", r"(^|/)(evals?|benchmarks?|scripts/eval)(/|$)", None, False),
    ("reads a project rules file (code)","CODE",  "agent",     r"AGENTS\.md|CLAUDE\.md|\.cursorrules|\.clinerules|GEMINI\.md|QWEN\.md", CODE, True),
    ("names AGENTS.md specifically",    "CODE",   "agent",     r"AGENTS\.md", CODE, True),
    ("rules verified in a download module","CODE","serve",
     # The md5 alternative used to read `\bmd5\b`: undefined in ERE, so it matched nothing while the
     # axis still printed 7/7 off sha256. Same shape, ERE-safe.
     r"sha256|sha512|checksum|verifyHash|hashlib|(^|[^a-z0-9])md5([^a-z0-9]|$)", DL, False),
    ("deferred / filtered tool surface","CODE",   "agent",
     r"tool_search|deferred.?tool|lazy[-_ ]?tool|list_functions|get_function_details|search_tools"
     r"|discover_tools|filterTools|toolFilter", CODE, True),
    ("MCP client/server (code)",        "CODE",   "agent",
     r"(^|[^a-z0-9])mcp([^a-z0-9]|$)|modelcontextprotocol", CODE, True),
    # Confinement, i.e. a profile the child cannot step outside. The first version of this axis also
    # accepted `job.?object`, `appcontainer` and bare `seccomp`, and reported 8/14 agent trees as
    # sandboxing. Read the matched lines (OC_EVIDENCE=1) and goose's was CreateJobObjectW — kill the
    # process tree on close, not a sandbox (`crates/goose/src/agents/platform_extensions/developer/
    # shell_process.rs:100`); pi's was a comment about EACCES under someone else's seccomp policy
    # (`packages/tui/src/terminal.ts:51`); vllm's and sglang's were container-environment notes. What
    # survives is the honest minority, and it is the trees that run *other people's* code that hold it.
    ("OS confinement profile for the child (code)", "CODE", "agent",
     r"(^|[^a-z0-9])(sandbox-exec|seatbelt|sandbox[-_]profile|bubblewrap|firejail|landlock"
     r"|createRestrictedToken)", CODE, True),
    # Does a *serving* tree ship the harness-side wiring — the config that points somebody else's
    # coding agent at this endpoint? Segment serve on purpose: it is the serve/agent seam, and it is
    # the rung root § Adoption says to spend on ("a harness consuming us"). Scored on all source, so a
    # tree's example script counts as present; the read of which hit is product code lives in
    # comparator-consensus.md, not here.
    ("wires a third-party coding agent to itself (code)", "CODE", "serve",
     r"ANTHROPIC_BASE_URL|OPENAI_BASE_URL|OPENAI_API_BASE|CLAUDE_CODE_|claude[-_]code"
     r"|codex[-_](config|app[-_]server)", CODE, True),
    ("subagents / multi-agent (code)",  "CODE",   "agent",
     r"subagent|sub_agent|subAgent|spawn_agent|spawnAgent|agent_tool|Task tool|teammate|multi.?agent"
     r"|orchestrator|swarm", CODE, True),
    ("tool/hook events (code)",         "CODE",   "agent",
     r"pre[-_]?tool[-_]?use|post[-_]?tool[-_]?use|hookEvent|hook_event|on_tool_call|pretooluse"
     r"|permissions?\.json|settings\.json", CODE, True),
    ("speculative decoding / MTP (code)","CODE",  "serve",
     r"speculative|draft[-_]?model|draftModel|num_speculative|multi[-_]?token[-_]?predict"
     r"|typical_acceptance|self[-_]?draft", CODE, True),
    ("prefix / KV cache reuse (code)",  "CODE",   "serve",
     r"prefix[-_ ]?cach|kv[-_ ]?cache|kvCache|cache[-_ ]?salt|prompt[-_ ]?cach|prefixReuse"
     r"|resume.?kv|cached[-_ ]?tokens", CODE, True),
    ("auto-update path (code)",         "CODE",   "shippable",
     r"sparkle|appcast|auto[-_ ]?update|self[-_ ]?update|UpdateCheck|updateAvailable|newVersionAvailable", CODE, False),
    ("cancellation (code, 6 idioms)",   "CODE",   "shippable",
     r"AbortSignal|CancellationToken|cancel_token|abortSignal|abortHandle|cancelGeneration"
     r"|interruptTurn|isCancelled|withTaskCancellationHandler|shouldStop|stop_generation", CODE, False),
    ("session rewind / fork / compaction","CODE", "agent",
     r"rewind|fork_session|forkSession|undoLast|branchConversation|compaction|compact_history"
     r"|compressHistory|summariz(e|ation).*history", CODE, False),
    ("reasoning-effort knob (code)",    "CODE",   "serve",
     r"reasoning_effort|reasoningEffort|thinking_budget|preserve_thinking|thinking_token", CODE, False),
    ("stall / turn limit (code)",       "CODE",   "agent",
     r"maxTurns|max_turns|maxIterations|max_iterations|turn.?limit|stall(ed|ing|Timeout)|idle.?timeout", CODE, False),
    ("empty-suite refusal named",       "CODE",   "shippable",
     r"vacuous|no tests ran|zero tests|ran 0 tests|empty suite|SUITE_RAN|runcount", None, False),
    ("screen capture (code)",           "CODE",   "agent",
     r"ScreenCaptureKit|CGWindowList|CGDisplayStream|computer[-_ ]use|cua-driver|screen[-_ ]capture", CODE, True),
]

# ── the lint described in the header: refuse a pattern git grep's engine cannot honour ──────────
BAD_ESCAPE = re.compile(r"\\b|\\B|\\w|\\W|\\s|\\S|\\d|\\D|\\A|\\Z|\(\?=|\(\?<!|\(\?<!|\(\?<")
broken = []
for a in AXES:
    if a[3] and BAD_ESCAPE.search(a[3]):
        bad = sorted({m.group(0) for m in BAD_ESCAPE.finditer(a[3])})
        broken.append("%s uses %s" % (a[0], " ".join(bad)))
if broken:
    raise SystemExit("AXIS-PATTERN-INVALID (POSIX ERE leaves these undefined, so they match nothing):\n  "
                     + "\n  ".join(broken))

# OC_AXES="substring,substring" re-runs one axis after a correction without paying for the whole sweep.
_only = [k.strip().lower() for k in os.environ.get("OC_AXES", "").split(",") if k.strip()]
if _only:
    AXES = [a for a in AXES if any(k in a[0].lower() for k in _only)]
    if not AXES:
        raise SystemExit("OC_AXES matched no axis")


def sh(cwd, args):
    try:
        return subprocess.run(["git", "-C", cwd] + args, capture_output=True, text=True,
                              timeout=240).stdout
    except Exception:
        return ""


def where(tree):
    return repo if tree == "ocoreai" else os.path.join(parent, tree)


# Pathspec pruning: a git pathspec skips a file before its bytes are read, while the Python filter
# below still decides the hit. It has to stay a superset of every filter it fronts — the CODE list is
# the same extension set as CODE's regex, the README list the same three names as ROOT_README's — or
# pruning would silently drop hits, which is the failure this instrument keeps re-finding. Measured on
# this box: unpruned, these axes read every tracked byte of 27 mirrors (a 10 MB single-line
# calibration JSON is one of them) and a six-axis subset did not finish in five minutes.
PRUNE = {
    "README": ["README.md", "README.rst", "README.markdown"],
    "CODE": ["*.py", "*.ts", "*.tsx", "*.js", "*.jsx", "*.go", "*.rs", "*.swift", "*.kt", "*.java",
             "*.zig", "*.c", "*.cpp", "*.hpp", "*.m", "*.mm", "*.rb", "*.dart", "*.scala"],
}
_LISTED = {}


def listed(tree):
    if tree not in _LISTED:
        _LISTED[tree] = sh(where(tree), ["ls-files"]).split("\n")
    return _LISTED[tree]


def sel(tree, kind, pat, filt):
    """The matched file set — the count is derived from it, and the trend block intersects it."""
    d = where(tree)
    if kind == "GIT":
        return {t for t in sh(d, ["tag"]).split("\n") if t.strip()}
    if kind in ("PATH", "COUNT"):
        return {f for f in listed(tree) if re.search(pat, f, re.I)}
    out = sh(d, ["grep", "-l" if kind == "CODE" else "-n", "-I", "-i", "-E", "-e", pat, "--"]
             + PRUNE.get(kind, []))
    lines = out.split("\n")
    if kind == "CODE":
        hits = {f for f in lines if f}
        return {f for f in hits if re.search(filt, f)} if filt else hits
    hits = set()
    for line in lines:
        parts = line.split(":", 2)
        if len(parts) < 3:
            continue
        path, content = parts[0], parts[2]
        if filt and not re.search(filt, path):
            continue
        if re.search(pat, content, re.I):
            hits.add(path)
    return hits


def evidence(tree, kind, pat, filt):
    """One matched line, so a count can be looked at instead of trusted. Deliberately the first hit,
    not a sample: the question is 'is this the mechanism or a comment about it', and one line answers
    it for the price of one git grep."""
    if kind not in ("CODE", "README"):
        return ""
    out = sh(where(tree), ["grep", "-n", "-I", "-i", "-E", "-e", pat, "--"] + PRUNE.get(kind, []))
    for line in out.split("\n"):
        parts = line.split(":", 2)
        if len(parts) < 3:
            continue
        path, ln, content = parts[0], parts[1], parts[2].strip()
        if filt and not re.search(filt, path):
            continue
        if kind == "README" and not re.search(pat, content, re.I):
            continue
        return "%s:%s  %s" % (path, ln, content[:100])
    return "<<< counted, nothing readable >>>"


def changed(tree, days):
    """Files this tree actually edited inside the window — the difference between a field that carries
    a mechanism and a field that is working on one."""
    out = sh(where(tree), ["log", "--since=%d.days" % days, "--name-only", "--no-renames",
                           "--no-merges", "--pretty=format:"])
    return {l.strip() for l in out.split("\n") if l.strip()}


def cadence(tree, days=30, windows=4):
    """Commits per window, newest first. `rev-list --count` with both bounds, so a mirror cloned a
    month ago reports a quiet last month rather than a false zero-due-to-HEAD."""
    out = []
    for k in range(windows):
        n = sh(where(tree), ["rev-list", "--count", "--since=%d.days" % ((k + 1) * days),
                             "--until=%d.days" % (k * days) if k else "--until=now", "HEAD"])
        out.append(int(n.strip() or 0))
    return out


def tag_windows(tree, days=30, windows=4):
    """Tags *minted* per window.creatordate: annotated tags carry the tag date, lightweight ones the
    commit date they point at — which is why a mirror's early history can look back-loaded."""
    raw = sh(where(tree), ["for-each-ref", "refs/tags", "--format=%(creatordate:unix)"])
    stamps = [int(x) for x in raw.split("\n") if x.strip().lstrip("-").isdigit()]
    now = time.time()
    return [sum(1 for s in stamps if s > now - (k + 1) * days * 86400) -
            sum(1 for s in stamps if s > now - k * days * 86400)
            for k in range(windows)]


print("mirrors: %s   (parent: %s; ocoreai scored by the same instruments)" % (len(trees), parent))
present = {}
for name, kind, seg, pat, filt, trended in AXES:
    denom = SEG.get(seg, trees)
    per = {t: sel(t, kind, pat, filt) for t in trees}
    present[name] = per
    in_seg = [t for t in denom if per.get(t)]
    allc = [t for t in trees if per.get(t)]
    dead = " <<INSTRUMENT-DEAD: no tree matched>>" if not allc else ""
    numeric = kind in ("GIT", "COUNT")
    print("\n── %s   [segment: %s]%s" % (name, seg, "" if trended else ""))
    if numeric:
        vals = sorted(((len(per[t]), t) for t in denom if per.get(t)), reverse=True)
        counts = sorted(len(per[t]) for t in denom if per.get(t))
        med = counts[len(counts) // 2] if counts else 0
        print("   in-segment %d/%d  median=%d%s" % (len(in_seg), len(denom), med, dead))
        print("   %s" % ", ".join("%s=%d" % (t, v) for v, t in vals[:9]))
        print("   ours: %s=%s" % ("tags" if kind == "GIT" else "SKILL.md", len(per["ocoreai"])))
    else:
        print("   in-segment %d/%d   all-trees %d/%d%s" % (len(in_seg), len(denom), len(allc),
                                                           len(trees), dead))
        print("   ours: %s" % ("YES (%d files)" % len(per["ocoreai"]) if per["ocoreai"] else "no"))
        print("   %s" % ", ".join(sorted(in_seg)))
        if os.environ.get("OC_EVIDENCE") == "1":
            for t in sorted(in_seg + (["ocoreai"] if per.get("ocoreai") else [])):
                print("      %-18s %s" % (t, evidence(t, kind, pat, filt)[:150]))

if os.environ.get("OC_NO_TREND") == "1":
    raise SystemExit(0)

# ── where the field is moving ────────────────────────────────────────────────────────────────────
# Two different questions, and the first one is a premise for the second: is a tree still being
# edited at all (cadence), and is this *concept* among the edits (heat). A concept present in 14/14
# trees and touched by 1 in the window is maintenance; present in 6 and touched by 9 is a direction.
print("\n\n══ TREND — window %d d, cadence in 30-d windows (newest first) ══\n" % trend_days)
chg = {t: changed(t, trend_days) for t in trees}
print("%-18s %-24s %s" % ("tree", "commits 30·30·30·30", "tags minted 30·30·30·30"))
rows = []
for t in trees:
    rows.append((t, cadence(t), tag_windows(t)))
for t, c, g in sorted(rows, key=lambda r: -sum(r[1][:2])):
    print("%-18s %-24s %s" % (t, "·".join(str(x) for x in c), "·".join(str(x) for x in g)))
field = sum(sum(c[:2]) for t, c, g in rows if t != "ocoreai") / max(1, len(trees) - 1)
ours = [c for t, c, g in rows if t == "ocoreai"][0]
print("\nfield mean commits (last 60 d): %.0f    ours: %d" % (field, sum(ours[:2])))
live = [t for t, c, g in rows if t != "ocoreai" and sum(c[:2]) > 0]
print("trees with any commit in the last 60 d: %d/%d" % (len(live), len(trees) - 1))

print("\n── concept heat — present (HEAD) vs being edited (window %d d) ──" % trend_days)
for name, kind, seg, pat, filt, trended in AXES:
    if not trended or kind == "GIT":
        continue
    denom = SEG.get(seg, trees)
    per = present[name]
    in_seg = [t for t in denom if per.get(t)]
    hot = [t for t in in_seg if per[t] & chg[t]]
    print("   %-38s present %2d/%d   edited now %2d/%d   %s"
          % (name, len(in_seg), len(denom), len(hot), len(in_seg), ",".join(hot) or "—"))
    print("   %-38s ours: present %s · edited now %s"
          % ("", "yes" if per["ocoreai"] else "no",
             "yes (%d files)" % len(per["ocoreai"] & chg["ocoreai"])
             if per["ocoreai"] & chg["ocoreai"] else "no"))
PY
