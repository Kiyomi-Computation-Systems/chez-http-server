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
