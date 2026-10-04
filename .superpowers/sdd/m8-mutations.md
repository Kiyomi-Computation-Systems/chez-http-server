# M8 — mutation log

Every test in M8 is watched to fail: a single named mutation breaks the
asserted property, the suite goes red, and the mutation is reverted. Recorded
per global-constraints ("a test is finished when it has been watched to fail").
The milestone plan §14 names the slice's mutations; the extras below each
witness a property the slice's suites assert beside them.

Platform: Darwin arm64, Chez Scheme 10.4.1 (`tarm64osx`), libuv 1.52.1, 2026-10-03.
Library path as in M7
(`src:tests:vendor/chez-libuv/src:vendor/chez-httparse/src:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs:vendor/chez-httparse/test/support/harness:vendor/chez-libuv/tests`).
Each mutant ran from a scratch copy of the mutated file, placed first on the
library path under an absolute root, or, for a suite program, run from that
root; a process the suite starts, `tests/serve-child.sps`, inherits that path.
The substitution had to match exactly once, several edits to one file applied
in turn, and the tree was never edited. A row lists each suite that went red
and its failures; the others were green. "exit 2" is a suite whose body
raised.

## M8.1 — the drain (2026-10-03)

Built in one working tree on the owner's "start M8.1" (progress.md, M8.1),
reviewed on the owner's form, then cut into three stacked steps: the limit
and the core's rows (feat/m8.1-rows); the drain in the shell
(feat/m8.1-drain); the signals and `serve` (feat/m8.1-signals). Each run
took a set of mutants against every suite of its tree, a frozen copy of the
working tree's files, or of the step's own, main's with the step's files,
with vendor and build linked, four at a time. Every mutant in every run
loaded (no `Exception` in any report).

### The first step: the limit and the core's rows

Eighteen mutants on the step's own tree, after the review: each reddens a
check.

| Mutant | Step | Where | Change | Reddens (suite, failures) |
|---|---|---|---|---|
| M8C-0 | 1 | `connection` | the old row: idle drains, half-closing, and draining a state again | connection-table 3 |
| M8C-1 | 1 | `connection` | idle told to finish asks for nothing | connection-table 1 |
| M8C-2 | 1 | `connection` | a request in flight never marked to close | connection-table 8 |
| M8C-3 | 1 | `connection` | a reason of its own overwritten | connection-table 1 |
| M8C-4 | 1 | `connection` | lingering told to finish closes at once | connection-table 1 |
| M8C-5 | 1 | `connection` | idle closes as at its idle deadline | connection-table 1 |
| M8C-6 | 1 | `connection` | responding not told | connection-table 3 |
| M8C-7 | 1 | `connection` | the in-flight states refuse the event | connection-table 2 |
| M8C-8 | 1 | `connection` | closing told to finish closes again | connection-table 1 |
| M8C-9 | 1 | `connection` | a state in any phase accepted | connection-table 1 |
| M8C-10 | 1 | `connection` | a cancelled request logged as a read error, as before the review | connection-table 2 |
| M8L-1 | 1 | `limits` | default-limits' drain is 9 s | limits 2 |
| M8L-2 | 1 | `limits` | the environment's default drain is 9 s | limits 1 |
| M8L-3 | 1 | `limits` | the variable listed as CHEZ_HTTP_DRAIN_TIMEOUT_MS | limits 1 |
| M8L-4 | 1 | `limits` | the drain read in its stored unit, not seconds | limits 1 |
| M8L-5 | 1 | `limits` | the drain's accessor answers 10 s whatever the field holds | limits 2 |
| M8T-1 | 1 | `the table` | T11 loses its instances | connection-table 1 |
| M8T-2 | 1 | `the table` | D4 loses its instances | connection-table 1 |

The step adds or changes fourteen checks, each reddened by one of them: the
limits suite's value test (M8L-1) and override (M8L-4, M8L-5), its drift
guard (M8L-1, M8L-2), its variables (M8L-3) and `limits-with` (M8L-5); and
the table's states (M8C-0), T8's ten instances (idle by M8C-1, the six
in flight by M8C-2, a reason of its own by M8C-3, lingering by M8C-4,
closing by M8C-8), T10 and T11 (M8C-2), T12 (M8C-10), the held pairs
(M8C-0), the two counts (M8T-1, M8T-2), and the state outside the ten
(M8C-9).

### The second step: the drain in the shell

Forty-one mutants on the step's own tree, after the review: each reddens a
check but M8H-15, the listener's failure, which libuv reports only on
Windows. A scope statement (the review's fifth).

| Mutant | Step | Where | Change | Reddens (suite, failures) |
|---|---|---|---|---|
| M8H-1 | 2 | `shell` | finish-all tells no connection | shell 4 |
| M8H-2 | 2 | `shell` | force-close-all closes nothing | shell 8 |
| M8H-3 | 2 | `shell` | the timer stops on an empty wheel while draining | shell 4 |
| M8H-4 | 2 | `shell` | the timer not started as the drain begins | shell 4 |
| M8H-5 | 2 | `shell` | a close not told to the server | shell 4 |
| M8H-6 | 2 | `shell` | a reconciled connection not told to the server | shell 1 |
| M8H-9 | 2 | `shell` | the shutdown dated by the loop's cached time | shell 1 |
| M8H-10 | 2 | `shell` | telling the connections stops at the first raise | shell 1 |
| M8H-11 | 2 | `shell` | the last raise kept, not the first | shell 1 |
| M8H-13 | 2 | `shell` | the shutdown told no connection is open | shell 11 |
| M8H-15 | 2 | `shell` | a listener's failure told with no time and no connections open (a scope statement: libuv reports one only on Windows) | none: survives |
| M8S-1 | 2 | `server` | force-close-all never asked for (plan §14's mutation) | server 4, shell 8 |
| M8S-2 | 2 | `server` | the deadline's tick must pass it, not reach it | server 3, shell 1 |
| M8S-3 | 2 | `server` | the deadline kept after the forced close | server 3 |
| M8S-4 | 2 | `server` | the last close never ends the drain | server 4, shell 5 |
| M8S-5 | 2 | `server` | a shutdown with none open drains, never stopping | server 2, shell 2 |
| M8S-6 | 2 | `server` | the connections never told to finish | server 8, shell 8 |
| M8S-7 | 2 | `server` | draining logged without its count | server 10, shell 6 |
| M8S-8 | 2 | `server` | a listener failure stops at once, open connections or not | server 2 |
| M8S-9 | 2 | `server` | an event's time and count unchecked | server 2 |
| M8S-10 | 2 | `server` | a state takes any deadline | server 1 |
| M8S-11 | 2 | `server` | an arrival once stopped is accepted | server 1 |
| M8S-12 | 2 | `server` | the deadline 10 s whatever the limits say | server 2, shell 4 |
| M8S-13 | 2 | `server` | stopped not a phase | server 6 |
| M8S-14 | 2 | `server` | the forced close not logged | server 4, shell 3 |
| M8S-15 | 2 | `server` | the drain's end not logged | server 4, shell 5 |
| M8S-16 | 2 | `server` | finish-all not in the vocabulary | server 2 |
| M8S-17 | 2 | `server` | refusals after the first not counted | server 2, shell 1 |
| M8S-18 | 2 | `server` | an arrival answered with a copy of the state | server 1 |
| M8S-19 | 2 | `server` | a tick's time unchecked | server 1 |
| M8S-20 | 2 | `server` | an arrival at the cap accepted | server 5, shell 3 |
| M8S-22 | 2 | `server` | an arrival below the cap refused | clients 15, contract (raised, exit 2, 2 failed), serve 5, server 5, shell (raised, exit 2, 9 failed) |
| M8S-23 | 2 | `server` | a shutdown or failure in any phase taken as one while listening | server 3 |
| M8S-24 | 2 | `server` | an arrival while draining accepted | server 1 |
| M8S-25 | 2 | `server` | a listener failure not logged | server 3 |
| M8S-26 | 2 | `server` | a tick that asks for no close logs itself | clients 1, server 6 |
| M8S-27 | 2 | `server` | the last close ends a server still listening too | clients 17, contract (raised, exit 2, 1 failed), serve 4, server 1, shell (raised, exit 2, 5 failed) |
| M8S-28 | 2 | `server` | any close ends the drain | server 2, shell 2 |
| M8S-29 | 2 | `server` | connection-closed not an event | server 2 |
| M8X-1 | 2 | `shell` | an awaiting answer taken as a response: no handler waits | contract 84, shell 17 |
| M8X-2 | 2 | `connection` | a lingering connection whose client closes stays until its deadline | clients 2, connection-linger 4, connection-originated 23, connection-table 1, contract 22, libhtp-lane 5, message-loop 1, outcome-lane 3, ratchet 1, serve 1, shell 6 |

The step adds or changes fifty-five checks, the server suite's forty-two
and thirteen of the shell suite's, each reddened by one of them. The
shell's precondition, past M8X-1's eighth FAIL line, was read from the
suite run by hand on that mutant's root: seventeen failures, the
precondition the twelfth.

### The third step, and the finished tree: sixty-five mutants

The third step's six (M8H-7, M8H-8, M8H-12, M8H-14, M8V-1 and M8V-2) ran on
the finished tree with the other fifty-nine, which the first two steps'
trees had run on their own.

| Mutant | Step | Where | Change | Reddens (suite, failures) |
|---|---|---|---|---|
| M8C-0 | 1 | `connection` | the old row: idle drains, half-closing, and draining a state again | connection-table 3, shell 3 |
| M8C-1 | 1 | `connection` | idle told to finish asks for nothing | connection-table 1, serve 2, shell 3 |
| M8C-2 | 1 | `connection` | a request in flight never marked to close | connection-table 8, serve 2, shell 2 |
| M8C-3 | 1 | `connection` | a reason of its own overwritten | connection-table 1 |
| M8C-4 | 1 | `connection` | lingering told to finish closes at once | connection-table 1 |
| M8C-5 | 1 | `connection` | idle closes as at its idle deadline | connection-table 1 |
| M8C-6 | 1 | `connection` | responding not told | connection-table 3 |
| M8C-7 | 1 | `connection` | the in-flight states refuse the event | connection-table 2, serve 2, shell (raised, exit 2, 0 failed) |
| M8C-8 | 1 | `connection` | closing told to finish closes again | connection-table 1 |
| M8C-9 | 1 | `connection` | a state in any phase accepted | connection-table 1 |
| M8C-10 | 1 | `connection` | a cancelled request logged as a read error, as before the review | connection-table 2, shell 1 |
| M8H-1 | 2 | `shell` | finish-all tells no connection | serve 2, shell 4 |
| M8H-2 | 2 | `shell` | force-close-all closes nothing | serve 2, shell 8 |
| M8H-3 | 2 | `shell` | the timer stops on an empty wheel while draining | serve 2, shell 4 |
| M8H-4 | 2 | `shell` | the timer not started as the drain begins | shell 4 |
| M8H-5 | 2 | `shell` | a close not told to the server | serve 2, shell 4 |
| M8H-6 | 2 | `shell` | a reconciled connection not told to the server | shell 1 |
| M8H-7 | 3 | `shell` | the signal handles never closed | serve 1, shell 2 |
| M8H-8 | 3 | `shell` | SIGTERM watched alone | serve 2, shell 1 |
| M8H-9 | 2 | `shell` | the shutdown dated by the loop's cached time | shell 1 |
| M8H-10 | 2 | `shell` | telling the connections stops at the first raise | shell 1 |
| M8H-11 | 2 | `shell` | the last raise kept, not the first | shell 1 |
| M8H-12 | 3 | `shell` | a signal asks for nothing | serve 3 |
| M8H-13 | 2 | `shell` | the shutdown told no connection is open | serve 2, shell 11 |
| M8H-14 | 3 | `shell` | a shell that has stopped may watch | shell 2 |
| M8H-15 | 2 | `shell` | a listener's failure told with no time and no connections open (a scope statement: libuv reports one only on Windows) | none: survives |
| M8L-1 | 1 | `limits` | default-limits' drain is 9 s | limits 2, server 5 |
| M8L-2 | 1 | `limits` | the environment's default drain is 9 s | limits 1 |
| M8L-3 | 1 | `limits` | the variable listed as CHEZ_HTTP_DRAIN_TIMEOUT_MS | limits 1 |
| M8L-4 | 1 | `limits` | the drain read in its stored unit, not seconds | limits 1 |
| M8L-5 | 1 | `limits` | the drain's accessor answers 10 s whatever the field holds | limits 2, serve 2, server 2, shell 4 |
| M8S-1 | 2 | `server` | force-close-all never asked for (plan §14's mutation) | serve 2, server 4, shell 8 |
| M8S-2 | 2 | `server` | the deadline's tick must pass it, not reach it | server 3 |
| M8S-3 | 2 | `server` | the deadline kept after the forced close | server 3 |
| M8S-4 | 2 | `server` | the last close never ends the drain | serve 2, server 4, shell 5 |
| M8S-5 | 2 | `server` | a shutdown with none open drains, never stopping | serve 1, server 2, shell 2 |
| M8S-6 | 2 | `server` | the connections never told to finish | serve 2, server 8, shell 8 |
| M8S-7 | 2 | `server` | draining logged without its count | serve 3, server 10, shell 6 |
| M8S-8 | 2 | `server` | a listener failure stops at once, open connections or not | server 2 |
| M8S-9 | 2 | `server` | an event's time and count unchecked | server 2 |
| M8S-10 | 2 | `server` | a state takes any deadline | server 1 |
| M8S-11 | 2 | `server` | an arrival once stopped is accepted | server 1 |
| M8S-12 | 2 | `server` | the deadline 10 s whatever the limits say | serve 2, server 2, shell 4 |
| M8S-13 | 2 | `server` | stopped not a phase | server 6 |
| M8S-14 | 2 | `server` | the forced close not logged | serve 2, server 4, shell 3 |
| M8S-15 | 2 | `server` | the drain's end not logged | serve 2, server 4, shell 5 |
| M8S-16 | 2 | `server` | finish-all not in the vocabulary | server 2 |
| M8S-17 | 2 | `server` | refusals after the first not counted | server 2, shell 1 |
| M8S-18 | 2 | `server` | an arrival answered with a copy of the state | server 1 |
| M8S-19 | 2 | `server` | a tick's time unchecked | server 1 |
| M8S-20 | 2 | `server` | an arrival at the cap accepted | server 5, shell 3 |
| M8S-22 | 2 | `server` | an arrival below the cap refused | clients 15, contract (raised, exit 2, 2 failed), serve 7, server 5, shell (raised, exit 2, 9 failed) |
| M8S-23 | 2 | `server` | a shutdown or failure in any phase taken as one while listening | server 3 |
| M8S-24 | 2 | `server` | an arrival while draining accepted | server 1 |
| M8S-25 | 2 | `server` | a listener failure not logged | server 3 |
| M8S-26 | 2 | `server` | a tick that asks for no close logs itself | clients 1, serve 2, server 6 |
| M8S-27 | 2 | `server` | the last close ends a server still listening too | clients 17, contract (raised, exit 2, 3 failed), serve 4, server 1, shell (raised, exit 2, 5 failed) |
| M8S-28 | 2 | `server` | any close ends the drain | serve 2, server 2, shell 2 |
| M8S-29 | 2 | `server` | connection-closed not an event | server 2 |
| M8T-1 | 1 | `the table` | T11 loses its instances | connection-table 1 |
| M8T-2 | 1 | `the table` | D4 loses its instances | connection-table 1 |
| M8V-1 | 3 | `serve` | serve watches no signal | serve 3 |
| M8V-2 | 3 | `serve` | serve runs until the loop is empty, not until the drain ends | serve 2 |
| M8X-1 | 2 | `shell` | an awaiting answer taken as a response: no handler waits | contract 84, serve 2, shell 17 |
| M8X-2 | 2 | `connection` | a lingering connection whose client closes stays until its deadline | clients 2, connection-linger 4, connection-originated 23, connection-table 1, contract 22, libhtp-lane 5, message-loop 1, outcome-lane 3, ratchet 1, serve 1, shell 6 |

Each reddens a check but M8H-15. (There is no M8S-21: the number was
skipped.) Plan §14's mutation, M8S-1, `force-close-all` never asked for,
reddens the held connection's row, "a client that holds its connection is
closed at the drain's deadline", as the plan expects, and the server's
deadline rows and both signal checks beside it.

### Before the review

A first run, on an earlier copy of the tree, left three survivors, and
checks that no mutant reddened:
- M8H-4, the timer not started as the drain begins, survived: the shutdown
  came before the firing that would have stopped the timer. The check of a
  connection held in its handler now waits for that firing first.
- M8H-10 and M8H-11, telling the connections stopping at the first raise,
  and the last raise kept, survived: the deadline closed the connection left
  untold, and no check told one raise from another. Both connections now
  raise, each its own condition, and the drain must end before its deadline.
- The in-flight connection's close was checked as closed, which the
  deadline would have done anyway: it now closes before the deadline asks
  for anything (M8X-2).
- Thirteen mutants were added for checks no mutant reddened, the arrival
  rows rewritten for the drain's state among them (M8S-20 to M8S-29, M8C-8,
  M8C-9, M8X-1).

Then sixty-three, on the tree the review read: each reddened a check, and
each of the seventy-one checks the slice had added or changed was reddened
by one. M8S-6 was first cut with one closing paren too many and did not
load; re-cut, it reddens serve 2, server 8 and shell 8.

### The review's fixes

- The first finding, a forced close logging `read-error ECANCELED` for a
  write it cancelled, is T12 in the core and the slow reader in the shell
  suite; M8C-10, the row taken out, reddens both.
- The ninth rewrote the server step's checks of an event's shape
  (`shaped`): M8S-9, M8S-18 and M8S-19 were re-cut for it.
- The fifth, the listener's failure, is M8H-15: it survives, since libuv
  reports a listener's failure only on Windows. A scope statement.

### Every check the slice added or changed, and a mutant that reddens it

Seventy-four: seventy by name, read from each mutant's own FAIL lines, and
four whose expected value alone changed: the limits suite's drift guard (by
M8L-1 and M8L-2), its variables (M8L-3) and `limits-with` (M8L-5), and the
table's held pairs (M8C-0). The runner prints eight FAIL lines a suite at
most, so the shell's precondition, past M8X-1's eighth, was read from the
suite run by hand on that mutant's root (seventeen failures, the
precondition the twelfth).

