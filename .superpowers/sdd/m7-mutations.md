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
