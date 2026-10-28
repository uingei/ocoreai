#!/usr/bin/env python3
"""_skill_task_harness.py — assemble and judge the stranger-agent task (probe 40).

Why this is a separate file: probe 40's §2 needs a checkpoint, and a claim that can only be
checked where weights exist is a claim no runner ever verifies. The two parts that decide the
verdict — how the artefact is injected, and what counts as the task being *done* — are pure
functions of files, so they are testable on any host (probe 40 §1). The live tier then runs
exactly the same code against a real model, so the instrument and the measurement cannot drift.

Subcommands
  prompt  build the agent's request body: system = the published skill, verbatim
  audit   prove the injection is the artefact and the task text leaks no route
  verify  exact-value check on the deliverable file (unguessable nonce)
"""

import argparse
import json
import os
import sys

# Tokens that would hand the agent the answer. The task may be plain English — it may not name
# a route, a query parameter or a method+path pair, because discovering those from the artefact
# is the thing under test.
LEAK_TOKENS = (
    "/sessions",
    "/v1/",
    "q=",
    "GET ",
    "POST ",
    "DELETE ",
    "endpoints",
    "capabilities",
)

SKILL_ORDER = ("SKILL.md", "references/wire.md", "references/agent-loop.md",
               "references/honesty-and-limits.md")


def skill_text(skill_dir):
    """The published artefact, concatenated in a fixed order, with a header per file.

    Order is fixed because the injection size is a measured number in the probe's output; a
    nondeterministic order would make it uncomparable.
    """
    parts, missing = [], []
    for rel in SKILL_ORDER:
        path = os.path.join(skill_dir, rel)
        if not os.path.isfile(path):
            missing.append(rel)
            continue
        with open(path, encoding="utf-8") as fh:
            parts.append("### BEGIN %s\n%s\n### END %s" % (rel, fh.read().strip(), rel))
    if missing:
        raise SystemExit("skill dir %s is missing %s" % (skill_dir, ", ".join(missing)))
    return "\n\n".join(parts)


def cmd_prompt(a):
    art = skill_text(a.skill_dir)
    with open(a.task_file, encoding="utf-8") as fh:
        task = fh.read().strip()
    tools = []
    if a.tools_file:
        with open(a.tools_file, encoding="utf-8") as fh:
            payload = json.load(fh)
        specs = payload if isinstance(payload, list) else (
            payload.get("data") or payload.get("tools") or [])
        keep = set(a.only_tools.split(",")) if a.only_tools else None
        for s in specs:
            fn = s.get("function") or {}
            name = fn.get("name", "")
            if keep is None or name in keep:
                tools.append(s)
        if not tools:
            raise SystemExit(
                "no tool declaration survived the filter — the agent would have no way to act, "
                "so the task would measure a refusal rather than a capability")
    body = {
        "model": a.model,
        "session_id": a.session,
        "temperature": 0.0,
        "max_tokens": int(a.max_tokens),
        "messages": [{"role": "system", "content": art}, {"role": "user", "content": task}],
    }
    if tools:
        body["tools"] = tools
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(body, fh)
    names = ",".join((s.get("function") or {}).get("name", "?") for s in tools)
    print("injected_bytes=%d files=%d tools=%d(%s) body_bytes=%d"
          % (len(art.encode()), len(SKILL_ORDER), len(tools), names,
             len(json.dumps(body).encode())))


def cmd_audit(a):
    art = skill_text(a.skill_dir)
    with open(a.task_file, encoding="utf-8") as fh:
        task = fh.read()
    fails = []
    if len(art.encode()) < int(a.min_artefact_bytes):
        fails.append("artefact is %d bytes < floor %d — the injection shrank, so the agent was "
                     "not given the surface the claim is about"
                     % (len(art.encode()), int(a.min_artefact_bytes)))
    leaks = [t for t in LEAK_TOKENS if t.lower() in task.lower()]
    if leaks:
        fails.append("task text names the route it should make the agent find: %s"
                     % ", ".join(leaks))
    if a.nonce and a.nonce in task:
        fails.append("task text contains the nonce — an exact-value check would prove nothing")
    if "http://" not in task and "https://" not in task:
        fails.append("task text gives no base URL — the agent has nothing to point the artefact at")
    for fails_line in fails:
        print("AUDIT FAIL %s" % fails_line)
    if fails:
        return 1
    print("audited ok artefact=%d bytes task=%d bytes" % (len(art.encode()), len(task.encode())))
    return 0


def cmd_verify(a):
    """Pass only if the unguessable token is in the deliverable.

    Containment, not equality: the task asks the agent to copy what the server said, and a model
    that retrieved the right note but wrapped it in its own sentence has still finished the job.
    The token is generated per run and appears nowhere the agent can read except through the
    server, so its presence is the proof — the anti-echo case is impossible by construction,
    because `audit` fails the run if the token ever reaches the task text.
    """
    if not os.path.isfile(a.file):
        print("VERIFY FAIL no deliverable at %s — the agent never wrote the answer" % a.file)
        return 1
    with open(a.file, encoding="utf-8", errors="replace") as fh:
        got = fh.read()
    if a.expect in got:
        print("VERIFY ok deliverable carries the token (%d bytes written)" % len(got))
        return 0
    print("VERIFY FAIL deliverable=%r does not contain %r — a guessed or partial answer is not"
          " the task" % (got[:160].strip(), a.expect))
    return 1


def main():
    p = argparse.ArgumentParser(prog="_skill_task_harness.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    q = sub.add_parser("prompt")
    q.add_argument("--skill-dir", required=True)
    q.add_argument("--task-file", required=True)
    q.add_argument("--out", required=True)
    q.add_argument("--model", required=True)
    q.add_argument("--session", required=True)
    q.add_argument("--tools-file", default="")
    q.add_argument("--only-tools", default="")
    q.add_argument("--max-tokens", default="900")
    q.set_defaults(fn=cmd_prompt)

    u = sub.add_parser("audit")
    u.add_argument("--skill-dir", required=True)
    u.add_argument("--task-file", required=True)
    u.add_argument("--min-artefact-bytes", default="12000")
    u.add_argument("--nonce", default="")
    u.set_defaults(fn=cmd_audit)

    v = sub.add_parser("verify")
    v.add_argument("--expect", required=True)
    v.add_argument("--file", required=True)
    v.set_defaults(fn=cmd_verify)

    a = p.parse_args()
    sys.exit(a.fn(a))


if __name__ == "__main__":
    main()
