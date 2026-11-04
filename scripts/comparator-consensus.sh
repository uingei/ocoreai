#!/usr/bin/env bash
# comparator-consensus.sh — what the field agrees on, counted off the local mirrors; plus where it is
# moving.
#
# Prints, per axis, the trees that show the mechanism and the count; then DIFFUSION (each axis classified
# by its share of its own segment, plus the ours-alone and segment-majority-zeros lines — the cut
# docs/agent/comparator-innovation.md reads); then SEGMENT-AUDIT (serving trees on disk that the declared
# `serve` segment omits, loose by design, for a human to adjudicate); then the release-ledger block; then a
# trend block (cadence, tags minted, and which concepts the field is editing *this quarter* rather than
# merely carrying) and the touch-weighted churn block. It is
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
import collections
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
    # serve = answers a chat-completion POST itself. This list was hand-typed while five serving trees sat
    # unlisted on the same disk: `Rapid-MLX` (`rapid_mlx/routes/chat.py:2`), `MTPLX`
    # (`mtplx/server/openai.py:37679`), `Strata` (`serve/server.py:6`, which names the Anthropic route in
    # the same sentence), `openclaw` (the endpoint is a knob, default off:
    # `src/config/schema.help.runtime.ts:287`) and `TensorFold` ("TensorFold serves language models from a
    # Zig binary", `README.md:3`, whose own tests drive it with raw HTTP framing cases). So every `n/7`
    # this file printed was a field divided by a subset of itself, and the subset was chosen before three
    # of the five trees existed here. `vllm-metal` stays out on a read, not a hunch: its one /v1 hit is a
    # *client* POST (`args.endpoint + "/v1/chat/completions"`), and a backend that rides vllm's server is
    # not itself a server. The SEGMENT-AUDIT block now prints loose candidates, so the next arrival is
    # visible without waiting for someone to notice the prose and the data disagree.
    "serve": ["vllm", "sglang", "ollama", "omlx", "mlx-serve", "splash", "ocoreai",
              "Rapid-MLX", "MTPLX", "Strata", "openclaw", "TensorFold"],
    "agent": ["hermes-agent", "openclaw", "codex", "claude-code", "qwen-code", "opencode",
              "goose", "pi", "cline", "deepseek-harness", "harness2", "Strata", "OpenHands", "ocoreai"],
    # Ships something a stranger installs or runs: everything except the trees that are a model's
    # README, a benchmark for other people's code, or a pin we compile rather than distribute.
    "shippable": [t for t in trees if t not in
                  {"Qwen3.8", "Qwen3.8-Flash-Next", "SWE-bench", "mlx-swift-lm", "coreai-models"}],
}
CODE = r"\.(py|ts|tsx|js|jsx|go|rs|swift|kt|java|zig|c|cpp|hpp|m|mm|rb|dart|scala)$"
# SRC = CODE plus the build/prose-tooling layer. A mechanism that lives in a shell script or a Makefile is
# invisible to CODE, and "our repo has none" is then an artifact of the pathset, not of the repo.
SRC = r"\.(py|ts|tsx|js|jsx|go|rs|swift|kt|java|zig|c|cpp|hpp|m|mm|rb|dart|scala|sh|bash|mk)$|Makefile"
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
    # Two mechanisms that surfaced in the churn block's hottest-file column (11-04) and had no axis at
    # all, which is how a spreading practice stays invisible: goose's `src/acp/server.rs` (25 touches)
    # and qwen-code's `acp-integration/session/Session.ts` (112) are one protocol; deepseek-harness's
    # generated-and-verified-fresh config catalog is another.
    # Scored on the protocol's NAME, because three attempts to score it by shape each produced a fresh
    # false positive and one false negative, all of them plausible: (i) `[^a-z0-9]` boundaries scored
    # `Rapid-MLX` off `sqrt_acp`/`acp_prev` (the alpha-cumulative-product pair of a diffusion sampler);
    # (ii) treating `_` as an identifier character — which it is, and ERE has no `\b` for the lint below to
    # refuse — fixed that and dropped OpenHands' real `acp_server: "claude-code"`; (iii) widening to
    # protocol-ish vocabulary (`acp\\.`, `RequestPermission`) then scored `Rapid-MLX`'s `acp.max()`, and
    # scored `codex`, `Strata` and `mlx-serve` on their *own* permission code, which is not the protocol at
    # all. A token this short in a corpus this polyglot has no decidable boundary, so the axis asks the
    # question a reader can actually check: does the tree name the protocol or import its package. Same
    # in-segment count (8/14) as the broken versions had, which is exactly why the shape versions read fine
    # and were wrong.
    ("speaks ACP (agent client protocol)", "CODE", "agent",
     r"agent[-_.]client[-_.]protocol|agentclientprotocol", CODE, True),
    # Scored on SRC (CODE's extensions plus `.sh`/`Makefile`), because a generator can live in a shell
    # script and the pathset must not be what hides it. Measured today the widening changes nothing here
    # (2/24 either way), which is the useful result: the binding constraint is the *vocabulary*
    # (`doc-sync`, `generate-docs`, `verify-config-catalog`), not the file type — our own
    # `make docs-check` re-derives figures into prose under a name this pattern does not know, so `ours:
    # no` means "we do not use their words", not "we have nothing".
    ("generates docs from source (code)",  "SRC",  "shippable",
     r"gen[-_]config[-_]catalog|verify[-_]config[-_]catalog|doc[-_]sync|docs?[-_]generator|generate[-_]docs?",
     SRC, True),
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
# SRC's superset must match SRC's regex the same way CODE's does, or pruning would drop hits the
# filter would have kept — the invariant the comment above this block states.
PRUNE["SRC"] = PRUNE["CODE"] + ["*.sh", "*.bash", "*.mk", "*Makefile", "*makefile"]
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
    out = sh(d, ["grep", "-l" if kind in ("CODE", "SRC") else "-n", "-I", "-i", "-E", "-e", pat, "--"]
             + PRUNE.get(kind, []))
    lines = out.split("\n")
    if kind in ("CODE", "SRC"):
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
    if kind not in ("CODE", "SRC", "README"):
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


