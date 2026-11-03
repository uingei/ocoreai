# coreai-models fork — window adjudication

The ledger enumerates `Engine/CoreAI*.swift`: 12 files carry Apple's BSD-3 header plus a provenance
line. A window closes with `Adjudicated: <sha>` in the file header plus one row in the window log — one verdict, one
piece of evidence from **our** tree. Unfinished verdicts stay in the § Open list, never an implicit
"nothing to do".

Verdict key — **absorbed**: already in our copy, with the line that proves it. **n/a**: the surface it
changes does not exist here, with the grep that proves it. **open**: it touches something we ship and
somebody owes an action — named. Absorbed and n/a are decisions; open is debt with a face.

## The windows are measured by `make drift`, not typed here

`make drift` prints the live table (our file → upstream counterpart → unread count), deriving the
counterpart from each file's own header. A copy of those numbers here went stale the first time the
mirror moved, so it is gone; the verdict per commit — what no command can recompute — is in
`coreai-fork-window-log.md`.

## Every per-commit verdict lives in `coreai-fork-window-log.md`

Two tables: the closed-window rows and this round's. This file keeps only what no command can recompute
and nothing can re-derive — the rule above and the queue below.

## Open, in the order that pays

The *order* is this list's only claim; each measurement an item rests on lives in its row in the
window log (and in the file that row cites), so nothing is re-typed here.

1. **`f03e8ce` whitespace cap** — closed on the shipping lane by probe 12 §5b; sits behind `cc3c234`
   until a macOS 27 host can read the CoreAI lane.
2. **`cc3c234` Wan asset names** — one read of a bundle's manifest says whether our hardcoded names can
   miss a declared one; port upstream's helper, or stop calling it a risk.
3. **`8623ac6` static-shape slice (~500 L)** — re-sync to upstream's shape, or record the divergence in
   the header with the reason. Leaving it unsaid is the failure mode this file exists to end.
4. **`7359dbc` VLM consolidation** — take it or say why not; ours is bigger than the file it came from.
5. **`2704a69` turn-end stop tokens**, **`9db7476` `language.states`** and **`6a6bb0e` #374's** width-1
   `main` fix — all three settle with one macOS 27 run over the bundles we advertise. Owner-side: a host
   that can import CoreAI.
6. **`7fd2063` includeLogits two-axis shape** — cheap now, expensive after ten more call sites.

## Caveat that outlives any one pass

**n/a must not be read as "not worth it."** The batching family (#335/#367/#377) is a serving
capability we lack wholesale; its cost is ~860 upstream lines plus a scheduler of our own. Every row
here is a one-pass read of one commit against our tree: disagree by changing the row and the
`Adjudicated:` line that closed it, not by arguing in chat.