- **limits** (2 by name):
  - drain 10 s after a shutdown is asked for: M8L-1
  - drain 3 s -> 3000 ms, and 0 s -> 0 ms; below 0, or not a number, is refused: M8L-4, and 1 more
- **server** (42 by name):
  - the events are design §4.6's four and listener-failed: M8S-29
  - the actions are design §4.6's five and finish-all: M8S-16
  - a server listens, drains, then has stopped: M8S-13
  - the samples name every event, in order: M8S-29
  - every event is one the step takes, in every phase: M8S-13
  - no row asks for an action outside the vocabulary: M8S-13, and 1 more
  - an episode at a cap of one: accepted; refused, logged; refused; accepted, counted: M8S-17, and 2 more
  - a drain: told to finish, one closes, the deadline closes the other, and its close ends it: M8L-1, and 10 more
  - a drain whose connections finish before the deadline is never forced: M8S-4, and 3 more
  - a drain of 0 ms closes what is open at the first tick, at its own instant: M8L-5, and 5 more
  - the step answers with the state it was given, updated: M8S-18, and 1 more
  - an event outside the vocabulary, or one without the time or the count it carries, is a cal: M8S-9
  - so is a tick without its time while draining, and a close without its count: M8S-9, and 1 more
  - a state in no phase, with negative refusals, no limits, no cap, or a deadline not a time i: M8S-10
  - an arrival with fewer open than the cap is accepted: M8S-22
  - so is one that takes the last place: M8S-22
  - an arrival with the cap open is refused, and the first refusal logged: M8S-20
  - a refusal after the first is counted, not logged: M8S-17, and 1 more
  - the cap is the limits': by default 10 000 open are refused: M8S-20
  - and 9 999 open are not: M8S-22
  - an arrival once a place is free is accepted, and the refusals logged with their count: M8S-22
  - a shutdown stops listening, tells the connections open to finish, and arms the drain's dea: M8L-1, and 2 more
  - the deadline is the limits' drain timeout after the shutdown: M8L-5, and 3 more
  - a shutdown during refusals logs their count: M8L-1, and 2 more
  - a shutdown with no connection open stops at once: M8S-5, and 1 more
  - a second shutdown asks for nothing: M8S-23
  - nor does one once stopped: M8S-13, and 2 more
  - an arrival while draining is refused, and not logged: M8S-24
  - and once stopped: M8S-11, and 1 more
  - a listener that fails shuts the server down, logged, and drains as a shutdown does: M8L-1, and 4 more
  - and logs the count of refusals under way: M8L-1, and 4 more
  - and stops at once with no connection open: M8S-5, and 2 more
  - a listener failure while draining asks for nothing: M8S-23
  - a tick asks for nothing while listening: M8S-26
  - nor while draining, before the deadline: M8S-26
  - the first tick at the deadline closes every connection still open, logged: M8S-1, and 3 more
  - and so does the first past it: M8S-1, and 2 more
  - a tick once they have been closed asks for nothing: M8S-26
  - a close asks for nothing while listening: M8S-27
  - nor while draining, connections still open: M8S-28
  - the last close ends the drain: stopped, logged: M8S-4, and 1 more
  - after the deadline too: M8S-4, and 1 more
- **connection-table** (8 by name):
  - T8 any, shutdown-requested: idle closes at once, no response; in flight, close after the r: M8C-0, and 7 more
  - T10 told to finish, handling, handler-responded -> responding: the response says Connectio: M8C-2
  - T11 told to finish, responding, last write-completed -> lingering: shutdown, read-start, a: M8C-2, and 1 more
  - T12 any live state, read-error ECANCELED -> closing: disarm, close, no log: M8C-10
  - ten states: design §4.3's nine, less draining (M8.1), decision 0011's lingering and M6.2's: M8C-0
  - a state outside the ten is refused: M8C-9
  - design §4.4: all 9 termination and error rows have a test, and M8.1's three: M8C-7, and 1 more
  - M5.2: all 3 tick rows left since M8.1 retired draining have a test: M8T-2
- **shell** (15 by name):
  - a shutdown with no connection open closes the listener the clients used, and the server st: M8S-5, and 1 more
  - before the shutdown: a keep-alive client served, a handler waiting, half a head read: M8X-1 (by hand)
  - told to finish, an idle keep-alive connection is closed at once, with no response, while t: M8C-0, and 4 more
  - a request in flight is answered, saying the connection closes, then its client reads the s: M8C-0, and 5 more
  - and the connection closes once its client does, before the drain's deadline asks for anyth: M8C-0, and 5 more
  - a client that holds its connection is closed at the drain's deadline, with no response, on: M8H-2, and 5 more
  - the drain ends with its last connection: the server has stopped, logged, and the shell hol: M8H-2, and 8 more
  - a connection held in its handler, nothing armed, the timer stopped, is closed at the drain: M8H-2, and 7 more
  - and that drain ends: stopped, logged: M8H-2, and 10 more
  - a client that never reads its answer is closed at the drain's deadline, on time, and the w: M8C-10, and 10 more
  - a connection the run loop drops during a drain, its handle closed behind the shell, ends i: M8H-2, and 8 more
  - a shutdown asked once the loop has been held 300 ms dates its drain after the hold: M8H-9, and 1 more
  - when telling each connection to finish raises, each is still told and closed, the first ra: M8H-1, and 7 more
  - a shell that watches signals holds two signal handles, watches once, and closes them once: M8H-7, and 1 more
  - a shell that has stopped is refused a watch, and holds no signal handle: M8H-14
- **serve** (3 by name):
  - serve, sent SIGTERM, drains: the idle client closed at once, the request in flight answere: M8C-1, and 22 more
  - and so does serve sent SIGINT: M8C-1, and 23 more
  - once serve has returned, a SIGINT ends the process at once: M8H-7, and 5 more

## M8.2 — the hand-off door (2026-10-03)

