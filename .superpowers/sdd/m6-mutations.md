# M6 — mutation log

Every test in M6 is watched to fail: a single named mutation breaks the
asserted property, the suite goes red, and the mutation is reverted. Recorded
per global-constraints ("a test is finished when it has been watched to fail").
The milestone plan §14 names one mutation per slice; the extras below each
witness a property the slice's suites assert beside it.

Platform: Darwin arm64, Chez Scheme 10.4.1 (`tarm64osx`), libuv 1.52.1, 2026-09-28.
Library path as in M5
(`src:tests:vendor/chez-libuv/src:vendor/chez-httparse/src:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs:vendor/chez-httparse/test/support/harness:vendor/chez-libuv/tests`).
Each mutant ran from a scratch copy of the mutated file, placed first on the
library path under an absolute root, or, for a suite program, run from that
root; the substitution had to match exactly once, several edits to one file
applied in turn, and the tree was never edited. A row lists each suite that
went red and its failures; the others were green. "exit 2" is a suite whose
body raised, and "exit 255" one that did not load.

## M6.1, first step — the readers, and brief risk 3's pins (2026-09-28)

Red before green: `tests/test-body.sps` stopped at load, exit 255, with
`(http-server body)` not found, before the library was written. The pins
suite pins a dependency, so it passed as written, and was watched red by its
mutants.

These ran on the first step's own tree, a scratch worktree cut from main at
f21ab76 with the step's files laid in, against all of its thirty-nine
suites.

The plan's mutation (M6.1-PA) first made the pins suite loop for ever:
feeding again from where the read started feeds the same bytes again at
every pause, and the runner stopped it at 600 s. The suite's feed loop is now
capped by iteration count, one feed per byte and one more, and past it notes
that it looped: the two pinned rows fail, and the suite ends.

| # | mutated | mutation | observed |
|---|---|---|---|
| M6.1-PA | `test-pause-pins.sps` | the plan's: the feed after the pause starts where the read started | pause-pins 2 |
| M6.1-PB | `test-pause-pins.sps` | an empty rest is not fed | pause-pins 1 |
| M6.1-BA | `body.sls` | read-body makes a whole reader | body 1 |
| M6.1-BB | `body.sls` | the helper cap is 1,048,575 | body 1 |
| M6.1-BC | `body.sls` | a cap given is ignored | body 2 |
| M6.1-BD | `body.sls` | the whole body is always copied | body 1 |
| M6.1-BE | `body.sls` | a part of a bytevector is never copied | body 1 |
| M6.1-BF | `body.sls` | no piece: the procedure gets #f | body 1 |
| M6.1-BG | `body.sls` | on-end answers a symbol, not the procedure's answer | body 4 |
| M6.1-BH1 | `body.sls` | no check that a reader is made of procedures | body 1 |
| M6.1-BH2 | `body.sls` | no check on the cap | body 1 |
