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
