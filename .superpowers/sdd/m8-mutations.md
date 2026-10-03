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
