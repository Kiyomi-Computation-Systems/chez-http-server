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

### The review's fixes (2026-10-02)

The /code-review high found seven, all fixed on the owner's word, each in the
step it belongs to (progress.md). New mutants for the fixes, specs re-cut
where a fix moved the text they cut, and specs withdrawn where a fix took
their code away:

| Mutant | Step | Where | Change | Reddens on its step's tree (suite, failures) |
|---|---|---|---|---|
| M7W-15 | second | `waits` | a late resume logged with no verb | waits 2, shell 1 |

Re-cut: M7W-1 and M7W-4, for the cell that now keeps its verb (their first
re-cuts left a parenthesis open, did not load, and were cut again, the
parentheses counted; their reports grep clean of `Exception`).

Then every step's tree was made afresh, and each step's mutants ran on it,
against every suite, three at a time: five on the first and fifteen on the
second. Every mutant loaded, and every one reddened a check. Every check a
step added is reddened by its own step's mutants on its own tree: four of
four and eleven of eleven.