def changed_touches(tree, days):
    """The same log as `changed`, kept as a per-file COUNT instead of a set: how many times a file was
    edited is the effort signal, which files were edited at all is the breadth signal. The churn block
    needs the first and prints the second, because they disagree — openclaw touches one baseline file
    1 624 times and that is invisible to a set."""
    out = sh(where(tree), ["log", "--since=%d.days" % days, "--name-only", "--no-renames",
                           "--no-merges", "--pretty=format:"])
    return collections.Counter(l.strip() for l in out.split("\n") if l.strip())


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

# ── the diffusion cut — how far each practice spread inside its own segment ────────────────────────
# The consensus table is sorted by agreement, which buries the two rows a direction comes from: the
# practice exactly ONE tree in a segment holds (a bet nobody has been exposed to yet — not a lead, not an
# error), and the practice we hold while the segment does not. Shares are taken against each axis's own
# declared segment, because "2/7" and "2/24" are different facts. Reuses `present` from the sweep above,
# so it costs no extra scan.
STATE = [(1.0, "CONSENSUS"), (0.8, "NEAR-CONSENSUS"), (0.5, "MAJORITY"),
         (0.15, "MINORITY"), (0.02, "RARE"), (0.0, "SINGLETON"), (-1.0, "ABSENT")]


def state_of(n, d):
    if n == 0:
        return "ABSENT"
    share = float(n) / d if d else 0.0
    for floor, label in STATE:
        if share >= floor:
            return label
    return "SINGLETON"


print("\n── diffusion — how far each practice spread (share of its own segment) ──")
diff_rows = []
for name, kind, seg, pat, filt, trended in AXES:
    if kind == "GIT":
        continue
    denom = SEG.get(seg, trees)
    per = present[name]
    in_seg = [t for t in denom if per.get(t)]
    diff_rows.append((float(len(in_seg)) / max(1, len(denom)), name, seg, len(in_seg), len(denom),
                      sorted(in_seg), bool(per["ocoreai"])))
