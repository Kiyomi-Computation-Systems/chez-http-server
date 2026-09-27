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
| M4.3-A | the plan's: a connection over the cap accepted anyway | server 5 — the three refusal rows ("an arrival with the cap open is refused, and the first refusal logged", "a refusal after the first is counted, not logged", "the cap is the limits': by default 10 000 open are refused"), the episode, and "the step answers with the state it was given, updated". On the finished tree, shell 3 as well (below). Every other suite green |
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

## M4.3, second step — the shell's listener, and one closer (2026-09-26)

Red before green: the shell suite with the listener's checks stopped at load
against the first step's shell (`shell-server` unbound, exit 255), and
`tests/test-close-ownership.sps` failed on a copy of the tree whose shell had
three `uv-close!` owners, its fixtures green (11 passes, 1 failure). These
mutants ran on the finished tree.

| # | mutation (`src/http-server/private/shell.sls`) | observed |
|---|---|---|
| M4.3-S1 | a close's callback leaves the connection in the table | shell 6 — "when the client closes, the connection closes and leaves the table", the two failed writes' "... closes the connection", "when the client served closes, its place is free", "and the next client is served" (refused: the table still counted the first), and "and the refusals are logged with their count" |
| M4.3-S2 | `reconcile!` drops nothing | shell 2 — "until the run loop reconciles the table with the loop, logs it, and runs on", and "every connection closes and leaves the table" |
| M4.3-S3 | a refused handle left open | shell 3 — "two clients over max-connections each read the stream's end, having read nothing", and the end's live handles and counters |
| M4.3-S4 | the listener listens with 511, not the limits' backlog | shell 3 — "a listener with the limits' backlog of -1 cannot listen, and is closed", and the end's two |
| M4.3-S5 | a listener that cannot listen left open | shell 5 — the backlog's check, "a listener on a port in use cannot listen, and is closed", "and the shell may listen again", and the end's two |
| M4.3-S6 | `close-listener` not performed | shell 3 — "a shutdown closes the listener the clients used, and the server drains", and the end's two |
| M4.3-S7 | a shell that listens on a second listener | shell 4 — "and listens on one listener at a time", the shutdown's check (the second listener took the field, so the shutdown closed it and left the first open), and the end's two |
| M4.3-S7b | a shell that listens after its server has stopped | shell 3 — "and a server that has stopped listening never listens again", and the end's two |
| M4.3-S7c | the review's C1b: any listener made refuses the next, closed or not | shell 1 — "and the shell may listen again" |
| M4.3-S8 | `shell-adopt!` serves a refused connection | shell 2 — the two over-cap checks |
| M4.3-S9 | the review's C3: a raise before serving leaves the handle open | shell 5 — "when a connection cannot be adopted, its client reads the stream's end", "and the connection is closed and gone, the error logged", "when the server's step raises on an arrival, its client reads the stream's end", and the end's two |
| M4.3-S12 | the answer's log not run | shell 2 — "the first refusal is logged, the second is not, and one connection is open", and "and the refusals are logged with their count" |
| M4.3-S13 | the table counted as empty on every arrival | shell 3 — the over-cap checks and the count's log |
| M4.3-S14 | a raise closes the handle and is dropped | shell 3 — "with no response, the connection closed and gone, the error logged", and the two failed listeners' checks |
| M4.3-S15 | the listener takes a connection and does not offer it | shell exit 2 — "the server's own listener serves a client", then the suite's body raised before finishing |
| M4.3-S16 | a raise in the arrival's step answered by serving anyway | shell 2 — "when the server's step raises on an arrival, its client reads the stream's end", and "with nothing read, no connection served, and the error logged" |
| M4.3-A | the plan's, on the finished tree, against every suite | server 5, as above, and shell 3 — the two over-cap checks and "and the refusals are logged with their count". Every other suite green |

The check that one procedure closes every handle, and its reader:

