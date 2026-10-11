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

## After M8 — a client's close noticed while its request is answered (2026-10-04)

Decision 0020, on the owner's word ("lets do C"), and by form ("Once", "Close quietly"):
the core reads past a request's end to notice the client close, and the wait a
request's code is in raises `&client-closed`, once. Platform: Darwin arm64, Chez 10.4.1
(`tarm64osx`), libuv 1.52.1, 2026-10-04, the library path as above. Three stacked PRs:
the waits and the API; the core and the fake shell; the libuv shell.

Tests first: the wait suite's seven checks and the connection table's rows were written
before the code. The wait suite did not load (`client-closed?` unbound), and the table
failed seventeen: the new rows, H6, B8 and B9 without their `read-stop`, T2's two
instances, the vocabulary. The other suites' checks came as the build found their
cases; each was watched to fail by a mutant below. Every mutant ran against all fifty
suites, the contract and message-loop suites again after their last changes.

| mutant | the edit | red |
|---|---|---|
| K-A | a request's end stops reading again | connection-body, connection-table, message-loop, shell |
| K-A2 | a streaming reader's end stops reading again | connection-body, connection-table |
| K-A3 | a whole reader's end stops reading again | connection-table |
| K-B | bytes past a request's end are dropped, not held | connection-head, connection-table, message-loop, shell |
| K-C | a delivery held replaces the pause's rest | connection-table |
| K-D | a held delivery is not the parser's last | message-loop |
| K-E | a held delivery's base is left the last one's | message-loop |
| K-F | the client's end past a request's end changes nothing | connection-table, contract, message-loop, shell |
| K-G | the client's end tells the code with requests held | connection-table, contract, message-loop |
| K-H | the client's end is not remembered | connection-table, contract, message-loop |
| K-I | a read error past a request's end tells no one | connection-table, contract |
| K-J | a response after the client's end lingers | connection-table, message-loop |
| K-K | reading starts again after the client's end | connection-table, contract |
| K-L | a read wanting more after the end, in head or body, does not close | message-loop |
| K-L2 | a read wanting more after the end, in idle, does not close | message-loop |
| K-M | any raise of the close is quiet, the client closed or not | connection-table, shell |
| K-N | no raise is quiet: every one a failure | connection-table, message-loop |
| K-O | an originated status forgets the client closed | connection-table |
| K-P | the vocabulary leaves client-closed out | connection-table |
| K-Q | a message's end does not pause the parser | message-loop (exit 2) |
| RP-A | the replay drains the fake after every event | contract |
| RP-B | the replay drains after the clock moves | contract |
| RP-C | a script's client ends its stream without waiting for its answers | contract |
| SH-A | the libuv shell ignores client-closed | contract, shell |
| SH-B | each coroutine gets a notice of its own | contract, shell |
| SH-C | the notice is kept past the request | shell |
| SH-D | every raise of the close is logged | shell |
| SH-E | a raise of the close is quiet though the client did not close | shell |
| SR-A | bytes past a request's end are fed at once | connection-head, connection-table, message-loop (exit 2), shell |
| TM-A | the table's N1 row loses its instance | connection-table |
| W-A | a close never ends the wait parked then | contract, message-loop, shell, waits |
| W-B | a wait does not raise a close no wait has raised yet | waits |
| W-C | every wait after the close raises (sticky) | waits |
| W-D | a second close ends a wait again | waits |
| W-E | a close takes back nothing | shell, waits |
| W-F | a notice keeps no coroutine's context | contract, message-loop, shell, waits |
| W-G | a close raises a deadline's condition | contract, message-loop, shell, waits |
| W-H | the facade exports no client-closed names | serve |
| M7B-14 | a reader's answer reads again though its message has ended (the message loop's serial?, which M7.1 taught a wait from a message's end) | connection-body, connection-table, contract, shell (exit 2) |
| M7B-15 | after a response, reading starts again before the parser is resumed (re-cut on 0020's tree) | connection-table, message-loop |

The checks the slice touched, and their killers:
- the wait suite's seven: W-A to W-G, each as its row says (W-B the two raised before a
  park, W-C and W-D the once rows, W-E the sleep taken back); the serve suite's export
  list: W-H;
- the connection table: H6, K-A; B8, K-A2; B9, K-A3; T2's two instances, K-I; P3, K-B and SR-A; N1 and N3, K-B
  and SR-A; N2, K-B, K-C and SR-A; N4 and N5, K-F; N6, K-F, K-G, K-H, K-J; N7, K-F,
  K-N; N8, K-O; N9, K-M; N10, K-F, K-G; N11, K-F, K-G, K-H, K-K; the vocabulary and
  "no row emits an action outside the vocabulary", K-P; the row count, TM-A;
- the head suite's bytes-arrived row, K-B and SR-A; the body suite's read-stop count,
  K-A and K-A2;
- the message loop's order row, K-A and M7B-15; its eight: told, K-F, K-N, W-A, W-F,
  W-G; caught and answered, K-F, K-H, K-J, W-A, W-F, W-G; held and served, K-B; two
  held together, K-B, K-D; judged where the parser stopped, K-B, K-E; an end with a
  request held, K-F, K-G, K-H; the cut, K-F, K-G, K-H, K-L; the empty line, K-F, K-G,
  K-H, K-L2;
- the contract: the reset while a call sleeps, K-I, W-A, W-F, W-G; the sleep that ends
  early, SH-A, SH-B (the shells part), K-F, W-A; the three requests that end early,
  RP-A (its traces), K-F, K-H, K-K; the lookup in a pipeline, K-G, K-H, K-K, RP-B;
  every script that waits read an answer, RP-C; the waiting scripts' traces and bytes,
  RP-B;
- the shell suite: the close noticed, K-A, K-F, SH-A, SH-B, SH-D, W-A, W-F, W-G; the
  half-close answered, K-A, K-F, SH-A, SH-B, W-A, W-F, W-G; held and answered, K-B,
  SR-A; the condition raised by a handler itself, K-M, SH-E; the retention check,
  extended to what the waits kept, SH-C.

Found while mapping:
- The contract's waiting scripts had half-closed as soon as they sent, which before
  0020 the server saw only after its answer. With 0020 their handlers were told,
  answered nothing, and both shells agreed on writing nothing. So a script's client now
  ends its stream once answered, two scripts end early on purpose, and a check holds
  every other to having read an answer (RP-C).
- `serial?` keys a message's end on the paused result, since no `read-stop` marks it
  now. Nothing reaches its "no feed until the resume" clause: a feed to a paused parser
  raises in byte-machine (SR-A, exit 2) and a parser not paused raises in the core
  (K-Q, exit 2), before any check. M7's two `serial?` mutants, run again on this tree,
  are still killed: M7B-14 as it was, M7B-15 re-cut on the new `response-written`.
- RP-A has one witness, the three requests that end early, whose end comes in the turn
  a handler's call waits in. When it comes a turn later, a fake drained after every
  event agrees too.

## After M8 — the smuggling-framing lane (2026-10-04)

Decision 0021, on the owner's forms ("Static fixtures only", then "Per-case verdict +
gate"): plan §14's last open item, a hand-written fixed-vector lane for the request-
smuggling framing families, not a vendored generator or a probe reader. Platform: Darwin
arm64, Chez 10.4.1 (`tarm64osx`), 2026-10-04, the library path as above.

The suite (`tests/test-smuggling-lane.sps`) is new; eight checks over the nineteen
vectors of `tests/smuggling-corpus.sls`. Two code mutants are of the status table in
`(http-server decisions)`, the rest of the corpus data, each watched red on the finished
tree (by hand, reverted after; the lane is self-contained, no data file to redirect).

| mutant | the edit | red |
|---|---|---|
| D-STATUS | `(unsupported-transfer-coding . 501)` → `. 400` | the verdict gate: `te-coding-before-chunked`, "verdict 400, recorded 501" |
| D-PARSE400 | `parser-error-status` returns `500`, not `400` | the verdict gate: all twelve 400-refused cases (every hazard but `te-coding-before-chunked`) |
| A-SEP | the request assembler joins lines with LF, not CRLF | "cl.te assembles to its exact bytes"; "te-ows-tab carries a tab, not a space, after the colon"; the verdict gate |
| C-COUNT | a case dropped from `smuggling-cases` | "nineteen framing vectors"; "thirteen are hazards (refused)" |
| C-CAT | a `hazard` case's category set to `safe` | "six are safe (served)"; "thirteen are hazards (refused)"; the policy check |
| C-DUP | a case id repeated | "every case id is unique" |
| P-POLICY | a `hazard` case's `expected` set to `served` | the policy check; the verdict gate |

The checks the lane has, and their killers:
- "nineteen framing vectors", counting the list the properties loop over: C-COUNT;
- "six are safe (served)": C-CAT; "thirteen are hazards (refused)": C-COUNT, C-CAT;
- "every case id is unique": C-DUP;
- "cl.te assembles to its exact bytes" and "te-ows-tab carries a tab, not a space, after
  the colon": A-SEP;
- "every case's category and recorded verdict agree" (the security policy, read off the
  corpus with no server): C-CAT, P-POLICY;
- "every case meets its recorded verdict" (the gate, both ways): D-STATUS, D-PARSE400,
  A-SEP, P-POLICY. D-STATUS and D-PARSE400 are server regressions — a status the core
  originates moved — so the gate catches a real change, not only a data edit.

Chunk invariance is not a check here (decision 0021): these vectors refuse at the head,
so no mutant can make one size-dependent. The property is the outcome lane's (L-F1,
L-F2) and the robustness lane's.

## After M8 — a taker that waits (2026-10-04)

Decision 0023, on the owner's form ("take-over answers awaiting"), the first slice of the
WebSocket path (decision 0022): a take-over may answer `(awaiting thunk)`, its thunk run
on a coroutine whose waits are told when the stream closes. Platform: Darwin arm64, Chez
10.4.1 (`tarm64osx`), 2026-10-04, the library path as above.

Tests first, against the tree before the behaviour:
- the fake's door suite: 23 passes and 5 failures, the five new checks, once
  `fake-shell-taker-failures` existed (recording nothing);
