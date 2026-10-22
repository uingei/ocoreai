#!/usr/bin/env python3
"""boot-diff.py — what does the engine DO differently on a collapsed boot?

startup-correlation.py compares per-boot numbers. This compares per-boot *behaviour*: the
ordered sequence of log-line shapes between boot and StdTurn, normalized so that timestamps,
request ids, session ids, token counts and latencies all collapse to the same shape. A shape
that appears in one outcome group and not the other is a structural difference; a shape present
in both is excluded, however suspicious it looks.

Why shapes and not numbers: every numeric field measured so far (loadMs, sysMemGB, promptTokens,
cachedTokens, divergence) overlaps across groups, yet TTFT separates by 20-30x. Either the
cost difference has a cause that shows up as a line in the log, or it has no cause in the log at
all — and the second answer is itself a finding (the instrument is not seeing the thing).

Honesty rules baked in:
  * group sizes floor at n>=3 on both sides before any shape is called a discriminator;
  * shape counts are per-turn, so a multi-turn boot does not outvote a single-turn boot;
  * the script prints how many shapes it considered and how many boots had no StdTurn at all,
    so an empty result cannot pass vacuously.
"""
import collections
import re
import sys

STD = re.compile(
    r"StdTurn: (\S+) fed=\d+ of \d+ divergence=(-?\d+) tokens=(\d+) reason=(\S+)"
)

# Normalize one log line into a shape: strip timestamp, pid, ids, numbers, quoted content.
TS = re.compile(r"^\S+ \S+\s")
PID = re.compile(r"\[\d+:\d+\]")
REQ = re.compile(r"req-[0-9A-F]+")
UUID = re.compile(r"\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b")
HEX = re.compile(r"\b[0-9a-f]{6,}\b")
NUM = re.compile(r"-?\d+(\.\d+)?")
QUOTED = re.compile(r"'[^']*'|\"[^\"]*\"")


def shape(line):
    s = TS.sub("", line)
    s = PID.sub("", s)
    s = REQ.sub("req-X", s)
    s = UUID.sub("uuid", s)
    s = QUOTED.sub("Q", s)
    s = HEX.sub("X", s)
    s = NUM.sub("N", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s[:110]


turns = []
no_turn = 0
logs = 0
for path in sys.argv[1:]:
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    logs += 1
    shapes = []
    saw = False
    for line in lines:
        m = STD.search(line)
        if m:
            key = m.group(1)
            if re.match(r"cd-[ef]\d+t$", key):
                tokens = int(m.group(3))
                turns.append(
                    {
                        "file": path.rsplit("/", 1)[-1],
                        "arm": key[3],
                        "outcome": "collapsed" if tokens <= 1 else "healthy",
                        "prefix": list(shapes),
                    }
                )
                saw = True
            continue
        shapes.append(shape(line))
    if not saw:
        no_turn += 1

groups = collections.defaultdict(list)
for t in turns:
    groups[t["outcome"]].append(t)

print(f"logs={logs} turns={len(turns)} logs_without_cd_turn={no_turn}")
for name, ts in sorted(groups.items()):
    n = len(ts)
    avg = sum(len(t["prefix"]) for t in ts) / n
    print(f"  {name:9s} n={n:3d}  avg_lines_before_stdturn={avg:.1f}")

if len(groups) < 2 or any(len(v) < 3 for v in groups.values()):
    print("INSUFFICIENT: need >=3 turns in both outcome groups")
    sys.exit(0)

collapsed, healthy = groups["collapsed"], groups["healthy"]


def union(ts):
    return collections.Counter(s for t in ts for s in set(t["prefix"]))


c_un, h_un = union(collapsed), union(healthy)
considered = sorted(set(c_un) | set(h_un))
only_c = [s for s in considered if s in c_un and s not in h_un]
only_h = [s for s in considered if s in h_un and s not in c_un]

print(f"\nshapes considered={len(considered)}  only-in-collapsed={len(only_c)}  only-in-healthy={len(only_h)}")


def present(un, n_total):
    return {s: un[s] for s in un}


print("\n--- ONLY IN COLLAPSED -------------------------------------------")
for s in sorted(only_c, key=lambda x: -c_un[x]):
    print(f"  [{c_un[s]}/{len(collapsed)}] {s}")
print("\n--- ONLY IN HEALTHY ---------------------------------------------")
for s in sorted(only_h, key=lambda x: -h_un[s]):
    print(f"  [{h_un[s]}/{len(healthy)}] {s}")

# A shape that only appears once per group at n>4 is likely an idiosyncrasy, not a cause.
print("\n--- SMALL-SAMPLE FILTER -----------------------------------------")
strong_c = [s for s in only_c if c_un[s] >= 3]
strong_h = [s for s in only_h if h_un[s] >= 3]
if not strong_c and not strong_h:
    print("  none: no structural difference survives n>=3 on either side")
for s in strong_c:
    print(f"  COLLAPSED-SIDE [{c_un[s]}/{len(collapsed)}] {s}")
for s in strong_h:
    print(f"  HEALTHY-SIDE   [{h_un[s]}/{len(healthy)}] {s}")

print("\nCAVEAT: post-hoc sweep over", len(considered),
      "shapes; a shape appearing in >=3 of one group by chance is possible."
      "\nCAVEAT: shapes after StdTurn are not examined (the probe runs after the turn).")
