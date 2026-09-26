# M4 — mutation log

Every test in M4 is watched to fail: a single named mutation breaks the
asserted property, the suite goes red, and the mutation is reverted. Recorded
per global-constraints ("a test is finished when it has been watched to fail").
The milestone plan §8 names one mutation per slice; the extras below each
witness a property the slice's suite asserts beside it.

Platform: Darwin arm64, Chez Scheme 10.4.1 (`tarm64osx`), libuv 1.52.1, 2026-09-26.
Library path as in M3, and chez-libuv's `tests/` last, for `(uv-testing)`
(`src:tests:vendor/chez-libuv/src:vendor/chez-httparse/src:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs:vendor/chez-httparse/test/support/harness:vendor/chez-libuv/tests`).
Each mutant ran from a scratch copy of the mutated file, placed first on the
library path under an absolute root; the substitution had to match exactly
once, and the tree was never edited. A gate's mutants ran the make target
from a scratch copy of `src/`.

## M4.1 — a connection's parser shares one binding list (2026-09-26)

The adapter, `(http-server private adapter)`, came in M2.2, so the property
held before its check: a connection's parser costs what byte-machine's
`make-parser` costs on a binding list made once, 1,056 B each. The check was
watched to fail by the plan's mutation, against every suite.

| # | mutation (`src/http-server/private/adapter.sls`) | observed |
|---|---|---|
| M4.1-A | the plan's: the binding list is built per connection (`make-conn-parser` calls a `make-adapter-bindings`) | connection-allocation 1 — "a connection's parser costs what one on a binding list made once does": 2,640 B against 1,056 B, so a list per connection costs 1,584 B more. Design §7.5 measured 1,216 B for a plain list (2026-09-19); the adapter's bindings are closures. Every other suite green |

## M4.2, first step — the shell serves a connection (2026-09-26)

Red before green: `tests/test-shell.sps` ran before `(http-server private
shell)` existed and stopped at load, exit 255, "library (http-server private
shell) not found". Only the shell suite imports the shell, so its mutants ran
against that suite alone. The first run of all of them read "library
(uv-testing) not found" and tested nothing: the runner's path had no
chez-libuv `tests/`. They ran again with it.

A code review before the first commit found fourteen things, all fixed on the
owner's word; its record is with the second step. The runs below are on this
step's tree alone: a scratch worktree cut from main at 76d5a13, the submodules
and `build/` linked from the checkout, the mutation runner pointed at it.
There, every suite is green: twenty-nine, 736 expected passes, shell 27.

