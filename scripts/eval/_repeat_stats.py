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

import _conditions as COND  # same directory: KEY_FIELDS, parse and field_diffs have one home


def _read_run(path):
    """One `results.tsv` → (rows, score, invalid, no_delivery, conditions).

    `score` is the last `#` line that is neither `# invalid` nor `# conditions`; `conditions` is
    the parsed `# conditions` record, `{}` for a run written before that line existed.
    """
    rows = {}
    score = ""
    invalid = ""
    conditions = {}
    no_delivery = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("# conditions"):
                conditions = COND.parse(line)
                continue
            if line.startswith("# invalid"):
                invalid = line.strip().lstrip("#").strip()
                continue
            if line.startswith("#"):
                score = line.strip().lstrip("#").strip()  # per-run, reset above
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 5 or parts[0] == "task":
                continue
            rows[parts[0]] = (parts[1], parts[2], parts[3])
            if "finish=None" in parts[4]:
                no_delivery.append(parts[0])
    return rows, score, invalid, no_delivery, conditions


def _runs_and_conditions(root):
    """Every run-*/results.tsv under root, name-sorted, with the invalid flag already resolved."""
    collected = []
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name, "results.tsv")
        if not os.path.isfile(path):
            continue
        rows, score, invalid, no_delivery, conditions = _read_run(path)
        if not invalid and no_delivery:
            # Runs written before run.sh learned to mark themselves: a row whose usage carries
            # `finish=None` is a task the engine never ran, so the run's denominator is not the
            # scoreboard's denominator and its score is not comparable with other runs.
            invalid = (
                f"retroactive: {len(no_delivery)} task(s) delivered no turn (finish=None)"
                f" — e.g. {', '.join(sorted(no_delivery)[:3])}"
            )
        collected.append((name, rows, score, invalid, conditions))
    return collected


def _fingerprint(cond):
    return tuple(sorted((k, v) for k, v in cond.items() if k in COND.KEY_FIELDS))


def _majority(pairs):
    """(the mode fingerprint over the runs that state conditions, how many stated nothing).

    The mode, not the first run: a root is N repeats of one configuration, so the configuration is
    what most of its runs say they played. Ties break on first appearance and callers pass
    name-sorted lists, so the choice is deterministic.
    """
    stated = [_fingerprint(c) for _, c in pairs if c]
    if not stated:
        return None, len(pairs)
    counts = {}
    order = []
    for fp in stated:
        if fp not in counts:
            order.append(fp)
            counts[fp] = 0
        counts[fp] += 1
    return max(order, key=lambda fp: counts[fp]), len(pairs) - len(stated)


def _majority_conditions(root):
    """What the valid, non-empty runs of a root mostly agree they played (None when none speak)."""
    return _majority([
        (name, cond)
        for name, rows, _score, invalid, cond in _runs_and_conditions(root)
        if rows and not invalid
    ])


def _drop_other_games(root, runs, announced):
    """Exclude the runs of this root that played a different game, naming the field that proves it.

    `repeat.sh` averages whatever it finds, so a run whose task file, tool declarations, model,
    temperature, approval policy, concurrency or host differs from the rest of its root is not a
    sample of that configuration — the tasks digest catches the class that already bit here, where
    widening the task set moved a score without the engine changing. A run that states nothing (one
    written before the conditions line existed) is kept: an unknown is not proof of a difference.
    It is counted, though, because the number it joins has to carry that caveat.
    """
    if len(runs) < 2:
        return runs
    majority, unstated = _majority(announced)
    if majority is None:
        return runs
    by_name = dict(announced)
    keep = []
    rejects = []
    for entry in runs:
        cond = by_name.get(entry[0]) or {}
        if not cond:
            keep.append(entry)
            continue
        if _fingerprint(cond) == majority:
            keep.append(entry)
            continue
        diffs = COND.field_diffs(dict(majority), cond)
        rejects.append("%s: %s" % (
            entry[0], ", ".join("%s %s → %s" % (k, a, b) for k, a, b in diffs)))
    if rejects:
        print(f"⚠️  {len(rejects)} run(s) in {root} EXCLUDED — conditions differ from the"
              f" other {len(runs) - len(rejects)} run(s) of this root:", file=sys.stderr)
        for line in rejects:
            print(f"    {line}", file=sys.stderr)
        print("    a run played under other rules is not a sample of this configuration, and the"
              " exclusion is part of the result: quote it with the number", file=sys.stderr)
    if unstated:
        print(f"    {unstated} of {len(runs)} run(s) in {root} state no conditions at all —"
              " kept, so any number averaged with them carries that caveat", file=sys.stderr)
    return keep


