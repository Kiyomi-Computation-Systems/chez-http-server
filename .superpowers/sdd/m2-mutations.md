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

## M2.2 — the head, and the request accumulator

### First step: parser callbacks enter directly

Decision 0002's third amendment, suite `tests/test-connection-entry.sps`.

Red before green, before any mutation: against `main`'s `connection.sls` the
suite exited 255 (`attempt to reference unbound identifier
conn-parser-callbacks`). Against a naive skeleton, `main`'s core plus entry
points that wrap each callback in a tagged list and call `conn-step` (the shape
the amendment turned down), it exited 1 with 18 passes and 9 failures:
- the seven closed-set checks, because M2.1's core answers an unknown callback
  with nothing and never looks at a payload's shape;
- "the first action is the reply", because M2.1 answered a callback with no row
  with no actions at all;
- the allocation check.

Both ways agreed there, as they must when both are the same path.

| # | suites | mutation (`src/http-server/connection.sls`) | observed |
|---|--------|----------|----------|
| M2.2-A | entry, table | `continue` answers a fresh `(list '(reply-parser continue))` instead of the quoted constant | entry exit 1; 29 passes, 1 failure — "a callback whose data the core does not keep allocates nothing". Table green, 62 |
| M2.2-B | entry, table | the tagged path passes a span on as `bv to from` | entry exit 1; 27 passes, 3 failures — one step both ways, and the whole parses of the POST and the chunked POST. The pipelined GETs carry no body, so they held. Table exit 1; 61 passes, 1 failure — `H5` |
| M2.2-C | entry, table | `check-callback` loses its closed-set arm | entry exit 1; 28 passes, 2 failures — an unknown callback, entered directly and as a tagged list. An unknown name given a span was still refused, by the "an event callback carries no span" arm. Table green |
| M2.2-D | entry, table | `check-callback` loses its "a span callback needs its span" arm | entry exit 1; 29 passes, 1 failure — "a span callback without its span is refused, all ten". Table green |
| M2.2-E | entry, table | `on-message-begin`'s reply moves to second place | entry exit 1; 29 passes, 1 failure — "the first action is the reply". Table exit 1; 61 passes, 1 failure — `H2`. Both ways still agreed, since they share the transition |
| M2.2-F | entry, table | `on-chunk-complete` leaves `conn-parser-callbacks` | entry exit 1; 23 passes, 4 failures — the vocabulary list; chez-httparse's parser refusing the binding list, which now has a hole; the chunked POST's replay, refused mid-parse, so its three follow-on checks did not run; and the allocation check, whose `on-chunk-complete` row was refused. Table green |

A is the regression the amendment exists to prevent, and the shape check alone
sees it: M2.1's per-callback lists allocated for callbacks whose data the core
never keeps. B shows why "both ways agree" is a check: a delegation bug in the
tagged path breaks only the rows that keep a span. E shows the converse: a
transition that answers out of order is wrong both ways at once, so the
reply-first check has to exist beside both-ways.

A survivor, measured rather than guessed: on-headers-complete's five fields are
accepted and unused in this step, so a tagged path that passed them in the
wrong order would survive. The head makes them load-bearing.

All six reverted, each restore byte-identical by sha256; `make test` green
afterwards: twelve suites, 187 expected passes (connection-entry 30,
connection-table 62, corpus-inventory 7, fake-shell 12, flag-pins 8, headers 9,
integration 5, libhtp 11, limits 19, ratchet 7, records 14, trace-lane 3),
exit 0.

### Second step: the pure libraries

2026-09-24, Darwin arm64, Chez 10.4.1 (`tarm64osx`). Same method as the first
step: one scripted substitution per mutation, refused unless it matched the
expected number of sites; each suite run alone; the file restored and checked
byte-identical by sha256. The mutations of this step and of the two that follow
it (the head, and the corpus and allocation checks, each its own PR) were run
on a tree with all three applied.

Red before green, before the code each suite tests existed:
- `test-limits.sps` did not load (`attempt to reference unbound identifier
  limits-max-header-value-bytes`).
- `test-span.sps` exited 255 (`library (http-server span) not found`).
- `test-headers.sps` exited 1: 9 passes, the six new span rows failing.
- `test-decisions.sps` exited 255 (`library (http-server decisions) not found`).

`test-records.sps` changed only its example; the record itself is unchanged.

| # | suites | mutation | observed |
|---|--------|----------|----------|
| M2.2-L | decisions | `parser-error-status` answers `invalid-transfer-encoding` 501 whatever its node | exit 1; 10 passes, 2 failures — "at any other node is a 400", and the real `chunked,deflate` request mapping to 400 |
| M2.2-O | limits | `default-limits`' header-field default becomes 8191; `limits-from-environment`'s stays 8192 | exit 1; 21 passes, 2 failures — the default, and "empty env == default-limits, field by field" |
| M2.2-P | span | `make-span` loses its bounds check | exit 1; 10 passes, 4 failures — the four refusals |
| M2.2-Q | headers | a span's bytes are read from 0, not its start | exit 1; 11 passes, 4 failures — four of the six span rows. The two left are the miss and the length check, which reading from 0 does not change |

Q's first run left three span rows green: the fixture's first header started
at offset 0, where ignoring a span's start changes nothing. The fixture now
puts the headers after a request line, so no span starts at 0.

L, O, P and Q reverted, each restore byte-identical by sha256. On this step's
tree alone, `make test` is green: fourteen suites, 225 expected passes
(decisions 12 and span 14 new; limits 23, headers 15 and records 16), exit 0.
