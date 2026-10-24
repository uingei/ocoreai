#!/usr/bin/env python3
"""Self-test for the auto-A/B loop's two judges — no GPU, no build, seconds to run.

The loop proposes, and a proposer that grades its own exam is decoration. So the judges are tested
here, and the interesting assertions are the *attribution* ones: they re-run the same proposal with
the protection list or the allow list swapped, and require the verdict to change accordingly. That
is what makes deleting `tasks-edit-repair.json` from `autoloop-protected.txt` a red test rather
than a silently weaker loop.
"""

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"  # inherited by every subprocess below: a judge read
# from stale bytecode is a judge that passed while the file on disk said otherwise
import _autoab_gate as gate  # noqa: E402
import _ledger_selftest as ledgerdoc  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")
ALLOW = os.path.join(HERE, "autoloop-allow.txt")
PROTECTED = os.path.join(HERE, "autoloop-protected.txt")

REQUIRED_PROTECTED = [
    "scripts/eval/tasks-edit-repair.json",
    "scripts/eval/tasks.json",
    "scripts/eval/_verifier_selftest.py",
    "scripts/eval/_repeat_stats.py",
    "scripts/eval/run.sh",
    "scripts/agents-md-contract.sh",
]


def run_gate(patches, allow=ALLOW, protected=PROTECTED):
    env = dict(os.environ, OCOREAI_AUTOAB_ALLOW=allow, OCOREAI_AUTOAB_PROTECTED=protected)
    proc = subprocess.run(
        [sys.executable, os.path.join(HERE, "_autoab_gate.py"), "check-paths"] + patches,
        capture_output=True, text=True, env=env)
    return proc.returncode, proc.stdout


def synthetic_patch(path):
    fd, patch = tempfile.mkstemp(prefix="ocoreai-autoab-selftest-", suffix=".patch")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1 +1 @@\n-x\n+y\n"
                 % (path, path, path, path))
    return patch


def write_runs(dirs, bits_by_task):
    """A root of k runs of results.tsv, from per-task pass bits — the judges testable without a
    model, and with the discordance (b, c) set on purpose rather than inherited from a score."""
    tasks = sorted(bits_by_task)
    k = len(next(iter(bits_by_task.values())))
    for index in range(k):
        run = os.path.join(dirs, "run-%d" % (index + 1))
        os.makedirs(run, exist_ok=True)
        passes = [t for t in tasks if bits_by_task[t][index] == "1"]
        with open(os.path.join(run, "results.tsv"), "w", encoding="utf-8") as fh:
            fh.write("task\tkind\trc\telapsed_ms\tusage\n")
            for task in tasks:
                fh.write("%s\twrite\t%s\t1\tfinish=stop\n"
                       % (task, "0" if task in passes else "1"))
            fh.write("# score %d/%d  model fake\n" % (len(passes), len(tasks)))
    return dirs


def bits(common_pass="111111", a="100000", b="001100", c="000000"):
    """18 tasks that never fail, three that carry the discordance the judges read."""
    pattern = {"t%02d" % i: common_pass for i in range(1, 19)}
    pattern.update({"taskA": a, "taskB": b, "taskC": c})
    return pattern


