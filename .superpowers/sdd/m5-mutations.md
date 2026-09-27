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

## M5.1, second step — the wheel (2026-09-27)

Red before green, twice. First build: `tests/test-wheel.sps` stopped at load,
exit 255, "library (http-server wheel) not found". After the review, the
rewritten suite stopped at load against the first wheel, at
`make-wheel-entry`.

Every mutant below ran against every suite of the finished tree, thirty-six
(`test-exports.sps` loads every library under `src/http-server/`, the wheel
included, so no suite could be left out on the ground that it does not import
the mutated library). Where a row names no other suite, the other thirty-five
were green. Mutant W first ran with an extra closing paren, did not load
("missing definition for multiple exports"), and reddened the wheel suite at
load and the exports suite; it was corrected and ran again, and its row is the
second run.

| # | mutation (`src/http-server/wheel.sls`) | observed |
|---|---|---|
| M5.1-A | the plan's: a deadline rounds down to its bucket's start, stored so when armed | wheel 5 — the two firing rows ("a deadline fires at the first tick at or after it, never before: ticks on bucket boundaries", "and with ticks between bucket boundaries"), the interval row ("every deadline from 1000 to 3000 ms fires once, within [D, D + 250) of it, for ticks at three phases"), "within one bucket, the earlier deadline fires first", which the rounding makes a tie, and the plain-list row. Every other suite green (35) |
| M5.1-A2 | a deadline fires once its bucket starts, compared so at the advance | wheel 4 — the two firing rows, the interval row, and the plain-list row |
| M5.1-B | every entry in a visited ring fires: by bucket, not by deadline | wheel 6 — the two firing rows, the interval row, "a deadline a revolution ahead, in the same slot, waits for its own time", the forty-deadline row ("one advance past forty deadlines over five revolutions fires those due, earliest first, and keeps the rest"), and the plain-list row |
| M5.1-C | a deadline whose bucket has passed kept in that bucket's ring, not the cursor's | wheel 2 — "a deadline already past when armed fires at the next advance", and the plain-list row |
| M5.1-D | a disarm does nothing | wheel 5 — the disarm row ("a disarmed deadline never fires, and disarming an entry not armed changes nothing"), the entry-deadline row, the count row, the holding row ("an entry the caller keeps, disarmed or fired, holds nothing of the wheel; one still armed is held"), and the plain-list row |
| M5.1-D2 | an unlinked entry keeps its links | wheel 4 — the entry-deadline row, the count row, the holding row, and the plain-list row |
| M5.1-D3 | an unlink does not count down | wheel 4 — the count row ("the count is how many entries are armed, 0 once the last fires: the shell's cue to stop its timer"), the holding row, the forty-deadline row, and the plain-list row |
| M5.1-E | a fired entry left in its ring | wheel 13 — the two firing rows, the interval row, the past-deadline row, "a deadline fires once; armed again, the entry fires again", the disarm, moving, entry-deadline, count and holding rows, the revolution row, the forty-deadline row, and the plain-list row |
| M5.1-E2 | a link does not count up | wheel 5 — the count row, the holding row, the forty-deadline row, the plain-list row, and "a refused arm leaves the entry and the count as they were" |
| M5.1-F | arming an armed entry again changes its deadline but leaves it in its ring | wheel 3 — "arming an entry again moves its one deadline, later or earlier", "equal deadlines fire in the order they were last armed", and the plain-list row |
| M5.1-G | an advance stops short of now's bucket | wheel 14 — the two firing rows, the interval row, "instants start at 0: a deadline at 0 fires at an advance to 0", the past-deadline, firing-once, disarm, moving, entry-deadline, count and holding rows, the equal-deadlines row, the revolution row, and the plain-list row |
| M5.1-H | a long jump visits one slot too few | wheel 2 — the forty-deadline row, and the plain-list row. Its default-slot run (tick 250, 512 slots) now makes 357 arms a revolution ahead and 176 advances over 512 buckets (a scratch count), where the first generator's, capped at 32,767, made none |
| M5.1-I | what fires is not sorted: ring by ring, in arming order | wheel 3 — "within one bucket, the earlier deadline fires first, whichever was armed first", the forty-deadline row, and the plain-list row |
| M5.1-J | what fires sorted from the collection reversed | wheel 2 — the equal-deadlines row, and the plain-list row |
| M5.1-K | a ring puts a new entry first | wheel 2 — the equal-deadlines row, and the plain-list row |
| M5.1-M | an entry's deadline read while it is not armed | wheel 3 — the entry-deadline row ("an entry's deadline reads as armed, and #f before it is armed and once it fires or is disarmed"), the holding row, and the plain-list row |
| M5.1-W | the slot's `mod` dropped: a bucket past the last slot indexes past the vector, so arming raises | wheel 3, exit 1 — the revolution row, the forty-deadline row and the plain-list row. The forty-deadline row arms inside its check, so the raise is its failure, not the suite's harness error |
| M5.1-P1 | a tick that is not a whole number above 0 accepted | wheel 1 — the refusal row ("a tick or slot count that is not a whole number above 0, an instant that is not a whole number of ms from 0, or what is not an entry, is refused by the procedure it is given to") |
| M5.1-P2 | a slot count that is not a whole number above 0 accepted | wheel 1 — the refusal row |
| M5.1-P3 | a deadline that is not a whole number from 0 accepted | wheel 2 — the refusal row, and "a refused arm leaves the entry and the count as they were" |
| M5.1-P4 | a now that is not a whole number from 0 accepted | wheel 1 — the refusal row |
| M5.1-P5 | a tick's least is 0 | wheel 1 — the refusal row |
| M5.1-P6 | the exactness test dropped: 1000.0 accepted | wheel 2 — the refusal row, whose arm at 1000.0 is now refused by `vector-ref`, not `wheel-arm!`, and "a refused arm leaves the entry and the count as they were". Before the review this mutant survived: the row accepted a refusal by any procedure |
| M5.1-P7 | an advance to 0 refused | wheel 1 — "instants start at 0: a deadline at 0 fires at an advance to 0". Before the review it survived: no row advanced to 0 |
| M5.1-P8 | arming what is not an entry not refused by `wheel-arm!` | wheel 1 — the refusal row, the raise now `entry-next`'s |
| M5.1-P9 | disarming what is not an entry not refused by `wheel-disarm!` | wheel 1 — the refusal row |
| M5.1-P10 | reading the deadline of what is not an entry not refused by `wheel-entry-deadline` | wheel 1 — the refusal row |
| M5.1-R | a refused arm has already disarmed: the deadline checked after the unlink | wheel 1 — "a refused arm leaves the entry and the count as they were" |
| M5.1-N | the cursor never saved | **survives**, every suite green — a scope statement, measured. With the cursor at 0, an advance visits the slots from bucket 0 to now's, all 512 of them at instants of uv_now's scale, so it still meets every due deadline and fires the same keys: only the work differs. Measured (`wheel-cost2.sps`, scratch, two runs): 10,000 entries, deadlines spread over 75 s, an advance every 250 ms until all fired, 301 advances. Twenty times over, the advances took 12 and 13 ms of CPU with the cursor, 157 and 161 ms without: about 2 µs an advance against 26 µs. Each run allocated the same 807,200 B. The suite checks what fires, not how many slots an advance visits |

