# M3 — mutation log

Every test in M3 is watched to fail: a single named mutation breaks the
asserted property, the suite goes red, and the mutation is reverted. Recorded
per global-constraints ("a test is finished when it has been watched to fail").
The milestone plan §7 names one mutation per slice; the extras below each
witness a property the slice's suite asserts beside its table.

Platform: Darwin arm64, Chez Scheme 10.4.1 (`tarm64osx`), 2026-09-25.
Library path as in M2 (`src:tests:vendor/chez-libuv/src:vendor/chez-httparse/src:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs:vendor/chez-httparse/test/support/harness`).
Each mutant ran from a scratch copy of the mutated file, placed first on the
library path under an absolute root; the substitution had to match exactly
once, and the tree was never edited.

## M3.1 first step — what a response may carry, and the Date line (2026-09-25)

The mutants ran against the step's tree alone, in a scratch worktree cut from
main at b491d1f, against test-serializer: nothing else imports
`(http-server serializer)` yet.

Red before green: against a stub that exported the four names and answered
nothing (no fault, never closing, a zero Date line), the suite exited 1 with 7
passes and 32 failures. The 7 were the rows whose answer is "no fault" or
"does not close", which the stub gave by accident; H to N make each red.

| # | mutation (`src/http-server/serializer.sls`) | observed |
|---|---|---|
| M3.1-B | the calendar drops the 400-year rule (`(fxdiv doe 146096)` → `0`) | exit 1; 38 passes, 1 failure — "every instant's line is Chez's calendar's": exactly the three instants on an era's last day, 2000-02-29 twice and 2400-02-29, which read as 1 March. The sweep's 4,334 regular instants, the RFC 9110 example and the epoch held; the edges are in the table for this |
| M3.1-C | a value refuses only CR, LF and NUL | exit 1; 2 failures — the 0x01 and DEL rows |
| M3.1-E | a 1xx is accepted as an answer (100..599) | exit 1; 2 failures — the 100 and 199 rows |
| M3.1-H | a value's HTAB is refused too | exit 1; 1 failure — "an HTAB and obs-text in a value" |
| M3.1-I | the close option is compared case-sensitively | exit 1; 2 failures — "a handler's Connection: Close" (refused as a connection-field) and "a handler's Connection: close closes" (`CLOSE`) |
| M3.1-J | the close option keeps its leading whitespace | exit 1; 1 failure — "a handler's Connection: close, with spaces" |
| M3.1-K | the status range ends at 598 | exit 1; 1 failure — "a 599" |
| M3.1-L | a name or value must be a bytevector, never a span | exit 1; 1 failure — "a name and a value that are spans" |
| M3.1-M | every response asks to close | exit 1; 1 failure — "no Connection field does not" |
| M3.1-N | an empty reason is refused | exit 1; 1 failure — "an empty reason" |

A first run of M (`#t` put before the body) survived: the body's last
expression still decided the answer, so the mutant changed nothing. Rewritten
to return `#t` outright, it died as above.

Every suite was green afterwards, in the scratch worktree: twenty-two suites,
440 expected passes (serializer 39), each exit 0.

## M3.1 second step — the wire (2026-09-25)

The mutants ran against the finished tree, uncommitted on feat/m3.1-wire,
against test-serializer.

Red before green: with the first step's library and a `serialize-response`
that answered nothing, the suite exited 1 with 56 passes and 85 failures —
every wire, segment, byte-count and read-back check of the 17 rows, the 13
status lines and the four refusals. The 56 were the first step's 39 and the
rows' 17 "no fault" checks.