if not diff_rows:
    print("   <<INSTRUMENT-DEAD: no axis scored>>")
for share, name, seg, n, d, who, ours in sorted(diff_rows, key=lambda r: (r[0], r[1])):
    print("   %-14s %-42s %2d/%-3d  ours:%s" % (state_of(n, d), name[:42], n, d,
                                                "yes" if ours else "NO"))
    if n <= 2 and who:
        print("   %-14s   who: %s" % ("", ", ".join(who)))
# "Ours alone" is the row that prices a bet: the segment's denominator excludes us being counted twice,
# so n == 1 with ours=True means nobody else in the segment holds the mechanism at all.
alone = [r[1] for r in diff_rows if r[6] and r[3] <= 1]
behind = [(r[1], r[3], r[4]) for r in diff_rows if not r[6] and r[3] >= max(2, int(0.5 * r[4]))]
print("   ours-alone (we score; no other in-segment tree does): %s"
      % (", ".join(alone) if alone else "— none; every practice we hold is held by others —"))
print("   segment-majority we score zero on: %s"
      % (", ".join("%s %d/%d" % b for b in behind) if behind else "— none —"))

# ── SEGMENT-AUDIT: does the declared segment match the disk? ───────────────────────────────────────
# Segments are hand-typed data, and hand-typed data goes stale the day a tree is cloned: `serve` had
# seven members while five serving trees sat unlisted, so every serve denominator silently divided by a
# subset. This cannot be a verdict — "mentions a chat route" is true of every harness that CALLS one, and
# a regex cannot tell a server from a client across eight stacks (that judgement is what the header
# comment on SEG is for) — so it prints loose candidates with one matched line each, for a human to
# adjudicate, and names the pattern's bias so nobody reads it as a count.
ROUTE = re.compile(r"/v1/(chat/completions|completions|messages)\b")
REGISTER = re.compile(r"(@\w+\.(post|api_route|route|get)\(|\b(app|router|api|server|e)\.(post|route|"
                      r"add_route|add_post|handle|handleFunc)\(|\.route\(\s*[\"']|Router\(on:\s*[\"']|"
                      r"Endpoints?:|serve language models)")
print("\n── SEGMENT-AUDIT — serve candidates on disk the declared segment omits (LOOSE: "
      "a client that POSTs the route also matches; adjudicate by reading the line) ──")
for t in trees:
    if t in SEG["serve"]:
        continue
    out = sh(where(t), ["grep", "-n", "-I", "-E", "-e", r"/v1/(chat/completions|completions|messages)",
                        "--"] + PRUNE["CODE"])
    hits = [l for l in out.split("\n") if ROUTE.search(l)]
    reg = [l for l in hits if REGISTER.search(l)]
    if reg:
        print("   %-18s %4d route line(s), %d registration-shaped — %s"
              % (t, len(hits), len(reg), reg[0][:110].strip()))

