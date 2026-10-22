#!/usr/bin/env python3
# margin-summary.py — one home for the arm E/F verdict logic (rows: boot<TAB>outcome<TAB>probe line).
# argv[1] = rows file, argv[2] = arm label (E pairs margin with outcome; F does it with the disk
# KV cache emptied every boot). The label is a parameter because the two arms must reach the same
# verdict from the same arithmetic — a second copy of this logic is how two arms start disagreeing.
import re
import sys

LABEL = sys.argv[2] if len(sys.argv) > 2 else "E"

STEP = re.compile(
    r"step(\d+) chose '(.*?)' id=(-?\d+) lp=(-?[\d.]+) rival='(.*?)' id=(-?\d+) "
    r"margin=(-?[\d.]+|[-])"
)
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
healthy, collapsed, noprobe = [], [], 0
for _boot, outcome, line in rows:
    steps = {int(m.group(1)): m for m in STEP.finditer(line)}
    if not steps:
        noprobe += 1
        continue
    m1 = steps.get(1)
    m2 = steps.get(2)
    healthy_or_collapsed = collapsed if outcome == "C" else healthy
    healthy_or_collapsed.append(
        (
            float(m1.group(7)) if m1 and m1.group(7) != "-" else None,
            float(m2.group(7)) if m2 and m2.group(7) != "-" else None,
            float(m1.group(4)) if m1 else None,
        )
    )


def fmt(group, idx):
    vals = [g[idx] for g in group if g[idx] is not None]
    if not vals:
        return "n/a"
    return "min=%.4f max=%.4f n=%d" % (min(vals), max(vals), len(vals))


# The outcome is already decided by the first sampled token, so the discriminator is step1's chosen
# logprob: does a process land in one discrete logits regime, or in another?
print(
    "  %s rows=%d (collapsed=%d healthy=%d no-probe=%d)"
    % (LABEL, len(rows), len(collapsed), len(healthy), noprobe)
)
print(
    "  %s step1 margin — collapsed: %s | healthy: %s"
    % (LABEL, fmt(collapsed, 0), fmt(healthy, 0))
)
print(
    "  %s step2 margin — collapsed: %s | healthy: %s"
    % (LABEL, fmt(collapsed, 1), fmt(healthy, 1))
)
c0 = [g[2] for g in collapsed if g[2] is not None]
h0 = [g[2] for g in healthy if g[2] is not None]
print(
    "  %s step1 chosen lp — collapsed: %s | healthy: %s"
    % (LABEL, fmt(collapsed, 2), fmt(healthy, 2))
)
print("  %s distinct step1 lp values: %s" % (LABEL, sorted({round(v, 4) for v in c0 + h0})))

c1 = [g[0] for g in collapsed if g[0] is not None]
h1 = [g[0] for g in healthy if g[0] is not None]
if not c1 or not h1:
    print("  %s VERDICT: INCONCLUSIVE — need both a collapsed and a healthy turn in this run" % LABEL)
elif min(h1) > max(c1):
    print(
        "  %s VERDICT: MARGIN SEPARATES — every healthy turn cleared every collapsed turn"
        " (gap %.4f nats at step1): the near-tie is the decision point" % (LABEL, min(h1) - max(c1))
    )
elif len(c1) >= 3 and len(h1) >= 3 and max(c1) - min(c1) < 1e-3 and max(h1) - min(h1) < 1e-3:
    print(
        "  %s VERDICT: MARGIN IS STABLE WHILE OUTCOME FLIPS — slot ordering is not what flips;"
        " look downstream of the logits (mask / grammar / eos handling)" % LABEL
    )
else:
    print(
        "  %s VERDICT: OVERLAP — collapsed %.4f..%.4f vs healthy %.4f..%.4f at step1 margin;"
        " width does not decide (see the step1 lp split below)"
        % (LABEL, min(c1), max(c1), min(h1), max(h1))
    )

if c0 and h0:
    if min(h0) > max(c0):
        print(
            "  %s VERDICT(2): STEP1 LP SEPARATES — every collapsed turn sits closer to 0 than every"
            " healthy one (gap %.4f nats): the process-level logits regime is the precursor"
            % (LABEL, min(h0) - max(c0))
        )
    elif min(c0) > max(h0):
        print(
            "  %s VERDICT(2): STEP1 LP SEPARATES INVERTED — collapsed turns are the MORE certain"
            " ones (gap %.4f nats): certainty, not a near-tie, precedes the collapse"
            % (LABEL, min(c0) - max(h0))
        )
    else:
        print(
            "  %s VERDICT(2): STEP1 LP OVERLAPS — collapsed %.4f..%.4f vs healthy %.4f..%.4f;"
            " no per-process regime found at step1" % (LABEL, min(c0), max(c0), min(h0), max(h0))
        )
