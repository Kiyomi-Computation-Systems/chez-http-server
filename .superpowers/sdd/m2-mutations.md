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

### Third step: the head

Red before green: `test-connection-head.sps` exited 255 (`library (http-server
private adapter) not found`) before the head and the adapter existed.

| # | suites | mutation | observed |
|---|--------|----------|----------|
| M2.2-G | head, trace | the adapter passes `flags` as 0, what the parser's reset leaves, instead of reading them in on-headers-complete (replaces the plan's mutation; see the ledger) | head exit 1; 14 passes, 3 failures — the one-request keep-alive rows, pipelined 1.1 and pipelined 1.0: every row that carries a `Connection` header. Trace green |
| M2.2-H | head | on-message-begin does not roll the head | exit 1; 16 passes, 1 failure — pipelined 1.0, whose first message has a header. Pipelined 1.1's first message has none, so that row held |
| M2.2-I | head, trace | a name or value is refused at its limit, not past it (`fx>=?`) | head exit 1; 15 passes, 2 failures — the two at-the-limit rows for names and values. Trace green: no fixture comes near 8,192 |
| M2.2-J | head | the parser's error after a refusal is answered as a parser error | exit 1; 13 passes, 4 failures — the four refusals, answered 400 |
| M2.2-M | decisions, table | `reason-status` answers `handler-failed` 502 | decisions exit 1; 11 passes, 1 failure — the reasons row. Table exit 1; 61 passes, 1 failure — `T6`: the core reads its statuses from the table |
| M2.2-R | head, trace | the adapter answers the core's `fail` with continue | head exit 1; 13 passes, 4 failures — the four refusals. Trace green |

G replaces the plan's mutation, which cannot change a keep-alive answer (the
ledger's "Found and recorded, for the head", measured over the corpus).

G, H, I, J, M and R reverted, each restore byte-identical by sha256. On this
step's tree, `make test` is green: fifteen suites, 241 expected passes
(connection-head 17 new; connection-entry 29, connection-table 62), exit 0.

### Fourth step: the corpus and allocation checks

These two checks were written after the code they measure, so mutation is
their only evidence of failing.

| # | suites | mutation | observed |
|---|--------|----------|----------|
| M2.2-N | trace, head, allocation | the adapter answers on-headers-complete's continue with `skip-body` | trace exit 1; 3 passes, 1 failure — "with the core's bindings installed, every trace still equals its log": 45 of the 135 fixtures mismatched, those with bodies (e.g. `request/connection.md#5` expected its body span and got `message complete`). The plain trace lane held. Head exit 1 — the POST with a body. Allocation green |
| M2.2-H | allocation | on-message-begin does not roll the head (as above) | exit 1; 2 passes, 2 failures — "every request … is served", on both connections: the stale header count passes 100 after 34 requests |
| M2.2-K | allocation, head, entry | a piece in one fragment is copied instead of kept as its span | allocation exit 1; 7 passes, 1 failure — "a 500-byte target and header value cost what short ones do". Head and entry green: no correctness test can see the copy, and the per-callback check only completes empty pieces |

H's first run against the allocation suite ended with a harness error (exit 2):
the refused request raised outside any check. The suite now measures inside a
guard and reports "every request … is served" as a check. K is the pattern the
plan gives M2.3: a performance invariant that no correctness test can
distinguish from correct code is caught only by its shape check.

All twelve reverted, each restore byte-identical by sha256; `make test` green
afterwards: sixteen suites, 250 expected passes (connection-allocation 8,
connection-entry 29, connection-head 17, connection-table 62, corpus-inventory
7, decisions 12, fake-shell 12, flag-pins 8, headers 15, integration 5, libhtp
11, limits 23, ratchet 7, records 16, span 14, trace-lane 4), exit 0.

## M2.3 — the request-target

2026-09-24, Darwin arm64, Chez 10.4.1 (`tarm64osx`). The same discipline: one
literal substitution that must match its expected count, each suite run alone,
the file restored and checked byte-identical by sha256.

### First step: the target's limit (414)

Red before green: the two new rows each failed alone before the code. The
decisions suite's reasons row failed (`target-too-large` has no status), and
the head suite's "a target one byte past it is refused with 414" failed (the
target was accepted). The at-the-limit row passed from the start: it is the
boundary A turns red.