Decided first, as decision 0016, on the owner's "start M8.2"; built in one
working tree, reviewed on the owner's form, then cut into three stacked
steps: the switch, the transport and the 101 (feat/m8.2-switch); the core's
door and the fake transport (feat/m8.2-door); the shell's transport and the
facade (feat/m8.2-transport). Each run took a set of mutants against every
suite of its tree, a frozen copy of the working tree's files, or of the
step's own, main's with the step's files, with vendor and build linked, three
or four at a time. Every mutant in every final run loaded (no `unbound
identifier` and no `Exception in read` in any report).

### The first step: the switch, the transport and the 101

Thirty-three mutants on the step's own tree, after the review: each reddens a
check.

| Mutant | Step | Where | Change | Reddens (suite, failures) |
|---|---|---|---|---|
| M8DR-1 | 1 | `switch` | a switch's accessors swapped | records 2, serializer 20 |
| M8DR-2 | 1 | `switch` | switch? accepts nothing | records 1, serializer 21 |
| M8DR-3 | 1 | `switch` | a switch is a response | records 2, serializer 2 |
| M8DR-4 | 1 | `transport` | a whole write's range a byte short | records 1 |
| M8DR-5 | 1 | `transport` | a disarm hands its procedure #t | records 1 |
| M8DR-6 | 1 | `transport` | transport? accepts nothing | records 1 |
| M8DR-7 | 1 | `transport` | transport? accepts anything | records 1 |
| M8DR-8 | 1 | `transport` | a write of no bytes accepted | records 2 |
| M8DR-9 | 1 | `transport` | reading started with anything | records 2 |
| M8DR-10 | 1 | `transport` | a negative deadline accepted | records 2 |
| M8DR-11 | 1 | `transport` | a drain call that is no procedure accepted | records 2 |
| M8DR-12 | 1 | `transport` | a verb reaches its procedure before its check | records 2 |
| M8DR-13 | 1 | `transport` | a transport made of anything | records 1 |
| M8DS-1 | 1 | `serializer` | the 101 says no Connection | serializer 3 |
| M8DS-2 | 1 | `serializer` | the 101 carries a Date slot | serializer 3 |
| M8DS-3 | 1 | `serializer` | a handler's Connection copied | connection-response 2, connection-table 1, serializer 4 |
| M8DS-4 | 1 | `serializer` | a response written as a 101 | serializer 1 |
| M8DS-5 | 1 | `serializer` | not-a-switch not looked for | serializer 1 |
| M8DS-6 | 1 | `serializer` | invalid-take-over not looked for | serializer 1 |
| M8DS-7 | 1 | `serializer` | a switch's Connection judged as a response's | serializer 2 |
| M8DS-9 | 1 | `serializer` | a switch with no Upgrade accepted | serializer 2 |
| M8DS-10 | 1 | `serializer` | a protocol not offered accepted | serializer 3 |
| M8DS-11 | 1 | `serializer` | protocols compared by their bytes, case and all | serializer 2 |
| M8DS-12 | 1 | `serializer` | only the request's first Upgrade line read | serializer 1 |
| M8DS-13 | 1 | `serializer` | a request's fields that are spans not read | serializer 1 |
| M8DS-14 | 1 | `headers` | an empty element names a protocol | headers 1 |
| M8DS-15 | 1 | `serializer` | a switch's Connection untrimmed | serializer 1 |
| M8DS-16 | 1 | `serializer` | the switch's Upgrade field looked for under another name | serializer 5 |
| M8DS-17 | 1 | `headers` | field-elements leaves the OWS around an element | headers 2 |
| M8DS-18 | 1 | `headers` | field-elements reads only the first field | headers 1 |
| M8DS-20 | 1 | `headers` | field-elements reads a span's whole bytevector | headers 1 |
| M8DS-21 | 1 | `serializer` | a switch's Connection that lists upgrade among others accepted | serializer 1 |
| M8DS-22 | 1 | `serializer` | a switch's fields not checked | serializer 7 |

The step adds thirty-nine checks, each reddened by one of them: the
records suite's fourteen, the switch's (M8DR-1 to M8DR-3) and the
transport's (M8DR-4 to M8DR-13); the serializer's four on the 101 (M8DS-1
to M8DS-4) and its nineteen fault rows, each reddened by the mutant of its
rule (M8DS-5 to M8DS-22), the field rules' five by M8DS-22; and the headers
suite's two on `field-elements` (M8DS-14, M8DS-17, M8DS-18, M8DS-20).

### The second step: the core's door and the fake transport

Forty-one mutants on the step's own tree: each reddens a check. M8DC-1 is
plan §14's: the retained bytes starting a byte late redden the table's
hand-off row, W2, and the contract at every delivery size, as the plan
expects.

