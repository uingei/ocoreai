#!/usr/bin/env python3
"""What produced a scoreboard number — written into `results.tsv`, and enforced where runs meet.

Why: `# score 30/36 model X` is the line that gets quoted into CHANGELOG and averaged by
`_repeat_stats.py`, and it carried no conditions at all. The denominator comes from a task file
that gets edited, and the tool set comes from `GET /v1/tools` on a server that gets rebuilt, so two
runs that print the same score may have been played under different rules — and `repeat.sh` averages
whatever it finds. Measured cost of exactly this class: on 10-22 a run that lost 13 tasks to an
engine outage was averaged in and McNemar reported p=0.0032 for a change that had none.

The comparators that got this right record it: ollama's decision bench writes `corpus_sha256`,
`concurrency`, `epoch` and `cached_input_tokens` into every row
(`~/references/ollama/cmd/bench/decision.go:98`) and refuses warmup or concurrency for a case that
claims cache reuse (`:69`); Strata writes how a number is produced before it quotes it
(`~/references/Strata/docs/BENCHMARK_PROTOCOL.md`). Recording is half of it, so this file also
gives `_repeat_stats.py` the fields to refuse on: a run whose conditions differ from the rest of
its root is not a sample of that configuration, and it is excluded, loudly.
"""

import hashlib
import json
import os
import platform

DIGEST_LEN = 12

# The fields that decide whether two runs measured the same game. `score` is deliberately not one
# of them — that is the thing being measured.
KEY_FIELDS = ("model", "tasks", "tools", "temperature", "approval", "concurrency", "host", "docs",
              "binary")

# Inside one root every field above must agree: a repeat of a configuration that states something
# else is not a repeat. Across two roots the loop is *deliberately* moving one thing, so the
# refusal is narrower. `tools` sits apart because a proposal's whole point can be the tool
# descriptions and schemas the model is handed (AGENTS.md § Documentation Map treats them as
# function-calling contracts), and refusing on that would make the loop unable to judge exactly
# the experiments it exists to judge. Movement there is the hypothesis, so it is printed instead.
SURFACE_FIELDS = ("tools", "docs")
INVARIANT_FIELDS = tuple(k for k in KEY_FIELDS if k not in SURFACE_FIELDS)


def _digest(data):
    return hashlib.sha256(data).hexdigest()[:DIGEST_LEN]


def tasks_token(path):
    """`<basename>+sha256:<12>` over the task file's bytes — ids plus prompts plus verifiers."""
    with open(path, "rb") as fh:
        return "%s+%s" % (os.path.basename(path), _digest(fh.read()))


def tools_token(specs):
    """`<count>+sha256:<12>` over the tool declarations the agent was actually handed.

    The declarations come from `GET /v1/tools` through `_eval.tool_specs` (one home for the shape:
    the wire answers `{"data":[…]}`, and a local copy of a schema is the drift class this repo
    already refuses). The digest covers names *and* descriptions *and* schemas, because that is what
    the model reads: a reworded description or a tightened `required` list is a different instrument
    even when every name survives. Order-insensitive — the set is the condition, not its order.
    """
    canon = "\n".join(sorted(
        json.dumps(spec, sort_keys=True, separators=(",", ":"), ensure_ascii=False) for spec in specs))
    return "%d+%s" % (len(specs), _digest(canon.encode("utf-8")))


def docs_token(path):
    """`none`, or `<basename>+sha256:<12>` over the instruction doc the workspace handed the agent.

    `WorkspaceContext.buildSection` injects `<workspace>/AGENTS.md` into the system prompt, so a run
    whose workspace holds a doc and a run whose workspace holds none are different instruments — and a
    run that *thinks* it passed a doc while the file was not there is the vacuous-arm class this file
    exists to refuse. `none` is a stated value, not an omission: the 39-task board ran with no doc for
    its whole history, and that has to read as a condition rather than as a missing field.
    """
    if not path or path == "none":
        return "none"
    with open(path, "rb") as fh:
        return "%s+%s" % (os.path.basename(path), _digest(fh.read()))


def binary_token(path):
    """`<basename>+<mtime>+<bytes>` for the artefact that actually answered, or `unknown`.

    A board's verdict is a claim about a *build*, while the path `_lib.sh` resolves is whatever sits
    there: measured 10-27, a run scored against a binary four hours older than the sources it was
    judging, and nothing in `results.tsv` could show it. mtime+size is not a fingerprint — it is
    cheap, and it moves when the artefact is rebuilt, which is the difference a paired A/B must not
    cross silently (a rebuild between arms changes the engine, not the hypothesis). `unknown` is a
    stated value so an omission cannot be read as a match.
    """
    if not path or path in ("none", "unknown"):
        return "unknown"
    st = os.stat(path)
    return "%s+%d+%d" % (os.path.basename(path), int(st.st_mtime), st.st_size)


def render(model, tasks_path, tool_specs, temperature, approval, concurrency=1, host=None,
           docs=None, binary=None):
    """The `k=v …` body, in KEY_FIELDS order — one home for the order and for the separators."""
    fields = [
        ("model", model),
        ("tasks", tasks_token(tasks_path)),
        ("tools", tools_token(tool_specs)),
        ("temperature", str(temperature)),
        ("approval", approval),
        ("concurrency", str(concurrency)),
        ("host", host or "%s %s %s" % (platform.system(), platform.release(), platform.machine())),
        ("docs", docs_token(docs)),
        ("binary", binary_token(binary)),
    ]
    return " ".join("%s=%s" % (k, v) for k, v in fields)


