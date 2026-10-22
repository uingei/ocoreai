#!/usr/bin/env python3
"""Aggregate repeated scoreboard runs into a noise floor.

Why this exists: `run.sh` prints N/M, and 9 tasks made one task worth 11 percentage points —
an observed ±1 between identical configurations was therefore indistinguishable from an
improvement. Any loop that auto-accepts a change on that signal is tuning noise. This file
turns repeated runs into the three numbers a decision needs:

  spread        — mean and sample SD across the runs, plus the binomial 95% CI half-width of a
                  single run (the noise one measurement carries even with a frozen build);
  instability   — the tasks that flip between identical runs, by id (the actual noise sources,
                  which is a different list from "the hard tasks");
  detection     — the smallest improvement that could be called real: the smallest Δtasks whose
                  paired sign test (McNemar, exact) reaches p < 0.05 against the observed
                  discordance, and the unpaired bound 1.96·√(2p(1-p)/n) for a single-run A/B.
"""

import json
import math
import os
import sys
from itertools import combinations


def load_runs(root):
    runs = []
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name, "results.tsv")
        if not os.path.isfile(path):
            continue
        rows = {}
        score = ""
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("#"):
                    score = line.strip().lstrip("#").strip()  # per-run, reset above
                    continue
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 5 or parts[0] == "task":
                    continue
                rows[parts[0]] = (parts[1], parts[2], parts[3])
        if rows:
            runs.append((name, rows, score))
    return runs


def mcnemar_exact(b, c):
    """Two-sided exact sign test on discordant pairs (no normal approximation, because b+c is
    small here and the approximation is the part that would lie)."""
    n = b + c
    if n == 0:
        return 1.0
    m = min(b, c)
    tail = sum(math.comb(n, i) for i in range(m + 1)) * (0.5 ** n)
    return min(1.0, 2.0 * tail)


def paired(a_root, b_root):
    """McNemar between two configurations over all |A|x|B| run pairs.

    Per task, b = pairs where A passed and B failed, c = the reverse. The exact two-sided sign
    test is used because |A|x|B| is small and the chi-square approximation is the part that
    would overstate significance. Pooling tasks is deliberate: the same change moves several
    tasks, and each contributes discordance — but the pooled p is only honest when the tasks
    share one cause, which is why the per-task breakdown is printed alongside.
    """
    ra, rb = load_runs(a_root), load_runs(b_root)
    if not ra or not rb:
        print("paired: both roots need run-*/results.tsv (A=%d B=%d)" % (len(ra), len(rb)))
        return 1
    tasks = sorted({t for _, rows, _ in ra + rb for t in rows})
    b = c = 0
    flipped = []
    for t in tasks:
        pa = [rows[t][1] == "0" for _, rows, _ in ra if t in rows]
        pb = [rows[t][1] == "0" for _, rows, _ in rb if t in rows]
        for x in pa:
            for y in pb:
                if x and not y:
                    b += 1
                elif y and not x:
                    c += 1
        if pa and pb and (sum(pa) / len(pa)) != (sum(pb) / len(pb)):
            flipped.append("%s %d/%d->%d/%d" % (t, sum(pa), len(pa), sum(pb), len(pb)))
    n = len(tasks)
    sa = [sum(1 for t in tasks if rows.get(t, ("", "1"))[1] == "0") for _, rows, _ in ra]
    sb = [sum(1 for t in tasks if rows.get(t, ("", "1"))[1] == "0") for _, rows, _ in rb]
    mean_a, mean_b = sum(sa) / len(sa), sum(sb) / len(sb)
    p = mcnemar_exact(b, c)
    print("paired A=%s  B=%s" % ("/".join(map(str, sa)), "/".join(map(str, sb))))
    print("mean %.2f -> %.2f of %d  (delta %+.2f tasks, %+.1f pp)"
          % (mean_a, mean_b, n, mean_b - mean_a, 100 * (mean_b - mean_a) / n))
    print("discordant: b(A-only)=%d c(B-only)=%d -> McNemar exact two-sided p=%.4f%s"
          % (b, c, p, "  SIGNIFICANT" if p < 0.05 else "  NOT significant"))
    print("tasks that moved: %s" % ("; ".join(flipped) if flipped else "none"))
    return 0