| Mutant | Step | Where | Change | Reddens (suite, failures) |
|---|---|---|---|---|
| M8DC-1 | 2 | `connection` | the retained bytes start a byte late (plan §14's mutation) | connection-switch 3, connection-table 1, message-loop 1, outcome-lane 1 |
| M8DC-2 | 2 | `connection` | the hand-off not disarmed | connection-switch 2, connection-table 3 |
| M8DC-3 | 2 | `connection` | handed off as the 101 is asked for, not once written | connection-switch (raised, exit 2, 7 failed), connection-table 8, message-loop 1, outcome-lane 1 |
| M8DC-4 | 2 | `connection` | an HTTP/1.0 request let through | connection-switch 1, connection-table 1 |
| M8DC-5 | 2 | `connection` | a CONNECT let through | connection-switch 1, connection-table 1 |
| M8DC-6 | 2 | `connection` | a request with a body let through | connection-switch 1, connection-table 1 |
| M8DC-7 | 2 | `connection` | a request that does not upgrade let through | connection-switch 1, connection-table 1 |
| M8DC-8 | 2 | `connection` | a switch's faults not looked for | connection-switch 1, connection-table 4 |
| M8DC-9 | 2 | `connection` | a taken stream's close leaves it handed off | connection-switch 3, connection-table 1 |
| M8DC-10 | 2 | `connection` | handed off, bytes fed | connection-table 1 |
| M8DC-11 | 2 | `connection` | handed off, the client's end closes | connection-table 1 |
| M8DC-12 | 2 | `connection` | handed off, a read error closes | connection-table 1 |
| M8DC-13 | 2 | `connection` | handed off, a tick closes | connection-table 1 |
| M8DC-14 | 2 | `connection` | handed off, told to finish closes | connection-table 1 |
| M8DC-15 | 2 | `connection` | handed off, an answer is written | connection-table 1 |
| M8DC-16 | 2 | `connection` | the parser's own hand-off taken again (T7) | connection-table 1 |
| M8DC-17 | 2 | `connection` | the hand-off named otherwise | connection-switch (raised, exit 2, 7 failed), connection-table 4, message-loop 1, outcome-lane 1 |
| M8DC-18 | 2 | `connection` | the take-over kept by a close | connection-table 1 |
| M8DC-19 | 2 | `connection` | the input kept by the hand-off | connection-table 1 |
| M8DC-20 | 2 | `connection` | the take-over kept by the hand-off | connection-table 1 |
| M8DC-21 | 2 | `connection` | the switch's 101 not counted outstanding | connection-switch (raised, exit 2, 5 failed), connection-table 4, message-loop 1, outcome-lane 1 |
| M8DC-22 | 2 | `connection` | no 100 before the 101 | connection-switch 1, connection-table 1 |
| M8DF-1 | 2 | the fake shell | the fake's writes not kept for the client | connection-switch 2 |
| M8DF-2 | 2 | the fake shell | the fake's write told 'done | connection-switch 1 |
| M8DF-3 | 2 | the fake shell | the fake writes after its close | connection-switch 1 |
| M8DF-4 | 2 | the fake shell | the fake's close not told to the taker | connection-switch 2 |
| M8DF-5 | 2 | the fake shell | the fake's close not told to the core | connection-switch 3 |
| M8DF-6 | 2 | the fake shell | the client's end to the core, not the taker | connection-switch 1 |
| M8DF-8 | 2 | the fake shell | the fake's disarm ignored | connection-switch 1 |
| M8DF-9 | 2 | the fake shell | the fake's drain call runs every time | connection-switch 1 |
| M8DF-10 | 2 | the fake shell | the fake's deadline passes at once | connection-switch 2 |
| M8DF-11 | 2 | the fake shell | a read error reaches the taker as the end | connection-switch 1 |
| M8DF-12 | 2 | the fake shell | the fake's read-stop ignored | connection-switch 1 |
| M8DF-13 | 2 | the fake shell | the fake's drain tells a connection not handed off nothing | connection-switch 1 |
| M8DF-14 | 2 | the fake shell | the fake's drain call registered while draining waits | connection-switch 1 |
| M8DF-15 | 2 | the fake shell | the fake arms a deadline on a closed stream | connection-switch 1 |
| M8DF-16 | 2 | the fake shell | the fake's late close call waits | connection-switch 1 |
| M8DT-2 | 2 | the table | a termination row dropped from the table | connection-table 1 |
| M8DT-3 | 2 | the table | a switch row dropped from the table | connection-table 1 |
| M8DX-1 | 2 | the outcome lane | the outcome lane renders a hand-off as nothing handed over | outcome-lane 1 |
| M8DX-2 | 2 | the message loop | the message loop renders a hand-off as nothing handed over | message-loop 1 |

The step adds or changes thirty-seven checks by name, each reddened by one of
them: W1 to W7, their twenty instances each by its own (W3's five by M8DC-4
to M8DC-7, W6's six by M8DC-10 to M8DC-15, W2's two by M8DC-1 and M8DC-2,
W4's four by M8DC-8), the parser's hand-off refused (M8DC-16), what the door
lets go of (M8DC-18 to M8DC-20), the two counts (M8DT-2, M8DT-3); the switch
suite's twenty-three, the core's by the M8DC mutants and the fake
transport's by the M8DF ones; and the message loop's and the outcome lane's
hand-off (M8DX-2, M8DX-1). The libhtp lane renders a hand-off the same way,
but no libhtp stream's handler takes an upgrade, so no check reaches it.

### The third step, and the finished tree: ninety-seven mutants

The third step's twenty-three ran on the finished tree with the first two steps' seventy-four, which had also run on their own steps' trees. The step's are M8DH-1 to M8DH-23, less M8DH-17, and M8DE-1. Each of the seventy-four reddens there what it reddened on its own step's tree, the same count in each suite, and some redden checks the later steps added too.

| Mutant | Step | Where | Change | Reddens (suite, failures) |
|---|---|---|---|---|
| M8DC-1 | 2 | `connection` | the retained bytes start a byte late (plan §14's mutation) | connection-switch 3, connection-table 1, message-loop 1, outcome-lane 1, serve 1, shell 2 |
| M8DC-2 | 2 | `connection` | the hand-off not disarmed | connection-switch 2, connection-table 3, shell 1 |
| M8DC-3 | 2 | `connection` | handed off as the 101 is asked for, not once written | connection-switch (raised, exit 2, 7 failed), connection-table 8, message-loop 1, outcome-lane 1, serve 2, shell (raised, exit 2, 7 failed) |
| M8DC-4 | 2 | `connection` | an HTTP/1.0 request let through | connection-switch 1, connection-table 1 |
| M8DC-5 | 2 | `connection` | a CONNECT let through | connection-switch 1, connection-table 1 |
| M8DC-6 | 2 | `connection` | a request with a body let through | connection-switch 1, connection-table 1 |
| M8DC-7 | 2 | `connection` | a request that does not upgrade let through | connection-switch 1, connection-table 1 |
| M8DC-8 | 2 | `connection` | a switch's faults not looked for | connection-switch 1, connection-table 4 |
| M8DC-9 | 2 | `connection` | a taken stream's close leaves it handed off | connection-switch 3, connection-table 1, shell 1 |
| M8DC-10 | 2 | `connection` | handed off, bytes fed | connection-table 1 |
| M8DC-11 | 2 | `connection` | handed off, the client's end closes | connection-table 1 |
| M8DC-12 | 2 | `connection` | handed off, a read error closes | connection-table 1 |
| M8DC-13 | 2 | `connection` | handed off, a tick closes | connection-table 1 |
| M8DC-14 | 2 | `connection` | handed off, told to finish closes | connection-table 1 |
| M8DC-15 | 2 | `connection` | handed off, an answer is written | connection-table 1 |
| M8DC-16 | 2 | `connection` | the parser's own hand-off taken again (T7) | connection-table 1 |
| M8DC-17 | 2 | `connection` | the hand-off named otherwise | connection-switch (raised, exit 2, 7 failed), connection-table 4, message-loop 1, outcome-lane 1, serve 2, shell (raised, exit 2, 7 failed) |
| M8DC-18 | 2 | `connection` | the take-over kept by a close | connection-table 1 |
| M8DC-19 | 2 | `connection` | the input kept by the hand-off | connection-table 1 |
| M8DC-20 | 2 | `connection` | the take-over kept by the hand-off | connection-table 1 |
| M8DC-21 | 2 | `connection` | the switch's 101 not counted outstanding | connection-switch (raised, exit 2, 5 failed), connection-table 4, message-loop 1, outcome-lane 1, serve 1, shell (raised, exit 2, 0 failed) |
| M8DC-22 | 2 | `connection` | no 100 before the 101 | connection-switch 1, connection-table 1 |
| M8DE-1 | 3 | the facade | the facade without the close call | serve 1 |
| M8DF-1 | 2 | the fake shell | the fake's writes not kept for the client | connection-switch 2 |
| M8DF-2 | 2 | the fake shell | the fake's write told 'done | connection-switch 1 |
| M8DF-3 | 2 | the fake shell | the fake writes after its close | connection-switch 1 |
| M8DF-4 | 2 | the fake shell | the fake's close not told to the taker | connection-switch 2 |
| M8DF-5 | 2 | the fake shell | the fake's close not told to the core | connection-switch 3 |
| M8DF-6 | 2 | the fake shell | the client's end to the core, not the taker | connection-switch 1 |
| M8DF-8 | 2 | the fake shell | the fake's disarm ignored | connection-switch 1 |
| M8DF-9 | 2 | the fake shell | the fake's drain call runs every time | connection-switch 1 |
| M8DF-10 | 2 | the fake shell | the fake's deadline passes at once | connection-switch 2 |
| M8DF-11 | 2 | the fake shell | a read error reaches the taker as the end | connection-switch 1 |
| M8DF-12 | 2 | the fake shell | the fake's read-stop ignored | connection-switch 1 |
| M8DF-13 | 2 | the fake shell | the fake's drain tells a connection not handed off nothing | connection-switch 1 |
| M8DF-14 | 2 | the fake shell | the fake's drain call registered while draining waits | connection-switch 1 |
| M8DF-15 | 2 | the fake shell | the fake arms a deadline on a closed stream | connection-switch 1 |
| M8DF-16 | 2 | the fake shell | the fake's late close call waits | connection-switch 1 |
| M8DH-1 | 3 | `shell` | the take-over never called | serve 2, shell (raised, exit 2, 7 failed) |
| M8DH-2 | 3 | `shell` | the taker's close call never run | shell 3 |
| M8DH-3 | 3 | `shell` | a taker that raises leaves its stream open | shell 3 |
| M8DH-4 | 3 | `shell` | the taker's close cuts its writes short | shell 1 |
| M8DH-5 | 3 | `shell` | a write after the close is written | shell 1 |
| M8DH-6 | 3 | `shell` | a taken stream leaves the table | shell 9 |
| M8DH-7 | 3 | `shell` | a taken stream's deadline ticks the core | shell 2 |
| M8DH-8 | 3 | `shell` | a taker's deadline starts no timer | shell 2 |
| M8DH-9 | 3 | `shell` | the drain tells a taker nothing | shell 2 |
| M8DH-10 | 3 | `shell` | a drain call registered while draining waits | shell 1 |
| M8DH-11 | 3 | `shell` | a write refused at the call not told | shell 3 |
| M8DH-12 | 3 | `shell` | reading restarted without stopping | shell 1 |
| M8DH-13 | 3 | `shell` | reading begun on a closed stream | shell 1 |
| M8DH-14 | 3 | `shell` | a deadline armed on a closed stream | shell 1 |
| M8DH-15 | 3 | `shell` | a taker's values handed back to chez-libuv | shell (raised, exit 2, 0 failed) |
| M8DH-16 | 3 | `shell` | the bytes handed over as the core's span | serve 1, shell 5 |
| M8DH-18 | 3 | `shell` | the shell's read-stop verb ignored | shell 1 |
| M8DH-19 | 3 | `shell` | the shell's disarm ignored | shell 1 |
| M8DH-20 | 3 | `shell` | the shell's drain call runs every time | shell 1 |
| M8DH-21 | 3 | `shell` | reading started only while it reads | serve 2, shell 9 |
| M8DH-22 | 3 | `shell` | a write counted before libuv takes it | shell 4 |
| M8DH-23 | 3 | `shell` | a close call registered late waits | shell 1 |
| M8DR-1 | 1 | `switch` | a switch's accessors swapped | connection-switch (raised, exit 2, 8 failed), connection-table 10, message-loop 1, outcome-lane 1, records 2, serializer 20, serve 1, shell (raised, exit 2, 7 failed) |
| M8DR-2 | 1 | `switch` | switch? accepts nothing | connection-switch (raised, exit 2, 8 failed), connection-table 16, message-loop 1, outcome-lane 1, records 1, serializer 21, serve 1, shell (raised, exit 2, 7 failed) |
| M8DR-3 | 1 | `switch` | a switch is a response | clients 14, connection-allocation (raised, exit 2, 4 failed), connection-body 12, connection-deadlines 3, connection-entry 4, connection-expect 9, connection-head 16, connection-linger 9, connection-originated 1, connection-padding 9, connection-response 22, connection-retention 2, connection-stream 16, connection-table 17, contract 3, libhtp-lane 15, message-loop 9, outcome-lane 3, ratchet 1, records 2, serializer 2, serve 4, shell 60 |
| M8DR-4 | 1 | `transport` | a whole write's range a byte short | connection-switch 1, records 1, serve 1, shell 6 |
| M8DR-5 | 1 | `transport` | a disarm hands its procedure #t | records 1 |
| M8DR-6 | 1 | `transport` | transport? accepts nothing | records 1 |
| M8DR-7 | 1 | `transport` | transport? accepts anything | records 1 |
| M8DR-8 | 1 | `transport` | a write of no bytes accepted | records 2 |
| M8DR-9 | 1 | `transport` | reading started with anything | records 2 |
| M8DR-10 | 1 | `transport` | a negative deadline accepted | records 2 |
| M8DR-11 | 1 | `transport` | a drain call that is no procedure accepted | records 2 |
| M8DR-12 | 1 | `transport` | a verb reaches its procedure before its check | records 2 |
| M8DR-13 | 1 | `transport` | a transport made of anything | records 1 |
| M8DS-1 | 1 | `serializer` | the 101 says no Connection | connection-switch 4, connection-table 6, serializer 3, serve 1, shell 11 |
| M8DS-2 | 1 | `serializer` | the 101 carries a Date slot | connection-switch 4, connection-table 6, serializer 3, serve 1, shell 10 |
| M8DS-3 | 1 | `serializer` | a handler's Connection copied | connection-response 2, connection-table 1, serializer 4 |
| M8DS-4 | 1 | `serializer` | a response written as a 101 | serializer 1 |
| M8DS-5 | 1 | `serializer` | not-a-switch not looked for | serializer 1 |
| M8DS-6 | 1 | `serializer` | invalid-take-over not looked for | connection-table 1, serializer 1 |
| M8DS-7 | 1 | `serializer` | a switch's Connection judged as a response's | serializer 2 |
| M8DS-9 | 1 | `serializer` | a switch with no Upgrade accepted | connection-table 1, serializer 2 |
| M8DS-10 | 1 | `serializer` | a protocol not offered accepted | connection-switch 1, connection-table 1, serializer 3 |
| M8DS-11 | 1 | `serializer` | protocols compared by their bytes, case and all | serializer 2 |
| M8DS-12 | 1 | `serializer` | only the request's first Upgrade line read | serializer 1 |
| M8DS-13 | 1 | `serializer` | a request's fields that are spans not read | connection-switch (raised, exit 2, 8 failed), connection-table 7, message-loop 1, outcome-lane 1, serializer 1, serve 1, shell (raised, exit 2, 7 failed) |
| M8DS-14 | 1 | `headers` | an empty element names a protocol | headers 1 |
| M8DS-15 | 1 | `serializer` | a switch's Connection untrimmed | serializer 1 |
| M8DS-16 | 1 | `serializer` | the switch's Upgrade field looked for under another name | connection-switch (raised, exit 2, 8 failed), connection-table 7, message-loop 1, outcome-lane 1, serializer 5, serve 1, shell (raised, exit 2, 7 failed) |
| M8DS-17 | 1 | `headers` | field-elements leaves the OWS around an element | headers 2 |
| M8DS-18 | 1 | `headers` | field-elements reads only the first field | headers 1 |
| M8DS-20 | 1 | `headers` | field-elements reads a span's whole bytevector | headers 1 |
| M8DS-21 | 1 | `serializer` | a switch's Connection that lists upgrade among others accepted | serializer 1 |
| M8DS-22 | 1 | `serializer` | a switch's fields not checked | connection-table 1, serializer 7 |
| M8DT-2 | 2 | the table | a termination row dropped from the table | connection-table 1 |
| M8DT-3 | 2 | the table | a switch row dropped from the table | connection-table 1 |
| M8DX-1 | 2 | the outcome lane | the outcome lane renders a hand-off as nothing handed over | outcome-lane 1 |
| M8DX-2 | 2 | the message loop | the message loop renders a hand-off as nothing handed over | message-loop 1 |

Each reddens a check. There is no M8DS-8 or M8DS-19: the numbers were skipped. M8DF-7, M8DH-17 and M8DT-1 were withdrawn before the review (below). Plan §14's mutation, M8DC-1, the retained bytes starting a byte late, reddens the table's hand-off row, W2, and the contract at every delivery size, as on the second step's tree. On the finished tree it also reddens the shell's door and the facade's.

M8DH-15, a taker's call handing what it returns back to chez-libuv, reddens the shell suite by raising: the shell's close callback returns no values to chez-libuv, which raises, and the run loop with it. That is the failure the shell's dropping of a taker's return values was found by (decision 0016's list).

### Before the review

A first run, of seventy-seven mutants on an earlier copy of the tree, left seven survivors, and checks that no mutant reddened:
- M8DF-7, the fake's deadline passing again, and M8DH-17, the end of a taker's reading reported twice, survived: the code they changed was redundant, since the wheel calls an entry once and libuv reports a read's end once. It was taken out and the two withdrawn; M8DH-13 was re-cut once the guard was gone.
- M8DF-8, the fake's disarm ignored; M8DF-9, the fake's drain call run every time; M8DH-4, the taker's close cutting its writes short; and M8DH-8, a taker's deadline starting no timer, survived: no check could tell. Four checks were added: a deadline disarmed leaving none armed, a drain call registered again not run, a taker's close waiting for a 4 MiB write still under way, and a deadline armed with the timer stopped.
- M8DT-1, a switch row dropped from the table, survived: it renamed a row and dropped nothing. Re-cut as M8DT-3.
- Letting the parser go at the hand-off had no check that could see it, and was taken out.
- Eleven mutants were added for checks no mutant yet reddened, among them the checks just added and W7: M8DC-22, M8DF-11 to M8DF-14, M8DH-18 to M8DH-21, M8DS-16 and M8DT-2.
- M8DH-2 was first cut with one closing paren too many and did not load. Re-cut, it returned no values to chez-libuv's callback, which raised; cut a third time, it reddens three of the shell's checks.

Then eighty-six, on the tree the review read: each reddened a check, and each of the eighty-four checks the slice had added or changed was reddened by one.

### The review's fixes

- The ninth, `field-elements` shared: M8DS-17, M8DS-18 and M8DS-20 in the headers suite; M8DS-9 to M8DS-13 re-cut for the serializer's new reading, and M8DS-14 moved to `field-elements`.
- The third, the renderers: M8DX-1 and M8DX-2.
- The seventh and eighth, on the fake transport: M8DF-15 and M8DF-16; M8DF-8 re-cut.
- The second, a write counted once libuv has taken it: M8DH-22; M8DH-11 re-cut.
- The eighth, on the shell: M8DH-23; M8DH-2 re-cut.
- The first, the docs on bounding a taker's writes: no mutant, docs only.
- M8DS-21 and M8DS-22 were added on the first step's own tree, for two of its checks no mutant reddened there: a switch's Connection that lists `upgrade` among others, and the field rules' five.

### Every check the slice added or changed, and a mutant that reddens it

Ninety-seven, by name, read from each mutant's own FAIL lines on the finished tree. The table's W rows have twenty instances under seven names; each instance is reddened by its own mutant, as on the second step's tree, the table suite and the core being the same there. The runner prints eight FAIL lines a suite at most; no check here is named only past that cap.

- **records** (14):
  - a switch's headers read back: M8DR-1
  - its take-over reads back: M8DR-1
  - switch? accepts: M8DR-2
  - a switch is no response: M8DR-3
  - a response is no switch: M8DR-3
  - each verb calls its procedure, the arguments in one shape: M8DR-4, and 2 more
  - transport? accepts: M8DR-6
  - transport? rejects a switch: M8DR-7
  - a write of no bytes, outside its bytevector, of no bytevector, or with a callback that is : M8DR-8
  - reading is started with two procedures, or refused: M8DR-9
  - a deadline is a count of milliseconds with a procedure, or #f alone, or refused: M8DR-10
  - the drain's and the close's calls are procedures, or refused: M8DR-11
  - and no refused verb reached its procedure: M8DR-8, and 4 more
  - a transport is made of seven procedures, or refused: M8DR-13
- **shell** (19):
  - through the door: the 101, then the frame sent with the handshake, written back, the conne: M8DC-1, and 11 more
  - a frame sent later comes back after it; the client's end reaches the taker, which closes, : M8DC-1, and 15 more
  - a taker that raises: logged taker-failed, the stream closed after the 101: M8DC-3, and 9 more
  - the taker's close follows its write; a write after the close is cancelled, its callback to: M8DC-3, and 10 more
  - the taker's close waits for a write still under way: its client reads all of it, then the : M8DC-3, and 10 more
  - a write refused at the call: its callback is told the errno, and the taker's close closes : M8DC-3, and 8 more
  - a taker that stops reading reads nothing more while it is stopped: M8DC-3, and 9 more
  - started again, it reads what waited, then the client's end: M8DH-21
  - a write refused off the loop's thread raises to its caller, and leaves the taker's close f: M8DH-22, and 2 more
  - reading started again while it reads: the second callbacks take the reads, the first hears: M8DH-12, and 3 more
  - a taken stream counts against max-connections: a second client is refused while it is open: M8DH-6, and 1 more
  - and once it has closed, the next client is served: M8DH-6, and 2 more
  - a taker's deadline, armed with the timer stopped, passes the first time the timer fires at: M8DC-2, and 3 more
  - a taker's deadline is the stream's one entry in the wheel, and disarmed leaves none: M8DH-19
  - told the server drains, a taker says goodbye and closes; the drain ends then, before its d: M8DH-6, and 4 more
  - a taker that ignores the drain has its stream closed at the deadline, on time, its close t: M8DH-2, and 4 more
  - on a stream the server has closed, a write is cancelled, reading and a deadline begin noth: M8DH-2, and 4 more
  - a drain call runs once: one registered again while the server drains is not run: M8DH-6, and 2 more
  - a switch answered while the server drains: its taker's drain call runs as it is registered: M8DH-10, and 1 more
- **serve** (2):
  - the facade exports the handler's names, the verbs it waits with, a switch and the transpor: M8DE-1
  - a handler takes an upgrade with the facade's names alone: the 101, then what its taker wri: M8DC-1, and 13 more
- **headers** (2):
  - field-elements: a list's elements, over every line of the field, in order, the OWS trimmed: M8DS-14, and 2 more
  - field-elements reads a span's list within its bounds: M8DS-17, and 1 more
- **message-loop** (1):
  - a WebSocket handshake taken by a switch, read whole: its 101, then handed off with the byt: M8DC-1, and 8 more
- **outcome-lane** (1):
  - the instrument renders a hand-off: a handshake taken, the bytes after it handed over: M8DC-1, and 8 more
- **serializer** (23):
  - a WebSocket's 101: the status line, its fields, Connection: upgrade, the blank line; two s: M8DR-1, and 3 more
  - a handler's Connection is not copied, and its Date is: M8DR-1, and 4 more
  - what a client reads: a 101 and its fields, the server's Connection among them, nothing aft: M8DR-1, and 3 more
  - what is not a switch is not written as one: M8DR-3, and 1 more
  - a switch: a response is no switch: M8DR-3, and 1 more
  - a switch: a take-over that is no procedure: M8DR-2, and 1 more
  - a switch: headers that are not a list: M8DR-1, and 2 more
  - a switch: a name with a space: M8DR-1, and 2 more
  - a switch: a value with a CR: M8DR-1, and 2 more
  - a switch: a Content-Length: M8DR-1, and 2 more
  - a switch: a Transfer-Encoding: M8DR-1, and 1 more
  - a switch: a Connection: close: M8DS-7, and 1 more
  - a switch: a Connection: upgrade, close: M8DS-21, and 1 more
  - a switch: no Upgrade: M8DS-9
  - a switch: an Upgrade naming nothing: M8DS-9
  - a switch: an Upgrade the request did not offer: M8DS-10
  - a switch: an offered protocol and one not: M8DS-10
  - a switch: a request that offered none: M8DS-10
  - a switch: the protocol the request offered: M8DS-16
  - a switch: in another case, compared without regard to it (§7.8's SHOULD): M8DS-11, and 1 more
  - a switch: one of the request's list, and of its second line: M8DS-11, and 2 more
  - a switch: a handler's own Connection: Upgrade: M8DS-7, and 2 more
  - a switch: a request's fields that are spans: M8DS-13, and 1 more
- **connection-switch** (23):
  - at every delivery size: the bytes handed over, then those read on, are exactly the bytes a: M8DC-1, and 9 more
  - some delivery sizes hand bytes over, and some hand none: M8DC-3, and 6 more
  - read whole, every byte after the request is handed over: M8DC-1, and 7 more
  - a handshake expecting 100-continue reads the 100, then the 101: M8DC-21, and 7 more
  - the core's part, from the handler's call: the 101 written, then the hand-off, disarmed fir: M8DC-2, and 7 more
  - the taker's writes follow the 101, in order: M8DC-3, and 8 more
  - each write's callback is told it is written, in order: M8DC-3, and 6 more
  - closed by the taker: its write first, its close call once, a later write cancelled, the co: M8DC-3, and 13 more
  - a close call registered after the stream has closed runs at once: M8DC-9, and 3 more
  - on a stream that has closed, a deadline arms nothing and never passes: M8DC-2, and 3 more
  - the client's end reaches the taker, and the core is not told: M8DF-6
  - a read error reaches the taker as its errno: M8DF-11
  - a taker that stops reading is handed nothing more: one read, the rest of the input not del: M8DC-1, and 1 more
  - a deadline passes once its time has come, and once: M8DF-10
  - a deadline disarmed never passes, and leaves nothing armed: M8DF-8, and 1 more
  - the drain call runs once the shell drains, once, a call registered after it never: M8DF-9
  - a switch answered while the shell drains: its drain call runs as it is registered: M8DF-14
  - a connection not handed off is told to finish: idle, it closes: M8DF-13
  - a request that does not upgrade, answered a switch: 500, logged not-an-upgrade, the staged: M8DC-7
  - an HTTP/1.0 upgrade (RFC 9110 §7.8: its Upgrade ignored): the same: M8DC-4
  - a CONNECT: the same: M8DC-5
  - an upgrade with a body, answered at its head: the same: M8DC-6
  - a switch to a protocol the request did not offer: 500, logged invalid-upgrade: M8DC-8, and 1 more
- **connection-table** (12):
  - W1 handling, handler-responded with a switch, the door open -> responding: the 101's write: M8DC-3, and 6 more
  - W2 responding, the 101's last write-completed -> handed-off: disarm, the hand-off, the byt: M8DC-1, and 10 more
  - W3 handling, handler-responded with a switch, the door closed -> responding 500, close-aft: M8DC-4, and 4 more
  - W4 handling, handler-responded with a switch with a fault, the door open -> responding 500: M8DC-8, and 5 more
  - W5 handed-off, closed -> closed: M8DC-9
  - W6 handed-off, any other event -> handed-off: nothing: M8DC-10, and 5 more
  - W7 handling, handler-responded with a switch, the request expecting 100-continue -> respon: M8DC-3, and 5 more
  - a hand-off on the parser's pause channel is refused, in head and in body: M8DC-16
  - handed off, the core keeps no input, request or take-over: M8DC-3, and 9 more
  - a 101 cut short by a read error closes, its take-over let go: M8DC-3, and 5 more
  - design §4.4: 8 of the 9 termination and error rows have a test, T7 retired (M8.2), and M8.: M8DT-2
  - M8.2: all 7 switch rows have a test: M8DT-3

## M8.3 — the black-box and robustness lanes (2026-10-04)

Built from main at 3ab1934 on the owner's "Start m8.3", after measuring six
surveyed corpora in a scratch tree (progress.md, M8.3) and two decisions by
form: HTTP/0.9 is refused 505, and the black-box lane uses curl and vtest2.
Platform: Darwin arm64, Chez 10.4.1 (`tarm64osx`), libuv 1.52.1, 2026-10-04,
the library path as above. Each mutant ran from a scratch copy of its edited
file against every suite, four at a time; every one loaded (no `Exception` in
any report).

### The first step: the robustness lane, and HTTP/0.9

The step adds `(robustness-lane)` and `tests/test-robustness-lane.sps` over
AWS http-desync-guardian's 162 vendored cases (decision 0007, through
`tests/provenance.sls` and `tests/guardian-corpus.sls`), promotes libhtp's 24
invalid streams and 4 HTTP/0.9 streams in the ratchet, and gives the core one
new rule: a request with no version (HTTP/0.9) is refused 505,
`version-not-supported`, judged first at on-headers-complete.

Seven mutants, each named for what it breaks, every one reverted:

| mutant | the edit | suites red (failures) |
|---|---|---|
| M8R-V1 | the HTTP/0.9 refusal removed from `conn-headers-complete-step` | head (4), originated (1), padding (1), cut-off (1), libhtp-lane (2), trace (1), ratchet (1), robustness (1) |
| M8R-V2 | `version-not-supported` mapped to 400, not 505, in `(http-server decisions)` | head (4), originated (1), padding (1), cut-off (1), decisions (1), libhtp-lane (2), ratchet (1) |
| M8R-V3 | the version judged after the Host, not before | head (1): "the version is judged before the Host and the framing" |
| M8R-G1 | guardian's request built with LF, not CRLF, between fields | robustness (2): "severe.yaml#1 is read as its bytes", the property gate |
| M8R-G2 | a served case dropped from `served-cases` | robustness (2): "30 cases reach the handler", the property gate |
| M8R-G3 | a Severe case added to `served-cases` | robustness (3): the two above, and "no Severe case is in the serve manifest" |
| M8R-L1 | a libhtp 0.9 stream's expectation set to served, not 505 | libhtp-lane (1), ratchet (1) |

Two readings the table shows, each a check the slice relies on:
- M8R-V2 leaves `robustness` and `trace` green where M8R-V1 reddens them: a
  405-or-more status is still a refusal (the serve manifest holds), and the
  trace lane gates the refusal's reason, not its status. So the status map
  (decisions) and the refusal itself (head, originated) are witnessed apart.
- M8R-V3 reddens only the one head check that asserts the version is judged
  before the Host, so the order is tested, not just the refusal.

Two more checks were witnessed by hand, not by `mut.py` (one mutates vendored
data, the other needs the loader made lenient):
- flipping one byte of a vendored guardian file reddened `robustness` with a
  provenance failure, exit 3 (`test/vendor/http-desync-guardian/tests/single-case.yaml`:
  "expected sha256 … but computed …");
- making the YAML loader skip an unindented line it does not know, instead of
  refusing it, reddened "the loader refuses an unindented line that is not a
  case".

### The first step's review, and its fixes: twelve mutants

A `/code-review high` found ten (progress.md, M8.3). The owner chose by form to
refuse every version that is not 1.x (the first), and to fix the second to the
ninth and note the tenth. The fixes changed the version rule's line and the
reason's comment, so the first step's seven were re-cut to the new text and
run again on the fixed tree, beside five new ones; every one loaded and matched
once.

| mutant | the edit | suites red (failures) |
|---|---|---|
| M8R-V1 | the version refusal removed | head (5), originated (1), padding (1), cut-off (1), libhtp-lane (2), trace (1), ratchet (1), robustness (1) |
| M8R-V2 | `version-not-supported` mapped to 400 | head (5), originated (1), padding (1), cut-off (1), decisions (1), libhtp-lane (2), ratchet (1) |
| M8R-V3 | the version judged after the Host | head (1): "the version is judged before the Host and the framing" |
| M8R-V4 | only major 0 refused, as before the review | head (1): "a request line that says HTTP/2.0, which the parser reads: 505" |
| M8R-G1 | guardian's request built with LF between fields | robustness (3): the probe case's request, "severe.yaml#1 is read as its bytes", the property gate |
| M8R-G2 | a served case dropped from `served-cases` | robustness (2) |
| M8R-G3 | a Severe case added to `served-cases` | robustness (3), "no Severe case is in the serve manifest" among them |
| M8R-G4 | the loader reads on past two spaces after a key's colon | robustness (1): "the loader refuses two spaces after a key's colon, …, and a plain scalar's comment" |
| M8R-G5 | the loader reads a plain scalar's comment as its text | robustness (1): the same check |
| M8R-L1 | a libhtp 0.9 stream's expectation set to served | libhtp-lane (1), ratchet (1) |
| M8R-P1 | the provenance walk keeps dotfiles | robustness, exit 3 (1): "the files a refresh writes leave out every dotfile", then the manifest's failure |
| M8R-S1 | the size scan ignores the selection, every size always | robustness (1): "the runs are the corpus lanes' schedule" |

M8R-P1 first ran with the dotfile check after the manifest's, and reddened the
suite only through `verify-provenance!`'s exit 3, the named check never reached
(passes 2, failures 0): the tree's own `.gitattributes`, which the walk then
kept, is unlisted. The check moved before the manifest's, and the re-run above
names it.

Witnessed by hand, beside these: one more file vendored with its sha256 line
and the count raised to 14 reddened "PROVENANCE lists LICENSE, NOTICE, the
README and the ten YAML files", now a `test-eqv` (the review's seventh); and
the first step's two (a flipped vendored byte, exit 3; a lenient loader).

### The second step: the strictness lane, fifteen mutants

The step adds `(strictness-lane)` and `tests/test-strictness-lane.sps` over
Kestrel's parsing tables, httpd's `http_strict.t` and lighttpd's `request.t`
(355 cases), each read by a reader of its own (`tests/kestrel-corpus.sls`,
`tests/httpd-corpus.sls`, `tests/lighttpd-corpus.sls`). It changes no source
under `src/`, so each mutant is in the lane or a reader; every one loaded and
matched once, and each reddened the strictness suite and no other.

| mutant | the edit | the strictness suite's failures |
|---|---|---|
| M8S-D1 | a departure dropped (httpd row 15, HTTP/1.2) | the lane: "every case agrees with its source, or departs as listed" |
| M8S-D2 | a case that agrees listed as a departure (httpd row 1) | the lane |
| M8S-H1 | httpd's cases take the lenient column, not the strict | the lane |
| M8S-H2 | httpd's reader keeps an undef strict expectation | "httpd's row 41: the strict host expects what the lenient one does" |
| M8S-K1 | `RequestLineInvalidData` appends no non-token methods | "the cases: Kestrel 237, httpd 77, lighttpd 41" |
| M8S-K2 | Kestrel's reader decodes `\r` as LF | the end-to-end requests, the lane |
| M8S-K3 | the tail check reports every table | "Kestrel's three tables that append others still append as ported" |
| M8S-C1 | `complete-head` completes nothing | the end-to-end requests, `complete-head`'s own, the lane |
| M8S-L1 | lighttpd's transform leaves LF unconverted | the end-to-end requests, the lane |
| M8S-L2 | lighttpd's scope takes a module section too | the counts, lighttpd's and the cases' |
| M8S-V1 | the verdict counts an interim 100 as a response | the lane |
| M8S-V2 | the verdict calls an unanswered case served | the lane |
| M8S-R1 | httpd's reader takes a word as an expectation | "the readers refuse an unknown table, an unknown value, an unknown line" |
| M8S-R2 | lighttpd's reader skips a line no block shape is | the same |
| M8S-S1 | the size scan ignores the selection | "the runs are the corpus lanes' schedule" |

M8S-L1 first left the end-to-end check green: its lighttpd case was the first
block, one line, with no LF inside for the transform to make CRLF. The check
moved to the third block, three lines, and the re-run above names it.

### The second step's review, and its fixes: thirty-three mutants on the fixed tree

A `/code-review high` found ten, all fixed on the owner's word ("Fix all ten";
progress.md, M8.3). The fixes touched the first step's files too, shared now:
`(corpus-text)` for the readers' string helpers and `(corpus-scan)` for the
delivery sizes both lanes take. So every M8.3 mutant ran again on the fixed
tree against every suite, the specs re-cut where the fixes changed the text
they quote: the first step's eleven (the core's four, the robustness lane's
seven), the second step's fourteen, and eight new. Every one loaded and
matched once, and every one reddened a suite.

| new mutant | the edit | suites red (failures) |
|---|---|---|
| M8C-S1 | the shared schedule ignores the selection (replaces M8R-S1, M8S-S1) | robustness (1), strictness (1): each lane's schedule check |
| M8C-T1 | the shared `split` drops an empty part | strictness (3): lighttpd's blocks, whose pipelined heredocs hold empty lines |
| M8C-G6 | guardian's cache returns the first file read, whatever the file | robustness (5) |
| M8S-D3 | a departure is held only to differ from its source | strictness (1): "a departure listed with a verdict this server does not give is a mismatch" |
| M8S-C2 | `complete-head` completes a header section ended by CRLF too | strictness (2): `complete-head`'s own, the lane |
| M8S-H3 | httpd leaves out every gated row, the version-gated ones too | strictness (1): "the cases: Kestrel 237, httpd 79, lighttpd 41" |
| M8S-K4 | Kestrel's reader takes an array opened on its constructor's line | strictness (1): "Kestrel's reader refuses an array opened on its constructor's line, and a row past ASCII" |
| M8S-K5 | Kestrel's reader takes a row past ASCII | strictness (1): the same |

Readings the re-run gave:
- M8R-V1 and M8R-V4 redden the strictness lane too: with HTTP/0.9 or HTTP/2.0
  served, httpd's rows 41 and 14 agree with httpd and are listed departures.
- M8C-T1 leaves the robustness lane green: guardian's YAML loader skips empty
  lines anyway, so the shared `split` dropping them is no fault there.
- M8R-P1 ended the strictness suite with exit 1, not 3: its `verify-provenance!`
  ran inside a check's expression, which took the provenance failure for its
  own. Moved out of the check, as the robustness suite has it, and re-run: both
  suites exit 3, the provenance failure the vocabulary names.

Witnessed by hand: the refresh script, run against a checkout without the
corpus's files, emptied a scratch copy of `test/vendor/kestrel` (exit 1) before
the fix, and kept it, exit 2 by name, after.

### The third step: the black-box lane, thirty-four mutants

The step adds vtest2 (decision 0017: a submodule at the archived mirror's `last`
tag, built by `make vtest`), twelve scripts under `tests/vtc/`, a section of
`tests/test-clients.sps` that runs each against a server of the lane's own and
holds it to a manifest both ways, and five curl checks. It changes no source
under `src/`. Each mutant ran against the clients suite, the lane's (M8B-P1
against the shell suite, whose check it is); a mutant in `src/` reddens other
suites too, which the first two steps' runs already cover. Every one loaded and
matched once. A script's failure is read off the suite's `VTEST` line, its
first `----` line naming the client and the expectation; vtest stops a script
at its first failure, so each client was given a mutant of its own.

| mutant | the edit | the clients suite's failures (the script, its client) |
|---|---|---|
| M8B-K1 | every request closes after its response | the verdicts (keep-alive, http10 c2, head, chunked-upload, stream c1); five M4 curl checks; ab -k |
| M8B-H1 | no `Connection: keep-alive` to a 1.0 client kept | the verdicts (http10 c2); ab -k |
| M8B-H2 | no `Connection: close` on a last response | the verdicts (http10 c1 and six others: five on their `Connection` lines, stream c2 on an incomplete head); both servers' log checks; the M4 1.0 stream check |
| M8B-D1 | a HEAD's answer framed as a GET's, content written | the verdicts (head c1: status `-`, the stray body read as a status line); the M4 HEAD check |
| M8B-E1 | no 100 to a request expecting it | the verdicts (expect c1: 408); the M4 Expect check |
| M8B-E2 | a 100 to HTTP/1.0 too | the verdicts (expect c2: 100) |
| M8B-W1 | `read-whole-body` hands on an empty body | the verdicts (chunked-upload c1, expect c1) |
| M8B-T1 | a streamed body close-delimited to 1.1 | the verdicts (stream c1); the M4 chunked stream check |
| M8B-T2 | a streamed body chunked to 1.0 | the verdicts (stream c2); the M4 1.0 stream check |
| M8B-V1 | a version not 1.x served | the verdicts (version c1: 200) |
| M8B-V4 | HTTP/0.9 refused, HTTP/2.0 served | the verdicts (version c2: 200) |
| M8B-V2 | the HTTP/2 preface ignored | the verdicts (version c3: 408, the lane's header deadline); curl --http2-prior-knowledge, killed at the cap |
| M8B-V3 | the parser's refusal answered 500 | the verdicts (framing c1, version c4) |
| M8B-U1 | an upgrade not taken keeps its connection | the verdicts (upgrade c1); curl --http2 |
| M8B-R1 | a bracket or pipe target refused 400 | the verdicts (redirect c1: 400); curl -g -L |
| M8B-R2 | a POST's bracket target redirected too | the verdicts (redirect c2: 301) |
| M8B-L1 | no target limit | the verdicts (limits c1: 200) |
| M8B-L2 | no field-value limit in a head | the verdicts (limits c2: 200) |
| M8B-L3 | no server body cap, at the head or as it arrives | the verdicts (limits c3: 200) |
| M8B-O1 | a head past its deadline closed with no 408 | the verdicts (timeouts c1) |
| M8B-O2 | a body past its deadline closed with no 408 | the verdicts (timeouts c2) |
| M8B-O3 | an idle connection never closed | the verdicts (timeouts: vtest killed at the cap) |
| M8B-F2 | a duplicate Content-Length's refusal, the parser's `unexpected-content-length`, answered 500 | the verdicts (framing c2: 500) |
| M8B-F3 | a coding before a final chunked served | the verdicts (framing c3: 200) |
| M8B-F4 | Transfer-Encoding below HTTP/1.1 served | the verdicts (framing c4: 200) |
| M8B-F5 | an HTTP/1.1 request without Host served | the verdicts (framing c5: 200) |
| M8B-S1 | one script not run | "the scripts in tests/vtc are the manifest's"; the verdicts |
| M8B-S2 | the manifest lists a passing script as failing | the verdicts (`version.vtc` passed, listed failed) |
| M8B-S3 | a closed connection never leaves the table | the lane's table, log and nothing-left checks; the M4 table and nothing-left checks |
| M8B-S4 | the lane's handler raises for `/h` | the verdicts (head c1: 500); the lane's log check |
| M8B-S5 | the lane's server never shut down | the lane's log and nothing-left checks |
| M8B-C4 | `OPTIONS *` read as the path `/` | curl: OPTIONS * |
| M8B-C5 | the path a handler reads has its dot segments removed (uriparse's `remove-dot-segments`) | curl --path-as-is |
| M8B-P1 | the test client never finishes a read the close ends | the shell suite: "a 200 with Connection: close and no framing field, the body read whole at the close" (brief risk 4) |

M8B-D1 first left `head.vtc` green: the GET after the HEAD checked its body
and its length, not its status, and vtest read the stray body as that
response's status line, the rest following as fields. Every `rxresp` in the
lane is now followed by a status check (37), and the re-run above names the
script.

`framing.vtc`'s c1 and c2 are the parser's refusals, so M8B-V3 reddens c1 and
the script stops there. Their codes differ, `invalid-transfer-encoding` and
`unexpected-content-length` (read off the parser in scratch), so M8B-F2 answers
the second alone 500. Witnessed by hand as well: each request with its fault
removed (c1 without its Content-Length, c2 with one length) is served.

Witnessed by hand: `make vtest` rebuilds a binary whose stamp names another
commit; `make check-pins` names `vendor/vtest2` moved to another commit
(PIN MISMATCH); and the clients suite with `VTEST` naming no file ends
`HARNESS-ERROR`, status 2, the client named on standard error.

### The third step's review, and its fixes: forty-one mutants on the fixed tree

A `/code-review high` found ten, all fixed on the owner's word ("Fix all ten";
progress.md, M8.3). The fixes rewrote the lane's part of the clients suite, so
every M8B mutant ran again on the fixed tree against the clients suite (M8B-P1
against the shell suite): the thirty-four, M8B-S4 re-cut for the handler that
now hands all but a POST to the clients' handler, and seven new. Every one
loaded and matched once, and every one reddened its check.

| new mutant | the edit | the clients suite's failures |
|---|---|---|
| M8B-S6 | the rules' reader lets an rxresp go unchecked | "the rules' reader names an rxresp with no status check, a client never run, one never waited for" |
| M8B-S7 | the rules' reader lets a client go unrun | the same |
| M8B-S8 | the rules' reader forgets a started client | the same |
| M8B-S9 | the rules' reader asks each rxresp for a check no script has | "every script checks each answer's status and runs every client" |
| M8B-S10 | the lane takes a dotfile for a script | "the lane leaves out a dotfile, as an editor's lock file is, and a backup's name" |
| M8B-S11 | a killed script's verdict loses its TIMED OUT | "a run is passed only at exit 0; else its ---- lines, and TIMED OUT for one vtest killed" |
| M8B-S12 | any run that ends is read as passed | the same |

Readings the re-run gave:
- M8B-O3, an idle connection never closed, ends with vtest's own verdict now,
  `----` c3 "Expected close: timeout", its whole mutant run 7.4 s, where the cap
  killed it after about 20 s with an empty one.
- M8B-V2 reddens `version.vtc` c3 alone: the curl check it reddened was
  dropped (the review's second finding).
- The rules' two snippet faults and the scripts' own check redden apart: S6 to
  S8 leave every script clean, and S9 leaves the snippet's faults named.

Witnessed by hand, before and after each fix:
- `make vtest VTEST=path` copied our build over the user's file at `path` and
  wrote a stamp beside it; now nothing is written there, and
  `make test VTEST=path` and `VTEST=path make test` both reach the suite, which
  names the missing `path` (status 2).
- `make -n vtest` with a stale stamp deleted `build/vtest2`'s 45 objects and
  exited 2; now it prints the script's line, nothing deleted, exit 0, as does
  `make -n test`.
- On a copy of the submodule without its `.git`, the old pipe exited 0 though
  git had failed ("not a git repository"); `tests/build-vtest.sh` builds the
  copy's files, saying so.
- With `CC=false` and no binary, `make test` said vtest did not build and ran
  on: the clients suite named `build/vtest` (status 2), and the decisions
  suite passed its 52.
- In the layers' scratch worktree, which had no binary, `make test` could not
  build vtest: `git -C DIR archive -o build/vtest2.tar` took its path inside
  the submodule. Written through the shell now, `make vtest` from no binary
  builds it.

## M8.4 — load, and the release (2026-10-04)

Built from main at 28e0d77 on the owner's "Start m8.4", after measuring (progress.md,
M8.4) and one form of three decisions. Platform: Darwin arm64, Chez 10.4.1 (`tarm64osx`),
libuv 1.52.1, 2026-10-04, the library path as above.

The slice adds `tests/fetch-oha.sh` and `make oha` (decision 0018). To
`tests/test-clients.sps` it adds a reader of oha's JSON report and two load runs: 20,000
GETs on 50 kept-alive connections, and 2,000 on a connection each. It changes no source
under `src/`.

Each mutant ran from a scratch copy of its edited file against the clients suite, the
smoke's, two at a time. Each suite run opens about 2,300 connections, and four at a time
would come near macOS's 16,384 client ports in TIME_WAIT. Every one loaded and matched
once, with no `Exception` in any report, and every one reddened its checks.

| mutant | the edit | the clients suite's failures |
|---|---|---|
| M84-A | the shell drops one write in a thousand, its completion reported (plan §14's mutation) | both oha runs; "curl: 16 MiB streamed to it, read at 16 MiB/s, arrive in order" |
| M84-B | the report's reader drops a tally's last pair | the reader's check; both oha runs |
| M84-C | the reader keeps an escape's backslash, not the character escaped | the reader's check |
| M84-D | the serializer writes one status line in a thousand as 503's, the response otherwise whole | both oha runs |

Plan §14's mutation reddens what it expects. Run by hand from M84-A's root, on
`tests/serve-child.sps`, oha counted 19,980 responses and 20 timeouts of the 20,000 kept
alive. Every response under M84-D arrives, so oha counts no failure, and M84-D reddens
the status tally alone.

Every check the slice added, and the mutants that redden it:

| check | reddened by |
|---|---|
| oha: the report's reader reads each tally's pairs in order, an error's name with its quotes, and an empty one | M84-B, M84-C |
| oha: 20,000 GETs, 50 connections kept alive, every one answered 200, none failed | M84-A, M84-B, M84-D |
| oha: 2,000 GETs, 10 at a time, each on a connection of its own, every one answered 200, none failed | M84-A, M84-B, M84-D |

Witnessed by hand:
- `tests/fetch-oha.sh`:
  - into an empty `build/`, it fetched oha in 0.56 s;
  - at the next call it kept it;
  - a binary with a byte appended was fetched again, at the pinned sum;
  - a copy whose pin had one digit changed refused the download, exit 2, leaving no file;
  - with `uname` faked as Plan9 mips, it named the platform and exited 2;
  - with no argument, it printed its usage and exited 2;
  - `make -n oha` printed its line and fetched nothing;
  - in Docker, on Linux aarch64, `make oha` fetched the arm64 binary at its pin.
- `make test`:
  - with no oha it could fetch (the faked `uname`, `build/oha` moved aside), it said so
    and ran on, and the clients suite named `build/oha`, status 2;
  - with `OHA` named on the command line, it fetched none, and the clients suite passed
    its 35.
- The clients suite with no oha ended `HARNESS-ERROR`, status 2, naming `build/oha` on
  standard error.

### The review's fixes: seven mutants on the fixed tree

A `/code-review high` found ten, all fixed on the owner's word ("Fix all ten";
progress.md, M8.4). The fixes renamed the smoke's two checks, which now also hold the
bodies' bytes, and added a check that an empty `OHA` or `VTEST` names the default. So
the four mutants ran again on the fixed tree, with three new, two at a time. Every one
loaded and matched once, and every one reddened its checks.

| mutant | the edit | the clients suite's failures |
|---|---|---|
| M84-A | (as above) | both oha runs; curl's 16 MiB streamed to it |
| M84-B | (as above) | the reader's check; both oha runs |
| M84-C | (as above) | the reader's check |
| M84-D | (as above) | both oha runs |
| M84-E | the serializer frames one response in a thousand with an empty body, Content-Length 0 | both oha runs |
| M84-F | an empty `OHA` or `VTEST` is taken as the client's name | "oha: OHA or VTEST unset or empty names the default, and any other value the client it names" |
| M84-G | the report's reader drops a number's last character | the reader's check; both oha runs |

Run by hand on `tests/serve-child.sps` from each mutant's root, whose bodies are the 6
bytes "served":
- under M84-E, oha counted 20,000 answered 200 and no failure, and 119,880 bytes of
  bodies of the 120,000: only the new byte count reddens it;
- under M84-D, 19,980 answered 200 and 20 answered 503, no failure, and 120,000 bytes:
  the status tally reddens it.

Every check the slice adds, and the mutants that redden it, on the fixed tree:

| check | reddened by |
|---|---|
| oha: OHA or VTEST unset or empty names the default, and any other value the client it names | M84-F |
| oha: the report's reader reads each tally's pairs in order, an error's name with its quotes, an empty one, and a number | M84-B, M84-C, M84-G |
| oha: 20,000 GETs, 50 connections kept alive, every one answered 200 with its 4 bytes, none failed | M84-A, M84-B, M84-D, M84-E, M84-G |
| oha: 2,000 GETs, 10 at a time, each on a connection of its own, every one answered 200 with its 4 bytes, none failed | M84-A, M84-B, M84-D, M84-E, M84-G |

Witnessed by hand on the rewritten `tests/fetch-oha.sh`:
- the paths above again: a fresh fetch, one kept, a corrupted binary fetched again, a
  pin with a digit changed refused (exit 2, the directory left empty), an unpinned
  platform and a missing argument, each exit 2;
- with `PATH` holding `sh`, `dirname` and `uname` alone, it said "sha256: neither
  sha256sum nor shasum is on PATH" and exited 2, before it made the directory or
  fetched anything;
- four fetches at once into one empty directory each said "fetched", and left the
  pinned binary and no temporary file.
- The old script, its download at the one name `oha.part`, run the same way, four at
  once, three trials: in each, one fetched and three failed, their sum reading "No
  such file or directory" after the first had renamed `oha.part` into place.

Witnessed by hand on the shared `tests/sha256.sh`, which the corpus vendoring now calls
too (the review's seventh):
- it reproduces every sum the five vendored corpora's PROVENANCE files record, 123 of
  123;
- `tests/vendor-corpus.sh`, run with `PATH` holding everything in `/bin`, `/usr/bin`,
  `/sbin`, `/usr/sbin` and `/opt/homebrew/bin` but `sha256sum` and `shasum`, on a git
  copy of guardian's vendored files, said "sha256: neither sha256sum nor shasum is on
  PATH" and exited 2, the vendored tree untouched;
- run again with the tools, on the same copy, it rewrote PROVENANCE's
  `upstream-commit` line alone, the copy's commit for upstream's: every sum it wrote
  was the one recorded. The vendored tree was then restored.

## After M8 — the pipeline cap removed (2026-10-04)

Built on `docs/parse-ahead-not-wanted` (decision 0004's amendment "parse-ahead is not
wanted") on the owner's "lets remove `pipeline-cap` in its own PR". Platform: Darwin
arm64, Chez 10.4.1 (`tarm64osx`), libuv 1.52.1, 2026-10-04, the library path as above.

`(http-server limits)` loses the field `pipeline-cap`, its accessor, `env-pipeline-cap`
and `CHEZ_HTTP_PIPELINE_CAP` (0005's amendment "the pipeline cap is removed"). The new
checks were written first and run against the code before the change, their mutant. The
checks that changed have mutants of their own: a field gone from a positional
constructor is where arguments slip out of order.

| mutant | the edit | the failures |
|---|---|---|
| the code before the change | `pipeline-cap` a field, `CHEZ_HTTP_PIPELINE_CAP` read, any value but 1 refused | the limits suite: "the environment variables, one per field"; "CHEZ_HTTP_PIPELINE_CAP is not read: whatever it holds, the limits are default-limits, field by field"; "pipeline-cap is a field no more: limits-with refuses it" (49 passes, 3 failures) |
| env-boolean keeps the default for any other value | `CHEZ_HTTP_REQUIRE_HOST=yes` read as unset, not refused | the serve suite: "a malformed setting raises an &http-server-config-error naming it, from serve" (15 passes, 1 failure) |
| default-limits' read buffer and connection cap swapped | `make-limits` given 10000 and 16384 where pipeline-cap's removal left 16384 and 10000 | the limits suite: "read buffer 16 KiB"; "max connections 10 000"; "empty env == default-limits, field by field"; "CHEZ_HTTP_PIPELINE_CAP is not read" (48 passes, 4 failures) |
| limits-with drops an override of read-buffer-size | the field after the one removed keeps its base value | the limits suite: "limits-with replaces each field alone, by name" (51 passes, 1 failure) |

Run by hand against the code before the change, the variable at "1" left the limits as
they were, and at "2", "-3" and "many" each faulted; `limits-with` accepted
`pipeline-cap`. Each failure above is its own row's.

Every check the change added or changed, and the mutant that reddens it:
- the limits suite's "CHEZ_HTTP_PIPELINE_CAP is not read" and "pipeline-cap is a field no
  more", both new, and "the environment variables, one per field", changed: the code
  before the change;
- the serve suite's "a malformed setting raises an &http-server-config-error naming it,
  from serve", whose second setting is now `CHEZ_HTTP_REQUIRE_HOST=yes` for
  `CHEZ_HTTP_PIPELINE_CAP=2`: env-boolean keeping the default;
- the limits suite's "empty env == default-limits, field by field", over nineteen fields
  now: the swap;
- its "limits-with replaces each field alone, by name", over nineteen names now: the
  dropped override.

## After M8 — a taker's deferred `done` made as `serve` returns (2026-10-04)

M8.2's review's sixth finding, fixed on the owner's "build the targeted fix". Platform:
Darwin arm64, Chez 10.4.1 (`tarm64osx`), libuv 1.52.1, 2026-10-04, the library path as
above.

`serve`'s loop became `run-until-stopped!`, a test's to run on a loop of its own, with
no change of behavior; then the checks were written and run red; then the fix: the
shell's queue of a taker's deferred calls (`taker-later!`, `call-deferred!`) and
`shell-call-deferred!`, which the run calls once its server has stopped.

Red before the fix, the serve suite's two new checks, on `run-until-stopped!` without
the call: 16 passes, 2 failures. Printed, the `done`s had been told nothing when the run
returned, and `ECANCELED` once the loop turned on: `(() (ECANCELED))`.

| mutant | the edit | the serve suite's failures |
|---|---|---|
| M6-A | `run-until-stopped!` makes no deferred call | both checks (16 passes, 2 failures) |
| M6-B | the pass runs until the queue is empty | "a done so told as serve's run returns that asks for a write" (17, 1) |
| M6-C | `call-deferred!` leaves the call it makes in the queue, so it is made again | both (16, 2) |
| M6-D | `call-deferred!` makes the newest first | "two writes … in order, and once each" (17, 1) |
| M6-E | `taker-later!` defers through the scheduler alone, as before the fix | both (16, 2) |
| M6-F | the one-line drain: `shell-call-deferred!` drains the whole scheduler | both (16, 2): the other work queued as the stream closed ran |

Every check the fix added, and the mutants that redden it:
- "two writes a taker asks for once its stream has closed: their dones are told
  ECANCELED before serve's run returns, in order, and once each, and nothing else the
  scheduler holds is run": M6-A, M6-C, M6-D, M6-E, M6-F;
- "a done so told as serve's run returns that asks for a write: that write's done waits
  for a turn, which serve does not run": M6-A, M6-B, M6-C, M6-E, M6-F.

## After M8 — every 1.x served, and every other version answered 505 (2026-10-04)

Plan §14's open list, M8.3's robustness lane, item 3d, decided on the owner's "serve 1.x
for 3d" (decision 0006's amendment of 2026-10-04, later). Platform: Darwin arm64, Chez
10.4.1 (`tarm64osx`), libuv 1.52.1, 2026-10-04, the library path as above.

The checks were written first and run against the code before the change: the head
suite 59 passes and 7 failures, its two rows of versions the parser cannot read passing,
as they must; the allocation suite 25 and 1; the robustness lane 15 and 2; the
strictness lane 16 and 1; the clients suite 35 and 1, `version.vtc` failing at c4. Then
the change: the adapter's field initials gain llhttp's version leniency.

| mutant | the edit | the suites it reddens, failures |
|---|---|---|
| V-A | the parser strict again (the leniency 0) | head 7 (the pin, 3.0, 0.8, 1.2, the pipelined pair, the Host rule, the framing); robustness 1; strictness 1; clients 1 (c4) |
| V-B | a second leniency, `headers`, beside the version's | head 1 (the pin); libhtp lane 1 and the ratchet 1 (`46-auth-digest-invalid-username.t`); robustness 1; strictness 1 |
| V-C | the core refuses every version but 1.0 and 1.1 | head 4 (1.2, the pipelined pair, the Host rule, the framing); robustness 1; strictness 1; clients 1 (c4, 505) |
| V-D | the core refuses only 0.x | head 2 (2.0, 3.0); strictness 1; clients 1 (c2) |
| V-E | the core refuses only a major above 1 | head 5 (four of HTTP/0.9's rows, 0.8); cut-off 1; originated 1; padding 1; libhtp lane 2 and the ratchet 1 (HTTP/0.9's streams); trace lane 1 (`sample.md#10`'s listed refusal); robustness 1; strictness 1; clients 1 (c1) |
| V-F | `invalid-version` answered 505 | head 1 (the versions the parser cannot read); decisions 1 ("every code but the hand-off is a 400"); clients 1 (c6) |
| V-G | `invalid-constant` answered 505 | head 1 (`http/1.1`); decisions 1; libhtp lane 1 and the ratchet 1 (`43-invalid-protocol.t`) |
| V-H | llhttp's version gate, `http/1.1?`, narrowed to exactly 1.1 | head 1 (the framing); clients 1 (c4: `Connection: keep-alive` written) |
| V-I | the Host rule for exactly 1.1, not 1.2 | head 1 (the Host rule) |
| V-J | the adapter makes its field initials for each parser, not once | allocation 1 |
| V-K | the core refuses only 0.x and 2.x, so 3.0 is served | head 1 (3.0); strictness 1; clients 1 (c5) |
| V-T | (a test mutant) `acceptable#9` dropped from the serve manifest | robustness 2 (the count, the manifest) |

Every check the change added or changed, and the mutants that redden it:
- the head suite's "a connection's parser runs llhttp's version leniency and no other":
  V-A, V-B;
- "HTTP/3.0, a major version the server does not speak": V-A, V-D, V-K;
- "HTTP/0.8, a 0.x that is not HTTP/0.9": V-A, V-E;
- "HTTP/1.2, a minor version past 1.1: served as HTTP/1.1, kept alive" and "HTTP/1.9,
  then HTTP/1.2, pipelined": V-A, V-C;
- "HTTP/1.2 is HTTP/1.1 to the Host rule": V-A, V-C, V-I;
- "HTTP/1.2 is HTTP/1.1 to the framing": V-A, V-C, V-H;
- "a version the parser cannot read stays its error, a 400": V-F;
- "a protocol name in lowercase, http/1.1, stays the parser's error, a 400": V-G;
- the allocation suite's "a connection's parser costs what one on a binding list made
  once does", its initials mirrored: V-J, and the code before the change;
- the robustness lane's manifest check, `acceptable#9` served: V-A, V-B, V-C, V-E, V-T;
  its count, "31 cases reach the handler": V-T;
- the strictness lane's departures, HTTP/1.2's moved to Kestrel: V-A, V-B, V-C, V-D,
  V-E, V-K;
- `version.vtc`: c4 by V-A, V-C and V-H, c5 by V-K, c6 by V-F; c1 and c2, unchanged,
  by V-E and V-D.

## After M8 — one PROVENANCE checker (2026-10-04)

M8.3's step 1 review, its tenth finding, settled on the owner's "merge for 3": libhtp's
suite checks its PROVENANCE with the shared `(provenance)`. Platform: Darwin arm64, Chez
10.4.1 (`tarm64osx`), libuv 1.52.1, 2026-10-04, the library path as above.

A gate whose failure ends the suite cannot be reddened from the vendored tree, so its
failures were witnessed by hand: a scratch copy of `test/vendor/libhtp`, one change each,
run through main's libhtp suite and the merged one, each pointed at the copy.

| the copy | main's suite | the merged suite |
|---|---|---|
| unchanged | exit 0 | exit 0 |
| a stray `files/notes.txt` | exit 0 | exit 3, "vendored file not in the manifest: files/notes.txt" |
| a stray `NOTICE` at the top | exit 0 | exit 3, "... not in the manifest: NOTICE" |
| one sha256 corrupted (M1.3's mutation) | exit 3 | exit 3 |
| a byte of `01-get.t` changed | exit 3 | exit 3 |
| a listed file missing | exit 3 | exit 3 |
| `file-count` one too many | exit 3 | exit 3 |

| mutant | the edit to `(provenance)` | the merged tree | main's libhtp suite |
|---|---|---|---|
| P-B | it reads no sha256 line | libhtp exit 3; robustness exit 3; strictness exit 3 | green, 11 passes |
| P-D | it returns no files listed | libhtp 1 ("PROVENANCE lists LICENSE + the 102 streams"); robustness 1; strictness 1 | green, 11 passes |

The checks the change touched: the libhtp suite's "PROVENANCE lists LICENSE + the 102
streams", its count now the shared checker's list: P-D; its gate, which ends the suite
with status 3 and names no check: P-B and the witnesses above.

## After M8 — the outcome lane runs all 167 (2026-10-04)

Decision 0019, on the owner's "A": the outcome lane takes the 32 fixtures the trace lane
defers. Platform: Darwin arm64, Chez 10.4.1 (`tarm64osx`), 2026-10-04, the library path
as above.

Tests first, against the tree before the change: the ratchet 7 passes and 2 failures
("outcome lane: 167 passing", "outcome lane: 0 deferred"), the outcome suite 6 and 1
("167 request fixtures in the lane"). With the manifest's 32 outcome entries `passing`
and the split not yet per lane, the ratchet 8 and 1: "no ratchet violations", 32 of
them, each "lenient, must be deferred, is passing".

| mutant | the edit | red |
|---|---|---|
| L-A | the ratchet's outcome split derived from each fixture's meta again | ratchet 1: "no ratchet violations", 32, each "lenient, must be deferred, is passing" |
| L-B | the outcome suite's list the strict 135 | outcome lane 1: "167 request fixtures in the lane" |
| L-E | the ratchet's trace split lost, every request fixture in scope | ratchet 1: "no ratchet violations", 32, each the trace lane's "in-scope fixture marked deferred" |
| L-F1 | `response-written` never feeds the input a message's pause kept | outcome lane 3: the instrument's whole-input row, and both handlers' rows (read: `connection.md#2`, `pipelining.md#1`, `lenient-headers.md#2`; unread: `connection.md#2`, `lenient-headers.md#2`); ratchet 1 (those three, and libhtp's 07); 14 other suites |
| L-F2 | `answer-error` answers 500 for a parser error the head's feed met in the body | outcome lane 1, bodies read: `transfer-encoding.md#9`, #10, #12, #24, #25, #27 to #32; ratchet 1 (those 11, and libhtp's 64 and 65); 5 other suites |

By hand on a scratch tree, since the ratchet reads `tests/ratchet.txt` from its working
directory: the tree's files linked, the manifest a copy with one line changed. The
unchanged copy: green, 9 passes.

| mutant | `outcome/request/lenient-headers.md#2` | red |
|---|---|---|
| L-C | `deferred` | ratchet 3: "outcome lane: 167 passing", "outcome lane: 0 deferred", "no ratchet violations" ("in-scope fixture marked deferred") |
| L-D | `not-yet` | ratchet 3: "outcome lane: 167 passing", "outcome lane: 0 not-yet", "no ratchet violations" ("marked not-yet but now passes") |
| L-G | removed | ratchet 2: "outcome lane: 167 passing", "manifest covers every fixture in every lane" (RATCHET MISSING) |

The checks the change touched:
- the ratchet's "outcome lane: 167 passing": the tree before, L-C, L-D, L-G; its
  "outcome lane: 0 deferred": the tree before, L-C;
- its "no ratchet violations", the split now per lane: the flipped manifest before the
  split, L-A, L-E, L-C, L-D, L-F1, L-F2;
- the outcome suite's "167 request fixtures in the lane", counting the list it compares:
  the tree before, L-B;
- its two "every fixture has one outcome at every chunk size" rows, now over 167: L-F1
  (both, through `lenient-headers.md#2` among strict fixtures) and L-F2 (bodies read,
  through `transfer-encoding.md#28`, #30 and #32 among strict fixtures).

No mutant fails a check through the 32 alone, as decision 0019's measured overlap
predicted.