| # | mutation | observed |
|---|---|---|
| M4.3-G1 | a second caller: `reconcile!` closes a stale connection's handle itself | close-ownership 1 — "src/ uses uv-close! once, in handle-close!" |
| M4.3-G2 | `handle-close!` closes twice, on one line | close-ownership 1 — the same |
| M4.3-G3 | an alias, `(shut uv-close!)`, bound in `serve!` | close-ownership 1 — the same |
| M4.3-G4 | a close after a `;` in a string | close-ownership 1 — the same. The awk scan it replaces passed this |
| M4.3-G5 | two uses one character apart, `(list uv-close! uv-close!)` | close-ownership 1 — the same. The awk scan counted one |
| M4.3-WA | the walker keeps a form's first use alone (in the suite's walker) | close-ownership 2 — "two calls on one line", "two uses one character apart" |
| M4.3-WB | the walker names every use by its outermost definition | close-ownership 1 — "a call in a definition inside another" |
| M4.3-WD | the walker names every use top-level | close-ownership 9 — every fixture with a definition |
| M4.3-WF | the walker sees calls alone | close-ownership 1 — "two uses one character apart" |
| M4.3-WG | a string naming `uv-close!` counted as a use | close-ownership 1 — "a string naming it is not a use" |
| M4.3-WH | the walker skips import clauses | close-ownership 1 — "a rename in an import" |

The G mutants ran the suite from a scratch copy of `src/`, which it reads from
its working directory; the walker's ran the suite edited.

Two survive, and are scope statements, as is one fixture:

| # | mutation | observed, and why no test |
|---|---|---|
| M4.3-S10 | an arrival answered with neither `accept` nor `refuse` runs on | shell green, 62. The shell's assertion answers a bug in the step, and the step's rows pin its answer to every arrival, so no check can provoke it |
| M4.3-S11 | `server-run!` drops an action it cannot perform | shell green, 62. Likewise: no row asks the shell for one. It was silent before the review (C12) |
| — | "comments are not uses" | a pin on Chez's reader, which drops comments and datum comments; no mutation of ours can turn it red, as with the flag pins |

Found by the review in the first build's records, and corrected here: its
M4.3-S7 said the second listener was never closed, where the first was, and its
shutdown check read the shell's listener field, so it passed under that
mutant; the check now reads the listener the clients used. Its M4.3-G2 said the
awk scan now named each call; two uses one character apart still counted as
one, and a `;` in a string hid a call. That scan is gone.

`make test` afterwards: see the ledger's M4.3 entry.

## M4.4, first step — the socket lane's upload past a refusal (2026-09-26)

The upload check passed at once, against M4.2's staged close, so its red is
its mutants'. The ticker's check, which the review added (ledger, M4.4), was red
first: the ticker the wait left also reddened the suite's last "no handle is
left on the loop". Every mutant ran on the finished tree, and U, U3 and K
again in a scratch worktree with only this step, where each turned the same
checks of the shell suite red.

