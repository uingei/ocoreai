# verify-rerun-command

problem: claim-without-verify

Claim: binding verification to the command that *showed* the problem — "run that same
command again after your change, only call it fixed if it now succeeds" — keeps the
claim-without-verify gain of `verify-order-before-done` (45:11 discordant on the frozen
set, k=6) without its regression veto, which named two stable-pass tasks that an
unbounded "run it before calling it done" drove into edit-against-own-output storms.
Shape taken from mini-swe-agent's workflow step 4 (`config/mini.yaml`: verify by
re-running the reproduction), narrowed to tasks that actually had a showing command.
