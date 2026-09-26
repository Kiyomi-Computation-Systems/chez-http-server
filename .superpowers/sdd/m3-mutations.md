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