| # | mutation | observed |
|---|---|---|
| M4.4-U | a close at once: the libuv shell performs the half-close as a close (`shell.sls`) | shell 5 — "a client that uploads four MiB past a refusal sends all of it" (the send fails with EPIPE, three runs of three), "and then reads the refusal, a 400, and the stream's end" (the 400 is read, then ECONNRESET), and the linger's three; contract 10 — the read and trace checks of the five scripts that close in stages. Every other suite green |
| M4.4-U3 | no reading while lingering: a read-start skipped when the connection lingers (`shell.sls`) | shell 7 — the upload's two (its send never finishes), the linger's two once the client closes, and the end's three, since a lingering connection that does not read never closes until M5's deadline; contract 6 — the read checks of the five scripts that close in stages (the client's end is never read) and the end's check. Every other suite green |
| M4.4-K | `run-shell-until` leaves its ticker when the run loop raises, as before the review (`tests/shell-testing.sls`) | shell 2 — "a wait the run loop's raise ends leaves no handle of its own on the loop", and "and no handle is left on the loop". Every other suite green |
| M4.4-Q | a probe, not a mutation of the code: the upload's client connects to port 1, where nothing listens (the suite) | shell 2 — the upload's two, and the suite runs on to its end, 63 passes. Before the review's fix it stopped there, a harness error after 13 passes |

U3 found a flaw in the upload check first: a send the suite's own close cut
short started a read on a closing handle, and the raise surfaced in the next
block's wait, reddening the three checks of the handler that raises with it.
The client now reads only while its handle is open.

## M4.4, second step — the contract test (2026-09-26)

Red before green: the fake shell's two checks ran before it had a trace or
handed over a later turn's events one at a time. `tests/test-fake-shell.sps`
raised at the five-argument `make-fake-shell` (a harness error, after 15
passes), and `tests/test-message-loop.sps` stopped at load
(`fake-shell-deliver-later!` unbound). The script whose handler raises a
condition with no message, which the review added, was red first: its trace
check failed at the handler's answer, the two conditions alike and distinct.
The rest of the contract suite was written against shells that already agree,
so its red is its mutants'. All ran on the finished tree.

| # | mutation | observed |
|---|---|---|
| M4.4-A | the plan's: the libuv shell's write path sends the Date line's space after the colon as a tab (`shell.sls`, `write!`) | contract 9 — every script's "the client read the bytes the fake shell wrote", each naming the byte, `(differs-at i 32 9)`: 32 in the fake's bytes, 9 in the libuv shell's, at byte 22 after a 200's status line, 31 after a 400's and 41 after a 500's. The socket lane green, 65: llhttp strips a tab there as it strips a space, so the Date reads the same. Every other suite green |
| M4.4-T | the libuv shell reports its half-close's completion twice (`shutdown!`) | contract 5 — the trace checks of the five scripts that close in stages, each at the second `(shutdown-completed)`, index 18 (13 for the refusal). The core ignores it, so the wire and the socket lane stay green. Every other suite green |
| M4.4-T2 | the libuv shell traces an action after performing it (`run!`) | contract 9 — every script's trace check, at index 1, where the feed's result comes before the feed. Every other suite green |
| M4.4-R | the libuv shell's read path drops each delivery's last byte (`serve!`'s on-data) | contract 9 — every script's "the libuv shell read what the client sent, then its end alone, and closed", `(wrong-length n)`; its wire and trace checks green, since the fake is given the same short stream. So the read check is what closes the replay's gap. The socket lane 28; every other suite green |
| M4.4-X | the libuv shell reports a read error after the client's end (`serve!`'s on-eof) | contract 9 — every script's read check, naming `(eof read-error)`. The replay hands the fake the same read error, so the wire and trace checks stay green, and so does every other suite: before the review, when the read check counted the client's end alone, this mutant left the contract green |
| M4.4-E | a shutdown leaves the listener open (`server-run!`) | contract 1 — "at the end, no connection is left, and no handle on the loop"; shell 3, as M4.3-S6. Every other suite green |
| M4.4-N | the rendering compares a condition by its message alone, and any other record by identity, as before the review (the suite) | contract 1 — "a handler that raises a condition with no message: the two shells' traces are identical", at index 10, the handler's answer. Every other suite green |
| M4.4-P | `shell-listen!` reports port 1, where nothing listens (`shell.sls`; the contract suite alone) | contract 9 — every script's read check, naming `(not-connected satisfied ECONNREFUSED)`; the suite runs on. Before the review's fix it stopped at the first script, a harness error |
| M4.4-P2 | `shell-listen!` reports its port plus one, on macOS the client's own (the contract suite alone) | contract 9 — the first script's connect refused at the call, `EINVAL`, and the rest `ECONNREFUSED`, each named; the suite runs on |
| M4.4-F1 | the fake shell traces an action after performing it (`tests/fake-shell.sls`) | fake-shell 1 — "a trace sees each event as it is dispatched, and each action before it is performed"; contract 9, every trace check. Every other suite green |
| M4.4-F2 | the fake shell traces only the events dispatched outside a drain | fake-shell 1 and contract 9, the same |
| M4.4-F3 | the fake shell delivers the newest later event, not the oldest | message-loop 1 — "a later turn's events are delivered one at a time, oldest first, then none". Every other suite green |
| M4.4-F4 | the fake shell delivers every later event when asked for one | message-loop 1, the same |

F3 and F4 survive in the contract suite, a scope statement: at no completion
in its nine scripts does the fake have two waiting. libuv 1.52.1 runs a
write's completion in the loop's pending phase, and in the same call shuts the
socket for the half-close the core asks for there and runs its callback,
before the poll that reads (`src/unix/stream.c:733-735, 1232-1238, 625-660`).
The replay delivers each completion where the libuv shell received its own
regardless, and the message loop's check holds the order.

`make test` afterwards: see the ledger's M4.4 entry.

## M4.5, first step — what a handler sees (2026-09-27)

Red before green: `tests/test-view.sps` ran first against a stub
`(http-server view)` whose four accessors answered `'stub`, and all twelve
checks failed (status 1). Every mutant ran on the finished tree. The view is
imported by its suite alone, so its mutants ran against that suite and the
exports suite. M4.5-A and M4.5-Q, whose `target-form` the judge shares, ran
against every suite.

| # | mutation | observed |
|---|---|---|
| M4.5-A | the plan's: an absolute-form request's host read from its Host field (`request-host`) | view 1 — "absolute-form: the host is the target's authority, whatever Host says". Every other suite green, 32 |
| M4.5-B | the path is the whole origin-form target, its query too (`request-path`) | view 2 — "origin-form: the path up to the first ?, as sent, and the query after it", and "origin-form with no ?: no query; ending in ?: an empty one" |
| M4.5-C | the query follows the last "?", not the first (`request-query`) | view 1 — "origin-form: the path up to the first ?, ...", whose query holds a second "?" |
| M4.5-D | a target with no "?" reads an empty query, not #f | view 4 — the no-"?" check, the empty path's, asterisk-form's and authority-form's, each expecting no query |
| M4.5-E | a target ending in "?" reads no query, not an empty one | view 1 — "origin-form with no ?: no query; ending in ?: an empty one" |
| M4.5-F | an absolute-form path is split as origin-form's (`request-path`) | view 2 — "absolute-form: the path and the query are the URI's", and "absolute-form with an empty path: the path reads /" |
| M4.5-G | an empty absolute-form path reads empty, not "/" | view 1 — "absolute-form with an empty path: the path reads /" |
| M4.5-H | asterisk-form's path reads empty, not "*" | view 1 — "asterisk-form: the path is *, with no query, and the host is Host's" |
| M4.5-I | authority-form's path is its target | view 1 — "authority-form: no path, no query, and the host is Host's" |
| M4.5-J | authority-form's host is its target, RFC 9112 §3.3's authority, not the Host field's (`request-host`) | view 1 — the authority-form check. Decision 0012 reads the Host field for every form but absolute-form, and the check holds that letter |
| M4.5-K | the Host field's value is not read: every host but absolute-form's reads empty | view 3 — asterisk-form's, authority-form's, and "origin-form: the host is the Host field's value" |
| M4.5-L | a request with no Host reads #f, not empty | view 1 — "an empty Host reads empty, and so does a request with none" |
| M4.5-M | a header by name reads the last field of that name, not the first (`request-header`) | view 1 — "a header by name, in any case: the first field's value, or none" |
| M4.5-N | a header's name is matched with its case | view 3 — the by-name check, and the two value checks, which ask in lower case for names sent capitalized |
| M4.5-O | a value keeps the whitespace after it (`field-value`) | view 2 — "a value without the whitespace after it", and "the host is the Host field's value without the whitespace after it" |
| M4.5-O2 | the host is the Host field's value with the whitespace after it (`request-host`) | view 1 — "the host is the Host field's value without the whitespace after it". Every other suite green, 33 |
| M4.5-P | strings are UTF-8 decoded, not a character per byte (`latin-1`) | view 1 — "a value is a character per byte, whatever the byte": the lone 0xE9 decodes to U+FFFD |
| M4.5-Q | `target-form` loses its CONNECT arm (`target.sls`), the rule the judge and the view share | target 5 — the CONNECT rows; trace lane 1, two CONNECT traces refused as `invalid-target`; view 1 — the authority-form check. Every other suite green |

The host's row was added after the Host fix (PR #54) asked what a handler reads
of a value with whitespace after it. Before the row, O2 had no check to redden:
the core answers `Host: h ` 400 until #54's judge trims, so the row builds its
request by hand. Each of the view's thirteen checks is reddened by at least one
mutant above.

## M4.5, second step — the facade (2026-09-27)

Red before green: the limits suite's three address rows failed against a stub
`address-from-environment` answering "stub" and -1, and the serve suite's
eight behavior rows against a stub `(http-server private serve)` that listened
on 127.0.0.1:0 with default-limits, logged nothing, and whose `serve`
returned at once. The exports row passed against it, since the facade's list
was already the one written; its red is Z's. Every mutant ran against every
suite, on the finished tree.

| # | mutation | observed |
|---|---|---|
| M4.5-R | the default host is 0.0.0.0, every interface (`address-from-environment`) | limits 2 — the defaults row and the "each alone" row, whose port-only case reads the default host; serve 1 — "it listens where the environment says, and logs where" |
| M4.5-S | the default port is 80 | limits 2 — the defaults row, and the "each alone" row's host-only case |
| M4.5-T | a port has no upper bound | limits 1 — "a port that is not a whole number from 0 to 65535 is refused" |
| M4.5-U | CHEZ_HTTP_HOST is not read | limits 1 — the "each alone" row; serve 1 — the host row: the start listens on 127.0.0.1 |
| M4.5-V | a malformed setting is raised as the pure parser raised it, not as a config error (`settings`) | serve 1 — "a malformed setting raises an &http-server-config-error naming it, from serve" |
| M4.5-W | a host the bind refuses is raised as chez-libuv raised it (`start-server`) | serve 1 — "a host that is no IP literal is refused by the bind, as a config error naming CHEZ_HTTP_HOST, and nothing is left open" |
| M4.5-X | the start serves default-limits, not the environment's | serve 1 — "its limits are the environment's: a target over CHEZ_HTTP_MAX_TARGET_BYTES gets 414" |
| M4.5-Y | the start logs the port asked for, 0, not the one it got | serve 3 — the listening row, and the two exchanges, whose client connects to the logged port |
| M4.5-Z | the facade exports `start-server` too (`src/http-server.sls`) | serve 1 — "the facade exports the handler's names, the server's start, and its errors" |
| M4.5-AA | the log writes a record whole (`put-detail`) | serve 1 — "the log writes a line for each thing: what happened, then each detail" |
| M4.5-AB | the log keeps a condition's line breaks | serve 1 — "a condition in the log reads as Chez displays it, on one line" |
| M4.5-AC | the environment's path accepts a pipeline cap of 2 (`env-pipeline-cap`) | limits 1 — "a pipeline cap of 1 is accepted; 2 and 8 are refused"; serve 1 — the malformed-setting row, its pipeline cap |
| M4.5-AD | the start leaves a timer on the loop | serve 1 — "shut down, the server leaves nothing on the loop" |
| M4.5-AE | `serve` reads the process's environment, not its lookup | serve 1 — the malformed-setting row: every start is refused at the bind, naming CHEZ_HTTP_HOST, not the setting |
| M4.5-AF | the facade imports `(chezscheme)` (`src/http-server.sls`), run by `make check-imports` alone | `IMPURE IMPORT outside src/http-server/private/`, naming the line; make exit 2. Before this step the audit read `src/http-server/` alone and the facade's file was outside it |

AC first hung the serve suite: its `serve` accepted the cap, listened on
8080 and ran for good, and the run was killed. So every start that should
fail now also names a host no bind accepts, and so does the suite's own
environment: a start that gets past its settings, or a `serve` that reads the
process's environment (AE), is refused at the bind instead. AC and AE were
run again after that, and each turned its rows red without hanging.

Every check of the step is reddened by at least one mutant above.

## A Host value with OWS after it (2026-09-27)

The mutants ran against the fix's tree, uncommitted on
fix/host-trailing-whitespace at a5d8474, against every suite, and again after
the review's fixes (ledger, this date), with the same results. Rebased onto
6bf3c34 once M4.5 merged, they ran again against its thirty-four suites, with
the same results; the view suite's hand-built host row stays green under each,
since it builds its request without the core.

Red before green: on main's `value-fault` each new row failed alone in its
suite (host 11 passes and 1 failure, connection-head 51 and 1). The unit
row's four values read `(invalid-reg-name invalid-reg-name invalid-port
invalid-reg-name)`, and each request was refused 400 at every delivery size.
After review the head row leaves out the headers a handler reads; its red is
HW-A's, which judges the bounds main's code judged.

| # | mutation | observed |
|---|---|---|
| HW-A | the trim removed: `value-fault` judges the span as llhttp delivered it (`src/http-server/host.sls`) | host 1 — "a Host value is judged without the OWS around it"; connection-head 1 — "a Host value with a space or a tab after it is served". Every other suite green |
| HW-B | `value-fault` trims the OWS after the value, and keeps the OWS before it | host 1 — the same row, through ` h`. Every other suite green: llhttp never delivers OWS before a value, so the head row cannot see it |
| HW-P | a probe, not a mutation of the fix: the core trims every value where it records it (`src/http-server/connection.sls`, `on-header-value-complete`) | every suite green: 32 at a5d8474, 34 after the rebase. Under it the handler reads `h` for `X: h ` (checked), so the head row asks nothing of what a handler reads. It makes a span for every value, and the allocation lane stayed green |

`make test` afterwards: see the ledger's entry of this date.