- the shell suite: 190 passes and 4 failures, the two new checks and two knock-ons (the
  raising taker's stream never closed, so a handle was left on the loop).

The third shell check, the thunk that ends, was written after mapping the mutants showed
the libuv shell had no check of its own for it (TW-F would have survived).

Sixteen mutants, every suite each (`scratchpad/door/mut`, four at a time), all loaded:

| mutant | the edit | red |
|---|---|---|
| TW-A | the libuv shell drops a take-over's `awaiting` answer | shell 5: its three waiting-taker checks, and the two leaked-handle knock-ons |
| TW-B | the stream's close tells the taker's notice nothing | shell 1: the taker that waits, told |
| TW-C | the close the notice told is logged `taker-failed` | shell 1: the taker that waits, logging nothing |
| TW-D | a thunk's raise leaves the stream open | shell 3: the raising thunk, and the two knock-ons |
| TW-E | a thunk's raise is not logged | shell 1: the raising thunk |
| TW-F | a thunk that returns closes the stream | shell 1: the thunk that ends |
| TW-G | the thunk's coroutine gets a notice of its own, not the taker's | shell 1: the taker that waits, told |
| TF-A | the fake drops a take-over's `awaiting` answer | door 5: all five |
| TF-B | the fake's close tells the taker's notice nothing | door 1: told once the stream has closed |
| TF-C | the fake records the told close as a failure | door 1: letting the told close out is no failure |
| TF-D | the fake leaves the stream open after a thunk's raise | door 1: a thunk that raises anything else |
| TF-E | the fake does not record a thunk's raise | door 1: a thunk that raises anything else |
| TF-F | the fake does not drain after a delivery to a taker | door 1: resumed by a read, then writes |
| TF-G | the fake does not drain after a taker's completion | door 1: told once the stream has closed |
| TF-H | the fake closes the stream when a thunk returns | door 3: resumed by a read, told, the thunk that ends |
| TF-I | the fake gives the thunk's coroutine a notice of its own | door 1: told once the stream has closed |

The checks the slice added, and their killers:
- the fake's door suite: resumed by a read, then writes: TF-A, TF-F, TF-H; told once the
  stream has closed: TF-A, TF-B, TF-G, TF-H, TF-I; letting the told close out is no
  failure: TF-A, TF-C; a thunk that raises anything else: TF-A, TF-D, TF-E; a thunk that
  ends leaves the stream open: TF-A, TF-H;
- the shell suite: the taker that waits, told and logging nothing: TW-A, TW-B, TW-C,
  TW-G; the raising thunk: TW-A, TW-D, TW-E; the thunk that ends: TW-A, TW-F.

Taken out while mapping: a clause in both shells that closed a taker's new notice at
once "if the stream has closed already". The notice is made in `hand-off!`, before any
close can complete, so no input reaches it and no mutant could redden it.

## After M8 — a number in ASCII digits alone (2026-10-05)

Decision 0005's amendment of 2026-10-05, on the owner's form ("ASCII digits only"):
`parse-exact` refuses a value that is not one or more of `0` to `9`, naming its variable,
before `string->number` reads it. Platform: Darwin arm64, Chez 10.4.1 (`tarm64osx`),
libuv 1.52.1, 2026-10-05, the library path as above.

Tests first, against main's library, the new checks in place: the limits suite 55 passes
and 4 failures, the four malformed checks; the serve suite 17 and 1, its start-failure
check, whose `#x1F90` row was read as port 8080 and refused only at the bind, naming
`CHEZ_HTTP_HOST` (measured). Every other suite green: 1,959 expected passes. Each wrong row was a
spelling Chez reads as an exact integer within its field's bounds (`+5`, `-0`, `#x10`,
`#e1e3`, `10/2`, `#e5`, `5+0i`, `5@0`), but the high water's, which spell values below
the low water's default and were refused by the water rule, naming the low water.

Seventeen rows, every suite each (`scratchpad/mut`, four at a time), each red set named
before the run, all loaded:

| mutant | the edit | red |
|---|---|---|
| B-0 | none: a comment's text | none, run alone: 51 suites, 1,964 expected passes |
| ND-OLD | the code before the change: `string->number`'s exact integers within bounds | limits 4: the four malformed checks; serve 1: the start-failure check |
| ND-PLUS | `digits?` takes a plus sign for a digit | limits 4: the four malformed checks |
| ND-MINUS | `digits?` takes a minus sign for a digit | limits 4: the four malformed checks (`-0`) |
| ND-NUMERIC | `char-numeric?` for a digit | limits 4: the four malformed checks (U+0663) |
| ND-FIRST | `digits?` reads only the first character | limits 5: the four malformed checks, and the port's old one (`80.5`) |
| ND-LAST | `digits?` leaves the last character unread | limits 4: the four malformed checks |
| ND-NAMES-VALUE | the digit refusal names the value first | limits 4: the four malformed checks |
| ND-ERROR | the digit refusal an `&error`, not an assertion violation | limits 4: the four malformed checks; serve 1: the start-failure check |
| ND-SECONDS | `env-seconds->ms` reads as `string->number` does | limits 1: the timeouts' |
| ND-INTEGER | `env-integer` reads as `string->number` does | limits 2: the tick, sizes and counts', and the port's; serve 1 |
| ND-BODY | `env-max-body`'s number reads as `string->number` does | limits 1: the body cap's |
| ND-PORT | the port reads as `string->number` does | limits 1: the port's; serve 1 |
| ND-ZERO | `digits?` refuses a leading zero | limits 2: the two leading-zero checks |
| ND-EMPTY | `digits?` takes the empty string | none: survives, equivalent |
| ND-VARS | the library lists a twentieth variable | limits 2: the coverage check, and "the environment variables, one per field" |
| ND-V | the suite's eleven lose `CHEZ_HTTP_BACKLOG` | limits 1: the coverage check |

Every red was by value, exit 1, with no harness error, and each set was the one named.
ND-EMPTY survives because every reader takes an empty value as unset before it parses:
`digits?` keeps its length check to stay true to its name, a scope statement.

In the four-at-a-time run, B-0 also reddened one shell check, "a connection held in its
handler, nothing armed, the timer stopped, is closed at the drain's deadline, on time", on
the loop's real clock with a 10 ms tick. The shell suite reads no environment: its limits
come from `limits-with`. Run again: B-0's shell suite alone, green three times; under six
busy loops on the eight cores, main's code (ND-OLD's tree) and B-0 four times each, all
green; B-0 alone over every suite, green.

The checks the change added or changed, and their killers:
- the limits suite's timeouts': ND-OLD, ND-PLUS, ND-MINUS, ND-NUMERIC, ND-FIRST, ND-LAST,
  ND-NAMES-VALUE, ND-ERROR, ND-SECONDS;
- its tick, sizes and counts': the same, ND-INTEGER for ND-SECONDS;
- its body cap's: the same, ND-BODY for ND-SECONDS;
- its port's: the same, ND-INTEGER and ND-PORT for ND-SECONDS;
- its coverage check, "these checks cover every variable read but the Host switch": ND-V,
  ND-VARS;
- its two leading-zero checks: ND-ZERO;
- the serve suite's "a malformed setting raises an &http-server-config-error naming it,
  from serve", a fourth row, `CHEZ_HTTP_PORT=#x1F90`: ND-OLD, ND-ERROR, ND-INTEGER, ND-PORT.

## After M8 — a taker may abort its stream, and a handler may read every line of a field (2026-10-08)

Decision 0024, on chez-websocket's M4.2 form ("Door change: abort", "Every line, in the
release"): `transport-abort!`, the fake shell's door made to do what the libuv shell's
does for a client that reads nothing, and `request-header-values`. Platform: Darwin
arm64, Chez 10.4.1 (`tarm64osx`), libuv 1.52.1, 2026-10-08, the library path as above.
Each red set was named and hashed before its run (`scratchpad/srv/red`, `srv/mut`).

Tests first, in two stages, as chez-websocket's M4.1 review did:
- **Against main's code**, the new checks in place: the records, fake door and shell
  suites stopped at load, exit 255, Chez refusing the unbound `transport-abort!` as it
  loaded each program; the serve suite 17 passes and 1 failure, its export list. The
  prediction named the right suites but the wrong way for three: it expected run-time
  failures, exit 2 or 1. Chez's expander refuses a program that names an unbound
  identifier wherever the name sits.
- **Against the API alone** (the verb, the facade's export, and each shell's eighth
  procedure only asking for the close): exactly the four new fake checks and the shell
  suite's bound. A first run also reddened the shell suite's raise check: the bound
  check's stream, left open at that stage, closed during the next check once its client
  went, and its `EPIPE` and its close landed in that check's notes. Each of the two checks
  now waits for its connection to be gone before the next begins; run again, exactly the
  five named.
- **The values layer**, the same way: the view suite stopped at load (exit 255) and the
  serve suite failed its export list; then, `request-header-values` answering no value,
  exactly the view suite's new check.

**The abort layer, 0e234e2:** 24 rows, 23 mutants and the baseline, the records, fake
door, shell, serve and fake-shell suites each, two at a time. 23 matched; A-3 did not.

| mutant | the edit | red |
|---|---|---|
| B-0 | none | none: 305 passes |
| A-1 | the libuv shell's abort only asks for the close | shell 1: the bound |
| A-2 | the libuv shell's abort does nothing | shell 1: the bound |
| A-3 | a raise in a taker's call is logged, its stream left open | shell 4: the raise in a deadline's call, the raising take-over, and the suite's two closing leak checks |
| T-1 | a transport of seven procedures aborts by its close | records 1: seven refuse the abort |
| T-2 | `transport-abort!` calls the close procedure | records 2: each verb, seven refuse; door 3: the bound, the abort, the raises; shell 1: the bound |
| T-3 | an eighth procedure is not checked | records 1: seven or eight, or refused |
| T-4 | the facade does not export `transport-abort!` | serve 1: the export list |
| K-1 | the fake's abort only asks for the close | door 4: the bound, the abort, the raises, the raising thunk |
| K-2 | the fake's abort tells the writes outstanding nothing new | door 4: the same |
| K-3 | the fake's close begins at once, whatever is outstanding | door 1: the bound |
| K-4 | the fake's close leaves the deadline armed | door 1: the abort |
| K-5 | the fake guards no call into the taker's code | door 1: the raises |
| K-6 to K-12 | the take-over, the reads, the end, the deadline's call, the drain call, a write's callback, the close call, each unguarded | door 1 each: the raises |
| K-13 | a waiting thunk's raise only asks for the close | door 1: the raising thunk |
| K-14 | the last write's turn never begins a close asked for | door 1: closed by the taker, its write first |
| K-15 | the fake's abort leaves reading on | door 1: the abort |
| K-16 | the fake's abort leaves its taker writing | door 1: the abort |

A-3's two leak checks, "and no handle is left on the loop" and "nor a TCP handle, a read
buffer or a write request", were not predicted: the streams it leaves open still hold
their handles when the suite ends. A knock-on; its named checks are red.

**The values layer, cbe029a:** 6 rows, 5 mutants and the baseline, the view, serve and
headers suites each: 0 mismatches.

| mutant | the edit | red |
|---|---|---|
| B-0 | none | none: 55 passes |
| V-1 | `request-header-values` reads the first field alone | view 1: every field |
| V-2 | each value kept with the whitespace after it | view 1: every field |
| V-3 | the values in reverse order | view 1: every field |
| V-4 | an empty value dropped | view 1: every field |
| V-5 | the facade does not export `request-header-values` | serve 1: the export list |

A name is matched without regard to case by `headers-ref-all`, the same `header-name=?`
that `request-header` reads by; the headers suite's "ref-all across case" holds it, so no
mutant of the view's own was cut for it, a scope statement.

Every red was by value, exit 1, with no harness error. The checks the change added or
changed, and their killers:
- the records suite: each verb calls its procedure: T-2; seven or eight, or refused: T-3;
  seven refuse the abort: T-1, T-2;