def load_runs(root):
    runs = []
    announced = []
    skipped = []
    for name, rows, score, invalid, cond in _runs_and_conditions(root):
        if invalid:
            # An invalid run carries no model signal: averaging it in manufactured a p=0.0032
            # "regression" out of an engine outage on 10-22. Exclude it, loudly.
            skipped.append((name, invalid))
            continue
        if rows:
            runs.append((name, rows, score))
            announced.append((name, cond))
    if skipped:
        print(
            f"⚠️  {len(skipped)} run(s) in {root} EXCLUDED as invalid "
            "(tasks never reached the engine):",
            file=sys.stderr,
        )
        for name, why in skipped:
            print(f"    {name}: {why}", file=sys.stderr)
        if runs:
            print(
                f"    reporting on the {len(runs)} valid run(s) only — the exclusion is part of"
                " the result, quote it with the number",
                file=sys.stderr,
            )
    return _drop_other_games(root, runs, announced)


def mcnemar_exact(b, c):
    """Two-sided exact sign test on discordant pairs (no normal approximation, because b+c is
    small here and the approximation is the part that would lie)."""
    n = b + c
    if n == 0:
        return 1.0
    m = min(b, c)
    tail = sum(math.comb(n, i) for i in range(m + 1)) * (0.5 ** n)
    return min(1.0, 2.0 * tail)


def task_row(runs, task, k):
    """Positional pass/fail per task over the first k runs: a task missing from a run is a fail,
    never a skipped slot — skipping would slide the later runs out of alignment with the other
    configuration and invent pairs that were never measured."""
    return [runs[i][1].get(task, ("", "1"))[1] == "0" for i in range(k)]


def discordance(ra, rb, tasks):
    """(b, c, cells) for McNemar, pairing run i of A with run i of B: one matched pair per cell.

    Deliberately NOT the |A|x|B| cross product: over the product, b-c collapses to
    |B|*(totalA - totalB) identically, so the sign test would weigh k times the evidence it has —
    one run buys one discordance per run on the other side. With 1:1 pairing b+c is bounded by
    tasks*min(|A|,|B|), which is how many comparisons were actually made. What optimism is left
    is within-run clustering (a run's tasks move together), which is why the loop also vetoes
    per-task regressions instead of trusting the pooled p alone.
    """
    k = min(len(ra), len(rb))
    b = c = 0
    for task in tasks:
        pa, pb = task_row(ra, task, k), task_row(rb, task, k)
        b += sum(1 for x, y in zip(pa, pb) if x and not y)
        c += sum(1 for x, y in zip(pa, pb) if y and not x)
    return b, c, len(tasks) * k


def taskset_mismatch(ra, rb):
    """None when both sides were measured over exactly the same task ids; else the refusal text.

    `task_row` books a task missing from a run as a fail, so two sides with different task sets are
    not two measurements of one game: every task absent from the base hands the variant k free
    one-direction cells. Measured on this host — a 21-task base paired with a 30-task variant of an
    unchanged build gave b=6 c=33, McNemar p=0.0000 "SIGNIFICANT". Widening the task set is therefore
    a goal post, and the loop must stop on it rather than report a number.
    """
    a = {t for _, rows, _ in ra for t in rows}
    b = {t for _, rows, _ in rb for t in rows}
    if a == b:
        return None
    diff = ", ".join(sorted(a ^ b)[:8])
    more = " (+%d more)" % (len(a ^ b) - 8) if len(a ^ b) > 8 else ""
    return ("task sets differ: base %d task(s), variant %d, common %d — differing: %s%s. "
            "A task the base never ran is booked as a base fail, so any p from this pairing measures "
            "the task set, not the change. Re-measure both sides over the same task file."
            % (len(a), len(b), len(a & b), diff, more))


def _majority_pair(a_root, b_root):
    ma, _ = _majority_conditions(a_root)
    mb, _ = _majority_conditions(b_root)
    if ma is None or mb is None:
        return None, None
    return dict(ma), dict(mb)


