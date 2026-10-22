#!/usr/bin/env python3
# startup-correlation.py — which per-boot fact co-varies with the collapse?
#
# The margin probe says step-1 lands in one of a few discrete logprob regimes and that the
# outcome tracks the regime with zero overlap, but it does not say WHAT sets the regime. Each
# probe log is one cold boot, so the boot's own startup facts can be joined against the outcome
# instead of guessed at. Fields parsed: shader-library path, model load time, system memory
# reading at load, prompt tokens, cached prompt tokens, TTFT.
#
# Honesty rules baked in:
#   • a field "separates" only if the two ranges do not overlap AND each side has n>=3 —
#     otherwise this script would happily report separation on one sample per side;
#   • separating fields are CANDIDATES, not a carrier: this is a post-hoc sweep over ~7 fields,
#     so the multiple-comparisons risk is stated in the output;
#   • every field that does NOT separate is printed too — the exclusion list is the useful part.
#   • `tokens` is compared alongside the timings on purpose. `firstTokenMs` is stamped at the
#     first output chunk and the standard non-stream path emits that chunk when generation
#     completes (`EngineInference.swift:4635`), so it is whole-turn latency, not TTFT: a
#     200-token turn reported firstTokenMs=4671.26 at overallMs=4672.66. Any separation it
#     shows is the token count talking, and this script says so instead of promoting it.
import os
import re
import statistics
import sys

STD = re.compile(
    r"StdTurn: (\S+) fed=\d+ of \d+ divergence=(-?\d+) tokens=(\d+) reason=(\S+) "
    r"upstreamPrompt=(\S+) upstreamCached=(\S+) firstTokenMs=([\d.]+)"
)
LP = re.compile(r"step1 chose '.*?' id=(-?\d+) lp=(-?[\d.]+) rival='.*?' id=(-?\d+)")
LIB = re.compile(r"Metal shader library: (\S+)")
SYSMEM = re.compile(r"System memory: ([\d.]+)GB in use")
LOAD = re.compile(r"loaded \(ready dir\) in (\d+)ms")
FIELDS = ["tokens", "loadMs", "sysMemGB", "promptTokens", "cachedTokens", "firstTokenMs",
          "divergence"]


def to_int(s):
    m = re.match(r"(\d+)", s)
    return int(m.group(1)) if m else None


rows = []
for path in sys.argv[1:]:
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    lib = (LIB.search(text) or [None, None])[1] if LIB.search(text) else None
    mem = SYSMEM.search(text)
    load = LOAD.search(text)
    lp = LP.search(text)
    for m in STD.finditer(text):
        key = m.group(1)
        # arm E/F turns only: session keys "cd-e<N>t" / "cd-f<N>t" — one turn per boot
        if not re.match(r"cd-[ef]\d+t$", key):
            continue
        tokens = int(m.group(3))
        rows.append(
            {
                "arm": key[3],
                "outcome": "C" if tokens <= 1 else "ok",
                "tokens": tokens,
                "lp": float(lp.group(2)) if lp else None,
                "lib": lib,
                "loadMs": int(load.group(1)) if load else None,
                "sysMemGB": float(mem.group(1)) if mem else None,
                "promptTokens": to_int(m.group(5).replace("Optional(", "")),
                "cachedTokens": to_int(m.group(6).replace("Optional(", "")),
                "firstTokenMs": float(m.group(7)),
                "divergence": int(m.group(2)),
            }
        )

collapsed = [r for r in rows if r["outcome"] == "C"]
healthy = [r for r in rows if r["outcome"] != "C"]
print(
    "  G boots parsed=%d (collapsed=%d healthy=%d) lp known=%d"
    % (len(rows), len(collapsed), len(healthy), sum(1 for r in rows if r["lp"] is not None))
)
print("  G distinct step-1 lp: %s" % sorted({round(r["lp"], 4) for r in rows if r["lp"] is not None}))
print("  G metallib paths: %s" % sorted({str(r["lib"]) for r in rows}))


def rng(group, field):
    vals = [r[field] for r in group if r[field] is not None]
    if not vals:
        return None
    return (min(vals), max(vals), statistics.median(vals), len(vals))


names = FIELDS + ["lp"]
spans = {}
seps = []
for field in names:
    c = rng(collapsed, field)
    h = rng(healthy, field)
    spans[field] = (c, h)
    if not c or not h:
        print("  G %-13s collapsed=%s healthy=%s" % (field, c, h))
        continue
    separates = c[3] >= 3 and h[3] >= 3 and (h[0] > c[1] or c[0] > h[1])
    if separates:
        seps.append(field)
    print(
        "  G %-13s collapsed %.4g..%.4g (med %.4g, n=%d) | healthy %.4g..%.4g (med %.4g, n=%d)%s"
        % (field, c[0], c[1], c[2], c[3], h[0], h[1], h[2], h[3], "  <== SEPARATES" if separates else "")
    )

if seps:
    print("  G CANDIDATES (non-overlapping, n>=3 both sides): %s" % ", ".join(seps))
    print(
        "  G CAVEAT: %d fields swept post-hoc on %d boots — a separating field is a lead to test"
        " by toggling it, not a proven carrier." % (len(names), len(rows))
    )
else:
    print("  G NO startup field in this log set separates the outcomes — the carrier is not among them")