- the fake's door suite: the bound: T-2, K-1, K-2, K-3; the abort: T-2, K-1, K-2, K-4,
  K-15, K-16; the raises: T-2, K-1, K-2, K-5 to K-12; the raising thunk: K-1, K-2, K-13;
  and closed by the taker, whose path the fake now takes through `taker-wrote!`: K-14;
- the shell suite: the bound: A-1, A-2, T-2; the raise in a deadline's call: A-3;
- the serve suite's export list: T-4, V-5;
- the view suite's every field: V-1 to V-4.

Found while mapping the mutants: the fake left a deadline armed before its close armed
after it, so it passed on a closed stream, where the libuv shell's close disarms it. The
fake's close now disarms it too, and the abort check arms one first (K-4). And the libuv
shell's abort was first written to stop reading and mark its taker closing before the
close; the close does both, so no check could tell them apart, and the abort is the
close alone, as a taker's raise has it.

### Decision 0024's review, and its fixes (2026-10-08)

A /code-review xhigh over #146-#149: eleven findings, nine fixed on the owner's word ("Fix
the review findings as a fifth pr"), two noted in plan §14's open list. Platform: Darwin
arm64, Chez 10.4.1, 2026-10-08.

Tests first, against #149's tip (12a36a0), named and hashed: the fake door suite 32
passes and 2 failures, the aborted write the client "read" and the end told twice. The
third new check, the late raises, was predicted red and passed. Both guards it holds
already existed; the finding was that nothing watched them, so its red is the mutants'
(R-5 to R-8). A prediction error.

On the fixed tree (e91e07b): 32 rows, 31 mutants and the baseline, the records, fake door,
shell, serve and fake-shell suites each, two at a time, 0 mismatches. The abort layer's
23, re-cut where the fake changed, redden what they did before, with three differences:
- A-3's two leak checks are now named.
- K-5 also reddens the late raises.
- K-15 and K-16 now cut `stop-taking!`, which the close and the abort share. K-16 reddens
  the end told once (a stopped taker is read on) and closed by the taker (its close never
  begins).

| mutant | the edit | red |
|---|---|---|
| R-1 | an aborted write's bytes are the client's | door 1: the abort |
| R-2 | a closing taker is still read | door 1: the end told once |
| R-3 | the end is told every time | door 1: the end told once |
| R-4 | the end told marks nothing | door 1: the end told once |
| R-5 | a late write's `ECANCELED` callback unguarded | door 1: the late raises |
| R-6 | that callback's raise swallowed, unrecorded | door 1: the late raises |
| R-7 | a close call registered after the close unguarded | door 1: the late raises |
| R-8 | that call's raise swallowed, unrecorded | door 1: the late raises |

The checks the review added or changed, and their killers:
- the abort, now with the client reading neither write: T-2, K-1, K-2, K-4, K-15, R-1;
- the end told once, and nothing read once aborted: K-16, R-2, R-3, R-4;
- the late raises: K-5, R-5 to R-8, R-6 and R-8 by value;
- the shell suite's two door checks, through `door-unread`: A-1, A-2, T-2 (the bound),
  A-3 (the raise).

Taken out while mapping: the fake cleared its end mark when reading started again. No
check reached it and no taker restarts after its end, so the fake tells an end once per
stream.

## After M8 — a coroutine parks on a full continuation, and each park lands once (2026-10-09)

Decision 0025, on two forms: "A server slice next", in chez-websocket's M4.3 step 3
review, and "Number each park", here. The code's layer, `feat/0025-park`, carries every
change the mutants read.

Platform: Darwin 25.6.0 arm64 (Apple M1), Chez Scheme 10.4.1 (`tarm64osx`), 2026-10-09. The
heap and cost figures were measured on Linux 6.12.76-linuxkit aarch64 in Docker as well
(Ubuntu 24.04, Chez 10.4.1), where they read the same.
- **The code:** `src/http-server/private/scheduler.sls`.
- **The suite:** `tests/test-scheduler.sps`, 23 checks.

**The oracles:**
- Chez's refusal of a one-shot continuation entered a second time: an `&assertion` naming no
  one, `attempt to invoke shot one-shot continuation`. Measured.
- A one-shot continuation captured 4 calls deep and left by an escape keeps a stack segment,
  3,419 to 3,420 B, whatever the scheduler does. That makes it the heap check's reference,
  measured in the run.
- 0025's form: a second landing raises an assertion naming the verb.

### The test-first runs

Each red set was named and hashed before its run, but for stage 0's.
- **Stage 0:** the two new rows and the calibration's new name, on main's scheduler.
  - A slip: the suite was first run before its prediction was named. That run showed the red
    set: the two new rows, 21 passes. It did not show their values.
  - The prediction, hashed after that run, named the values blind. The values probe then
    read, as named:
    - the second landing `(((landed 1) (raised assertion)) ((landed 1) (raised assertion)))`,
      Chez's refusal, naming no one;
    - the heap: 3,691 B parked against a 3,420 B reference, not under half.
- **Stage 1:** `call/cc` alone, no check. As predicted:
  - the second-landing row alone red, its value
    `(((landed 1) (landed 2) (returned 2)) …)`, the code after the park run twice;
  - the heap 705 B against 3,419, under half;
  - `make test`: fifty-one suites, 1,984 expected passes and that one failure.
- **Stage 2:** the numbered landing. As predicted:
  - the row reads `(((landed 1) (raised assertion coroutine-park!)) ((landed 1) (raised
    assertion coroutine-yield!)))`;
  - the heap 745 B against 3,420;
  - `make test` green: fifty-one suites, 1,985.

### The mutants

Each red set was named and hashed before its run. Three were re-cut, from the M7 exit's
log, for the code this change touches; the others were cut new.
- The new and test mutants ran against every suite, except PK-4 and the test mutants,
  which ran against the scheduler suite alone.
- The rows that ran every suite also ran the values probe.
- The M7 re-cuts were predicted by suite, as the M7 exit recorded them.

| id | mutant | red, predicted and seen |
|---|---|---|
| BASE | the unmutated tree (a comment) | none; values as stage 2 |
| PK-1 | `suspend!` by `call/1cc` again, its park still numbered | scheduler: the second-landing row, `(raised assertion)` naming no one, and the heap row, 3,862 B against 3,420 |
| PK-2 | the landing's check gone | scheduler: the second-landing row, the code after the park run twice |
| PK-3 | a landing does not mark its park landed | the same |
| PK-4 | the park not numbered before its capture: every first landing refused | scheduler alone: R3's row, a raise after a park, a park woken, a yield, a guard after a park, a parameter across a park, the second-landing row (`((raised assertion coroutine-park!))`) |
| PK-5 | the landing's check by `fx>=?`: a second landing passes | scheduler: the second-landing row, run twice |
| PK-6 | a yield's landing not checked | scheduler: the second-landing row, its yield half run twice |
| PK-7 | the refusal names `suspend!`, not the verb | scheduler: the second-landing row, `(raised assertion suspend!)` |
| PK-8 | the refusal an `&error`, not an `&assertion` | scheduler: the second-landing row, `(raised other)` |
| PT-1 | the suite's reference by a full continuation | scheduler: exit 3, the provenance failure, 288 B each |
| PT-2 | the suite's `entered-twice` never arms its before thunk | scheduler: the second-landing row, `(((landed 1) (returned 1)) …)` |
| PT-4 | the suite's calibration measures coroutines that end | scheduler: the calibration row |
| M7S-B | R3: a coroutine's first run returns normally at its end, into the continuation that first entered it | connection-switch 1, contract 67, message-loop 7, scheduler (raised, exit 2, 7 failed), shell (raised, exit 2), waits 28 |
| M7S-H | a wake of a coroutine that is not parked is not refused | scheduler: the waking row |
| M7S-R | a woken coroutine entered again from its start | connection-switch 1, contract 11, message-loop 6, scheduler 8 (the second-landing row among them, `(() ())`), shell (raised, exit 2, 24 failed), waits 36 |
| M7W-8 | a wait on no coroutine is not refused as R2 | scheduler 1, shell 1, waits 2 |
| M7X-1 | the scheduler keeps the drain's continuation once a coroutine has run | none: survives, as at the M7 exit |

- **Run 1: 17 rows, 2 mismatches, one prediction error.** M7S-B and M7S-R also reddened
  `connection-switch` and `message-loop`. Their predictions took the M7 exit's suites, and
  those two suites' waiting rows came after it:
  - `message-loop`'s with #127 (decision 0020);
  - `connection-switch`'s take-over that awaits with decision 0023.
- **Run 2:** those two rows, re-predicted, **0 mismatches**, the same counts.
- Every mutant loaded. M7S-B did not hang, though its stale return re-ran an old drain:
  under `call/cc` that re-run is silent (decision 0025's Consequences).

**Every new or changed check has a killer by value:**
- the second-landing row: PK-1, PK-2, PK-3, PK-5, PK-6, PK-7, PK-8, PK-4, PT-2 and M7S-R;
- the heap row: PK-1;
- its provenance stop: PT-1;
- the calibration, renamed: PT-4.

**The survivor:** M7X-1, as at the M7 exit: no check reads what the scheduler keeps once a
coroutine has run. Why it keeps nothing a check sees, now that a park's capture promotes the
drain's continuation, was not measured.

The values probe (`rows.sps`) is built from the suite's own helper text, and was run with
each mutant's library root first.

## After M8 — decision 0025's review: the drain full too, and a refusal that ends the one running (2026-10-09)

The review's fixes, on `fix/0025-review`, stacked on the ledger branch. Two forms ("Drain
full too", "End the one running") and eight findings.

Platform: Darwin 25.6.0 arm64 (Apple M1), Chez Scheme 10.4.1, 2026-10-09. The values probes
read the same on Linux 6.12.76-linuxkit aarch64 and x86_64 (the latter under emulation), in
Docker.
- **The code:** `src/http-server/private/scheduler.sls` and `src/http-server/private/waits.sls`.
- **The suites:** `tests/test-scheduler.sps` (26 checks), `tests/test-waits.sps` (38),
  `tests/testing.sls` (`heap`) and `tests/test-clients.sps` (its own `heap` gone).

**The oracles:**
- the two forms;
- a one-shot continuation captured 4 calls deep and left: 3,516 B allocated and 3,419 to
  3,420 B kept, measured in the run;
- the peers' behaviour (decision 0025's amendment).

**The values probes** (`rows-sched.sps`, `rows-waits.sps`) are each built from its suite's
own text before `run-suite`, so neither can drift from the checks.

### The test-first runs

Each red set and its values were named and hashed before the run; all four matched.
- **Stage 0:** the tests on the branch's code. 1,985 passes and the four new rows red:
  - the guarded row, the code after the guard run twice;
  - the cross row, `(b returned #f)`, and A's later wake an assertion;
  - the once row, 4,191 B against 3,516;
  - the waits row, naming `coroutine-park!`.
- **Stage 1:** the drain full. The once row green at 1,177 B; 1,986 passes.
- **Stage 2:** the refusal ends the one running. The guarded and cross rows green; 1,988
  passes.
- **Stage 3:** a waiting verb names itself. The waits row green; 1,989 passes.

### The mutants

