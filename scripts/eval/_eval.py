#!/usr/bin/env python3
"""JSON side of the task-success scoreboard. Kept separate from run.sh so the shell
stays readable and no JSON is parsed with sed (the failure mode that makes a verifier
report a pass it never measured)."""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TASKS_PATH = os.environ.get("OCOREAI_EVAL_TASKS", os.path.join(HERE, "tasks.json"))
# The scoreboard's single sampling setting, named so the conditions line can state it without a
# second literal to drift: `_conditions.py` reads this constant instead of repeating 0.0.
REQUEST_TEMPERATURE = 0.0


def tasks():
    with open(TASKS_PATH, encoding="utf-8") as fh:
        return json.load(fh)["tasks"]


def task(task_id):
    for t in tasks():
        if t["id"] == task_id:
            return t
    raise SystemExit("unknown task id: %s" % task_id)


SNAPSHOT_PER_FILE_BYTES = 2048
SNAPSHOT_BUDGET_BYTES = 65536


def write_snapshot(ws, dest, budget=SNAPSHOT_BUDGET_BYTES,
                  per_file=SNAPSHOT_PER_FILE_BYTES):
    """Record what the workspace actually holds, for a task that failed.

    `verify` says the workspace is wrong; it never says what the produced file *says*, and the
    next task wipes the directory. Without these bytes the cause of a failure is gone when the
    session ends, which turns every root-cause claim in README.md into a claim with no gate.
    Returns the size written so the caller can floor it (a snapshot of nothing is still a fact,
    so the report is never empty)."""
    names = sorted(
        os.path.relpath(os.path.join(root, name), ws)
        for root, _dirs, files in os.walk(ws)
        for name in files
    )
    chunks = []
    if not names:
        chunks.append("<< workspace holds no files: the agent created nothing >>\n")
    used = 0
    for index, rel in enumerate(names):
        path = os.path.join(ws, rel)
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            raw = fh.read(per_file)
        body = raw.decode("utf-8", "replace")
        shown = "" if len(raw) >= size else ", first %d bytes shown" % len(raw)
        chunk = "### %s (%d bytes%s)\n%s%s" % (
            rel, size, shown, body, "" if body.endswith("\n") or not body else "\n")
        cost = len(chunk.encode("utf-8"))
        if used + cost > budget:
            chunks.append("<< artefact budget %d B exhausted; %d file(s) not shown >>\n"
                         % (budget, len(names) - index))
            break
        chunks.append(chunk)
        used += cost
    text = "".join(chunks)
    with open(dest, "w", encoding="utf-8") as out:
        out.write(text)
    return len(text.encode("utf-8"))





def _usage_ints(usage):
    """(prompt, completion) from a usage cell, or None if either is missing.

    The cell is written by `usage` above (`finish=… prompt=… cached=… completion=…`), so a wire
    or helper change shows up here as an unparsed row rather than as a silently zero token count:
    a cost figure computed from zeros is a harness bug wearing a model score."""
    out = []
    for field in ("prompt", "completion"):
        m = re.search(r"%s=([0-9]+)" % field, usage or "")
        if not m:
            return None
        out.append(int(m.group(1)))
    return out


