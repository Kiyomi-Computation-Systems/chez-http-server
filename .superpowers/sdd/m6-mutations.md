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


## M6.2, first step — the core waits for a reader's credit (2026-09-28)

Red before green, in the first build: the table suite stopped at load, exit
255, its reader that grants credit made with five arguments before
`make-body-reader` took them; with the reader's field written, fifteen of its
checks failed until the core's rows were: the state list, C1, C3 to C8, and
D4's new instance. C2, C9 and T2's new instance passed at once, since each
says nothing changes, which the core already did. The review then moved the
credit's word from that field to the shell's answer; its rows and checks
(C10, C11, C2's whole reader on credit, C6's credit while the body is read,
and the two refusal flows) were written with the fixes. Every check was
watched red by the mutants below.

These ran on the first step's own tree, a scratch worktree cut from main at
e9191ef with the step's files laid in, against all of its forty suites.
M6.2-D is the plan's mutation: the credit ignored, reading goes on. Every
check the step added or changed is reddened by at least one mutant:
- C1 by D and E; C2 by I and RI; C3 by D, E and K; C4 by D, F and G; C5 by D
  and G; C6 by H, I and RE; C7 by D and L; C8 by N; C9 by L and O; C10 by RA;
  C11 by RD; T2's new instance by M; D4's by D, P and RC; the state list by C,
  and a state refused outside it by U; the credit rows' count by RC and T,
  under which building C4 raises;
- the fake connection's flows: the one-read bound, both framings, by D, K,
  RC, RH and T; the malformed body's 400 and the cap's 413 by RA and T; the
  body deadline through the wait by D, E, F, K, RC, RH and T; and the reader
  answered with no word of credit never making reading wait by I (its tenth
  failure in the body suite, read by hand, since the runner prints eight).

Found by the mutants, and settled before they were recorded:
- M6.2-T first ended the body suite with a harness error: a credit the core
  refused, an assertion violation of its own, raised out of the check that
  gave it. The checks now take a refused credit as a result and fail by name.
- The fake connection's deadline check was written to read what the timer's
  firing asked for, which is nothing both when no tick comes and when a tick
  asks for nothing, so it could not show a deadline run through the wait. It
  counts the ticks instead, and M6.2-E reddens it.
- M6.2-A and M6.2-B, run on the first build, mutated the reader's field
  (`read-body` granting credit; a whole reader allowed to). The review took the
  field out, so their code is gone, and they are withdrawn with the check they
  reddened. The specs that cut code the review rewrote (G, H, I, O, T) were cut
  again on the new code, with the same meaning.

Not mutated: the entry suite's checks that every callback is answered, in every
state, run over the new state as well; its answers are every state's
else-branch, whose mutants are M2's.

| # | mutated | mutation | observed |
|---|---|---|---|
| M6.2-C | `connection.sls` | awaiting-credit left out of conn-states | connection-table 1 |
| M6.2-D | `connection.sls` | the plan's: the credit ignored, reading goes on regardless | connection-body 3; connection-table 9 |
| M6.2-E | `connection.sls` | the wait keeps the body deadline armed | connection-body 1; connection-table 4 |
| M6.2-F | `connection.sls` | the credit starts reading without arming the body deadline | connection-body 1; connection-table 2 |
| M6.2-G | `connection.sls` | a partial credit starts reading | connection-table 2 |
| M6.2-H | `connection.sls` | a credit past what was handed accepted | connection-table 2 |
| M6.2-I | `connection.sls` | every streaming reader owes credit | connection-body 10; connection-deadlines 1; connection-head 1; connection-originated 1; connection-table 3; contract 2; libhtp-lane 3; message-loop 2; outcome-lane 2; ratchet 1; shell 5 |
| M6.2-K | `connection.sls` | the pieces kept for the answer owe no credit | connection-body 3; connection-table 1 |
| M6.2-L | `connection.sls` | handler-failed changes nothing in awaiting-credit | connection-table 2 |
| M6.2-M | `connection.sls` | read-error changes nothing in awaiting-credit | connection-table 1 |
| M6.2-N | `connection.sls` | bytes-arrived fed in awaiting-credit | connection-table 1 |
| M6.2-O | `connection.sls` | a credit in handling or responding starts reading | connection-table 2 |
| M6.2-P | `connection.sls` | a tick in awaiting-credit answers 408 | connection-table 1 |
| M6.2-RA | `connection.sls` | the wait before the refusal: a feed that met an error waits for the credit owed | connection-body 2; connection-table 2 |
| M6.2-RC | `connection.sls` | the answer's credit ignored | connection-body 3; connection-table 2 |
| M6.2-RD | `connection.sls` | any word after the answer taken | connection-table 2 |
| M6.2-RE | `connection.sls` | a credit while reading goes on is not read | connection-table 1 |
| M6.2-RH | `fake-shell.sls` | the fake connection made on credit answers without it | connection-body 3 |
| M6.2-RI | `connection.sls` | a whole reader's pieces owed on credit | connection-table 1 |
| M6.2-T | `connection.sls` | every credit refused | connection-body 5; connection-table 1 |
| M6.2-U | `connection.sls` | a state outside the eleven accepted | connection-table 1 |

## M6.2, second step — the libuv shell's credit (2026-09-28)

The socket checks and the contract's credit script were written once the
core's rows passed, and each was watched red by a mutant. These ran on the
finished tree against all of its forty suites: the first step's twenty-one
again, which redden more suites here, and the second step's six. Every check
the step added or changed is reddened by at least one mutant:
- the shell suite, on a shell made on credit: the timer stopped while the
  connection waits and stays, by D, E, K, Q, RC and RG; the reader handed the
  whole body a read at a time, by D, K, R, RC, RG and T; a refused credit
  raising to the caller and closing the connection, by RB, and by D, H, K, R,
  RC and RG, under which the second client never waits or the credit is
  taken;
- the contract's credit script: the libuv shell reading what was sent by R
  and T; the bytes the fake wrote by RG and S; the two traces by RG, RH, S and
  T; and the check at the end, now over three shells, by R.

Found by the mutants, and settled before they were recorded:
- M6.2-K, M6.2-R and M6.2-T first ended the shell suite, and the contract
  under R, as exit 2: a credit the core refused raised out of the check that
  gave it. The checks take a refusal as a result now.
- The contract's crediting credits only the script's own connection: under R
  the connection left waiting stayed on the shell, and a later script's waits
  credited it.
- M6.2-T, M6.2-RF and M6.2-RH then still ended the contract as exit 2: its
  replay handed the fake a credit the libuv shell had taken and the fake's
  core refused, and the fake raised it. The replay now records such a refusal
  in the fake's trace, which then differs from the libuv shell's, and the
  four mutants touching it (S, cut again on the new replay, T, RF and RH) were
  run again.

| # | mutated | mutation | observed |
|---|---|---|---|
| M6.2-C | `connection.sls` | awaiting-credit left out of conn-states | connection-table 1 |
| M6.2-D | `connection.sls` | the plan's: the credit ignored, reading goes on regardless | connection-body 3; connection-table 9; shell 3 |
| M6.2-E | `connection.sls` | the wait keeps the body deadline armed | connection-body 1; connection-table 4; shell 1 |
| M6.2-F | `connection.sls` | the credit starts reading without arming the body deadline | connection-body 1; connection-table 2 |
| M6.2-G | `connection.sls` | a partial credit starts reading | connection-table 2 |
| M6.2-H | `connection.sls` | a credit past what was handed accepted | connection-table 2; shell 3 |
| M6.2-I | `connection.sls` | every streaming reader owes credit | connection-body 10; connection-deadlines 1; connection-head 1; connection-originated 1; connection-table 3; libhtp-lane 3; message-loop 2; outcome-lane 2; ratchet 1; shell 5 |
| M6.2-K | `connection.sls` | the pieces kept for the answer owe no credit | connection-body 3; connection-table 1; shell 3 |
| M6.2-L | `connection.sls` | handler-failed changes nothing in awaiting-credit | connection-table 2 |
| M6.2-M | `connection.sls` | read-error changes nothing in awaiting-credit | connection-table 1 |
| M6.2-N | `connection.sls` | bytes-arrived fed in awaiting-credit | connection-table 1 |
| M6.2-O | `connection.sls` | a credit in handling or responding starts reading | connection-table 2 |
| M6.2-P | `connection.sls` | a tick in awaiting-credit answers 408 | connection-table 1 |
| M6.2-Q | `shell.sls` | the timer stops only once no connection is left | shell 1 |
| M6.2-R | `shell.sls` | the libuv shell's credit dispatches nothing | contract 2; shell 4 |
| M6.2-RA | `connection.sls` | the wait before the refusal: a feed that met an error waits for the credit owed | connection-body 2; connection-table 2 |
| M6.2-RB | `shell.sls` | a refused credit neither closes nor raises to the caller | shell 1 |
| M6.2-RC | `connection.sls` | the answer's credit ignored | connection-body 3; connection-table 2; shell 3 |
| M6.2-RD | `connection.sls` | any word after the answer taken | connection-table 2 |
| M6.2-RE | `connection.sls` | a credit while reading goes on is not read | connection-table 1 |
| M6.2-RF | `shell.sls` | the libuv shell answers on credit when not made so | contract 12; shell 5 |
| M6.2-RG | `shell.sls` | the libuv shell made on credit answers without it | contract 2; shell 3 |
| M6.2-RH | `fake-shell.sls` | the fake connection made on credit answers without it | connection-body 3; contract 1 |
| M6.2-RI | `connection.sls` | a whole reader's pieces owed on credit | connection-table 1 |
| M6.2-S | `test-contract.sps` | the contract's replay never gives the fake the credit | contract 2 |
| M6.2-T | `connection.sls` | every credit refused | connection-body 5; connection-table 1; contract 2; shell 1 |
| M6.2-U | `connection.sls` | a state outside the eleven accepted | connection-table 1 |

## M6.3 — a streamed response (2026-09-28)

Four stacked steps, each proven on its own tree: a scratch tree of main with
the step's files, and those of the steps below it, laid in. Each step's
mutants ran against all of that tree's suites, four at a time; the fourth
step's tree is the finished one. A step's mutants are those whose code it
brings and whose checks it holds. Every mutant loaded (no `Exception` in any
report), and every one reddened a suite. The runner prints eight failures a
suite, so where a report cut the list (SA and SC on the serializer, CAA on
the table), the suite was run by hand under the mutant, and the checks it
cut are red there too.

Red before green: `tests/test-limits.sps` stopped at load, exit 255, with
`limits-write-low-water` unbound, before the fields were written;
`tests/test-serializer.sps` with `serialize-piece` unbound; and
`tests/test-connection-table.sps` with `conn-producer` unbound, its stream
rows written before the core's. `tests/test-connection-stream.sps` was
written before the core too, and first run once the core was. The contract's
bare-close script failed its first check when first run: the server's bare
close comes before it reads the client's end, a first, and the script is
marked so. The review's checks (S13 refused, S17, the empty answer's flow,
the shared size lines, the 100-byte piece's size line) were each run red
before their fixes.

Found by the mutants, and settled before they were recorded:
- M6.3-CC, the carried arm dropped, first reddened only the fake-shell flow
  and the table: the socket's and curl's HTTP/1.0 requests did not ask to
  keep the connection, so it closed for that, not for its close-delimited
  body. They now ask, as ab -k asks, and CC reddens both.
- M6.3-CW, M6.3-SB and M6.3-SG ended the contract as exit 2: the core raised
  in both shells, and the fake's raise escaped the replay. The replay now
  records any raise while the fake takes an event, `(raised event
  condition)`, in the fake's trace, as it recorded a refused credit (M6.2),
  and the three fail it by name.
- `producer-event`, in the core (the second step), was checked first in the
  stream suite (the third), so its mutants could not redden its own step.
  The check moved to the table's vocabulary checks, and CR, CS and CS2
  redden it on the second step's tree.
- M6.3-CX, the allocation shape's witness, keeps its growing list in the
  field the pause reads, so it also reddens the entry suite and ends the
  trace lane as exit 2. It is recorded as it ran; the shape is its target.
- The review rewrote the empty piece's row, so M6.3-CG (an empty piece
  written, not skipped) is withdrawn, its code gone, and M6.3-CG2 and
  M6.3-CS2 witness the new rule; CR was cut again on `producer-event`'s new
  text.

### The first step: the write water marks, and the piece framing

Twenty mutants on that tree, each reddening its own suite, and every check
the step added or changed reddened by at least one:
- the limits suite: the two defaults by LA and LB; the drift guard by LA, LB
  and LC; the variables' list by LD; the marks given in bytes by LC and LE;
  marks at or below the high water accepted by LE and LF; above it refused
  by LC, LE and LG; limits-with by name, over the two new fields, by LH;
