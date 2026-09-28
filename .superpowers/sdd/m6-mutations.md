# M6 — mutation log

Every test in M6 is watched to fail: a single named mutation breaks the
asserted property, the suite goes red, and the mutation is reverted. Recorded
per global-constraints ("a test is finished when it has been watched to fail").
The milestone plan §14 names one mutation per slice; the extras below each
witness a property the slice's suites assert beside it.

Platform: Darwin arm64, Chez Scheme 10.4.1 (`tarm64osx`), libuv 1.52.1, 2026-09-28.
Library path as in M5
(`src:tests:vendor/chez-libuv/src:vendor/chez-httparse/src:vendor/chez-httparse/vendor/byte-machine/src:vendor/uriparse/src:build/scheme-libs:vendor/chez-httparse/test/support/harness:vendor/chez-libuv/tests`).
Each mutant ran from a scratch copy of the mutated file, placed first on the
library path under an absolute root, or, for a suite program, run from that
root; the substitution had to match exactly once, several edits to one file
applied in turn, and the tree was never edited. A row lists each suite that
went red and its failures; the others were green. "exit 2" is a suite whose
body raised, and "exit 255" one that did not load.

## M6.1, first step — the readers, and brief risk 3's pins (2026-09-28)

Red before green: `tests/test-body.sps` stopped at load, exit 255, with
`(http-server body)` not found, before the library was written. The pins
suite pins a dependency, so it passed as written, and was watched red by its
mutants.

These ran on the first step's own tree, a scratch worktree cut from main at
f21ab76 with the step's files laid in, against all of its thirty-nine
suites.

The plan's mutation (M6.1-PA) first made the pins suite loop for ever:
feeding again from where the read started feeds the same bytes again at
every pause, and the runner stopped it at 600 s. The suite's feed loop is now
capped by iteration count, one feed per byte and one more, and past it notes
that it looped: the two pinned rows fail, and the suite ends.

| # | mutated | mutation | observed |
|---|---|---|---|
| M6.1-PA | `test-pause-pins.sps` | the plan's: the feed after the pause starts where the read started | pause-pins 2 |
| M6.1-PB | `test-pause-pins.sps` | an empty rest is not fed | pause-pins 1 |
| M6.1-BA | `body.sls` | read-body makes a whole reader | body 1 |
| M6.1-BB | `body.sls` | the helper cap is 1,048,575 | body 1 |
| M6.1-BC | `body.sls` | a cap given is ignored | body 2 |
| M6.1-BD | `body.sls` | the whole body is always copied | body 1 |
| M6.1-BE | `body.sls` | a part of a bytevector is never copied | body 1 |
| M6.1-BF | `body.sls` | no piece: the procedure gets #f | body 1 |
| M6.1-BG | `body.sls` | on-end answers a symbol, not the procedure's answer | body 4 |
| M6.1-BH1 | `body.sls` | no check that a reader is made of procedures | body 1 |
| M6.1-BH2 | `body.sls` | no check on the cap | body 1 |

## M6.1, second step — the core hands a body to a reader (2026-09-28)

The core's rows were written with their tests, and each check was then
watched red against a mutant. These ran on the finished tree, after the
review's fixes, against all of its forty suites; the first step's eleven ran
again here too, and redden more suites than on their own tree.

Found by the mutants, and settled before they were recorded:
- M6.1-CAA's first spec did not load (a parenthesis too many), and tested
  nothing; fixed, it was run again.
- After the first run six changed checks had no mutant; M6.1-EM to M6.1-ER
  were written for them, and each went red.
- M6.1-CK is the bug the reader's own view found while building (decision
  0013's "Found while building"): the core letting a reader go when it
  writes a status of its own. It reddens the checks that read what a reader
  was handed at every delivery size.