| # | mutation (`src/http-server/private/shell.sls`) | observed |
|---|---|---|
| M4.2-H | design §6.4's: the adapter's queue drains inside the parser callback (`(enqueue! c actions) (drain! c)`) | shell 4 — "no action ran but from the outermost drain", and with it the three requests in one write: "a client reads three whole responses" and "... answered in order". The handler ran and the write was issued inside the feed, before its result could keep the rest of the delivery, so the second and third requests were never read. Also "nothing holds the response's body": the violations record keeps each action run out of place, the write's segments included |
| M4.2-R | M3.3's, carried: the write's completion keeps its segments (`write-done` takes them, and reads them) | shell 1 — "and nothing holds the response's body". The write was outstanding when the collection ran (checked first, by chez-libuv's write-queue gauge) |
| M4.2-S | the half-close not performed: `shutdown` reports `shutdown-completed` without `uv-shutdown!` | shell 3 — "the client reads the stream's end", the raising handler's "... reads the stream's end" after its 500, and the four-MiB response's "... and the stream's end": each response arrived whole, but no client read the end |
| M4.2-L | no reading on while the connection lingers (`read-start!` skipped in `lingering`) | shell 5 — "when the client closes, the connection closes and leaves the table" and "its verbs ran in order", and the end's three: every connection, no handle left, the counters. A lingering connection that reads nothing never sees its client close |
| M4.2-T | the close's callback leaves the connection in the table | shell 2 — "when the client closes, the connection closes and leaves the table", and the end's "every connection closes and leaves the table" |
| M4.2-D | the Date line one second off the clock | shell 1 — "its Date is the shell's clock's second" |
| M4.2-K | review: the clock read for every response | shell 1 — "three responses read the clock fewer than three times" |
| M4.2-G | review: a handler's raise is not logged | shell 1 — "and the shell logged what the handler raised" |

The export check, against every suite:

| # | mutation | observed |
|---|---|---|
| M4.2-E | `(http-server span)` exports a `uv-span` | exports 1 — "none of them exports a uv- name". Every other suite green |

The plan's Mutation B is the close-ownership gate's. Each ran `make
check-close-ownership` from a scratch copy of this step's `src/`:

| # | mutation | observed |
|---|---|---|
| M4.2-B1 | the plan's: a second `uv-close!` call, in `read-stop!`, for a handle no longer open | the gate exits 1, naming `shell.sls:254: read-stop!` and `shell.sls:276: connection-close!`. The shell suite stays green with it, 27 passes, since no handle it stops is ever closed: the gate is the test here |
| M4.2-B2 | `connection-close!` closes twice | the gate exits 1, naming both calls in `connection-close!` |
| M4.2-B3 | the one call moved into a helper, `close-handle!`, that `connection-close!` calls | the gate exits 1, naming `close-handle!` |
| M4.2-B4 | review: `(define close-now uv-close!)`, called in `read-stop!` | the gate exits 1, naming `close-now`. Before the review the gate matched only `(uv-close!` and passed this |
| M4.2-B5 | review: `(apply uv-close! ...)` in `read-stop!` | the gate exits 1, naming `read-stop!`. Before the review it passed |
| calibration | a commented-out `;; (uv-close! ...)` line added | the gate passes: it reads the code, not the comments |
| calibration | a definition named `times-uv-close!-ran` added | the gate passes: it matches the name alone |
| calibration | review: ripgrep not on `PATH` | the gate exits 2, "needs ripgrep (rg) on PATH". Before the review, awk given no files read standard input |

One survives, and is a scope statement:

| # | mutation | observed, and why no test |
|---|---|---|
| M4.2-N | review: Nagle's algorithm left on | shell green, 27. chez-libuv has no getter for `TCP_NODELAY`, and its effect is time on a link with a round trip. On loopback no stall shows either way, on Darwin or Linux (`research/spike/m4-nodelay.*`) |

## M4.2, second step — what fails (2026-09-26)

The runs below are on the finished tree: twenty-nine suites, 757 expected
passes, shell 48.

The run loop's guard. The plan's Mutation A expected "a raised
`&byte-machine-contract` to escape uncaught" once the guard was narrowed to
`error?`. That premise does not hold for a callback's raise: chez-libuv raises
it again from `uv-run` composed with `&uv-callback-error`
(`vendor/chez-libuv/src/libuv/loop.sls:39-45`), an `&error`, so `error?`
catches it. What keeps a poisoned parser fatal is the contract arm's place
before the callback-error arm. The mutation still fails the check, by another
path: the condition is caught, logged as a callback error, and the loop runs
on.

| # | mutation (`shell-run!`'s guard) | observed |
|---|---|---|
| M4.2-A | the plan's: one `error?` arm, logging and running on, in place of the two | shell 3 — "the run loop raises a contract condition again" (it ran on), "having logged the contract violation first" (it logged `callback-error`), and "and raises it again when the log raises" |
| M4.2-A2 | the two arms, callback-error first | shell 3 — the same three |

The review's fixes in this step. Each fix's check was watched to fail against
the code as it was before the fix, which is what each mutation puts back.

| # | mutation (`src/http-server/private/shell.sls`) | observed |
|---|---|---|
| M4.2-X | a raise from the outermost dispatch goes on without closing the connection | shell 5 — "when a connection's callback raises, its client reads the stream's end", "with no response, the connection closed and gone, the error logged", and the end's three, since the connection never closes |
| M4.2-J | a failed adoption is not closed | shell 4 — "when a connection cannot be adopted, its client reads the stream's end", "and the connection is closed and gone", and the end's live handles and counters |
| M4.2-C | `reconcile!` drops nothing | shell 2 — "until the run loop reconciles the table with the loop, and logs it", and the end's "every connection closes and leaves the table" |
| M4.2-Q | the run loop logs a contract violation with the log itself, not quietly | shell 1 — "and raises it again when the log raises" |
| M4.2-W1 | a failed write settled before its read error | shell 2 — the two "as a read error, then settled" checks: the completion's failure and the call's |
| M4.2-W2 | a write's completion reads its error as success | shell 1 — "as a read error, then settled, with no half-close". The connection still closed: its client had gone |
| M4.2-W3 | a write refused at the call is not caught | shell 2 — "a write refused when it is issued closes the connection" and its order check. libuv 1.52.1 refuses a write after `uv_shutdown` at the call, with EPIPE (measured first, 2026-09-26); a libuv that took the write and failed it at the completion would pass the check through the other path |

One survives, and is a scope statement:

| # | mutation | observed, and why no test |
|---|---|---|
| M4.2-F1 | a shutdown's failed completion reported as `shutdown-completed` | shell green, 48. `shutdown(2)` fails only if the client resets in the one poll between the write's completion and the shutdown, which a test on one loop cannot order. A lingering connection reads, so a reset still closes it through the read's error |

Found while running them: M4.2-T first also turned the run loop's "and logs
it first" red, which read the newest log entry, and the reconciliation's own
entries come after the contract violation's. The log checks now clear the log
before the raise and read its oldest entry.

The first step's mutants, again on the finished tree, turn the same checks
red as on the first step's tree, but for these:

| # | observed here |
|---|---|
| M4.2-T | shell 3 — "when the client closes, the connection closes and leaves the table", and the two failed writes' "... closes the connection", which ask the same. The end's "every connection closes and leaves the table" held: the run loop's reconciliation dropped the entries whose handles had closed |
| M4.2-B1 | put where the suites never run it, in `reconcile!`, closing a stale connection's handle: the gate exits 1, naming `shell.sls:321: connection-close!` and `shell.sls:386: reconcile!`; the shell suite stays green, 48 |

`make test` was green afterwards: twenty-nine suites, 757 expected passes
(connection-allocation 19, shell 48, exports 2), exit 0.

## M4.3, first step — the two limits, `limits-with`, and `server-step` (2026-09-26)

Red before green: `tests/test-limits.sps` stopped at load at its first new
name (unbound identifier), then, once `limits-with` existed, failed the
backlog's bound alone (36 passes, 1 failure) until the bound existed;
`tests/test-server.sps` stopped at load against the step before the review's
rework (`server-refused` unbound, exit 255). These mutants ran on the first
step's own tree, a scratch worktree cut from main at 100ae8b, and again on the
finished tree, with the same result; the plan's ran against every suite.

| # | mutation (`src/http-server/limits.sls`) | observed |
|---|---|---|
| M4.3-L1 | max-connections' default moved to 10,001 in `default-limits` alone | limits 2 — "max connections 10 000", and the drift guard, "empty env == default-limits, field by field" |
| M4.3-L2 | the backlog's default moved to 512 in `limits-from-environment` alone | limits 1 — the drift guard alone |
| M4.3-L2b | the backlog's default moved to 512 in `default-limits` alone | limits 2 — "listen backlog 511", and the drift guard |
| M4.3-L3 | max-connections read from a misspelled variable | limits 2 — "max connections overridden", and "no connections, or no backlog, is refused", whose 0 was then never read |
| M4.3-L3b | the backlog read from a misspelled variable | limits 3 — "backlog overridden", the bound's check, and "no connections, or no backlog, is refused" |
| M4.3-L4 | a backlog of 0 accepted | limits 1 — "no connections, or no backlog, is refused" |
| M4.3-L5 | `CHEZ_HTTP_BACKLOG` left out of `limits-environment-variables` | limits 1 — "the environment variables, one per field" |
| M4.3-L6 | no upper bound on the backlog | limits 1 — "a backlog is at most a C int's largest: 2147483647 is accepted, one more refused" |
| M4.3-L7 | the bound one short, `<` for `<=` | limits 1 — the same check |
| M4.3-W1 | `limits-with` takes a name that is not a field | limits 1 — "a name that is not a field is refused" |
| M4.3-W2 | `limits-with` reads each field one place off | limits 1 — "limits-with replaces each field alone, by name" |
| M4.3-W3 | `limits-with` applies the first override alone | limits 1 — "and several at once" |

| # | mutation (`src/http-server/server.sls`) | observed |
|---|---|---|
| M4.3-A | the plan's: a connection over the cap accepted anyway | server 5 — the three refusal rows ("an arrival with the cap open is refused, and the first refusal logged", "a refusal after the first is counted, not logged", "the cap is the limits': by default 10 000 open are refused"), the episode, and "the step answers with the state it was given, updated". Every other suite green |
| M4.3-B | the cap off by one, `<=` for `<` | server 5 — the same five |
| M4.3-C | an episode's first refusal not logged | server 3 — the first-refusal row, the default cap's, and the episode |
| M4.3-D | every refusal logged, nginx's way | server 2 — "a refusal after the first is counted, not logged", and the episode |
| M4.3-E | an episode's count not logged at the next accept | server 2 — "an arrival once a place is free is accepted, and the refusals logged with their count", and the episode |
| M4.3-F | a shutdown that does not stop listening | server 2 — "a shutdown stops listening", and "a shutdown during refusals logs their count" |
| M4.3-G | a stop that does not log the episode's count | server 2 — the shutdown's and the failed listener's count rows |
| M4.3-H | an arrival answered with a copy of the state | server 1 — "the step answers with the state it was given, updated" |
| M4.3-I | a second stop closes the listener again | server 2 — "a second shutdown asks for nothing", and "a listener failure while draining asks for nothing" |
| M4.3-J | a failed listener logged only | server 3 — its three rows |
| M4.3-K | a tick that asks to force every connection closed | server 2 — the two tick rows |
| M4.3-M | an arrival below the cap refused | server 5 — "an arrival with fewer open than the cap is accepted", "so is one that takes the last place", "and 9 999 open are not", the count row, and the episode |
| M4.3-M2 | the last place never taken | server 4 — "so is one that takes the last place", "and 9 999 open are not", the count row, and the episode |
| M4.3-M4 | an arrival while draining refused and logged | server 1 — "an arrival while draining is refused, and not logged" |
| M4.3-M5 | a close that asks for a log | server 2 — the two close rows |
| M4.3-V | an event outside the vocabulary answered with nothing | server 1 — "an event outside the vocabulary, or an arrival without a count, is a caller bug" |
| M4.3-V2 | an arrival's count not checked | server 1 — the same check |
| M4.3-V3 | `listener-failed` left out of the vocabulary | server 2 — the events' list, and "the samples name every event, in order" |
| M4.3-V4 | `force-close-all` left out of the vocabulary | server 1 — the actions' list |
| M4.3-V5 | `draining` left out of the phases | server 8 — the phases' list, and every check that starts a server draining |
| M4.3-P | a state in any phase accepted | server 1 — "a state in no phase, with negative refusals, no limits, or no cap is refused" |
| M4.3-P2 | a state with no connection cap accepted | server 1 — the same check |
| M4.3-X | a vocabulary event the step does not take | server 4 — "every event is one the step takes, listening or draining", the two tick rows, and "no row asks for an action outside the vocabulary", which the step's raise stopped |
| M4.3-Y | a stop that asks for an action outside the vocabulary | server 3 — "no row asks for an action outside the vocabulary", and the two shutdown rows |