| # | mutation (`src/http-server/serializer.sls`) | observed |
|---|---|---|
| M3.1-A | consecutive bytevector segments are joined into one (plan §7's named mutation) | exit 1; 134 passes, 7 failures — exactly the segment counts of the seven rows with something to join: the six with a body after the head (Content-Length, chunked, close-delimited, the handler's fields, keep-alive, the handler's Connection), and the handler's Date row, whose status line and block meet with no slot between. Every wire, byte count and read-back held: the bytes are identical, and only the count sees the concatenation |
| M3.1-D | the header block copies a handler's Connection field as well | exit 1; 3 failures — that row's wire, byte count and read-back (the parser reads two Connection fields). Its segment count held: the block is still one segment |
| M3.1-F | the chunk size is written in decimal | exit 1; 2 failures — the chunked row's wire (`26` for `1a`) and its read-back: the parser read a 38-byte chunk and was still waiting for its data |
| M3.1-G | a Date slot is left beside a handler's own Date | exit 1; 4 failures — that row's wire, segments, byte count and read-back (two Date fields) |

The first step's ten, re-run on the whole suite:

| # | observed |
|---|---|
| M3.1-B, C, E, I, J, K, N | exit 1; the same rows as in the first step, and nothing else: 1, 2, 2, 2, 1, 1 and 1 failures |
| M3.1-H | exit 1; 6 failures — the fault row, and the wire row's five checks: the refusal stops the write |
| M3.1-L | exit 1; 6 failures — the fault row, and the span row's five checks, for the same reason |
| M3.1-M | exit 1; 75 passes, 66 failures — the wire, segments, byte count and read-back of the 13 rows whose connection stays open (52), the 13 status lines, and "no Connection field does not". A response that asks to close cannot be written on a connection that stays open, so the serializer refuses them all, and the loops count each refusal as failed checks rather than ending the suite |

A is the plan's prediction made exact: the wire bytes are identical, and only
the segment counts go red, which is the assertion earning its place (plan §7).
The read-back is chez-httparse's strict response parser, a client that is not
our code; it goes red with the wire in D, F, G, H and L.

`make test` was green afterwards: twenty-two suites, 542 expected passes
(serializer 141), exit 0.

## The ratchet and a libhtp run that raises (2026-09-25)

Found by M3.2-T on feat/m3.2-framing. Its fault made the fake shell raise
"a write's byte count is not its bytes'", and test-ratchet.sps exited 255,
outside the status vocabulary. The ratchet computed its verdicts at the
program's top level, and `libhtp-mismatch` ran each stream with no guard.

The mutants ran against the fix, uncommitted on fix/ratchet-libhtp-raise (cut
from main at bd49005). F is M3.2-T's fault, simulated on this tree: the fake
shell's `write` raises its assertion, with the irritants (95 94).

Red before green: the new check in test-libhtp-lane, "a stream whose run
raises is a mismatch that says what it raised", first failed against main's
`libhtp-mismatch` on arity. With the run as an argument and no guard, it
failed for the right reason: exit 1, 14 passes, 1 failure. The run's assertion
escaped `libhtp-mismatch`, and SRFI-64 counted it as the check's failure.

| # | suites | mutation (`tests/libhtp-lane.sls`) | observed |
|---|--------|------------------------------------|----------|
| L9 | libhtp-lane, ratchet | `libhtp-mismatch` runs the stream bare, not through the outcome lane's `attempt` (the lane's L1–L8 are the M2 exit's) | libhtp-lane exit 1; 14 passes, 1 failure — the new row. Ratchet green: on this tree no stream's run raises |

test-ratchet under F:

| lane and ratchet | observed |
|---|---|
| main's | exit 255; "Exception in fake-shell: a write's byte count is not its bytes' with irritants (95 94)", the report's crash |
| the fix's lane with L9, main's ratchet | exit 255, the same crash: the gate ran at the program's top level |
| the fix with L9 | exit 2; HARNESS-ERROR after 8 passes: the gate runs inside the suite |
| the fix | exit 1; 8 passes, 1 failure. 141 violations, each with its lane's reason: the 12 libhtp streams ("raised fake-shell a write's byte count is not its bytes'") and 129 outcome fixtures ("the whole input raised …"). The other 6 end in `body` and write nothing: content-length.md#10, #11 and #16, and transfer-encoding.md#2, #8 and #11. The trace lane runs no fake shell |

The trace lane passes on any raise but an adapter refusal. With its comparator
made to raise, the fix's ratchet exited 2, HARNESS-ERROR after 8 passes, and
main's exited 255 ("Exception in trace-lane: a probe raise").

`make test` was green afterwards: twenty-two suites, 543 expected passes
(libhtp-lane 15), exit 0.

## M3.2 first step — the framing decision (2026-09-25)

The mutants ran against the finished tree, uncommitted on feat/m3.2-framing,
against test-decisions: nothing else calls the decision in this step. The
counts are the final tree's, re-measured after review added the status
check, which is one more pass in each.

Red before green: against a stub that exported `response-framing` and
`response-connection` and answered nothing, the suite exited 1 with 17 passes
and 34 failures: every framing and Connection row, the three checks beside
them, and the reason list, which names invalid-response. The 17 were the
checks the suite had before. The status check, added in review, failed first
against the decision without it: 51 passes, 1 failure.

| # | mutation (`src/http-server/decisions.sls`) | observed |
|---|---|---|
| M3.2-A | the brief's: an unknown length is chunked whatever the version (the gate before `chunked` dropped) | exit 1; 48 passes, 4 failures — the unknown-length rows for 1.0, 0.9 and 2.0, and "every framing mode is some row's answer": close-delimited is no row's answer any more |
| M3.2-B | the version gate reads the major version only | exit 1; 4 failures — the unknown-length rows for 1.0 and 2.0, now chunked, and the Connection rows for 1.0 and 2.0, which lose their keep-alive. 0.9 held: its major is 0 |
| M3.2-C | a HEAD's rule comes before the 1xx, 204, 304 and CONNECT rule | exit 1; 2 failures — "a 204 to a HEAD" and "a 304 to a HEAD", each given the HEAD's Content-Length |
| M3.2-D | a 304 is framed as usual | exit 1; 2 failures — the 304 with a body, and the 304 to a HEAD |
| M3.2-E | every status to CONNECT has no body, not only a 2xx | exit 1; 2 failures — the 3xx and the 407 to CONNECT |
| M3.2-F | a HEAD answered with no body announces a length | exit 1; 1 failure — "a HEAD answered with no body gets neither" |
| M3.2-G | the 1xx range ends at 198 | exit 1; 1 failure — "the last 1xx gets neither" |
| M3.2-H | the 2xx range to CONNECT ends at 298 | exit 1; 1 failure — "the last 2xx to CONNECT, of unknown length, gets neither" |
| M3.2-I | keep-alive is written to HTTP/1.1 too | exit 1; 1 failure — the 1.1 Connection row |
| M3.2-J | only HTTP/1.1's last response says close | exit 1; 3 failures — the Connection rows for 1.0, 0.9 and 2.0 |
| M3.2-K | invalid-response has no status of its own | exit 1; 1 failure — the reason list |
| M3.2-L | any length is taken | exit 1; 1 failure — "a length that is not a count, #f or unknown is refused" |
| M3.2-S | any status is framed (review) | exit 1; 1 failure — "a status outside 100–599 is refused" |

A is the plan's named mutation, with the plan's expectation met: the 1.0
table rows, and nothing else. That takes a row whose length is unknown: a
known length gets Content-Length at every version, so without M6's stream in
the decision's domain, chunked to a 1.0 client could not be told apart.

Every suite was green with this step alone on 409b886, in a scratch
worktree: twenty-two suites, 577 expected passes (decisions 52), each exit 0.

## M3.2 second step — the serializer's entry for a checked response, and what the reader sees (2026-09-25)

The mutants ran against the finished tree, against test-serializer, and
against the core's suites (connection-response and -table) to show where
else each is seen.

Red before green: against a stub `serialize-checked-response` that wrote
nothing, the suite exited 1 with 144 passes and 2 failures, the entry's two
checks. Against M3.1's reader, which answered on at a message's end, it
exited 1 with 144 passes and 2 failures: `bytes-after` and the 100 Continue.
A 1xx alone reads the same with either reader, so that check only pins it.

| # | mutation | observed |
|---|---|---|
| M3.2-U | `serialize-response` no longer asks for a fault (`src/http-server/serializer.sls`) | test-serializer exit 1; 145 passes, 1 failure — "a response with a fault is not serialized". The core's suites held: the core writes a handler's response through the checked entry, and its own have no fault, so the serializer's tripwire lives in this check alone |
| M3.2-V | the checked entry no longer refuses a close on a connection that stays (`src/http-server/serializer.sls`) | test-serializer exit 1; 3 failures — serialize-response's two refusals of a close on a kept connection, which go through the entry now, and the entry's own. The core's suites held: the core never passes such a response |
| M3.2-X | the reader stops at an interim response (`tests/response-reader.sls`) | test-serializer exit 1; 1 failure — "the reader reads past a 100 Continue". The core's suites held: no row writes an interim response |

Every suite was green with the first two steps on 409b886, in a scratch
worktree: twenty-two suites, 582 expected passes (serializer 146), each exit 0.

## M3.2 third step — the core writes through the serializer (2026-09-25)

The mutants ran against the finished tree, uncommitted on feat/m3.2-framing
after it took main at 409b886, against the core's suites, and R, T and AA
against every suite.

Red before green: against the second step's core, which still wrote
`(write response)`, the new suite exited 1 with 0 passes and 23 failures.
The table failed 10 (H7, the seven originated writes, R1 and R2), the head
suite 40, the outcome lane 3, the libhtp lane 12 and the ratchet 1, its
violation line. The message loop exited 2: its body raised, since the fake
shell cannot perform the old write. In review, the table's rows for the
write deadline and R1 failed first against the core without it (8), and the
two review rows of the new suite opened green: M3.2-Y and Z finish them.

| # | mutation (`src/http-server/connection.sls`) | observed |
|---|---|---|
| M3.2-M | the core ignores the handler's `Connection: close` | connection-response exit 1; 2 failures — the two rows with the handler's `Connection: close`. The checked entry still refuses a response that closes on a connection that stays, so each run raises |
| M3.2-N | the core writes a response without asking for its fault | connection-response exit 1; 6 failures — the six fault rows. The checked entry does not look for faults, so each goes on the wire as the handler gave it: the CR LF splits the response, and the client reads a `Set-Cookie: a=1` the handler never set; the parser refuses the handler's Content-Length beside the server's; the 101 goes out as a protocol switch; the string raises at the record's accessor |
| M3.2-O | the framing is not told the request's method | connection-response exit 1; 4 failures — the two HEAD rows, the HEAD's refused answer, and the 2xx to CONNECT. A HEAD answered with the GET's body reads back with the right status, fields and body; only the reader's `bytes-after` sees the body written after the head |
| M3.2-P | the framing takes every request for HTTP/1.1 | connection-response exit 1; 1 failure — "HTTP/1.0 asking to keep alive", which loses its keep-alive. The other 1.0 rows close, and say so either way |
| M3.2-Q | a refused response is answered with no log | connection-response exit 1; 6 failures — the six fault rows' actions |
| M3.2-W | the core's own responses arm no write deadline (review) | connection-table exit 1; 8 failures — T3's four, T4, T6, U2 and R1. The new suite held: it records writes and logs, not deadlines |
| M3.2-Y | a refused response keeps the connection (review) | connection-response exit 1; 6 failures — the six fault rows, each ending idle, and the one with a request behind it writing a second 500; connection-table 1, R1 |
| M3.2-Z | a response to no request is framed as a HEAD's (review) | connection-response 1 failure — "a HEAD redirected before its request is built"; connection-table 7 (T3's four, T4, T6, U2, whose states hold no request); connection-head 24 (the refusals made before the request is built) |
| M3.2-R | the Connection field never says close | red in three suites: connection-response 13 failures (every row that closes; the two with the handler's close raise), connection-head 25 (every refusal's header block) and connection-table 9 (T3's four, T4, T6, U2, R1 and R2). The message loop, the two lanes and the ratchet held: they record a write by its status |
| M3.2-T | a write's byte count is one more than its bytes | the fake shell's count check fires on every write: connection-response 23 failures, connection-head 40, connection-table 10 (H7, the seven originated writes, R1 and R2, whose counts the rows take from their own segments), libhtp-lane 12, outcome-lane 3, message-loop exit 2 (its body raised), and the ratchet exit 1, its one failure naming each violation with the reason its lane gives, "raised fake-shell a write's byte count is not its bytes'" |
| M3.2-AA | the core reads a handler's response for faults twice again (review) | survived every suite. It changes no byte and allocates nothing: the fault check is 270 ns of `serialize-response`'s ~570 ns for three headers, and 0 B, measured, not tested. A scope statement |

T found a gap outside M3.2: test-ratchet.sps ran its lanes at the top level,
outside `run-suite`, and a raise in a libhtp stream exited 255, outside the
status vocabulary. PR #33 (e339931) fixed it on main, and this branch takes
it: under T the ratchet now exits 1 and names each stream.

The first step's twelve, re-run on the finished tree against the eight
suites that read a write or the decision (decisions, connection-response,
-table and -head, message-loop, the outcome and libhtp lanes, ratchet):

| # | observed |
|---|---|
| M3.2-A, C, E, G, H, L | exit 1 in test-decisions only, on the same rows as in the first step. The core never passes an unknown length, a HEAD answered 204 or 304, a CONNECT answered 3xx or 4xx, a 199, a 299 or a bad length, so only the table can see them |
| M3.2-B | test-decisions as before, and connection-response 1 failure: "HTTP/1.0 asking to keep alive" |
| M3.2-D | test-decisions as before, and connection-response 1 failure: "a 304 with a body" |
| M3.2-F | test-decisions as before, and connection-response 2 failures: the HEAD answered with no body, and the HEAD's refused answer, the core's own 500 |
| M3.2-I | test-decisions as before, connection-response 9 failures (every HTTP/1.1 response on a connection that stays, and the Date check, a 1.1 GET) and connection-table 1 (H7) |
| M3.2-J | test-decisions as before, and connection-response 2 failures: the two 1.0 rows that close |
| M3.2-K | test-decisions as before, connection-response 6 failures (the six fault rows) and connection-table 1 (R1): `reason-status` refuses invalid-response, so the core raises |

The message loop, the two lanes, the ratchet and the head suite held for all
twelve: they record a write by its status, and the core's own responses
close.

`make test` was green afterwards: twenty-three suites, 608 expected passes
(connection-response 23), exit 0.

## M3.3 — write accounting (2026-09-25)

The mutants ran against the finished tree, uncommitted on
feat/m3.3-write-accounting at c39bcf6, after the review's fixes, against
every suite; A, A2, B and L again against the retention suite once its
driver took a refused completion as a failing check.

Red before green: against a stub that exported `conn-outstanding-bytes` and
took it in `make-conn-state`, with no accounting, the table exited 1 with 82
passes and 10 failures, every instance of W1 to W4 as they stood. The
retention suite was green there, 8 passes: the core already keeps nothing
of a response, so its red is the plan's mutation, A. The review's checks
failed first against the core before its fixes: the table exited 1, 92
passes and 4 failures (the constructor's check, W4's completion without a
count and with no write outstanding, and W5).

Found by the first run of A: the runner, `mut.py`, read each edit's file from
the tree afresh, so a spec with several edits to one file kept only the last,
and A and A2 failed to compile. It now applies them in turn. No earlier spec
had two edits to one file, so no recorded result changes.

| # | mutation (`src/http-server/connection.sls`) | observed |
|---|---|---|
| M3.3-A | the plan's: the state keeps the write's segment list until its completion | connection-retention exit 1; 2 failures, one per case. A handler's response: its body, the segment list and the header block held, the response record released. A fault's: the 500's segment list and header block held, the handler's response and body released, since they are never written. Every other suite green, every wire test among them: the bytes written are the same |
| M3.3-A2 | the state keeps the handler's response until the completion | connection-retention exit 1; 1 failure: a handler's response, the response and its body held, the segment list and header block released. The fault's case held: its response never reaches that line |
| M3.3-B | a write's bytes are not counted when it is issued | connection-table 3 failures, W1's three. Every completion is then more than is outstanding, so the core refuses it wherever a write completes: connection-response 23, connection-head 40, connection-entry 3 (the replays), connection-retention 2 (the two completions; nothing is kept), libhtp-lane 12, outcome-lane 3, the ratchet 1 (each violation "raised conn-step a completion the core did not ask for"), and exit 2 in connection-allocation, message-loop and trace-lane, whose bodies raised |
| M3.3-C | a completion does not take its bytes off | connection-table 4 failures: W2, W3's two and W5. A connection's second completion is then fewer bytes than are outstanding on its last write, so every connection that answers twice is refused: connection-response 1 (two requests in one delivery), connection-head 2 (the pipelined rows), connection-entry 1, message-loop 9, libhtp-lane 6 (the pipelined and multi-request files), outcome-lane 3, the ratchet 1, and exit 2 in connection-allocation and trace-lane |
| M3.3-D | the completion's check is gone | connection-table 6 failures, W4's six; nothing else |
| M3.3-E | the last write may leave bytes outstanding | connection-table 1 failure: W4's last completion one byte short, which leaves idle with 1 byte outstanding |
| M3.3-F | a completion may report one byte more than is outstanding | connection-table 1 failure: W4's completion over by one, which leaves -1 bytes outstanding |
| M3.3-G | the count is not checked to be a fixnum | connection-table 2 failures: W4's `ten` and its completion without a count, on each of which Chez's `fx<=?` raises before the core can refuse it. The row takes a refusal only from conn-step: `fx<=?`'s is an assertion violation too, so a row that took any would let G survive |
| M3.3-H | a completion in closing is ignored again (review) | connection-table 2 failures: W5, and W4's completion with no write outstanding, which closing then accepts |
| M3.3-I | a completion with no write outstanding is not refused (review) | connection-table 1 failure: W4's 0-byte completion in closing, which would leave -1 writes outstanding |
| M3.3-J | the state's counts are not checked when it is made (review) | connection-table 1 failure: the constructor's check, a write with no bytes and bytes with no write among its four refusals |
| M3.3-K | the count is read when the event arrives, in any state (review) | connection-table 1 failure: W4's completion without a count, on which `car` raises before the core can refuse it |
| M3.3-L | a handler's response gets no write (review: the retention driver) | connection-retention exit 1; 3 failures, the handler's case: 'no-write, the phase it stopped in, and no completion. The suite's checks fail; its body does not raise |

`make test` was green afterwards: twenty-four suites, 631 expected passes
(connection-table 96, connection-retention 8), exit 0.

## M3.4 — the originated statuses end to end (2026-09-25)

The mutants ran against the finished tree, uncommitted on
feat/m3.4-originated-statuses at b3b1a90, against every suite; H against the
new suite alone. They ran again after the review's fixes, which changed the
suite's text but no value it expects, and every result was the same.

Red before green: the rows opened green, 18 passes. M3.2 already writes every
originated status through the serializer, and M2 closes after each, so the
rows' red is the plan's mutation, A, run once per reason. Every mutant below
exited 1, and no suite's body raised.

Found by H's first run: the runner puts a mutated library first on the
library path, but it runs each suite program from the tree, so an edited
program was never run, and H read green. It now runs an edited program from
the mutant's root. H is the first spec to edit a program, so no recorded
result changes.

| # | mutation | observed |
|---|---|---|
| M3.4-A1 to A13 | the plan's, once per reason: `respond` keeps the connection alive after the status for one reason, and closes after every other (`src/http-server/connection.sls`) | connection-originated: exactly that reason's rows, one each, and two for A4 (parser-error: the 400 and the 501). The status is written without `Connection: close`. A kept 500 answers the request behind it too, and the connection ends idle. A kept status answered while reading resumes a parser that is not paused, and byte-machine refuses it (`&byte-machine-contract`) |
| | A1 target-redirect (301) | also connection-head 2 (the redirect rows), connection-response 1 (the HEAD's 301), outcome-lane 1 and the ratchet 1 (`request/uri.md#5`) |
| | A2 invalid-target (400) | also connection-head 10 (the target rows), outcome-lane 1, the ratchet 1 (four fixtures) |
| | A3 invalid-host (400) | also connection-head 5 (the Host rows) |
| | A4 parser-error (400 and 501) | also connection-head 3, connection-table 4 (T3's), outcome-lane 1, the ratchet 1 (four fixtures) |
| | A5 header-timeout (408) | also connection-table 2 (T4, and W1's 408). Nothing else produced a 408 end to end: this suite's row is the only one |
| | A6 target-too-large (414) | also connection-head 1 |
| | A7 to A10, the four 431 reasons | also connection-head 1 each, its own limit's row |
| | A11 handler-failed (500) | also connection-table 1 (T6), message-loop 1 |
| | A12 invalid-response (500) | also connection-response 6, connection-table 2 (R1, and W1's 500), connection-retention 1 (the fault's close) |
| | A13 http2-preface (505) | also connection-table 1 (U2), message-loop 1, outcome-lane 1, the ratchet 1 |
| M3.4-B | a delivery in `responding` is fed to the parser, as in the reading states | connection-originated 12 failures: every row answered while reading, from `head` or `body` (all but the two 500s, answered after reading stopped at the pause). Also connection-table 1 (P3) |
| M3.4-C | a response that closes the connection first resumes the parser onto its pending input | connection-originated 2 failures: the two 500s, whose next request was the pause's pending input. Also connection-head 2 (the pipelined rows), connection-table 1 (H10), message-loop 2 |
| M3.4-D | `(http-server decisions)` gains a reason, `(body-timeout . 408)`, that no row drives | connection-originated 1 failure: every reason has a row. Nothing else |
| M3.4-E | `originated-reasons` is empty | connection-originated 1 failure: every row's reason is one of them. The first coverage check would pass an empty list, so this one is its guard |
| M3.4-F | 413's reason phrase is RFC 7231's `Payload Too Large`, not RFC 9110's (`src/http-server/serializer.sls`) | connection-originated 1 failure: the 413, through the serializer. Also serializer 1 (the status line of 413) |
| M3.4-G | the core's own responses leave out `Connection: close`, and the connection still closes | connection-originated 14 failures, every row driven end to end; the 413 row holds, since it names its connection itself. Also connection-head 25, connection-response 7, connection-table 10 |
| M3.4-H | the table loses its 501 row (the one mutation made in the test, since the property is the table's) | connection-originated exit 1, 16 passes and 1 failure: design §6.5's statuses each have a row. The reasons' checks hold, since the 400's row carries parser-error too |

`make test` was green afterwards: twenty-five suites, 649 expected passes
(connection-originated 18), exit 0.

## The shared header helpers (2026-09-26)

The mutants ran against this PR's tree, uncommitted on
refactor/header-byte-helpers at 5e16b63, against every suite. HD ran again
once the compare's check gained a range longer than its token, `chunk`. That
case reads "different" under HA to HC as well, so their results stand.

| # | mutation (`src/http-server/headers.sls`) | observed |
|---|---|---|
| HA | `range-ci=?` compares with regard to case | headers 1 (the compare), serializer 2 (a handler's `Connection: Close`, and its close) |
| HB | `trim-ows` keeps trailing OWS | headers 1 (the trim), serializer 1 (`Connection: close` with spaces) |
| HC | `trim-ows` keeps leading OWS | headers 1 (the trim), serializer 1 (`Connection: close` with spaces) |
| HD | `range-ci=?` matches a token as a prefix | headers 1 (`chunk` against `Chunked`), serializer 1 (a handler's `Connection: close, upgrade` taken for close) |

`make test` was green afterwards: twenty-five suites, 652 expected passes,
exit 0.

## The transfer-encoding statuses, by RFC 9112 (2026-09-26)

The mutants ran against the finished tree, uncommitted on
fix/transfer-encoding-status at 5e16b63, against every suite. That tree
includes the review's fixes and the owner's 400 for HTTP/1.0 with
Transfer-Encoding. Earlier sets ran on the trees before the review and
before the 400. The review redesigned the check, and the 400 turned a close
into a refusal, so the set below replaces them for the tree committed.

Red before green, in three rounds:
- before the review, 19 checks failed in five suites against a stub, every
  one on the transfer codings: connection-head 4, connection-originated 3,
  connection-table 1, decisions 4 and transfer-coding 7. In that stub the new
  library refused nothing, and `invalid-transfer-encoding` was answered 501
  at every node, as the old split answered its no-chunked node;
- for the review's fixes, 8 checks failed in four suites. The stub gave the
  new API with the old behaviour: the order-bound check, no close for
  HTTP/1.0, and header helpers that answered wrongly. The failures were
  connection-response 1, connection-table 1, headers 3 and
  transfer-coding 2;
- for the owner's 400, 6 checks failed in three suites against the tree that
  closed after the response: connection-head 3, connection-originated 2 and
  decisions 1. The unit suite could not load until the rule had its new
  name.

Found while writing the mutants:
- the first set's scan past the value would have survived the unit suite's
  first helper. Its lines went on "\r\nX: gzip, chunked", and a scan past a
  value never met a clean chunked there. The helper now puts ", gzip"
  straight after the value;
- the review's rewrite needed a row the suite lacked, the two lines in the
  other order, for TG.

| # | mutation | observed |
|---|---|---|
| TA | `parser-error-status` answers `invalid-transfer-encoding` 501 again (`src/http-server/decisions.sls`) | connection-head 2 (pigeons, `chunked, deflate`), connection-originated 1 (the 400 with no chunked), connection-table 1 (T3), decisions 3 |
| TB | the core never asks about the codings (`src/http-server/connection.sls`) | connection-head 2 (another coding beside chunked, on one line and on two), connection-originated 1 (the 501) |
| TC | the codings are judged before the target | connection-head 1 (the invalid target's 400), and the trace lane 1: transfer-encoding.md#21 and #22 are refused as unsupported-transfer-coding, not invalid-target |
| TD | the codings are judged before the Host, and so before the framing | connection-head 3 (the missing Host's 400, the invalid target's, and HTTP/1.0 with `gzip, chunked`, which turns 501), and the trace lane 1 (#21 and #22) |
| TE | the F-CHUNKED gate is gone: the codings are read for every request (`src/http-server/transfer-coding.sls`) | connection-head 1 and connection-originated 1 (pigeons turns 501), transfer-coding 1, and the trace lane 1: the core refuses transfer-encoding.md#13 before the parser does |
| TF | the gate reads F-TRANSFER-ENCODING, not F-CHUNKED | the same as TE |
| TG | only the first Transfer-Encoding line in the list is read | connection-head 1 (two lines: the core keeps its fields newest first), transfer-coding 1 (two lines, in either order) |
| TH | `range-ci=?` compares with regard to case (`src/http-server/headers.sls`) | headers 1, serializer 2 (a handler's `Connection: Close`), transfer-coding 1 |
| TI | `trim-ows` keeps trailing OWS | headers 1, serializer 1 (`Connection: close` with spaces), transfer-coding 1, and the trace lane 1: transfer-encoding.md#27 and #29 send `chunked` with a trailing space |
| TJ | `trim-ows` keeps leading OWS | headers 1, serializer 1, transfer-coding 2 |
| TK | an empty element counts as a coding | transfer-coding 1 (`, chunked` and `chunked, , chunked`) |
| TL | `range-ci=?` matches a token as a prefix | headers 1 (`chunk` against `Chunked`), serializer 1 (a handler's `Connection: close, upgrade` taken for close), transfer-coding 1 (`chunkedchunked, chunked`). Run again once the PR below gave the compare's check its prefix case |
| TM | the scan runs past the value to the end of its bytevector | transfer-coding 4, and every chunked request end to end, whose value runs on into the rest of the delivery: connection-entry 1, connection-head 1, libhtp-lane 3, outcome-lane 1, the ratchet 1, the trace lane 1 |
| TN | the HTTP/1.0 rule is never asked (`src/http-server/connection.sls`) | connection-head 3 (HTTP/1.0 with Transfer-Encoding, twice, and the framing's order), connection-originated 1 (its 400) |
| TO | the rule's version gate is inverted | transfer-coding 2, and every HTTP/1.1 request with Transfer-Encoding is refused 400 while HTTP/1.0 passes: connection-head 8, connection-originated 3, connection-entry 1, libhtp-lane 3, the ratchet 1, the trace lane 2 |
| TP | the rule reads F-CHUNKED, not F-TRANSFER-ENCODING | transfer-coding 1 (HTTP/1.0 with Transfer-Encoding and no chunked framing). Nothing end to end: the parser refuses every Transfer-Encoding it does not frame as chunked, so the two flags refuse the same requests |
| TQ | `unsupported-transfer-coding` is answered 400 (`src/http-server/decisions.sls`) | connection-head 2, connection-originated 1, decisions 1 (the reasons' table) |
| TR | the framing is judged after the target (`src/http-server/connection.sls`) | connection-head 1 (the framing before the target: an HTTP/1.0 target with a fragment turns invalid-target) |
| TS | the framing is judged before the Host | connection-head 1 (two Hosts on HTTP/1.0 with Transfer-Encoding turn faulty-framing) |
| TU | `faulty-framing` is answered 500 (`src/http-server/decisions.sls`) | connection-head 3, connection-originated 1, decisions 1 (the reasons' table) |

`make test` was green afterwards: twenty-six suites, 674 expected passes,
exit 0.

## M3.5, first PR — the limit and the fake shell's shutdown (2026-09-26)

The mutants ran on the first PR's tree (feat/m3.5-linger-groundwork),
against every suite.

Red before green:
- the limits suite could not load before the field existed;
- the fake shell's recovery check failed against the drain that left its
  depth raised: the next dispatch's shutdown never ran;
- the write-after-shutdown check is the harness's own, and SN below is its
  red.

Found while writing the checks: the fake shell's own suite drives it with
stub actions that are bare symbols. The first version of the
write-after-shutdown check read each action with `car`, and raised on the
first one. It now reads only a tagged list.

| # | mutation | observed |
|---|---|---|
| SL | the linger default is 5 s, not decision 0011's 30 s (`src/http-server/limits.sls`) | limits 1 (the default). The drift guard holds: both defaults moved together |
| SM | `CHEZ_HTTP_LINGER_TIMEOUT` is read as milliseconds | limits 1 (the override) |
| SN | the fake shell lets a write through after the shutdown (`tests/fake-shell.sls`) | fake-shell 2 (the refusal, and the actions after it: the write and its note ran) |
| RE | the drain restores nothing on a raise, as before the review | fake-shell 1 (the next dispatch never drains) |
| RF | the drain restores the depth on a raise, but keeps the abandoned queue | fake-shell 1 (the note queued behind the refused write runs first) |

`make test` was green afterwards: twenty-six suites, 679 expected passes,
exit 0.
