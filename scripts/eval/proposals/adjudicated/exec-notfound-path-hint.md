# exec-notfound-path-hint

Claim: when `exec_command` exits 127, naming the PATH neighbour that exists
(`python3` at its full path) turns "this approach fails" into a re-runnable fact, so the
tasks lost to `python`-vs-`python3` recover without any prompt sentence. Measured face:
the v2 arm of 11-14 lost `make-failing-test-pass` 6/6→0/6 with the wording quoted three
times verbatim ("the `python` command was not found"); README § known-failure has held
this class since 10-22 (`make-third-test-pass`). Pure lookup, nothing executes;
undecidable ⇒ report byte-identical (gated by `ExecNotFoundHintTests`, 8 tests).
