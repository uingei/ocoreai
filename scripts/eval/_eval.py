#!/usr/bin/env python3
"""JSON side of the task-success scoreboard. Kept separate from run.sh so the shell
stays readable and no JSON is parsed with sed (the failure mode that makes a verifier
report a pass it never measured)."""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TASKS_PATH = os.environ.get("OCOREAI_EVAL_TASKS", os.path.join(HERE, "tasks.json"))


def tasks():
    with open(TASKS_PATH, encoding="utf-8") as fh:
        return json.load(fh)["tasks"]


def task(task_id):
    for t in tasks():
        if t["id"] == task_id:
            return t
    raise SystemExit("unknown task id: %s" % task_id)


def tool_specs(needed):
    """Tool declarations come from the server (/v1/tools), never from a copy here: a
    local copy of the schema is a second truth that drifts when the tool changes."""
    cache = os.environ.get("OCOREAI_TOOLS_CACHE")
    if not cache or not os.path.exists(cache):
        raise SystemExit(
            "OCOREAI_TOOLS_CACHE is unset or missing — run.sh must cache GET /v1/tools there"
            " before calling this helper (a missing cache would score every task as a failure"
            " of the model, which it is not)"
        )
    with open(cache, encoding="utf-8") as fh:
        payload = json.load(fh)
    specs = payload
    if isinstance(payload, dict):
        # /v1/tools answers {"data":[…]} (the wire's own wrapper). Accept the plain list
        # too, but never guess silently: an unknown shape yields [] and the caller's floor
        # turns that into a loud harness failure rather than a 0/N model score.
        specs = payload.get("data") or payload.get("tools") or []
    if not isinstance(specs, list):
        return []

    def spec_name(s):
        if not isinstance(s, dict):
            return ""
        fn = s.get("function")
        return (fn or {}).get("name") if isinstance(fn, dict) else s.get("name", "")

    return [s for s in specs if spec_name(s) in needed]


def main():
    cmd = sys.argv[1]

    if cmd == "count":
        print(len(tasks()))

    elif cmd == "ids":
        print("\n".join(t["id"] for t in tasks()))

    elif cmd == "families":
        # kind=N lines, sorted so the caller's floor loop is deterministic: the set of
        # capability families is part of what the scoreboard promises to measure.
        counts = {}
        for t in tasks():
            counts[t["kind"]] = counts.get(t["kind"], 0) + 1
        for k in sorted(counts):
            print("%s=%d" % (k, counts[k]))

    elif cmd == "field":
        t = task(sys.argv[2])
        v = t.get(sys.argv[3], "")
        print(v if isinstance(v, str) else json.dumps(v))

    elif cmd == "spec-count":
        # run.sh asks here rather than re-implementing the filter: two copies of this
        # rule is the drift class this repo already documents (one home per decision).
        print(len(tool_specs(set(sys.argv[2].split()))))

    elif cmd == "create-files":
        ws = sys.argv[2]
        for rel, content in task(sys.argv[3]).get("files", {}).items():
            dest = os.path.join(ws, rel)
            os.makedirs(os.path.dirname(dest) or ws, exist_ok=True)
            with open(dest, "w", encoding="utf-8") as fh:
                fh.write(content)

    elif cmd == "body":
        ws, model, session_id, needed = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
        t = task(sys.argv[6])
        specs = tool_specs(set(needed.split()))
        names = ", ".join(sorted((s.get("function") or {}).get("name", "?") for s in specs))
        prompt = (
            t["prompt"]
            + "\n\nWorkspace directory (absolute): "
            + ws
            + "\nTools available to you: "
            + names
            + "\nUse the tools to actually change or read the workspace. Do not describe what"
              " you would do — do it, then reply with one short line saying what happened."
        )
        body = {
            "model": model,
            "session_id": session_id,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": int(t.get("max_tokens", 700)),
            "temperature": 0.0,
        }
        if specs:
            body["tools"] = specs
        print(json.dumps(body))

    elif cmd == "answer":
        with open(sys.argv[2], encoding="utf-8") as fh:
            data = json.load(fh)
        choice = (data.get("choices") or [{}])[0]
        content = (choice.get("message") or {}).get("content")
        if isinstance(content, list):
            content = " ".join(
                b.get("text", "") for b in content if isinstance(b, dict)
            )
        print((content or "").strip())

    elif cmd == "usage":
        with open(sys.argv[2], encoding="utf-8") as fh:
            data = json.load(fh)
        choice = (data.get("choices") or [{}])[0]
        usage = data.get("usage") or {}
        calls = (choice.get("message") or {}).get("tool_calls") or []
        print(
            "finish=%s prompt=%s cached=%s completion=%s echoed_tool_calls=%d"
            % (
                choice.get("finish_reason"),
                usage.get("prompt_tokens"),
                (usage.get("prompt_tokens_details") or {}).get("cached_tokens"),
                usage.get("completion_tokens"),
                len(calls),
            )
        )

    else:
        raise SystemExit("unknown command: %s" % cmd)


main()