def main():
    if len(sys.argv) >= 5 and sys.argv[1] == "--a":
        return paired(sys.argv[2], sys.argv[4])
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    runs = load_runs(root)
    if not runs:
        print("no results.tsv under %s/run-*/ — repeat.sh writes these" % root)
        return 1

    tasks = sorted({t for _, rows, _ in runs for t in rows})
    k = len(runs)
    matrix = {t: [int(rows[t][1]) if t in rows else -1 for _, rows, _ in runs] for t in tasks}
    scores = [sum(1 for t in tasks if matrix[t][i] == 0) for i in range(k)]
    n = len(tasks)
    mean = sum(scores) / k
    p = mean / n
    sd = (sum((s - mean) ** 2 for s in scores) / (k - 1)) ** 0.5 if k > 1 else 0.0
    # Units, stated once because they are where this kind of instrument goes wrong: p is a
    # proportion, so 1.96*sqrt(p(1-p)/n) is a proportion (percentage points), and the same
    # half-width in TASKS is that times n. The first draft of this file printed the
    # proportion as tasks (±0.2 of 24) and called 1 task "detectable" at n=24, where the
    # honest number is ±4.6 tasks.
    ci_prop = 1.96 * math.sqrt(max(p * (1 - p), 1e-12) / n)
    ci_tasks = ci_prop * n

    unstable = [t for t in tasks if 0 < sum(1 for v in matrix[t] if v == 0) < k]
    always = [t for t in tasks if all(v == 0 for v in matrix[t])]
    never = [t for t in tasks if all(v != 0 for v in matrix[t])]

    print("repeats %d · tasks %d · scores %s" % (k, n, "/".join(str(s) for s in scores)))
    print("mean %.2f/%d (%.1f%%) · SD across runs %.2f" % (mean, n, 100 * p, sd))
    print("single-run 95%% CI half-width ±%.1f tasks (%.1f pp) — a smaller difference is noise"
          % (ci_tasks, 100 * ci_prop))
    print("stable-pass %d · stable-fail %d · FLAKY %d %s"
          % (len(always), len(never), len(unstable), ("(%s)" % ", ".join(unstable)) if unstable else ""))

    # A/B on one run each: the count-difference SD is sqrt(2*n*p*(1-p)), so the smallest Δ in
    # TASKS that clears 95%% is 1.96*sqrt(2*n*p*(1-p)).
    detection = math.ceil(1.96 * math.sqrt(max(2 * n * p * (1 - p), 1e-12)))
    print("detection: an unpaired A/B must move >= %d tasks to clear 95%% on one run each"
          % detection)
    if k >= 2:
        # discordance available across this set's own runs: report the paired threshold that
        # these runs' flakiness actually supports
        disc = 0
        for a, b in combinations(range(k), 2):
            for t in tasks:
                if (matrix[t][a] == 0) != (matrix[t][b] == 0):
                    disc += 1
        pairs = k * (k - 1) // 2
        print("paired: %d discordant task-pair(s) over %d run-pair(s) -> McNemar is the right "
              "test here; use --a/--b to compare two configurations" % (disc, pairs))
        if disc:
            need = 0
            for b in range(1, n + 1):
                if mcnemar_exact(b, 0) < 0.05:
                    need = b
                    break
            print("        with this much flakiness, a clean sweep of %d task(s) flipping one way "
                  "is the smallest paired p<0.05 result" % (need or n + 1))

    out = {
        "runs": k,
        "tasks": n,
        "scores": scores,
        "meanTasks": round(mean, 3),
        "sdAcrossRuns": round(sd, 3),
        "singleRunCI95HalfWidthTasks": round(ci_tasks, 2),
        "singleRunCI95HalfWidthPp": round(100 * ci_prop, 1),
        "unstableTaskIds": unstable,
        "alwaysPass": always,
        "alwaysFail": never,
        "minDetectableUnpairedDeltaTasks": detection,
        "perTaskPasses": {t: sum(1 for v in matrix[t] if v == 0) for t in tasks},
    }
    with open(os.path.join(root, "noise.json"), "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print("wrote %s/noise.json" % root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
