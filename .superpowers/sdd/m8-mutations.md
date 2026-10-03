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