def main():
    bad = []
    comment = os.path.join(FIXTURES, "fixture-comment-touch.patch")
    goalpost = os.path.join(FIXTURES, "fixture-goalpost-move.patch")

    # 1 — the allowed fixture passes the gate as configured.
    rc, out = run_gate([comment])
    if rc != 0:
        bad.append("the Sources/-only fixture was refused by the real lists:\n%s" % out)

    # 2 — the verifier-weakening fixture is refused, and refused BY THE PROTECTION LIST: the
    # reason is the assertion, so an entry deleted from autoloop-protected.txt turns this red
    # instead of letting the prefix rule cover it up.
    rc, out = run_gate([goalpost])
    if rc == 0 or "protected goal-post" not in out:
        bad.append("the goal-post fixture was not refused by the protection list (rc=%d):\n%s"
                  % (rc, out))

    # 3 — attribution, both directions: empty the protection list, allow scripts/, and the same
    # patch must now be allowed. Nothing about the patch changed.
    empty = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False)
    empty.write("")
    empty.close()
    allow_scripts = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False)
    allow_scripts.write("scripts/\n")
    allow_scripts.close()
    rc, out = run_gate([goalpost], allow=allow_scripts.name, protected=empty.name)
    if rc != 0:
        bad.append("with the protection list emptied the goal-post fixture was still refused — the"
                  " refusal never came from the list:\n%s" % out)

    # 4 — the allow list gates too: the same Sources/-only fixture, against an allow list that
    # names only docs/, must be refused for the prefix reason.
    allow_docs = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False)
    allow_docs.write("docs/\n")
    allow_docs.close()
    rc, out = run_gate([comment], allow=allow_docs.name)
    if rc == 0 or "outside the allowed prefix" not in out:
        bad.append("the allow list did not gate a Sources/-only patch (rc=%d):\n%s" % (rc, out))

    # 5 — a patch outside the allowed prefix is refused as configured, and a patch naming no file
    # is refused rather than passed.
    readme = synthetic_patch("README.md")
    rc, out = run_gate([readme])
    if rc == 0 or "outside the allowed prefix" not in out:
        bad.append("a README.md patch was not refused (rc=%d):\n%s" % (rc, out))
    nofiles = synthetic_patch("")
    rc, out = run_gate([nofiles])
    if rc == 0:
        bad.append("a patch naming no file was allowed")
    for path in (readme, nofiles):
        os.unlink(path)
    for handle in (empty, allow_scripts, allow_docs):
        os.unlink(handle.name)

    # 6 — the protection list still lists the goal posts.
    listed = gate.read_list(PROTECTED)
    missing = [p for p in REQUIRED_PROTECTED if p not in listed]
    if missing:
        bad.append("autoloop-protected.txt no longer lists: %s" % ", ".join(missing))
    if "Sources/" not in gate.read_list(ALLOW):
        bad.append("autoloop-allow.txt no longer allows Sources/ — the loop can propose nothing")

    # 7 — the decision rule, on fabricated scoreboards. b and c are pinned to the exact cell
    # counts because they ARE the pairing convention: matched 1:1 pairing gives b=0/c=15 for a
    # clean sweep, while the |A|x|B| product reports c=106 for the same data — a p computed from
    # 106 pairs where 126 comparisons were made and only six runs exist.
    base = write_runs(tempfile.mkdtemp(prefix="ocoreai-autoab-base-"), bits())
    same = write_runs(tempfile.mkdtemp(prefix="ocoreai-autoab-same-"), bits())
    better = write_runs(tempfile.mkdtemp(prefix="ocoreai-autoab-better-"),
                        bits(a="111111", b="111111", c="111111"))
    # b=1, c=4 → p=0.375: half a task better, which is exactly what the frozen set's own noise
    # floor (±3.2 tasks at k=1) can produce from a change that does nothing.
    marginal = write_runs(tempfile.mkdtemp(prefix="ocoreai-autoab-marginal-"),
                          bits(a="000000", b="111111"))
    worse_bits = bits()
    for index in range(1, 19):
        worse_bits["t%02d" % index] = "011111"  # every stable task drops one run: no single veto
    worse = write_runs(tempfile.mkdtemp(prefix="ocoreai-autoab-worse-"), worse_bits)
    veto_bits = bits()
    veto_bits["t03"] = "111100"  # a task that never failed at baseline loses two of six
    veto = write_runs(tempfile.mkdtemp(prefix="ocoreai-autoab-veto-"), veto_bits)
    thin = write_runs(tempfile.mkdtemp(prefix="ocoreai-autoab-thin-"),
                      {t: v[:3] for t, v in bits().items()})

    cells = 21 * 6
    cases = [
        ("identical must not be kept", base, same, 1, "revert", 0, 0),
        ("a clean sweep must be kept", base, better, 0, "keep", 0, 15),
        ("+0.5 tasks at p=0.375 must not be kept", base, marginal, 1, "revert", 1, 4),
        ("p<0.05 in the wrong direction must not be kept", base, worse, 2, "revert", 18, 0),
        ("a stable task losing 2 of 6 must veto", base, veto, 2, "revert", 2, 0),
        ("k=3 against k=6 is not measured", base, thin, 3, "not-measured", None, None),
    ]
    for label, a_root, b_root, want_rc, want_decision, want_b, want_c in cases:
        out, rc = gate.decide(a_root, b_root)
        if rc != want_rc or out.get("decision") != want_decision:
            bad.append("%s: got rc=%s decision=%s (%s)"
                      % (label, rc, out.get("decision"), json.dumps(out, sort_keys=True)))
        if want_b is not None and (out.get("b"), out.get("c")) != (want_b, want_c):
            bad.append("%s: discordance is b=%s c=%s, pinned b=%d c=%d — the pairing convention "
                      "changed (%s)" % (label, out.get("b"), out.get("c"), want_b, want_c,
                                       json.dumps(out, sort_keys=True)))
        if want_b is not None and out.get("paired_cells") != cells:
            bad.append("%s: paired_cells=%s, pinned %d (21 tasks x 6 matched runs)"
                     % (label, out.get("paired_cells"), cells))

    # 8 — the knobs are live. The loop reads α and k_min from the environment, and a self-test
    # that only ever calls decide() with defaults would stay green while a shipped override quietly
    # moved the bar, so the marginal variant is run through the CLI twice: at the shipped α it is
    # inside noise, at a loosened α the same bytes are kept.
    def cli(root_a, root_b, **overrides):
        env = dict(os.environ, **overrides)
        proc = subprocess.run(
            [sys.executable, os.path.join(HERE, "_autoab_gate.py"), "decide", root_a, root_b],
            capture_output=True, text=True, env=env)
        return proc.returncode, proc.stdout

    knob_cases = [
        ("CLI at the shipped alpha must revert the marginal variant", base, marginal, {}, 1),
        ("CLI with OCOREAI_AUTOAB_ALPHA=0.99 must keep it (the knob is wired)", base, marginal,
         {"OCOREAI_AUTOAB_ALPHA": "0.99"}, 0),
        ("CLI with OCOREAI_AUTOAB_KMIN=7 must call k=6 not-measured", base, same,
         {"OCOREAI_AUTOAB_KMIN": "7"}, 3),
    ]
    for label, root_a, root_b, overrides, want_rc in knob_cases:
        rc, out = cli(root_a, root_b, **overrides)
        if rc != want_rc:
            bad.append("%s: got rc=%d (%s)" % (label, rc, out.strip().replace("\n", " | ")))

    # 9 — the ledger carries its header, so an empty ledger and a missing one stay different facts.
    ledger = os.path.join(HERE, "autoloop.tsv")
    header = "ts\tproposal\tbase_commit\tvalid_runs\tscores_base\tscores_variant\tb\tc\tp\tdecision\ttraces"
    if not os.path.isfile(ledger) or open(ledger, encoding="utf-8").readline().strip() != header:
        bad.append("autoloop.tsv is missing or its header drifted from the 11 columns the loop writes")

    # 10 — the script that runs the loop is scanned too, because two of its properties live only
    # there: it never runs a destructive git command (this tree carries uncommitted work, and a
    # `git checkout` mid-loop would erase it while the ledger claims a clean revert), and its
    # before/after tree check is scoped to the prefixes the loop may write under — an unrelated
    # file appearing mid-run is not a variant that failed to revert.
    script = open(os.path.join(HERE, "autoab.sh"), encoding="utf-8").read()
    if len(script.splitlines()) < 100:
        bad.append("autoab.sh scan read %d lines — the premises below would pass vacuously"
                   % len(script.splitlines()))
    for forbidden in ("git checkout", "git reset --hard", "git clean"):
        if forbidden in script:
            bad.append("autoab.sh runs `%s` — a reverted variant must be undone by applying the "
                      "patch backwards, never by discarding the tree" % forbidden)
    if 'git status --porcelain > ' in script:
        bad.append("autoab.sh snapshots the whole tree instead of the allowed scope — a file the "
                   "loop cannot write would read as a variant that failed to revert")
    if "tree_state \"$BEFORE\"" not in script or "tree_state \"$AFTER\"" not in script:
        bad.append("autoab.sh no longer snapshots the tree through tree_state at both ends")
    # Same-line, not file-wide: `$ALLOW` appears in the existence check too, so a file-wide test
    # here passed while the scope was hardcoded — a scan must find the line that carries the claim.
    scope_lines = [l for l in script.splitlines() if "SCOPE+=(" in l]
    if not scope_lines:
        bad.append("autoab.sh has no SCOPE+= line at all — the scope check below is vacuous")
    derived = [l for l in scope_lines if '"$ALLOW"' in l]
    if scope_lines and not derived:
        bad.append("autoab.sh builds its write scope without the allow list — scope and gate would "
                   "be two numbers that drift (%s)" % (scope_lines[0].strip()[:90],))

    # 11 — both sides must be the same game. `task_row` books a task missing from a run as a fail,
    # so a wider variant against a narrower base manufactures k one-direction cells per added task.
    # Measured here with real data before the guard existed: a 21-task base against a 30-task
    # variant of an *unchanged* build reported McNemar p=0.0000 "SIGNIFICANT".
    narrow_bits = {k: v for k, v in bits().items() if k != "taskC"}
    narrow = write_runs(tempfile.mkdtemp(prefix="ocoreai-autoab-narrow-"), narrow_bits)
    wide = write_runs(tempfile.mkdtemp(prefix="ocoreai-autoab-wide-"), bits())
    out, rc = gate.decide(narrow, wide)
    if rc != gate.NOT_MEASURED or out.get("decision") != "not-measured" \
            or "task sets differ" not in out.get("why", ""):
        bad.append("a wider variant against a narrower base was judged (%s, rc=%d) instead of "
                  "refused — widening the task set would move the goal posts and report p≈0"
                  % (out.get("decision"), rc))
    stats_src = open(os.path.join(HERE, "_repeat_stats.py"), encoding="utf-8").read()
    if "def taskset_mismatch" not in stats_src:
        bad.append("_repeat_stats.py lost taskset_mismatch — `paired --a/--b` would report a p "
                   "across two different task sets, and this file's guard above would be unenforced")
    if "taskset_mismatch(ra, rb)" not in stats_src:
        bad.append("_repeat_stats.paired() no longer calls the guard — the CLI path and the loop "
                   "path would drift apart, which is the whole thing this repo says not to do")

    bad += ledgerdoc.readme_count_defects("scenarios", len(cases) + len(knob_cases) + 8)
    print("autoab self-test: %d scenario(s), %d defect(s)" % (len(cases) + len(knob_cases) + 8,
                                                               len(bad)))
    for entry in bad:
        print("  FAIL %s" % entry)
    if bad:
        return 1
    print("  ✅ path gate refuses goal-post moves for the recorded reason, the allow list bites"
          " too, discordance is matched 1:1 by run position, and a variant is kept only on a"
          " significant gain in the right direction with no veto — at an alpha the test can move")
    return 0


if __name__ == "__main__":
    sys.exit(main())