def build(model, tasks_path, tool_specs, temperature, approval, concurrency=1, host=None,
          docs=None, binary=None):
    """The canonical conditions string (without the leading `#` the scoreboard writes)."""
    return "conditions " + render(model, tasks_path, tool_specs, temperature, approval,
                                  concurrency=concurrency, host=host, docs=docs, binary=binary)


def parse(text):
    """`# conditions k=v …` (or the bare line) → dict; unparseable values stay strings."""
    body = text.strip()
    if body.startswith("#"):
        body = body.lstrip("#").strip()
    if not body.startswith("conditions "):
        return {}
    out = {}
    for chunk in body[len("conditions "):].split():
        if "=" in chunk:
            key, value = chunk.split("=", 1)
            out[key] = value
    return out


def field_diffs(a, b, only=None):
    """Fields both sides state but state differently — empty means the two runs are comparable.

    A field one side never stated is not a difference: runs written before this line existed must
    still be readable, and the caller says so out loud rather than pretending they matched.
    `only` narrows the comparison to the fields a caller is entitled to refuse on.
    """
    keys = KEY_FIELDS if only is None else tuple(only)
    return [(k, a[k], b[k]) for k in keys if k in a and k in b and a[k] != b[k]]



def _declared_specs(names):
    """The server's own declarations for the names this scoreboard needs.

    `names` is the whitespace-separated list `run.sh` holds in `OCOREAI_EVAL_TOOLS` — the same
    split `_eval.py spec-count` uses, because a separator copied wrong is a second truth. The
    coverage is floored against the request: `_eval.tool_specs` answers `[]` for anything it does
    not recognise, and a digest over zero tools attributes the score to a server that declares
    nothing. Measured on this host: a comma where `_eval` splits on whitespace produced
    `tools=0+e3b0c44298fc` — sha256 of the empty string — on a run whose every request carried
    six declarations.
    """
    import _eval
    wanted = set(names.split())
    if not wanted:
        raise SystemExit("_conditions.py: no tool names given — a conditions line over zero"
                        " declarations would attribute the score to a server that declares nothing")
    specs = _eval.tool_specs(wanted)
    if "all" in wanted:
        # `all` is a word, not a tool name, so "every asked name is declared" cannot be its premise.
        # The equivalent check is that the server declared a surface at all: `_eval.tool_specs` answers
        # [] for an unreadable or oddly shaped payload, and a digest over zero tools would credit the
        # score to a server that declares nothing — the same failure the name check above exists for.
        if not specs:
            raise SystemExit("_conditions.py: `all` resolved to zero declarations from the cached"
                            " GET /v1/tools — the tools digest would cover a surface the run never"
                            " handed the model")
        return specs
    missing = sorted(wanted - set(_eval.spec_name(s) for s in specs))
    if missing:
        raise SystemExit("_conditions.py: the cached GET /v1/tools does not declare %s (asked for"
                        " %d, got %d) — the tools digest would cover a different instrument than"
                        " the one this run hands the model"
                        % (", ".join(missing), len(wanted), len(specs)))
    return specs


if __name__ == "__main__":
    import argparse
    import _eval
    ap = argparse.ArgumentParser(prog="_conditions.py", description=__doc__.split("\n")[0])
    ap.add_argument("--model", required=True)
    ap.add_argument("--tasks", default=None,
                   help="task file (default: _eval.TASKS_PATH, i.e. $OCOREAI_EVAL_TASKS)")
    ap.add_argument("--tools", required=True,
                   help="whitespace-separated tool names, i.e. $OCOREAI_EVAL_TOOLS")
    ap.add_argument("--temperature", default=None,
                   help="default: _eval.REQUEST_TEMPERATURE, the value the scoreboard actually"
                        " sends — a literal here would be a second home for the same decision")
    ap.add_argument("--approval", required=True)
    ap.add_argument("--concurrency", default="1")
    ap.add_argument("--docs", default="none",
                   help="path to the instruction doc the workspace handed the agent, or `none`"
                        " (the board's whole history until 10-27) — digested, not named, because a"
                        " reworded doc is a different instrument")
    ap.add_argument("--binary", default="unknown",
                   help="the ocoreai artefact answering the requests; recorded as"
                        " <name>+<mtime>+<bytes> so a rebuild between arms is visible")
    a = ap.parse_args()
    # Pairs only: `run.sh` writes the `# conditions …` marker itself, so the marker lives at the
    # one site that writes it instead of being invented twice.
    print(render(
        model=a.model,
        tasks_path=a.tasks or _eval.TASKS_PATH,
        tool_specs=_declared_specs(a.tools),
        temperature=a.temperature if a.temperature is not None else _eval.REQUEST_TEMPERATURE,
        approval=a.approval,
        concurrency=a.concurrency,
        docs=None if a.docs == "none" else a.docs,
        binary=None if a.binary in ("none", "unknown") else a.binary,
    ))