def efficiency(path):
    """Cost per VERIFIED success, derived from the run file's own rows.

    Two decisions this cannot get wrong quietly: cost is summed over every row (a failed attempt
    spends its tokens and its seconds, and excluding them would price success below its real
    cost), and the denominators are published next to the quotients (`passes=`, `usage_parsed=`),
    so `tokens_per_success` always names what it was divided by. At zero passes the quotient is
    `none` — undefined is a fact, zero is a fabrication."""
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 5 or parts[0] == "task":
                continue
            rows.append(parts)
    if not rows:
        raise SystemExit(
            "efficiency: %s holds zero task rows — an instrument that read nothing prints no "
            "number (a 0/0 average would be a score invented from absence)" % path)

    passes = 0
    ms_all = 0
    ms_success = []
    tokens = 0
    parsed = 0
    unparsed = []
    for parts in rows:
        try:
            ms = int(parts[3])
        except ValueError:
            ms = None
        if ms is not None:
            ms_all += ms
        ok = parts[2].strip() == "0"
        if ok:
            passes += 1
            if ms is not None:
                ms_success.append(ms)
        ints = _usage_ints(parts[4])
        if ints is None:
            unparsed.append(parts[0])
        else:
            parsed += 1
            tokens += ints[0] + ints[1]

    def rank(values, q_bp):
        """Nearest-rank percentile over `q_bp` basis points, in exact integer arithmetic.

        Float arithmetic here crashed the first live run (23 successes: ceil(0.95*23)-1 = 21.0
        reached `ordered[...]`), which is why the quantiles take basis points and the ceiling
        floors at 19 successes instead of trusting a two-row fixture to find it."""
        ordered = sorted(values)
        rank_ceil = (q_bp * len(ordered) + 9999) // 10000
        return ordered[min(len(ordered) - 1, max(0, rank_ceil - 1))]

    out = ["passes=%d/%d" % (passes, len(rows)),
           "rows=%d" % len(rows),
           "median_ms_success=%s" % (rank(ms_success, 5000) if ms_success else "none"),
           "p95_ms_success=%s" % (rank(ms_success, 9500) if ms_success else "none"),
           "ms_total=%d" % ms_all,
           "ms_per_success=%s" % (round(ms_all / passes) if passes else "none"),
           "tokens_total=%s" % (tokens if parsed else "unmeasured"),
           "tokens_per_success=%s" % (round(tokens / passes) if passes and parsed else "none"),
           "usage_parsed=%d/%d" % (parsed, len(rows))]
    if parsed == 0:
        out.append("usage_shape=broken")
    return " ".join(out), unparsed


def spec_name(spec):
    """A tool entry's name under both shapes the wire answers: {function:{name}} and {name}."""
    if not isinstance(spec, dict):
        return ""
    fn = spec.get("function")
    return (fn or {}).get("name") if isinstance(fn, dict) else spec.get("name", "")


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

    elif cmd == "snapshot":
        # Prints the byte count it wrote; run.sh proves it is an integer and floors it at 1.
        print(write_snapshot(sys.argv[2], sys.argv[3]))

    elif cmd == "body":
        ws, model, session_id, needed = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
        t = task(sys.argv[6])
        specs = tool_specs(set(needed.split()))
        names = ", ".join(sorted((s.get("function") or {}).get("name", "?") for s in specs))
        head = (
            t["prompt"]
            + "\n\nWorkspace directory (absolute): "
            + ws
            + "\nTools available to you: "
            + names
            + "\n"
        )
        # A task that declares response_format asks for a machine-readable answer, so the
        # harness must not also demand "one short line" — two instructions, one of them
        # unparseable, would score the harness's own ambiguity instead of the server's.
        response_format = t.get("response_format")
        tail = (
            "Use the tools to actually change or read the workspace, then reply with only the"
            " JSON object described above — no prose, no code fences."
            if response_format
            else "Use the tools to actually change or read the workspace. Do not describe what"
                 " you would do — do it, then reply with one short line saying what happened."
        )
        prompt = head + tail
        body = {
            "model": model,
            "session_id": session_id,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": int(t.get("max_tokens", 700)),
            "temperature": REQUEST_TEMPERATURE,
        }
        if specs:
            body["tools"] = specs
        if response_format:
            body["response_format"] = response_format
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

    elif cmd == "efficiency":
        line, unparsed = efficiency(sys.argv[2])
        if unparsed:
            line += " usage_unparsed=%d(%s)" % (len(unparsed), ",".join(unparsed[:3]))
        print(line)

    else:
        raise SystemExit("unknown command: %s" % cmd)


if __name__ == "__main__":
    main()
