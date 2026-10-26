#!/usr/bin/env python3
"""Efficiency self-test — the cost figures are priced against their own denominators.

Why: the scoreboard's mission is not only "did the workspace end up right" but "what did a
verified success cost" (elapsed and tokens, including the attempts that did not verify). Two
failure modes are live here and both are gated rather than trusted:

  quotient without a denominator — `tokens_per_success=0` printed from a run where the usage
          column stopped parsing looks like a very cheap model, so every quotient is published
          next to `passes=`/`usage_parsed=` and an unparsed column says `unmeasured` instead;
  the score line displaced — `_repeat_stats._read_run` takes the LAST `#` line as the run's
          score, so a `# efficiency` line written after `# score` would silently become the
          score of every A/B verdict ever taken from this file. The order is pinned here.
"""

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import _eval  # noqa: E402
import _repeat_stats  # noqa: E402

HEADER = "task\tkind\trc\telapsed_ms\tusage\n"


def write(body):
    path = os.path.join(tempfile.mkdtemp(prefix="ocoreai-efficiency-selftest-"), "results.tsv")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(HEADER + body)
    return path


def usage(prompt, completion):
    return "finish=stop prompt=%d cached=0 completion=%d echoed_tool_calls=1" % (prompt, completion)


def main():
    defects = []

    # 1. hand-computable fixture: two passes (100 ms/400 ms, 10+5 and 20+5 tokens) and one
    #    failure that spent 300 ms and 40 tokens. Success latency ignores the failure; unit cost
    #    does not — that asymmetry is the whole claim, so it is asserted in both directions.
    good = write(
        "a\twrite\t0\t100\t%s\n" % usage(10, 5)
        + "b\tedit\t1\t300\t%s\n" % usage(30, 10)
        + "c\texec\t0\t400\t%s\n" % usage(20, 5)
    )
    line, unparsed = _eval.efficiency(good)
    expect = {
        "passes=2/3": "the verifier, not the prose, decides the denominator",
        "median_ms_success=100": "median of the two successes (the failed 300 ms row is not latency)",
        "p95_ms_success=400": "nearest-rank p95 over the successes",
        "ms_total=800": "the run's whole wall time, waste included",
        "ms_per_success=400": "800/2 — a failure's seconds are paid by the successes",
        "tokens_total=80": "(10+5) + (30+10) + (20+5) = 15+40+25: a failed attempt still spent its tokens",
        "tokens_per_success=40": "80/2 — the failure's tokens are paid by the successes",
        "usage_parsed=3/3": "every row's usage cell parsed",
    }
    for token, why in expect.items():
        if token not in line:
            defects.append("fixture-1: missing %s in `%s` — %s" % (token, line, why))
    if unparsed:
        defects.append("fixture-1: rows reported unparsed: %s" % unparsed)
    if "usage_shape=broken" in line:
        defects.append("fixture-1: parsed usage called broken")

    # 1b. twenty successes: the p95 index sits strictly below the last element, which is the
    #     shape that crashed the first live run — a float index reaching list[]. The fixture is
    #     generated, so the expectation states the RULE (the 19th of 20 sorted values) rather
    #     than a magic number copied out of the code under test.
    many = write("".join(
        "t%02d\texec\t0\t%d\t%s\n" % (i, 100 + i, usage(1, 1)) for i in range(20)))
    mline, _ = _eval.efficiency(many)
    #     values 100..119 → median is the 10th (109) and nearest-rank p95 is ceil(0.95*20)=19th
    #     (118, not the maximum 119); 20 rows x (1+1) tokens = 40, so the unit cost is 2.
    if "median_ms_success=109" not in mline or "p95_ms_success=118" not in mline:
        defects.append("20-success fixture: median/p95 wrong (`%s`) — expected 109 (10th of 20) "
                       "and 118 (19th of 20, nearest-rank), with integer indices" % mline)
    if "tokens_per_success=2" not in mline:
        defects.append("20-success fixture: unit cost wrong (`%s`) — 40 tokens / 20 passes = 2" % mline)

    # 2. zero passes: the quotient is undefined, and `0` would be read as "free".
    zero = write("a\twrite\t1\t100\t%s\n" % usage(10, 5))
    zline, _ = _eval.efficiency(zero)
    if "passes=0/1" not in zline:
        defects.append("zero-pass fixture: denominator not stated (`%s`)" % zline)
    for trapped in ("ms_per_success=none", "tokens_per_success=none", "median_ms_success=none"):
        if trapped not in zline:
            defects.append("zero-pass fixture: %s missing from `%s` — a 0 quotient reads as free"
                           % (trapped, zline))

    # 3. a usage column that stopped matching (wire or helper change) must refuse to price.
    broken = write("a\twrite\t0\t100\tfinish=stop cached=0 echoed_tool_calls=0\n")
    bline, bunparsed = _eval.efficiency(broken)
    if "usage_shape=broken" not in bline or "tokens_per_success=none" not in bline:
        defects.append("broken-usage fixture: priced from zeros anyway (`%s`)" % bline)
    if bunparsed != ["a"]:
        defects.append("broken-usage fixture: the unparsed row must be named, got %s" % bunparsed)

    # 4. no rows at all is not a score of zero, it is an instrument that read nothing.
    empty = write("")
    proc = subprocess.run([sys.executable, os.path.join(HERE, "_eval.py"), "efficiency", empty],
                          capture_output=True, text=True)
    if proc.returncode == 0:
        defects.append("empty run file printed `%s` — zero rows must exit non-zero"
                       % proc.stdout.strip())
    elif "zero task rows" not in (proc.stderr or ""):
        defects.append("empty run file failed without naming why: %s" % (proc.stderr or "").strip()[:160])

    # 5. the trap: `_read_run` keeps the LAST `#` line as the score, so efficiency must precede it.
    body = (HEADER + "a\twrite\t0\t100\t%s\n" % usage(10, 5))
    for order, want_score in ((True, "score 22/35"), (False, "efficiency passes=1/1")):
        path = os.path.join(tempfile.mkdtemp(prefix="ocoreai-efficiency-order-"), "results.tsv")
        tail = ("# efficiency passes=1/1\n" if order else "# score 22/35\n") + \
               ("# score 22/35\n" if order else "# efficiency passes=1/1\n")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body + tail)
        _rows, score, _invalid, _nd, _cond = _repeat_stats._read_run(path)
        if score != want_score:
            defects.append(
                "order %s: `_read_run` read the score as %r — the last `#` line wins, so "
                "run.sh must write `# efficiency` BEFORE `# score`"
                % ("efficiency-then-score" if order else "score-then-efficiency", score))

    if defects:
        print("efficiency self-test: %d defect(s)" % len(defects))
        for d in defects:
            print("  FAIL %s" % d)
        return 1
    print("efficiency self-test: 5 scenario group(s) green — denominators, zero-pass, broken "
          "usage, empty run, and the score-line order")
    print("  ✅ cost per verified success is priced from rows that name their own denominator")
    return 0


if __name__ == "__main__":
    sys.exit(main())
