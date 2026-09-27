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
