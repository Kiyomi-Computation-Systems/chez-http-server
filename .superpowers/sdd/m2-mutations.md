# M2 — mutation log

Every test in M2 is watched to fail: a single named mutation breaks the
asserted property, the suite goes red, and the mutation is reverted. Recorded
per global-constraints ("a test is finished when it has been watched to fail").
The milestone plan §6 names one mutation per slice; the extras below each
witness a property the slice's suite asserts beside its table.

Platform: Darwin arm64, Chez Scheme 10.4.1 (`tarm64osx`), 2026-09-23.
Library path as in M1 (`src:tests:vendor/chez-libuv/src:vendor/chez-httparse/src:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs:vendor/chez-httparse/test/support/harness`).
Each mutation was one scripted substitution that refused to run unless it
matched the expected number of sites. The suite ran alone (`chez --program`),
and the file was restored and checked byte-identical by sha256 afterwards.

## M2.1 — the vocabulary and the table

Red before green, before any mutation: with no library the suite exited 255
(`Exception: library (http-server connection) not found`); against a skeleton
carrying the vocabulary and a `conn-step` that answered nothing it exited 1
with 27 passes and 35 failures — 31 of the 33 row instances (the two that
passed are the tick guards, whose expected outcome is "nothing happens"), the
fourteen-actions check, and the three fake-shell checks.

| # | suite | mutation | observed |
|---|-------|----------|----------|
| M2.1-A | `tests/test-connection-table.sps` | in `on-write-completed` (`src/http-server/connection.sls`), swap the target states of the two last-completion branches: `'closing` ↔ `'idle` (plan §6's named mutation) | exit 1; 60 passes, 2 failures — exactly `H9` (keep-alive → idle) and `H10` (close-after → closing). The actions were untouched, so each row failed on its state alone |
| M2.1-B | same | the unknown-event branch answers `(values s '())` instead of raising | exit 1; 60 passes, 2 failures — "an unknown event is an assertion violation" and "an event that is not a tagged list is an assertion violation" |
| M2.1-C | same | drop `body-credit` from `conn-step`'s no-op arm, so a vocabulary event has no arm | exit 1; 61 passes, 1 failure — "a vocabulary event is accepted: body-credit" |
| M2.1-D | same | both tick guards read `(if #t` instead of checking the armed kind (2 sites) | exit 1; 60 passes, 2 failures — one instance each of `T4` and `T5`: the guard instances, where nothing is armed. The two firing instances held |
| M2.1-E | same | the `T9` row loses its only instance (the table, which is what the count guards) | exit 1; 60 passes, 1 failure — "design §4.4: all 9 termination and error rows have a test" (the count fell to 8). T9's own assertion disappeared rather than failed, which is why the count exists |
| M2.1-F | same | drop `hand-off` from `conn-actions` | exit 1; 59 passes, 3 failures — the vocabulary list, "no row emits an action outside the vocabulary" (T7's `hand-off`), and "the rows use fourteen of the sixteen actions" |
| M2.1-G | same | delete `make-conn-state`'s phase check | exit 1; 61 passes, 1 failure — "a state outside the nine is refused" |

A is the plan's prediction made exact: exactly the two rows, and nothing else,
which is the evidence that the rows are independent — each is driven from a
synthetic state by one event, so no row passes through another's transition.
B and C are the two arms of the closed event set (0002 item 2: an unknown event
is an assertion violation, a known one never is), witnessed separately as
M1.4 witnessed both arms of the ratchet. D is the guard that gives "past the
deadline" a meaning when deadlines are kinds rather than instants (ledger,
M2.1). E is the plan's "a row with no test fails the lane by being absent
from the coverage count". F is the one place the vocabulary departs from the
plan's "fifteen actions" (ledger, M2.1): the sixteenth is load-bearing.

The fake shell's tick changed shape in this slice, `(tick . now)` →
`(tick now)`. Its clock assertion in `tests/test-fake-shell.sps` was updated
first and watched red (11 passes, 1 failure: "ticks carry the injected clock,
in order"), then `fake-shell-tick!` was changed; the connection suite's
"the fake shell delivers (tick now)" was red for the same reason until then.

All seven reverted; `make test` green afterwards: eleven suites, 157 expected
passes (connection-table 62, corpus-inventory 7, fake-shell 12, flag-pins 8,
headers 9, integration 5, libhtp 11, limits 19, ratchet 7, records 14,
trace-lane 3), exit 0.
