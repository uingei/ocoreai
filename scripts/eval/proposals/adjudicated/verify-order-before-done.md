# verify-order-before-done

Claim: adding an ordering clause to `toolActionDirective` — run the change with
`exec_command` before calling it finished, because a file tool's `OK` only means the
bytes were saved — moves the multi-step claim-without-verify face: stably-failing board
tasks (`fix-wrong-key-decoy`, `fix-off-by-one-slice`, `multi-step-two-derived-writes`,
11-14 run) dispatched 3–4 edit/read calls, zero `exec_command`, and declared done over a
workspace the verifier rejected. Reporting ("how you verified it") was already demanded;
the missing verb was *before*.