| # | suites | mutation | observed |
|---|--------|----------|----------|
| M2.3-A | head, trace | the target is refused at its limit, not past it (`fx>=?`) | head exit 1; 18 passes, 1 failure — "a target at max-target-bytes passes". Trace green: no fixture's target comes near 8,192 |
| M2.3-B | decisions, head | `reason-status` answers `target-too-large` 431 | decisions exit 1; 11 passes, 1 failure — the reasons row. Head exit 1; 18 passes, 1 failure — the refusal, answered 431 |
| M2.3-C | head | the target is checked against `max-header-field-bytes` | head exit 1; 18 passes, 1 failure — the refusal: the target passes under 8,192 |

A, B and C reverted, each restore byte-identical by sha256. `make test` green
afterwards: sixteen suites, 252 expected passes (connection-head 19), exit 0.

### Second and third steps: the target judge, and the core judging the target (400)

Red before green:
- `test-target.sps` exited 255 before its library existed (`library (http-server target) not found`).
- The decisions suite failed its reasons row: `invalid-target` had no status.
- The head suite failed its five refusal rows. The row "a target of each form passes" held from the start, and it is the boundary that G and N turn red.
- The allocation suite failed its two new shapes. Every workload read 2,624 B: nothing was judged, so nothing was copied or parsed.
- Before the refusals were listed, the trace lane's property 1 failed on exactly the spike's eight fixtures. Each read "adapter refused: no llhttp error number for code invalid-target".