def conditions_mismatch(a_root, b_root):
    """None when both roots agree on every field the loop may not move; else the refusal text.

    `taskset_mismatch` catches a differing set of task ids; this catches the game changing under
    identical ids — another task file, model, temperature, approval policy, concurrency or host.
    Each of those moves a score without the engine changing, which is what a p is meant to
    isolate. The tool declarations are deliberately NOT refused across roots: a proposal may edit
    precisely those contracts, so their movement is `conditions_movement`, stated under the p.
    """
    ma, mb = _majority_pair(a_root, b_root)
    if ma is None or mb is None:
        return None
    diffs = COND.field_diffs(ma, mb, only=COND.INVARIANT_FIELDS)
    if not diffs:
        return None
    return ("conditions differ on %s (%s) — the two sides were played under different rules, so"
            % (", ".join(k for k, _, _ in diffs),
               "; ".join("%s %s vs %s" % (k, a, b) for k, a, b in diffs))
            + " any p from this pairing measures the rules rather than the change")


def conditions_movement(a_root, b_root):
    """What the two sides legitimately differ in, as one quotable line (None when nothing moved).

    A surface field moving is the agent-facing half of a proposal: what the turn was handed changed,
    so the verdict carries *what* changed rather than implying both sides ran one instrument. The
    sentence names the field it is explaining — a tool digest moving is a changed contract, a docs
    digest moving is a changed instruction corpus, and telling a docs A/B that "declarations moved"
    hands the reader the wrong explanation of their own number.
    """
    ma, mb = _majority_pair(a_root, b_root)
    if ma is None or mb is None:
        return None
    diffs = COND.field_diffs(ma, mb, only=COND.SURFACE_FIELDS)
    if not diffs:
        return None
    why = {
        "tools": "the schemas/descriptions the model was handed changed",
        "docs": "the instruction doc injected into every turn changed",
    }
    return "surface moved: %s — %s, so this p is about what the turn was handed, not only the engine" % (
        ", ".join("%s %s vs %s" % (k, a, b) for k, a, b in diffs),
        "; ".join(why.get(k, "%s changed" % k) for k, _, _ in diffs))


def paired(a_root, b_root):
    """McNemar between two configurations, over min(|A|,|B|) positionally matched run pairs.

    Per task and matched run, b = A passed and B failed, c = the reverse. The exact two-sided sign
    test is used because b+c is small and the chi-square approximation is the part that would
    overstate significance. Pooling tasks is deliberate: the same change moves several tasks, and
    each contributes discordance — but the pooled p is only honest when the tasks share one cause,
    which is why the per-task breakdown is printed alongside.
    """
    ra, rb = load_runs(a_root), load_runs(b_root)
    if not ra or not rb:
        print("paired: both roots need run-*/results.tsv (A=%d B=%d)" % (len(ra), len(rb)))
        return 1
    mismatch = taskset_mismatch(ra, rb)
    if mismatch:
        print("paired: %s" % mismatch)
        print("        no p reported — the delta here would be the task set, not the change")
        return 1
    cond = conditions_mismatch(a_root, b_root)
    if cond:
        print("paired: %s" % cond)
        print("        no p reported — the delta here would be the conditions, not the change")
        return 1
    tasks = sorted({t for _, rows, _ in ra + rb for t in rows})
    b, c, cells = discordance(ra, rb, tasks)
    flipped = []
    for t in tasks:
        pa = [rows[t][1] == "0" for _, rows, _ in ra if t in rows]
        pb = [rows[t][1] == "0" for _, rows, _ in rb if t in rows]
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
    print("discordant: b(A-only)=%d c(B-only)=%d of %d matched cell(s) = k%d x %d tasks"
          % (b, c, cells, min(len(ra), len(rb)), n))
    print("            McNemar exact two-sided p=%.4f%s"
          % (p, "  SIGNIFICANT" if p < 0.05 else "  NOT significant"))
    print("tasks that moved: %s" % ("; ".join(flipped) if flipped else "none"))
    moved = conditions_movement(a_root, b_root)
    if moved:
        print("conditions: %s" % moved)
    return 0


def main():
    if len(sys.argv) >= 5 and sys.argv[1] == "--a":
        return paired(sys.argv[2], sys.argv[4])
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    runs = load_runs(root)
    if not runs:
        print("no results.tsv under %s/run-*/ — repeat.sh writes these" % root)
        return 1

    majority, unstated = _majority_conditions(root)
    if majority:
        caveat = "" if not unstated else "  (+%d run(s) stating none)" % unstated
        print("conditions %s%s" % (
            " ".join("%s=%s" % (field, value) for field, value in majority), caveat))
    else:
        print("conditions none stated — this root predates the conditions line, so its number"
              " cannot be attributed to a task set, tool set, model or sampling setting")

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
