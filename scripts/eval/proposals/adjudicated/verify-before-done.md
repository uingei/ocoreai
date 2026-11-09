# verify-before-done

**Claim (one sentence):** making the verify duty operational — "before you say done, verify with a tool" —
instead of report-shaped ("report how you verified") moves the write/repair tasks where the model currently
persists wrong bytes and claims done (board 11-08: `out.txt` missing the suffix, `b.txt` missing `-2`,
`page.py` replaced by an orphan-indented fragment — each answered as success).

**Why this shape:** our own comment at `SystemPromptBuilder.swift:44` says the target models need "a direct
behavioral command, not policy prose"; the report-shaped sentence is policy prose and was not followed. The
clause states the two operational facts: verify with a tool, and a file tool's OK is durability not validity
(the doctrine already at `AGENTS.md` § The surface). Field precedent for the duty itself:
codex `core/gpt_5_2_prompt.md:111` ("Only terminate your turn when you are sure that the problem is solved")
and `:138` (verify with tests once work is complete) — cited, not copied; ours is scoped to the file-tool
OK-is-durability gap this binary has measured.

**Cost stated before the answer:** the clause adds ~150 bytes to every tool-bearing turn's prompt; regressions
on currently-passing frozen tasks land in the same McNemar as the wins. Keep-or-revert is the loop's, not mine.

**VERDICT (11-08, after the answer — ledger `20261108-213000`):** reverted, measured as a clean negative.
k=6 vs k=6 on the frozen set: 28.50 → 28.67 of 52, matched b=17 c=18, exact McNemar p=1.00; moved tasks ran
both directions (fix-index-out-of-range 1/6→6/6 up, copy-with-suffix 3/6→0/6 down); veto clean. The claim
above stands as written; what it bought is the negative itself: **the claim-without-verify failure is not a
missing prompt sentence** — at this model size the duty was already in prose and the board moved nowhere when
it was made operational. The unmeasured first pass (`20261108-172950`) additionally exposed that the loop
cannot judge any binary-changing proposal at all — recorded in `docs/agent/open-items.md`.
