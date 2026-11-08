# syntax-regression-gate

**Claim (one sentence):** moving the syntax truth before the write — a file that compiles/parses
today is not rewritten into bytes that do not, with the compiler's own line in the refusal — kills
the 11-08 failure class where `edit_lines` replaced a whole valid `page.py` with the orphan fragment
`    return items[:n]`, the same result carried `OK-but-invalid — … py_compile FAILED`,
and the turn two seconds later answered "has been fixed" over a verify_rc=1 artefact.

**Why this shape:** the post-write report is measured-ignored (the incident above is one of six
board tasks that day), and making the duty a prompt sentence measured p=1.00 the same day
(`verify-before-done.md`) — so neither "tell them after" nor "tell them to check" survives contact
with this model size; enforcement before the write is the remaining rung. Refusal doctrine inherited
from this file's own precedents (zero-match stays a refusal; a refusal names the exits that exist
today: fix the text, or a fragment belongs at a new path). Broken→fixed, broken→broken, new files
and undecidable types keep writing exactly as before; the unit pin is byte-exact — the incident's own
bytes replayed (`SyntaxRegressionGateTests`, 15 tests green at the paired base commit).

**Cost stated before the answer:** up to two extra `python3` spawns per `.py` write (pre-check old +
new; the post-write check was already one); the refusal removes broken bytes as a state the loop can
pass through, which is a behaviour change every repair task is exposed to.

**VERDICT (11-08, after the answers — reverted, measured regression on the frozen set):**
matched k=6 vs k=6 against the base root `20261108-213000` (`/tmp/autoab-base-1108`, base commit
bcea3287; the only binary difference is this patch): 28.50 → 26.33 of 52, discordance b=19 c=6 of
312 matched cells, exact McNemar **p=0.0146 in the wrong direction**; one task improved
(`fix-off-by-two` 1/6→5/6), nine moved down; the strict veto rule (base 6/6 → variant ≤4/6) fired on
no task (`fix-key-in-f-string` 6/6→5/6 was closest). An informational k=6 on the 45-task set scored
26.67 mean and a k=1 paired single (30→28) agreed on direction. Durability worked as designed:
**110 broken writes refused across the six frozen-set runs** (attributed per-run via each boot's
bridge log; 13 in the k=1), every one leaving the old bytes on disk — zero silent corruptions on
any gated run. The mechanism the price names: at this model size repair is *repair-by-rewrite through
broken states* — the model rewrites whole files and leans on the next call to fix what the last broke;
refusing the broken step sends it into repeated-identical retries that end in giving up (the
`make-failing-test-pass` answer quoted the refusal verbatim). What would change the verdict is a
recovery payload that converts a refusal into a landing rewrite — nearest-candidate machinery the
field ships (openclaw `edit-diff.ts` getCandidateHint) but which has still never been measured
against this give-up loop. Owner call if durability is ever worth a fixed price: the board says the
current gate costs ≈2.2 tasks/52 per run. Recorded: `docs/agent/open-items.md`, CHANGELOG 11-08.