Every check the step added is reddened by one mutant at least:
- the firing rows and the interval row by A, A2, B, E and G;
- the row at 0 by G and P7;
- the past deadline by C, E and G;
- firing once by E and G;
- disarming by D, E and G;
- moving by E, F and G;
- the entry-deadline row by D, D2, E, G and M;
- the count row by D, D2, D3, E, E2 and G;
- the holding row by D, D2, D3, E, E2, G and M;
- the order within a bucket by A and I;
- equal deadlines by F, G, J and K;
- the revolution row by B, E, G and W;
- the forty-deadline row by B, D3, E, E2, H, I and W;
- the plain-list row by every wheel mutant but N and those of P and R: A, A2, B, C, D, D2, D3, E, E2, F, G, H, I, J, K, M and W;
- the refusal row by P1 to P6 and P8 to P10;
- the refused arm by E2, P3, P6 and R.

## M5.2 — every deadline the core arms has its tick row (2026-09-27)

Red before green, first build: the tests edited, the core as on main at 2dbef93.
- connection-table 21:
  - T1 (3), T2 (7), T5, T7 (2), L2 and L3, which now disarm first;
  - D1's first instance and D2's first two;
  - "after every row, the state records the deadline its actions leave armed", with thirteen strays, every row that closed or handed off with a kind recorded;
  - the moves-on check, where `(body body)` and `(responding write)` stayed put;
  - and the fake shell's idle close.