| # | suites | mutation | observed |
|---|--------|----------|----------|
| M2.3-D | allocation, target, head, trace | the judge makes a fresh collector for every absolute-form target (the plan's mutation: "a fresh collector per request instead of resetting one") | allocation exit 1; 9 passes, 1 failure — "an absolute-form target costs one reused collector's parse". Target, head and trace green. As the plan predicted, the allocation assertion is the only red |
| M2.3-E | target, allocation, head, trace | the collector is not reset before a target | target exit 1; 23 passes, 1 failure — "one judge, three absolute-form targets in a row". Allocation exit 1, the same check as D. Head and trace green: none of their connections judges a second absolute-form target |
| M2.3-F | target, head, trace | an origin-form target is judged whole as a path, not split at its first `?` | target exit 1; 19 passes, 5 failures — every row whose target carries a query. Head exit 1; 1 failure — the GET with a query. Trace exit 1 — property 1: the fixtures with queries become refusals |
| M2.3-G | target, head, trace | a part is copied from the delivery's start, not the target's | target exit 1; 21 passes, 3 failures — the rows judged inside a larger bytevector. Head exit 1; 3 failures. Trace exit 1; both property-1 checks |
| M2.3-H | target, head, trace | `*` is accepted with any method | target exit 1; 1 failure — "* with any other method is refused". Head exit 1; 1 failure. Trace exit 1 — the listed `method.md#5` is not refused |
| M2.3-I | target, head, trace | an absolute-form fragment is accepted | target exit 1; 1 failure. Head exit 1; 1 failure. Trace green: the corpus's four fragments are all origin-form, and the charset refuses those |
| M2.3-J | target, head, trace | absolute-form userinfo is accepted | target exit 1; 2 failures — the rule's row and three-in-a-row. Head exit 1; 1 failure. Trace exit 1 — the listed `uri.md#10` is not refused |
| M2.3-K | target, head, trace | CONNECT is not sent to authority-form | target exit 1; 4 failures — every CONNECT refusal answers another code, while host:port still passes, read as a scheme and a path. Head green: a CONNECT with no port is still refused, as `scheme-required`. Trace exit 1 — the corpus's CONNECT targets are refused (in `home_0.netscape.com`, `_` is not a scheme byte) |
| M2.3-L | decisions, head | `reason-status` answers `invalid-target` 431 | decisions exit 1; 1 failure — the reasons row. Head exit 1; 5 failures — the five refusals, answered 431 |
| M2.3-M | head, trace, allocation, table, entry | the core ignores the judge's verdict | head exit 1; 5 failures — every refusal. Trace exit 1 — the listed refusals. Allocation exit 1; 2 failures — no copy and no parse. Table and entry green |
| M2.3-N | trace, head, table, entry, allocation | the core refuses every target | trace exit 1 — every other trace. Head exit 1; 12 failures. Table exit 1; 1 failure — H4, the one row that reaches on-headers-complete. Entry exit 1; 6 failures — the three replays' handler and idle checks. Allocation exit 1; 2 failures — no request is served |

D through N were each reverted, and each restore was byte-identical by sha256. `make test` was green afterwards: seventeen suites, 287 expected passes (target 24, connection-head 25, connection-allocation 10, trace-lane 7), exit 0.

### Fourth step: the narrow redirect (301, decision 0009)

Red before green:
- `test-target.sps` exited 255 (`target-redirect` unbound).
- The decisions suite failed its reasons row: `target-redirect` had no status.
- The head suite failed its two redirect rows, each answered 400. The rows for the POST and for the Location past the limit held from the start: both answers were 400 either way, so they are the boundaries O and T turn red.
- The trace lane failed on the listed `request/uri.md#5`: it was refused as `invalid-target`, not as `target-redirect`.

| # | suites | mutation | observed |
|---|--------|----------|----------|
| M2.3-O | target, head, trace | any method is redirected, not only GET and HEAD | target exit 1; 1 failure — "no other method is redirected". Head exit 1; 1 failure — the POST row. Trace green |
| M2.3-P | target, head, trace | a path that begins `//` is redirected (the open-redirect guard removed) | target exit 1; 1 failure — "a path that begins // is not redirected". Head was green on the first run, so the row "a path that begins // is refused with 400, never redirected off-host" was added. Re-run: head exit 1; 1 failure — that row. Trace green |
| M2.3-Q | target, head, trace | brackets are encoded in the path too | target exit 1; 1 failure — "brackets in a path are not bracket params". Head and trace green |
| M2.3-R | target, head, trace | the encoded target is not judged | target exit 1; 1 failure — "a target with any other fault is not redirected". Head and trace green: the core's listed refusals have nothing to encode. The row "a path that begins /\ is not redirected" was added afterwards, for the browser reading of `\` as `/`. Re-run: target exit 1; 2 failures — that row too |
| M2.3-S | target, head, trace | a target with nothing encoded is redirected to itself | target exit 1; 1 failure — "a target with nothing to encode is not redirected". Head and trace green: the core asks only about refused targets, and those can never redirect to themselves |
| M2.3-T | head, target | the core does not hold the Location to `max-target-bytes` | head exit 1; 1 failure — "one to a target past it is refused with 400". Target green |
| M2.3-U | head | the Location must be under `max-target-bytes`, not within it (`fx<?`) | head exit 1; 1 failure — "a redirect to a target at max-target-bytes is made" |
| M2.3-V | decisions, head, trace | `reason-status` answers `target-redirect` 302 | decisions exit 1; 1 failure — the reasons row. Head exit 1; 2 failures — both redirects. Trace green: it checks the reason, not the status |
| M2.3-W | head, table | the redirect is answered without its Location | head exit 1; 2 failures — both redirects. Table green |
| M2.3-X | head, trace, target | the core refuses what it would redirect | head exit 1; 2 failures — both redirects. Trace exit 1 — the listed `uri.md#5`. Target green |

O through X were each reverted, and each restore was byte-identical by sha256. `make test` was green afterwards: seventeen suites, 303 expected passes (target 35, connection-head 30), exit 0.

### Follow-up: judged in place (uriparse v0.5.0)

Red before green:
- With the pin moved and the copying judge still in place, `test-connection-allocation.sps` failed the three checks that name the target:
  - "a 500-byte target costs what a short one does" (3,136 B against 2,640 B);
  - "a 500-byte target with a query costs what a short one does" (3,152 B);
  - "an absolute-form target costs one reused collector's parse more" (16 B over: the copy of `/a` that an absolute-form request never makes).
- The first-byte row and the strengthened "own bytes" row passed against the copying judge, since any correct judge passes them. AA and Z are the mutations they exist for.

Each mutant ran from a scratch copy of `src/http-server/target.sls` placed first on the library path, against every suite, so the tree was never edited.

| # | suites | mutation | observed |
|---|--------|----------|----------|
| M2.3-Y | target, head, entry, allocation, trace | the path is judged from the delivery's start | target exit 1; 35 passes, 1 failure — "a target is judged by its own bytes, not its delivery's". Head exit 1; 12 failures. Entry exit 1; 6 failures. Allocation exit 1; 2 failures — no request is served. Trace exit 1; 1 failure — every other trace |
| M2.3-Z | target, head, entry, allocation, trace | the path is judged to the delivery's end | target exit 1; 35 passes, 1 failure — the same row, through its new target with no query. Before that target was added, the target suite stayed green. Head exit 1; 11 failures. Entry exit 1; 6 failures. Allocation exit 1; 2 failures. Trace exit 1; 1 failure |
| M2.3-AA | target | the query skips its first byte | target exit 1; 35 passes, 1 failure — "a query's first byte is judged". Every other suite green: no other row, and no corpus fixture, has a bad first query byte |
| M2.3-AB | target, head, allocation, trace | the query is judged to the delivery's end | target exit 1; 1 failure — the "own bytes" row. Head exit 1; 1 failure. Allocation exit 1; 1 failure — a request is not served. Trace exit 1; 1 failure |
| M2.3-AC | target, head, allocation, trace | the "?" test is dropped: the path's first fault is the verdict | target exit 1; 28 passes, 8 failures — the rows whose targets carry a query. Head exit 1; 3 failures. Allocation exit 1; 1 failure. Trace exit 1; both property-1 checks |
| M2.3-AD | allocation | the query is copied before it is judged | allocation exit 1; 10 passes, 1 failure — "a 500-byte target with a query costs what a short one does", at 3,168 B. Every other suite green |
| M2.3-AE | allocation | the path is copied before it is judged | allocation exit 1; 8 passes, 3 failures — both 500-byte targets and the absolute-form check; the CPS workload costs 2,672 B. Every other suite green |

`make test` was green afterwards: seventeen suites, 305 expected passes (target 36, connection-allocation 11), exit 0.

### Empty hosts (2026-09-25)

Red before green:
- test-target.sps failed "an http or https target with no host is refused" and "CONNECT with an empty host is refused".
- The head suite failed its two new rows, each request served instead of refused.
- The boundary row, where another scheme keeps uriparse's verdict, passed before the rule, as it must. AG and AH are its mutations.

Each mutant ran from a scratch copy of `src/http-server/target.sls` placed first on the library path, against every suite.

| # | suites | mutation | observed |
|---|--------|----------|----------|
| M2.3-AF | target | the scheme is compared with its case | target exit 1; 38 passes, 1 failure — "an http or https target with no host is refused", through `HTTP:///x`. Every other suite green |
| M2.3-AG | target | the rule holds for every scheme | target exit 1; 1 failure — "a target of another scheme keeps uriparse's verdict". Every other suite green |
| M2.3-AH | target | a scheme that begins "http" or "https" matches | target exit 1; 1 failure — the same row, through `httpx:///x`. Every other suite green |
| M2.3-AI | target | a missing authority counts as a host | target exit 1; 1 failure — the no-host row, through `http:x` and `http:/x`. Every other suite green |
| M2.3-AJ | target, head | CONNECT's host is not checked | target exit 1; 1 failure — "CONNECT with an empty host is refused". Head exit 1; 31 passes, 1 failure — its CONNECT row |
| M2.3-AK | target, head | an empty host counts as a host | target exit 1; 37 passes, 2 failures — both no-host rows. Head exit 1; 30 passes, 2 failures — both new rows |

`make test` was green afterwards: seventeen suites, 310 expected passes (target 39, connection-head 32), exit 0.

### Host header rules (2026-09-25)

Red before green:
- test-limits.sps exited 255 before the switch existed (`limits-require-host?` unbound), and test-host.sps before the library did.
- The head suite failed its five refusal rows, each request served instead of refused. Its three served rows held: a valid Host, the switch off, and HTTP/1.0 with none. The decisions suite failed its reasons row: `invalid-host` had no status.
- At the wiring, the table's H4 went red, since its head had no Host. So did the trace lane, with the switch still on: 54 fixtures' traces changed and 7 listed fixtures were refused for their Host, 61 in all, the count measured before.
- The allocation lane's 500-byte Host check held from the start, since the value was judged in place from the first; AP is the mutation it exists for.

Each mutant ran from a scratch copy of the mutated file placed first on the library path, against every suite.

| # | suites | mutation | observed |
|---|--------|----------|----------|
| M2.3-AL | host, head | a second Host line is not refused | host exit 1; 9 passes, 2 failures — "the Host name matches in any case", through its two-line case, and "more than one Host is refused". Head exit 1; 1 failure — "two Host lines are refused with 400" |
| M2.3-AM | host, head, trace | the judge ignores the switch | host exit 1; 1 failure — "unless the requirement is off". Head exit 1; 17 passes, 23 failures — every row under `minimal`. Trace exit 1; both property-1 checks, 61 fixtures |
| M2.3-AN | host, head | HTTP/1.0 must send a Host too | host exit 1; 1 failure — "HTTP/1.0 and 0.9 with no Host pass". Head exit 1; 1 failure — "an HTTP/1.0 request with no Host is served" |
| M2.3-AO | host, head | a Host with userinfo is not refused | host exit 1; 1 failure — "a Host with userinfo is refused". Head exit 1; 1 failure — its userinfo row |
| M2.3-AP | allocation | the Host value is copied before it is judged | allocation exit 1; 11 passes, 1 failure — "a 500-byte Host value costs what a short one does"; the CPS workload rose to 2,640 B |
| M2.3-AQ | host, head, entry, allocation, trace | the Host value is judged to its line's end | host exit 1; 4 passes, 7 failures. Head exit 1; 2 failures. Entry exit 1; 6 failures. Allocation exit 1; 2 failures — no request is served. Trace exit 1; both property-1 checks, 23 fixtures |
| M2.3-AR | head, allocation | the Host is judged after the target | head exit 1; 1 failure — "a redirectable target with no Host is refused with 400, not redirected". The allocation lane's absolute-form check also failed, because this mutant judges an accepted target twice |
| M2.3-AS | head, trace | the core ignores the switch | head exit 1; 23 failures. Trace exit 1; both property-1 checks, 61 fixtures |
| M2.3-AT | limits | any value but "false" keeps the requirement on | limits exit 1; 25 passes, 1 failure — "any other Host requirement value is refused" |
| M2.3-AU | trace | the corpus lane runs with the requirement on | trace exit 1; both property-1 checks, 61 fixtures: 54 traces changed, and 7 listed refusals refused for their Host |

`make test` was green afterwards: eighteen suites, 333 expected passes (host 11, connection-head 40, limits 26, connection-allocation 12), exit 0.

## M2.4 — the message loop (2026-09-25)

Each mutant ran from a scratch copy of the mutated file placed first on the library path, against every suite of its step's tree. Each step's tree was a scratch worktree of main at 18e6a46 holding that step's files and the ones below it, with no commits.

### First step: the pending input

Red before green:
- The table's P1 failed before the core kept the rest. Its first instance got no pending input where `(bv 28 40)` was due.
- P1's second instance, a pause at the delivery's end, held, as it must; D is its mutation. P2 and P3 held from the start, since nothing answered an error in `handling` or fed after a close-marked message; E and F are theirs.
- The adapter handing its actions to the shell's queue is a refactor: every suite held, and the allocation lane measured 2,512 B where it had 2,624 B.

| # | suites | mutation | observed |
|---|--------|----------|----------|
| M2.4-A | table | the plan's mutation A: the rest is kept from `parser-result-consumed`, not `-next` | table exit 1; 67 passes, 2 failures — both P1 instances, the rest kept from 18, not 28. Every other suite green; the message-loop suite holds the measured boundary, in the next step |
| M2.4-D | table | a pause at the delivery's end keeps an empty rest | table exit 1; 1 failure — P1's second instance |
| M2.4-E | table | an error result after the pause is answered | table exit 1; 1 failure — P2 |
| M2.4-F | table, head | bytes-arrived feeds in handling, responding and closing | table exit 1; 3 failures — P3's three instances. Head exit 1; 1 failure — "bytes-arrived asks for feed-parser in idle, head and body, not handling" |
| M2.4-I | table | the rest is fed after a close-marked message | table exit 1; 1 failure — H10 |

`make test` was green afterwards: eighteen suites, 340 expected passes (connection-table 69), exit 0.