- the serializer suite: the pieces' eighteen checks by SC (the chunks'), SD
  (the close-delimited ones') and SG (the counts); a piece never copied by SD
  and SE; the size lines shared by SO; the 4 KiB chunk's line by SP; the
  last chunk by SH; the close-delimited end by SI; the refusals by SJ, SK,
  SL and SM.

| # | mutated | mutation | observed |
|---|---|---|---|
| M6.3-LA | `limits.sls` | the high water's default is 262,143 | limits 2 |
| M6.3-LB | `limits.sls` | the low water's default is 65,535 | limits 2 |
| M6.3-LC | `limits.sls` | the environment's high water defaults to 262,145, apart from default-limits | limits 3 |
| M6.3-LD | `limits.sls` | the low water's variable left out of the list | limits 1 |
| M6.3-LE | `limits.sls` | the high water read from the low water's variable | limits 3 |
| M6.3-LF | `limits.sls` | equal water marks refused | limits 1 |
| M6.3-LG | `limits.sls` | a low water above the high water accepted | limits 1 |
| M6.3-LH | `limits.sls` | the low water's field named otherwise, so limits-with cannot replace it by name | limits 1 |
| M6.3-SC | `serializer.sls` | a chunk without its closing CRLF | serializer 12 |
| M6.3-SD | `serializer.sls` | a close-delimited piece framed as a chunk | serializer 7 |
| M6.3-SE | `serializer.sls` | a piece always copied | serializer 1 |
| M6.3-SG | `serializer.sls` | a chunk's byte count leaves out its size line | serializer 4 |
| M6.3-SH | `serializer.sls` | the last chunk without the empty trailer section's CRLF | serializer 1 |
| M6.3-SI | `serializer.sls` | a close-delimited body's end writes the last chunk | serializer 1 |
| M6.3-SJ | `serializer.sls` | an empty piece accepted | serializer 1 |
| M6.3-SK | `serializer.sls` | a piece in any mode accepted | serializer 1 |
| M6.3-SL | `serializer.sls` | a piece past its bytevector's end accepted | serializer 1 |
| M6.3-SM | `serializer.sls` | the end of any mode writes nothing | serializer 1 |
| M6.3-SO | `serializer.sls` | a size line made for every piece, none shared | serializer 1 |
| M6.3-SP | `serializer.sls` | a power of two's size line taken from the next place | serializer 1 |

### The second step: the core streams a producer's body

Forty-seven mutants on that tree: the first step's twenty again, and
twenty-seven for the core and the producer's head. Every check the step
added or changed is reddened by at least one:
- the table: S1, S2 and S4 by CAA; S3 by CD; S5 by CF, CY, SC, SD and SG;
  S6 by CA, the plan's; S7 by CA, CB and CAB; S8 by CB; S9 by CI and SH;
  S10 by CI and SI; S11 by CJ, CI, CAB and SI; S12 by CK, CK2, CL and CN;
  S13 by CG2; S14 by CH; S15 by CN and CQ; S16 by CM and CAB; S17 by CB2;
  the stream rows' count by CC, CE, CW, LH, SA and SB; the sixteen actions
  and no action outside them by CAA; the producer's answer as an event by
  CR, CS and CS2;
- the serializer suite: each of the three producer heads' five checks, the
  fault row and the checked entry by SA, and most of the heads' by SB too;
  a producer given a Content-Length refused by SN.
The step brings both shells' `notify-producer`, whose checks are the
steps' above: the fake shell's (FA) and a waiting producer's asked flag
(CP) are watched in the third step, the libuv shell's and its log (FB, FC)
in the fourth.

| # | mutated | mutation | observed |
|---|---|---|---|
| M6.3-CA | `connection.sls` | the plan's: high water ignored, the producer always asked | connection-table 8 |
| M6.3-CB | `connection.sls` | low water ignored: a waiting producer asked again at the high water | connection-table 2 |
| M6.3-CC | `connection.sls` | M3.2's carried arm dropped: a close-delimited body does not close the connection | connection-table 2 |
| M6.3-CD | `connection.sls` | a producer kept where no body is written | connection-table 2 |
| M6.3-CE | `connection.sls` | the producer not asked for its first piece with the head | connection-table 2 |
| M6.3-CF | `connection.sls` | a piece written with no write deadline armed | connection-table 3 |
| M6.3-CH | `connection.sls` | a piece no one asked for accepted | connection-table 1 |
| M6.3-CI | `connection.sls` | the end does not let the producer go | connection-table 3 |
| M6.3-CJ | `connection.sls` | a close-delimited end with nothing outstanding writes no response | connection-table 1 |
| M6.3-CK | `connection.sls` | a producer's failure after the head answered 500, not a bare close | connection-table 1 |
| M6.3-CL | `connection.sls` | a failure in responding closes with no piece asked for | connection-table 1 |
| M6.3-CM | `connection.sls` | the write deadline armed with no write outstanding while the producer is asked | connection-table 1 |
| M6.3-CN | `connection.sls` | a close does not let the producer go | connection-table 3 |
| M6.3-CQ | `connection.sls` | a piece after the producer was let go refused | connection-table 2 |
| M6.3-CR | `connection.sls` | a producer's piece handed over from its second byte | connection-table 1 |
| M6.3-CS | `connection.sls` | a producer's answer that is neither a bytevector nor the eof object taken as the end | connection-table 1 |
| M6.3-CW | `connection.sls` | a producer's body taken as no body | connection-table 2 |
| M6.3-CY | `connection.sls` | the next piece asked for before the last is written | connection-table 3 |
| M6.3-CAA | `connection.sls` | the action named ask-producer, outside the vocabulary | connection-table 11 |
| M6.3-CAB | `connection.sls` | the stream's rows in no state but responding: a completion ignores the producer | connection-table 5 |
| M6.3-CB2 | `connection.sls` | a waiting producer asked again at the low water alone, past the high water | connection-table 1 |
| M6.3-CG2 | `connection.sls` | the core takes a piece of no bytes, refusing none itself | connection-table 1 |
| M6.3-CK2 | `connection.sls` | a producer's failure after the head changes nothing | connection-table 1 |
| M6.3-CS2 | `connection.sls` | a producer's empty bytevector taken as a piece | connection-table 1 |
| M6.3-LA | `limits.sls` | the high water's default is 262,143 | limits 2 |
| M6.3-LB | `limits.sls` | the low water's default is 65,535 | limits 2 |
| M6.3-LC | `limits.sls` | the environment's high water defaults to 262,145, apart from default-limits | limits 3 |
| M6.3-LD | `limits.sls` | the low water's variable left out of the list | limits 1 |
| M6.3-LE | `limits.sls` | the high water read from the low water's variable | limits 3 |
| M6.3-LF | `limits.sls` | equal water marks refused | limits 1 |
| M6.3-LG | `limits.sls` | a low water above the high water accepted | limits 1 |
| M6.3-LH | `limits.sls` | the low water's field named otherwise, so limits-with cannot replace it by name | connection-table 2; limits 1 |
| M6.3-SA | `serializer.sls` | a producer is a fault, invalid-body | connection-table 2; serializer 19 |
| M6.3-SB | `serializer.sls` | a producer's head counts its body's length as a bytevector's | connection-table 2; serializer 15 |
| M6.3-SC | `serializer.sls` | a chunk without its closing CRLF | connection-table 6; serializer 13 |
| M6.3-SD | `serializer.sls` | a close-delimited piece framed as a chunk | connection-table 1; serializer 8 |
| M6.3-SE | `serializer.sls` | a piece always copied | serializer 1 |
| M6.3-SG | `serializer.sls` | a chunk's byte count leaves out its size line | connection-table 6; serializer 4 |
| M6.3-SH | `serializer.sls` | the last chunk without the empty trailer section's CRLF | connection-table 1; serializer 2 |
| M6.3-SI | `serializer.sls` | a close-delimited body's end writes the last chunk | connection-table 2; serializer 2 |
| M6.3-SJ | `serializer.sls` | an empty piece accepted | serializer 1 |
| M6.3-SK | `serializer.sls` | a piece in any mode accepted | serializer 1 |
| M6.3-SL | `serializer.sls` | a piece past its bytevector's end accepted | serializer 1 |
| M6.3-SM | `serializer.sls` | the end of any mode writes nothing | serializer 1 |
| M6.3-SN | `serializer.sls` | a producer given a Content-Length accepted | serializer 1 |
| M6.3-SO | `serializer.sls` | a size line made for every piece, none shared | serializer 1 |
| M6.3-SP | `serializer.sls` | a power of two's size line taken from the next place | serializer 2 |

### The third step: the fake shell's flows, and the allocation shapes

Fifty mutants on that tree: the second step's forty-seven again, and
M6.3-CP, M6.3-CX and M6.3-FA. Every check the step added is reddened by at
least one:
- the stream suite: HTTP/1.1 by CI, CR, SC and SH among others; HTTP/1.0 by
  CC, SD and SI among others; HEAD and 204 by CD; the 0005 bound by CA, CP
  and CAB; the water marks acting by CA, CB, CP and CAB; the three bare
  closes by CK and CK2, and the answer that is no piece by CS; the empty
  answer by CS2 and CK; the bytevector handed out again by CY; a producer
  in place of a reader, a reader's response streamed, and the GET behind a
  stream by CI and SH; the transport failure and the write deadline by CN,
  and by CA and CE; and every flow by FA, the fake shell's producer never
  called;
- the allocation suite: a stream written whole by CE, CI, CW, CAA, SA and
  SB; a piece's cost however many came before it by CX; a 16 KiB piece by
  SE; a 100-byte piece's own size line by SO and SE. "A streamed piece costs
  something" is the instrument's calibration, as its sibling for a request
  is: it guards the shape against reading 0 = 0, and no mutant is claimed
  for it.

| # | mutated | mutation | observed |
|---|---|---|---|
| M6.3-CA | `connection.sls` | the plan's: high water ignored, the producer always asked | connection-stream 4; connection-table 8 |
| M6.3-CB | `connection.sls` | low water ignored: a waiting producer asked again at the high water | connection-stream 1; connection-table 2 |
| M6.3-CC | `connection.sls` | M3.2's carried arm dropped: a close-delimited body does not close the connection | connection-stream 1; connection-table 2 |
| M6.3-CD | `connection.sls` | a producer kept where no body is written | connection-stream 1; connection-table 2 |
| M6.3-CE | `connection.sls` | the producer not asked for its first piece with the head | connection-allocation 1; connection-stream 2; connection-table 2 |
| M6.3-CF | `connection.sls` | a piece written with no write deadline armed | connection-table 3 |
| M6.3-CH | `connection.sls` | a piece no one asked for accepted | connection-table 1 |
| M6.3-CI | `connection.sls` | the end does not let the producer go | connection-allocation 1; connection-stream 6; connection-table 3 |
| M6.3-CJ | `connection.sls` | a close-delimited end with nothing outstanding writes no response | connection-table 1 |
| M6.3-CK | `connection.sls` | a producer's failure after the head answered 500, not a bare close | connection-stream 4; connection-table 1 |
| M6.3-CL | `connection.sls` | a failure in responding closes with no piece asked for | connection-table 1 |
| M6.3-CM | `connection.sls` | the write deadline armed with no write outstanding while the producer is asked | connection-table 1 |
| M6.3-CN | `connection.sls` | a close does not let the producer go | connection-stream 2; connection-table 3 |
| M6.3-CP | `connection.sls` | a waiting producer asked again, but not marked asked | connection-stream 2 |
| M6.3-CQ | `connection.sls` | a piece after the producer was let go refused | connection-table 2 |
| M6.3-CR | `connection.sls` | a producer's piece handed over from its second byte | connection-allocation 1; connection-stream 12; connection-table 1 |
| M6.3-CS | `connection.sls` | a producer's answer that is neither a bytevector nor the eof object taken as the end | connection-stream 2; connection-table 1 |
| M6.3-CW | `connection.sls` | a producer's body taken as no body | connection-allocation 1; connection-stream 14; connection-table 2 |
| M6.3-CX | `connection.sls` | each write's bytes kept on the connection, appended, as a log would be | connection-allocation 1; connection-entry 1; trace-lane exit 2 |
| M6.3-CY | `connection.sls` | the next piece asked for before the last is written | connection-stream 1; connection-table 3 |
| M6.3-CAA | `connection.sls` | the action named ask-producer, outside the vocabulary | connection-allocation 1; connection-stream 14; connection-table 11 |
| M6.3-CAB | `connection.sls` | the stream's rows in no state but responding: a completion ignores the producer | connection-stream 2; connection-table 5 |
| M6.3-CB2 | `connection.sls` | a waiting producer asked again at the low water alone, past the high water | connection-table 1 |
| M6.3-CG2 | `connection.sls` | the core takes a piece of no bytes, refusing none itself | connection-table 1 |
| M6.3-CK2 | `connection.sls` | a producer's failure after the head changes nothing | connection-stream 4; connection-table 1 |
| M6.3-CS2 | `connection.sls` | a producer's empty bytevector taken as a piece | connection-stream 1; connection-table 1 |
| M6.3-FA | `fake-shell.sls` | the fake shell's producer not called | connection-stream 14 |
| M6.3-LA | `limits.sls` | the high water's default is 262,143 | limits 2 |
| M6.3-LB | `limits.sls` | the low water's default is 65,535 | limits 2 |
| M6.3-LC | `limits.sls` | the environment's high water defaults to 262,145, apart from default-limits | limits 3 |
| M6.3-LD | `limits.sls` | the low water's variable left out of the list | limits 1 |
| M6.3-LE | `limits.sls` | the high water read from the low water's variable | limits 3 |
| M6.3-LF | `limits.sls` | equal water marks refused | limits 1 |
| M6.3-LG | `limits.sls` | a low water above the high water accepted | limits 1 |
| M6.3-LH | `limits.sls` | the low water's field named otherwise, so limits-with cannot replace it by name | connection-stream 3; connection-table 2; limits 1 |
| M6.3-SA | `serializer.sls` | a producer is a fault, invalid-body | connection-allocation 1; connection-stream 15; connection-table 2; serializer 19 |
| M6.3-SB | `serializer.sls` | a producer's head counts its body's length as a bytevector's | connection-allocation 1; connection-stream 15; connection-table 2; serializer 15 |
| M6.3-SC | `serializer.sls` | a chunk without its closing CRLF | connection-stream 7; connection-table 6; serializer 13 |
| M6.3-SD | `serializer.sls` | a close-delimited piece framed as a chunk | connection-stream 1; connection-table 1; serializer 8 |
| M6.3-SE | `serializer.sls` | a piece always copied | connection-allocation 2; serializer 1 |
| M6.3-SG | `serializer.sls` | a chunk's byte count leaves out its size line | connection-stream 12; connection-table 6; serializer 4 |
| M6.3-SH | `serializer.sls` | the last chunk without the empty trailer section's CRLF | connection-stream 7; connection-table 1; serializer 2 |
| M6.3-SI | `serializer.sls` | a close-delimited body's end writes the last chunk | connection-stream 1; connection-table 2; serializer 2 |
| M6.3-SJ | `serializer.sls` | an empty piece accepted | serializer 1 |
| M6.3-SK | `serializer.sls` | a piece in any mode accepted | serializer 1 |
| M6.3-SL | `serializer.sls` | a piece past its bytevector's end accepted | serializer 1 |
| M6.3-SM | `serializer.sls` | the end of any mode writes nothing | serializer 1 |
| M6.3-SN | `serializer.sls` | a producer given a Content-Length accepted | serializer 1 |
| M6.3-SO | `serializer.sls` | a size line made for every piece, none shared | connection-allocation 1; serializer 1 |
| M6.3-SP | `serializer.sls` | a power of two's size line taken from the next place | connection-stream 6; serializer 2 |

### The fourth step: a streamed response on a socket, in the contract, and to curl

Fifty-three mutants on the finished tree: the third step's fifty again, and
M6.3-FB, M6.3-FC and M6.3-FD. Every check the step added or changed is
reddened by at least one:
- the shell suite: the MiB asked for by FB, CW and CAA; the bound while the
  client reads nothing by CA, the plan's, and by FB; the whole MiB read by
  CA, CP and CAB among others; HTTP/1.0 kept alive by CC, SD and SI; the GET
  behind a stream by CI and SC; the bare close by CK, CK2 and CR; its log by
  FC;
- the contract: each script's bytes by FA and FB; its traces by FA, and the
  chunked and HTTP/1.0 scripts' by FB too; what the libuv shell read, by FB
  and CI for those two, and by FB, CK, CK2 and FD for the bare close;
- the clients suite: curl's chunked stream by SC, SH and CR; curl's HTTP/1.0
  stream, which asks to keep the connection, by CC, SD and SI.

| # | mutated | mutation | observed |
|---|---|---|---|
| M6.3-CA | `connection.sls` | the plan's: high water ignored, the producer always asked | connection-stream 4; connection-table 8; shell 2 |
| M6.3-CB | `connection.sls` | low water ignored: a waiting producer asked again at the high water | connection-stream 1; connection-table 2 |
| M6.3-CC | `connection.sls` | M3.2's carried arm dropped: a close-delimited body does not close the connection | clients 2; connection-stream 1; connection-table 2; shell 2 |
| M6.3-CD | `connection.sls` | a producer kept where no body is written | connection-stream 1; connection-table 2 |
| M6.3-CE | `connection.sls` | the producer not asked for its first piece with the head | connection-allocation 1; connection-stream 2; connection-table 2 |
| M6.3-CF | `connection.sls` | a piece written with no write deadline armed | connection-table 3 |
| M6.3-CH | `connection.sls` | a piece no one asked for accepted | connection-table 1 |
| M6.3-CI | `connection.sls` | the end does not let the producer go | clients 6; connection-allocation 1; connection-stream 6; connection-table 3; contract 3; shell 7 |
| M6.3-CJ | `connection.sls` | a close-delimited end with nothing outstanding writes no response | connection-table 1 |
| M6.3-CK | `connection.sls` | a producer's failure after the head answered 500, not a bare close | connection-stream 4; connection-table 1; contract 2; shell 5 |
| M6.3-CL | `connection.sls` | a failure in responding closes with no piece asked for | connection-table 1 |
| M6.3-CM | `connection.sls` | the write deadline armed with no write outstanding while the producer is asked | connection-table 1 |
| M6.3-CN | `connection.sls` | a close does not let the producer go | connection-stream 2; connection-table 3 |
| M6.3-CP | `connection.sls` | a waiting producer asked again, but not marked asked | connection-stream 2; shell 2 |
| M6.3-CQ | `connection.sls` | a piece after the producer was let go refused | connection-table 2 |
| M6.3-CR | `connection.sls` | a producer's piece handed over from its second byte | clients 2; connection-allocation 1; connection-stream 12; connection-table 1; shell 4 |
| M6.3-CS | `connection.sls` | a producer's answer that is neither a bytevector nor the eof object taken as the end | connection-stream 2; connection-table 1 |
| M6.3-CW | `connection.sls` | a producer's body taken as no body | clients 3; connection-allocation 1; connection-stream 14; connection-table 2; contract 5; shell 10 |
| M6.3-CX | `connection.sls` | each write's bytes kept on the connection, appended, as a log would be | connection-allocation 1; connection-entry 1; trace-lane exit 2 |
| M6.3-CY | `connection.sls` | the next piece asked for before the last is written | connection-stream 1; connection-table 3 |
| M6.3-CAA | `connection.sls` | the action named ask-producer, outside the vocabulary | clients 6; connection-allocation 1; connection-stream 14; connection-table 11; contract 4; shell 15 |
| M6.3-CAB | `connection.sls` | the stream's rows in no state but responding: a completion ignores the producer | connection-stream 2; connection-table 5; shell 1 |
| M6.3-CB2 | `connection.sls` | a waiting producer asked again at the low water alone, past the high water | connection-table 1 |
| M6.3-CG2 | `connection.sls` | the core takes a piece of no bytes, refusing none itself | connection-table 1 |
| M6.3-CK2 | `connection.sls` | a producer's failure after the head changes nothing | connection-stream 4; connection-table 1; contract 2; shell 5 |
| M6.3-CS2 | `connection.sls` | a producer's empty bytevector taken as a piece | connection-stream 1; connection-table 1 |
| M6.3-FA | `fake-shell.sls` | the fake shell's producer not called | connection-stream 14; contract 6 |
| M6.3-FB | `shell.sls` | the libuv shell's producer not called | clients 6; contract 10; shell 14 |
| M6.3-FC | `shell.sls` | the libuv shell does not log a producer's raise | shell 1 |
| M6.3-FD | `test-contract.sps` | the contract expects the client's end read after a bare close | contract 1 |
| M6.3-LA | `limits.sls` | the high water's default is 262,143 | limits 2 |
| M6.3-LB | `limits.sls` | the low water's default is 65,535 | limits 2 |
| M6.3-LC | `limits.sls` | the environment's high water defaults to 262,145, apart from default-limits | limits 3 |
| M6.3-LD | `limits.sls` | the low water's variable left out of the list | limits 1 |
| M6.3-LE | `limits.sls` | the high water read from the low water's variable | limits 3 |
| M6.3-LF | `limits.sls` | equal water marks refused | limits 1 |
| M6.3-LG | `limits.sls` | a low water above the high water accepted | limits 1 |
| M6.3-LH | `limits.sls` | the low water's field named otherwise, so limits-with cannot replace it by name | connection-stream 3; connection-table 2; limits 1 |
| M6.3-SA | `serializer.sls` | a producer is a fault, invalid-body | clients 3; connection-allocation 1; connection-stream 15; connection-table 2; contract 1; serializer 19; shell 8 |
| M6.3-SB | `serializer.sls` | a producer's head counts its body's length as a bytevector's | clients 3; connection-allocation 1; connection-stream 15; connection-table 2; contract 5; serializer 15; shell 10 |
| M6.3-SC | `serializer.sls` | a chunk without its closing CRLF | clients 2; connection-stream 7; connection-table 6; serializer 13; shell 3 |
| M6.3-SD | `serializer.sls` | a close-delimited piece framed as a chunk | clients 1; connection-stream 1; connection-table 1; serializer 8; shell 1 |
| M6.3-SE | `serializer.sls` | a piece always copied | connection-allocation 2; serializer 1 |
| M6.3-SG | `serializer.sls` | a chunk's byte count leaves out its size line | connection-stream 12; connection-table 6; contract 4; serializer 4 |
| M6.3-SH | `serializer.sls` | the last chunk without the empty trailer section's CRLF | clients 1; connection-stream 7; connection-table 1; serializer 2; shell 3 |
| M6.3-SI | `serializer.sls` | a close-delimited body's end writes the last chunk | clients 1; connection-stream 1; connection-table 2; serializer 2; shell 1 |
| M6.3-SJ | `serializer.sls` | an empty piece accepted | serializer 1 |
| M6.3-SK | `serializer.sls` | a piece in any mode accepted | serializer 1 |
| M6.3-SL | `serializer.sls` | a piece past its bytevector's end accepted | serializer 1 |
| M6.3-SM | `serializer.sls` | the end of any mode writes nothing | serializer 1 |
| M6.3-SN | `serializer.sls` | a producer given a Content-Length accepted | serializer 1 |
| M6.3-SO | `serializer.sls` | a size line made for every piece, none shared | connection-allocation 1; serializer 1 |
| M6.3-SP | `serializer.sls` | a power of two's size line taken from the next place | clients 2; connection-stream 6; serializer 2; shell 3 |

### The fifth step: small pieces capped, a wrong answer named by its kind (M6.3's second review, 2026-09-29)

Sixty-two mutants on the finished tree: the fourth step's fifty-three again, three of
them re-cut for the code the step rewrote (M6.3-CA, the plan's, now the bytes' test gone
and the writes' kept; M6.3-CB; M6.3-CP), and nine more: six for the writes cap, M6.3-WA
to M6.3-WF, and three for the answer's naming, M6.3-LA2 to M6.3-LC2. Every check the
step added or changed is reddened by at least one:
- the table: S18 by WA, WC and WE, and SG; S19 by WA to WF and CAB; the answer's kind
  and length by LA2, LB2 and LC2; the stream rows' count, now nineteen, by CE;
- the stream suite: the small pieces by WA, WB, WC, WE, WF, CAB and CP, and SG; the
  water marks acting, its asks now read with their writes, by CA, CB, CP and CAB, as
  before;
- the shell suite: the 4,000 rows asked for by FB, CAA, CW, SA and SB; never more than
  64 writes outstanding while the client reads nothing by WA, WC, WE and CAB, and FB
  among others; the rows read whole by WA, WC, WE, CAB, CR, SC and SH among others;
- the allocation suite: a stream written whole by CI, CW, CAA, SA and SB. CE no longer
  reddens it there: the harness now performs a completion that asks for a piece, as a
  shell does, so a producer not asked with the head is asked once the head's write
  completes. The stream and table suites redden CE. A piece's cost however many came
  before it, now over 48 pieces, by CX.

The S19 helper builds its state from the bytes each write counted. With the literal
counts it first had, SG, a chunk's bytes short of its size line, made the stream rows
raise while they were built, and only the group's count failed; SG now fails its rows,
S5 to S8, S17 and S18. CP's shell suite ended early in this run, its raise ending the
suite (exit 2), after the MiB's two checks failed.

| # | mutated | mutation | observed |
|---|---|---|---|
| M6.3-CA | `connection.sls` | the plan's: high water ignored, the producer always asked (re-cut for the writes cap: the bytes' test gone, the writes' kept) | connection-stream 4; connection-table 8; shell 2 |
| M6.3-CB | `connection.sls` | low water ignored: a waiting producer asked again at the high water (re-cut for the writes cap) | connection-stream 1; connection-table 2 |
| M6.3-CC | `connection.sls` | M3.2's carried arm dropped: a close-delimited body does not close the connection | clients 2; connection-stream 1; connection-table 2; shell 2 |
| M6.3-CD | `connection.sls` | a producer kept where no body is written | connection-stream 1; connection-table 2 |
| M6.3-CE | `connection.sls` | the producer not asked for its first piece with the head | connection-stream 2; connection-table 2 |
| M6.3-CF | `connection.sls` | a piece written with no write deadline armed | connection-table 4 |
| M6.3-CH | `connection.sls` | a piece no one asked for accepted | connection-table 1 |
| M6.3-CI | `connection.sls` | the end does not let the producer go | clients 6; connection-allocation 1; connection-stream 6; connection-table 3; contract 3; shell 8 |
| M6.3-CJ | `connection.sls` | a close-delimited end with nothing outstanding writes no response | connection-table 1 |
| M6.3-CK | `connection.sls` | a producer's failure after the head answered 500, not a bare close | connection-stream 4; connection-table 1; contract 2; shell 5 |
| M6.3-CL | `connection.sls` | a failure in responding closes with no piece asked for | connection-table 1 |
| M6.3-CM | `connection.sls` | the write deadline armed with no write outstanding while the producer is asked | connection-table 1 |
| M6.3-CN | `connection.sls` | a close does not let the producer go | connection-stream 2; connection-table 3 |
| M6.3-CP | `connection.sls` | a waiting producer asked again, but not marked asked (re-cut for the writes cap) | connection-stream 3; shell 2 |
| M6.3-CQ | `connection.sls` | a piece after the producer was let go refused | connection-table 2 |
| M6.3-CR | `connection.sls` | a producer's piece handed over from its second byte | clients 2; connection-allocation 1; connection-stream 13; connection-table 1; shell 5 |
| M6.3-CS | `connection.sls` | a producer's answer that is neither a bytevector nor the eof object taken as the end | connection-stream 2; connection-table 2 |
| M6.3-CW | `connection.sls` | a producer's body taken as no body | clients 3; connection-allocation 1; connection-stream 15; connection-table 2; contract 5; shell 13 |
| M6.3-CX | `connection.sls` | each write's bytes kept on the connection, appended, as a log would be | connection-allocation 1; connection-entry 1; trace-lane exit 2 |
| M6.3-CY | `connection.sls` | the next piece asked for before the last is written | connection-stream 1; connection-table 4 |
| M6.3-CAA | `connection.sls` | the action named ask-producer, outside the vocabulary | clients 6; connection-allocation 1; connection-stream 15; connection-table 13; contract 4; shell 18 |
| M6.3-CAB | `connection.sls` | the stream's rows in no state but responding: a completion ignores the producer | connection-stream 3; connection-table 6; shell 3 |
| M6.3-CB2 | `connection.sls` | a waiting producer asked again at the low water alone, past the high water | connection-table 1 |
| M6.3-CG2 | `connection.sls` | the core takes a piece of no bytes, refusing none itself | connection-table 1 |
| M6.3-CK2 | `connection.sls` | a producer's failure after the head changes nothing | connection-stream 4; connection-table 1; contract 2; shell 5 |
| M6.3-CS2 | `connection.sls` | a producer's empty bytevector taken as a piece | connection-stream 1; connection-table 2 |
| M6.3-FA | `fake-shell.sls` | the fake shell's producer not called | connection-stream 15; contract 6 |
| M6.3-FB | `shell.sls` | the libuv shell's producer not called | clients 6; contract 10; shell 18 |
| M6.3-FC | `shell.sls` | the libuv shell does not log a producer's raise | shell 1 |
| M6.3-FD | `test-contract.sps` | the contract expects the client's end read after a bare close | contract 1 |
| M6.3-LA | `limits.sls` | the high water's default is 262,143 | limits 2 |
| M6.3-LB | `limits.sls` | the low water's default is 65,535 | limits 2 |
| M6.3-LC | `limits.sls` | the environment's high water defaults to 262,145, apart from default-limits | limits 3 |
| M6.3-LD | `limits.sls` | the low water's variable left out of the list | limits 1 |
| M6.3-LE | `limits.sls` | the high water read from the low water's variable | limits 3 |
| M6.3-LF | `limits.sls` | equal water marks refused | limits 1 |
| M6.3-LG | `limits.sls` | a low water above the high water accepted | limits 1 |
| M6.3-LH | `limits.sls` | the low water's field named otherwise, so limits-with cannot replace it by name | connection-stream 3; connection-table 2; limits 1 |
| M6.3-LA2 | `connection.sls` | a wrong answer held in the refusal, as before | connection-table 1 |
| M6.3-LB2 | `connection.sls` | a string named without its length | connection-table 1 |
| M6.3-LC2 | `connection.sls` | a list named as a pair | connection-table 1 |
| M6.3-SA | `serializer.sls` | a producer is a fault, invalid-body | clients 3; connection-allocation 1; connection-stream 16; connection-table 2; contract 1; serializer 19; shell 11 |
| M6.3-SB | `serializer.sls` | a producer's head counts its body's length as a bytevector's | clients 3; connection-allocation 1; connection-stream 16; connection-table 2; contract 5; serializer 15; shell 13 |
| M6.3-SC | `serializer.sls` | a chunk without its closing CRLF | clients 2; connection-stream 8; connection-table 8; serializer 13; shell 4 |
| M6.3-SD | `serializer.sls` | a close-delimited piece framed as a chunk | clients 1; connection-stream 1; connection-table 1; serializer 8; shell 1 |
| M6.3-SE | `serializer.sls` | a piece always copied | connection-allocation 2; serializer 1 |
| M6.3-SG | `serializer.sls` | a chunk's byte count leaves out its size line | connection-stream 13; connection-table 8; contract 4; serializer 4 |
| M6.3-SH | `serializer.sls` | the last chunk without the empty trailer section's CRLF | clients 1; connection-stream 8; connection-table 1; serializer 2; shell 4 |
| M6.3-SI | `serializer.sls` | a close-delimited body's end writes the last chunk | clients 1; connection-stream 1; connection-table 2; serializer 2; shell 1 |
| M6.3-SJ | `serializer.sls` | an empty piece accepted | serializer 1 |
| M6.3-SK | `serializer.sls` | a piece in any mode accepted | serializer 1 |
| M6.3-SL | `serializer.sls` | a piece past its bytevector's end accepted | serializer 1 |
| M6.3-SM | `serializer.sls` | the end of any mode writes nothing | serializer 1 |
| M6.3-SN | `serializer.sls` | a producer given a Content-Length accepted | serializer 1 |
| M6.3-SO | `serializer.sls` | a size line made for every piece, none shared | connection-allocation 1; serializer 1 |
| M6.3-SP | `serializer.sls` | a power of two's size line taken from the next place | clients 2; connection-stream 6; serializer 2; shell 3 |
| M6.3-WA | `connection.sls` | the producer asked whatever the writes outstanding | connection-stream 1; connection-table 2; shell 2 |
| M6.3-WB | `connection.sls` | a waiting producer asked again whatever the writes outstanding | connection-stream 1; connection-table 1 |
| M6.3-WC | `connection.sls` | the producer asked at 64 writes outstanding too | connection-stream 1; connection-table 2; shell 2 |
| M6.3-WD | `connection.sls` | a waiting producer asked again only below 16 writes | connection-table 1 |
| M6.3-WE | `connection.sls` | the writes cap 65 | connection-stream 1; connection-table 2; shell 2 |
| M6.3-WF | `connection.sls` | a waiting producer asked again at 17 writes | connection-stream 1; connection-table 2 |

## Write batching, after M6.3 (feat/write-batching, 2026-09-29)

The libuv shell holds a write under 4,096 bytes, its bytes copied as it is held, and
sends a turn's held writes as one write (decided on the owner's word, by form: its own PR
after M6.3's five). Only `(http-server private shell)` changed, with the checks.

Red before green: the finished tests ran against main's shell, its `shell.sls` first on
the library path. Two checks failed, and the rest passed:
- "and the core's writes outstanding are one write request of chez-libuv's: a turn's
  small writes go out as one": 52 writes outstanding while the client read nothing, and
  52 write requests. On the finished tree, 48 writes, and 1 write request;
- "with nothing written, the connection closed and gone, the error logged, the close its
  last event": main issues the head's write at once, so the client read it.
The rows read back from one refilled bytevector, the unread rows' settling, and the
16 KiB pieces' write requests passed on main: they hold what the batching must keep, and
the mutants below watch them fail.

Every mutant ran against all forty-one suites of the finished tree, four at a time. None
failed to load. Where a row names no other suite, the others were green. The runner
prints eight FAIL lines a suite at most, so batch-B's and M4.2-X's shell lists were also
run by hand.

| # | mutated | mutation | observed |
|---|---|---|---|
| batch-A | `shell.sls` | the copy dropped: a held write kept by reference, its segments sent as they are at the flush | shell 1 — "a 200, chunked, each row as it was when handed over, in order". A first cut kept the chunks, so each write it sent ended with an empty span, which libuv 1.52.1 finishes a turn later (`uv__write_req_update` stops on a trailing empty buffer), so a close cancelled it; that cut also reddened the rows' wait and the contract's bare close. Re-cut with no chunks. The finished code never sends an empty span: the core writes only segments with bytes |
| batch-A2 | `shell.sls`, `tests/producers.sls` | calibration: batch-A, and the refilled producer hands out a fresh bytevector each call | SURVIVES, as meant. The refilled rows tell a copy from a reference only because their producer refills one bytevector |
| batch-B | `shell.sls` | nothing sent once the queue is empty: the drain never flushes | clients 11; contract 58; serve 4; shell 55, among them the one-write check, the refilled rows' two, and the unread rows' wait, close and settling |
| batch-C | `shell.sls` | the writes held not sent before a close | contract 2 — the bare close's read and its bytes, `(wrong-length 0)`; shell 1 — "after the head and the piece: the body cut short, no status written" |
| batch-D | `shell.sls` | the writes held not sent before a shutdown | SURVIVES: a scope statement. The core asks for a shutdown only once every write has completed (decision 0011's staged close, `response-written`), and a held write is outstanding, so none is held then. The flush keeps a held write from following the half-close, should that change |
| batch-E | `shell.sls` | the writes held not sent before a larger write | shell 1 — the MiB's "every piece in order": its head, held, went out after the first 16 KiB piece |
| batch-F | `shell.sls` | every write held, however large | shell 1 — "and each of the core's writes outstanding is a write request of chez-libuv's: a piece of 16 KiB is not held" |
| batch-G | `shell.sls` | no write held | shell 2 — the one-write check, and "with nothing written, ...", the head sent at once, as on main |
| batch-H | `shell.sls` | a failed write reports its read error alone, settling none of the writes it carried | shell 3 — the unread rows' settling, and M4.2's two "as a read error, then settled" |
| batch-I | `shell.sls` | a failed write settles only the first write it carried | shell 1 — the unread rows' settling |
| batch-J | `shell.sls` | the writes a write carried reported completed last first | contract 3 — the three streamed scripts' traces, `(differs-at 29 libuv (event (write-completed 5)) fake (event (write-completed 84)))`: the fake reports each completion in the order written |
| batch-K | `shell.sls` | what is held not dropped when a dispatch raises | shell 1 — "with nothing written, ... the close its last event": the held head, sent at the next dispatch to the closed handle, failed, and its read error and completion came after `closed` |
| batch-L | `shell.sls` | a new chunk the write's own length, never twice the last's | SURVIVES: a scope statement. The chunks' growth changes how many chunks, allocations and spans a turn's write takes, never its bytes or their order |
| batch-M | `shell.sls` | a write that fits the last chunk copied over its start | clients 2; contract 2; shell 6 |
| batch-N | `shell.sls` | a chunk closed at its length, not where its bytes end | shell 2 — the rows' and the refilled rows' bodies |
| batch-O | `tests/fake-shell.sls` | the fake shell makes a write's wire when its writes are read, not as it performs the write | connection-stream 1 — "a producer that hands out one bytevector again: each piece written as it was when handed over", whose producer is now `(producers)`'s refilled one |
| M4.2-W1 | `shell.sls` | re-cut: a failed write settled before its read error | shell 2 — the two "as a read error, then settled" |
| M4.2-W2 | `shell.sls` | re-cut: a write's completion reads its error as success | shell 4 — the unread rows' settling, the two "as a read error, then settled", and "a write refused when it is issued closes the connection" |
| M4.2-W3 | `shell.sls` | re-cut: a write refused at the call is not caught | shell 2 — "a write refused when it is issued closes the connection" and its order check. That write is held now, and sent once the drain empties; a held write and a larger one are sent through one guarded call, `send!`, so the check holds both |
| M4.2-R | `shell.sls` | re-cut: the write's completion keeps its segments | shell 1 — "and nothing holds the response's body" |
| M4.2-X | `shell.sls` | re-run: a raise from the outermost dispatch goes on without closing the connection | shell 10, both of the held write's bug checks among them |

Every check this change added or changed is reddened by one mutant at least:
- the rows' one write request by B, G and M; the 16 KiB pieces' write requests by F;
- the refilled rows read whole by B, and each row as it was handed over by A, B, M and N;
- the unread rows' wait and close by B, and their settling by B, H, I and M4.2-W2;
- the bug once a write is held: the stream's end by M4.2-X, and nothing written, the
  close the last event, by G, K and M4.2-X;
- the stream suite's bytevector handed out again, its producer shared now, by O.

### After the PR's review (2026-09-29)

A /code-review high of PR #79 found seven, none a correctness bug; a deeper review of
three, on the owner's ask, measured each, and the owner chose by form: what is held goes
out before a drain's first producer call (`producer-called?`), `hold!` copies with a
named let, a check for a turn's one write refused at the call, and the docs' cutoff.

Red before green: on the first commit's shell, the head-first check failed, its
producer's first call finding no write request more than the handler had: the head was
still held. The refused turn's two checks passed there, and are watched to fail by S and
M4.2's W2 and W3 below.

Twenty-five mutants on the fixed tree against all forty-one suites, four at a time: the
twenty-one before, three of them re-cut for the named let (batch-A, batch-A2, batch-M),
and four new, batch-P to batch-S. None failed to load. One more survived than before:
batch-E, the writes held not sent before a larger write. The MiB's check had killed it,
its head held when the first 16 KiB piece was written; now the head goes out before the
producer is first called, so nothing is held then. A check of pieces of 100 bytes and
5,000 in turn, `/mixed`, was added, and batch-E, run again with it, is killed.

| # | mutated | mutation | observed |
|---|---|---|---|
| batch-A | `shell.sls` | re-cut for the named let: the copy dropped, a held write kept by reference | shell 1 — the refilled rows, each as handed over |
| batch-A2 | `shell.sls`, `tests/producers.sls` | calibration: batch-A, and the refilled producer hands out a fresh bytevector each call | SURVIVES, as meant |
| batch-B | `shell.sls` | nothing sent once the queue is empty | clients 11; contract 58; serve 4; shell 58 |
| batch-C | `shell.sls` | the writes held not sent before a close | contract 3 — the bare close's read, bytes and traces; shell 1 — the bare close's body cut short |
| batch-D | `shell.sls` | the writes held not sent before a shutdown | SURVIVES: a scope statement, as before |
| batch-E | `shell.sls` | the writes held not sent before a larger write | shell 1 — "a 200, chunked, the pieces in the order handed over", `/mixed` (the check added for it; without it, SURVIVED) |
| batch-F | `shell.sls` | every write held, however large | shell 1 — the 16 KiB pieces' write requests |
| batch-G | `shell.sls` | no write held | shell 2 — the rows' one write request, and the held write's bug check |
| batch-H | `shell.sls` | a failed write reports its read error alone | shell 4 — both rows' settling checks and M4.2's two |
| batch-I | `shell.sls` | a failed write settles only the first write it carried | shell 2 — both rows' settling checks |
| batch-J | `shell.sls` | the writes a write carried reported completed last first | contract 2 — the two streamed scripts' traces |
| batch-K | `shell.sls` | what is held not dropped when a dispatch raises | shell 1 — the held write's bug check |
| batch-L | `shell.sls` | a new chunk the write's own length | SURVIVES: a scope statement, as before |
| batch-M | `shell.sls` | re-cut for the named let: a write that fits the last chunk copied over its start | clients 1; contract 1; shell 6, the head-first check among them |
| batch-N | `shell.sls` | a chunk closed at its length | clients 2; contract 2; shell 5 |
| batch-O | `tests/fake-shell.sls` | the fake shell makes a write's wire when its writes are read | connection-stream 1 |
| batch-P | `shell.sls` | nothing sent before the drain's first producer call | shell 1 — "the second stream's head went out before its producer was first called, one write request" |
| batch-Q | `shell.sls` | what is held sent before every producer call | shell 1 — the rows' one write request |
| batch-R | `shell.sls` | a drain starts with the last one's producer calls counted, so only a connection's first stream sends its head first | shell 1 — the head-first check, on the stream behind another |
| batch-S | `shell.sls` | a write refused at the call settles only the first write it carried | shell 1 — the refused turn's settling |
| M4.2-W1 | `shell.sls` | a failed write settled before its read error | shell 2 |
| M4.2-W2 | `shell.sls` | a write's completion reads its error as success | shell 5, both rows' settling checks among them |
| M4.2-W3 | `shell.sls` | a write refused at the call is not caught | shell 4 — the refused turn's close and settling, and M4.2's refused write's two |
| M4.2-R | `shell.sls` | the write's completion keeps its segments | shell 1 |
| M4.2-X | `shell.sls` | a raise from the outermost dispatch goes on without closing the connection | shell 10 |

Every check the fixes added is reddened by one mutant at least: the two streams on one
connection read by B, and the second's head-first check by P, R, M and B; the refused
turn's close by M4.2-W3, and its settling by S, H, I, M4.2-W2 and M4.2-W3; the mixed
pieces read to the stream's end by B, and in order by E and B. B's shell list was run by
hand against the finished tests, the mixed check among them: 60 failures.

## M6.4 — Expect, trailers, and the exit's files (feat/m6.4-expect-trailers, 2026-09-29)

Red before green, each new suite and check run against main's source (`git archive main
src`) with the finished tests:
- the table: 24 failures, the Expect rows E1, E3 to E6 and E8, and the trailer and
  extension rows F2, F5, F6 and F7's two answered instances; the rest are guards, watched
  red by the mutants below;
- `tests/test-connection-expect.sps`: 8 of its 14, the 100 and its deadline, the trailer
  431s and the extensions' 413;
- the shell suite: the two checks of a client that waits for the 100, which never came
  within the cap; the refusal's two passed there;
- curl's: held past the cap, 24 s, waiting a minute for a 100 main never sends;
- the originated suite: its coverage check, once the reason existed with no row; the two
  rows then failed on the shape of a refusal read as it arrives (a `read-stop` after the
  status), where both requests arrive in the head's delivery, so what they meet waits for
  the handler's answer, reading stopped already (`kept`);
- the lane: 05's expectation, no 100 on main.
`field-lists?` is new, so the headers suite does not load against main; its three
checks are watched red by M to R and AG.

Forty mutants on the finished tree against all forty-two suites, four at a time
(thirty-nine by `mut.py`, AK by hand). None failed to load. The first run, thirty-three,
left two survivors, J and K: the 100's completion ignored in `handling` and in
`awaiting-credit` instead of settled leaves the phase and the actions as they were, and
E8 read only those. E8 now runs through M3.3's accounting step, which reads the writes
and bytes outstanding after the completion, and J and K, run again, redden it; B, I and
AF, which reddened E8 before, were run again against its new form and still do. Then
AG, AH, AI, AJ, AL and AK were added for checks no mutant had reddened (the other
expectation's flow, and the four counts), and AM for the refusal's socket check.

Three contract scripts were written and taken out before the run: a chunked body's
extension and trailer within their limits, a trailer past them and extensions past
them. The two shells share the core, and differ in nothing those scripts exercise: no
fault of either shell could redden them, and both would agree on any fault of the core.
A fourth, an Expect head answered at once, went after the run for the same reason: no
mutant reddened its three checks. What the contract keeps for M6.4 is the one new thing a
shell does, a write while the connection still reads.

| # | mutated | mutation | observed |
|---|---|---|---|
| M6.4-A | `connection.sls` | the plan's: the 100 written with the head | connection-expect 4; connection-table 12 — E1 (5), E3 (3), E4 (2), E5, E6; libhtp-lane 2 — 05 and 99; ratchet 1; shell 1 — the refusal's "no 100" |
| M6.4-B | `connection.sls` | the 100 never written | clients 1 — curl's; connection-expect 4; connection-table 11 — E3 (3), E4 (2), E5, E6, E8 (4); libhtp-lane 1 — 05; ratchet 1; shell 2 — the waiting client's two |
| M6.4-C | `connection.sls` | the expectation met on HTTP/1.0 too | connection-expect 1 — HTTP/1.0's; connection-table 1 — E2 |
| M6.4-D | `connection.sls` | the expectation met with no body too | connection-expect 1 — no body's; connection-table 1 — E2 |
| M6.4-E | `connection.sls` | the body deadline armed at an Expect head anyway | connection-table 5 — E1 (5) |
| M6.4-F | `connection.sls` | the 100 arms no body deadline | connection-expect 1 — the 408; connection-table 3 — E3 (3) |
| M6.4-G | `connection.sls` | the 100 written after the pieces kept | connection-expect 2; connection-table 5 — E3, E4 (2), E5, E6 |
| M6.4-H | `connection.sls` | the 100 written before a response given instead of a reader too | connection-expect 1; connection-table 1 — E7; libhtp-lane 1 — 99; ratchet 1; shell 1 |
| M6.4-I | `connection.sls` | the 100's completion not settled in `body` | clients 4 — the ends' counts; connection-expect 4; connection-table 1 — E8; contract 2 — the Expect script's close, and the end's; libhtp-lane 1; ratchet 1; shell 3 — the ends' counts |
| M6.4-J | `connection.sls` | the 100's completion not settled in `handling` | connection-table 1 — E8 (SURVIVED before E8 read the writes outstanding) |
| M6.4-K | `connection.sls` | the 100's completion not settled in `awaiting-credit` | connection-table 1 — E8 (likewise) |
| M6.4-L | `connection.sls` | a reader past its cap sent the 100 and read, not refused | connection-table 1 — E7 |
| M6.4-M | `headers.sls` | the expectation matched with case | connection-table 1 — E1; headers 1 |
| M6.4-N | `headers.sls` | the first field of the name decides | headers 1 — "over any of its lines" |
| M6.4-O | `headers.sls` | an element matched by its prefix | connection-table 1 — E2; headers 1 — "…and nothing else" |
| M6.4-P | `headers.sls` | an element's OWS not trimmed | connection-table 2 — E1 (2); headers 2 |
| M6.4-Q | `headers.sls` | the list not split at its commas | connection-table 1 — E1; headers 2 |
| M6.4-R | `headers.sls` | a span's list read to its bytevector's end | clients 1; connection-expect 4; headers 1 — "honouring its bounds"; libhtp-lane 1; ratchet 1; shell 2 |
| M6.4-S | `connection.sls` | trailer fields counted against no limit, as before | connection-expect 3 — the three 431s; connection-originated 1 — the trailer's 431; connection-table 6 — F2 (4), F6, F7 |
| M6.4-T | `connection.sls` | the trailers counted with the head's fields | connection-expect 2 — the full section served, and the value's 431; connection-table 2 — F3 (2) |
| M6.4-U | `connection.sls` | a trailer's size not started again at its name's end | connection-expect 2; connection-table 1 — F1 |
| M6.4-V | `connection.sls` | a trailer's size not started again at its value's end | connection-table 2 — F2, F3 |
| M6.4-W | `connection.sls` | the field count refused at the limit, not past it | connection-expect 2; connection-head 1 — "max-header-count headers pass"; connection-table 1 — F3 |
| M6.4-X | `connection.sls` | chunk extensions counted against no limit, as before | connection-expect 1 — the 413; connection-originated 1; connection-table 5 — F5 (3), F6, F7 |
| M6.4-Y | `connection.sls` | chunk extensions counted a chunk at a time | connection-expect 1; connection-table 2 — F5's two across chunks |
| M6.4-Z | `connection.sls` | chunk extensions refused at 16 KiB, not past it | connection-expect 1 — 16 KiB served; connection-table 2 — F4 (2) |
| M6.4-AA | `connection.sls` | an extension's value not counted | connection-expect 1; connection-originated 1; connection-table 1 — F5 |
| M6.4-AB | `decisions.sls` | chunk extensions past 16 KiB answered 400 | connection-expect 1; connection-originated 1; connection-table 2 — F6, F7 |
| M6.4-AC | `tests/libhtp-lane.sls` | every stream delivered with CRLF | libhtp-lane 2 — every other stream as cut, and the scope |
| M6.4-AD | `tests/libhtp-lane.sls` | the Expect streams delivered as cut | libhtp-lane 4 — 05, 99, the scope, and the conversion's check; ratchet 1 |
| M6.4-AE | `tests/libhtp-lane.sls` | 99's handler reads, as every other stream's | libhtp-lane 1 — 99; ratchet 1 |
| M6.4-AF | `serializer.sls` | the 100 without its blank line | clients 1; connection-expect 1 — the 100 as read; connection-table 11 — E3 (3), E4 (2), E5, E6, E8 (4); shell 2 |
| M6.4-AG | `headers.sls` | any Expect value taken for 100-continue | connection-expect 1 — another expectation's; connection-table 3 — E2 (3); headers 2 |
| M6.4-AH | `tests/libhtp-lane.sls` | the lane loses 99-expect-100.t's expectation | libhtp-lane 2 — "fourteen streams have an expectation", and the scope; ratchet 1 |
| M6.4-AI | `tests/test-connection-table.sps` | E8 loses its instances | connection-table 1 — "the 100's accounting row has a test" |
| M6.4-AJ | `tests/test-connection-table.sps` | F7 loses its instances | connection-table 1 — "all 7 trailer and extension rows have a test" |
| M6.4-AK | `tests/ratchet.txt`, by hand | 05-expect.t marked not-yet (the suite reads the file by path, so it ran in a scratch root of symlinks to the tree, the one file a copy) | ratchet 3 — "14 passing", "88 not-yet", and a violation, "marked not-yet but now passes" |
| M6.4-AL | `tests/test-connection-table.sps` | E1 loses its instances | connection-table 1 — "all 7 Expect rows have a test" |
| M6.4-AM | `connection.sls` | an Expect head answered at once keeps the connection, its body never sent | connection-expect 1 — the response's; connection-table 1 — E7; libhtp-lane 1 — 99; ratchet 1; shell 2 — the refusal's two |
| M6.4-SH1 | `shell.sls` | the libuv shell writes only while responding or closing | clients 1 — curl's; contract 4 — the Expect script's three, and the end's; shell 5 — the waiting client's two, and the ends' counts |

Every check M6.4 added or changed is reddened by one mutant at least:
- the table: E1 by A, E, M, P, Q; E2 by C, D, O, AG; E3 by A, B, F, G, AF; E4 to E6 by
  A, B, G, AF; E7 by H, L, AM; E8 by B, I, J, K, AF; F1 by U; F2 by S, V; F3 by T, V, W;
  F4 by Z; F5 by X, Y, AA; F6 and F7 by S, X, AB; the three counts by AI, AJ and AL;
- the headers suite's three by M to R and AG;
- the flows' fourteen: the streaming reader's and the chunked one's by A, B, G, I, R;
  the 100 as read by B, I, R, AF; a response instead by A, H, AM; HTTP/1.0's by C; no
  body's by D; another expectation's by AG; the 408 by A, B, F, I, R; the full trailer
  section served by T, U, W; the section past by S, U, W; the fourth field by S; the value
  past by S, T; 16 KiB of extensions served by Z; a byte more by X, Y, AA, AB;
- the shell's four: the waiting client's two by B, R, AF, SH1, and the refusal's two by
  AM, "no 100" by A and H too;
- the contract's Expect script, its three checks by SH1, its close by I;
- curl's by B, R, AF, SH1;
- the originated suite's two rows by S, and by X, AA, AB;
- the lane's: the count by AH, the scope by AC, AD, AH, the delivery's two by AC and AD,
  05 by A, B, I, R, AD, 99 by A, H, AD, AE, AM; the ratchet's counts by AK, and its
  violations by the lane's mutants.

### After the PRs' review (2026-09-29)

A /code-review high of PRs #80 to #82 found five. On the owner's word, by form, the 100
still goes first before a refusal the head's feed met, and the finding that would have
left it out is withdrawn; the cap case beside it is fixed: `accept-reader` refuses a
reader whose cap the declared length passes before the 100, and `read-with` one whose cap
the body met so far passes, after it.

Red before green: on #80's first commit, the flows' chunked body past a whole reader's cap
failed, and so did E6's two new instances, in body and, the body ended, in handling. The
flows' declared length past the cap passed there, and is watched red by R2.

Two mutants on the fixed tree (#82's, 1,335 expected passes) against all forty-two
suites, two at a time, each reddening only the checks it was cut for:

| Mutant | Where | Change | Reddens |
|---|---|---|---|
| M6.4-R1 | `connection.sls` | the body met so far checked before the 100, as before the fix | connection-expect 1 — the chunked body past the cap; connection-table 2 — E6's instances in body and in handling |
| M6.4-R2 | `connection.sls` | the declared length checked after the 100, with the body met | connection-expect 1 — the declared length past the cap; connection-table 1 — E7 |

Forty-two mutants in all; none survives.

## The padding PR (fix/padding-limits, 2026-09-30)

What the parser reads and hands the core no span of is held to limits: the whitespace
before a value counts with it, 431; more than two empty lines before a request line,
more than one space between its parts, and a chunk size of more than 16 hex digits, 400.
Every event callback carries the parser's position, and the core measures each run by it.

Red before green:
- The entry suite, on the vocabulary step against main's core: an event callback without
  the parser's position, and on-headers-complete without it, were accepted, two failures.
  A span callback given a position in place of its span was refused there already (an
  arity error), and is watched red by P-EA.
- The table's padding rows on the vocabulary step, whose core reads no position: sixteen
  instances failed, every refusal. The rows within a limit passed there, and are watched
  red by the mutants that tighten a limit (P-G, P-H2, P-I2, P-OC, P-S, P-S2, P-S3, P-T,
  P-U).
- The flows suite against main's core and adapter: twelve of fifteen failed, the work a
  run costs among them. The three main serves too are watched red by mutants.

The first run, thirty-five mutants on the tree before its last changes, left two
survivors, and both changed the tree:
- **P-C**, a delivery's base never set: the fake shell hands every read as a slice of one
  bytevector indexed from the connection's first byte, so a base of 0 was right by
  accident. The flows now hand each read in a bytevector of its own, at index 3, as the
  shells hand a read over.
- **P-D**, the pending rest's base not set anew: equivalent. The rest a pause keeps is its
  delivery's own bytes, from where the parser stopped, so its base is the delivery's; the
  line was removed, and `feeding!` says why.

Two more were weak, reddening only the table: P-AH, the empty lines judged at no read's
end, and P-AE, the section judged before the value there. The flows gained the work a run
costs, a megabyte of each fed to the parser one 16 KiB read, which P-AH now reddens; P-AE
changes only which of two 431s a read's end names, and its row is its check.

Forty-four mutants on the finished tree (1,388 expected passes) against all forty-three
suites, four at a time: thirty-six, then eight for the checks the thirty-six left unred,
the rows within a limit and the entry's shapes. Cutting the three layers found one more
gap: nothing checked that a chunk size's digits are left to the parser's error, only the
request line's, so G12 gained that instance, and P-Q2 reddens it (against the table and
the flows). None survives, and every check this PR added or changed is reddened by at
least one.

| Mutant | Where | Change | Reddens (suite, failures) |
|---|---|---|---|
| P-A | `adapter` | the adapter passes 0 for an event's position | clients 9, connection-allocation 5, connection-body 29, connection-deadlines 5, connection-expect 16, connection-head 50, connection-linger 9, connection-originated 22, connection-padding 12, connection-response 24, connection-retention 8, connection-stream 16, contract 1, libhtp-lane 14, message-loop 13, outcome-lane 3, ratchet 1, serve 3, shell 54, trace-lane 2, view 13 |
| P-B | `adapter` | the adapter passes 0 for on-headers-complete's position | connection-body 12, connection-expect 8, connection-head 1, connection-originated 2, connection-padding 5, libhtp-lane 3, outcome-lane 1, ratchet 1, shell 1, trace-lane 1 |
| P-C | `connection` | a delivery's base is not set as it is fed | connection-padding 12 |
| P-C2 | `connection` | a delivery's base ignores where its bytes start | connection-body 26, connection-expect 15, connection-head 48, connection-padding 11, message-loop 10, outcome-lane 4, ratchet 1 |
| P-E | `connection` | a read's bytes are not counted | connection-expect 2, connection-head 2, connection-padding 9, connection-table 7 |
| P-F | `connection` | five bytes of empty lines pass | connection-padding 1, connection-table 3 |
| P-G | `connection` | three bytes of empty lines are the most | connection-padding 1, connection-table 3, trace-lane 1 |
| P-H | `connection` | two spaces after the method pass at the target | connection-originated 1, connection-padding 1, connection-table 1 |
| P-H2 | `connection` | one space after the method is refused at the target | clients 9, connection-allocation 5, connection-body 29, connection-deadlines 5, connection-entry 6, connection-expect 16, connection-head 50, connection-linger 9, connection-originated 21, connection-padding 11, connection-response 24, connection-retention 8, connection-stream 16, connection-table 120, contract 1, libhtp-lane 14, message-loop 13, outcome-lane 3, ratchet 1, serve 3, shell 54, trace-lane 2, view 13 |
| P-I | `connection` | a space after the target passes at the protocol | connection-padding 1, connection-table 1 |
| P-I2 | `connection` | the protocol right after the target's space is refused | clients 9, connection-allocation 5, connection-body 29, connection-deadlines 5, connection-expect 16, connection-head 49, connection-linger 9, connection-originated 20, connection-padding 11, connection-response 24, connection-retention 8, connection-stream 16, connection-table 4, contract 1, libhtp-lane 14, message-loop 13, outcome-lane 3, ratchet 1, serve 2, shell 54, trace-lane 2, view 13 |
| P-J | `connection` | the run after the target opens at a line end too | outcome-lane 2, ratchet 1 |
| P-K | `connection` | the target's run is not opened, so its end is unknown | connection-padding 1, connection-table 2 |
| P-L | `connection` | the whitespace is not added to the section | connection-expect 1, connection-head 1, connection-padding 1, connection-table 1 |
| P-M | `connection` | the whitespace is not kept with the value | connection-expect 1, connection-head 1, connection-padding 4, connection-table 1 |
| P-N | `connection` | a value's limit ignores its whitespace | connection-expect 1, connection-head 1, connection-padding 4, connection-table 1 |
| P-O | `connection` | a head's value-complete keeps its whitespace for the next name | connection-expect 4, connection-table 2 |
| P-O2 | `connection` | a trailer's value-complete keeps its whitespace for the next name | connection-table 1 |
| P-P | `connection` | empty lines refused at a read's end are answered from idle | connection-table 1 |
| P-Q | `connection` | the request line's and the digits' runs are judged at the parser's error too | connection-table 1 |
| P-R | `connection` | the whitespace is not judged at the parser's error | connection-table 1 |
| P-S | `connection` | no slack for the byte that ends a size's digits at a read's end | connection-padding 1, connection-table 1 |
| P-S2 | `connection` | one space after the method is past its limit at a read's end | connection-body 26, connection-expect 15, connection-head 48, connection-padding 9, connection-table 1, message-loop 9, outcome-lane 4, ratchet 1 |
| P-S3 | `connection` | whitespace bringing the section to its limit is past it at a read's end | connection-table 1 |
| P-T | `connection` | on-chunk-header counts the size line's LF as a digit | connection-padding 1, connection-table 1 |
| P-U | `connection` | an extension's first byte counts its `;` as a digit | connection-padding 1, connection-table 1 |
| P-V | `connection` | on-chunk-complete opens no size line | connection-padding 3, connection-table 4 |
| P-W | `connection` | a chunked head opens no size line | connection-originated 1, connection-padding 1, connection-table 1 |
| P-X | `connection` | on-message-complete opens no empty-lines run | connection-padding 1, connection-table 1 |
| P-Y | `connection` | on-message-begin judges no empty lines | connection-originated 1, connection-padding 2, connection-table 2 |
| P-Z | `connection` | the empty-lines refusal at on-message-begin keeps no reason | connection-originated 1, connection-padding 2 |
| P-AA | `connection` | a run is never closed | connection-body 26, connection-deadlines 1, connection-expect 15, connection-head 47, connection-originated 2, connection-padding 9, connection-table 1, libhtp-lane 1, message-loop 9, outcome-lane 4, ratchet 1, shell 2, trace-lane 2 |
| P-AB | `connection` | a trailer opens no whitespace run | connection-expect 2, connection-padding 3, connection-table 1 |
| P-AC | `connection` | a head's field opens no whitespace run | connection-head 2, connection-padding 5, connection-table 3 |
| P-AD | `connection` | the method opens no run | connection-originated 1, connection-padding 3, connection-table 4 |
| P-AE | `connection` | the section is judged before the value at a read's end | connection-table 2 |
| P-AF | `decisions` | a chunk size's digits past 16 are refused 413 | connection-originated 1, connection-padding 2, connection-table 1 |
| P-AG | `connection` | 17 digits pass at the callback | connection-originated 1, connection-padding 1, connection-table 4 |
| P-AH | `connection` | a read's end in idle judges no empty lines | connection-padding 1, connection-table 1 |
| P-AI | `connection` | no run is judged at a read's end | connection-padding 1, connection-table 7 |
| P-EA | `connection` | an event entry takes a span callback's name | connection-entry 4 |
| P-EB | `connection` | an event callback enters without its position | connection-entry 1 |
| P-EC | `connection` | on-headers-complete enters without its position | connection-entry 1 |
| P-OC | `connection` | the colon counts with the whitespace | connection-expect 4, connection-head 2, connection-padding 4, connection-table 7 |
| P-Q2 | `connection` | a chunk size's digits judged at the parser's error | connection-table 1 (G12's digits instance) |

Forty-five mutants for this PR; none survives.

## The padding PR's review (2026-09-30)

A /code-review max found 15, and the owner asked for all fixed, seven choices by form
(the ledger). What changed: the spaces after a target are counted however it ends, and a
request line with no version lets them go at its first field; a chunk's extensions count
a byte for each `;` and `=`; a 431 names the limit its bytes passed first; an empty
value's line end does not count; a parser-result carries the parser's own count; each
run's limit is stated once (`run-limits`); and the table's state builder refuses a
refused setup step.

Red before green: on f0950e2, before any edit, the padding suite's six new and changed
checks failed and its other thirteen passed. Every new and changed check in every suite
is watched red by at least one mutant below, mapped by its name in the runner's
reports: the padding suite's six by P-J1/P-J2 (no version), R-W1/R-W2 (an empty value),
P-AE/P-AE2/P-AE3 (both limits), R-X1/R-X2/R-X3 (empty extensions at 16 KiB), R-X1 (a
megabyte of them) and R-X1/R-X2/R-X3/R-G3 (the work check); the table's G9, G10, G12, G13, G14, F4, F5 and F3
by P-J2/R-W2, P-AE, P-Q, P-J1, R-G1/R-G2, R-X3, R-X1/R-X2 and R-F3a/R-F3b; the entry's
four by T-E14, P-EB, R-EF and R-K8; the row count by T-G; the setup guard by T-F3.

Every mutant was run again on the reviewed tree, all forty-three suites each. Of the
PR's forty-five, twenty-two applied as written; twenty-one were cut again against the
rewritten text (P-AE, P-AH, P-AI, P-E, P-H, P-H2, P-I, P-I2, P-L, P-M, P-N, P-Q, P-Q2,
P-R, P-S, P-S2, P-S3, P-T, P-U, P-Y, P-Z); and two were withdrawn: P-J, whose mutation,
the run after the target opening at a line end too, is now the rule, and P-K, the
target's own run, which is gone. Twenty-two are new: P-AE2, P-AE3, P-E2, P-J1 to P-J3,
thirteen R- mutants of the fixes, and three T- mutants of the suites' own guards and
counts. P-J2, no slack for a versionless line's CR, also reddens the outcome lane: llhttp's
"No HTTP version" fixture, a read ending after its CR.

One survived the first run: **R-W3**, an empty value's pad allowed below 0. The pad goes
below 0 only where the parser ends an empty value at a byte it then refuses, and its error
comes next, so no outcome could show it. The clamp went, and its comment says why; R-W1
and R-W4, which quoted its line, were cut again and run again with the four mutants that
touch the same procedure (P-L, P-M, P-N, P-OC), and R-F3a and R-F3b were added for row
F3, whose head changed.

| Mutant | Where | Change | Reddens (suite, failures) |
|---|---|---|---|
| P-A | `adapter` | the adapter passes 0 for an event's position | clients 9, connection-allocation 5, connection-body 29, connection-deadlines 5, connection-head 50, connection-originated 22, connection-padding 17, connection-retention 8, contract 1, libhtp-lane 14, message-loop 13, outcome-lane 3, ratchet 1, serve 3, shell 54, trace-lane 2 |
| P-B | `adapter` | the adapter passes 0 for on-headers-complete's position | connection-body 12, connection-expect 8, connection-head 1, connection-originated 2, connection-padding 9, libhtp-lane 3, outcome-lane 1, ratchet 1, shell 1, trace-lane 1 |
| P-C | `connection` | a delivery's base is not set as it is fed | connection-padding 17 |
| P-E | `connection` | the parser's count is not kept | connection-expect 2, connection-head 2, connection-padding 10, connection-table 7 |
| P-F | `connection` | five bytes of empty lines pass | connection-padding 1, connection-table 3 |
| P-G | `connection` | three bytes of empty lines are the most | connection-padding 1, connection-table 3, trace-lane 1 |
| P-H | `connection` | two spaces after the method pass at the target | connection-originated 1, connection-padding 1, connection-table 2 |
| P-I | `connection` | a space after the target's one passes at the protocol | connection-padding 1, connection-table 2 |
| P-L | `connection` | the whitespace is not added to the section | connection-expect 1, connection-head 1, connection-padding 2, connection-table 3 |
| P-M | `connection` | the whitespace is not kept with the value | connection-expect 1, connection-head 1, connection-padding 5, connection-table 1 |
| P-N | `connection` | a value's limit ignores its whitespace | connection-expect 1, connection-head 1, connection-padding 5, connection-table 1 |
| P-O | `connection` | a head's value-complete keeps its whitespace for the next name | connection-expect 4, connection-table 2 |
| P-P | `connection` | empty lines refused at a read's end are answered from idle | connection-table 1 |
| P-Q | `connection` | the request line's, the empty lines' and the digits' runs are judged at the parser's error too | connection-table 2 |
| P-R | `connection` | the whitespace is not judged at the parser's error | connection-table 1 |
| P-S | `connection` | no slack for the byte that ends a size's digits at a read's end | connection-padding 1, connection-table 1 |
| P-T | `connection` | on-chunk-header counts the size line's LF as a digit | connection-padding 1, connection-table 1 |
| P-U | `connection` | an extension's first byte counts its `;` as a digit | connection-padding 1, connection-table 1 |
| P-V | `connection` | on-chunk-complete opens no size line | connection-padding 3, connection-table 4 |
| P-W | `connection` | a chunked head opens no size line | connection-originated 1, connection-padding 1, connection-table 1 |
| P-X | `connection` | on-message-complete opens no empty-lines run | connection-padding 1, connection-table 1 |
| P-Y | `connection` | on-message-begin judges no empty lines | connection-originated 1, connection-padding 2, connection-table 2 |
| P-Z | `connection` | the empty-lines refusal at on-message-begin keeps no reason | connection-originated 1, connection-padding 2 |
| P-AA | `connection` | a run is never closed | connection-body 26, connection-expect 15, connection-head 48, connection-originated 3, connection-padding 15, libhtp-lane 2, message-loop 10, outcome-lane 4, ratchet 1, shell 1, trace-lane 2 |
| P-AB | `connection` | a trailer opens no whitespace run | connection-expect 2, connection-padding 4, connection-table 1 |
| P-AC | `connection` | a head's field opens no whitespace run | connection-head 2, connection-padding 6, connection-table 3 |
| P-AD | `connection` | the method opens no run | connection-originated 1, connection-padding 3, connection-table 2 |
| P-AE | `connection` | a piece's limit is named whenever passed, before the section's | connection-padding 1, connection-table 2 |
| P-AF | `decisions` | a chunk size's digits past 16 are refused 413 | connection-originated 1, connection-padding 2, connection-table 1 |
| P-AG | `connection` | 17 digits pass at the callback | connection-originated 1, connection-padding 1, connection-table 4 |
| P-AH | `connection` | a read's end in idle judges no empty lines | connection-padding 1, connection-table 1 |
| P-AI | `connection` | no run is judged at a read's end | connection-padding 1, connection-table 7 |
| P-C2 | `connection` | a delivery's base ignores where its bytes start | connection-body 26, connection-expect 15, connection-head 48, connection-padding 16, message-loop 10, outcome-lane 4, ratchet 1 |
| P-E2 | `connection` | the parser's count is summed, as each read's bytes were | clients 1, connection-allocation 5, connection-body 27, connection-expect 15, connection-head 48, connection-linger 1, connection-padding 12, connection-table 1, libhtp-lane 3, message-loop 10, outcome-lane 4, ratchet 1 |
| P-EA | `connection` | an event entry takes a span callback's name | connection-entry 4 |
| P-EB | `connection` | an event callback enters without its position | connection-entry 1 |
| P-EC | `connection` | on-headers-complete enters without its position | connection-entry 1 |
| P-H2 | `connection` | one space after the method is refused at the target | clients 9, connection-allocation 5, connection-body 29, connection-deadlines 5, connection-entry 6, connection-head 50, connection-originated 21, connection-padding 16, connection-retention 8, connection-table 14, contract 1, libhtp-lane 14, message-loop 13, outcome-lane 3, ratchet 1, serve 3, shell 54, trace-lane 2 |
| P-I2 | `connection` | the protocol right after the target's space is refused | clients 9, connection-allocation 5, connection-body 29, connection-deadlines 5, connection-head 49, connection-originated 20, connection-padding 15, connection-retention 8, connection-table 14, contract 1, libhtp-lane 14, message-loop 13, outcome-lane 3, ratchet 1, serve 2, shell 54, trace-lane 2 |
| P-J1 | `connection` | a request line's first field does not let the run after the target go | connection-padding 1, connection-table 2 |
| P-J2 | `connection` | no slack at a read's end for a versionless line's CR | connection-padding 1, connection-table 1, outcome-lane 2, ratchet 1 |
| P-J3 | `connection` | on-url-complete opens no run after the target | connection-padding 1, connection-table 2 |
| P-O2 | `connection` | a trailer's value-complete keeps its whitespace for the next name | connection-table 1 |
| P-OC | `connection` | the colon counts with the whitespace | connection-expect 4, connection-head 2, connection-padding 5, connection-table 6 |
| P-Q2 | `connection` | a chunk size's digits are judged at the parser's error | connection-table 1 |
| P-S2 | `connection` | one space after the method is past its limit at a read's end | connection-body 26, connection-expect 15, connection-head 48, connection-padding 11, connection-table 1, message-loop 9, outcome-lane 4, ratchet 1 |
| P-S3 | `connection` | whitespace bringing the section to its limit is past it at a read's end | connection-table 1 |
| P-AE2 | `connection` | the section's limit is named whenever passed, before a piece's | connection-padding 2 |
| P-AE3 | `connection` | both limits passed at one byte name the section's | connection-padding 1 |
| R-EF | `connection` | a span entry takes an event callback's name | connection-entry 2 |
| R-G1 | `connection` | a run is judged at a read's end in any phase | connection-table 6 |
| R-G2 | `connection` | the whitespace is judged at a read's end in any phase | connection-table 1 |
| R-G3 | `connection` | a chunk size's digits are read in head | connection-padding 1, connection-table 2 |
| R-K8 | `connection` | a parser-result's codes are read only if it has them | connection-entry 1 |
| R-W1 | `connection` | an empty value's line end counts with its whitespace | connection-padding 1 |
| R-W2 | `connection` | the whitespace is judged whole at a read's end | connection-padding 1, connection-table 1 |
| R-W4 | `connection` | a value one byte long is taken for an empty one | connection-expect 2, connection-head 2, connection-padding 4, connection-table 3 |
| R-X1 | `connection` | an extension name's end counts no byte | connection-expect 1, connection-originated 1, connection-padding 3, connection-table 3 |
| R-X2 | `connection` | an extension value's end counts no byte | connection-expect 1, connection-originated 1, connection-padding 2, connection-table 1 |
| R-X3 | `connection` | an extension's end counts two bytes | connection-expect 1, connection-padding 2, connection-table 3 |
| R-F3a | `connection` | the trailers' fields are not counted afresh | connection-expect 2, connection-table 1 |
| R-F3b | `connection` | the trailers' bytes are not counted afresh | connection-expect 3, connection-padding 2, connection-table 6 |
| T-G | `test-connection-table` | the table's padding row G14 has no test | connection-table 1 |
| T-F3 | `test-connection-table` | row F3's head one byte past the section's limit again (the table's setup! guard) | connection-table 1 |
| T-E14 | `test-connection-entry` | the entry suite's event callbacks lose one | connection-entry 1 |

Sixty-five mutants on the reviewed tree; none survives.

## The cut-off-span PR (fix/cut-off-spans, 2026-10-01)

At the parser's error the core now judges what the error cut off, a target's or a field
name's bytes it was not handed, and then the run still open, as a read's end would have
(decided on the owner's word, by form; the ledger). A parser-result is `(parser-result
status offset next code span)`, built once by the adapter, its offset at an error the
refused byte's.

Red before green: on main's code, a copy of the new suite without its two checks of the
adapter failed five of its nine checks, those whose inputs split on main, and passed the
other four: a target and the names at their limits, the tabs, and the tripwire. The whole
suite cannot load on main, which has no `parser-result-event`. test-serve's new check failed
against main's sources. Every new and changed check is watched red by at least one mutant
below, mapped by its name in the runner's reports:
- the cut-off suite's eleven: a target at its limit by X-T1; a byte past it by X-T2 and
  X-T4; the spaces by X-T3 and X-C3; the tabs by X-A1 and X-C1; the names at their limit
  by X-L1 to X-L7; a byte past by X-N1 and X-N3; the section by X-N2; the digits by X-R1,
  X-R2 and X-C1; the result as a shell hands it by X-A1, X-A2 and X-A4; a pause's code by
  X-A3; the tripwire for byte-machine #145 by X-B1;
- the table's G12 by X-C1 and X-R1; K1 by X-T1; K2 by X-T4; K3 by X-T3; K4 by X-L1, X-L3,
  X-L4, X-L7, X-N1 and X-N2; T7, its pause code moved, by X-C4; the cut-off rows' count by
  T-K;
- the entry suite's renamed check by X-C2;
- test-serve's new check by X-A4 and X-S1.

Twenty-eight mutants, every one run against all forty-four suites (T-K against the table's
alone), none surviving. Two notes:
- X-S1 reddens five contract checks as well. The contract suite holds the two shells' traces
  equal, and a libuv shell that drops the span differs from the fake one at the first read
  that ends inside a span.
- X-T5, a space check that raises, reddens the outcome lane and the ratchet too, so the
  corpora reach the check: an error cutting off a target while the spaces after the method
  are open. Their answers there are main's.

The padding PR's sixty-five, on this tree. Sixty-two were run again, each against the
suites it reddened before, or all of them where cut again:
- fifty-seven as written;
- five cut again against the rewritten text: P-AI, P-J3, P-O, P-O2 and R-G1.

Three were withdrawn:
- P-Q and P-Q2: their mutation, runs judged at the parser's error, is now the rule;
- R-K8, a result's fields read only where present: it is X-C2 now.

All sixty-two are still killed.

| Mutant | Where | Change | Reddens (suite, failures) |
|---|---|---|---|
| X-A1 | `adapter` | the adapter does not step back past a byte the parser took and refused | connection-cut-off 2 |
| X-A2 | `adapter` | the adapter steps back past a callback's failure too | connection-cut-off 1 |
| X-A3 | `adapter` | the adapter drops a pause's code | connection-cut-off 1 |
| X-A4 | `adapter` | the adapter hands no span | connection-cut-off 7, serve 1 |
| X-B1 | byte-machine's runtime | byte-machine's runtime exports an accessor for the span an error abandoned (#145 landed) | connection-cut-off 1 |
| X-C1 | `connection` | at an error the core counts the refused byte too | connection-cut-off 2, connection-table 1 |
| X-C2 | `connection` | a result's code and span are read only where present | connection-entry 1 |
| X-C3 | `connection` | a refusal of the core's own does not stop the cut-off judgment | connection-cut-off 1, connection-padding 1 |
| X-C4 | `connection` | a pause's code is read from the span's place | connection-table 3 |
| X-L1 | `connection` | the first field's line begins at the version's CR, not past its CRLF | connection-cut-off 1, connection-table 1 |
| X-L2 | `connection` | a versionless request line sets no line start | connection-cut-off 1 |
| X-L3 | `connection` | a head's value end sets no line start | connection-cut-off 2, connection-table 1 |
| X-L4 | `connection` | a chunk's size line sets no line start | connection-cut-off 1, connection-table 1 |
| X-L5 | `connection` | a trailer's value end sets no line start | connection-cut-off 1 |
| X-L6 | `connection` | a cut-off name counts from its line start always | connection-cut-off 2 |
| X-L7 | `connection` | a cut-off name counts from the read's start always | connection-cut-off 2, connection-table 3 |
| X-N1 | `connection` | a cut-off field name is not judged | connection-cut-off 3, connection-table 3 |
| X-N2 | `connection` | a cut-off name is not counted with the section | connection-cut-off 1, connection-table 1 |
| X-N3 | `connection` | a cut-off name forgets the fragments a read's end handed on | connection-cut-off 1 |
| X-R1 | `connection` | at the parser's error only the whitespace run is judged, as before | connection-cut-off 1, connection-table 2 |
| X-R2 | `connection` | a run is judged with no slack | connection-cut-off 1, connection-padding 2, connection-table 2, outcome-lane 2, ratchet 1 |
| X-S1 | `shell` | the libuv shell builds its own result, with no span | contract 5, serve 1 |
| X-T1 | `connection` | a target cut off before its first fragment is counted a byte long | connection-cut-off 2, connection-table 1 |
| X-T2 | `connection` | a cut-off target is not placed: the open run is judged instead | connection-cut-off 3, connection-table 3, serve 1 |
| X-T3 | `connection` | no space check: a target always begins one byte after the method's space | connection-cut-off 1, connection-table 2 |
| X-T4 | `connection` | a carried target counts only the bytes of the read that failed | connection-cut-off 1, connection-table 1 |
| X-T5 | `connection` | the space check reads the delivery at the wrong index | connection-cut-off 4, connection-table 4, outcome-lane 2, ratchet 1, serve 1 |
| T-K | the table suite | row K3 holds no instance | connection-table 1 |

## The pin PR (refactor/abandoned-span, 2026-10-01)

byte-machine v0.7.0's parse error records the span it abandoned and where that span's
withheld bytes begin (its #145). So the core reads them in place of placing the span, and
the result's `span` is the error's `(name . offset)` (decided on the owner's word, by form;
the ledger). The pins move to chez-httparse v0.4.5 and uriparse v0.6.2.

Red before green, at the new pins on the old code: the cut-off suite's two shape checks
failed, and six of the table's twelve K1–K4 instances, in K1, K2 and K4. The new check of
the core's refusal at the head's end, added after the run below found X-C3 surviving,
failed on X-C3's mutant. Every new and changed check is watched red by at least one mutant
below, mapped by its name in the runner's reports:
- the cut-off suite's shape check by X-A1, X-A2 and Y-A1 to Y-A4 (Y-A3 by its error with
  no span open); a pause's code by X-A3; the core's refusal at the head's end by X-C3;
- the table's K1 by Y-C1, Y-C4, Y-C9 and Y-C10; K2 by Y-C3, Y-C9 and Y-C10; K3 by Y-C1 and
  Y-C2; K4 by Y-C5, Y-C7 and Y-C8; the cut-off rows' count by T-K.

Eighty-nine mutants, none surviving:
- seventeen new, Y-A1 to Y-S2, each run against all forty-four suites;
- ten of the cut-off-span PR's, each against all forty-four, T-K against the table's alone.
  Three were cut again where `span` became `abandoned` (X-C2, X-C3 and X-C4), and T-K
  against the rows' new results;
- the padding PR's sixty-two, each against the suites it reddened before, or all of them
  where cut again: fifty-nine as written, and three cut again where `conn-line`'s lines
  went (P-J3, P-O and P-O2).

Withdrawn, the code they mutated gone:
- X-B1, the tripwire;
- X-L1 to X-L7, the line starts;
- X-T1 and X-T5, the placement of a target and its space check.

Cut again as new ones, the code they mutated rewritten: X-A4 as Y-A4; X-S1 as Y-S1; X-T2,
X-T3 and X-T4 as Y-C9, Y-C2 and Y-C3; X-N1, X-N2 and X-N3 as Y-C8, Y-C7 and Y-C6.

Three notes:
- **X-C3 survived the first run.** It drops the guard that keeps the core's own refusal from
  the cut-off judgment. Under #91 it reddened two checks, both spaces after the method
  refused as the target's first bytes arrived: two spaces and then a target (the cut-off
  suite), and a megabyte of them (the padding suite). At the error that refusal causes,
  #91's placement counted the read from its start as target, spaces and all, and named
  the target instead. v0.7.0 records nothing withheld at a data callback that fails, since
  the callback was handed its bytes, so the judgment now finds nothing past a limit. The
  guard still matters where a run is left open. A request line with no version and no fields keeps the run after its target open
  to its head's end, and on X-C3's mutant a target the core refuses there was answered for
  the spaces (400, `request-line-spaces`, not `invalid-target`). The cut-off suite's new
  check holds it, at every delivery size, and X-C3 reddens it.
- **X-C4's first run did not load:** its cut named `span`. Cut again, it reddens the table's
  three, as before.
- **Y-S1 reddens test-serve alone.** X-S1 reddened five contract checks too, but a span now
  reaches the core only at an error, so the two shells' traces over the contract's
  requests stay equal. test-serve's target cut off through the libuv shell is what sees it.

| Mutant | Where | Change | Reddens (suite, failures) |
|---|---|---|---|
| Y-A1 | `adapter` | the pair's offset is the error's own, not where the withheld bytes begin | connection-cut-off 6, serve 1 |
| Y-A2 | `adapter` | the adapter hands the abandoned span's name alone | connection-cut-off 8, connection-head 1, connection-originated 1, outcome-lane 2, ratchet 1, serve 1 |
| Y-A3 | `adapter` | an error with no span open hands a pair of nothing | connection-cut-off 1 |
| Y-A4 | `adapter` | the adapter hands no span | connection-cut-off 7, serve 1 |
| Y-C1 | `connection` | a cut-off target counts from one past the method's space, as the workaround placed it, with no space check | connection-cut-off 3, connection-table 3 |
| Y-C2 | `connection` | no spaces judgment before a cut-off target | connection-cut-off 1, connection-table 2 |
| Y-C3 | `connection` | a carried target forgets the fragments a read's end handed on | connection-cut-off 1, connection-table 1 |
| Y-C4 | `connection` | a cut-off target counts the refused byte too | connection-cut-off 2, connection-table 2 |
| Y-C5 | `connection` | a cut-off name counts a byte short | connection-cut-off 2, connection-table 3 |
| Y-C6 | `connection` | a carried name forgets the fragments a read's end handed on | connection-cut-off 1 |
| Y-C7 | `connection` | a cut-off name is not counted with the section | connection-cut-off 1, connection-table 1 |
| Y-C8 | `connection` | a cut-off field name is not judged | connection-cut-off 3, connection-table 3 |
| Y-C9 | `connection` | a cut-off target is not judged | connection-cut-off 3, connection-table 3, serve 1 |
| Y-C10 | `connection` | the spaces before a cut-off target are counted to the refused byte | connection-cut-off 3, connection-table 2, serve 1 |
| Y-C11 | `connection` | the span is read with no guard for a result that carries none | connection-body 4, connection-cut-off 2, connection-head 2, connection-originated 2, connection-table 13, message-loop 1, outcome-lane 2, ratchet 1 |
| Y-S1 | `shell` | the libuv shell drops the span | serve 1 |
| Y-S2 | the fake shell | the fake shell drops the span | connection-cut-off 6 |
| T-K | the table suite | row K3 holds no instance | connection-table 1 |
| X-A1 | `adapter` | the adapter does not step back past a byte the parser took and refused | connection-cut-off 2 |
| X-A2 | `adapter` | the adapter steps back past a callback's failure too | connection-cut-off 1 |
| X-A3 | `adapter` | the adapter drops a pause's code | connection-cut-off 1 |
| X-C1 | `connection` | at an error the core counts the refused byte too | connection-cut-off 2, connection-table 1 |
| X-C2 | `connection` | a result's code and span are read only where present | connection-entry 1 |
| X-C3 | `connection` | a refusal of the core's own does not stop the cut-off judgment | connection-cut-off 1 |
| X-C4 | `connection` | a pause's code is read from the span's place | connection-table 3 |
| X-R1 | `connection` | at the parser's error only the whitespace run is judged, as before | connection-cut-off 1, connection-table 2 |
| X-R2 | `connection` | a run is judged with no slack | connection-cut-off 1, connection-padding 2, connection-table 2, outcome-lane 2, ratchet 1 |

## The M6 exit (feat/m6-exit, 2026-10-02)

The exit adds checks and changes no code under `src/`. The clients suite has curl send
16 MiB to a streaming reader and read 16 MiB from a producer, each at 16 MiB/s, and
holds what arrives, the server's heap, read every 50 ms after two full collections, and
the bytes written and not yet completed (`tests/test-clients.sps`). The libhtp lane runs
`35-early-response.t` a second time, its handler answering 400 at the head, as the
recorded origin answered it (`tests/test-libhtp-lane.sps`). Both were decided on the
owner's word, by form (the ledger).

The code they check was already in place, so each check was watched red by a mutant of
the code, or by a calibration of the check where its half guards against a vacuous pass.
By name:
- "16 MiB sent at 16 MiB/s arrive in order, no read handing the reader more than the read
  buffer": M6X-F, and M6X-G;
- "the server's heap, read throughout, grew by less than 1 MiB as they came in": M6X-B
  and M6X-C, and its readings half by C-fast;
- "16 MiB streamed to it, read at 16 MiB/s, arrive in order": M6X-I, and C-short;
- "the bytes written and not yet completed backed up past the low water, and never passed
  the high water by more than a piece's write": its upper half by M6X-A, its lower by M6X-E,
  and both by C-short;
- "the server's heap, read throughout, grew by less than 1 MiB as they went out": M6X-D,
  and its readings half by C-fast;
- the lane's "35-early-response.t answered 400 at the head": M6X-G, and C-read.

The suites' helpers changed shape: the clients suite's `spawn` and `run` take a pipe
for the child's standard input, a procedure that takes its output, a watch and a cap,
and the lane's `libhtp-outcome` runs through `run-stream`. The checks that call them as
before are unchanged, and pass.

| Mutant | Where | Change | Reddens (suite, failures) |
|---|---|---|---|
| M6X-A | `connection` | high water ignored: a producer is asked whatever the bytes outstanding, up to its 64 writes | clients 1, connection-stream 4, connection-table 8, shell 2 |
| M6X-B | `connection` | the core keeps every piece it hands a streaming reader | clients 1 |
| M6X-C | `shell` | the libuv shell keeps every read it hands the core | clients 1 |
| M6X-D | `shell` | the libuv shell keeps every write's segments after it is sent | clients 1, shell 1 |
| M6X-E | `shell` | the libuv shell reports a write completed as it is sent, not when libuv completes it | clients 1, contract 3, shell 6 |
| M6X-F | `shell` | the libuv shell starts reading with chez-libuv's default buffer, 64 KiB, not the limit's | clients 1, shell 6 |
| M6X-G | `connection` | a request whose head announces a body is never asked of the handler at the head, as before M6.1 | clients 8, connection-allocation 1, connection-body 28, connection-cut-off 3, connection-entry 5, connection-expect 15, connection-head 2, connection-originated 3, connection-padding 9, connection-retention 2, connection-stream 2, connection-table 49, contract 9, libhtp-lane 8, message-loop 4, outcome-lane 3, ratchet 1, shell 16, trace-lane (raised, exit 2) |
| M6X-H | `shell` | the libuv shell sends a write before the writes it holds, not after | shell 1 |
| M6X-I | `serializer` | a chunked piece's size line counts a byte short | clients 5, connection-allocation 1, connection-stream 11, connection-table 5, serializer 7, shell 9 |
| C-fast | the clients suite | curl unlimited, so neither 16 MiB run is slow: two or three heap readings | clients 2 |
| C-short | the clients suite | a stream of three pieces, 48 KiB, under the low water | clients 3 |
| C-read | the lane | the early run's handler reads the body, as the lane's own run does | libhtp-lane 1 |

Each mutant ran against all forty-four suites, and none failed to load: every report's
red suites are failures, or, for M6X-G's trace lane, a raise.

Two notes:
- **M6X-B and M6X-C redden the clients suite alone.** Each keeps the whole body in the
  heap, as the core's pieces or the shell's reads, and before the exit no check read the
  heap while a body came in. M6X-D, which keeps the shell's writes, reddens the shell
  suite's retention check besides, which collects while a 4 MiB write is outstanding and
  finds the response's body held.
- **M6X-H reddens the shell suite alone.** The exit's checks do not see it, since a 16 KiB
  piece is never held (write batching holds a write under 4,096 bytes), and a stream's
  head is sent before its producer is first called. M6X-I, a piece's framing a byte short,
  is the content mutant they see.