- The review rewrote the code nine specs mutated (the pieces handed on, the
  whole buffer, the status's release). Eight were written again, with the
  same meaning, on the new code; M6.1-CD, which allocated the declared length
  one byte longer, is withdrawn, its code gone. M6.1-RA to M6.1-RH witness
  the review's fixes.

| # | mutated | mutation | observed |
|---|---|---|---|
| M6.1-PA | `test-pause-pins.sps` | the plan's: the feed after the pause starts where the read started | pause-pins 2 |
| M6.1-PB | `test-pause-pins.sps` | an empty rest is not fed | pause-pins 1 |
| M6.1-BA | `body.sls` | read-body makes a whole reader | body 1; connection-body 4; connection-entry 1; connection-table 6 |
| M6.1-BB | `body.sls` | the helper cap is 1,048,575 | body 1 |
| M6.1-BC | `body.sls` | a cap given is ignored | body 2; connection-body 4; connection-table 3; shell 2 |
| M6.1-BD | `body.sls` | the whole body is always copied | body 1 |
| M6.1-BE | `body.sls` | a part of a bytevector is never copied | body 1 |
| M6.1-BF | `body.sls` | no piece: the procedure gets #f | body 1; connection-body 4 |
| M6.1-BG | `body.sls` | on-end answers a symbol, not the procedure's answer | body 4; connection-allocation 1; connection-body 4; connection-retention 1; shell 2 |
| M6.1-BH1 | `body.sls` | no check that a reader is made of procedures | body 1 |
| M6.1-BH2 | `body.sls` | no check on the cap | body 1 |
| M6.1-CA | `connection.sls` | a streaming reader is handed no piece as it arrives | connection-body 9; connection-entry 1; connection-table 2; libhtp-lane 2; ratchet 1 |
| M6.1-CB | `connection.sls` | the pieces kept for the answer are dropped | connection-body 13; connection-retention 2; connection-table 4; libhtp-lane 4; ratchet 1; shell 1 |
| M6.1-CC | `connection.sls` | a whole body is handed over as no piece | connection-body 5; connection-retention 2; connection-table 1; shell 1 |
| M6.1-CE | `connection.sls` | a chunked body handed over as its last piece only | connection-body 1; shell 1 |
| M6.1-CF | `connection.sls` | a whole reader's pieces also handed over as they arrive | connection-allocation 1; connection-body 4; connection-table 1 |
| M6.1-CG | `connection.sls` | an empty whole body is not ended | connection-body 4; connection-table 1 |
| M6.1-CH | `connection.sls` | a response to a request with a body does not close | connection-body 3; connection-table 3; outcome-lane 2; shell 2 |
| M6.1-CI | `connection.sls` | a declared length is not held to max-body-bytes | connection-body 1; connection-originated 1; connection-table 1; serve 1 |
| M6.1-CJ | `connection.sls` | a piece past a cap is not handed over up to it | connection-body 2; connection-table 1 |
| M6.1-CK | `connection.sls` | every status the core writes lets the reader go | connection-body 2 |
| M6.1-CL | `connection.sls` | a reader's cap is not held to the declared length | connection-body 1; connection-table 1 |
| M6.1-CM | `connection.sls` | a reader's cap is ignored | connection-body 4; connection-table 3; shell 2 |
| M6.1-CN | `connection.sls` | a reader's cap is not held to the pieces as they arrive | connection-body 2; connection-table 1 |
| M6.1-CO | `connection.sls` | an error the head's feed met in the body is answered at once | connection-body 5; connection-table 5; outcome-lane 2; ratchet 1 |
| M6.1-CP | `connection.sls` | handler-failed is not answered while the body is read | connection-body 2; connection-table 2 |
| M6.1-CQ | `connection.sls` | a reader that raised is not let go | connection-body 1 |
| M6.1-CS | `connection.sls` | the final response keeps the reader | connection-body 1; connection-retention 1 |
| M6.1-CT | `connection.sls` | a head announcing a body asks the handler in its own step | connection-allocation 1; connection-body 5; connection-entry 2; connection-retention 2; connection-table 9; outcome-lane 1 |
| M6.1-CU | `connection.sls` | the handler is never asked with the feed's result | clients 5; connection-allocation 1; connection-body 22; connection-entry 5; connection-head 2; connection-retention 2; connection-table 20; contract 7; libhtp-lane 5; message-loop 4; outcome-lane 3; ratchet 1; shell 9; trace-lane exit 2 |
| M6.1-CV | `connection.sls` | pieces met before the answer are handed over at once | connection-body 18; connection-retention 2; connection-table 6; libhtp-lane 4; ratchet 1; shell 1 |
| M6.1-CW | `connection.sls` | the pieces kept are handed over newest first | connection-body 4; connection-table 1; libhtp-lane 2; ratchet 1; shell 1 |
| M6.1-CX | `connection.sls` | a whole reader is handed the pieces kept, besides buffering them | connection-body 3; connection-table 1 |
| M6.1-CY | `connection.sls` | a streaming reader is not ended at the message's end | connection-body 5; connection-head 2; connection-table 1; contract 2; libhtp-lane 4; message-loop 2; outcome-lane 2; ratchet 1 |
| M6.1-CZ | `connection.sls` | the reader's response is not answered | clients 5; connection-allocation 1; connection-body 8; connection-deadlines 3; connection-entry 3; connection-head 16; connection-retention 2; connection-table 1; contract 3; libhtp-lane 12; message-loop 4; outcome-lane 2; ratchet 1; shell 5; trace-lane exit 2 |
| M6.1-CAA | `connection.sls` | no row ends a reader | clients 5; connection-body 9; connection-deadlines 3; connection-entry 4; connection-head 16; connection-table 6; contract 4; libhtp-lane 12; message-loop 4; outcome-lane 2; ratchet 1; shell 5 |
| M6.1-CG2 | `connection.sls` | a streaming reader of an ended message is not ended | clients 5; connection-body 5; connection-deadlines 3; connection-entry 4; connection-head 16; connection-table 2; contract 2; libhtp-lane 8; message-loop 4; outcome-lane 3; ratchet 1 |
| M6.1-CL2 | `connection.sls` | a reader's cap is not held to the body met before it answered | connection-body 1; connection-table 1 |
| M6.1-CO2 | `connection.sls` | a kept error is answered before the pieces kept | connection-body 2; connection-table 2 |
| M6.1-CO3 | `connection.sls` | a kept error is answered to a response too | connection-body 1; connection-table 1; outcome-lane 1 |
| M6.1-EA | `connection.sls` | a streaming reader's piece is copied | connection-entry 1; connection-table 2 |
| M6.1-EB | `connection.sls` | a message's end does not pause the parser (M2.4's) | clients 10; connection-allocation 4; connection-body 9; connection-deadlines 1; connection-entry 2; connection-head 14; connection-linger 1; connection-response 11; connection-retention exit 2; connection-table 1; contract exit 2; libhtp-lane 6; message-loop exit 2; outcome-lane 2; ratchet 1; shell exit 2; view 12 |
| M6.1-EC | `connection.sls` | a reader's acceptance keeps a KiB | connection-allocation 2 |
| M6.1-EE | `shell.sls` | the libuv shell hands a reader no piece | contract 4; shell 1 |
| M6.1-EF | `shell.sls` | the libuv shell never ends a reader | clients 5; contract 10; shell 5 |
| M6.1-EG | `shell.sls` | the libuv shell does not catch a reader's piece raising | contract 3 |
| M6.1-EH | `shell.sls` | the libuv shell does not catch a reader's end raising | contract 3 |
| M6.1-EI | `fake-shell.sls` | the fake shell does not catch a reader's end raising | connection-body 1; contract exit 2 |
| M6.1-EJ | `http-server.sls` | the facade does not export read-whole-body | serve 1 |
| M6.1-EK | `fake-shell.sls` | every dispatch drains, nested (M2.4-C's) | connection-body 1; fake-shell 1; libhtp-lane 12; message-loop 4; outcome-lane 5; ratchet 1 |
| M6.1-EM | `connection.sls` | a keep-alive completion starts reading before it resumes the parser | connection-table 2; message-loop 3 |
| M6.1-EN | `connection.sls` | a handler asked is asked again at the next feed's result | clients 5; connection-allocation 1; connection-body 21; connection-entry 3; connection-head 2; connection-retention 2; connection-table 16; contract 7; libhtp-lane 5; message-loop 5; outcome-lane 5; ratchet 1; shell 9; trace-lane exit 2 |
| M6.1-EO | `connection.sls` | the body deadline's tick row removed (M5.2-B, on this tree) | connection-deadlines 1; connection-originated 1; connection-table 3; shell 2 |
| M6.1-EP | `test-connection-originated.sps` | the 413 row removed | connection-originated 2 |
| M6.1-EQ | `test-connection-table.sps` | row B19 has no instance | connection-table 1 |
| M6.1-ER | `test-contract.sps` | the contract renders a reader as any record | contract 4 |
| M6.1-RA | `connection.sls` | the declared length allocated as the reader answers, before the body arrives (the review's first finding) | connection-body 1 |
| M6.1-RB | `connection.sls` | the declared length allocated at the first piece | connection-body 1 |
| M6.1-RC | `connection.sls` | the buffer grown by each piece alone | connection-allocation 1 |
| M6.1-RD | `connection.sls` | the buffer doubled past the declared length, never grown to it | connection-allocation 1; connection-body 1 |
| M6.1-RE | `connection.sls` | a status the core writes keeps the whole reader's buffer (the review's second finding) | connection-body 1 |
| M6.1-RF | `limits.sls` | CHEZ_HTTP_MAX_BODY_BYTES not read from the environment | limits 1; serve 1 |
| M6.1-RG | `fake-shell.sls` | the suites' reading handler answers without reading | connection-deadlines 1; connection-head 2; connection-originated 1; libhtp-lane 5; message-loop 4; outcome-lane 2; ratchet 1 |
| M6.1-RH | `connection.sls` | a piece past a cap handed over whole | connection-body 2; connection-table 2 |
