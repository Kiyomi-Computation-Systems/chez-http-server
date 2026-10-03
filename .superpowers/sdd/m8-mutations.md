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

