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
root; a process the suite starts, `tests/serve-child.sps`, inherits that path.
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

### The second step: every handler after the turn (feat/m7.1-after-the-turn)

Seventeen mutants on that tree: the core's, the shells' and serve's, and
the review's M7R-1, M7R-2 and M7R-5. The plan's "call a handler from inside
`on-data`" is M7B-4. M7B-4 and M7R-1 are cut for that tree's
`call-handler!`, which dispatches the handler's answer itself; the third
step's `answered` takes its place, and the two are cut for it there. M7B-12
to M7B-15 witness the checks the step changed rather than added: the shell
suite's check of the timer, whose loop the step turns through the scheduler
(M5.3-L's edit); row B3, whose start the step moved into the head's feed,
since a request asked with its body still to come now waits in handling;
and the message loop's `serial?`, which the step taught a wait on the
handler from a message's end. The runner prints eight failures a suite, so
the table suite was run by hand under each core mutant, every failure
listed, for the rows the step changed. The numbers skip M7B-5, the mutant of
a guard around each handler call, withdrawn with that guard when M7.1's
review put one a turn in its place (M7B-10, M7R-2), and M7R-4, for which no
mutant was run. Every check the step added or changed is reddened by at
least one.

| Mutant | Where | Change | Reddens (suite, failures) |
|---|---|---|---|
| M7B-1 | `connection` | the core asks the handler of a request whose body is still arriving with reading on, as before M7.1 | connection-body 1, connection-expect 1, connection-table 18, shell 2 |
| M7B-2 | `connection` | a reader's answer does not read again: the request stays in handling | clients 6, connection-body 22, connection-cut-off 3, connection-deadlines 1, connection-entry 1, connection-expect 13, connection-head 2, connection-originated 1, connection-padding 10, connection-table 66, contract 3, libhtp-lane 5, message-loop 2, outcome-lane 2, ratchet 1, shell 7 |
| M7B-3 | `connection` | awaiting credit from handling stops reading and disarms again | connection-table 2 |
| M7B-4 | `shell` | the libuv shell calls a handler from inside on-data, in place (design §5.3's mutation) | shell 2 |
| M7B-6 | `shell` | the shell feeds the parser outside the phase 'in-parser | none: survives (below) |
| M7B-7 | `fake-shell` | the fake shell calls a handler in place, inside its drain | none: survives (below) |
| M7B-8 | `serve` | serve's loop runs uv-run alone, not the scheduler's turn | serve 1 |
| M7B-9 | `shell` | a scheduler for each shell, not one for each loop | contract 3, shell 88 |
| M7B-10 | `shell` | a shell's turn unguarded | shell 10 |
| M7B-11 | `shell` | the loops' schedulers kept in a weak table: a loop let go is never collected | shell 1 |
| M7B-12 | `shell` | the shell's timer never stopped (M5.3-L), against the check whose loop M7.1 now turns through the scheduler | shell 2 |
| M7B-13 | `connection` | a piece of the body re-arms no body deadline: continue alone (row B3, whose start M7.1 moved to the head's feed) | connection-table 3, shell 1 |
| M7B-14 | `connection` | a reader's answer reads again though its message has ended (the message loop's serial?, which M7.1 taught a wait from a message's end) | connection-body 1, connection-table 4, message-loop 1 |
| M7B-15 | `connection` | after a response, reading starts again before the parser is resumed (the message loop's serial?) | connection-table 2, message-loop 3 |
| M7R-1 | `shell` | a handler called though its connection closed before the drain reached the call | shell 1 |
| M7R-2 | `shell` | the turn's guard takes only a uv-run callback error as a callback's, not a raise out of the drain | shell 4 |
| M7R-5 | `shell` | the shell's drain leaves the phase a raise out of a feed left | none: survives (below) |

By check, the mutants that redden it:
- shell, "a client reads the response of a handler that names where it was called": M7B-9;
- shell, "a handler is called after libuv's turn, from the scheduler's drain, on no coroutine": M7B-4, M7B-9;
- shell, "a handler whose connection closed before the drain reached its call is not called: its client reads the stream's end and nothing else": M7B-4, M7R-1;
- shell, "a loop let go with its shell is collected, its scheduler with it": M7B-11;
- shell, "when the dispatch of a handler's answer raises, its client reads the stream's end": M7B-10, M7R-2;
- shell, "with no response, the connection closed and gone, the raise logged as a callback's": M7B-10, M7R-2;
- shell, "its wheel empty, the timer stops, firing once more at most, and the shell keeps it": M7B-12;
- serve, "serve, run as a program of its own, answers a request, calling its handler after libuv's turn": M7B-8;
- connection-body, "a reader answered with no word of credit never makes reading wait: a read-stop per message, and one as the POST waits on its handler with its body still to come, every delivery size": M7B-1, M7B-14;
- message-loop, "from a message's end to its resume, or to its staged close, the parser is not fed nor the socket read": M7B-14, M7B-15;
- message-loop, "from a message's end to its resume, the parser is not fed nor the socket read": M7B-15;
- the table, the rows the step changed, each failure listed by hand: B2,
  B11, B15, S4, E6 and E7 by M7B-1; B3 by M7B-13; B4, B6, B19 and E3 by
  M7B-1 and M7B-2; C3 by M7B-1, M7B-2 and M7B-3; E5 by M7B-1 and M7B-3.

Three survive, each a scope statement:
- **M7B-6, the shell feeding the parser outside `'in-parser`.** Nothing a
  feed runs, the adapter's bindings and the pure core they step, can wait,
  so no check can see the phase set. The scheduler suite checks its R5
  refusal, and `make check-imports` holds that none of that code can reach
  the scheduler: the pure libraries import no private library, and the
  adapter neither the scheduler nor the shell or serve. Watched red by an
  import of the scheduler added to the adapter, and to `server.sls`.
- **M7R-5, the shell's drain not setting the phase back after a raise out
  of a feed.** A feed raises only when the parser breaks its contract, which
  no check can make it do. Inside a turn, the wind around the poll sets the
  phase back once the poll is over, and until then the phase is read only
  by a park, refused either way, as R5's or R1's, or by a drain, which
  nothing the shell runs makes inside the poll. The set back matters to a
  loop run outside a turn (`shell-run!`), whose next turn's drain would
  refuse a park as R5's.
- **M7B-7, the fake shell calling a handler in place.** Every drain the core
  runs today ends with its `call-handler`, so the fake answers in the same
  order either way, and the contract test sees the same traces. M7.3's
  scripts with handlers that wait are where the fake's later call shows.

Two notes:
- **M7B-8 survived every suite until the serve suite's new check.** Nothing
  ran `serve` itself, and its loop, now the scheduler's turn, left uv-run
  alone calling no handler. The check runs `serve` in a process of its own
  (`tests/serve-child.sps`), which inherits the mutant's library path.
- **M7B-11 is a fix found while building.** The loops' schedulers were first
  kept in a weak table, and a scheduler's poll holds its loop, so no loop was
  ever let go. The shell suite now checks that a loop let go is collected.

### The third step: `awaiting` (feat/m7.1-awaiting), and the finished tree

Forty-nine mutants on the finished tree: the first step's twenty and the
second step's seventeen again, M7B-4 and M7R-1 cut for its `call-handler!`,
and the third step's twelve. The numbers skip M7A-7, for which no mutant was
run, and M7A-11 is M7S-C's edit, run again as the third step's. Every check
M7.1 added or changed is reddened by at least one, as on its own step's
tree, and the same three survive. The shell's suites now run on the
scheduler, so the first step's mutants redden them too: M7S-A, with the
modes swapped, four socket suites, whose waits, capped by iteration count,
then spin through their caps where 'once blocked; M7S-B, M7S-N, M7S-Q and
M7S-R the shell suite.

| Mutant | Where | Change | Reddens (suite, failures) |
|---|---|---|---|
| M7S-A | `scheduler` | the poll's modes swapped: 'once when something is ready, 'nowait when nothing is | clients 3, contract (raised, exit 2, 2 failed), scheduler 1, serve 1, shell (raised, exit 2, 10 failed) |
| M7S-B | `scheduler` | R3: a coroutine's first run returns normally at its end, into the continuation that first entered it | scheduler (raised, exit 2, 1 failed), shell (raised, exit 2, 1 failed) |
| M7S-C | `scheduler` | R2's check gone: a park on no coroutine is not refused | scheduler 1, shell 1 |
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
| M7S-N | `scheduler` | the coroutine running not cleared once it parks or ends | scheduler (raised, exit 2), shell (raised, exit 2, 20 failed) |
| M7S-O | `scheduler` | the poll not in the phase 'in-uv-run | scheduler 3 |
| M7S-P | `scheduler` | the ready queue run newest first | scheduler 2 |
| M7S-Q | `scheduler` | a call run on a coroutine of its own | scheduler 2, shell 9 |
| M7S-R | `scheduler` | a woken coroutine entered again from its start, not resumed where it parked | scheduler 6, shell (raised, exit 2, 18 failed) |
| M7B-1 | `connection` | the core asks the handler of a request whose body is still arriving with reading on, as before M7.1 | connection-body 1, connection-expect 1, connection-table 18, shell 2 |
| M7B-2 | `connection` | a reader's answer does not read again: the request stays in handling | clients 6, connection-body 22, connection-cut-off 3, connection-deadlines 1, connection-entry 1, connection-expect 13, connection-head 2, connection-originated 1, connection-padding 10, connection-table 66, contract 3, libhtp-lane 5, message-loop 2, outcome-lane 2, ratchet 1, shell 7 |
| M7B-3 | `connection` | awaiting credit from handling stops reading and disarms again | connection-table 2 |
| M7B-4 | `shell` | the libuv shell calls a handler from inside on-data, in place (design §5.3's mutation) | shell 3 |
| M7B-6 | `shell` | the shell feeds the parser outside the phase 'in-parser | none: survives (below) |
| M7B-7 | `fake-shell` | the fake shell calls a handler in place, inside its drain | none: survives (below) |
| M7B-8 | `serve` | serve's loop runs uv-run alone, not the scheduler's turn | serve 1 |
| M7B-9 | `shell` | a scheduler for each shell, not one for each loop | contract 3, shell 102 |
| M7B-10 | `shell` | a shell's turn unguarded | shell 10 |
| M7B-11 | `shell` | the loops' schedulers kept in a weak table: a loop let go is never collected | shell 1 |
| M7B-12 | `shell` | the shell's timer never stopped (M5.3-L), against the check whose loop M7.1 now turns through the scheduler | shell 2 |
| M7B-13 | `connection` | a piece of the body re-arms no body deadline: continue alone (row B3, whose start M7.1 moved to the head's feed) | connection-table 3, shell 1 |
| M7B-14 | `connection` | a reader's answer reads again though its message has ended (the message loop's serial?, which M7.1 taught a wait from a message's end) | connection-body 1, connection-table 4, message-loop 1, shell 2 |
| M7B-15 | `connection` | after a response, reading starts again before the parser is resumed (the message loop's serial?) | connection-table 2, message-loop 3 |
| M7R-1 | `shell` | a handler called though its connection closed before the drain reached the call | shell 1 |
| M7R-2 | `shell` | the turn's guard takes only a uv-run callback error as a callback's, not a raise out of the drain | shell 4 |
| M7R-3 | `scheduler` | a feed's beginning leaves the phase as it was | scheduler 2 |
| M7R-5 | `shell` | the shell's drain leaves the phase a raise out of a feed left | none: survives (below) |
| M7A-1 | `shell` | a handler's awaiting thunk called in place, on no coroutine | shell 3 |
| M7A-2 | `shell` | a waiting handler's reader handed its pieces in place | shell 3 |
| M7A-3 | `shell` | a waiting handler's producer called in place | shell 2 |
| M7A-4 | `shell` | a waiting connection's calls not made one at a time: each started at once | shell 1 |
| M7A-5 | `shell` | a waiting handler's answer given with no word of credit | shell 1 |
| M7A-6 | `shell` | a waiting connection's next call never started | shell 10 |
| M7A-8 | `shell` | a connection keeps waiting past its waiting request: not reset at the next handler's call | shell 1 |
| M7A-9 | `shell` | a waiting call's event never dispatched once it has ended | shell 13 |
| M7A-10 | `scheduler` | a wait on no coroutine answers #f quietly, not refused | scheduler 1, shell 2 |
| M7A-11 | `scheduler` | R2's check gone (M7S-C), against the shell suite | scheduler 1, shell 1 |
| M7A-12 | `awaiting` | an awaiting made of anything | body 1 |
| M7A-13 | `awaiting` | awaiting-thunk answers the record itself | body 1, shell 7 |

By check, the third step's, the mutants that redden it:
- shell, "a handler that waits answers awaiting: its thunk parks on a coroutine, and nothing is answered while it waits": M7S-N, M7B-9, M7A-1, M7A-13;
- shell, "once woken, its answer is written": M7S-B, M7S-N, M7S-R, M7B-9, M7A-9;
- shell, "the thunk's answer, resumed in the drain, on its coroutine": M7S-N, M7S-R, M7A-1, M7A-9, M7A-13;
- shell, "the next request on the connection, its handler ordinary, has its reader called in place": M7S-N, M7S-Q, M7S-R, M7A-1, M7A-8, M7A-9, M7A-13;
- shell, "the client of an ordinary handler that waits reads the stream's end": M7S-N, M7S-Q, M7A-10;
- shell, "after a 500, the refusal logged as R2's, a wait on no coroutine": M7S-C, M7S-N, M7S-Q, M7B-4, M7A-10, M7A-11;
- shell, "the client of a handler that waits and reads a body reads its response": M7S-N, M7S-R, M7B-14, M7A-6, M7A-9;
- shell, "its reader takes each piece on a coroutine, in order, yielding before it keeps one": M7S-N, M7S-R, M7B-14, M7A-2, M7A-4, M7A-6, M7A-9, M7A-13;
- shell, "its reader waits on a piece, and reading waits for it: the connection awaits its credit": M7A-2, M7A-5, M7A-6, M7A-9, M7A-13;
- shell, "once it has taken the piece, the rest is read, and the response follows": M7A-6, M7A-9;
- shell, "the reader's response": M7A-2, M7A-6, M7A-9, M7A-13;
- shell, "the client of a handler that waits and streams reads its response": M7S-R, M7A-3, M7A-6;
- shell, "its producer is called on a coroutine for each piece, yielding before each: the pieces in order": M7S-R, M7A-3, M7A-6, M7A-13;
- body, "awaiting carries its thunk, and is neither a reader nor anything else": M7A-13;
- body, "an awaiting is made of a procedure": M7A-12.

## M7.2 — what a handler waits with (2026-10-02)

Four steps (plan §14's M7.2 note, decision 0015), each proven on its own
tree, the steps below it beneath it. Each step's mutants ran against every
suite of that tree, three at a time, unless a row names its suite. Every
mutant loaded (no `Exception` in any report).

### The first step: the scheduler without `guard`

Five mutants, each reddening the scheduler suite alone. Each of the four
checks the step added is reddened by at least one. The plan's mutation, the
`guard` put back, is M7G-1. M7.1's M7S-J ("the coroutine's guard gone")
matches nothing once the `guard` is gone; M7G-4 is it, re-cut. M7G-5 edits
the suite itself: the instrument the allocation checks read, made to read
nothing, which the calibration reddens.

| Mutant | Where | Change | Reddens (suite, failures) |
|---|---|---|---|
| M7G-1 | `scheduler` | the `guard` back: a coroutine's raise caught by a guard inside the drain's one-shot continuation | scheduler 2 |
| M7G-2 | `scheduler` | the handler jumps through the drain's continuation as it was when the coroutine was entered, not the one that resumed it | scheduler (raised, exit 2, 1 failed) |
| M7G-3 | `scheduler` | the handler returns to the raise, not jumping to the drain | scheduler (raised, exit 2, 2 failed) |
| M7G-4 | `scheduler` | no handler: a coroutine's raise leaves its stack (M7S-J re-cut) | scheduler (raised, exit 2, 2 failed) |
| M7G-5 | the suite | the counter read as nothing: `bytes-each` answers 0 (the scheduler suite alone) | scheduler 1 |

By check, the first step's, the mutants that redden it:
- scheduler, "a coroutine that raises after a park: the raise comes to its end procedure, and the turns after it run on": M7G-2, M7G-3, M7G-4;
- scheduler, "1,000 coroutines parked at once each keep a stack the counter sees": M7G-5;
- scheduler, "a coroutine that ends by its value allocates no stack of its own": M7G-1;
- scheduler, "a coroutine that ends by a raise allocates no stack of its own": M7G-1.

M7.1's "a coroutine that raises: the raise comes to its end procedure, and
the drain runs on", whose code the step rewrote, is reddened by M7G-3 and
M7G-4.

### The second step: `await` and R4

Fourteen mutants, against all forty-six suites, the waits suite among them.
The waits suite's checks were then made to take a raise out of their
turns as their own failure, not the suite's (`taken`), and the first twelve
ran again against it alone; their waits rows below are that run's, the
other suites' the first run's. M7W-13 and M7W-14 ran last, against every
suite. Each of the eleven checks the step added is reddened by
at least one. The plan's mutation, design §5.3's third, the one-shot check
removed, is M7W-1, and R4's two rows go red. The import audit's new rule
has no mutant here: an import of the waits added to the adapter, in a
scratch copy of `src/` and the Makefile, reddened `make check-imports`,
and passed main's rule.

| Mutant | Where | Change | Reddens (suite, failures) |
|---|---|---|---|
| M7W-1 | `waits` | R4's one-shot check removed (design §5.3's third): every resume after `register` wakes the coroutine | waits 2, shell 1 |
| M7W-2 | `waits` | a resume called while `register` runs is lost: the wait parks anyway | waits 2 |
| M7W-3 | `waits` | a wait takes the coroutine running without asking whether it may park: `register` runs first | waits 1 |
| M7W-4 | `waits` | a late resume is not logged | waits 2, shell 1 |
| M7W-5 | `waits` | make-waits keeps no waits for the scheduler | waits 6, shell 2 |
| M7W-6 | `shell` | the shell gives the loop's scheduler no waits | shell 2 |
| M7W-7 | the facade | the facade does not export `await` | serve 1 |
| M7W-8 | `scheduler` | a wait on no coroutine is not refused as R2: `waiting-coroutine` answers #f | scheduler 1, shell 1, waits 1 |
| M7W-9 | `shell` | the shell's waits log nothing | shell 1 |
| M7W-10 | `waits` | a resume wakes the coroutine with #t, not what it was given | waits 3, shell 1 |
| M7W-11 | `waits` | a raise out of `register` is swallowed, and the wait parks | waits 1 |
| M7W-12 | `waits` | a wait on a loop that keeps no waits goes ahead | waits 1 |
| M7W-13 | `scheduler` | R1's check gone from `waiting-coroutine`: a park or a wait inside the poll is not refused as R1 (M7S-D1 re-cut) | scheduler 1, waits 1 |
| M7W-14 | `scheduler` | R5's check gone from `waiting-coroutine`: a park or a wait inside a feed is not refused as R5 (M7S-E re-cut) | scheduler 1, waits 1 |

By check, the second step's, the mutants that redden it:
- waits, "a wait parks until its resume is called, from a callback, and answers what the resume was given": M7W-5, M7W-10;
- waits, "a resume called while register runs: the wait answers at once, without parking": M7W-2, M7W-5;
- waits, "R4: a resume called again is logged as late-resume, and wakes nothing, not even the coroutine waiting again": M7W-1, M7W-4, M7W-5, M7W-10;
- waits, "R4: a resume called twice while register runs: the wait answers the first, and the second is logged": M7W-1, M7W-2, M7W-4, M7W-5;
- waits, "one coroutine's resume, called by another, wakes it in the same drain": M7W-5, M7W-10;
- waits, "a raise out of register comes out of the wait, and nothing parks": M7W-5, M7W-11;
- waits, "a wait on no coroutine is refused as R2, in a callback as R1, in a feed as R5, each before register runs": M7W-3, M7W-8, M7W-13, M7W-14;
- waits, "a wait on a loop that keeps no waits is an assertion violation": M7W-12;
- shell, "a handler that waits on await parks, and nothing is answered while it waits": M7W-5, M7W-6;
- shell, "another request's handler wakes it: both are answered, and the second resume is logged as late-resume": M7W-1, M7W-4, M7W-5, M7W-6, M7W-9, M7W-10;
- serve, "the facade exports the handler's names, the verbs it waits with, the server's start, and its errors": M7W-7.

The step moved the scheduler's refusals into `waiting-coroutine`, which a
park still calls, so M7.1's M7S-C, M7S-D1 and M7S-E match nothing; M7W-8,
M7W-13 and M7W-14 are them, re-cut, and redden M7.1's rows again: "R2: a
park on no coroutine, in a call the drain makes and outside any turn, is
refused as R2" (M7W-8); "R1: a callback that parks, and a drain inside a
callback, are refused as R1" (M7W-13); "R5: a park inside a feed is refused
as R5, and the phase is the drain's once the feed is over" (M7W-14).

### The third step: `sleep-ms` and `with-deadline`

Thirty-six mutants first, against all forty-seven suites, three at a time:
none reddened a suite but the heap's, the waits', the shell's and the
serve suite. Seven survived, each a check too weak to see its mutant, and
each check was made stronger:
- M7H-4: the model run of 5,000 steps never built a removal that leaves
  the last entry below a later parent, and the sift-downs after one mend
  it; a check builds one, and buries the entry under two more.
- M7H-6: the collection check took out only entries whose slot the next
  one filled; it now takes out the heap's only entry, and removes its last.
- M7H-9: another heap's entry was removed from an empty heap, which raises
  anyway; it is now removed from a heap with entries at its place.
- M7T-14 and M7T-17: with the clock at 0, the heap's own check refused -1;
  at 10, -1 makes a time the heap takes, and the check reads which verb
  refused.
- M7T-15: a wait with no clock fails anyway, applying #f; the check reads
  which verb refused.
- M7T-21: the check read the loop's clock itself, bringing it up to date
  for the sleep; it now reads the monotonic clock.
Then all thirty-six again, and M7H-13, against the heap, waits and shell
suites; the rows below are that run's, and the serve suite's the first's.
Every check the step added is reddened by at least one.

| Mutant | Where | Change | Reddens (suite, failures) |
|---|---|---|---|
| M7H-1 | `heap` | ties broken newest first | heap 2, waits 1 |
| M7H-2 | `heap` | an entry put in never moves up past its parent | heap 3, waits 1 |
| M7H-3 | `heap` | moving down always takes the left child, not the earlier of the two | heap 3 |
| M7H-4 | `heap` | a removal from the middle never moves the last entry up | heap 1 |
| M7H-5 | `heap` | an entry taken out keeps its place | heap (raised, exit 2, 1 failed) |
| M7H-6 | `heap` | the slot an entry leaves is not cleared | heap 1 |
| M7H-7 | `heap` | an advance takes out only the entries before now | heap 4, waits 9 |
| M7H-8 | `heap` | an insert takes any time | heap 1 |
| M7H-9 | `heap` | another heap's entry is taken out | heap 1 |
| M7H-10 | `heap` | the earliest read from the last slot, not the first | heap 1, waits 1 |
| M7H-11 | `heap` | the vector grown with half its entries copied | heap 1 |
| M7H-12 | `heap` | an advance takes any now | heap 1 |
| M7H-13 | `heap` | an empty heap's earliest read from its first slot | heap 2, waits 10, shell 2 |
| M7T-1 | `waits` | the waits' timer, firing, takes out what is due a millisecond later too | waits 1 |
| M7T-2 | `waits` | the waits' timer not armed again for what is left | waits 4 |
| M7T-3 | `waits` | the waits' timer not stopped once nothing is left | waits 7, shell 3 |
| M7T-4 | `waits` | the waits' timer armed again for every entry put in, not only a new earliest | waits 6, shell 2 |
| M7T-5 | `waits` | a passed deadline leaves the sleep it ended armed | waits 5, shell 2 |
| M7T-6 | `waits` | a passed deadline does not end the wait in progress | waits 6, shell 4 |
| M7T-7 | `waits` | a passed deadline not counted | waits 2 |
| M7T-8 | `waits` | a thunk that returns leaves its deadline in force | waits 2 |
| M7T-9 | `waits` | a raise out of the thunk leaves its deadline in force | waits 4 |
| M7T-10 | `waits` | a raise a handler outside continues ends the deadline | waits 1 |
| M7T-11 | `waits` | a wait after a deadline has passed begins anyway | waits 2 |
| M7T-12 | `waits` | a wait a deadline ends answers its token, not a raise | waits 6, shell 1 |
| M7T-13 | `waits` | with-deadline takes the coroutine running without asking whether it may park | waits 1 |
| M7T-14 | `waits` | sleep-ms takes any number | waits 1 |
| M7T-15 | `waits` | a timed wait on waits with no clock goes ahead | waits 1 |
| M7T-16 | `waits` | a passed deadline wakes the coroutine itself, its wait left parked (R4 bypassed) | waits 1 |
| M7T-17 | `waits` | with-deadline takes any number | waits 1 |
| M7T-18 | `shell` | the shell's waits get no clock | shell 2 |
| M7T-19 | `shell` | the waits' timer, firing, fires nothing | shell 5 |
| M7T-20 | `shell` | a shell that serves no more leaves the timer of its loop's waits | shell 1 |
| M7T-21 | `shell` | the waits' clock read with no update | shell 1 |
| M7T-22 | the facade | the facade does not export sleep-ms | serve 1 |
| M7T-23 | `shell` | a closed timer of the waits is kept, and started again | shell 1 |
| M7T-24 | `waits` | the waits' timer armed for a new earliest's time, not its delay | waits 1, shell 5 |

By check, the third step's, the mutants that redden it:
- heap, "an advance takes out exactly the entries at or before now, the earliest first, equal times in the order they were put in": M7H-1, M7H-2, M7H-3, M7H-7;
- heap, "5,000 steps of inserts, removals and advances take out what the list model takes out": M7H-1, M7H-2, M7H-3, M7H-5, M7H-7, M7H-10, M7H-11, M7H-13;
- heap, "a removal takes out that entry alone; removing it again, or one an advance took, does nothing": M7H-7;
- heap, "a removal from the middle moves the last entry up past a later parent, so an advance still finds it": M7H-2, M7H-3, M7H-4;
- heap, "an empty heap has no earliest time and a count of 0": M7H-13;
- heap, "a time or a now that is not a whole number of milliseconds, or another heap's entry, is an assertion violation": M7H-8, M7H-9, M7H-12;
- heap, "a heap holds nothing of an entry it has taken out, by an advance or a removal, and holds one still in": M7H-6, M7H-7;
- waits, "a sleep parks until the timer fires at or after its time; the timer armed for it, again for what is left, and stopped once none is left": M7H-7, M7H-13, M7T-1, M7T-2, M7T-3;
- waits, "sleeps wake in the order of their times, equal times in the order they slept, the timer armed for the earliest": M7H-1, M7H-2, M7H-7, M7H-10, M7H-13, M7T-2, M7T-3, M7T-4;
- waits, "sleep-ms and with-deadline take a whole number of milliseconds, refused by them before anything is armed": M7T-14, M7T-17;
- waits, "a timed wait on a loop whose waits keep no clock is an assertion violation, the verb's": M7T-15;
- waits, "the wait in progress when a deadline passes raises &deadline-passed, and its sleep is taken out of the timer's keeping": M7H-7, M7H-13, M7T-3, M7T-4, M7T-5, M7T-6, M7T-12;
- waits, "a deadline that passes while its coroutine is not parked makes its next wait raise at once, before anything is armed": M7H-7, M7H-13, M7T-3, M7T-7, M7T-11;
- waits, "with-deadline answers what its thunk returns, and its deadline is taken out when the thunk returns or raises": M7H-13, M7T-8, M7T-9;
- waits, "once a deadline has passed, every later wait inside it raises at once, and a wait after it does not": M7H-7, M7H-13, M7T-3, M7T-4, M7T-5, M7T-6, M7T-7, M7T-8, M7T-11, M7T-12, M7T-24;
- waits, "deadlines nest: the inner one passing first raises through it alone, and the outer one, passing later, raises at the wait then": M7H-7, M7H-13, M7T-2, M7T-3, M7T-4, M7T-5, M7T-6, M7T-9, M7T-12;
- waits, "an outer deadline passing inside an inner one raises out through both, and takes the inner one out": M7H-7, M7H-13, M7T-2, M7T-4, M7T-5, M7T-6, M7T-9, M7T-12;
- waits, "R4: a resume after a deadline ended its wait is logged as late-resume": M7H-7, M7T-6, M7T-12, M7T-16;
- waits, "with-deadline is refused as a wait is, on no coroutine as R2, in a feed as R5, in a callback as R1, its thunk not run and nothing armed": M7T-13;
- waits, "a raise that a handler outside continues leaves the deadline in force": M7T-3, M7T-4, M7T-5, M7T-6, M7T-9, M7T-10, M7T-12;
- shell, "a handler that holds the loop 30 ms, then sleeps 20 ms, sleeps 18 ms or more by the monotonic clock; one whose deadline of 10 ms ends a sleep of a minute is answered passed; nothing is left armed": M7H-13, M7T-3, M7T-4, M7T-5, M7T-6, M7T-12, M7T-18, M7T-19, M7T-21, M7T-24;
- shell, "after a shell on the loop serves no more, closing the timer of the loop's waits, a handler that sleeps is answered: the timer is made again": M7H-13, M7T-3, M7T-18, M7T-19, M7T-23, M7T-24;
- serve, "the facade exports the handler's names, the verbs it waits with, the server's start, and its errors": M7T-22.

The shell suite's "and no handle is left on the loop" is reddened by M7T-5,
M7T-6, M7T-19, M7T-20 and M7T-24, a timer of the waits left armed or open.

### The fourth step: `resolve`

Fifteen mutants, against all forty-seven suites, three at a time: fourteen
of the step's, and M7T-25, the third step's, for the check that step gained
while the fourth was built (a sleep due at its deadline's own time, below).
Each of the checks the step added is reddened by at least one. One survives,
a scope statement.

| Mutant | Where | Change | Reddens (suite, failures) |
|---|---|---|---|
| M7L-1 | `waits` | resolve answers the whole answer, its reason before its addresses | shell 1, waits 2 |
| M7L-2 | `waits` | a lookup that fails answers its no addresses, raising nothing | shell 1, waits 1 |
| M7L-3 | `waits` | a lookup's error raised with a reason of its own, not the resolver's | shell 1, waits 1 |
| M7L-4 | `waits` | a lookup a deadline ends is not cancelled | waits 1 |
| M7L-5 | `waits` | resolve takes a name that is not a string | waits 1 |
| M7L-6 | `waits` | resolve on waits with no resolver goes ahead | waits 1 |
| M7L-7 | `shell` | the shell asks libuv about an empty name too | shell 1 |
| M7L-8 | `shell` | the shell asks libuv about a name with a NUL too | shell 1 |
| M7L-9 | `shell` | the shell's lookup asks for every kind of socket | shell 1 |
| M7L-10 | `shell` | the shell answers a failed lookup with a reason of its own, not the errno's name | shell 1 |
| M7L-11 | `shell` | the shell's cancel cancels nothing | none: survives (below) |
| M7L-12 | the facade | the facade does not export resolve | serve 1 |
| M7L-13 | `shell` | the shell gives the loop's waits no resolver | shell 1 |
| M7L-14 | `waits` | a wait answered while it begins parks anyway (M7W-2 re-cut) | shell 3, waits 3 |
| M7T-25 | `waits` | a sleep a deadline took back in the same advance wakes anyway | waits 1 |

By check, the fourth step's, the mutants that redden it:
- waits, "resolve parks until the lookup answers, and answers its addresses": M7L-1;
- waits, "a lookup's failure raises &resolve-error, its reason the resolver's": M7L-2, M7L-3;
- waits, "a lookup answered while it is asked: resolve answers at once, without parking": M7L-1, M7L-14;
- waits, "R4: a deadline that ends a resolve cancels its lookup, and the lookup's answer after it is logged as late-resume": M7L-4;
- waits, "resolve takes a string, and on waits with no resolver is an assertion violation, its own": M7L-5, M7L-6;
- shell, "a handler that resolves localhost is answered the addresses uv-getaddrinfo! gives; one that resolves an empty name, or one with a NUL, invalid-name; one no resolver knows, its EAI_ error": M7L-1, M7L-2, M7L-3, M7L-7, M7L-8, M7L-9, M7L-10, M7L-13, M7L-14;
- serve, "the facade exports the handler's names, the verbs it waits with, the server's start, and its errors": M7L-12;
- and the third step's, waits, "a sleep due at its deadline's own time, the deadline armed first: the wait raises, and the sleep taken back wakes nothing and logs nothing": M7T-25.

One survives, a scope statement:
- **M7L-11, the shell's cancel cancelling nothing.** `uv-cancel!` takes a
  lookup back only while it waits for a thread of libuv's pool, and no
  check can make libuv hold one there on demand: the waits suite checks
  that a deadline asks for the cancel (M7L-4), and the shell's is
  chez-libuv's verb, called with the request it answered.

### The layers, each on its own tree

Each step's tree was then made afresh, main at f5532ee with the step's files,
and those of the steps below it, laid in, and each step's mutants ran there
against every suite, three at a time: the first's five, the second's
fourteen, and the third's thirty-eight, M7H-13 and M7T-25 among them. On
the finished tree, every mutant of the four steps ran again, seventy-one;
ten of the first three steps' matched nothing there, the code they cut
rewritten by a later step, and were re-cut against it: M7W-1, M7W-2, M7W-4,
M7W-6, M7W-7, M7W-9, M7W-11, M7W-12, M7T-18 and M7T-22. Every mutant
loaded, and every one reddened at least one check but M7L-11, the scope
survivor above. Every check a step added is reddened by its own step's
mutants on its own tree: four of four on the first, eleven of eleven on the
second, twenty-three of twenty-three on the third, six of six on the fourth.
So is the serve suite's list of the facade's exports, which the second,
third and fourth steps each changed, its name the same (M7W-7, M7T-22,
M7L-12).

### The review's fixes (2026-10-02)

The /code-review high found seven, all fixed on the owner's word, each in the
step it belongs to (progress.md). New mutants for the fixes, specs re-cut
where a fix moved the text they cut, and specs withdrawn where a fix took
their code away:

| Mutant | Step | Where | Change | Reddens on its step's tree (suite, failures) |
|---|---|---|---|---|
| M7W-15 | second | `waits` | a late resume logged with no verb | waits 2, shell 1 |
| M7T-26 | third | `waits` | a deadline left on a park too: the after thunk asks nothing of the coroutine | waits 9, shell 4 |
| M7T-27 | third | `waits` | a deadline never left: the after thunk does nothing | waits 6 |
| M7T-28 | third | `waits` | a thunk entered again and left again leaves its deadline again | waits 1 |
| M7T-29 | third | `scheduler` | coroutine-suspending? answers #f, a park taken for a leaving | waits 9, shell 4 |
| M7T-30 | third | `waits` | with-deadline answers one value of its thunk | waits 1 |
| M7L-15 | fourth | `shell` | a refusal caught only as chez-libuv's own, not libuv's EINVAL | shell 1 |
| M7L-16 | fourth | `shell` | a refusal caught only as libuv's EINVAL, not chez-libuv's own | shell 1 |
| M7L-17 | fourth | `shell` | a refusal caught and answered nothing: the wait parks for good | shell 3 |
| M7L-18 | fourth | `shell` | no refusal caught: the lookup raises what libuv raises | shell 1 |

Re-cut: M7W-1 and M7W-4, for the cell that now keeps its verb (their first
re-cuts left a parenthesis open, did not load, and were cut again, the
parentheses counted; their reports grep clean of `Exception`); M7L-9, for
the lookup's call split across lines. Withdrawn: M7T-8, M7T-9 and M7T-10,
whose exception handler the `dynamic-wind` replaced (M7T-27 and M7T-26 cut
what they cut); M7L-7 and M7L-8, whose tests of a name, for emptiness and a
NUL, the caught refusal replaced (M7L-15 and M7L-16 cut what they cut).

Then every step's tree was made afresh again, and each step's mutants ran
on it, against every suite, three at a time: five on the first, fifteen on
the second, forty on the third, and on the finished tree all seventy-six
again, the ten earlier re-cuts among them. Every mutant loaded, and every
one reddened a check but M7L-11, the scope survivor. Every check a step
added is reddened by its own step's mutants on its own tree: four of four,
eleven of eleven, twenty-six of twenty-six and six of six.