28 rows, 27 mutants and the baseline. The scheduler's and the suites' mutants were cut new,
or re-cut from this slice's first log for the code the review changed. M7S-B, M7S-H, M7S-R,
M7W-8 and M7X-1 were re-cut from M7's log.

| id | mutant | red, predicted and seen |
|---|---|---|
| BASE | the unmutated tree (a comment) | none |
| RV-1 | the drain's resume by `call/1cc` again | scheduler: the once row, 4,191 B against 3,516 |
| RV-2 | the refusal raised where the park lands | scheduler: the guarded row (the code after it ran twice) and the cross row (`(b returned #f)`) |
| RV-3 | the coroutine running ended unmarked as raised | scheduler: the second-landing, guarded and cross rows (`(returned #<condition>)`); waits: the await row |
| RV-4 | the refusal names no one | scheduler: those three, `(raised assertion)`; waits: the await row |
| RV-5 | a wait parks without naming itself | waits: the await row, naming `coroutine-park!` |
| RV-6 | `coroutine-park!` drops the name it is given | the same |
| RV-7 | the landing checks the number's parity | scheduler: the cross row, `((a after-1st) (a after-1st) (a raised …))` |
| PK-1 | `suspend!` by `call/1cc` again | scheduler: the second-landing, guarded, cross and heap rows (3,888 B); waits: the await row |
| PK-2 | the landing's check gone | scheduler: the second-landing, guarded and cross rows, each run twice; waits: the await row |
| PK-3 | a landing does not mark its park | scheduler: the second-landing and guarded rows; waits: the await row |
| PK-4 | the park not numbered before its capture | scheduler alone, with waits: nine rows, every one that lands a park; waits red |
| PK-5 | the check by `fx>=?` | scheduler: the second-landing, guarded and cross rows; waits: the await row |
| PK-6 | a yield's landing not checked | scheduler: the second-landing row, its yield half |
| PK-7 | the refusal names `suspend!` | scheduler: the three rows; waits: the await row, `(raised suspend!)` |
| PK-8 | the refusal an `&error` | scheduler: the three rows, `(raised other)` |
| PT-1 | the held reference by a full continuation | scheduler: exit 3, the provenance failure |
| PT-1b | the allocated reference by a full continuation | none: equivalent (3,484 B allocated) |
| PT-2 | entered-twice never armed | scheduler: the second-landing row |
| PT-3 | entered-guarded never armed | scheduler: the guarded row |
| PT-4 | the cross row's B enters nothing | scheduler: the cross row |
| PT-5 | the await row never armed | waits: the await row |
| PT-6 | the allocated reference 0 calls deep | scheduler: the calibration and once rows |
| M7S-B | R3 broken (re-cut) | connection-switch 1, contract 68, message-loop 7, scheduler (raised, exit 2, 7 failed), shell (raised, exit 2), waits 28 |
| M7S-H | a wake of one not parked let through (re-cut) | scheduler: the waking row |
| M7S-R | a woken coroutine entered again from its start (re-cut) | connection-switch 1, contract 11, message-loop 6, scheduler 10, shell (raised, exit 2, 24 failed), waits 37 |
| M7W-8 | a wait on no coroutine not refused as R2 (re-cut) | scheduler 1, shell 1, waits 2 |
| M7X-1 | the scheduler keeps the drain's continuation (re-cut) | shell: the idle check, "a connection idle after its handler, its reader and its producer waited holds none of the coroutines they ran on" |

- **Run 1: 28 rows, 1 mismatch, one prediction error.** PT-1b is equivalent: a full
  continuation captured 4 calls deep and left allocates a segment too, 3,484 B. Read from
  the runner's report, PK-4 showed a second mismatch. The runner prints at most eight FAIL
  lines a suite, and PK-4's ninth, the cross row, was in its suite's log. The comparison
  now reads each suite's log.
- **Run 2:** PK-4, and PT-1b re-predicted equivalent: **0 mismatches.**
- Every mutant loaded. M7S-B's suites print a `coroutine-wake!` assertion: the R3 breach
  reaches a wake of an ended coroutine. It did not hang.

