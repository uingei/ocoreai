# edit-noop-split-strip — price the merged split by removing it

`2f63a64c` split the 5-word `oldString == newString` refusal into two states (file already
holds the text vs. wrong quote), and the CHANGELOG row that shipped it stated the honest
limit itself: *"the board verdict is next round's autoab row, not this entry's claim."* The
k=1 rerun it carried halved the strike window 3 → 2 — one sample. This patch is the named
round: it strips `2f63a64c`'s FileTools hunk (the file has not moved since), so the variant
is the pre-split shape.

Direction of reading: a **revert with variant-dominated c** says the split paid for its
bytes; a flat pair (b≈c) says the disclosure costs nothing measurable and the merged claim
survives on reasoning alone, which is what the row said it was. A **keep** would strip a
merged disclosure whose `EditMismatchRecoveryTests` are green — the owner's review decides
that, not the loop's default.
