#!/usr/bin/env python3
"""The two calls the auto-A/B loop is not allowed to improvise.

    check-paths <patch> [patch…]   — may this proposal touch these files at all?
    decide <baseRoot> <variantRoot> — may this difference be called an improvement?

They live apart from `autoab.sh` so `_autoab_selftest.py` can run them with injected lists and
fabricated scoreboards: the rules then have gates that run without a GPU, without a build, and —
for `check-paths` — with a *reason*, which is what makes deleting a protection entry go red
instead of quietly changing which rule fired.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from _repeat_stats import (  # one McNemar, one home
    conditions_mismatch,
    conditions_movement,
    discordance,
    load_runs,
    mcnemar_exact,
    task_row,
    taskset_mismatch,
)

KEEP, NOT_SIGNIFICANT, REGRESSION, NOT_MEASURED = 0, 1, 2, 3


def read_list(path):
    if not path or not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8") as fh:
        return [l.strip() for l in fh if l.strip() and not l.strip().startswith("#")]


def paths_in_patch(text):
    """Every path a unified diff claims to touch, from both sides of every header: a rename that
    escapes an allowed prefix on one side still has to be seen."""
    found = []
    for line in text.splitlines():
        targets = []
        if line.startswith("diff --git "):
            parts = line.split(" ")[2:]
            targets = parts[:2]
        elif line.startswith(("+++ ", "--- ")):
            targets = [line[4:].strip().split("\t")[0]]
        for token in targets:
            path = token[2:] if token.startswith(("a/", "b/")) else token
            if path and path != "/dev/null" and path not in found:
                found.append(path)
    return found


def check_paths(patch_paths, allow, protected):
    """Ordered on purpose: the goal-post list bites first, so a refusal of a harness file is
    attributable to the protection list rather than to the prefix rule that would also catch it."""
    if not patch_paths:
        return [(None, "the patch names no file — a vacuous proposal is refused, not allowed")]
    offenders = []
    for path in patch_paths:
        if path in protected:
            offenders.append((path, "protected goal-post"))
        elif not any(path.startswith(prefix) for prefix in allow):
            offenders.append((path, "outside the allowed prefix"))
    return offenders


def decide(base_root, variant_root, k_min=6, alpha=0.05, veto_drop=2):
    base, variant = load_runs(base_root), load_runs(variant_root)
    out = {
        "base_runs": len(base),
        "variant_runs": len(variant),
        "k_min": k_min,
        "alpha": alpha,
    }
    if len(base) < k_min or len(variant) < k_min:
        out.update(
            decision="not-measured",
            why="a side has fewer than %d valid runs (excluded faults are not a score)" % k_min)
        return out, NOT_MEASURED

    mismatch = taskset_mismatch(base, variant)
    if mismatch:
        # Not a verdict about the proposal: the two sides are different games, so nothing was
        # measured. Re-baseline, then judge.
        out.update(decision="not-measured", why=mismatch)
        return out, NOT_MEASURED

    cond = conditions_mismatch(base_root, variant_root)
    if cond:
        # Same ids, different rules — the conditions line is what makes this decidable at all.
        out.update(decision="not-measured", why=cond)
        return out, NOT_MEASURED

    tasks = sorted({t for _, rows, _ in base + variant for t in rows})
    b, c, cells = discordance(base, variant, tasks)
    regressions = []
    for task in tasks:
        pa, pb = task_row(base, task, len(base)), task_row(variant, task, len(variant))
        # A task that never failed at baseline losing two of its runs is a regression whatever
        # the pooled p says: the aggregate is allowed to hide it, the veto is not.
        if all(pa) and sum(pb) <= len(pb) - veto_drop:
            regressions.append("%s %d/%d->%d/%d" % (task, len(pa), len(pa), sum(pb), len(pb)))

    sa = [sum(1 for t in tasks if rows.get(t, ("", "1"))[1] == "0") for _, rows, _ in base]
    sv = [sum(1 for t in tasks if rows.get(t, ("", "1"))[1] == "0") for _, rows, _ in variant]
    mean_a, mean_v = sum(sa) / len(sa), sum(sv) / len(sv)
    p = mcnemar_exact(b, c)
    out.update(
        tasks=len(tasks),
        scores_base="/".join(map(str, sa)),
        scores_variant="/".join(map(str, sv)),
        mean_base=round(mean_a, 2),
        mean_variant=round(mean_v, 2),
        paired_cells=cells,
        b=b,
        c=c,
        p=round(p, 4),
        regressions=regressions,
    )
    moved = conditions_movement(base_root, variant_root)
    if moved:
        # A "keep" must not read as if only the engine moved: the declarations handed to the
        # model changed too, and the verdict records which ones.
        out["declarations_moved"] = moved
    if regressions:
        out.update(decision="revert", why="regression veto: " + "; ".join(regressions))
        return out, REGRESSION
    if p < alpha and mean_v > mean_a:
        out.update(decision="keep", why="McNemar p=%.4f < %.2f, mean %+.2f tasks, no veto"
                   % (p, alpha, mean_v - mean_a))
        return out, KEEP
    if p < alpha and mean_v < mean_a:
        # Significant and the wrong way round: the sign test alone cannot tell direction, the mean
        # can, and a loop that keeps a significant loss is worse than one that measured nothing.
        out.update(decision="revert", why="significant regression: p=%.4f, mean %+.2f tasks"
                   % (p, mean_v - mean_a))
        return out, REGRESSION
    out.update(
        decision="revert",
        why="inside noise: p=%.4f, mean %+.2f tasks (needs p<%.2f and no regression)"
            % (p, mean_v - mean_a, alpha))
    return out, NOT_SIGNIFICANT


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cmd = argv[0]

    if cmd == "check-paths":
        allow_path = os.environ.get("OCOREAI_AUTOAB_ALLOW", os.path.join(HERE, "autoloop-allow.txt"))
        protected_path = os.environ.get(
            "OCOREAI_AUTOAB_PROTECTED", os.path.join(HERE, "autoloop-protected.txt"))
        allow, protected = read_list(allow_path), read_list(protected_path)
        offenders, all_paths = [], []
        for patch in argv[1:]:
            with open(patch, encoding="utf-8", errors="replace") as fh:
                patch_paths = paths_in_patch(fh.read())
            all_paths += [p for p in patch_paths if p not in all_paths]
            offenders += check_paths(patch_paths, allow, protected)
        print("check-paths allow=%s protected=%d path(s)" % (
            ",".join(allow) or "<empty>", len(protected)))
        for path, reason in offenders:
            print("  ❌ %s — %s" % (path or "<no file header>", reason))
        if offenders:
            print("  refused: %d offender(s); nothing was applied" % len(offenders))
            return 1
        print("  ✅ allowed: %s" % ", ".join(all_paths))
        return 0

    if cmd == "decide":
        if len(argv) < 3:
            print("usage: _autoab_gate.py decide <baseRoot> <variantRoot>", file=sys.stderr)
            return 2
        k_min = int(os.environ.get("OCOREAI_AUTOAB_KMIN", "6"))
        alpha = float(os.environ.get("OCOREAI_AUTOAB_ALPHA", "0.05"))
        out, rc = decide(argv[1], argv[2], k_min=k_min, alpha=alpha)
        print(json.dumps(out, sort_keys=True))
        print("  %s — %s" % (out["decision"].upper(), out["why"]))
        return rc

    print("unknown command: %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