**Every new or changed check has a killer by value:**
- the guarded row: RV-2, RV-3, RV-4, PK-1, PK-2, PK-3, PK-5, PK-7, PK-8, PT-3;
- the cross row: RV-2, RV-7 (finding 2's parity), PK-1, PK-2, PK-5, PT-4;
- the once row: RV-1, PT-6;
- the calibration row: PT-6;
- the waits' await row: RV-3 to RV-6, PK-1 to PK-3, PK-5, PK-7 and PT-5;
- the second-landing row, its values changed only in how they are read: PK-1 to PK-8,
  RV-3, RV-4.

**No longer a survivor:** M7X-1, since the drain's continuation is full. Kept, it holds the
last coroutine resumed, and the shell suite's idle check reddens.

## After M8 — the held shutdown's check timed by the loop's clock (2026-10-10)

The shell suite's "a shutdown asked once the loop has been held 300 ms dates its drain
after the hold", on `test/held-shutdown-loop-clock`. It held the loop 300 ms of Chez's
monotonic clock and took the drain's date, on libuv's loop clock, at 299 ms past `before`
or more. Now `hold-until!` times the hold by the loop's clock, read on a loop made for the
hold, and the bound is 300. Tests only: nothing under `src/` moved.

Platform: Darwin 25.6.0 arm64 (Apple M1), Chez 10.4.1 `tarm64osx`, libuv 1.52.1; and Linux
6.12.76-linuxkit aarch64 in Docker, `chez-libuv-noble-scratch:10.4.1` (Ubuntu 24.04, libuv
1.48.0, CI's), Chez 10.4.1. 2026-10-10, the library path as above.

**The oracles:**
- libuv's source: every loop in a process reads one clock, `uv__hrtime(UV_CLOCK_FAST)`,
  which never steps back (1.52.1: `src/unix/internal.h:467-471`; `linux.c:1603-1637`, one
  fast clock id a process; `darwin.c:60-63`; `win/core.c:325-329`, `win/util.c:464-483`);
- on Linux that clock is CLOCK_MONOTONIC_COARSE where it ticks every millisecond or finer,
  and Chez's is CLOCK_MONOTONIC (chez-websocket's `.plans/research/2026-10-10-s-silent-clock.md`).

### The probe

`.plans/research/spike/held-shutdown-clock.sps` repeats the check with the real shell,
each round on loops of its own, both ways in turn: the old hold, 300 ms of Chez's clock,
and the new one, a spin on a second loop until its time reads `before + 300`. It prints
the drain's date less `before`, in the loop's ms.

| where | rounds | Chez's clock: date − before | under 299 | the loop's clock: date − before | under 300 |
|---|---|---|---|---|---|
| Darwin, alone | 100 | 299 to 301; 299 in 86 | 0 | 300 in 100 | 0 |
| Darwin, four at once | 400 | 299 to 300; 299 in 351 | 0 | 300 to 301; 300 in 399 | 0 |
| Linux, alone | 300 | 299 to 300; 299 in 285 | 0 | 300 in 300 | 0 |
| Linux, four at once | 1,200 | 269 to 339; 299 in 1,026 | 53 | 300 to 356; 300 in 1,109 | 0 |

- **The old bound was not derived.** Four at once on Linux, the date fell under it in 53
  rounds of 1,200; in the least, Chez's clock moved 302.5 ms over the hold and the loop's
  269. Alone, on either, it never fell under; over all four rows it sat at the bound, 299,
  in 1,748 rounds of 2,000.
- **The new bound is exact.** The date never fell under 300 in 2,000 rounds. A loop's 300
  ms of hold took 288.5 to 356.3 ms of Chez's clock on Linux four at once, 298.8 to 300.5
  alone, and 299.0 to 301.0 on Darwin.

Run: `CHEZSCHEMELIBDIRS=<make build's library path> chez --program
.plans/research/spike/held-shutdown-clock.sps N` (300 rounds alone and 300 each in four
containers at once on Linux; 100 alone and 100 each four at once on Darwin).

### The mutants

Four rows, every suite each (scratchpad `mut/run1`, four at a time), each red set named
and its spec hashed before the run (sha256 `d30a2d50` HS-0, `c93febcb` M8H-9, `537b3bbf`
HS-SAME, `d1387144` HS-SAME+M8H-9). Every mutant loaded, and every row reported 51 suites.

| id | mutant | red, predicted and seen |
|---|---|---|
| HS-0 | none: a comment's text in the shell suite | none: 51 suites, 1,989 expected passes |
| M8H-9 | the shutdown dated by the loop's cached time: `stopping!` without `uv-update-time!` (re-cut on this tree) | shell 1: this check, `(#f stopped)` |
| HS-SAME | the hold spins on the suite's own loop | none |
| HS-SAME+M8H-9 | both | none: M8H-9 survives |

- **0 mismatches.**
- **M8H-9 dates the drain before the hold.** Run with its shell, the probe read the date
  less `before` as 0 in every round, both ways.
- **HS-SAME+M8H-9 is why the hold runs on a loop of its own.** Spun on the suite's loop,
  the hold leaves that loop's time at its end, and M8H-9's shutdown reads it. A scope
  statement, kept to say so.
- **On Linux** (the noble image, the shell suite, each row three times): the same. M8H-9
  red at this check, `(#f stopped)`, each time; the other three green, 204 expected passes.

**The changed check has its killer by value:** M8H-9.

## After M8 — a taker's arm brings the loop's clock up to date (2026-10-10, rebased 2026-10-11)

chez-websocket's #66 recorded SC-1 as a survivor (its `.superpowers/sdd/m4-mutations.md`):
`taker-deadline!` without its `uv-update-time!` left every server suite green. On
`test/taker-arm-refreshes-clock`, cut from 6191d47; tests only. `tests/test-shell.sps`
gains one check and its taker (`/door-held`). Built first with a helper of its own,
`hold-past!`; rebased onto 67024b0 once #162 merged, on the owner's word, it holds the
loop with #162's `hold-until!`, the same helper, and `hold-past!` is gone.

Platform: Darwin 25.6.0 arm64, Chez Scheme 10.4.1, libuv 1.52.1, 2026-10-10 and 11. Linux
6.12.76-linuxkit aarch64, libuv 1.48.0, in `chez-libuv-noble-scratch:10.4.1`, on a dev
shim; and x86_64 in `chez-websocket-ci-amd64:10.4.1`, under emulation.

**The check**, "a taker that holds the loop 300 ms as it takes the stream arms its
deadline after the hold, at the loop's time brought up to date". The taker reads the
loop's time as it takes the stream (`stale`). It holds the loop until libuv's clock reads
`stale` + 300, reads the loop's time again, arms a deadline of a minute, and reads the
connection's deadline. The check holds two things, and a failing side answers what it
read:
- the premise: the loop's time after the hold is still `stale`, so the arm has a stale
  time to bring up to date;
- the deadline, less the minute, is at least 300 ms past `stale`.

**The oracle:** libuv's clock, read on a loop made for the hold (the section above), so
the suite's loop's time is left as it was and the bound is exact. A bound of "the hold
less 1 ms" on Chez's clock could flake on Linux, whose loop clock is the coarse one.

### The runs

Each row's red set and the new check's values were named and hashed before each run; six
rows, every suite each, three at a time. The values were read through a copy of
`(testing)` in each mutant's root that prints a failure's actual and expected values.

| id | mutant | red, predicted and seen |
|---|---|---|
| B-0 | none (a comment) | none: shell 205 passes |
| SC-1 | `taker-deadline!` without `uv-update-time!` | shell: the new check, `(satisfied stale 0 satisfied)` |
| SC-2 | the clock brought up to date after the arm | shell: the new check, `0` |
| TK-1 | the taker's hold leaves the loop's time brought up to date | shell: the new check, the premise reading the loop's time after the hold |
| TK-1+SC-1 | both | shell: the new check, the premise alone; the bound holds, by the hold's refresh |
| TK-2 | the taker's hold holds nothing | shell: the new check, a small number |

- **Run 1, on d85c5cc (`hold-past!`), 2026-10-10: 0 mismatches.** TK-1 spun the hold on
  the suite's loop, TK-2 spun it not at all. TK-1 read `3503466694`, TK-2 `6`. The clients
  suite stopped at status 2 in every row, its tools not yet built in this worktree; every
  suite 1,952 passes in B-0.
- **On the rebased tree, TK-1 and TK-2 are cut at the taker's call to `hold-until!`,** so
  neither reaches the held shutdown's check, which shares the helper: TK-1 brings the
  loop's time up to date after the call, TK-2 holds until `stale`.
- **Run 2: 6 mismatches, one prediction error.** The clients suite was green in every
  row: the `make test` run since run 1 had built its tools. Every shell red set and value
  matched: SC-1 and SC-2 `0`, TK-1 `3542140092`, TK-1+SC-1 `3542140072`, TK-2 `0`; B-0
  1,990 passes.
- **Run 3, re-predicted: 1 mismatch, load.** B-0 went red on "a connection held in its
  handler, nothing armed, the timer stopped, is closed at the drain's deadline, on time",
  its drain wait `iterations-exhausted`: the check #162's entry measured red under load on
  main's tree too. It runs before the new check. B-0's shell suite alone: green, 205, five
  runs of five; run 2's B-0 was green. Every other row as run 2.
- **The gap run.** SC-1's library under main's `tests/test-shell.sps`: green, 204 passes,
  three runs of three, on 6191d47's suite and on 67024b0's. The same root reddens the new
  suite, so the mutant loaded.
- **Linux aarch64.** SC-1 is red by value there too, `0`, on both trees.
- **Linux, the rebased tree.**
  - aarch64: every suite 1,951 passes, the clients suite at status 2.
  - The shell suite 100 times on aarch64, four containers at a time, beside another
    session's eight. The new check passed all 100. Seven runs were red, each on one older
    check that runs before it: the 20 ms sleep's twice and a connection held in its
    handler five times. #162's held shutdown was never red.
  - x86_64: the shell suite 205, SC-1 `0`, every suite 1,951 passes.
- **Linux, the first tree** (d85c5cc).
  - aarch64: every suite 1,952 passes.
  - The shell suite 200 times, beside the same eight. The new check passed all 200. Five
    runs were red on older checks: the held shutdown's twice, the held handler twice and
    the door-timed once.
  - x86_64: every suite 1,951 passes.
- **The serve suite's "once serve has returned, a SIGINT ends the process at once"** was
  red in each x86_64 run (5 of 5 on the first tree) and once on aarch64 beside the eight
  containers. It waits on a child process by loop turns, so a slow child can run out of
  them. That suite and `src/` are main's, and main's CI passed the check on a real x86_64
  runner (run 38006078331).

**The new check's killers by value:**
- SC-1 and SC-2, the code;
- TK-1 and TK-1+SC-1, the premise. Without it, a hold that refreshed the loop's time would
  let SC-1 through, as TK-1+SC-1 shows;
- TK-2: the bound needs the hold.

No other check changed. **No longer a survivor:** SC-1.

## After M8 — the 20 ms sleep's check timed by the loop's clock (2026-10-11)

The shell suite's "a handler that holds the loop 30 ms, then sleeps 20 ms, sleeps 18 ms
or more by the monotonic clock; …", on `test/sleep-by-loop-clock`. Its `/sleep` handler
held the loop 30 ms of Chez's monotonic clock, then timed its sleep of 20 ms by that
clock. The check took 18,000 µs or more, saying the loop's clock "may trail the monotonic
clock by one". Now:
- the hold and the sleep are each timed by the loop's clock, read on a loop made for the
  read (`loop-ms`, beside `hold-until!`), and the bound is 20;
- a witness, a timer on the suite's loop due at `before` plus 19, reads how many timed
  waits are armed as it fires, and must read 1.

The check reads "… sleeps 20 ms or more by the loop's clock, a timer due 19 ms in firing
while the sleep is armed; …". Tests only: nothing under `src/` moved.

Platform: Darwin 25.6.0 arm64 (Apple M1), Chez 10.4.1 `tarm64osx`, libuv 1.52.1; and Linux
6.12.76-linuxkit aarch64 in Docker, `chez-libuv-noble-scratch:10.4.1` (Ubuntu 24.04, libuv
1.48.0, CI's), Chez 10.4.1. 2026-10-11, the library path as above.

**The oracles:**
- libuv's one clock, as for the held shutdown above: every loop in a process reads
  `uv__hrtime(UV_CLOCK_FAST)`, which never steps back;
- libuv's timers: `uv_timer_start` dates a timer `loop->time` plus its timeout, and
  `uv__run_timers` runs the due ones in the order they are due, then the order they were
  started (1.52.1 `src/timer.c`: `timer_less_than`, `uv_timer_start`, `uv__run_timers`;
  the file's only change since 1.48.0 drops an include). chez-libuv's `uv-timer-start!`
  calls `uv_timer_start` and refreshes nothing (v0.8.0 `src/libuv/timer.sls:50-65`);
- the waits' own code: `sleep-ms` arms its time at the loop's time brought up to date
  (`loop-clock!` in `shell.sls`: `uv-update-time!`, then `uv-now`) and starts the waits'
  timer for its delay; `waits-fire!`, the waits' timer's callback, ends a sleep only once
  a reading brought up to date is at or past it (`heap-advance!`, `<=`).

**What follows.**
- The length: `before` is read no later than the sleep's arming, the sleep ends no earlier
  than 20 ms after that, and the answer's reading is later still. So the sleep lasts 20 of
  the loop's milliseconds at least, on any platform and under any load.
- The witness: started from the cached time `cached` with a delay of `before` plus 19 less
  `cached`, it is due at `before` plus 19. The waits' timer is due at the arming plus 20,
  `before` plus 20 or later, so the witness runs first and reads the sleep: 1.
- Under M7T-21 the sleep and the waits' timer are dated from `cached`, at least 30 before
  `before`. The sleep is due first, `waits-fire!` takes it out, and the witness, if it has
  fired by the wake, reads 0. That holds whatever the wake's latency. The length does
  not: M7T-21's sleep lasts as long as its wake takes.

### The probes

`.plans/research/spike/sleep-clock.sps` repeats the `/sleep` handler with the real shell
and a client on its loop, two ways a round: the old hold, 30 ms of Chez's clock, and the
new one, a spin on a second loop until its time reads 30 ms on. Either way it times the
sleep by both clocks: Chez's in µs, as the check read it until now, and the loop's in ms,
read on a loop of its own, as the check reads it since.

| where | rounds a way | old hold: Chez µs | under 18,000 | old hold: loop ms | new hold: Chez µs | under 18,000 | new hold: loop ms |
|---|---|---|---|---|---|---|---|
| Darwin, alone | 200 | 19,281 to 45,858 | 0 | 20 to 46 | 19,498 to 54,755 | 0 | 20 to 54 |
| Darwin, four at once | 800 | 19,331 to 76,516 | 0 | 20 to 76 | 19,414 to 76,702 | 0 | 20 to 76 |
| Linux, alone | 300 | 15,685 to 52,316 | 5 | 20 to 52 | 18,140 to 80,632 | 0 | 20 to 80 |
| Linux, four at once | 1,200 | 8,295 to 110,310 | 35 | 20 to 108 | 14,936 to 89,534 | 7 | 20 to 89 |

- **The old bound was not derived.** On Linux the sleep fell under 18,000 µs of Chez's
  clock alone (5 of 300) and four at once (35 of 1,200). In the least, the sleep spanned
  24 of the loop's ms and 8,295 µs of Chez's. Timing the hold by the loop's clock does
  not save it: 7 of 1,200. On Darwin it never fell under 19,281 µs.
- **The new bound is exact.** By the loop's clock the sleep never fell under 20 ms in
  5,000 rounds, and sat at 20 in 1,393 of them.
- **The two clocks part by more than the sleep on Linux.** A hold of 30 ms of Chez's clock
  moved the loop's 19 to 160 ms four at once; one of 30 of the loop's ms took 4,092 to
  108,160 µs of Chez's.

`.plans/research/spike/sleep-witness.sps` is the same with the witness, and prints what it
read. Run with the shell as built, and with M7T-21's shell first on the library path:

| where | shell | rounds | sleep 20 ms or more by the loop's clock | witness read 1 |
|---|---|---|---|---|
| Linux, one probe beside ten other containers | as built | 600 | 600 | 600 |
| Linux, the same | M7T-21 | 600 | **20** | 0: not-fired 585, 0 in 15 |
| Darwin, alone | as built | 400 | 400 | 400 |
| Darwin, alone | M7T-21 | 400 | **6** | 0: not-fired 397, 0 in 3 |

- **The length alone let M7T-21 pass** in 26 rounds of 1,000. In 23 of them Chez's clock
  moved within a millisecond of the loop's or more, up to 210,428 µs for 210 ms: real pauses in the
  wake, not the loop's clock jumping. Bigger margins would have to outrun them.
- **The witness never did.** It read 1 in all 1,000 rounds as built, and never under
  M7T-21.

Run: `CHEZSCHEMELIBDIRS=[<mutant root>:]<make build's library path> chez --program
.plans/research/spike/sleep-clock.sps N` (300 rounds alone and 300 each in four
containers at once on Linux; 200 alone and 200 each four at once on Darwin), and
`sleep-witness.sps` the same way (300 and 200 rounds, each shell). A read of `loop-ms`
costs 8 to 12 µs on Darwin (1,000 reads, three rounds).

### The first run: the length alone

Four rows, every suite each (scratchpad `mut/run1`), specs hashed before the first run of
the changed check (sha256 `571f9068` SL-0, `090ca529` M7T-21, `da1cd439` SL-SAME,
`2bdb7922` SL-SAME+M7T-21), three runs on Darwin and two of the shell suite three times
on Linux:
- M7T-21 reddened the check alone, `(200 n)`, n 8, 1 and 2 on Darwin, where I predicted
  0 or 1, and 2, 2, 2, 2 and 4 on Linux. SL-0, SL-SAME and SL-SAME+M7T-21 stayed green.
- **But in Linux's fourth run M7T-21 passed:** its wake took 20 of the loop's ms or more.
  Its red rested on the wake's latency, as the old check's had (18 ms of Chez's clock).
  The probe then measured how often (the second table above).
- The first run's clients suite stopped in every row: `build/oha` was not fetched in this
  worktree. With it in place (`tests/fetch-oha.sh` kept the pinned binary by its
  sha256), the later runs read it green.

### Decided by form

Asked with the length's misses (1 of 6 Linux runs of the shell suite; with sleep-witness.sps
under M7T-21, the new hold's sleep 20 ms or more in 7 rounds of 300, beside other
sessions' containers) and the witness's 600 Linux rounds each way, the owner chose "Add
the witness (Recommended)". Weighed:
"Length check only", shipping M7T-21's red as one that rests on latency; and "Bigger
margin", a hold of 300 ms and a sleep of 200 ms, which M7T-21 passes only past a 200 ms
pause, about 0.5 s more a run, and still not derived.

### The mutants

Eight rows (scratchpad `mut/run2`, four at a time), each red set and value named and its
spec hashed before the first run of the witness check (sha256 `32aef28a` W-0, `fe858d3b`
M7T-21, `6684909d` SL-SAME, `3159defa` SL-SAME+M7T-21, `7c29bc6f` W-PAUSE, `510bdea1`
W-PAUSE+M7T-21, `c703d1b0` W-STALE, `477d3219` W-STALE+M7T-21). The first four ran over
every suite, the four W- rows over the shell suite, which alone runs their edit. The
runner put a `(testing)` that prints a failing check's values after the mutant's root.
Every mutant loaded, and every row reported its suites.

| id | mutant | red, predicted and seen |
|---|---|---|
| W-0 | none: a comment's text in the shell suite | none: 51 suites, 1,989 expected passes |
| M7T-21 | the waits' clock read with no update: `loop-clock!`'s now without `uv-update-time!` (re-cut on this tree) | shell 1: this check, `(200 3 not-fired)` |
| SL-SAME | `loop-ms` reads the suite's own loop, bringing its time up to date | none |
| SL-SAME+M7T-21 | both | none: M7T-21 survives |
| W-PAUSE | the handler holds 25 of the loop's ms after the wake, before the answer reads the loop's clock | none |
| W-PAUSE+M7T-21 | both: a pause in M7T-21's wake | shell 1: this check, `(200 at-least-20-ms not-fired)` |
| W-STALE | the witness started 19 ms on from the cached time, not from `before` | none |
| W-STALE+M7T-21 | both | shell 1: this check, `(200 4 1)` |

- **0 mismatches.** SL-SAME's shell suite also went red, at "a MiB answer's write holds
  the loop less than a tick: …" (10), with other sessions' ten containers running; alone
  it was green 3/3, and the soaks below see that check red on main's tree too: load.
- **W-PAUSE+M7T-21 is what the witness is for.** The pause makes M7T-21's sleep last 20
  ms, so the length passes, and the witness, closed before it was due, reads not-fired.
- **W-STALE+M7T-21 is why the witness is timed from `before`.** Started 19 ms on from the
  cached time, it is due just before M7T-21's stale sleep and reads it armed, 1; only
  the length is red.
- **SL-SAME+M7T-21 is why `loop-ms` runs on a loop of its own.** Read on the suite's
  loop, `before` brings that loop's time up to date, M7T-21's sleep is armed at `before`,
  and both parts hold. A scope statement, kept to say so.
- **The hold needs a loop of its own too** (`hold-until!`, #162's). Spun on the suite's
  loop (#162's HS-SAME edit), it leaves that loop's time at the hold's end, so M7T-21's
  sleep lasts nearly 20 ms. HS-SAME+M7T-21 against the length alone (sha256 `e0b9114e`,
  predicted mostly green), the shell suite ten times: green at this check 10/10. Run 7
  went red at "a MiB answer's write holds the loop less than a tick" (11), with the first
  soak running: load.
- **Load in the first run's rows:** SL-SAME+M7T-21 went red once at the serve suite's
  "once serve has returned, a SIGINT ends the process at once", `(satisfied satisfied ()
  (0 sigterm))`, and once at the contract's "through the coroutine shell, three requests
  in one write, the client's end at once, …" (one shell's third answer carried
  `Connection: close`, the other's did not). Each was green in that row's other runs and
  in M7T-21's (the same `src/` edit), and alone green 3/3 under each of the two rows.
- **On Linux** (the noble image, the tree as committed, the shell suite, each row three
  times, beside other sessions' containers): W-0 and SL-SAME+M7T-21 green, 204 expected
  passes; M7T-21 red at this check, `(200 1 not-fired)`, `(200 2 not-fired)` and `(200 3
  not-fired)`; W-PAUSE+M7T-21 `(200 at-least-20-ms not-fired)` each time; W-STALE+M7T-21
  `(200 2 1)`, `(200 2 1)` and `(200 4 1)`.

**The changed check has its killers by value:** M7T-21 (both parts), W-PAUSE+M7T-21
(the witness alone) and W-STALE+M7T-21 (the length alone).

## After M8 — the timer-stop waits read from the trace, and the taker's arm read after it (2026-10-11)

Two shell checks that went red under load, on `test/timer-waits-under-load`: "a connection
held in its handler, nothing armed, the timer stopped, is closed at the drain's deadline,
on time" (the held-connection check) and "a taker's deadline, armed with the timer
stopped, passes the first time the timer fires at or after it, once" (the taker check).
Each read `fired`, the count of the shell's firings, once the handler was seen waiting or
the stream handed off, then waited for one more. Now each waits for `fired-since-emptied?`: a firing
traced after the first disarm that followed the connection's last arm. And the taker check's taker
notes `armed` after its arm, not before. Tests only: nothing under `src/` moved.

Platform: Darwin 25.6.0 arm64 (Apple M1), Chez 10.4.1 `tarm64osx`, libuv 1.52.1; and Linux
6.12.76-linuxkit aarch64 in Docker, `chez-libuv-noble-scratch:10.4.1` (Ubuntu 24.04, libuv
1.48.0, CI's), Chez 10.4.1. 2026-10-11, the library path as above.

**The oracles:**
- the shell's code: `tick!` stops the timer at a firing that finds the wheel empty while
  the server does not drain, and traces the firing (`server-step!`'s `(tick now)`) after
  that decision; `run!` traces each action before it performs it; `start-ticking!`, at an
  arm, starts it again. So once the wheel has emptied, the next firing stops the timer,
  and nothing but an arm starts it;
- `taker-deadline!` arms at `uv-now` after `uv-update-time!`, and starts the timer with
  `uv-timer-again!`, which reads the loop's time and does not bring it up to date: the
  loop's time after the arm is the time the deadline counts from.

### The probe

A copy of the suite, run as the program, the checks unchanged. Before each check's wait it
counted the shell's firings traced since the connection's last
`disarm-deadline` (`since`), and it counted the wait's turns and the loop's milliseconds
across it. For the taker check the taker also noted the loop's time after its arm and the wheel's
deadline (`connection-deadline`). It printed one line a check a run. The values shadow, a
copy of `tests/testing.sls` printing a failing check's actual and expected values, was
first on the path. Eight containers at once, 50 runs each.

| tree | runs | the held-connection check red | its `since` ≥ 1 | the taker check red | its `since` ≥ 1 |
|---|---|---|---|---|---|
| main's (e20d9cb) | 400 | 20 | 20, the same 20 | 1 | 1, the same |

- **Every red run had its stopping firing before the suite looked, and every such run was
  red.** Its values were #162's: the held-connection check `(satisfied 0 iterations-exhausted satisfied
  satisfied () eof on-time)`, the taker check `(satisfied iterations-exhausted
  iterations-exhausted #t satisfied satisfied #t #t 1)`.
- **What spent the turns.** In each red run `fired` was 1, that firing 0 to 51 ms of the
  loop's clock before the wait began, and no firing came in the wait: 4,097 turns over
  10,806 to 25,618 ms of the loop's clock, 2.6 to 6.3 ms a turn, the suite's own 1 ms
  ticker the only timer left. The shell's timer had stopped. In the green runs the wait
  took 2 to 7 turns and 3 to 62 ms.
- **The taker's `armed`.** Read before the arm, it trailed the loop's time after the arm by
  0 ms in 386 runs, 1 in 12 and 2 in 2, and the wheel's deadline was that later time plus
  50 in all 400. The leg "no firing between the deadline and the one that passed it" never
  went false here, read either way.
- **Other checks red in that soak**, none changed here: the 20 ms sleep check 11 times, "a
  MiB answer's write holds the loop less than a tick" 4 (actual `10`), and slowhttptest's
  slow body once (its `armed >= sent` false).

### The demonstrations on main's tree

Four rows on the shell suite, each with the values shadow (scratchpad `mut/old`).

| id | what | seen |
|---|---|---|
| B-0 | none: a comment's text | green, 204 |
| LOAD-1 | the loop held 300 ms as the held connection's handler is asked for (`holding-at` matched on the action's verb, `call-handler`), after its last disarm | the held-connection check red, `(satisfied 0 iterations-exhausted …)`, the soak's values |
| LOAD-2 | the loop held 300 ms at the door's `hand-off`, after its last disarm | the taker check red, `(satisfied iterations-exhausted …)`, the soak's values |
| STALE | the `/door-timed` taker holds the loop 30 ms by libuv's clock (`hold-until!`) between noting `armed` and arming | the taker check red, `(… #t #f 1)`: firings between `armed` + 50 and the one that passed it |

### The mutants

Thirteen rows on this branch's tree, and the four above on main's (`mut/old`), each red set
predicted and its spec hashed before the run (sha256 `c67c6db6` FW-0, `daf61535` FW-LOAD1,
`3cd493f3` FW-LOAD2, `51efea52` FW-STALE, `3a2c3ba5` FW-NP1, `bf2b3ab7` FW-NP1+M8H-4,
`d4d447df` FW-NP2, `a2d9c7fa` M8H-4, `52dcfc44` M8H-2, `18539825` M8DH-8, `2f7ade22` M8DC-2,
`27bfa38c` FW-EARLY, `e1b76aef` FW-LATE; on main's, `5f9fa1aa` B-0, `d696eb12` LOAD-1,
`9cab2a2c` LOAD-2, `2a2be258` STALE). They ran on each of the branch's three trees: on
e20d9cb (`mut/new`); rebased onto 455a88d, where #163's check joined the suite (`mut/new2`;
FW-EARLY re-predicted for that check, `f8474271`); and rebased onto 68ce7ad, #166's sleep
check with it (`mut/new3`). The rows that change `src/`, and FW-0 and FW-NP1+M8H-4, ran
every suite, four at a time; the rest the shell suite. Every mutant loaded, and every
every-suite row reported 51 suites. The table is the last run's; each value at the changed
checks was the same in all three.

| id | mutant | red, predicted and seen |
|---|---|---|
| FW-0 | none: a comment's text in the shell suite | none: 51 suites, 1,990 expected passes |
| FW-LOAD1 | LOAD-1 on this tree | none: shell green, 205 |
| FW-LOAD2 | LOAD-2 on this tree | none |
| FW-STALE | the taker holds the loop 30 ms by libuv's clock before it arms | none |
| FW-NP1 | the held-connection check's wait for a firing since the wheel emptied left out | none |
| FW-NP1+M8H-4 | that and M8H-4 | none: M8H-4 survives |
| FW-NP2 | the taker check's wait left out | shell 1: the taker check, `(satisfied satisfied iterations-exhausted #f satisfied satisfied #t #t 1)`: the stopping firing came in the 30 idle turns |
| M8H-4 | the timer not started as the drain begins (re-cut on this tree) | shell 4: the held-connection check, `(satisfied 0 satisfied iterations-exhausted iterations-exhausted () open never-forced)`; "and that drain ends", and the suite's last two handle counts |
| M8H-2 | force-close-all closes nothing (re-cut) | serve 2, shell 10, the held-connection check among them: `(satisfied 0 satisfied iterations-exhausted iterations-exhausted () open on-time)` |
| M8DH-8 | a taker's deadline starts no timer (re-cut) | shell 1: the taker check, `(satisfied satisfied iterations-exhausted #t iterations-exhausted iterations-exhausted #f #f 0)` |
| M8DC-2 | the hand-off not disarmed (re-cut) | connection-switch 1, connection-table 3, shell 1: the taker check, `(satisfied iterations-exhausted iterations-exhausted #f satisfied satisfied #t #t 1)` |
| FW-EARLY | a taker's deadline armed 20 ms early (`taker-deadline!`'s `+ ms -20`) | shell 2: the taker check, `(… #f #t 1)`: it passed before `armed` + 50; and #163's check, `(satisfied stale 280 satisfied)` |
| FW-LATE | a taker's deadline armed 20 ms late | shell 1: the taker check, `(… #t #f 1)`: firings between `armed` + 50 and the one that passed it |

- **Mismatches.**
  - FW-NP1+M8H-4 was predicted to leave M8H-4's other three shell reds. They follow from
    the held connection left open, so they went green with it (every run).
  - FW-EARLY was predicted to redden #163's check too. In the second run, four at a time,
    it did not. Run alone there, three times, it did each time, reading `(satisfied stale
    280 satisfied)`, `280` and `282` where that check wants 300 or more; in the third run,
    four at a time, `280`; in the noble image, on both trees, `280`. Under load the loop's
    time can move the 20 ms on between #163's hold and its arm. That is the margin of
    #163's check, not of these: SC-1, the mutant it is for, reads `0` there.
- **The first run's other differences.** M8DH-8 also reddened a drain check of the door
  there: "told the server drains, a taker says goodbye and closes; …" on Darwin, and "a
  taker that ignores the drain has its stream closed at the deadline, on time, …" in the
  noble image; on the rebased trees, neither. And the clients suite stopped at `build/oha`,
  not yet fetched in that worktree, in every every-suite row, FW-0 too ("cannot start
  build/oha"); once `make test` had fetched it, it ran green alone for each of the eight,
  and in the later runs.
- **FW-NP1+M8H-4 is why the held-connection check waits.** Without the wait the shutdown
  comes while the timer still runs, and a drain that never starts it again still reaches
  its deadline. A scope statement, kept to say so.
- **FW-NP2 is why the taker check waits.** Without it, the stopping firing comes in the
  idle turns that check the timer stays stopped.
- **SC-1** (chez-websocket's: `taker-deadline!` without `uv-update-time!`) is not reddened
  by the taker check: it reads `armed` as the arm left it, either way. #163's check is its
  killer.
- **On Linux** (the noble image, the shell suite, each row once, on each tree): the same
  values. LOAD-1, LOAD-2 and STALE red on main's tree and B-0 green. On this tree, FW-0,
  FW-LOAD1, FW-LOAD2 and FW-STALE green, and FW-NP2, M8H-4, M8DH-8, FW-EARLY and FW-LATE
  red at the changed checks.

### The soak of this tree

The probe of this tree printed, per run, whether the stopping firing had come before the
suite looked, and the wait's turns. Eight containers at once, 50 runs each.

| tree | runs | the held-connection check red | stopped before the look | the taker check red | stopped before the look |
|---|---|---|---|---|---|
| e43522c, before the rebases | 400 | 0 | 8, each wait met in its first turn | 0 | 0 |
| rebased onto 455a88d | 400 | 0 | 6, each wait met in its first turn | 0 | 0 |
| rebased onto 68ce7ad, as committed | 400 | 0 | 11, each wait met in its first turn | 0 | 0 |

Before the rebases the waits took 1 to 8 turns, and six runs went red elsewhere: the 20 ms
sleep check 3 times and "a MiB answer's write holds the loop less than a tick" 3. After it,
1 to 7, and three: those two once each, and once "and the connection closes once its client does, before the drain's deadline asks for anything",
`(satisfied on-time)` where it wants `never-forced`: under load the in-flight connection's
close came after the drain's 200 ms. That check runs before both changed ones, its code
unchanged. On the last tree, 1 to 7 turns, and one run went red elsewhere: "a MiB answer's write holds the loop less than a tick", `10`. The 20 ms sleep check, #166's, never did.

**The changed checks have their killers by value:** the held-connection check, M8H-4 and
M8H-2; the taker check, M8DH-8, M8DC-2, FW-EARLY and FW-LATE (and FW-NP2, its own wait).

## After M8 — a taken stream's close half-closes and lingers (2026-10-11)

Decision 0026, from chez-websocket's decision 0008 item 6 ("Server slice after the lane").
Three stacked branches by form: `docs/0026-linger-decision` (the records),
`feat/0026-linger` (the code and its checks) and `docs/0026-ledger`. Platform: Darwin
25.6.0 arm64, Chez Scheme 10.4.1, libuv 1.52.1, 2026-10-11, chez-libuv v0.8.0 for runs 1
and 2 and v0.9.0 for run 3; Linux 6.12.76 aarch64 in
`chez-libuv-noble-scratch:10.4.1` (libuv 1.48.0, a dev shim) and x86_64 in
`chez-websocket-ci-amd64:10.4.1` under emulation.

- **The code:** `src/http-server/private/shell.sls` (`taker-close!`, `drop-reads!`,
  `taker-dropped-end!`, `taker-linger!`, `taker-deadline!`, `taker-passed!`, the
  read-stop verb, the taker's `ended?` and `lingering?`) and `tests/fake-shell.sls` (its
  door's close staged the same way; `fake-shell-shut?` exported).
- **The checks:**
  - `tests/test-shell.sps`, 210: five new, a taker that fails a client still sending, a
    client that ends while the close's writes are under way, the linger's bound on time,
    the linger armed after a hold, and the verbs once lingering; eight changed, their
    client closing once it reads the stream's end (`closed-by-client`): the late write,
    the 4 MiB write, the write off the loop's thread, the deadline with the timer
    stopped, the disarm, the hold at the take-over, and the two drains that say goodbye.
  - `tests/test-connection-switch.sps`, 38: four new, the fake's close lingering, its
    linger passing or a read error closing it, a client that ended during the writes,
    and the verbs once lingering; three changed, the client's end delivered before
    reading the stream closed.
  - `tests/test-serve.sps`, 18: `dones-at-stop`'s server lingers 1 s
    (`CHEZ_HTTP_LINGER_TIMEOUT`), where its drain's close would have waited for the
    drain's 10 s.

**The oracles:** the decision's measured cells, the suite's loop clock (`uv-now`, and
`hold-until!`'s second loop for the hold), the suite's own limits (`linger-limits`: a
100 ms linger, a 10 ms tick), and RFC 6455's close frame, 1009.

### The test-first runs

Each stage's red set and values were named and hashed before its run.
- **Stage 0**, the new and changed checks on dc5f11f's `src/`: 1,992 expected passes, the
  six predicted red by value. The shell's in-suite client read the close frame and then
  `ECONNRESET`, both its read and its write: the lost close, inside the suite.
- **Stage 1**, the libuv shell: 1,995, the fake's three still red.
- **Stage 2**, the fake: 1,998, every suite green.
- **Stage 3**, the check that the linger is armed after a hold, written after a mutant of
  `uv-update-time!` in `taker-linger!` was found with no killer: red on dc5f11f's shell
  `(satisfied stale #f satisfied)`, green on the branch's, 210.

### The mutants

25 rows, the baseline and 24 mutants, against every suite, three at a time, each with a
copy of `(testing)` that prints a failure's values. Kills are read from each suite's own
log, which lists every FAIL (`compare-logs.py`).

| id | mutant | red, seen in run 2 |
|---|---|---|
| B-0 | none (a comment) | none |
| LS-1 | the old close: read-stop, and closed once the writes are out | shell 4: the failing taker's, the bound's, the hold's, the verbs' |
| LS-2 | no half-close | shell 9: the failing taker's, the bound's, the verbs', the late write, the 4 MiB write, the write off the thread, both goodbye drains, the refused write |
| LS-3 | the close reads nothing | shell 14: the failing taker's, the verbs' (the 4 MiB never read), the hold's, the ended client's, the eight changed, and the suite's two leak checks |
| LS-4 | the client's end while the stream closes ignored | shell 13: the failing taker's, the hold's, the ended client's, the eight changed, and the two leak checks |
| LS-5 | a client that has ended still half-closes and lingers | shell 8: the five flows a client's end closes (the echo, the waiting taker, the paused one, the one started twice, the capped server's next client), the ended client's, and the two leak checks; serve 1: "shut down, the server leaves nothing on the loop" |
| LS-6 | the taker's own end not remembered | none: equivalent (below) |
| LS-7 | a deadline asked for while lingering armed | shell 1: the verbs', `(… #t #f #f …)` |
| LS-8 | the linger's passing calls the taker's deadline call | shell 1: the bound's, the taker's call run and the stream left open |
| LS-9 | the linger deadline not armed | shell 2: the bound's (the taker's own deadline closed it early) and the hold's (`#f`) |
| LS-10 | the linger armed from the loop's time not brought up to date | shell 1: the hold's, `(satisfied stale 0 satisfied)` |
| LS-11 | the linger by the idle limit | shell 1: the bound's |
| LS-12 | a read-stop while the stream closes stops it | shell 1: the verbs', the client's 4 MiB never written |
| LS-13 | a half-close refused at the call does not close | shell 1: the refused write's stream never closed |
| LF-1 | the fake's old close | switch 3: the fake's lingering, its linger passing, its verbs |
| LF-2 | the fake does not shut | switch 1: the lingering check, `(#f 30000 0 handed-off)` |
| LF-3 | the fake's linger deadline not armed | switch 3: the lingering check (`1000`, the taker's), its passing (closed at 29,999), its verbs |
| LF-4 | the fake drops the client's end while the stream closes | switch 5: the lingering check, the client that ended, and the three changed |
| LF-5 | the fake ignores a read error while the stream closes | switch 1: the passing check's second stream left open |
| LF-6 | the fake arms a deadline asked for while lingering | switch 1: the verbs' |
| LF-7 | the fake's read-stop while the stream closes stops it | switch 1: the verbs' |
| LF-8 | the fake's linger passing calls the taker's deadline call | switch 1: the passing check |
| LF-9 | the fake lingers for a client that has ended | switch 3: the client that ended, and two waiting takers that close at the client's end |
| LF-10 | the fake stops reading as the stream closes | switch 1: the verbs' |
| M6-A | re-cut: `run-until-stopped!` makes no deferred call | serve 2: both `dones-at-stop` checks |

- **Run 1: 5 mismatches, four prediction errors and a weak check.**
  - LS-3, LS-4 and LS-5 also reddened the shell suite's two leak checks, "and no handle is
    left on the loop" and "nor a TCP handle, a read buffer or a write request": a stream
    left lingering is left on the loop. LS-5 reddened the serve suite's too.
  - LF-4 left late-raises green: its write's callback raises, and the raise aborts the
    stream, so it closes without the client's end. The change that delivered the end
    there was taken out, and late-raises is main's again.
  - LF-3 left the passing check green: the fake's close completes on a later turn, so a
    reading taken just after the first firing could not see an early close. The check now
    settles first, and LF-3 reddens it.
- **Run 2, re-predicted: 1 mismatch, load.** LF-10, a fake mutant, reddened the shell
  suite's "a connection held in its handler, nothing armed, the timer stopped, is closed at
  the drain's deadline, on time", its wait `iterations-exhausted`: the shell suite loads no
  fake, and its run alone was green five times of five, 210. Every other row as named.
- **Run 3, on the stack rebased onto 68f29e5** (#164 to #167; chez-libuv v0.9.0, the shim
  rebuilt): the same 25 rows and predictions, hashed again. **0 mismatches.**
- **Every mutant loaded**, and every row reported 51 suites.

**Every new or changed check has a killer by value:**
- the failing taker's: LS-1, LS-2, LS-3, LS-4;
- the client that ended during the writes: LS-3, LS-4, LS-5;
- the bound's: LS-1, LS-2, LS-8, LS-9, LS-11;
- the hold's: LS-1, LS-3, LS-4, LS-9, LS-10;
- the verbs': LS-1, LS-2, LS-3, LS-7, LS-12;
- the eight changed shell checks: LS-3 and LS-4 each, and LS-2 the five that read the
  client's end;
- the fake's lingering: LF-1, LF-2, LF-3, LF-4; its passing: LF-1, LF-3, LF-5, LF-8; its
  client that ended: LF-4, LF-9; its verbs: LF-1, LF-3, LF-6, LF-7, LF-10;
- the three changed switch checks: LF-4;
- the two `dones-at-stop` checks: M6-A.

**LS-6 is equivalent.** Read again after EOF, libuv reports EOF again: EOF leaves the
stream readable, and `uv_read_start` clears the EOF flag (1.52.1, `src/unix/stream.c`
931-938, `src/uv-common.c` 926-935). So a close asked for at the client's end that does not
remember it starts reading, reads EOF at once, and closes then: one turn later, and with a
half-close first, which a client that has ended does not read. The flag stays: it saves
the turn, and the fake keeps the same one.

**Taken out rather than left unwatched:** a half-close whose completion reports an error
closed the stream. No check could provoke one alone, since a write side that fails as it
shuts fails the reads too. It is left to the reads and to the linger deadline (the
decision's record says so).

## After M8 — the signals watched before `listening` (2026-10-11)

Plan §14's signal gap, on `fix/signals-before-listening`. `start-server` takes a `ready`
call, made once it listens and before it logs `listening`; `serve` passes
`shell-watch-signals!`. Three checks are new in the serve suite:

- **the child's**: "serve, sent SIGTERM as it logs listening, drains, as it does a moment
  later, the process exiting 0". The child, started with `sigterm-at-listening`, sends
  itself SIGTERM from inside the write of the `listening` line, so the signal lands in
  the gap on every run, with no timing to miss;
- **the default's**: "started with no ready, it watches no signal: that is serve's",
  `(shell-signals sh)` after a four-argument start;
- **the order's**: "started with a ready, it calls it once it listens, before it logs
  listening", in process: what `ready` sees, the listener open and nothing logged,
  `(listening ())`.

Every prediction was written and hashed before its run (sha256 below). Darwin arm64.

- **Test first, on main's `serve.sls`** (4e1eac2e…): the child's check red alone, by value
  `(satisfied #t () (0 sigterm))`: the child wrote `listening` and was killed, nothing
  after. Its first run tested nothing: `parameterize` is not `(rnrs)`'s, so the child did
  not load and five checks raised. The child imports it from `(chezscheme)` now; the
  second run was the one predicted.
- **The fix** (978239e4…): the serve suite 19; `make test` fifty-one suites, 2,000.
- **The default's and the order's checks** were added after: main has no `ready` to break,
  so neither was red first. SG-3 kills the default's; SG-2 and SG-5 the order's.
- **Run 1, five rows** (1d15e196…), each with the values-printing `testing.sls`, every suite
  but SG-4's (the serve suite alone), before the order's check: **1 mismatch, a prediction
  error** (below).
- **SG-5, `ready` before the bind** (e6c36068…), every suite: green, as predicted. A probe
  showed the mutant loaded: its `ready` saw no listener, `#f`, where the tree's saw it
  listening. No check held the docstring's "once it listens", so the order's check was
  added.
- **Run 2, the six rows on the serve suite** (5b4eac36…), with the order's check: **0
  mismatches**. The other suites' files did not change.

| Row | Mutant | Red, by value |
|---|---|---|
| B-0 | a comment | none; serve 21 |
| SG-1 | `serve` passes no `ready`: nothing watches | serve's SIGTERM drain `… ("handling" "holding") (0 sigterm)`; its SIGINT drain `… (255 #f)`; the child's `(satisfied #t () (0 sigterm))`; "once serve has returned …" `(satisfied satisfied () (0 sigterm))` |
| SG-2 | `ready` after the log, main's order | the child's, `(satisfied #t () (0 sigterm))`; run 2, the order's too, `(listening (listening))` |
| SG-3 | the four-argument start watches | the default's, two signal handles; **and** the clients suite's "and the listener is the one handle left, beside the timer the shell keeps", `(#t #t 4)` for `(#t #t 2)` |
| SG-4 | the child never signals itself | the child's alone, `(iterations-exhausted #t () #f)` |
| SG-5 | `ready` before the bind | run 1, none; run 2, the order's alone, `(#f ())` |

- **The mismatch.** SG-3's clients red was not predicted: that check counts the loop's
  handles after an in-process start, and the two signal handles made four. A check that
  was already there holds the default too.
- **SG-1's SIGINT value** was left unpredicted: with no handle watching, Chez's own
  keyboard interrupt ended the child with status 255.
- **Every mutant loaded**: run 1's 204 logs for the four all-suite rows, 51 each, SG-5's 51,
  and run 2's six; none with `Exception` or `HARNESS`.

**Every new check has a killer by value:** the child's, SG-1, SG-2 and SG-4; the default's,
SG-3; the order's, SG-2 and SG-5.

## After M8 — a taken stream's close gives each write it waits for the write timeout (2026-10-11)

Decision 0027, on `feat/taker-close-write-timeout`, by the owner's form ("Write timeout
after close"). Once `transport-close!` has been asked for, each write the close waits for
has `write-timeout-ms`, from the close and again at each write's end, and the stream is
aborted past it. The taker keeps two instants, its own deadline and the bound, and the
stream's one wheel entry is armed at the earlier. Five checks are new in the shell suite,
on a shell whose write timeout is 300 ms, each client reading nothing of a 4 MiB write
(the server's send buffer 4 KiB):

- **C1, the bound alone:** a taker arming no deadline is aborted at the write timeout from
  the close, its write told `ECANCELED`, its close call once, nothing logged.
- **C2, each write:** /door-rearm's client reads from 150 ms after the close until the
  first write is out, then stops. The 16 MiB second write is aborted 300 ms after the
  first's end, not the close.
- **C3, the taker's own deadline first:** at 100 ms its call, which does not abort, runs
  once, and the bound still aborts the stream at 300.
- **C4, the taker's own deadline later:** at 600 ms, the bound aborts the stream at 300,
  and the taker's call never runs.
- **C5, a held loop:** a taker that holds the loop 300 ms, then closes behind a write, has
  its bound armed after the hold, at the loop's time brought up to date, and met.

Every prediction was written and hashed before its run. Darwin arm64.

- **Test first, on #174's shell** (d81b414d…): C1 to C4 red alone, by value:
  - C1 `(iterations-exhausted () () () #f)`;
  - C2 `(iterations-exhausted ((1 #f)) () #t #f)`;
  - C3 `(iterations-exhausted () () #f 1 #t)`;
  - C4 `(satisfied ((1 ECANCELED)) (()) #f (609))`.

  Its first run raised in C2's setup. The check read a write's time with `cadddr`, where
  `took-of` drops the tag and leaves three fields, so it tested nothing past C1. It was
  fixed to `caddr`, and the second run was the one predicted.
- **The bound** (de626370…): the shell suite was red in C2 in two of five runs,
  `(satisfied ((1 ECANCELED) (2 ECANCELED)) (()) #t #f)`. That was the check, not the
  shell. Through a 4 KiB send buffer, the client needed more than the 150 ms left to read
  the first 4 MiB, so the bound passed first. Once the client starts reading, the
  server's send buffer is now 1 MiB. Then 5 of 5 green, and 20 of 20 in a row.
- **C5** was added after, since no check held the bound's `uv-update-time!`. CB-7 is its
  killer.
- **Eight rows over every suite** (a3b41d44…), each with the values-printing
  `testing.sls`: **0 mismatches.**

| Row | Mutant | Red in the shell suite, by value (every other suite green) |
|---|---|---|
| B-0 | a comment | none |
| CB-1 | the close arms no bound | C1 `(iterations-exhausted () () () #f)`; C3 `(iterations-exhausted () () #f 1 #t)`; C4 `(… #f (602))`; C5 `(satisfied stale #f iterations-exhausted)` |
| CB-2 | a write's end arms the bound no more | C2 `(satisfied ((1 #f) (2 ECANCELED)) (()) #t #f)` |
| CB-3 | a passed bound does not abort | C1; C2; C3 `(… #f 429 #t)`, its call made at every tick; C4 `(… #t (308))`; C5 `(… iterations-exhausted)` |
| CB-4 | the entry armed at the later of the two | C3 `(… #t 0 #f)`; C4 `(… #f ())`; and the 0024 check "a close waiting on a write the client reads nothing of: a deadline asked for then passes …", its waits `iterations-exhausted` |
| CB-5 | the taker's own deadline replaces the bound | C3 `(iterations-exhausted () () #f 1 #t)`; C4 `(… #f (605))` |
| CB-6 | the taker's call arms nothing again | C3 `(iterations-exhausted () () #f 1 #t)` |
| CB-7 | the bound from the loop's stale time | C5 `(satisfied stale 0 satisfied)` |

- **Every mutant loaded:** 408 logs, 51 for each row, none with `Exception` or `HARNESS`.

**Every new check has a killer by value:** C1, CB-1 and CB-3; C2, CB-2 and CB-3; C3,
CB-1, CB-3, CB-4, CB-5 and CB-6; C4, CB-1, CB-3, CB-4 and CB-5; C5, CB-1, CB-3 and CB-7.
