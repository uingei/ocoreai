#!/usr/bin/env bash
# competitor-path-scan.sh — when did each reference ship each agent axis, and what did it cost them?
#
# Reads only `git log` subjects from the clones under ~/references (or $OCOREAI_REFS), so it
# runs anywhere the clones exist and never touches the network. For every axis it reports the
# OLDEST matching subject (the first mention), then how many later commits touch the axis and
# how many of those read like fixes — the cost proxy that ranks an axis by how much trouble it
# turned out to be. `docs/agent/competitor-iteration-paths.md` states the numbers this printed
# and the inference drawn from them; re-run this before quoting one.
#
# Honest limits: a subject is a first *mention*, not a GA date; keyword matching is heuristic;
# a mirror proves content, never HEAD.
set -uo pipefail
REFS="${OCOREAI_REFS:-$HOME/references}"
REPOS="${1:-codex ollama}"
[ -d "$REFS" ] || { echo "no reference root at $REFS — nothing to scan (SKIP is not a verdict)"; exit 0; }
"${PYTHON:-python3}" - "$REFS" "$REPOS" <<'PY_EOF'
import os, re, subprocess, sys
refs, repos = sys.argv[1], sys.argv[2].split()
AX = [
    ("sandbox", r"sandbox"), ("approvals", r"\bapprov"), ("review-diff", r"apply_patch|\breview\b"),
    ("notify", r"notif(y|ication)"), ("image-input", r"(image|screenshot).{0,20}(input|attach|paste)|vision"),
    ("mcp", r"\bmcp\b"), ("session-resume", r"\bresum(e|ing)\b.{0,30}(session|conversation|rollout)|/resume|--resume"),
    ("mid-turn-steer", r"steer|mid.?turn|interrupt.{0,25}(turn|generation|stream|response)"),
    ("structured-output", r"structured output|json_schema|response_format|grammar"),
    ("context-compact", r"compact(ion|ing|ed)?\b.{0,40}(context|history|token|conversation)|auto.?compact"),
    ("memory", r"\bmemor(y|ies)\b"), ("checkpoint-rewind", r"checkpoint|rewind|undo"),
    ("parallel-tools", r"parallel.{0,15}tool"), ("skills", r"\bskill"), ("subagents", r"subagent|sub-agent"),
    ("plan-mode", r"plan.?mode|\bplan\b.{0,20}mode"), ("hooks", r"\bhooks?\b"),
    ("background-tasks", r"background (task|job|run|exec)"),
    ("kv-cache-correctness", r"kv.?cach|prefix cach|prompt cach|rewind|evict|snapshot"),
]
FIX = re.compile(r"\bfix|revert|harden|guard|race|leak|deadlock|hang|corrupt|safe", re.I)
for repo in repos:
    p = os.path.join(refs, repo)
    if not os.path.isdir(os.path.join(p, ".git")):
        print("\n#### %s — not cloned here (designated, unread)" % repo)
        continue
    log = subprocess.run(["git", "-C", p, "log", "--date=short", "--format=%ad|%h|%s"],
                         capture_output=True, text=True).stdout
    rows = [(d, h, s) for d, h, s in (l.split("|", 2) for l in log.split("\n") if l.strip())]
    print("\n#### %s — %d commits, %s..%s" % (repo, len(rows), rows[-1][0], rows[0][0]))
    out = []
    for name, pat in AX:
        rx = re.compile(pat, re.I)
        hits = [x for x in reversed(rows) if rx.search(x[2])]
        if not hits:
            continue
        first, later = hits[0], hits[1:]
        fixes = [x for x in later if FIX.search(x[2])]
        out.append((first[0], name, len(later), len(fixes), first[2][:72]))
    for d, name, tl, fx, subj in sorted(out):
        print("  %-21s %s  later=%-4d fixes=%-4d  %s" % (name, d, tl, fx, subj))
PY_EOF