# ── what the field's own release ledgers say ─────────────────────────────────────────────────────
# Churn says where effort is going NOW; a per-version ledger is a tree's own statement of what it
# shipped and in WHICH ORDER — the only source in this corpus that carries sequence, and the only one
# written for a stranger to read before installing. Two facts about it are the finding, not the verb
# mix: most trees publish none, and where one exists the ledger is mostly a list of things that broke.
VER_HEAD = re.compile(r"^#{1,3} +v?(?:0|[1-9]\d*)\.\d+(?:\.\d+)?\b", re.M)
VERB = re.compile(r"^(Added|Fixed|Improved|Changed|Removed|Reduced|Updated|Deprecated|Breaking)\b")
BULLET = re.compile(r"^\s*[-*] +(.+)$", re.M)
# Ordered by when the most-installed coding agent first wrote them down (§ The field's own ledgers).
LEDGER_AXES = [
    ("permissions / approval", r"permission|approv|consent|trust"),
    ("MCP / connectors", r"\bmcp\b|connector"),
    ("model / effort / thinking", r"effort|thinking|reasoning|opus|sonnet|haiku"),
    ("compaction / memory", r"compact|memory|summar"),
    ("context / token budget", r"context window|token budget|context usage|overflow"),
    ("tests / evals", r"\btest\b|\beval|\bbenchmark"),
    ("update / install", r"\bupdate\b|install|brew|npm"),
    ("headless / SDK", r"headless|agent sdk|\bsdk\b"),
    ("plan mode", r"plan mode"),
    ("hooks / mods", r"\bhook\b|\bmod\b|\bmods\b"),
    ("subagents / background", r"subagent|background|workflow"),
    ("plugins / marketplace", r"plugin|marketplace"),
    ("sandbox / confinement", r"sandbox|seatbelt|confine"),
    ("skills", r"\bskill"),
    ("remote / cloud sessions", r"remote|cloud session|self-hosted"),
    ("localization", r"i18n|locale|translat|localiz"),
]
print("\n── release ledgers — what each tree tells a stranger it shipped ──")
labelled, no_ledger = [], []
for t in sorted(trees):
    # `ls-files` has no --ignore-case and `-i` there means --ignored (it errors on a bare pattern),
    # so case-insensitivity comes from grep-equivalent filtering in Python, not from a git flag.
    paths = [l.strip() for l in sh(where(t), ["ls-files", "-c"]).split("\n")
             if "changelog" in l.lower() and l.strip().lower().endswith(".md")]
    if not paths:
        no_ledger.append(t)
        continue
    body, best = "", ""
    for rel in paths:
        try:
            txt = open(os.path.join(where(t), rel), encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if len(VER_HEAD.findall(txt)) > len(VER_HEAD.findall(body)):
            body, best = txt, rel
    nv, bl = len(VER_HEAD.findall(body)), [m.group(1) for m in BULLET.finditer(body)]
    mix = collections.Counter(m.group(1) for x in bl for m in [VERB.match(x)] if m)
    if sum(mix.values()) < 40:
        print("   %-17s %-22s %3d versions  %5d bullets  (free-form: %d verb-labelled)"
              % (t, best[:22], nv, len(bl), sum(mix.values())))
        continue
    labelled.append((t, best, nv, bl, mix, body))
    n = sum(mix.values())
    print("   %-17s %-22s %3d versions  %5d bullets  Fixed=%d%% Added=%d%% Improved=%d%%  fix:add=%s"
          % (t, best[:22], nv, len(bl), 100 * mix["Fixed"] // n, 100 * mix["Added"] // n,
             100 * mix["Improved"] // n,
             ("%.1f:1" % (mix["Fixed"] / mix["Added"])) if mix["Added"] else "no Adds"))
print("   trees publishing NO changelog: %d/%d — %s" % (len(no_ledger), len(trees), ", ".join(no_ledger)))
SMALL_N = 4
if len(labelled) < SMALL_N:
    print("   <<SMALL-N: only %d verb-labelled ledgers exist, so any share below reads one big tree"
          " plus two — it is NOT a field consensus>>" % len(labelled))
big = max(labelled, key=lambda r: r[2]) if labelled else None
if big:
    t, best, nv, bl, mix, body = big
    heads = [m.start() for m in VER_HEAD.finditer(body)] + [len(body)]
    # A ledger is written NEWEST-first, so the segment list is reversed before anyone is told which
    # release came "first" — the first port of this block skipped that and reported the newest release
    # as release #1, which made every axis look like it shipped on day one.
    segs = []
    for i in range(len(heads) - 1):
        segs.append([m.group(1) for m in BULLET.finditer(body[heads[i]:heads[i + 1]])])
    segs.reverse()
    print("   first release to record each axis, in %s (%d releases, oldest first):" % (t, len(segs)))
    seq = []
    for name, rx in LEDGER_AXES:
        pat = re.compile(rx)
        pos = next((i for i, s in enumerate(segs) if any(pat.search(x) for x in s)), None)
        rel = sum(1 for s in segs if any(pat.search(x) for x in s))
        nb = sum(1 for s in segs for x in s if pat.search(x))
        seq.append((pos if pos is not None else 10 ** 6, name, rel, nb))
    for pos, name, rel, nb in sorted(seq):
        print("      %-26s %s %-5s then %3d/%d releases, %4d bullets"
              % (name, "at #%d" % (pos + 1) if pos < 10 ** 6 else "never  ", "", rel, len(segs), nb))

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

# ── where the agent trees' attention actually goes ───────────────────────────────────────────────
# Concept heat above answers "is this mechanism being touched"; it cannot answer "what is this tree's
# attention going INTO", because it counts trees, not effort. This block re-cuts the same window by what
# the PATH says a file is for, touch-weighted (a file edited 200× is 200 touches, not 1), so a
# 19 835-commit month and a 150-commit month compare as shapes rather than magnitudes.
# Three limits, stated because this file's own ledger is a list of path proxies that lied: buckets are
# NON-EXCLUSIVE (`codex-rs/core/src/guardian/tests.rs` is authority *and* measurement) so shares do not
# sum to 100 % and `unmatched` is printed, not hidden; a directory named `review` may be code review; and
# a tree that keeps its loop in `src/lib/` scores under whatever that dir is called. The hottest-files
# column is the part a reader can audit without trusting any regex — which is why it is here.
BUCKET = [
    ("loop/context",    r"(^|/)(context|compact|summar|memory|session|rewind|fork|history|token|budget|prompt)"),
    ("tools/skills",    r"(^|/)(tool|function|parser|skill|mcp|extension|plugin)"),
    # Split 11-04: one "authority" bucket conflated two mechanisms with opposite verdicts — approval
    # (a shipping agent's most-edited axis, per the ledgers) and OS confinement (shipped, quiet). A
    # pattern that answers two questions prints one number and invites the wrong reading of both.
    ("approval",        r"(^|/)(permission|approval|approv|consent|trust|review)"),
    # `guard` is deliberately NOT here: codex's `core/src/guardian/` is its APPROVAL subsystem
    # (approval_request.rs, permissions.rs, decision.rs, score_authorization.rs), so matching it under
    # confinement moved 7 % of the hottest tree's churn onto the wrong mechanism.
    ("confinement",     r"(^|/)(sandbox|seatbelt|jail|landlock|seccomp)"),
    ("orchestration",   r"(^|/)(subagent|sub_agent|orchestrat|swarm|team|task|delegat|routing|plan)"),
    ("meas/tests",      r"(^|/)(eval|bench|scorecard|probe|metrics|trace|judge|test)"),
    ("surface",         r"(^|/)(ui|app|web|chat|view|screen|channel|integrat|desktop|front|components|page)"),
    ("engine",          r"(^|/)(model|engine|infer|kv|specul|cache|kernel|serve|api|routes|server)"),
    # The two the buckets missed on 11-04, and missed loudly: `i18n` tables were hermes-agent's,
    # opencode's, OpenHands's and qwen-code's hottest files, and lockfile churn is a large part of the
    # `unmatched` column. An axis nobody thought to ask about reads as "not happening".
    ("localization",    r"(^|/)(i18n|l10n|locale|localiz|lang|language|translation|messages/)"),
    ("docs/spec",       r"(^|/)(docs?/|readme|architecture|openapi|protocol|schema|decisions|details)"),
    ("deps/release",    r"(^|/)(package-lock|pnpm-lock|bun\.lock|cargo\.lock|package\.json|setup\.py|cmakelists|changlog|changelog|feed\.xml|version|manifest)"),
]
# A share floor is not a liveness floor. Demanding >= 10 % of own churn before a bucket counts went red
# on `authority` for every tree — while codex's whole `guardian` module and openclaw's seven
# `packages/sandbox/*` were matching it the whole time. Big denominators squash shares; they do not
# mean absence. So the tally may use a share, and the vacuity check uses a FILE COUNT of zero.
FLOOR_SHARE = 10
SRC_EXT = (".swift", ".py", ".ts", ".tsx", ".js", ".mjs", ".cjs", ".go", ".rs", ".c", ".cc", ".cpp",
           ".h", ".hpp", ".java", ".kt", ".rb", ".php", ".cs", ".scala", ".sh", ".m", ".mm")
seg_agent = [t for t in SEG["agent"] if t != "ocoreai"]
print("\n── agent-tree churn — %d d, touch-weighted, buckets non-exclusive ──" % trend_days)
print("%-17s %-7s %-6s %s" % ("tree", "touch", "files", "top dirs | every bucket share | unmatched"))
shape = {b[0]: [] for b in BUCKET}
corpus_files = {b[0]: 0 for b in BUCKET}
for t in sorted(seg_agent, key=lambda x: -len(chg[x])):
    uniq = chg.get(t)
    if not uniq:
        print("%-17s %-7s %-6s (quiet in window)" % (t, "—", "—"))
        continue
    tc = changed_touches(t, trend_days)
    tot = sum(tc.values())
    # Churn presumes the mirror HOLDS THE IMPLEMENTATION. `claude-code` does not: 1 383 of its 1 473
    # tracked files are mods, so its churn measures docs and plugins while its CHANGELOG describes an
    # engine nobody here can read. Flag the premise rather than letting a docs mirror vote on effort.
    tracked = [f for f in sh(where(t), ["ls-files", "-c"]).split("\n") if f.strip()]
    src = sum(1 for f in tracked if f.lower().endswith(SRC_EXT))
    src_pct = (100.0 * src / len(tracked)) if tracked else 0.0
    flag = "" if src_pct >= 25 else "  <<docs mirror: %d%% source — churn cannot see its engine>>" % src_pct
    dirstat = collections.Counter(
        "/".join(p.split("/")[:2]) if "/" in p else p for p in tc.elements()).most_common(3)
    # One regex pass per (file, bucket), cached: the shares and the unmatched residual must come from
    # the same matrix or the column lies about how much of the tree it did not classify.
    files = sorted(tc)
    flags = {f: [bool(re.search(rx, f.lower())) for _, rx in BUCKET] for f in files}
    hit = []
    for bi, (name, _rx) in enumerate(BUCKET):
        n = sum(tc[f] for f in files if flags[f][bi])
        corpus_files[name] += sum(1 for f in files if flags[f][bi])
        hit.append((name, 100.0 * n / tot))
        if n * 100.0 / tot >= FLOOR_SHARE:
            shape[name].append(t)
    unmatched = sum(tc[f] for f in files if not any(flags[f]))
    tops = " ".join("%s:%d%%" % (d, 100 * c // tot) for d, c in dirstat)
    bs = " ".join("%s=%d%%" % (k[:4], int(v)) for k, v in sorted(hit, key=lambda x: -x[1]))
    print("%-17s %-7d %-6d %s%s" % (t, tot, len(uniq), tops[:34], flag))
    print("%-17s %-7s %-6s %s  unmatched=%d%%" % ("", "", "", bs, 100 * unmatched // tot))
    for p, n in tc.most_common(3):
        print("%-17s %-7s     hottest: %-4d %s" % ("", "", n, p[:70]))
print("\n  >= %d%% of own churn, in N of %d agent trees:" % (FLOOR_SHARE, len(seg_agent)))
for name, _ in BUCKET:
    n = sorted(shape[name])
    dead = "  <<INSTRUMENT-DEAD: zero files matched corpus-wide>>" if corpus_files[name] == 0 else ""
    print("    %-14s %2d/%d  %s%s" % (name, len(n), len(seg_agent), ", ".join(n), dead))
ours_u, ours_t = chg.get("ocoreai"), changed_touches("ocoreai", trend_days)
if ours_t:
    o_tot = sum(ours_t.values())
    o_hit = [(name, 100.0 * sum(v for k, v in ours_t.items() if re.search(rx, k.lower())) / o_tot)
             for name, rx in BUCKET]
    print("    ours  %d touches / %d files  %s" % (o_tot, len(ours_u or ()), " ".join(
        "%s=%d%%" % (n[:4], int(v)) for n, v in sorted(o_hit, key=lambda x: -x[1]))))
    for p, n in ours_t.most_common(3):
        print("    ours  hottest: %-4d %s" % (n, p[:74]))
PY