- decisions 1: the reason table, raised at `body-timeout`.
- connection-originated 18: every row, whose staged close now ends with the disarm, and "every row's reason is one of them, or a parser error", since `body-timeout` was not a reason yet.
- connection-linger 7: every row that closes.
- connection-deadlines 4: idle, body, write and linger. The header row and the kinds' check passed, since the header deadline already had its row.

Red before green, the review's fixes (`/code-review high`, 2026-09-27): the tests edited, the core as built above. connection-table 7:
- D2's first two, now logged;
- D3, draining's carried idle deadline, with no row;
- D4's two, a tick that left its kind recorded;
- the state-and-actions check, whose three strays were D3's and D4's ticks: at a tick the wheel holds nothing;
- the moves-on check, which now reads every state a row leaves and found `(draining idle)`.

connection-deadlines 1: the write row, not logged. The first run of D1's two instances failed too, but the fault was the test's: `ticked` read the state's deadline in an argument to `append`, which Chez evaluated before the step. It now binds the step first, as `kept` does. D1 then passed on the old core, as it should, since the core already framed the 408 for the request in flight.

Every mutant below ran against all thirty-seven suites of the finished tree. Where a row names no other suite, the others were green. The runner prints eight FAIL lines a suite at most; E's and M's longer lists were run by hand. The first build's twenty mutants, A to U, ran twice before the review with the same results, but for R's label (below). Every one was written again for the fixed `on-tick` and run once more.

