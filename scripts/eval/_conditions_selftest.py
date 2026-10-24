#!/usr/bin/env python3
"""Re-derive the conditions line and the aggregation guard from the files that claim them.

Why: `_conditions.py` is what makes a quoted `# score N/M` attributable, and `_repeat_stats.py` is
where runs get averaged into a noise floor and a McNemar p. Both claims rot silently: the builder
can lose a field, the digest can become a constant, the scoreboard can stop writing the line, and
the aggregator can go back to averaging whatever it finds. Every check here re-computes the value
from bytes rather than trusting the string, and the file scans floor their own patterns so a regex
that stopped matching fails instead of passing vacuously. No server, no GPU, no build.
"""

import hashlib
import json
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import _conditions as C  # noqa: E402

RUN_SH = os.path.join(HERE, "run.sh")
STATS_PY = os.path.join(HERE, "_repeat_stats.py")
HEX12 = re.compile(r"^[0-9a-f]{%d}$" % C.DIGEST_LEN)


def tasks_file(root, name, content):
    path = os.path.join(root, name)
    with open(path, "wb") as fh:
        fh.write(content)
    return path


def main():
    defects = []
    with tempfile.TemporaryDirectory() as root:
        a = tasks_file(root, "tasks.json", b'[{"id":"t1","verify":"test -f x"}]')
        same = tasks_file(root, "tasks-copy.json", b'[{"id":"t1","verify":"test -f x"}]')
        edited = tasks_file(root, "tasks-edited.json", b'[{"id":"t1","verify":"test -f y"}]')
        read_file = {"type": "function", "function": {
            "name": "read_file", "description": "read", "parameters": {"type": "object"}}}
        write_file = {"type": "function", "function": {
            "name": "write_file", "description": "write", "parameters": {"type": "object"}}}
        edit_file = {"type": "function", "function": {
            "name": "edit_file", "description": "edit", "parameters": {"type": "object"}}}
        specs = [read_file, write_file, edit_file]

        line = C.build("mlx/probe", a, specs, "0.0", "auto")
        again = C.build("mlx/probe", a, specs, "0.0", "auto")
        fields = C.parse(line)

        missing = [k for k in C.KEY_FIELDS if not fields.get(k)]
        if missing:
            defects.append("conditions line lacks field(s): %s — %s" % (", ".join(missing), line))

        if line != again:
            defects.append("the same inputs produced two different conditions lines: %r vs %r" % (line, again))

        # The digest must be a digest: equal bytes → equal token, one byte elsewhere → different,
        # and the value must match sha256 recomputed here (a hardcoded token would pass 1-2).
        tok_a = C.tasks_token(a)
        tok_same = C.tasks_token(same)
        tok_edited = C.tasks_token(edited)
        expected = hashlib.sha256(b'[{"id":"t1","verify":"test -f x"}]').hexdigest()[:C.DIGEST_LEN]
        if not tok_a.endswith("+" + expected):
            defects.append("tasks token %r is not sha256[:%d] of the file's bytes" % (tok_a, C.DIGEST_LEN))
        if tok_a.rsplit("+", 1)[1] != tok_same.rsplit("+", 1)[1]:
            defects.append("identical task bytes digest differently: %s vs %s" % (tok_a, tok_same))
        if tok_a == tok_edited:
            defects.append("editing a task's verifier did not move the tasks digest (%s)" % tok_a)
        if tok_a.split("+")[0] != "tasks.json":
            defects.append("tasks token lost its file name: %r" % tok_a)

        # Tool surface: a set, so declaration order is not a condition; membership is.
        t1 = C.tools_token(specs)
        t2 = C.tools_token(list(reversed(specs)))
        t3 = C.tools_token(specs + [dict(read_file, function=dict(
            read_file["function"], name="search_files", description="search"))])
        t4 = C.tools_token(specs[:-1] + [dict(edit_file, function=dict(
            edit_file["function"], name="patch_file"))])
        t5 = C.tools_token(specs[:-1] + [dict(edit_file, function=dict(
            edit_file["function"], description="edit, reworded"))])
        if t1 != t2:
            defects.append("tool digest depends on declaration order: %s vs %s" % (t1, t2))
        if t1 == t3:
            defects.append("an extra declared tool did not move the tools digest (%s)" % t1)
        if t1 == t4:
            defects.append("a renamed tool did not move the tools digest (%s)" % t1)
        if t1 == t5:
            defects.append("a reworded tool description did not move the tools digest (%s) — the model"
                          " reads that text, so the run is a different instrument" % t1)
        if not t1.startswith("%d+" % len(specs)):
            defects.append("tools token does not carry the count it names: %r (len=%d)" % (t1, len(tools)))
        for label, value in (("tasks", tok_a.rsplit("+", 1)[1]), ("tools", t1.rsplit("+", 1)[1])):
            if not HEX12.match(value):
                defects.append("%s digest %r is not %d lowercase hex" % (label, value, C.DIGEST_LEN))

        # Round trip, and the aggregator's own comparison operator.
        if C.parse("# " + line) != fields:
            defects.append("parse('# %s') lost the fields the builder emitted" % line)
        if C.field_diffs(fields, C.parse(again)) != []:
            defects.append("two runs of the same configuration report field differences")
        other = dict(fields)
        other["tasks"] = "tasks.json+%s" % ("0" * C.DIGEST_LEN)
        diffs = C.field_diffs(fields, other)
        if [d[0] for d in diffs] != ["tasks"]:
            defects.append("a changed tasks digest is not reported as a difference: %r" % (diffs,))
        if C.field_diffs({}, fields) != [] or C.field_diffs({"model": fields["model"]}, fields) != []:
            defects.append("a legacy run stating no conditions (or one field, matching) is being "
                          "reported as a mismatch — old results would stop aggregating entirely")
        if [d[0] for d in C.field_diffs(fields, dict(fields, model="mlx/other"))] != ["model"]:
            defects.append("a different model under the same task file is not reported as a difference")

    # Wiring, with self-floors: the scoreboard must build AND write the line before it writes the
    # score (load_runs lets a later `#` comment overwrite the score line it parsed), and the
    # aggregator must actually consult the fields.
    run = open(RUN_SH, encoding="utf-8").read()
    stats = open(STATS_PY, encoding="utf-8").read()
    floors = [
        ("run.sh references `_conditions.py`", run.count("_conditions.py") >= 2, ">=2 (builder + selftest)"),
        ("run.sh writes a conditions line", run.count("'# conditions") >= 1, ">=1"),
        ("run.sh still writes its score line", run.count("'# score") >= 1, ">=1"),
        ("_repeat_stats.py reads the conditions line", stats.count('"# conditions') >= 1, '>=1'),
        ("_repeat_stats.py compares conditions before averaging", stats.count("field_diffs") >= 2, ">=2"),
    ]
    for what, ok, floor in floors:
        if not ok:
            defects.append("%s — floor %s; the scan pattern rotted, so the guard is not wired" % (what, floor))
    if not defects:
        ci = run.find("'# conditions")
        si = run.find("'# score")
        if not (0 <= ci < si):
            defects.append("run.sh writes `# conditions` after `# score` (%d vs %d) — load_runs keeps the "
                          "last `#` line as the score, so the score line must come last" % (ci, si))

        # The cross-root refusal must be narrower than the within-root one: a proposal is allowed
        # to edit the tool declarations it is being judged on, and refusing there would stop the
        # loop deciding the experiments it exists to decide.
        if "tools" in C.INVARIANT_FIELDS or C.INVARIANT_FIELDS == C.KEY_FIELDS:
            defects.append("INVARIANT_FIELDS still refuses across roots on the tool declarations a"
                          " proposal is allowed to change — the loop could never keep such a patch")
        if set(C.INVARIANT_FIELDS) | set(C.SURFACE_FIELDS) != set(C.KEY_FIELDS):
            defects.append("INVARIANT_FIELDS and SURFACE_FIELDS do not partition KEY_FIELDS — a"
                          " field no comparison covers would drift unnoticed")
        if [d[0] for d in C.field_diffs(fields, dict(fields, tools="2+" + "0" * C.DIGEST_LEN),
                                        only=C.INVARIANT_FIELDS)] != []:
            defects.append("field_diffs(only=INVARIANT_FIELDS) still reports moved tool"
                          " declarations — the surface split is not enforced at the comparison itself")

        # The declaration set the digest covers must be the set the run hands the model. Measured
        # on this host: `--tools` was split on commas while `_eval.py` splits on whitespace, so a
        # live 6-tool run wrote `tools=0+e3b0c44298fc` — sha256 of the empty string — and nothing
        # went red. The floor below is the gate that would have caught it at boot.
    read_file = {"type": "function", "function": {
        "name": "read_file", "description": "read", "parameters": {"type": "object"}}}
    with tempfile.TemporaryDirectory() as cache_root:
        cache = os.path.join(cache_root, "v1-tools.json")
        with open(cache, "w", encoding="utf-8") as fh:
            json.dump({"data": [read_file, {"name": "write_file", "parameters": {}}]}, fh)
        env_cache = os.environ.get("OCOREAI_TOOLS_CACHE")
        os.environ["OCOREAI_TOOLS_CACHE"] = cache
        try:
            got = C._declared_specs("read_file write_file")
            if len(got) != 2:
                defects.append("_declared_specs took 2 names from the cache and returned %d — the"
                             " whitespace separator _eval.py uses is broken" % len(got))
            for bad, label in (("read_file,write_file", "comma-separated"), ("", "empty")):
                try:
                    C._declared_specs(bad)
                    defects.append("_declared_specs accepted %s names and would digest zero"
                                 " declarations" % label)
                except SystemExit:
                    pass
        finally:
            if env_cache is None:
                os.environ.pop("OCOREAI_TOOLS_CACHE", None)
            else:
                os.environ["OCOREAI_TOOLS_CACHE"] = env_cache

    n = len(C.KEY_FIELDS) + 18
    print("conditions self-test: %d check(s), %d defect(s)" % (n, len(defects)))
    for d in defects:
        print("  ✘ %s" % d)
    if defects:
        return 1
    print("  ✅ every conditions field is present and stable, the digests are real sha256 of the bytes "
          "they name (same bytes match, one edited byte or one renamed tool moves them), the parse "
          "round-trips, differences are reported only for fields both sides state, and both the "
          "scoreboard and the aggregator are wired to it at floors the scans can still miss")
    return 0


if __name__ == "__main__":
    sys.exit(main())
