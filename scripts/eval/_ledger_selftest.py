#!/usr/bin/env python3
"""Re-derive the B / B′ ledger in this directory's README from the digits printed beside it.

Why: the ledger is the record every resolution claim cites, and it drifted the round it grew — the
table row said B′ = 14 while the paragraph under it still said "short of target". So each row is
recomputed from its own cells (scores → mean, mean/tasks → pp, pass + fail + critical → total), the
task counts must grow down the table, B must not move while α and k are goal posts, and the prose
"B′ went …" sentence must be a subsequence of the B′ column that ends on the newest row.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
README = os.path.join(HERE, "README.md")
FLOOR_ROWS = int(os.environ.get("OCOREAI_LEDGER_FLOOR_ROWS", "6"))


def rows_from(text):
    """The ledger table as cells, plus k read from its header."""
    lines = text.split("\n")
    header = next((i for i, l in enumerate(lines) if "B′** (tasks)" in l), None)
    if header is None:
        return None, None
    k_match = re.search(r"k\s*=\s*(\d+)", lines[header])
    k = int(k_match.group(1)) if k_match else 6
    rows = []
    for line in lines[header + 2:]:
        if not line.lstrip().startswith("|"):
            break
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        rows.append(cells)
    return rows, k


def readme_count_defects(noun, n):
    """README states how many scenarios/mutations/rows each instrument runs. Every such number in the
    file must equal what actually ran: a self-reported count nobody re-checks is the same drift class
    as a stale B′, and two of them went stale in one round here."""
    try:
        with open(README, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        return ["FAIL %s unreadable, so its %s count cannot be checked (%s)" % (README, noun, exc)]
    claims = [int(c) for c in re.findall(r"(\d+)\s+%s\b" % noun, text)]
    if not claims:
        return []
    stale = sorted({c for c in claims if c != n})
    if stale:
        return ["FAIL README claims %s of %s, but the instrument ran %d"
                % (" / ".join(map(str, stale)), noun, n)]
    return []


def check():
    defects = []
    with open(README, encoding="utf-8") as fh:
        text = fh.read()

    rows, k = rows_from(text)
    if not rows:
        return ["FAIL the ledger table was found but has zero data rows — the scan is vacuous"], 0
    if len(rows) < FLOOR_ROWS:
        return ["FAIL only %d ledger row(s) parsed (floor %d) — a regex that stopped matching "
                "must fail, not pass quietly" % (len(rows), FLOOR_ROWS)], 0

    crits, sizes, bs = [], [], []
    for i, cells in enumerate(rows):
        label = "row %d (%s)" % (i + 1, cells[0] if cells else "?")
        if len(cells) != 9:
            defects.append("FAIL %s: %d column(s), the ledger has 9" % (label, len(cells)))
            continue
        size_m = re.search(r"(\d+)\s+task", cells[0])
        if not size_m:
            defects.append("FAIL %s: no task count in column 1" % label)
            continue
        m = int(size_m.group(1))
        scores = [int(s) for s in re.findall(r"\d+", cells[1])]
        if len(scores) != k:
            defects.append("FAIL %s: %d score(s), header says k=%d" % (label, len(scores), k))
            continue
        mean_m = re.search(r"([\d.]+)\s*\(\s*([\d.]+)%\s*\)", cells[2])
        if not mean_m:
            defects.append("FAIL %s: mean cell %r is not `N (P%%)`" % (label, cells[2]))
            continue
        mean, pp = float(mean_m.group(1)), float(mean_m.group(2))
        if abs(mean - sum(scores) / k) > 0.005:
            defects.append("FAIL %s: mean %s, but %s / %d = %.2f"
                          % (label, mean, "+".join(map(str, scores)), k, sum(scores) / k))
        if abs(pp - 100.0 * (sum(scores) / k) / m) > 0.05:
            defects.append("FAIL %s: %s%% of %d tasks, but the scores give %.1f%%"
                          % (label, pp, m, 100.0 * (sum(scores) / k) / m))
        crit_m = re.search(r"(\d+)\s*/\s*(\d+)", cells[6].strip("*"))
        stab_m = re.search(r"(\d+)\s*/\s*(\d+)", cells[7])
        if not crit_m or not stab_m:
            defects.append("FAIL %s: B′ %r or stable-pass/fail %r unparseable"
                          % (label, cells[6], cells[7]))
            continue
        crit, denom = int(crit_m.group(1)), int(crit_m.group(2))
        passed, failed = int(stab_m.group(1)), int(stab_m.group(2))
        if denom != m:
            defects.append("FAIL %s: B′ is over %d tasks, the row is a %d-task set"
                          % (label, denom, m))
        if passed + failed + crit != m:
            defects.append("FAIL %s: stable-pass %d + stable-fail %d + critical %d = %d, not %d"
                          % (label, passed, failed, crit, passed + failed + crit, m))
        bs.append(int(re.search(r"\d+", cells[5]).group(0)))
        crits.append(crit)
        sizes.append(m)

    if len(set(bs)) > 1:
        defects.append("FAIL B moved across the ledger (%s) while α, k and the 1:1 pairing are goal posts"
                      % " → ".join(map(str, bs)))
    if sizes != sorted(set(sizes)) or len(set(sizes)) != len(sizes):
        defects.append("FAIL the frozen set did not grow monotonically: %s" % sizes)

    defects += readme_count_defects("ledger rows", len(rows))

    seqs = re.findall(r"B′ went ([0-9 →\*]+)", text)
    if not seqs:
        defects.append("FAIL no `B′ went …` sentence matched — the prose premise of this check is gone")
    for seq in seqs:
        vals = [int(v) for v in re.findall(r"\d+", seq)]
        it = iter(crits)
        if not vals or not all(any(v == c for c in it) for v in vals):
            defects.append("FAIL `B′ went %s` is not a subsequence of the column (%s)"
                          % (seq.strip(), " → ".join(map(str, crits))))
        elif vals[-1] != crits[-1]:
            defects.append("FAIL `B′ went %s` ends at %d, the newest ledger row says %d"
                          % (seq.strip(), vals[-1], crits[-1]))

    return defects, len(rows)


def main():
    defects, n = check()
    for d in defects:
        print(d)
    print("ledger self-test: %d row(s) re-derived, %d defect(s)" % (n, len(defects)))
    if defects:
        return 1
    print("  ✅ every row's mean, percentage and stable-pass + stable-fail + critical = total follow from "
          "its own digits, the set grows monotonically, B never moved, and the prose B′ sequence ends on "
          "the newest row — at a floor the scan can miss")
    return 0


if __name__ == "__main__":
    sys.exit(main())