| # | mutation (`src/http-server/connection.sls` unless named) | observed |
|---|---|---|
| M5.2-A | the plan's: the write row removed | connection-table 3 — D2's first two instances, and "each deadline a row leaves armed, ticked in the state it leaves, moves the connection on"; connection-deadlines 1 — the write row. A write that never completes keeps the connection open |
| M5.2-B | the body row removed | connection-table 3 — D1's two instances with the body deadline, and the moves-on check; connection-deadlines 1 — the body row; connection-originated 1 — "408: a body still unfinished when the body deadline passes" |
| M5.2-C | the body row's guard removed: a tick in `body` answers 408 whatever was recorded | connection-table 1 — D1's guard instance |
| M5.2-D | the write row's guard removed | connection-table 1 — D2's guard instance |
| M5.2-E | a close emits no disarm, as before M5.2 | connection-table 18 — T1 (3), T2 (7), T5, L2, L3, D2's first two, D3, the state-and-actions check, and the fake shell's idle close; connection-originated 17, every row; connection-linger 7, every row that closes; connection-deadlines 3 — idle, write and linger |
| M5.2-F | the hand-off emits no disarm, as before M5.2 | connection-table 3 — T7 (2) and the state-and-actions check |
| M5.2-G | the body row answers for the header deadline | connection-table 2 — D1's two, their close-after `header-timeout`; connection-deadlines 1 and connection-originated 1, the body rows |
| M5.2-H | `body-timeout` answered 400 (`src/http-server/decisions.sls`) | decisions 1 — "each reason the core closes with after a response, and its status"; connection-table 2 — D1's two; connection-deadlines 1 and connection-originated 1, the body rows |
| M5.2-I | the write row closes for the reason the connection would have closed for after its response | connection-table 1 — D2's second instance, a 408 still being written |
| M5.2-J | the write row closes in stages, lingering, as a close after a response does | connection-table 3 — D2's first two and the moves-on check; connection-deadlines 1 — the write row |
| M5.2-K | the write deadline answered 408, a status of its own (both files) | decisions 1 — "a reason with no originated response is refused"; connection-originated 1 — "every reason the core originates a response for has a row"; connection-table 3 — D2's first two and the moves-on check; connection-deadlines 1 — the write row |
| M5.2-L | a close disarms only when a deadline is armed | connection-table 8 — T2's two instances with none armed, `handling` and `draining`, and every close a tick makes: T5, L3, D2's first two, D3 and the fake shell's idle close, since a tick clears the record before it closes; connection-linger 2 — the linger deadline's two closes; connection-deadlines 3 — idle, write and linger |
| M5.2-M | a close disarms after the close, not before | as E, less the state-and-actions check, which the order does not change: connection-table 17, connection-originated 17, connection-linger 7, connection-deadlines 3 |
| M5.2-N | the keep-alive completion arms the idle deadline without recording it | connection-table 2 — the state-and-actions check, and the moves-on check, which gains `(idle write idle)`; connection-deadlines 1 — the idle row, whose tick meets a state still recording the write deadline |
| M5.2-O | a row arms a deadline no tick row acts on: the shutdown from `idle` arms the write deadline in `draining` | connection-table 2 — T8, and the moves-on check, which gains `(draining write draining)` |
| M5.2-Q | the deadlines suite loses its linger row (`tests/test-connection-deadlines.sps`) | connection-deadlines 1 — "a row for each kind of deadline the core arms, in order" |
| M5.2-R | the table's D4 row loses its instances (`tests/test-connection-table.sps`) | connection-table 1 — "M5.2: all 4 tick rows have a test". Before the counts moved, the same kind of failure printed under a row's name (below) |
| M5.2-S | a linger row built from a state that raises (`tests/test-connection-table.sps`) | connection-table 1 — "M3.5: all 4 linger rows have a test", exit 1: the group's rows never ran, its count is `'raised`, and the error port reads "RAISED building the linger rows: Exception in make-conn-state: not a connection state with irritant no-such-state" |
| M5.2-T | no row arms the linger deadline: the staged close arms the idle one | connection-table 5 — H10 (2), W3's second instance, "the rows arm all five deadline kinds, and no other", and the moves-on check; connection-originated 17, connection-linger 6, and connection-deadlines 3 (header, body and linger), every staged close |
| M5.2-U | the header deadline's row removed | connection-table 3 — T4, W1's 408, and the moves-on check; connection-deadlines 1 — the header row; connection-originated 1 — "408: a head still unfinished when the header deadline passes" |
| M5.2-V | the write deadline's close is not logged | connection-table 2 — D2's first two; connection-deadlines 1 — the write row |
| M5.2-W | the draining row removed: only `idle` acts on the idle deadline | connection-table 2 — D3, and the moves-on check, where `(draining idle)` stays put |
| M5.2-X | a tick keeps the kind it found recorded | connection-table 4 — D4 (2), the state-and-actions check, and the moves-on check, which gains `(handling idle handling)` and `(head body head)` |
| M5.2-Y | the body row answers as though no request were in flight | connection-table 1 — D1's HEAD instance, which gains a `Content-Length: 0`. The POST's 408 frames the same either way |
| M5.2-Z | the body deadline lasts the idle timeout (`src/http-server/limits.sls`, `limits-deadline-ms`) | limits 1 — "each deadline kind lasts its own timeout"; connection-table 1 — "each deadline kind lasts one of the limits: idle 75 s, header, body and write 60 s, linger 30 s"; connection-deadlines 1 — the body row, ticked at 75,000 |
| M5.2-AA | the idle row's guard removed: a tick in `idle` or `draining` closes whatever was recorded | connection-table 2 — T5's guard instance and D3's |

Every check the slice added or changed is reddened by one mutant at least:
- T1, T2, T5, L2 and L3 by E and M; T2's two instances with nothing armed, T5 and L3 by L;
- T7 by F;
- D1 by B, G and H, its HEAD instance also by Y, its guard by C;
- D2 by A, E, I, J, K, L, M and V, its guard by D;
- D3 by E, L, M and W, its guard by AA; D4 by X;
- "M5.2: all 4 tick rows have a test" by R. The count checks moved beside it keep their earlier mutants, and S shows a group that raises fails its own count, with its cause printed;
- the state-and-actions check by E, F, N and X;
- the moves-on check by A, B, J, K, N, O, T, U, W and X;
- "the rows arm all five deadline kinds" by T;
- the fake shell's idle close by E, L and M;
- decisions' reason table by H, and write-timeout's refusal by K;
- connection-originated's body row by B, G and H, and every row's disarm by E and M;
- connection-linger's closes by E and M, and the linger deadline's two by L;
- connection-deadlines: idle by E, L, M and N; header by T and U; body by B, G, H, T and Z; write by A, E, J, K, L, M and V; linger by E, L, M and T; the kinds' check by Q. Each row's instant is 0005's default for its kind, and Z moves the body's.

Found on the way (scratch `nested-label.sps`, Darwin arm64, 2026-09-27): SRFI-64's simple runner names a failing check after the last check run inside its expression. A check `"OUTER"` whose expression ran a passing `"INNER"` and then failed printed `FAIL INNER: passes`. Six of the table's count checks ran their rows inside themselves, so a missing row's count would fail under a row's name, as the first R, which emptied D2, did ("D1 ..."). Each group's rows now run first, under a guard that prints the cause of a raise, so a group that raises fails its own count, exit 1 (S). No earlier log misnames one: M2.1-E's count, "all 9 termination and error rows", was already taken outside its check.

## M5.3 — one timer per loop, in both shells (2026-09-27)

Red before green, the tests edited, the shells as on main at 6fe18eb:
- connection-deadlines 6, each row and the adoption row, twice:
  - first because the fake had no fourth argument, so every row raised;
  - then with the argument alone, no wheel: every tick a millisecond early acted. Idle closed, the head and the body answered 408, the write closed logged, the linger closed, and so did the adoption row. The fake ticked every time.
- shell 10, with `shell-timer` a field never set:
  - the one-timer check and the counters;
  - "each of them closes once its deadlines pass", and the four deadline clients;
  - the guard check;
  - and, since those connections never closed, the end's two handle checks.
- contract 1: the stalling script's first check, its wait exhausted: no deadline fired, so no 408 was written.

The first green run failed the guard check on the test's own fault. It built its result with `append`, and Chez evaluated `(first-logged)` and the tick records before the `run-shell` that makes them: `(satisfied (() #f) (() #f) nothing-logged)`. It now binds the run first with `let*`, as M5.2's `ticked` does.

Mapping each check to a mutant before the run found four checks that could not fail, each strengthened before the run:
- the on-time check read "no firing between" and was vacuous without the server's tick. It now also needs a firing at the tick's own instant (I);
- the short limits were equal, so a deadline armed for the wrong kind would pass. They are now head 200, idle 250 and linger 300;
- nothing read whether a connection that leaves with no step of the core leaves the wheel. `shell-deadlines` and `connection-deadline` now let the failed adoption and the reconciliation show it (F, G);
- a closed fake connection asks for nothing when ticked, so the fake's disarm had no check. The deadlines suite now looks for the tick among the events delivered (U).

Every mutant below ran against all thirty-seven suites of the finished tree, four at a time. Where a row names no other suite, the others were green. None failed to load. The runner prints eight FAIL lines a suite at most, so A's, C's, D's and M's socket-lane lists were also run by hand, one at a time. A timing mutant's count can move between runs, since its extra or early timers fire where the loop's timing puts them: A reddened the lingering client's row in the parallel run and not by hand, and D reddened three rows more in parallel. The rows below name what every run reddened, and "in parallel" what only the parallel run did.

| # | mutation (`src/http-server/private/shell.sls` unless named) | observed |
|---|---|---|
| M5.3-A | the plan's: a timer per armed deadline, every arm making and starting one | shell 8 by hand, 9 in parallel — "with four connections open, the loop holds one timer, the shell's, firing every tick", "and chez-libuv counts one timer", "once its last connection leaves, the shell holds no timer", the end's "no handle is left on the loop", and, as the extra timers fire between a deadline and its tick, the half-head, idle and silent rows and the guard (the lingering row too, in parallel); clients 2 and serve 1, their loops never empty; contract 1, its end |
| M5.3-B | no deadline armed at adoption | shell 5 — "each of them closes once its deadlines pass", the silent client, the guard (its pair never ticks), and the end's two handle checks; contract 1 — the silent script's wait. The half-head script still passes: its header arm makes the timer |
| M5.3-C | a deadline armed at now, not now plus its limit | shell 9 — the one-timer check (connections closed before it), the four deadline rows, the guard, and three four-MiB rows, whose writes the write deadline now cuts short; contract 3 — both scripts' traces, and the half-head's bytes |
| M5.3-D | a deadline armed at its limit alone | shell 8 by hand — the three four-MiB rows, the four deadline rows and the guard; in parallel 11, the upload's two and the one-timer check more; contract 3, as C |
| M5.3-E | the disarm action performed as nothing | SURVIVES: a scope statement, below |
| M5.3-F | handle-close! leaves the connection in the wheel | shell 1 — "leaving no deadline armed, and no timer", after the failed adoption |
| M5.3-G | the reconciliation leaves the connection in the wheel | shell 1 — "until the run loop reconciles the table with the loop, logs it, takes it out of the wheel, and runs on" |
| M5.3-H | the ticks delivered under one guard | shell 4 — the guard check, its second connection never ticked; so the timer stays ("once its last connection leaves...") and the end's two handle checks |
| M5.3-I | the server not told the time | shell 5 — the four deadline rows and the guard: no firing at the tick's instant |
| M5.3-J | the timer repeating every two ticks | shell 1 — the one-timer check's repeat, 20 |
| M5.3-K | the timer never closed | shell 5 — the one-timer check and the counts, the main shell's timer still live, "leaving no deadline armed, and no timer", "once its last connection leaves...", and the end's handle check; clients 2, serve 1, contract 1, each at its end |
| M5.3-L | the timer closed as any connection leaves | shell 3 — "each of them closes", and the half-head and lingering rows, whose deadlines no timer fires once the first connection closed it |
| M5.3-M | no timer ever made | shell 10 — the one-timer check, the counts, "each of them closes", the four rows, the guard and the end's two handle checks; contract 1 — the half-head script's wait |
| M5.3-N | the wheel advanced a tick ahead of now: early | shell 5 — the four rows and the guard; contract 2 — both scripts' traces |
| M5.3-O | a tick that carries a now a millisecond on | contract 2 — both scripts' traces. The socket lane reads the same instant in the connection's tick and the server's, so an offset in both passes there |
| M5.3-P | the wheel advanced a tick behind now: late | shell 5 — the four rows and the guard, each tick a firing after its deadline's first |
| M5.3-Q | the fake ticks every time (`tests/fake-shell.sls`) | connection-deadlines 7 — the five rows, the adoption row, and "a connection its client closes is ticked no more" |
| M5.3-R | the fake arms at now (`tests/fake-shell.sls`) | connection-deadlines 6 — the five rows and the adoption row, each ticked at its early tick |
| M5.3-S | the fake arms at the limit alone (`tests/fake-shell.sls`) | as R: connection-deadlines 6 |
| M5.3-T | the fake ignores the instant it is made at (`tests/fake-shell.sls`) | as R: connection-deadlines 6 |
| M5.3-U | the fake performs a disarm as nothing (`tests/fake-shell.sls`) | connection-deadlines 1 — "a connection its client closes is ticked no more" |
| M5.3-V | the fake arms nothing when made (`tests/fake-shell.sls`) | connection-deadlines 1 — the adoption row; contract 1 — the silent script's traces |
| M5.3-W | the replay drops the ticks (`tests/test-contract.sps`) | contract 3 — both scripts' traces, and the half-head's bytes |
| M5.3-X | the replay leaves the fake's clock where it was made (`tests/test-contract.sps`) | as W: contract 3 |
| M5.3-Y | the replay makes the fake at 0 (`tests/test-contract.sps`) | SURVIVES: a scope statement, below |
| M5.3-Z | the arm action performed as nothing | shell 5 — "a connection whose handle was closed behind the shell's back stays in the table, its deadline armed", "each of them closes", and the half-head, idle and lingering rows; contract 1 — the half-head script's wait |
| M5.3-Z2 | the fake performs an arm as nothing (`tests/fake-shell.sls`) | connection-deadlines 5, the five rows; connection-linger 2 and connection-originated 2, whose deadlines now pass through the fake's wheel; contract 2 — the half-head script's bytes and traces |

Two survivors, each a scope statement, measured by the run above:
- **M5.3-E, the libuv shell's disarm performed as nothing.** In v1 every disarm the core asks for is followed in the same drain by an arm, which moves the deadline, or by a close, whose handle-close! disarms too. So no v1 flow leaves a deadline armed that a working disarm would take out. From M6.2, a connection waiting for its handler's credit is disarmed with nothing after it, and that row is the disarm's check (plan §14's note). The fake's disarm has its check (U), since the fake's close does not disarm.
- **M5.3-Y, the replay's fake made at 0.** The replay ticks the fake only where the libuv shell ticked. A fake deadline armed earlier than the libuv shell's therefore passes at the same tick and cannot show. A later one could, and V is that case. The fake's own start instant is held by the deadlines suite (T).

Every check the slice added or changed is reddened by one mutant at least:
- connection-deadlines: the five rows by Q, R, S, T and Z2; the adoption row by Q, R, S, T and V; "a connection its client closes is ticked no more" by Q and U;
- shell:
  - the one-timer check by A, C, J, K and M; the counts by A, K and M; "each of them closes" by B, L, M and Z;
  - the half-head row by A, C, D, I, L, M, N, P and Z; the idle row by A, C, D, I, M, N, P and Z; the lingering row by C, D, I, L, M, N, P and Z; the silent row by A, B, C, D, I, M, N and P;
  - the guard by A, B, C, D, H, I, M, N and P; "once its last connection leaves" by A, H and K;
  - "leaving no deadline armed, and no timer" by F and K; the reconciliation's two by Z (armed before) and G (taken out after);
- contract: the half-head script by C, D, M, N, O, W, X, Z and Z2; the silent script by B, C, D, N, O, V, W and X; the end's check by A and K.

## M5.3, after its review (2026-09-27)

`/code-review high` found ten things, all fixed on the owner's "fix all ten". Finding 3 was settled by form: a carried workaround, and chez-libuv #28.

Red before green, each fix's check written first and run on the tree as it was:
- contract 1: "a client the libuv shell never adopted replays as nothing", which raised in the fake's first arm, `(+ #f 75000)`. A scratch copy playing a script to a port where nothing listens ended as a harness error, exit 2. With the fix it ends in a named failure, exit 1, `(not-connected satisfied ECONNREFUSED)`;
- shell 2: "a connection closed from outside the core as it arms a deadline leaves with none armed", which read `(satisfied 2361711061 1)`. The deadline stayed armed, and its later tick spent the pair check's trap, so the pair check failed as well;
- shell 1: "after a handler that holds the loop 300 ms, the idle deadline armed after its answer is still ahead when the client has it", which read `(satisfied #f ... closed)`. The idle deadline, armed from the time the loop read before the handler, had already closed the connection;
- fake-shell 1, the stub's refused firing, held by Q2 below, since the split and its check came together;
- the checks of the timer's lifetime and of the pair, rewritten with the fixes, each held by the mutants below that restore the tree before the review: L2, AB and M2.

Finding 8, the held handle, is the test harness's, shown in a scratch copy whose pairing opens one client. Without the fix, the held handle failed the end's two handle checks besides the pair check. With it, only the pair check fails.

Every mutant below ran against all thirty-seven suites of the finished tree, four at a time. None failed to load, and the socket-lane lists over eight were run by hand, one at a time, with the same counts.

| # | mutation (`src/http-server/private/shell.sls` unless named) | observed |
|---|---|---|
| M5.3-A | the plan's: a timer per armed deadline, a new one each arm | shell 10 — "four connections open on one shell add one timer to the loop", "and chez-libuv counts one timer more", the four deadline rows and the pair, as the extra timers fire between, "its wheel empty, the timer stops...", "shut down... the shell closes its timer", and the end's handle check; clients 2, contract 1, serve 1, each at its end |
| M5.3-B | no deadline armed at adoption | shell 9 — the one-timer check and the counts, since the four silent clients arm nothing; "a shell shut down with no connection left closes the timer it kept" (`bad`'s adoption never made one); "each of them closes", the silent row, the pair, "shut down... closes its timer", and the end's two handle checks; contract 1 — the silent script's wait |
| M5.3-C | a deadline armed at now, not now plus its limit | shell 11 — the four-MiB upload's two, the three four-MiB write rows, the four deadline rows, the slow handler's and the pair; clients 2 — ab -k's run and the log; contract 3 — both scripts' traces, the half-head's bytes |
| M5.3-D | a deadline armed at its limit alone | as C: shell 11, clients 2, contract 3 |
| M5.3-E | the disarm action performed as nothing | SURVIVES: the scope statement of the first round stands |
| M5.3-F | handle-close! leaves the connection in the wheel | shell 3 — "leaving no deadline armed" (the failed adoption), the late arm's check, and "its wheel empty, the timer stops...", the connection closed from outside left armed |
| M5.3-G | the reconciliation leaves the connection in the wheel | shell 1 — "until the run loop reconciles... takes it out of the wheel, and runs on" |
| M5.3-H | the ticks delivered under one guard | shell 4 — the pair, whose second is never ticked, and so "shut down... closes its timer" and the end's two handle checks, with the second still open |
| M5.3-I | the server not told the time | shell 5 — the four deadline rows and the pair: no firing at the tick's instant |
| M5.3-J | the timer repeating every two ticks | shell 1 — the one-timer check's repeat, 500 |
| M5.3-K | the timer never closed | shell 3 — `bad`'s and `quick`'s closes, and the end's handle check; clients 1, contract 1, serve 1, each at its end |
| M5.3-L | the timer never stopped | shell 1 — "its wheel empty, the timer stops, firing once more at most, and the shell keeps it" |
| M5.3-L2 | the timer closed as the table empties, listening or not, as before the review | shell 3 — "its wheel empty... the shell keeps it", `bad`'s close and `quick`'s, each finding no timer kept to close; clients 1 — "the listener is the one handle left, beside the timer the shell keeps" |
| M5.3-M | no timer ever started | shell 13 — every deadline check, the one-timer check and the counts, "the timer stops", both shut-down closes, and the end's two; clients 1; contract 1 — the half-head script's wait |
| M5.3-M2 | a stopped timer never started again | shell 3 — the pair, whose deadlines the stopped timer never reaches, then "shut down... closes its timer" and the end's handle check; contract 1 — the silent script's wait, after the half-head script stopped the timer |
| M5.3-N | the wheel advanced a tick ahead of now: early | shell 5 — the four rows and the pair; contract 2 — both scripts' traces |
| M5.3-O | a tick that carries a now a millisecond on | contract 2 — both scripts' traces |
| M5.3-P | the wheel advanced a tick behind now: late | shell 5 — the four rows and the pair |
| M5.3-Q | the fake fires every time (`tests/fake-shell.sls`) | connection-deadlines 7 — the five rows, the adoption row, and "a connection its client closes is ticked no more" |
| M5.3-Q2 | firing a stub ticks it, as the one tick did before the review (`tests/fake-shell.sls`) | fake-shell 1 — "a stub step's shell keeps no timer: firing it is refused, and nothing is delivered" |
| M5.3-R | the fake arms at now (`tests/fake-shell.sls`) | connection-deadlines 6 — the five rows and the adoption row |
| M5.3-S | the fake arms at the limit alone (`tests/fake-shell.sls`) | as R |
| M5.3-T | the fake ignores the instant it is made at (`tests/fake-shell.sls`) | as R |
| M5.3-U | the fake performs a disarm as nothing (`tests/fake-shell.sls`) | connection-deadlines 1 — "a connection its client closes is ticked no more" |
| M5.3-V | the fake arms nothing when made (`tests/fake-shell.sls`) | connection-deadlines 1 — the adoption row; contract 1 — the silent script's traces |
| M5.3-W | the replay drops the ticks (`tests/test-contract.sps`) | contract 3 — both scripts' traces, the half-head's bytes |
| M5.3-W2 | the replay makes the fake at an adoption never seen, as before the review (`tests/test-contract.sps`) | contract 1 — "a client the libuv shell never adopted replays as nothing" |
| M5.3-X | the replay leaves the fake's clock where it was made (`tests/test-contract.sps`) | as W |
| M5.3-Y | the replay makes the fake at 0 (`tests/test-contract.sps`) | SURVIVES: the scope statement of the first round stands |
| M5.3-Z | the arm action performed as nothing | shell 6 — "stays in the table, its deadline armed", "each of them closes", the half-head, idle and lingering rows, and the slow handler's; contract 1 — the half-head script's wait |
| M5.3-Z2 | the fake performs an arm as nothing (`tests/fake-shell.sls`) | connection-deadlines 5, connection-linger 2, connection-originated 2, contract 2 |
| M5.3-AA | a connection closing armed again, as before the review | shell 2 — the late arm's check, and "its wheel empty, the timer stops...", the stray deadline keeping it running |
| M5.3-AB | the first raise goes on, whatever came after, as before the review | shell 1 — the pair: the run loop logs the first raise and runs on, and the contract condition is lost |
| M5.3-AC | the loop's clock left as the handler found it, as before the review | shell 1 — the slow handler's check |
| M5.3-AD | the clock brought up to date before the handler, not after | shell 1 — the slow handler's check: the refresh must follow the handler |

Every check the review added or changed is reddened by one mutant at least:
- contract's replay with nothing adopted by W2;
- fake-shell's refused firing by Q2;
- shell:
  - "leaving no deadline armed" by F; "a shell shut down with no connection left closes the timer it kept" by B, K, L2 and M;
  - the one-timer check by A, B, J and M, and its count by A, B and M;
  - the slow handler's by AC, AD, C, D and Z; the late arm's by AA and F;
  - "its wheel empty, the timer stops..." by A, AA, F, L, L2 and M;
  - the pair by A, AB, B, C, D, H, I, M, M2, N and P; `quick`'s close by A, B, H, K, L2, M and M2;
- clients' "the listener is the one handle left, beside the timer the shell keeps" by A, L2 and M.
The first round's checks keep their mutants, which ran again here with the same verdicts.
