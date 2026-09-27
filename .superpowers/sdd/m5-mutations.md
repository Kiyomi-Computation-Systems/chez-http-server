# M5 — mutation log

Every test in M5 is watched to fail: a single named mutation breaks the
asserted property, the suite goes red, and the mutation is reverted. Recorded
per global-constraints ("a test is finished when it has been watched to fail").
The milestone plan §14 names one mutation per slice; the extras below each
witness a property the slice's suite asserts beside it.

Platform: Darwin arm64, Chez Scheme 10.4.1 (`tarm64osx`), libuv 1.52.1, 2026-09-27.
Library path as in M4
(`src:tests:vendor/chez-libuv/src:vendor/chez-httparse/src:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs:vendor/chez-httparse/test/support/harness:vendor/chez-libuv/tests`).
Each mutant ran from a scratch copy of the mutated file, placed first on the
library path under an absolute root; the substitution had to match exactly
once, and the tree was never edited.

## M5.1, first step — the two limits, and how long each deadline lasts (2026-09-27)

Red before green. First build: `tests/test-limits.sps` stopped at load, exit
255, at its first new name, `limits-write-timeout-ms` (unbound identifier).
After the review, on the owner's decisions: the limits suite stopped at load
at `limits-deadline-ms`, then, with the mapping and no ceiling, failed the
tick's range row alone; the connection-table suite stopped at load at
`conn-deadline-kinds`. (The limits library's two changes were written before
their checks; the checks were then watched red against scratch copies without
them.)

These mutants ran on the first step's own tree, a scratch worktree cut from
main at c14956c, against all of its thirty-five suites, and again on the
finished tree against thirty-six, with the same result. Where a row names no
other suite, the others were green.

| # | mutation (`src/http-server/limits.sls`) | observed |
|---|---|---|
| M5.1-L1 | the write timeout's default moved to 61 s in `default-limits` alone | limits 2 — "write timeout 60 s per completion", and the drift guard, "empty env == default-limits, field by field"; connection-table 1 — "each deadline kind lasts one of the limits: idle 75 s, header, body and write 60 s, linger 30 s" |
| M5.1-L2 | the tick's default moved to 251 ms in `limits-from-environment` alone | limits 1 — the drift guard alone |
| M5.1-L2b | the tick's default moved to 500 ms in `default-limits` alone | limits 2 — "tick 250 ms", and the drift guard |
| M5.1-L3 | the tick read in whole seconds, as the timeouts are | limits 2 — "write 90 s -> 90000 ms; the tick is given in ms: 100 -> 100 ms", and the tick's range row ("a tick of 1 to 1,000 ms is accepted; 0, below 0, over 1,000, or not a number is refused") |
| M5.1-L4 | a tick of 0 ms accepted | limits 1 — the tick's range row |
| M5.1-L5 | the write timeout read from a misspelled variable | limits 1 — the write-and-tick override row |
| M5.1-L6 | `CHEZ_HTTP_TICK_MS` left out of `limits-environment-variables` | limits 1 — "the environment variables, one per field" |
| M5.1-L7 | the write timeout read in milliseconds | limits 1 — the write-and-tick override row |
| M5.1-L8 | the two new defaults swapped in `default-limits` | limits 3 — both defaults' rows, and the drift guard; connection-table 1 — the kinds' durations row |
| M5.1-L9 | the write timeout's field named `write-timeout` | limits 2 — "each deadline kind lasts its own timeout", whose `limits-with` names the field, and "limits-with replaces each field alone, by name" |
| M5.1-L10 | no ceiling on the tick | limits 1 — the tick's range row. Before the review there was no ceiling |
| M5.1-L11 | the tick's ceiling one short, 999 | limits 1 — the tick's range row |
| M5.1-L12 | the tick's minimum 2: a 1 ms tick refused | limits 1 — the tick's range row. Before the review this mutant survived: no row accepted 1 |
| M5.1-L13 | a body deadline lasts the idle timeout | limits 1 — "each deadline kind lasts its own timeout"; connection-table 1 — the kinds' durations row |
| M5.1-L14 | a kind that is not a deadline kind lasts 0 | limits 1 — "a kind the core does not arm has no duration" |
| M5.1-L15 | the tick's ceiling 99, so the override of 100 is refused | limits 2, exit 1 — the write-and-tick override row and the tick's range row. The override is read inside its check, so the refusal is that check's failure; before the review it was read in the suite's shared setup, and a refusal there ended the suite as a harness error |

| # | mutation (`src/http-server/connection.sls`) | observed |
|---|---|---|
| M5.1-K1 | `linger` left out of `conn-deadline-kinds` | connection-table 3 — "five deadline kinds: design §4.3's idle, header, body and write, and decision 0011's linger", "the rows arm all five deadline kinds, and no other", and the kinds' durations row |
| M5.1-K2 | a sixth kind, `drain`, in `conn-deadline-kinds` | connection-table 3 — the same three, the durations row because `drain` has none |

Every check the step added or extended is reddened by one mutant at least: the
limits' rows by L1 to L15, the connection table's three by K1 and K2, and its
durations row also by L1, L8 and L13.
