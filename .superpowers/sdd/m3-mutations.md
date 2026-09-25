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
