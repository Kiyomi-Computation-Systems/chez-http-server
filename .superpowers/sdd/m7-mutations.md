# M7 — mutation log

Every test in M7 is watched to fail: a single named mutation breaks the
asserted property, the suite goes red, and the mutation is reverted. Recorded
per global-constraints ("a test is finished when it has been watched to fail").
The milestone plan §14 names the slice's mutations; the extras below each
witness a property the slice's suites assert beside them.

Platform: Darwin arm64, Chez Scheme 10.4.1 (`tarm64osx`), libuv 1.52.1, 2026-10-02.
Library path as in M6
(`src:tests:vendor/chez-libuv/src:vendor/chez-httparse/src:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs:vendor/chez-httparse/test/support/harness:vendor/chez-libuv/tests`).
Each mutant ran from a scratch copy of the mutated file, placed first on the
library path under an absolute root, or, for a suite program, run from that
root.
The substitution had to match exactly once, several edits to one file applied
in turn, and the tree was never edited. A row lists each suite that went red
and its failures; the others were green. "exit 2" is a suite whose body
raised, and "exit 255" one that did not load.

## M7.1 — the scheduler, every handler after the turn, and `awaiting` (2026-10-02)

Three stacked steps, each proven on its own tree: a scratch worktree of main
at 4a7748b with the step's files, and those of the steps below it, laid in.
Each step's mutants ran against all forty-five suites of that tree, three at
a time. Every mutant loaded (no `Exception` in any report). No suite was run
before its code was written, so none is recorded red at load.

### The first step: the scheduler (feat/m7.1-scheduler)

Twenty mutants on that tree, M7S's nineteen and the review's M7R-3, each
reddening the scheduler suite and no other, since nothing else on that tree
imports the scheduler. Each of the suite's seventeen checks is reddened by
at least one. The plan's "swap `'once` and `'nowait`" is M7S-A; R2's mutant
is M7S-C and R3's M7S-B, named here as the plan asked.

| Mutant | Where | Change | Reddens (suite, failures) |
|---|---|---|---|
| M7S-A | `scheduler` | the poll's modes swapped: 'once when something is ready, 'nowait when nothing is | scheduler 1 |
| M7S-B | `scheduler` | R3: a coroutine's first run returns normally at its end, into the continuation that first entered it | scheduler (raised, exit 2, 1 failed) |
| M7S-C | `scheduler` | R2's check gone: a park on no coroutine is not refused | scheduler 1 |
| M7S-D1 | `scheduler` | R1's check gone from a park: a park inside the poll is not refused as R1 | scheduler 1 |
| M7S-D2 | `scheduler` | R1's check gone from the drain: a drain inside the poll runs | scheduler 1 |
| M7S-E | `scheduler` | R5's check gone: a park inside a feed is not refused | scheduler 1 |
| M7S-F | `scheduler` | the drain stops at what was ready as it began | scheduler 1 |
| M7S-G | `scheduler` | a coroutine's end procedure called on its own stack, before it jumps to the drain | scheduler 1 |
| M7S-H | `scheduler` | a wake of a coroutine that is not parked is not refused | scheduler 1 |
| M7S-I | `scheduler` | a coroutine spawned is entered at once, where it is spawned | scheduler (raised, exit 2, 2 failed) |
| M7S-J | `scheduler` | the coroutine's guard gone: a raise leaves its stack | scheduler (raised, exit 2, 1 failed) |
| M7S-K | `scheduler` | a feed's end leaves the phase 'in-parser | scheduler 2 |
| M7S-L | `scheduler` | a turn answers only the poll's answer | scheduler 5 |
| M7S-M | `scheduler` | a coroutine that yields runs again in the same drain | scheduler 2 |
| M7S-N | `scheduler` | the coroutine running not cleared once it parks or ends | scheduler (raised, exit 2) |
| M7S-O | `scheduler` | the poll not in the phase 'in-uv-run | scheduler 3 |
| M7S-P | `scheduler` | the ready queue run newest first | scheduler 2 |
| M7S-Q | `scheduler` | a call run on a coroutine of its own | scheduler 2 |
| M7S-R | `scheduler` | a woken coroutine entered again from its start, not resumed where it parked | scheduler 6 |
| M7R-3 | `scheduler` | a feed's beginning leaves the phase as it was | scheduler 2 |

By check, the mutants that redden it:
- scheduler, "a coroutine spawned runs at the next drain, not where it was spawned": M7S-I;
- scheduler, "a coroutine a callback spawns runs at the next turn's drain, once the poll is over": M7S-I, M7S-L, M7S-O;
- scheduler, "a coroutine's value comes to its end procedure from the scheduler, on no coroutine": M7S-G;
- scheduler, "a coroutine that raises: the raise comes to its end procedure, and the drain runs on": M7S-J, M7S-P;
- scheduler, "a coroutine parks, a callback wakes it, and it resumes at the next drain with what it was given": M7S-L, M7S-R;
- scheduler, "a drain runs what is ready, then what was made ready while it ran, in that order": M7S-F, M7S-P;
- scheduler, "a coroutine that yields runs again once the poll is over; the poll is 'nowait while it waits, 'once when nothing is ready": M7S-A, M7S-M, M7S-R;
- scheduler, "R1: a callback that parks, and a drain inside a callback, are refused as R1": M7S-D1, M7S-D2, M7S-O;
- scheduler, "R2: a park on no coroutine, in a call the drain makes and outside any turn, is refused as R2": M7S-C, M7S-Q;
- scheduler, "R3: a coroutine that parks, is woken and ends, ends through the scheduler, and the turns after it run on": M7S-B, M7S-R;
- scheduler, "R5: a park inside a feed is refused as R5, and the phase is the drain's once the feed is over": M7S-E, M7S-K, M7R-3;
- scheduler, "a feed inside a callback is 'in-parser, and 'in-uv-run once it is over": M7S-K, M7S-O, M7R-3;
- scheduler, "a call is made in the drain, on no coroutine": M7S-Q;
- scheduler, "waking a coroutine that is not parked, ready, woken already or ended, is an assertion violation": M7S-H;
- scheduler, "a turn answers the poll's answer, or #t while something is ready": M7S-L, M7S-M, M7S-R;
- scheduler, "a guard inside a coroutine catches a raise after a park": M7S-L, M7S-R;
- scheduler, "what a coroutine parameterizes stays its own across a park": M7S-L, M7S-R.
