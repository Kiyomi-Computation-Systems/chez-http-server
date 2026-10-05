# chez-http-server — ledger archive: M6, body streaming and backpressure

M6's entries, moved verbatim from `progress.md` on 2026-10-05 (its lines 2825–3793 at 64761cb). The mutation log is `m6-mutations.md`; the spine is `progress.md`.

---

M6.1: HOW A HANDLER READS A BODY. Two stacked steps, cut from main at f21ab76: feat/m6.1-readers, then feat/m6.1-body-reading on it; 2026-09-28, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

MEASURED FIRST (plan §14: "measured first and settled by form, as 0012 was"): `research/spike/m6-body-reading.sps`, two runs, whose allocation rows are the same.
- Brief risk 3, at chez-httparse v0.4.3: a pause inside on-body-data, fed again from `next`, delivers each body byte once, framed by Content-Length and chunked. After a pause on a body's last byte, one empty feed at `next` completes the message, and nothing else does. The plan's mutation, feeding again from where the read started, hands the head's first bytes over as body.
- The gate's JSON POST, through the real parser, adapter and core, with its body dropped as before M6: 2,320 B, 752 B under the 3,072 B gate.
- Each way of reading, a cycle modelled over the real parser, adds to that cycle: a reader handed each read's pieces as the parser meets them, 208 B (2,256 B a MiB); the plan's one-slot mailbox, the parser paused at each piece, 816 B (45,877 B a MiB); the buffering helper, 224 B; the server buffering every body, 32 B; `(handler request respond)`, 224 B. Streaming holds 80 B past today's connection once a MiB is in, and buffering 1,048,656 B.
- A body of unknown length, per 16 KiB piece: a thunk 64 B, a port 71 B, `emit`/`done` 114 B.

DECIDED on the owner's word (2026-09-28), by form, then "looks good" to the detail asked for on the first answer: decision 0013.
- A reader, answered at the head: `read-body` streams, `read-whole-body` buffers, 1 MiB, 413 past it. Weighed: the server buffering every body; `(handler request respond)`.
- Pieces as the parser meets them. Weighed: the one-slot mailbox.
- A response given instead of a reader: sent at once, then close. Weighed: after the body, keeping the connection; Go's rule.
- A body of unknown length is a thunk (M6.3). Weighed: a port; `emit` and `done`.

M6.1 FIRST STEP: the readers, and brief risk 3's pins (feat/m6.1-readers).
- `(http-server body)`, pure: `read-body` and `read-whole-body`, the readers a handler answers with, each carrying its cap and whether the core buffers the body for it. Nothing hands a body to them yet: the second step does.
- `tests/test-body.sps` (8 checks) and `tests/test-pause-pins.sps` (3). The core never pauses inside a body (decision 0013 item 3), so brief risk 3's two facts are pinned as the parser's, and the plan's mutation runs on the pins suite's own feed loop, whose feeds are capped by count.
- Decision 0013 as decided; the spike and its two runs; the research README.

`make test` green on this step's own tree, a scratch worktree cut from main with the step's files laid in: thirty-nine suites, 984 expected passes, exit 0.

Watched to fail (m6-mutations.md, the first step): eleven mutants on that tree, each reddening its own suite's checks and nothing else, every one of the step's eleven checks among them. The plan's mutation, M6.1-PA, turns the two pinned rows red.

Size: 301 inserted lines of code and tests.


M6.1 SECOND STEP: the core hands a body to a reader (feat/m6.1-body-reading).

FOUND WHILE BUILDING, each raised with the owner, and recorded in decision 0013's section "Found while building":
- The form's detail that kept the connection when the whole body came with the head was dropped before it was built, the owner told at once: whether the body came with the head depends on the reads, and the outcome lane holds the outcome to one.
- Item 1 as first built made eight strict fixtures' outcomes depend on the reads (the outcome lane: `transfer-encoding.md` #9, #10, #12, #24, #25, #27, #29 and #31, chunked bodies with a bad chunk size). With the body in the head's read, the parser met the error before the handler was asked, and answered 400; in later reads the handler was asked first. Now what the feed that completes a head meets of the body waits for the handler's answer: its pieces, and an error or a cap passed.
- Pausing the parser at the head instead was built and measured through the real core: the JSON POST cost 3,248 B read whole and 3,120 B streamed, over the gate. It was taken out.
- A streaming reader past a cap was handed `abcd` at a byte a time and `abc` read whole: a piece that passes a cap is now handed over up to the cap.
- Found by checking what each reader was handed, beside the core's actions: the core let a reader go when it wrote a status of its own, so the pieces already asked for, a prefix up to a cap or those met before an error, reached nobody at one read split and the reader at another. A reader is now let go when the connection lingers or closes, or when it raises.

BUILT:
- The core, `(http-server connection)`: a request whose head announces a body (chunked, or a Content-Length above 0) is handed to its handler with the feed's result, once the feed that completed the head has returned; what that feed met of the body, its pieces and an error or a cap passed, is kept for the answer. A reader is handed each read's pieces as `deliver-body`, the read's own spans, and `deliver-body-end` once the message has ended. A whole reader's body is copied as it arrives, into one bytevector grown to the declared length or joined when chunked, and handed over as its one piece. A response given instead of a reader is sent at once, and the connection closes after it, as `unread-body`. A body past `max-body-bytes`, or past a reader's cap, is refused as `body-too-large`, answered 413 (`(http-server decisions)`), and the piece that passes the cap is handed over up to it. A reader that raises is answered 500, as a handler that raises is. `conn-body-reader` is exported for the shells, and `conn-body-buffered`, the bytes the core buffers for a whole reader, for the checks. The parser is never paused inside a body.
- Both shells perform `deliver-body` and `deliver-body-end`: the fake shell, and the libuv shell, which logs a reader's raise as a handler's.
- The facade exports `read-body` and `read-whole-body`. `docs/handlers.org` gains "Reading the body"; `docs/configuration.org` and `docs/responses.org` say what the body cap does and when 413 is sent.
- `tests/test-connection-body.sps` (27 checks, each row at every delivery size); nineteen body rows (B1 to B19) in the transition table, and H5 a reader's.
- Suites that sent a body to a handler that answered at once now read it, where their checks need the connection kept, most through (fake-shell)'s `drops-body`: the message loop, entry, head, deadlines, originated (413 now driven end to end), allocation, the trace lane's driver, the outcome and libhtp lanes, the socket lane and the clients suite. The outcome lane runs every fixture with a handler that reads every body and with one that reads none. The contract test has reader scripts, among them readers that raise, and renders a reader by its cap and kind. The retention suite checks a body read whole is let go with its reader, and the serve suite a 413 from CHEZ_HTTP_MAX_BODY_BYTES set in the environment.

DECIDED on the owner's word (2026-09-28), by form:
- the four findings kept as built: what the head's read brings of the body waits for the handler's answer. Weighed: pausing the parser at the head (3,248 B and 3,120 B, over the gate); letting those outcomes depend on the reads, the outcome lane exempting eight fixtures;
- a /code-review first, its findings fixed on the owner's word, then two stacked PRs, each layer proved green on its own tree. Weighed: the two PRs without a review; one PR.

REVIEWED before the first commit, at high effort (/code-review), on the owner's "fix all findings" (2026-09-28): eight findings.
- **A whole reader's buffer was made at the declared length as the reader answered**, before any of the body came: a head alone could take up to the reader's cap, 1 MiB by default, and with no cap a declared length past what memory holds raised in the core. Fixed: the buffer grows as the body arrives, to the declared length once that is at most twice what has arrived, and doubling before, so it is never more than twice what has arrived, the buffers it grows through come to less than twice the body, and it ends exactly full. `conn-body-buffered`, exported, says how many bytes the core buffers for a whole reader, and the new checks read it: nothing buffered before a declared 64 KiB's bytes arrive, never more than twice what has arrived, the body handed over exactly its length (the body suite); 64 KiB in 1,000-byte pieces allocates 128,657 B in buffers, under twice its length (the allocation suite). Decision 0013's item 2 says so, and its review note.
- **A request refused mid-body kept a whole reader's buffer during its write**, since a status of the core's own no longer lets the reader go. Fixed: that status lets go of the buffer and the pieces kept, and keeps the reader. Checked: a whole reader past its cap mid-body buffers 3,000 bytes, then nothing, its 413 still being written.
- **A chunked whole body is copied twice at its peak.** The finding's premise was measured first and is wrong: on a chunked MiB in 64 pieces, copying each piece and joining them allocates 2,099,391 B; a doubling buffer trimmed at the end, the fix it proposed, 3,129,692 B; both hold 2 MiB at most (a scratchpad probe, two runs, the same). No change; the core's comment says why.
- **The request record's comment on its body field** said it would carry a body handle in M6. It now says the field stays #f: a handler reads a body through the reader it answers with.
- **docs/handlers.org** called any request with a Content-Length one with a body: it now says a Content-Length above 0.
- **body-piece answered one constant list in three arms.** Now `hand-on` hands a piece on by the handler's answer, and body-piece names its two answers once.
- **The suites' reading handler was written five times**: `drops-body`, in (fake-shell), replaces the message loop's, the originated, deadlines and head suites', and the outcome lane's. The socket lane's and the clients suite's handlers read a POST's body inside routes of their own, and keep them.
- **CHEZ_HTTP_MAX_BODY_BYTES never drove a 413 from the environment**: test-serve.sps starts its server with it set to 4, and a 5-byte body gets 413.

Measured on the finished tree (2026-09-28, Darwin arm64):
- `make test` green: forty suites, 1,069 expected passes, exit 0, 20.7 s.
- The allocation suite: curl's GET 1,840 B, unchanged; the JSON POST 2,624 B read whole and 2,432 B streamed, against the 3,072 B gate, where before M6.1, its body dropped, it cost 2,320 B; a 64 KiB body read whole, in 1,000-byte pieces, 128,657 B in buffers.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and ab 2.3 installed:
- `make test`, less its submodule and pin checks: forty suites, 1,069 expected passes, the allocation figures the same;
- the socket lane, three runs: 92 passes each.
CI's runs are still the billing block.

Watched to fail (m6-mutations.md, the second step): 64 mutants on the finished tree, and every check new or changed by the slice reddened by at least one. M6.1-CK is the bug the reader's own view found; M6.1-EM to M6.1-ER were written for six changed checks the first run left without a mutant; the review rewrote the code nine mutated, eight were written again, and M6.1-CD is withdrawn, its code gone; M6.1-RA to M6.1-RH witness the review's fixes.

Records: decision 0013's sections "Found while building" and the review's, and its item 2; decision 0005's amendment (`max-body-bytes`); design §4.1, §4.4 (the body rows) and §6.5 (413); plan §14's M6.1 note, and §7's 413 note; the docs; m6-mutations.md.

Size: 1,557 inserted lines of code and tests, 213 deleted, besides records and docs. It cannot be split further and stay green: once a request with a body is handed over at its head, every suite that sends one changes with it.

NEXT: the two stacked PRs, merged bottom up on the owner's word. Then M6.2 (plan §14), which the M6.1 note re-scopes.

MERGED to main on 2026-09-28, on the owner's "do closing ritual": **M6.1, as two stacked PRs.**
- **#69, the readers and brief risk 3's pins,** as fcd00b7. Its squash tree (d7408ab) is the tested tip's, 4edb4a2's, and its parent is f21ab76. It merged first and kept its branch, since #70 was based on it.
- **#70, the core hands a body to a reader,** as 780f4c0. It was retargeted to main and rebased from #69's tip, 4edb4a2. The rebased tip, 24b22ee, has the tested tree (d3af745, 1cda330's), and so does the squash, whose parent is fcd00b7.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36451927716 (#69), 36451961940 (#70 as opened) and 36452623653 (#70 rebased).
- **Branches.** Both deleted local and remote, and refs pruned. No PR is open. `gh pr merge --delete-branch` merged #70 and deleted its remote branch, but left the checkout on it, so the switch to main, the fast-forward and the local deletions were done by hand.

`make test` green on main: forty suites, 1,069 expected passes.

DONE and merged (fcd00b7, PR #69; 780f4c0, PR #70): **M6.1.**
- A handler reads a request's body through the reader it answers with at the head: `read-body` streams it, and `read-whole-body` buffers it, up to 1 MiB unless given a cap. `CHEZ_HTTP_MAX_BODY_BYTES` caps every body, and 413 has its first way in.
- The parser is never paused inside a body, so brief risk 3's two facts are pinned as the parser's.
- What the head's read brings of the body waits for the handler's answer, so the outcome never depends on how the bytes were split into reads.

NEXT: M6.2 (plan §14), backpressure on the read side, as the M6.1 note re-scopes it: a reader in v1 takes each read's pieces as they are handed over, so reading waits on a credit only for an awaiting reader (M7). M6.2's check is that wait, and the body deadline stopped through it, with a reader that withholds its credit. On a fresh branch cut from main after this commit, when the owner asks.


M6.2: BACKPRESSURE ON THE READ SIDE. Two stacked steps, cut from main at e9191ef: feat/m6.2-read-backpressure, then feat/m6.2-shell-credit on it; 2026-09-28, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

SETTLED BY THE RECORDS, NO FORM: decision 0013's consequences and plan §14's M6.1 note already say what M6.2 is. A reader answered in v1 takes each read's pieces as they are handed over, so reading goes on at once; reading waits on a credit only for M7's awaiting readers; and M6.2's check is that wait, and the body deadline stopped through it, with a reader that withholds its credit.

CHOSEN WHILE BUILDING, flagged for review:
- Whether reading waits for a reader: the shell's word, since the shell hands the pieces over. A shell that hands a streaming reader its pieces on credit answers with the reader and `credit`, `(handler-responded reader credit)`, as M7's coroutine shell will. First built as a field on the reader, `grants-credit?`, which the review moved to the answer (below). Weighed: every streaming reader granting credit, the shells granting it as each piece's procedure returns, which would stop and start reading, and disarm and arm the body deadline, at every body read in v1, where no reader withholds.
- Where the connection waits: a state of its own, `awaiting-credit`, which reads nothing and arms no deadline, as design §4.3's table says of each state. Weighed: a flag inside `body`, whose row in that table says it reads and arms the body deadline.
- How the libuv shell hears a credit: `connection-body-credit!`, which no action asks for. M7's scheduler will call it; the checks call it now. The facade exports nothing new.
- A credit counts bytes. One for more than the reader was handed and has not credited is an assertion violation, as a completion the core did not ask for is (M3.3).

DECIDED on the owner's word (2026-09-28), by form, after the plan-vs-landed walkthrough: a /code-review high first, its findings fixed on the owner's word, then two stacked PRs, each layer proven green on its own tree. Weighed: the two PRs without a review; the review, then one PR of 538 lines.

REVIEWED before the first commit, at high effort (/code-review), on the owner's "fix all findings" (2026-09-28): four findings, all fixed. The review's rows and checks were written with the fixes, and each was watched red by its mutant.
- **Nothing checked that a refusal wins over the wait** (the first step). A feed that hands a reader on credit pieces and then meets the parser's error, or passes a cap, is answered with its status: row C10, and two flows at every delivery size, a malformed chunked body answered 400 and one past max-body-bytes answered 413. M6.2-RA, the wait checked before the status, reddens all three.
- **A refused credit closes the connection and raises, undocumented** (the second step). `connection-body-credit!`'s comment now says so, and a socket check pins it: a credit for more than the reader was handed raises to the caller, and the connection is closed. M6.2-RB, the raise swallowed, reddens it.
- **The credit's word lived on the reader the handler builds** (both steps). Whether a shell hands a reader its pieces in place or on credit is the shell's to know: M7's coroutine shell hands each piece to the handler's coroutine. `(http-server body)` is back to M6.1's four fields, untouched by the slice, and the shell says so with the answer, anything but `credit` after it refused (row C11). The fake connection (the first step) and the libuv shell (the second) are made on credit for the checks. M6.2-RC (the word ignored) and M6.2-RD (any word taken), and M6.2-RF, RG and RH (a shell's word turned round), redden them.
- **The credit arm while the body is read could only take none** (the first step). on-body-credit's arms are split: `awaiting-credit` takes the credit, and starts reading once it covers what was handed; `body` takes only a credit of none, since nothing is owed there once a feed has returned. M6.2-RE, the `body` arm reading no credit, reddens C6.
- The rewrite left a guard doubled: `accept-reader` kept a whole reader off credit, which `owe!` does already, being called only for a streaming reader's pieces, and two guards for one property hide each other's mutants. The doubled one went before the mutants ran; M6.2-RI, a whole reader's pieces owed, reddens C2.

DECIDED on the owner's word (2026-09-28), by form, once the review's fixes had grown the slice to 674 inserted lines of code and tests: two stacked PRs still, the first 432 inserted, a little over plan §1 rule 1's ~400, as M4.3's two went. Weighed: three stacked PRs of 262, 170 and 242.

FOUND WHILE BUILDING:
- For M7, carried in plan §14: an awaiting handler asked at the head leaves reading going on until it answers, and every piece met meanwhile is kept for its answer, up to `max-body-bytes`, unset by default.
- The checks' credit calls raised out of their suites when a mutant made the core refuse a credit, so the suites stopped with a harness error. They now take a refusal as a result and fail by name, the contract's replay included (m6-mutations.md).

M6.2 FIRST STEP: the core waits for a reader's credit (feat/m6.2-read-backpressure).
- `(http-server connection)`: the eleventh state, `awaiting-credit`. An answer may carry `credit` after it, `(handler-responded reader credit)`, anything else after it being refused. The core counts the bytes it hands a streaming reader answered on credit; with credit owed once a read's feed has returned, or once the reader's answer has taken the pieces kept for it, the connection stops reading and disarms the body deadline, and `(body-credit n)` covering what was handed starts reading and arms the body deadline again. A body the parser refuses, or one past a cap, is still answered with its status. A read that ends the message hands its pieces over with the end and waits for nothing: reading stops at the pause for the response, as for every message. `handler-failed` and `read-error` act in the new state as in `body`, less the `read-stop`; `bytes-arrived` and a tick there change nothing; a credit once the message has ended, or once the reader is let go, changes nothing.
- `(fake-shell)`: a fake connection made on credit answers with each answer and `credit`.
- The checks, each reading what the reader was handed as well as the core's actions:
  - `tests/test-connection-table.sps`: eleven credit rows, C1 to C11, and the new state in T2 and D4;
  - `tests/test-connection-body.sps`: through a fake connection made on credit, at every delivery size, a reader never holds more than one read uncredited, with both framings; a malformed body and one past a cap are answered with their status; the body deadline does not run through the wait, and runs again after the credit; and a reader answered with no word of credit never makes reading wait.

`make test` green on this step's own tree, a scratch worktree cut from main with the step's files laid in: forty suites, 1,101 expected passes, exit 0.

Watched to fail (m6-mutations.md, the first step): twenty-one mutants on that tree, and every check the step added or changed reddened by at least one. The plan's mutation, M6.2-D, the credit ignored, reddens the slow reader's bound at every delivery size.

Size: 432 inserted lines of code and tests, 46 deleted.

NEXT: the second step, the libuv shell's credit, stacked on this one.


M6.2 SECOND STEP: the libuv shell's credit (feat/m6.2-shell-credit).
- `(http-server private shell)`: a shell made on credit answers with each handler's answer and `credit`; v1's server never makes one. `connection-body-credit!` dispatches `(body-credit n)`, and a credit the core refuses closes the connection and raises to the caller, as any bug in a dispatch does.
- The checks:
  - `tests/test-shell.sps`, on a shell made on credit: a 64 KiB body sent at once to a streaming reader. While the reader withholds its credit, past the body deadline's length, the connection has no deadline armed, the shell's timer stops and the connection stays (plan §14's note of 2026-09-27, M5.3's); credited each time it waits, the reader is handed the body a read at a time, in order, and the response is written; and a credit for more than the reader was handed raises to the caller, and the connection is closed;
  - `tests/test-contract.sps`: a credit script, played to a libuv shell made on credit and replayed to a fake made on credit. Its waits credit the script's connection each time it waits, the replay gives the fake each credit, and a credit the fake's core refuses shows in its trace rather than raising.

Measured on the finished tree (2026-09-28, Darwin arm64):
- `make test` green: forty suites, 1,107 expected passes, exit 0, 21.9 s.
- The allocation suite, the same before and after the slice: curl's GET 1,840 B; the JSON POST 2,624 B read whole and 2,432 B streamed; a 64 KiB body read whole, in 1,000-byte pieces, 128,657 B in buffers.
- On a socket, by a scratch copy of the shell suite printing them, two runs, the same: the reader handed the 64 KiB body sent at once was credited four times, 16,327 B, the first read less the 57-byte head, then 16,384 B three times, and held 16,384 B at most, one read.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and ab 2.3 installed:
- `make test`, less its submodule and pin checks: forty suites, 1,107 expected passes, the allocation figures the same;
- the shell suite and the contract, three runs each: 95 and 56 passes each time.

Watched to fail (m6-mutations.md, the second step): twenty-seven mutants on the finished tree, the first step's twenty-one again and the second step's six, and every check new or changed by the slice reddened by at least one. The plan's mutation, M6.2-D, reddens the slow reader's bound on the socket as well. M6.2-Q, the timer stopped only once no connection is left, is the first mutant a check can tell from the timer's stop at an empty wheel (M5.3's note).

Records: design §4.1 (the answer's `credit`), §4.3 (the state) and §4.4's M6.2 amendment (the rows); plan §14's M6.2 note, and the note carried to M7; decision 0013's note on the consequence M6.2 built; m6-mutations.md. The docs are unchanged: a v1 handler cannot withhold its credit.

Size: 242 inserted lines of code and tests, 37 deleted; the slice, 674 and 83.

NEXT: the two stacked PRs, merged bottom up on the owner's word. Then M6.3, a streamed response (plan §14).

MERGED to main on 2026-09-28, on the owner's "do closing ritual": **M6.2, as two stacked PRs.**
- **#71, the core waits for a reader's credit,** as 231a6ad. Its squash tree (24086c6) is the tested tip's, 06cbfb5's, and its parent is e9191ef. It merged first and kept its branch, since #72 was based on it.
- **#72, the libuv shell's credit,** as b36cd7f. It was retargeted to main and rebased from #71's tip, 06cbfb5. The rebased tip, de3ef65, has the tested tree (89a5aa4, 0bb79ab's), and so does the squash, whose parent is 231a6ad.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36461834323 (#71), 36461867546 (#72 as opened) and 36466500413 (#72 rebased).
- **Branches.** Both deleted local and remote, and refs pruned. No PR is open. `gh pr merge --delete-branch` merged #72 and deleted its remote branch, but left the checkout on it, so the switch to main, the fast-forward and the local deletions were done by hand.

`make test` green on main: forty suites, 1,107 expected passes.

DONE and merged (231a6ad, PR #71; b36cd7f, PR #72): **M6.2.**
- Reading waits for a reader's credit when the shell hands it its pieces on credit, `(handler-responded reader credit)`: the connection waits in `awaiting-credit`, reading stopped and no deadline armed, until `(body-credit n)` covers what the reader was handed, so a slow reader holds at most one read. A refusal still wins over the wait.
- v1's shells never answer on credit, so a v1 reader takes each piece as it is handed over, and v1's figures are unchanged. The checks stand in for M7's coroutine shell with a fake connection and a libuv shell made on credit.
- The libuv shell's timer stops while a connection waits for credit and stays, the row M5.3's note asked for.

NEXT: M6.3 (plan §14), a streamed response: `handler-body-chunk` and `handler-body-end` get their rows, chunked to HTTP/1.1 and close-delimited to 1.0 (M3.2's carried arm); `write-high-water` and `write-low-water` arrive, and with them `notify-producer`; and a handler that fails after its head is on the wire gets a bare close. Decision 0013 item 8 already settled the body of unknown length: a thunk, called only below the write's high water. On a fresh branch cut from main after this commit, when the owner asks.


THE CHEZ-LIBUV v0.7.3 PIN, on the owner's word, with the release note the owner relayed. Branch chore/chez-libuv-v0.7.3, cut from main at e992ea5; 2026-09-28, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. `vendor/chez-libuv` is at d46654c.

UPSTREAM: chez-libuv tagged v0.7.2 (e358156; annotated tag c26a31e, 08:37 -0400) and v0.7.3 (d46654c; annotated tag 410df26, 18:20 -0400) the day it tagged v0.7.1. GitHub's objects are the sibling checkout's. Neither carries an ask of ours, so decision 0008 is unchanged:
- v0.7.2 (PR #39, release PR #40) tightens chez-libuv's own memory-gate check. Nothing under its `src/` changed;
- v0.7.3 (PRs #42 and #43, release PR #44): a Chez without threads is refused by name at import (#41), where the import failed at `make-mutex`; `uv-async-send!` is fenced against `uv-close!` (#33), so a send that races a close either completes first or raises `&uv-handle-closed`, where it could reach freed memory; and `uv-close!` is one step, even inside an engine.

Checked against chez-libuv's history between the tags, as the note said:
- no C or header file changed, so the shim is v0.7.1's, and `make build` did not rebuild it;
- the facade and every public library but `(libuv async)` are byte-identical, and `(libuv async)`'s export list is unchanged, so no new name can collide with one of ours. The library path gains `(libuv private require-threaded)`, which exports nothing. `tests/uv-testing.sls` is byte-identical;
- the server's exposure: `src/` calls `uv-close!` once, in `handle-close!`, and makes no async handle and no engine. README.org and global-constraints already ask for a threaded Chez, and CI builds one with `--threads`.

Watched to fail: with the checkout moved and its gitlink staged, and the Makefile's pin not, `make check-pins` answered `PIN MISMATCH` (exit 2). With both moved, it passes.

`make test` green at v0.7.3: forty suites, 1,107 expected passes (shell 95), exit 0, 21 s, as main counted at v0.7.1.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1 `tarm64le`, `(threaded?)` #t), from a copy of the tree made with `COPYFILE_DISABLE=1`, the shim built there from v0.7.3's sources, curl 7.88.1 and ab 2.3 installed:
- `make test`, less its submodule and pin checks: forty suites, 1,107 expected passes;
- the shell suite, the contract and the integration suite, three runs each: 95, 56 and 5 passes each time.

CI's runs are still the billing block.

Records: global-constraints; design §5.4's note on the threads door; test-integration's version comment.

The pin moves alone: the gitlink and two changed lines, the Makefile's pin and test-integration's comment, besides these records.

DECIDED on the owner's word (2026-09-28), by form: one PR, the pin alone. Weighed: a review first; nothing committed.

NEXT: the PR, merged on the owner's word. Then M6.3 (plan §14), when the owner asks.

MERGED to main on 2026-09-28, on the owner's "do closing ritual": **the chez-libuv v0.7.3 pin, as one PR.**
- **#73, the pin,** as cfbf8cc. Its squash tree (1917601) is the tested tip's, 959e89d's, and its parent is e992ea5.
- **CI.** Its one run was the billing block, the `linux` job with 0 steps: 36493691705.
- **Branch.** Deleted local and remote, and refs pruned. No PR is open. `gh pr merge --delete-branch` merged #73 and deleted its remote branch, but left the checkout on it, so the switch to main, the fast-forward and the local deletion were done by hand.

`make test` green on main: forty suites, 1,107 expected passes.

DONE and merged (cfbf8cc, PR #73): **chez-libuv is pinned at v0.7.3.** A send that races an async handle's close is refused, where it could reach freed memory; `uv-close!` is one step; and a Chez without threads is refused by name. The server's code and counts are unchanged.

NEXT: M6.3 (plan §14), a streamed response, as M6.2's NEXT sets it out, on a fresh branch cut from main after this commit, when the owner asks.


M6.3: A STREAMED RESPONSE. Four stacked steps, cut from main at cbedab8: feat/m6.3-framing, then feat/m6.3-core-stream, feat/m6.3-stream-flows and feat/m6.3-socket, each on the one before; 2026-09-28, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. A fifth, fix/m6.3-small-pieces, on the fourth after the second review (2026-09-29, below).

SETTLED BY THE RECORDS, NO FORM: decision 0013 item 8 settled the API, a producer (a thunk answering a bytevector, or the eof object at the end), called only below the write's high water, chunked to HTTP/1.1 and close-delimited to 1.0; plan §14's M6.3 settled the rest: the rows, the two water marks with `notify-producer`, a bare close once the head is on the wire, and the plan's mutation.

CHOSEN WHILE BUILDING, flagged for review (decision 0013's section "Built"):
- The head goes out first, as every response's head does, and the producer is asked for its first piece once the head is written, so a producer that fails at its first call gets the bare close. Weighed: the head held for the first piece, one write fewer a response and a 500 for a first-call failure, which would leave the client of an M7 producer that awaits before its first piece with no head until then.
- An answer that is neither a bytevector of a byte or more nor the eof object is the producer failing: the shell reports `handler-failed`, the bare close, as it does a raise. The core's `producer-event` makes the answer an event, so both shells report it alike. Weighed: the core refusing the event as a caller bug. An empty bytevector was first written as nothing, the producer asked again; the review changed that (below).
- The water marks' edges: the producer is asked at or below the high water, and after waiting, at or below the low water and the high water both; a low water above the high water is refused at startup, whichever was set; equal marks and marks of 0 are accepted.
- While a piece is asked for with no write outstanding, no deadline is armed: the producer is the one waited on, and decision 0005 has no deadline for a handler. In v1 the shells call the producer in place, so its answer comes in the same drain.
- No body is written to a HEAD, a 204 or a 304, so their producer is never called.

FOUND WHILE BUILDING:
- The M5.2 note for M6.3, a body that stalls once a handler's head is on the wire, describes a case v1 does not reach: a handler's head goes on the wire only from `handling`, the body ended, or from `body` with a response given instead of a reader, which stops reading the body (decision 0013 item 4). No body deadline runs then, and the body's 408 stands (plan §14's note; the table's S4).
- Whether a failure after the head must reach the embedder, which plan §14 left to M6.3: it need not, since it is logged as `handler-failed` as every handler's failure is, so `&http-server-handler-error` stays undefined (design §6.4's note).
- The contract's first run of the bare-close script failed its first check: the server's bare close comes before it reads the client's half-close, the first close with no linger. Such a script is marked `(bare-close)`, and the check expects no end for it. And the contract rendered a response's body by identity, which would part the shells on any producer; a producer renders as one.
- M3.2's carried arm is reached only by an HTTP/1.0 client that asked to keep the connection; one that did not closes for that. The socket's and curl's HTTP/1.0 streams ask, so dropping the arm reddens a real client (the mutants, below).
- The allocation shape "a piece costs the same however many came before it" first compared the second 32 pieces' cost with twice the first 16's, and missed by 1 B, 9,729 B against 9,728: a collection's byte in an average. It compares per-piece quotients now.
- Splitting the slice into steps found `producer-event`, which the core exports in the second step, checked first in the stream suite of the third, so its mutants could not redden their own step. The check moved to the table's vocabulary checks.

DECIDED on the owner's word (2026-09-28), by form, after the plan-vs-landed walkthrough: a /code-review high first, its findings fixed on the owner's word, then four stacked PRs, each layer proven green on its own tree: about 230 inserted lines (the limits and the piece framing), 550 (the core's stream rows, both shells' `notify-producer` and the table), 440 (the fake shell's flows and the allocation shapes) and 220 (the socket, contract and curl checks), re-measured once the review's fixes are in. Weighed: the PRs without a review; three stacked PRs (about 230, 990 and 220); two (about 1,220 and 220).

REVIEWED before the first commit, at high effort (/code-review), on the owner's "fix all findings" (2026-09-28): six findings. Each fix's checks were written first and watched red, and each has its mutant.
- **An empty piece held the loop.** Written as nothing, the producer asked again, it let a producer that answered one while it had nothing ready be called again in the same drain for as long as it did, holding every connection. On the fake shell before the fix, a scratch program: 99,998 calls in one delivery, until its dispatch cap. An empty answer is now the producer failing, the bare close: `producer-event` refuses it, and the core refuses an empty `handler-body-chunk` as the shell's bug (S13). In v1 a producer cannot wait, so an answer that is no piece is its failure.
- **A low water above the high asked the producer past the high water.** `limits-with` checks no value; with a low water of 200 and a high of 90, a completion that left 92 bytes outstanding asked the producer again. A waiting producer is now asked at or below both marks (S17, red before the fix).
- **The docs said the server waits once 256 KiB are outstanding**; it waits once more than that is, and holds at most that and a piece. handlers.org says so.
- **The docs did not say a producer may never be called, or be let go early.** They do now, and that a port left open is closed when Chez collects it. The finding said Chez never closes one: its premise was half wrong. Measured by a scratch program, 20,000 opens of `/dev/null` under a 1,024-descriptor limit all succeed with a collection every 100, and fail at the limit with none. What stands: the close waits for a collection, which descriptors do not bring on.
- **Five suites wrote their producers each.** `tests/producers.sls`, `(producers)`, holds them: `producer-of`, `sized-producer`, `sized-body` and `counted`, for the stream, shell, contract and clients suites.
- **A size line was made for every piece.** A power of two's, 2^0 to 2^24, is now made once and shared, as the status lines are; a piece of any other length still makes its own. The core's cost a piece falls from 128 B to 112 B at 16 KiB.

Re-measured once the review's fixes were in: the four steps are 260, 596, 456 and 189 inserted lines of code and tests, where the form said about 230, 550, 440 and 220. None moved by fifty lines, so the shape stands, and was not asked again.


M6.3 FIRST STEP: the write water marks, and the piece framing (feat/m6.3-framing).
- `(http-server limits)`: the eighteenth and nineteenth fields, `write-high-water` and `write-low-water`, 262,144 and 65,536 bytes outstanding, from `CHEZ_HTTP_WRITE_HIGH_WATER` and `CHEZ_HTTP_WRITE_LOW_WATER` in bytes, with plan §3's four things; a low water above the high water refused at startup, whichever was set.
- `(http-server serializer)`: `serialize-piece`, a piece of a producer's body as the segments of one write, chunked (RFC 9112 §7.1) or close-delimited, never copied (a span is uv-write*!'s `(bv start end)`), a power of two's size line made once, an empty piece refused; `serialize-end`, the last chunk and an empty trailer section, or nothing when the close ends the body.
- The checks: `tests/test-limits.sps`, 51 (main's 46), the water marks; `tests/test-serializer.sps`, 171 (main's 147), the pieces, the end, their refusals, the size lines shared.
- Nothing calls the framing yet: the core does, in the second step. `response-fault` still refuses a producer, so a handler that answers one is answered 500 until then.

`make test` green on this step's own tree, a scratch tree of main with the step's files laid in: forty suites, 1,136 expected passes, exit 0.

Watched to fail (m6-mutations.md, the first step): twenty mutants on that tree, each reddening its own suite, and every check the step added or changed reddened by at least one.

Size: 260 inserted lines of code and tests, 20 deleted.

NEXT: the second step, the core streams a producer's body, stacked on this one.


M6.3 SECOND STEP: the core streams a producer's body (feat/m6.3-core-stream).
- `(http-server serializer)`: a producer's head writes no body, and a producer given a Content-Length is refused; `response-fault` takes a producer as a body. `(http-server response)` documents it.
- `(http-server connection)`: the stream, design §4.4's M6.3 rows. `respond-with` writes a producer's head and asks for its first piece when the head leaves the bytes outstanding at or below the high water; `handler-body-chunk` writes each piece and asks again at or below the high water, waiting past it; a completion asks a waiting producer again at or below both water marks; `handler-body-end` writes the last chunk, or, close-delimited, lets the close end the body, the response written once every write has completed; `handler-failed` with a piece asked for is a bare close; a piece or an end not asked for, or a piece of no bytes, is refused. Three fields hold the stream: the producer, the framing, and whether a piece is asked for. `conn-producer` and `producer-event` are exported for the shells: `producer-event` makes a producer's answer an event, refusing what is no piece, an empty bytevector among it. Every close lets the producer go. M3.2's carried arm is reached.
- Both shells perform `notify-producer`: `(fake-shell)`, and `(http-server private shell)`, which logs a producer's failure as a handler's. The fake's `write-wire` copies a span segment. Their checks are the steps' above.
- The checks: `tests/test-connection-table.sps`, 205 (main's 175), seventeen stream rows, S1 to S17, the vocabulary now wholly used, and a producer's answer as an event; `tests/test-serializer.sps`, 190, the producer's head in both framings and to a HEAD, read back by chez-httparse's response parser, and the refusals.
- Records: design §4.4's M6.3 amendment, §6.4's and §7.3's notes; decision 0005's amendment (the water marks), decision 0013's section "Built"; plan §14's M6.3 note; docs: handlers.org gains "Streaming a response", and responses.org and configuration.org the producer's framing and the two variables.

`make test` green on this step's own tree: forty suites, 1,185 expected passes, exit 0.

Watched to fail (m6-mutations.md, the second step): forty-seven mutants on that tree, the first step's twenty again and twenty-seven for the core and the producer's head, and every check the step added or changed reddened by at least one. The plan's mutation, M6.3-CA, high water ignored, reddens S6 and S7. The shells' `notify-producer`, and a waiting producer's asked flag, are watched in the third and fourth steps, where their checks are.

Size: 596 inserted lines of code and tests, 95 deleted, past plan §1 rule 1's ~400, as the form weighed.

NEXT: the third step, the fake shell's flows, stacked on this one.


M6.3 THIRD STEP: the fake shell's flows, and the allocation shapes (feat/m6.3-stream-flows).
- `tests/test-connection-stream.sps`, new, 15 checks: every stream read back by chez-httparse's response parser, with a trace reading the bytes outstanding at every ask and write: HTTP/1.1 chunked, HTTP/1.0 close-delimited, HEAD and 204; a MiB under 0005's marks never more than a piece's write past the high water; small marks, every ask at or below the high water and every one after a completion at or below the low; four bare closes, an empty answer among them; one bytevector handed out again; a producer in place of a reader, a reader's response streamed, a GET behind a stream; a transport failure and the write deadline mid-stream letting the producer go.
- `tests/test-connection-allocation.sps`, 26 (main's 21): a piece costs the same however many came before it, at 16 KiB what it does at 128 bytes, and more at 100 bytes, its size line.
- `tests/producers.sls`, new, `(producers)`: the producers the suites stream from.

`make test` green on this step's own tree: forty-one suites, 1,205 expected passes, exit 0.

Watched to fail (m6-mutations.md, the third step): fifty mutants on that tree, the second step's forty-seven again and three more, the fake shell's `notify-producer` (FA) among them, and every check the step added reddened by at least one, but the allocation shape's calibration, the instrument's guard. The plan's mutation, M6.3-CA, reddens the slow reader's bound in the fake shell's flows.

Size: 456 inserted lines of code and tests.

NEXT: the fourth step, a streamed response on a socket, stacked on this one.


M6.3 FOURTH STEP: a streamed response on a socket, in the contract, and to curl (feat/m6.3-socket).
- `tests/test-shell.sps`, 106 (main's 95): a MiB to a client that reads nothing yet, its writes waiting, the bound kept, then read whole; HTTP/1.0 asking to keep the connection, read at the close; a GET behind a stream; a bare close, logged.
- `tests/test-contract.sps`, 65 (main's 56): three scripts, chunked, HTTP/1.0 and the bare close, which is marked; the replay records a raise in the fake's trace, where it ended the suite; a producer renders as one.
- `tests/test-clients.sps`, 13 (main's 11): curl reads a chunked stream and a GET on its connection, and an HTTP/1.0 stream kept alive, read to the close.

Measured on the finished tree (2026-09-28, Darwin arm64):
- `make test` green: forty-one suites, 1,227 expected passes, exit 0. On main, measured in a scratch worktree the same day: forty suites, 1,107.
- The allocation suite: curl's GET 1,840 B and the JSON POST 2,624 B read whole and 2,432 B streamed, as on main; curl's GET streamed in 16, 32 and 64 pieces of 100 bytes 7,088, 11,952 and 21,681 B, a piece 304 B through the suite's harness; eight pieces of 16 KiB and of 128 bytes 4,528 B each, of 100 bytes 4,656 B.
- A scratchpad probe, two runs, the same: a piece costs the core 112 B when its length is a power of two and 128 B otherwise, and the producer's event 64 B.
- The shell suite five runs of five green.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1 `tarm64le`, threaded), from a copy of the finished tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and ab 2.3 installed:
- `make test`, less its submodule and pin checks: forty-one suites, 1,227 expected passes, the allocation figures the same;
- the shell, contract, stream and clients suites, three runs each: 106, 65, 15 and 13 passes each time.
CI's runs are still the billing block.

Watched to fail (m6-mutations.md, the fourth step): fifty-three mutants on the finished tree, the third step's fifty again and the libuv shell's three, and every check the step added or changed reddened by at least one. The plan's mutation, M6.3-CA, reddens the slow reader's bound on a socket as well; M6.3-CC, the carried arm dropped, the HTTP/1.0 stream in the fake shell, on a socket and in curl.

Size: 189 inserted lines of code and tests, 31 deleted; the slice, 1,501 and 146.

M6.3 SECOND REVIEW (2026-09-29), on the owner's ask, before the PRs: the empty piece's fix checked again for safety and performance.

HELD: an empty piece closes its own connection alone. On a socket (a scratch server whose producer answers a piece, then an empty bytevector): curl read the head and the piece, then the body cut short (its error 18); the log named the empty bytevector, in 145 characters; the next request was answered in 0.9 ms. The shells' guard holds only the producer's call and its answer's check, so the core's refusal is never blamed on the handler, and the fix costs a piece one length check.

FOUND (a scratch server whose producers never end, and a probe in Python: a client reading as fast as it can, another sending a GET every 2 ms, and clients that never read, the server's RSS read; one run each):
- **The empty piece was the limit of a slope.** The water marks count bytes, but each piece is a write of its own, which holds the loop and memory the same whatever its size: so a turn asked some 2,500 times for 100-byte pieces and some 43,700 for 1-byte ones chunked. On Linux (Debian 12, libuv 1.44.2, in Docker, aarch64), another client's request waited 50.6 ms at the median (62.9 at most) behind 100-byte pieces, 1,019 ms (1,697) behind 1-byte ones, and 0.11 ms behind 16 KiB ones. On Darwin arm64 (libuv 1.52.1): 250 ms (359), over 5 s, and 1.83 ms. A high water of 16 KiB cut the Darwin 100-byte wait to 12.8 ms: the wait follows the pieces a turn asks for.
- **The slow reader's bound held for large pieces only.** Each write outstanding holds a `uv_write_t` (192 bytes at libuv 1.52.1, measured with `sizeof`), 16 bytes a segment and chez-libuv's records, on top of its bytes. Per client that never read, Linux: 0.26 MB of 16 KiB pieces, 0.71 MB of 100-byte ones, 21.6 MB of 1-byte ones chunked, 129.5 MB of them to HTTP/1.0 (Darwin: 0.18, 0.69, 12.4, 102.7 MB), where handlers.org promised 256 KiB and a piece.
- **A wrong answer was logged whole**: `producer-event` named the answer itself, and a 100,000-character string answered for its bytes made a 100,141-character log line.
- **The docs pointed at ports that make a producer wait**: `get-bytevector-some` on "a binary input port", a pipe's or a socket's among them, and "return a piece only once you have one", which reads as waiting for one.

DECIDED on the owner's word (2026-09-29), by form, after a second form that set the options out: (1) the writes outstanding bounded at 64, a waiting producer asked again at 16 or fewer, fixed values. Weighed: the cap and the server gathering small pieces into writes of about 16 KiB, about 28 times the throughput by a handler that gathers, but a change to the core's pacing and the serializer's framing, not prototyped; docs only. (2) An answer that is no piece named by its kind and length. Weighed: as it was. (3) A fifth stacked PR on the four, which stay as proved. Weighed: folding the fixes into the four. The doc wording goes with them.

M6.3 FIFTH STEP: small pieces capped, a wrong answer named by its kind (fix/m6.3-small-pieces), on feat/m6.3-socket.
- `(http-server connection)`: `below-high-water?` asks too for fewer than `stream-writes-high`, 64, writes outstanding, and `stream-completed` asks a waiting producer again at `stream-writes-low`, 16, or fewer. `producer-event`'s violation names the answer by `answer-kind`: `(string 5)`, `(list 2)`, `(symbol)`, `(other)`.
- `tests/test-connection-table.sps`, 210 (the fourth step's 205): S18 and S19, the cap and its resume; the answer's kind and length, never held; nineteen stream rows.
- `tests/test-connection-stream.sps`, 16 (15): a thousand 100-byte pieces, never more than 64 writes outstanding, every ask after a completion at 16 or fewer; the watch reads the writes with the bytes.
- `tests/test-shell.sps`, 110 (106): 4,000 rows of 100 bytes to a client that reads nothing yet, never more than 64 writes outstanding, then read whole and in order.
- `tests/test-connection-allocation.sps`, 26 (26): the harness performs a completion that asks for a piece; the per-piece shape compares 16, 32 and 48 pieces.
- Docs: handlers.org (the cap, gathering small rows, answering at once, a file's port, the log's naming); configuration.org (the two fixed counts).
- Records: design §4.4's M6.3 amendment and §7.3's note; decision 0005's amendment of 2026-09-29, with its prior art (h2o, nginx, Node, Go, warp and Apache, and hyper and libuv beside them, checked against their sources on the owner's ask after the PRs opened); decision 0013's second review; plan §14's note.

FOUND WHILE BUILDING:
- The allocation harness completed a stream's writes but dropped what the completions asked for, so its 64-piece stream stopped at the cap, not written whole. It performs a completion that asks for a piece now, only that one, so a stream that never waits costs what it did: a piece 304 B, the harness's own 32 B more a stream.
- The per-piece shape compared the 17th to 32nd pieces with the 33rd to 64th, and at 64 a wait at the cap put a completion's cost among the pieces': 353 B against 352. It compares the 33rd to 48th now, and CX, the growing log, still reddens it.
- The S19 helper first completed its writes by literal counts, so a mutant that miscounts a chunk made the stream rows raise while built; it reads each write's count from the state now.
- Three mutants were orphaned by the rewrite, CA, CB and CP, and re-cut on the new text.

Measured on the finished tree (2026-09-29, Darwin arm64):
- `make test` green: forty-one suites, 1,237 expected passes, exit 0.
- The allocation suite: curl's GET streamed in 16, 32 and 48 pieces of 100 bytes 7,120, 11,984 and 16,849 B, a piece 304 B; eight pieces of 16 KiB and of 128 bytes 4,560 B each, of 100 bytes 4,688 B.
- A wrong answer's log line: 154 characters for a 100,000-character string, 153 for an empty bytevector.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1, libuv 1.44.2), from a copy of the finished tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and ab 2.3 installed:
- `make test`, less its submodule and pin checks: forty-one suites, 1,237 expected passes;
- the shell, stream, table and allocation suites, three runs each: 110, 16, 210 and 26 each time; the clients suite three runs, 13 each;
- the probe on the finished tree: another client's request waited 0.91 ms at the median (10.5 at most) behind 100-byte pieces, 0.90 ms (12.2) behind 1-byte ones and 0.11 ms (4.9) behind 16 KiB ones, 0.28 ms (16.4) with no stream; the streams read 31.2, 1.7 and 2,097.9 MB/s, and 100-byte pieces a handler gathered into 16 KiB 873.0 MB/s; per client that never read, 0.07 MB of 100-byte pieces and 0.26 MB of 16 KiB ones, and of 1-byte ones no growth measurable, the RSS falling as the heap was collected.
CI's runs are still the billing block.

Watched to fail (m6-mutations.md, the fifth step): sixty-two mutants on the finished tree, the fourth step's fifty-three again, three of them re-cut, and nine more, and every check the step added or changed reddened by at least one. The plan's mutation, M6.3-CA, still reddens the slow reader's bound with the cap in place: 16 KiB pieces meet the byte marks first.

Size: 243 inserted lines of code and tests, 61 deleted; the slice, 1,744 and 207.

NEXT: the five stacked PRs, merged bottom up on the owner's word. Then M6.4 (plan §14), Expect, trailers and the exit's files, when the owner asks.

MERGED to main on 2026-09-29, on the owner's "do closing ritual": **M6.3, as five stacked PRs**, bottom up.
- **#74, the water marks and the piece framing,** as 6fe5651. Its squash tree (48cc431) is the tested tip's, 0c52f12's, and its parent is cbedab8.
- **#75, the core's stream,** as aad6b3d, once retargeted to main and rebased from #74's old tip: the rebased tip dcc0fe5's tree (5eac99b) is ed485c1's.
- **#76, the fake shell's flows and the allocation shapes,** as bc273ab: 7129804, tree ff82f8d, 97629f5's.
- **#77, the socket, contract and curl checks,** as 6a34361: 03545b5, tree 44c474d, 4c301cc's.
- **#78, the second review's fixes,** its two commits squashed as ea2563a: 3eef27d, tree 3370d89, 4ce8a71's.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36555535033 for #74, and 36571384652, 36571471283, 36571542231 and 36571643014 for the rebased tips.
- **Branches.** All five deleted local and remote, and refs pruned. No PR is open. The four lower PRs merged without `--delete-branch`. #78's merged it and deleted its remote branch, but left the checkout on it, so the switch to main, the fast-forward and the local deletions were done by hand. After each force-push the first read showed the old head (CONFLICTING/DIRTY for #76 to #78), and the second the rebased head, MERGEABLE/UNSTABLE.

`make test` green on main: forty-one suites, 1,237 expected passes.

DONE and merged (6fe5651, aad6b3d, bc273ab, 6a34361 and ea2563a; PRs #74 to #78): **a streamed response.** A handler's body of unknown length is a producer, chunked to HTTP/1.1 and close-delimited to 1.0. The write water marks, and 64 writes outstanding, pace it. A producer's failure after the head is a bare close, logged by its answer's kind and length.

DECIDED on the owner's word (2026-09-29), by form, while the PRs were open: **write batching goes up as its own PR, after these five.**
- **What it does.** A turn's writes under 4 KiB are copied as each is handed over, and sent as one `uv-write*!` at the drain's end, and before a shutdown or a close. A larger write sends the batch first, then goes as today. It changes the libuv shell alone: the core, its events and the contract are unchanged.
- **A scratch prototype, one run each.** On Linux, 100-byte rows 31.6 to 160.0 MB/s, and another client's median wait 0.88 to 0.22 ms; 16 KiB pieces unchanged. On Darwin, 100-byte rows 6.9 to 113.5 MB/s.
- **The copy is required.** Without it, a producer that refills one bytevector, which handlers.org allows, sent every piece of a turn as its last.
- **Where the cost was.** The core alone costs 0.08 µs a piece, so nearly all of a small piece's cost is the write path.
- **No chez-libuv issue.** `uv-write*!` and the dev-build write-request counts are all the PR uses. `uv_try_write`, and idle or check handles, would help little once batching is in, and are unmeasured.
- **Weighed:** a sixth stacked PR; a note for later.

NEXT: write batching (above), its own PR on a fresh branch cut from main after this commit, as the owner chose. Then M6.4 (plan §14), Expect, trailers and the exit's files, when the owner asks.


WRITE BATCHING, after M6.3 (feat/write-batching, cut from main at 73cfeb5): the libuv shell holds a turn's small writes and sends them as one libuv write, as the owner chose by form, its own PR after M6.3's five.
- `(http-server private shell)` alone. `write!` holds a write under 4,096 bytes (`held-below`): `hold!` copies its bytes as it holds it, behind those held, into the connection's chunks, each new one twice the last's length or the write's, so no byte is copied again before chez-libuv's copy. The drain sends what is held, `flush!`, once it has run the queue empty, and runs on while that queues more; `run!` sends it first before a `shutdown` and a `close`, and `write!` before a write of 4,096 bytes or more, which goes out alone, as before. `send!` makes every write, one guarded `uv-write*!`, and its completion, `write-done`, reports each write it carried as `write-completed`, in the order written, after one `read-error` if it failed. A raise drops what is held with what is queued. The core, its events, the water marks, the 64-write cap and the contract are unchanged.
- The checks: `tests/test-shell.sps`, 119 (main's 110): the rows a turn writes are one write request of chez-libuv's, where the core counted 48 of its writes (Darwin); each 16 KiB piece's write is one of its own; 4,000 rows handed out in one bytevector, refilled at each call, read back whole, each as it was handed over; rows whose client goes while they are outstanding, a read error, then each row's write settled, none left outstanding; a bug once a write is held sends nothing, and the close is the connection's last event. `tests/producers.sls` gains `refilled-producer`, which the stream suite's bytevector handed out again now uses (16 checks, as on main).
- Records: design §7.3's note; decision 0005's amendment of this day, and decision 0013's note; plan §14's note; docs: handlers.org (the server gathers small pieces; gathering them in the handler is still about 4.7 times faster; a piece copied as the server takes it) and configuration.org (what the 64-piece count bounds).

FOUND WHILE BUILDING:
- **chez-libuv needs no change, and no issue was filed.** Its `uv-write*!` packs a write's spans end to end in one block, but gives libuv one `uv_buf_t` a span, and libuv 1.52.1 mallocs the array of a write with more than four (`src/unix/stream.c:1370-1372`). A scratch chez-libuv giving libuv one buffer over the packed spans measured 1 to 5 % faster for 64-span writes (Linux, three runs each); the chunks make a few spans a turn.
- **Three shapes, as scratch prototypes** (Linux, three runs each, the median, for 1, 100, 1,000 and 4,000-byte pieces): each held write a bytevector of its own, 64 segments a turn, 9.7, 166, 917 and 1,534 MB/s; one bytevector grown by copying, 11.8, 172, 762 and 1,088, slower than the first at 1,000 and 4,000 bytes; chunks never copied again, 11.8, 186, 990 and 1,580, as built.
- **The cutoff stays at 4 KiB.** Held too, 8 KiB pieces streamed faster on Linux, 1,708 MB/s against 1,465, and 16 KiB ones slower, 1,814 against 2,080; on Darwin both were faster held (one run).
- **A raise now sends nothing held.** On main, a bug once the head was written still sent the head, and an HTTP/1.0 client can take a close-delimited body cut short for a whole one. A held write is dropped with the queued actions a raise drops.
- **One guarded write.** The refused write M4.2's check sends is a held one now, sent as the drain empties, so `write!`'s own guard would have been checked by nothing; every write goes through `send!`.
- The first cut of the mutant that drops the copy kept the chunks, so each write it sent ended with an empty span, which libuv finishes a turn later (`uv__write_req_update` stops on a trailing empty buffer), so a close cancelled it. Re-cut with no chunks. The finished code sends no empty span: the core writes only segments with bytes.

Measured on the finished tree (2026-09-29, Darwin arm64):
- `make test` green: forty-one suites, 1,246 expected passes, exit 0.
- The red before green: against main's shell, the finished tests failed twice. The rows' one-write check read the core's 52 writes outstanding and 52 write requests, and the held write's bug check read the head main sent.
- A scratch server whose producers never end, a client reading as fast as it can, another sending a GET every 2 ms, main against the finished tree, three runs each, the median: 1-byte pieces 0.4 to 7.8 MB/s, 100-byte 7.3 to 131.9, 1,000-byte 68.1 to 898.8, 4,000-byte 264.5 to 1,370.5; another client's median wait behind the 100-byte pieces 3.24 ms to 0.37; 8 and 16 KiB pieces as before, 522.5 and 799.0 MB/s.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1 `tarm64le`, threaded, libuv 1.44.2), from a copy of the finished tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and ab 2.3 installed:
- `make test`, less its submodule and pin checks: forty-one suites, 1,246 expected passes;
- the shell, contract, stream and clients suites, three runs each: 119, 65, 16 and 13 each time;
- the probe, the same way: 1-byte pieces 1.9 to 11.4 MB/s, 100-byte 32.4 to 180.8, 1,000-byte 274.4 to 965.0, 4,000-byte 899.6 to 1,578.4; another client's median wait behind them 0.80, 0.81, 0.82 and 0.93 ms to 0.19, 0.20, 0.29 and 0.62; 8 and 16 KiB pieces as before, 1,444.0 and 2,107.6 MB/s; 100-byte rows a handler gathers into 16 KiB pieces 852.6 MB/s, about 4.7 times the rows one at a time, where it was about 26;
- ten clients that never read, one run each: 0.05 MB each of 100-byte pieces and 0.26 MB of 16 KiB ones, as on main, and 0.04 MB of 1-byte ones.

Watched to fail (m6-mutations.md, "Write batching"): twenty-one mutants on the finished tree against all forty-one suites, sixteen of them new (batch-A to batch-O, and batch-A2, a calibration), M4.2's four on the write path re-cut on the new code, and M4.2-X re-run; every check this change added or changed is reddened by at least one. Three survive: batch-D, the writes held not sent before a shutdown, a scope statement, since the core asks for a shutdown only once every write has completed; batch-L, the chunks' growth, a scope statement, a cost and never the bytes; batch-A2, the calibration, as meant.

Size: 259 inserted lines of code and tests, 73 deleted: one PR, under plan §1 rule 1's ~400.

DECIDED on the owner's word (2026-09-29), by form, after the walkthrough: committed and opened as one PR. Weighed: holding it for changes.

NEXT: the PR, merged on the owner's "do closing ritual". Then M6.4 (plan §14), Expect, trailers and the exit's files, when the owner asks.


WRITE BATCHING, ITS REVIEW (2026-09-29, PR #79 open): a /code-review high, on the owner's ask, found seven, none a correctness bug; then, on the owner's ask, a deeper review of three of them, each measured with scratch prototypes.
- (1) **A stream's head waited for the turn.** What was held went out only as the drain emptied, so a stream's head and first pieces waited for the turn's producer calls, up to 64. On Linux (Docker, five runs each, the median), a producer taking 200 µs a piece delayed its head from 0.12 ms to 12.74, one taking 2 ms from 0.14 to 126.3, one answering at once from 0.08 to 0.12; every stream still ended as soon or sooner. Two fixes were prototyped: what is held sent before the drain's first producer call, the head back at 0.10 to 0.19 ms, throughput unchanged (100-byte pieces 180.3 MB/s against 183.7); and what has been held a millisecond sent before each producer call, a slow producer's pieces as made, but fast small pieces 5 to 17 % slower (1-byte 11.5 MB/s to 9.6) and a turn's batch hanging on time, one check failing.
- (5) **`hold!`'s `fold-left` made a closure for every write held:** 32 bytes and some 6 ns in a scratch library (28.5 ns against 22.8 for a named let); through a whole process, some 15 of a piece's 1,430 bytes, its time within noise.
- (6) **The copy of a lone small response is not waste:** a process serving itself small keep-alive GETs allocated 367 bytes a request less than main's (11,561 against 11,928), one span costing chez-libuv less than four segments, and a prototype sending a lone write by reference 384 more (Darwin, 20,000 requests, three runs each).
- The other four: (2) a turn's one write refused at the call was tested with one write only; (3) handlers.org's "under 4 KiB" left out the chunk framing; (4) a completion's writes are dispatched one by one, so the producer refills at 16 and a batch carries 48; (7) the dev-build counters' guard is repeated in the shell suite.

DECIDED on the owner's word (2026-09-29), by form, after the deeper review: (1) what is held goes out before the drain's first producer call, and handlers.org says the pieces go out a turn at a time; weighed: the docs alone; a flush after a millisecond. (5) a named let. (2) and (3) fixed. (4) and (7) left. (6) no change, the premise measured wrong.

The fixes, a second commit on feat/write-batching:
- `(http-server private shell)`: the connection's `producer-called?`, cleared as each drain starts; `run!` sends what is held before the drain's first `notify-producer`. `hold!` copies with a named let.
- The checks: `tests/test-shell.sps`, 125 (the first commit's 119): a stream's head sent before its producer is first called, one write request, on a stream behind another on one connection; rows whose handle is closed behind the core mid-turn, the turn's one write refused at the call, a read error, then each row's write settled, none outstanding; pieces of 100 bytes and 5,000 in turn, read back in order.
- Docs: handlers.org, gathered pieces of up to 4,088 bytes, the headers before the producer's first call, the pieces up to 64 at a time.
- Records: design §7.3's note, re-measured; decision 0005's amendment and 0013's note; plan §14's note; m6-mutations.md, "After the PR's review".

FOUND WHILE FIXING: sending the head first let batch-E, the writes held not sent before a larger write, survive: the MiB's check had killed it, its head held when its first 16 KiB piece was written, and now nothing is held then. The mixed pieces' check was added for it.

Measured on the fixed tree (2026-09-29):
- `make test` green on Darwin arm64: forty-one suites, 1,252 expected passes, exit 0. On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, libuv 1.44.2), from a copy made with `COPYFILE_DISABLE=1`, curl and ab installed, less the submodule and pin checks: forty-one suites, 1,252; the shell, contract, stream and clients suites three runs each: 125, 65, 16 and 13 each time.
- Red before green: on the first commit's shell, the head-first check failed, its producer's first call finding no write request more than the handler had.
- The head, Linux, five runs each, the median, for producers taking 0, 20, 200 and 2,000 µs a piece: 0.10, 0.10, 0.13 and 0.19 ms, where main sent it at 0.09, 0.09, 0.12 and 0.20; the first piece at 0.10, 1.37, 12.76 and 126.37, where main's at 0.09, 0.09, 0.33 and 2.22; the stream's end at 0.26, 5.32, 51.52 and 513.03, where main's at 0.95, 6.32, 53.11 and 515.16. On Darwin the head at 0.21 to 0.32 ms, where main's at 0.13 to 0.27.
- The probe, main against the fixed tree, three runs each, the median. Linux: 1-byte pieces 1.9 to 11.4 MB/s, 100-byte 32.8 to 182.9, 1,000-byte 284.2 to 989.1, 4,000-byte 864.8 to 1,569.7; 8 and 16 KiB as before, 1,444.9 and 2,066.0; another client's median wait behind the 100-byte pieces 0.85 ms to 0.19; 100-byte rows a handler gathers 851.1 MB/s, about 4.7 times the rows one at a time. Darwin: 1-byte 0.4 to 7.9, 100-byte 7.3 to 132.4, 1,000-byte 68.2 to 905.2, 4,000-byte 265.5 to 1,385.1; the wait 3.24 ms to 0.37.
- Ten clients that never read, Linux, one run each: 0.03 MB each of 100-byte pieces, where main's 0.05, and 0.26 MB of 16 KiB ones, as main's.
- One process serving itself (Darwin, three runs each): a small keep-alive GET 11,577 bytes and 53.4 µs, where main's 11,920 and 54.3; a streamed 100-byte piece 1,661 bytes and 0.73 µs, where main's 3,913 and 12.2 µs.

Watched to fail (m6-mutations.md, "After the PR's review"): twenty-five mutants on the fixed tree against all forty-one suites, the twenty-one before, three of them re-cut for the named let, and four new, batch-P to batch-S; every check the fixes added is reddened by at least one. Three survive, as before: batch-D and batch-L, scope statements, and batch-A2, the calibration.

Size, the second commit: 122 inserted lines of code and tests, 28 deleted; the PR against main, 361 and 81, under plan §1 rule 1's ~400.

NEXT: the PR, updated, merged on the owner's "do closing ritual". Then M6.4 (plan §14), Expect, trailers and the exit's files, when the owner asks.

MERGED to main on 2026-09-29, on the owner's "do ritual": **write batching, PR #79**, its two commits (c7014af, d1bdb41) squashed as 83cebc9. Its squash tree (6c1846c) is the tested tip's, d1bdb41's, and its parent is 73cfeb5.
- **CI.** Both runs were the billing block, the `linux` job with 0 steps: 36593668069 for c7014af and 36635425131 for d1bdb41.
- **Branches.** `--delete-branch` merged it, switched this checkout to main, fast-forwarded it, and deleted the branch local and remote; `git fetch --prune` cleared the remote ref. No PR is open.

`make test` green on main: forty-one suites, 1,252 expected passes.

DONE and merged (83cebc9; PR #79): **write batching.** The libuv shell holds a turn's small writes and sends them as one libuv write, a stream's head first. On Linux, 100-byte pieces stream 182.9 MB/s where they streamed 32.8, and another client waits 0.19 ms at the median behind them where it waited 0.85; the core, its events and the contract are unchanged.

NEXT: M6.4 (plan §14), Expect, trailers and the exit's files, when the owner asks.


M6.4, EXPECT, TRAILERS AND THE EXIT'S FILES (feat/m6.4-expect-trailers, cut from main at e1a57f6), on the owner's "Let's start on M6.4".

DECIDED on the owner's word (2026-09-29), by form, before anything was built, each on numbers measured on main (Darwin arm64, the fake shell, and curl 8.7.1 against a scratch server):
- **Trailer fields are held to the four header limits, counted afresh.** On main, 101 trailer fields, a 9,000-byte trailer value and 16 MB of trailers were each answered 200. Weighed: one budget with the head; the body's cap, as freenginx counts them, which would leave them unbounded by default here.
- **A body's chunk extensions, all of them together, are held to 16 KiB, answered 413** (found, not in the plan). On main a 16-byte body carrying 16 MB of extensions was answered 200: the kind of attack Node's CVE-2024-22019 fixed. hyper holds a body's to 16 KiB; Node holds each chunk's to 16 KiB, with a 413 (corrected in the review below: the form called 16 KiB "hyper's and Node's figure"). Weighed: left for M8.3.
- **An Expect other than 100-continue is ignored**, as nginx and hyper ignore it. Weighed: 417, as Go, Apache, Node and Python answer.
- **libhtp's two Expect files are delivered with CRLF**, and 99's handler refuses `/forbidden` as its recorded origin did: after a discussion the owner asked for ("i need more discussion on this"). Both files end their lines in a bare LF, which the strict parser refuses at the first line (`invalid-version`, bytes 16 and 24), so as vendored they check only that, which llhttp's fixture "Only LFs present" pins already. Weighed: their 400s; our own CRLF copies; left not-yet, the M6 exit amended.
- **What the parser reads and hands the core no span of gets its own PR, after M6.4** (found while checking the extension cap): the spaces between a field's colon and its value, in a head or a trailer section, and a chunk size's leading zeros; a megabyte of either was answered 200. Weighed: folded into M6.4; asked of chez-httparse first (decision 0008). Go refuses a chunk size of more than 16 hex digits and a size line over 4 KiB, nginx a header line over 8 KiB.

What was built:
- `(http-server connection)`: a request's client waits for `100 Continue` when it is HTTP/1.1, announces a body, and its Expect lists 100-continue (`body-continue?`); then the head arms no body deadline. Accepting a reader writes the 100 first, `accept-reader`, before what reading brings (`read-with`, the rest of the old procedure), and arms the body deadline while the connection still reads; a reader refused by its cap, a response instead, and a handler that raises get their final status alone (the review below: a cap the body met so far passes is answered after the 100). The 100's completion is settled in `body`, `handling` and `awaiting-credit` too. In `body`, a trailer's name and value are counted as a head's are (`trailer-bytes`, and `field-bytes` and `field-counted`, shared with the head's `header-bytes`), the head's sizes started again for them, and a chunk extension's name and value bytes are counted over the whole body against `max-chunk-extension-bytes`, 16,384 (`extension-bytes`).
- `(http-server headers)`: `field-lists?`, whether a field's comma-separated list holds a token, without regard to case, OWS trimmed, over any of its lines, read in place.
- `(http-server serializer)`: `serialize-continue`, the 100 as one shared segment, its status line and the blank line.
- `(http-server decisions)`: `chunk-extensions-too-large`, 413.
- `tests/libhtp-lane.sls`: `libhtp-packets`, the two Expect streams delivered with CRLF (`crlf-files`); `handler-for`, 99's refusing `/forbidden`; the two expectations. `tests/ratchet.txt`: both promoted, fourteen libhtp streams passing.

The checks:
- `tests/test-connection-table.sps`, 258 (main's 210): E1 to E7 for Expect, E8 for the 100's completion through M3.3's accounting step, F1 to F7 for the trailers and extensions, and their three counts.
- `tests/test-connection-expect.sps`, new, 14: at every delivery size, the 100 first for a streaming and a whole reader, the 100 as a client reads it, none for a response instead, on HTTP/1.0, with no body, or for another expectation; the 408 once the body deadline armed with the 100 passes; trailers as large as a head after a head near the limits served, and a section, a count and a value past them answered 431; extensions at 16 KiB served over two chunks, and a byte more 413, at sampled sizes.
- `tests/test-headers.sps`, 21 (18): `field-lists?`.
- `tests/test-shell.sps`, 129 (125): a client that waits for the 100 on a socket reads it alone before it sends its body, then the response; one answered at once gets no 100 and the stream's end.
- `tests/test-contract.sps`, 68 (65): a body expecting 100-continue, sent once the server has read the head.
- `tests/test-clients.sps`, 14 (13): curl, with `--expect100-timeout 60`, reads the 100, then the response.
- `tests/test-connection-originated.sps`, 23 (21): a body's extensions past 16 KiB, 413; a trailer value past its limit, 431; both with `kept`, the shape of a refusal met in the head's delivery.
- `tests/test-libhtp-lane.sps`, 19 (15): fourteen streams; the scope over the streams as delivered; every other stream delivered as cut; the two converted and nothing else changed. `tests/test-ratchet.sps`, 9: fourteen passing, 88 not-yet.
- Records: design §4.3's `body` row and §4.4's M6.4 amendment, §8.2's note; decision 0013's built note; decision 0005's amendment of this day; plan §14's note. Docs: handlers.org (Expect, trailers), connections.org (the 100 and the body timeout), configuration.org (the trailers' and extensions' limits), responses.org (413, 431).

FOUND WHILE BUILDING:
- **The 100 goes out though the whole body came with the head.** Omitting it then, as RFC 9110 allows, would make what happens depend on how the bytes were split into reads; a client must be able to read a 100 it did not wait for.
- **The Expect files' bodies say where their line ends came from.** 05's is curl 7.18's upload, and its body is its Content-Length, 216 bytes, only with CRLF: 210 as vendored. 99's was written by hand: its 14 bytes count a bare LF.
- **The lane's scope holds as delivered.** Its check counts the streams that carry pipelining or a split request; with CRLF both Expect streams carry a request split across packets, so the scope check reads the packets the lane delivers.
- **Two survivors, J and K**: the 100's completion ignored in `handling` or `awaiting-credit` leaves the phase and actions as they were, and E8 read only those. On a v1 shell those completions cannot come there, the reader's response following in the same turn, so only a row can reach them; E8 now reads the writes outstanding, and both redden it.
- **Four contract scripts were written and taken out**: the trailers and extensions within and past their limits, and an Expect head answered at once. The shells share the core and differ in nothing those scripts exercise, so no fault of either could redden them. The contract keeps the one new thing a shell does, a write while the connection still reads.

Measured on the finished tree (2026-09-29, Darwin arm64):
- `make test` green: forty-two suites, 1,331 expected passes, exit 0 (main's forty-one, 1,252).
- Red before green: against main's source, the finished table failed 24 checks, the new flows suite 8, the shell suite 2, curl's 1 (held past the cap, 24 s), and the lane's 05.
- curl 8.7.1 asks for the 100 on an upload of 1,048,577 bytes or more, POST and PUT alike, and not at 1,048,576. Against a scratch server, main's source and this tree, three runs each: a 2 MiB POST took 1.016 s on main, waiting out curl's own second, and takes 5.4 to 6.4 ms; with Expect off, main 5.9 to 20.7 ms and this tree 5.0 to 5.3; a 100-byte POST with Expect forced, main 1.011 to 1.012 s, this tree 0.87 to 0.88 ms; a handler that refuses at once, 403 and no byte uploaded, main 0.9 to 1.2 ms, this tree 0.7 to 0.9.
- The probes that measured main, run again (the fake shell, the default limits): 101 trailer fields, a 9,000-byte trailer value and 16 MB of trailers are answered 431, the 16 MB refused in 3.0 ms of CPU where they were read in 40; 16 MB of extensions on a 16-byte body 413 in 2.5 ms, where 65; a MB of spaces before a field's value, in a head or a trailer section, and a MB of a chunk size's zeros, still 200, the next PR's.
- The allocation suite's figures are main's: curl's GET 1,840 B, the JSON POST 2,624 read whole and 2,432 streamed, ab -k's GET 2,112. A scratch probe, two runs: the Expect check costs a POST without Expect nothing, and a POST expecting 100-continue 128 B more than one with a field of the same size that is not Expect, the 100's write and its completion.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1, libuv 1.44.2), from a copy of the finished tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and ab 2.3 installed:
- `make test`, less its submodule and pin checks: forty-two suites, 1,331 expected passes;
- the shell, contract, flows and clients suites, three runs each: 129, 68, 14 and 14 each time;
- curl 7.88.1 asks for the 100 from 1,048,577 bytes too; a 2 MiB POST, three runs each: main's source 1.006 to 1.017 s, this tree 1.2 to 1.8 ms; with Expect off, main 1.2 to 2.1 ms, this tree 1.1 to 1.3 ms.

Watched to fail (m6-mutations.md, "M6.4"): forty mutants on the finished tree against all forty-two suites, thirty-nine by `mut.py` and one by hand, and every check this slice added or changed reddened by at least one. None survives: J and K did, until E8 read the writes outstanding. The plan's mutation, the 100 written with the head (M6.4-A), turns the Expect rows red, E1 to E6, and the flows, the lane's two files and the socket's refusal.

Size: 1,079 inserted lines of code and tests (the new flows suite's 252 among them), 112 deleted; over plan §1 rule 1's ~400, so it goes up as PRs of their own.

DECIDED on the owner's word (2026-09-29), by form, after the walkthrough: **three stacked PRs**, each green on its own, proved in a scratch tree of its own files before its commit: the 100 in the core and the fake shell, with the header helper; the 100 on the wire, in the socket, contract and curl checks, and libhtp's two files; the trailer and extension limits, with the records. Weighed: two, four (the header helper apart), one. Measured once cut, against main, then each on the one below: 527, 206 and 359 inserted lines of code and tests, and 60, 42 and 23 deleted, where the form estimated about 460, 210 and 410. The first layer passes forty-two suites, 1,289 expected passes, the second 1,301, the third 1,331.

NEXT: the three stacked PRs, merged bottom up on the owner's word. Then the padding PR, then the M6 exit.

M6.4, ITS REVIEW (2026-09-29, PRs #80 to #82 open): a /code-review high, on the owner's ask, found five. The owner asked for the second and third fixed, and for more on the first: how the servers researched hold chunk extensions.
- (1) **The extensions' cap, 16 KiB for a body's together, would refuse an upload that signs every chunk**, S3's aws-chunked. Its premise did not hold: AWS's docs put `chunk-signature` in the body, under `Content-Encoding: aws-chunked` and a Content-Length that counts it, not in HTTP chunk extensions; hyper #3522, an S3 server's author asking hyper to hand extensions on, was declined, and a later comment calls the two orthogonal. No report was found of hyper's or Node's cap refusing a client; the one sender found is ICAP's `0; ieof`, not HTTP. RFC 9112 §7.1.1: a server "ought to limit the total length of chunk extensions received in a request". Read in each server's source by three research agents, the decisive lines checked again here:
  - hyper holds a body's extensions to 16 KiB (16,383 bytes pass), its count never restarted, and hands the error to the service, which answers;
  - freenginx counts every byte of a body's extensions and trailer lines against `client_max_body_size`, 1 MiB by default, 413;
  - h2o fails a body once its bytes that are not data pass 100 KiB while the data is under a quarter of all it read, 400, and holds a size to 16 hex digits;
  - Go lets a body's size lines run 16 KiB past a credit of 16 bytes and twice the data for each chunk, holds a line to 4 KiB and a size to 16 hex digits, and leaves the status to the handler;
  - Node holds each chunk's to 16 KiB, its count restarted at every chunk header, 413; its own test serves three chunks of about 10 KB each;
  - h11 holds an unfinished line to about 16 KiB, so as the reads fall; Racket a size line to 8 KiB, and closes with no response;
  - nginx and Warp hold none, and Warp misframes a size line longer than a read (read and modelled, not run).
  Behind Caddy none arrives: Go's chunk reader drops them (read, not run).
- (2) **The 100 before a refusal the core already holds**, which the finding would have left out. Its premise, that the split already changed that outcome, was measured wrong on a probe: a bad chunk after an Expect head gets the 100, then 400, at all 90 delivery sizes, and the finding's change split them, the 100 at 32 and none at 58. Beside it the probe found the split deciding: a chunked 10-byte body read whole within 4 bytes got the 100 then 413 at 30 of its 99 sizes, and 413 alone at 69, the cap checked before the 100 against the body met so far, which only some splits had met; main sends no 100 at any.
- (3) **The header's write accounting named only `responding` and `closing`** for a completion.
- (4) `find-comma` is copied from `(http-server transfer-coding)`; (5) no deadline is armed while an Expect request waits on its handler, which the shells call at once. Left: not asked for (5 researched the next day, below).

DECIDED on the owner's word (2026-09-29), by form, after the research: (2) the 100 still goes first, and the cap case is fixed, so every split gets one outcome; the finding withdrawn. Weighed: the 100 left out once a refusal is known, as the finding asked, a departure from design §8.1. (1) 16 KiB a body kept, the finding withdrawn, and the records corrected: the form had called 16 KiB "hyper's and Node's figure", and decision 0005's amendment and the core's comments had Node holding a body's. Weighed: Go's allowance, growing with the data, in the padding PR; 16 KiB a chunk, as Node. The fixes go into the PRs they belong to, the PRs above rebased and pushed with a lease. Weighed: one fix commit on #82.

The fixes:
- #80, a second commit (f745d7f): `accept-reader` refuses a reader whose cap the declared length passes before the 100, and `read-with` one whose cap the body met so far passes, after it; the header's write accounting names `body`, `handling` and `awaiting-credit` for the 100's completion, and its Expect section says what the head's feed met is answered after the 100. The checks: `tests/test-connection-expect.sps`, 16 (14), a declared length past a whole reader's cap, 413 and no 100, and a chunked body past it, the 100 then 413, each at every delivery size; `tests/test-connection-table.sps`, 260 (258), E6's body met past the cap, in `body` and, the body ended, in `handling`.
- #81 and #82 rebased onto it: #81's patch unchanged; #82's one conflict, the flows suite's header, keeps both paragraphs.
- #82, a second commit: the records. Design §4.4's M6.4 row and note, and §7.3's note of the 100's completion; decision 0005's amendment, corrected and weighed again; the core's two comments on Node; m6-mutations.md; this entry.

Measured (2026-09-29):
- `make test` green on Darwin arm64, each layer on its own tree: #80's forty-two suites, 1,293 expected passes (1,289 before the review); #81's 1,305 (1,301); #82's 1,335 (1,331), exit 0.
- On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Linux 6.12.76-linuxkit aarch64, libuv 1.44.2, curl 7.88.1), from a copy of #82's tree made with `COPYFILE_DISABLE=1`, less the submodule and pin checks: forty-two suites, 1,335 expected passes, exit 0; the shell, contract, flows and clients suites, three runs each: 129, 68, 16 and 14 each time.
- Red before green: on #80's first commit, the flows' chunked body past the cap failed, and E6's two new instances; the declared length's check passed there, and is watched red by R2.

Watched to fail (m6-mutations.md, "After the PRs' review"): two mutants on #82's tree against all forty-two suites: M6.4-R1, the body met checked before the 100 as before the fix, reddens the flows' body past the cap and E6's two instances; M6.4-R2, the declared length checked after the 100, the flows' declared length and E7. Forty-two mutants in all; none survives.

Size of code and tests: #80's second commit, 94 inserted lines and 52 deleted, most of them `read-with` indented anew; the layers, against main and then each on the one below, 551, 206 and 362 inserted, and 42, 42 and 23 deleted.

NEXT: the three stacked PRs, merged bottom up on the owner's word. Then the padding PR, its design by form on measurements, then the M6 exit.

M6.4's REVIEW, THE FIFTH FINDING RESEARCHED (2026-09-30, PRs #80 to #82 open), on the owner's "Research 5 in more detail": no deadline is armed while an Expect request waits on its handler.
- **Empty in v1.** Both shells call the handler in place, and its answer is dispatched in the same drain (`call-handler!` in `(http-server private shell)`, `perform-connection!` in `tests/fake-shell.sls`), so no tick and no read can come between the question and the answer.
- **What M7's awaiting handler would meet**, probed on the core with the answer held back (a scratch program, states built as the table builds them): an Expect head alone arms nothing until the answer, which writes the 100 and arms the body deadline; a body met in full, with or without Expect, leaves `handling` with nothing armed, design §4.3's "a slow handler is the application's problem"; a piece the client sends without waiting arms the body deadline, and a stall after it, like a head without Expect whose client sends nothing, is answered 408 while the handler has not answered, its late answer then changing nothing. The client cannot lengthen the Expect wait: it lasts as long as the handler takes.
- **Six servers, read in their source by two research agents, the decisive lines checked again here:**
  - hyper writes the 100 when the service first polls the body, and bounds nothing: its one timer is the head's, 30 s, off unless a timer is given;
  - Warp writes it on the application's first body read, and pauses its 30 s timer while the application runs ("Let the application run for as long as it wants");
  - Go writes it on the handler's first body read, and bounds nothing by default: `ReadTimeout`, opt-in, starts before the head and spans the handler; `TimeoutHandler`, opt-in, answers 503;
  - nginx writes it when a module starts reading the body, a proxy before it asks its backend, arms no client timer between head and decision, and bounds a backend's answer to 60 s, then 504;
  - Node writes it at once unless the application listens for `checkContinue`; its whole-request timer, 300 s from the request's first byte, then answers 408;
  - h2o writes it at once, before any handler, and its request timers stop before the handler runs.
- **Clients** send the body without the 100 after 1 s (curl 8.22.0's default, Go's default transport, .NET 10), 3 s (Apache HttpClient 4 and 5) or 5 s (Java 24 on, fixed); Java 21 waits with no timer of its own.

DECIDED on the owner's word (2026-09-30), by form: the finding is closed as the design's, and plan §14's M7 carries it, so that M7's rows cover the wait with the others: reading stopped while such a handler has not answered, nothing armed, and its answer bringing the 100, reading and the body deadline. Weighed: M7.2 also weighing an opt-in limit on a handler's decision time; leaving it unrecorded.

NEXT: the three stacked PRs, merged bottom up on the owner's word. Then the padding PR, its design by form on measurements, then the M6 exit.

MERGED to main on 2026-09-30, on the owner's "do closing ritual": **M6.4, as three stacked PRs**, bottom up.
- **#80, the 100 in the core,** its two commits (c87e01b, and the review's fix f745d7f) squashed as a149def. Its squash tree (22ad889) is the tested tip's, f745d7f's, and its parent is e1a57f6. It merged first and kept its branch, since #81 was based on it.
- **#81, the 100 on the wire and libhtp's two Expect files,** retargeted to main and rebased from #80's tip, f745d7f: 91becde became 0f9320c, its tree (85bf4a5) the tested one's, and it merged as 23ce73c, whose parent is a149def.
- **#82, the trailer and extension limits and M6.4's records,** retargeted and rebased from #81's old tip, 91becde: its three commits (2dc1f03, ec0869b, 778a472) became e159a78, acb8e93 and a7f19a0, the tip's tree (7c000e2) the tested 778a472's, and they merged as d7c4b30, whose parent is 23ce73c.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36650182193, 36650185023 and 36650187998 as opened; 36655148024, 36655150142 and 36655149369 after the review; 36696914621 for the M7 note; 36697213666 and 36697301376 for the rebased tips.
- **Branches.** #82's `--delete-branch` merged it and deleted its remote branch, but left this checkout on the branch, as for #20, #22, #68, #70, #72 and #73: the switch to main, the fast-forward and the three local deletions were by hand, and #80's and #81's remote branches went in one `git push origin --delete`. No PR is open.

`make test` green on main: forty-two suites, 1,335 expected passes.

DONE and merged (a149def, 23ce73c, d7c4b30; PRs #80 to #82): **M6.4, Expect, trailers and the exit's files.** A client that expects 100-continue is sent it when the handler answers with a reader, at every delivery size, and the body deadline waits for it: curl's 2 MiB POST, which waited out its own second on main, takes 5.4 to 6.4 ms on Darwin and 1.2 to 1.8 on Linux. A chunked body's trailers are held to the four header limits, 431, and its extensions to 16 KiB a body, 413. libhtp's two Expect files join the lane with CRLF: fourteen streams pass. The review fixed the 100 before a body met past a reader's cap, kept the extensions' rule after reading eight servers' source, and carried the Expect wait to M7.

NEXT: the padding PR (the owner's word, by form, 2026-09-29: its own PR after M6.4): the spaces before a field's value and a chunk size's leading zeros, which the parser hands the core no span of, its design by form on measurements, when the owner asks. Then the M6 exit (plan §14).


THE PADDING PR (fix/padding-limits, cut from main at d52ab78), on the owner's "start the padding PR".

Measured on main first (2026-09-30, Darwin arm64, the fake shell, the default limits, 16 KiB reads): the parser reads four runs of bytes it hands the core no span of, and a megabyte of each was answered 200: spaces or tabs before a field's value, in a head or a trailer section, an empty value's among them; zeros before a chunk size, a data chunk's or the last's; spaces past the one between the request line's parts; and empty lines, CR or LF, before a request line, at a connection's start or between requests. The strict parser refuses the rest (a folded line, spaces before a colon or after a chunk size or a version, a tab in the request line), and an extension's `;` and `=` are the only bytes of it left uncounted, at most 5 for 3 counted (wrong for empty names and values, which the strict parser takes: the review below). Two of the four were found at this step: the ledger's M6.4 entry named the whitespace and the zeros.

How the core can see them: inside every callback the parser's runtime says how many bytes it has read (byte-machine's committed offset, `parser-stream-offset`; chez-httparse's own test adapter reads it). At every delivery size an event callback sees the same number (45 of 45 sizes for a padded head, 95 of 95 for padded chunks), and a span's is its feed's first byte plus its end. Prototyped in a scratch tree, the adapter passing it with each event callback and the core measuring each run from where one piece ends to where the next begins, checked at the callbacks and at every read's end: one outcome at every delivery size sampled, 81 to 328 each; curl's GET 1,840 B a request, as on main; 4.55 µs a request against main's 4.45 to 4.60.

The servers researched, read in their source by three research agents, the decisive lines checked again here, and Node 20.10.0, Racket 9.3's web-server, h11 and Go 1.26 (in Caddy 2.11.2) run:
- whitespace before a value: counted by all but Node, in a head or a line (Go 1 MiB + 4 KiB, 431; nginx 8 KiB a line, 400; hyper and h2o 417,792 B; Warp 50 KiB, 400; Racket 8 KiB a line, closed; h11 16 KiB, only while a head is incomplete);
- request-line spaces: 400 from Go, hyper, h11 and Warp; counted in the request line by nginx (414), h2o and Racket; Node neither;
- empty lines: none from Go (4 bytes forgiven after a POST), h11, Warp and Racket; one from freenginx (since 2024, "multiple CRLFs cannot be used as a DoS vector") and h2o; any number in hyper's 417,792 B; nginx and Node unbounded;
- a chunk size's digits: 16, zeros included, in Go and h2o, 20 in h11, a line of 8 KiB in Racket; nginx, freenginx, hyper, Node and Warp only overflow.
Behind Caddy none of the four arrives: it refuses the spaces and the empty lines, counts the whitespace in its 1 MiB head and holds a size to 16 digits.

DECIDED on the owner's word (2026-09-30), by form, on those numbers:
- **Whitespace before a field's value counts with the value**, against its limit, 8 KiB, and the section's, 16 KiB, 431, in a head and in a trailer section, as the whitespace after it already does. Weighed: every byte of each line, the peers' way. The space after a colon counts, so a field at an exact limit moves by that byte.
- **A chunk size has at most 16 hex digits, zeros included, 400**, as Go and h2o hold it. Weighed: 20, as h11; Go's allowance for bytes that are not data.
- **More than one space between the request line's parts is refused, 400**, as RFC 9112 §3's grammar has it and Go, hyper, h11 and Warp answer. Weighed: counted with the target, 414, as nginx counts its request line.
- **One empty line before a request line is skipped, a second refused, 400**, as RFC 9112 §2.2 asks a server to ignore one, and as freenginx and h2o do. Weighed: counted with the target, 414; none, as Go, h11, Warp and Racket, which would fail libhtp's passing stream 61 and llhttp's two fixtures that open with one.

DECIDED again on the owner's word (2026-09-30), by form, once the rule was built: **two empty lines, 4 bytes, before a request line, then 400.** The first form said the corpora carried one at most; the scan behind it read only where each input began and ended, and llhttp's fixture "CRLF between requests, implicit `keep-alive`" (connection.md#5) has a POST's 4-byte body followed by two, which the rule of one refused: the trace lane went red, the core changing what the parser does. Two is Go's allowance after a POST ("tolerance for old buggy clients"). Weighed: two after a body only, one elsewhere; one, the fixture a recorded exception to the trace lane's rule.

What was built:
- `(http-server private adapter)`: every event callback passes the parser's position, `parser-stream-offset`, and on-headers-complete passes it after `upgrade`.
- `(http-server connection)`: the event entry is `(conn-parser-step s name at)` and on-headers-complete takes `at` last; the tagged lists follow, `(parser-event name at)` and on-headers-complete's seventh field (decision 0002's amendment of this day). The state keeps where the parser is: the bytes it has taken (`parsed`, each read's `consumed`), the position of index 0 of the delivery being fed (`base`, set as the core asks for a feed; the rest a pause keeps is fed with its delivery's), and the one run open (`mark`, `run`, `open-run!`): `lines` from a message's end, or the connection's first byte, to on-message-begin; `after-method` to the target's first bytes; `target`, the target's own, only so its end is known; `after-target`, opened at on-url-complete one byte past the target's end, to the protocol's first bytes; `whitespace` from on-header-field-complete to the value's first bytes, in a head or a trailer section; `digits` from a chunked head's end, or on-chunk-complete, to the first extension's name or on-chunk-header. A run is judged at the callback that ends it: past 4 bytes of empty lines, `empty-lines`; past one space, `request-line-spaces`; past 16 digits, `chunk-size-too-long`; the whitespace kept as the value's `pad` and counted with it and the section. At a read's end `run-past-limit` judges the open run, the digits allowed the byte that ends them, `;` or CR, and at the parser's error only the whitespace; `refuse-run` answers it as a callback's refusal is answered, from idle into head first, through `answer-refusal`, the error branch, now shared.
- `(http-server decisions)`: the three reasons, 400.
- Docs: configuration.org, the whitespace counted with a value, a chunk size's 16 digits, the two empty lines and the one space; responses.org, the 400s.

The checks:
- `tests/test-connection-entry.sps`, 33 (main's 30): an event callback without the parser's position refused, all fifteen; a span callback given a position in place of its span, all ten; on-headers-complete without it; the callbacks recorded from a parse carry the positions the parser commits.
- `tests/test-connection-table.sps`, 293 (260): every event row carries a position, and the synthetic heads read as a parse reads them: a target in a request line, a field line with its one space, a chunked head's first size line; G1 to G12, 32 instances, and their count.
- `tests/test-connection-padding.sps`, new, 15: each run at every delivery size, within its limit and a byte past, each read in a bytevector of its own at an offset, as a shell hands one over; the megabyte runs main answered 200 at sampled sizes; and the work a run costs, a megabyte of each fed to the parser one 16 KiB read.
- `tests/test-connection-originated.sps`, 26 (23): the three 400s end to end. `tests/test-connection-head.sps`, 52, and `tests/test-connection-expect.sps`, 16: their exact-limit checks count the space after a colon.

FOUND WHILE BUILDING:
- **The first form's premise was wrong** (the second form, above).
- **A request line with no version** (llhttp's "No HTTP version", sample.md#10): the run after the target first opened at every on-url-complete, so a line end met at a read's end counted as spaces, and the outcome lane split the fixture, 400 a byte at a time, 200 whole. The run opens only one byte past the target's end; a line end is two (true of a CRLF only: a bare LF is one byte too, and the review below found the split it left).
- **A span the parser's error cuts off is never handed on** (chez-httparse: "an error abandons an open span"), so at the parser's error a run's bytes could hold it: only the whitespace is judged there, its value counting with it anyway. A run past its limit and then cut off by a malformed target or chunk size is 400 at every size, its reason the run's or the parser's by the split (not an extension, whose name ends the size's run first: the review below). The same cut already splits main's own limits: a 9,000-byte target then a control byte is 400 at 63 of 174 delivery sizes and 414 at 111, a 9,000-byte field name 400 at 61 and 431 at 113. Not this PR's; for the owner.
- **The fake shell hands every read as a slice of one bytevector**, indexed from the connection's first byte, so a delivery's base of 0 was right by accident: the first mutation run's survivor P-C. The flows hand each read in a bytevector of its own. P-D, the pending rest's base set anew, was equivalent, and its line went.

Measured on the finished tree (2026-09-30, Darwin arm64):
- `make test` green: forty-three suites, 1,389 expected passes, exit 0 (main's forty-two, 1,335).
- Red before green: on the vocabulary step against main's core, the entry suite's two new refusals; on the vocabulary step's core, which reads no position, the table's sixteen refusal instances; against main's core and adapter, twelve of the flows' fifteen.
- The probes that measured main, run again: every megabyte run refused, the empty lines before a request line or between two, the request line's spaces and a chunk size's zeros 400, the whitespace before a value, in a head or a trailer section, an empty value's too, 431; two spaces in a request line 400.
- The allocation suite's figures are main's: curl's GET 1,840 B, the JSON POST 2,624 read whole and 2,432 streamed, ab -k's GET 2,112, a browser's GET 3,312.
- CPU, main's core against this tree, the fake shell, three runs each: curl's GET 4.55 to 4.80 µs a request against 4.65 to 4.75, a browser's 8.90 to 8.95 against 8.90 to 9.15, a four-chunk POST 6.30 to 6.65 against 6.35 to 6.45; a body of 200,000 one-byte chunks in 16 KiB reads, five runs a process, 65 to 69 ms against 67 to 73, some 10 to 15 ns a chunk.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Linux 6.12.76-linuxkit aarch64, Chez 10.4.1, curl 7.88.1), from a copy made with `COPYFILE_DISABLE=1`, less the submodule and pin checks, the top layer's tree: forty-three suites, 1,389 expected passes, exit 0; the shell, contract, clients and padding suites, three runs each: 129, 68, 14 and 15 each time.

Watched to fail (m6-mutations.md, "The padding PR"): forty-four mutants on the finished tree against all forty-three suites, and a forty-fifth, P-Q2, for G12's instance that cutting the layers added; none survives, and every check this PR added or changed is reddened by at least one.

Size: 933 inserted lines of code and tests (the new flows suite's 259 among them, `src/` 314), 183 deleted; over plan §1 rule 1's ~400. Cut as three layers (the form below), each proved green on its own before its commit, against main and then each on the one below: 163, 576 and 228 inserted lines of code and tests, and 117, 55 and 45 deleted, where the form estimated about 190, 450 and 290; forty-two suites and 1,338 expected passes, then forty-three and 1,368, then 1,389.

DECIDED on the owner's word (2026-09-30), by form, after the walkthrough: **three stacked PRs**, each green on its own, proved before its commit: every event callback carrying the parser's position, with decision 0002's amendment; the two runs planned, the whitespace before a value and a chunk size's digits, with the runs' machinery; the two found, the request line's spaces and the empty lines before it, with the PR's records. Weighed: two, the positions and the four rules; one. And **the split found, main's own limits cut off by the parser's error, gets its own PR next**, before the M6 exit: with the positions, the core can place a target or a field name the error cut off and judge it by its limit. Weighed: carried to M8.3; folded into this PR.

NEXT: the three stacked PRs, merged bottom up on the owner's "do closing ritual". Then the PR for the split found, its design by form on measurements; then the M6 exit (plan §14).


THE PADDING PR'S REVIEW (2026-09-30, PRs #83 to #85 open): a /code-review max on the owner's ask (ten finders, a verifier for each candidate, a sweep) found fifteen, and the owner asked for all of them fixed: "lets fix all, start with the ones that need choices". Each choice's options were built in scratch copies and measured before the forms (Darwin arm64, the fake shell, every delivery size).

DECIDED on the owner's word (2026-09-30), by two forms, every option the recommended one:
- **The spaces after a target are counted however it ends.** A request line with no version ended by a bare LF, which the strict parser takes, was refused 400 or served 200 depending on where reads ended. `GET /a\nHost: x\r\n\r\n` got 400 at 9 of its 18 delivery sizes; main served it 200 at all. The core counted from one byte past the target, taking that byte for a space, but a bare LF is one byte too.
  - Now the run opens at every on-url-complete, a field or the head's end lets it go, and a read may end one byte past its limit: a versionless line's CR.
  - On a generated corpus of 3,522 and 3,549 inputs, each at every size, the PR split 296 and 330 inputs (206 and 218 of them in what was written, all with a bare LF). Now 7 and 7 split, each by its reason only (the run-then-error class below).
  - The one change in behaviour: a client that stops after one extra space waits for the header timeout instead of getting 400 at once.
  - Weighed: checking that byte for a space (the same corpus numbers, but hand-built rows then need a delivery).
- **A chunk's extensions count every byte, an empty one's too**: a byte at each name's and value's end, for its `;` or `=`.
  - A megabyte of `;=` was served 200 in 92 ms of CPU, growing linearly (8 MB took 736 ms through the libuv shell), bounded only by the body deadline. Now it gets 413 within its second 16 KiB read, in about 2 ms.
  - Weighed: every byte by position (+38 −30 lines, and a single large delivery parsed whole first); Go's 4 KiB a line alone (still served a megabyte spread over short lines).
- **A 431 names the limit its bytes passed first** (`first-past`), the field's on a tie. Of 2,856 swept trailer inputs, 224 split by their 431's reason on main and 496 on the PR; none of 56,692 swept and fuzzed inputs splits now. Weighed: leaving it.
- **An empty value's line end does not count.** 8,191 spaces and a CRLF were refused 431, where 8,191 spaces and a one-byte value were served. A malformed value at most 2 bytes past its limit, which the parser ends at a byte it then refuses, now gets its 400 instead of 431, at every size. Weighed: counting it, and saying so in the docs.
- **A run past its limit, then a parse error, goes to the next PR**, with main's own cut-off span. It is 400 at every split, but its reason depends on the split: `GET` + 3 spaces + a control byte names the run at 5 of its 31 sizes and the parser at the rest. Both halves need to know where a span the error cut off began. Weighed: fixing it here.
- **A parser-result carries the parser's own count**, `parser-result-stream-offset`, not one read's (decision 0002's amendment). The trace lane, which passes on only some results, had left the core's sum behind on 80 of its 141 reads. Weighed: spans carrying the position too (73 hand-built events to change); keeping the sum.
- **chez-httparse #55 filed**: document what `parser-stream-offset` answers inside a callback (decision 0008). Weighed: recording the reliance only.

Fixed without a choice:
- Row F3's head is now 10 bytes, at the tight limits' edge, and the table's state builder refuses a setup step the core refuses (`setup!`).
- G14 watches the four phase guards no check watched.
- The entry suite's two "all fifteen" checks are fourteen now, with a count: on-headers-complete is refused whatever its arguments, so its instance could never fail.
- A parser-result is read whole, once, before it is answered: a short one is an assertion violation again, as on main.
- The stale comment on `conn-span-callbacks` is corrected.
- The docs say 4 bytes of empty lines, name the fixed limits, and count every byte of the extensions.
- Each run's limit is stated once (`run-limits`, `close-judged!`), and on-message-begin refuses through `refuse`.
- `(decisive)` holds the action reducer that the body, Expect and padding suites each copied; `fake-shell-feed-input!` takes a delivery's offset; and `expecting` goes through `head-complete!`.

Found while building:
- **The two "all fifteen" checks** had the flaw, not one.
- **No check named the tie**, both limits passed at one byte; the padding suite's row gained one.
- **The clamp at 0 on an empty value's pad could change no outcome**: R-W3 survived. The pad goes below 0 only where the parser's error comes next. The clamp went.

The checks: padding 19 (15), the table 305 (293), entry 35 (33). In the table, G9 and G10 sit at the new allowances, G12 names the section first, G13 lets a versionless line's run go at its first field, G14 holds a run open past a 408, F4 and F5 count each delimiter, and the count is fourteen. Expect 16 and originated 26: their inputs shrink by the delimiters.

Measured on the finished tree (2026-09-30):
- `make test` on Darwin arm64: forty-three suites, 1,407 expected passes, exit 0.
- On Linux, in the same Docker image (698eba6; Linux 6.12.76-linuxkit aarch64, Chez 10.4.1): forty-three suites, 1,407 passes, exit 0. The shell, contract, clients and padding suites gave 129, 68, 14 and 19 in each of three runs.
- Allocation is unchanged: curl's GET 1,840 B, the JSON POST 2,624 and 2,432, ab -k's GET 2,112, a browser's GET 3,312, a parser 1,056.
- Red before green: on f0950e2, before any edit, the padding suite's six new and changed checks failed and thirteen passed.
- Mutants: sixty-five on the reviewed tree, none survives (m6-mutations.md, "The padding PR's review"). Every new and changed check is mapped by name to a mutant that reddened it.

Size: 471 inserted lines of code and tests (`src/` 182), 317 deleted; over plan §1 rule 1's ~400.

DECIDED on the owner's word (2026-09-30), by form, after the walkthrough: **two stacked PRs on #85**, each proved green on its own before its commit. The finished tree was set aside (22 files, sums, a tarball), the bottom layer was cut in place from f0950e2, and the top layer was restored from the set-aside with every sum matching. Weighed: one PR; folding each fix into #83 to #85.
- Bottom, `refactor/padding-review` (b5c6b4f): the parts that change no rule. The parser's own count, a result read whole, each run's limit stated once, `refuse` in on-message-begin, the table's `setup!` and F3, G14, the entry suite's fourteen and short result, `(decisive)`, the delivery offset, `expecting`, the adapter's #55 and the stale comment, decision 0002's amendment and the design's event table. 251 inserted lines of code and tests (`src/` 100), 235 deleted; `make test` 43 suites, 1,395 expected passes; allocation unchanged.
- Top, `fix/padding-review`: the four rules (a versionless line, empty extensions, the first limit passed, an empty value's line end), with the docs and the review's records. 234 inserted (`src/` 92), 96 deleted; 1,407.

NEXT: the two PRs, merged with #83 to #85, bottom up, on the owner's "do closing ritual". Then the PR for the split found, now with the run-then-error reason (plan §14's note); then the M6 exit.

MERGED to main on 2026-10-01, on the owner's "Do closing ritual": **the padding PR and its review, as five stacked PRs**, bottom up. Each squash tree is the tested tip's, and each merge was pinned to its head's full SHA.
- **#83, every parser event carrying the parser's position,** 59a5997, squashed as 777d36e (tree 2e5c8ca), whose parent is d52ab78. It merged first and kept its branch.
- **#84, a value's leading whitespace and a chunk size's digits,** retargeted to main and rebased from #83's tip: c615744 became f434b5e (tree d8a6fab, the tested one's). It merged as eea26fc.
- **#85, the request line's spaces and the empty lines, with the PR's records,** rebased from #84's old tip: f0950e2 became 418ca97 (tree 32ebd89). It merged as 7e43fb6.
- **#86, the review's parts that change no rule,** rebased from f0950e2: b5c6b4f became 08e4312 (tree 3d0c193). It merged as f64f410.
- **#87, the review's four rules, docs and records,** rebased from b5c6b4f: 83c98a5 became 6ab6c3b (tree 1f146f3). It merged as 17df6cc, whose parent is f64f410.
- **CI changed during the ritual.**
  - #83 to #85 as opened were the billing block, the `linux` job with 0 steps (36710798364, 36710802665, 36710805821).
  - Between 2026-09-30T11:48Z and 2026-10-01T00:37Z the block lifted. The job now runs, but `actions/checkout` cannot clone the three private sibling submodules (chez-httparse, chez-libuv, uriparse: "Repository not found"), so no build or test runs.
  - That failure hit #86 and #87 as opened (36797088983, 36797092945), every rebased tip (36797461697, 36797781000, 36797841231, 36797892375), and main's own run on 777d36e (36797428373). No PR touched `.gitmodules` or the workflow.
  - DECIDED on the owner's word, by form, during the ritual: **continue on local evidence**, each rebased tree proved equal to the tested one and each red run shown to be this checkout failure; fix CI separately. Weighed: pausing after #83 until CI can check out, which needs a token or deploy key the owner adds as an Actions secret.
- **Branches.** #87's `--delete-branch` merged it and deleted its remote branch, but left this checkout on the branch, as for #20, #22, #68, #70, #72, #73 and #82. The switch to main, the fast-forward and the five local deletions were by hand, and the four lower remote branches went in one `git push origin --delete`. No PR is open.

`make test` green on main: forty-three suites, 1,407 expected passes.

DONE and merged (777d36e, eea26fc, 7e43fb6, f64f410, 17df6cc; PRs #83 to #87): **the padding PR, what the parser reads and hands no span of held to limits.**
- Before, a megabyte of each run was served 200. Now each is refused within the read that passes its limit:
  - empty lines before a request line, past two (4 bytes), 400;
  - spaces between the request line's parts, past one, 400;
  - whitespace before a value, counted with it, 431 for the limit its bytes pass first;
  - a chunk size's digits, past 16, 400;
  - a chunk's extensions, every byte counted, 413.
- Every event carries the parser's position, and every result the parser's own count.
- The review fixed a split it had added: a versionless request line ended by a bare LF. It also fixed the empty extensions it had missed, and asked chez-httparse (#55) to document the offset it relies on.

**CI reads the private submodules through a secret, on `fix/ci-private-submodules` (2026-10-01).** The job's own token reads only this repository, and chez-libuv, chez-httparse, uriparse and chez-httparse's byte-machine are private. Checkout now fetches this repository alone. `make submodules` clones every submodule with the Actions secret `SUBMODULES_READ_TOKEN`, through a URL rewrite held in that step's environment and limited to Kiyomi-Computation-Systems' URLs. A first step fails, naming the secret, until the owner adds it: a fine-grained token with Contents read-only on those four repositories. Proved offline on Darwin arm64 (git 2.50.1; the runner has 2.55.0). Against a stand-in for github.com, with the real Makefile, 19 checks pass. One shows that a nested clone never sees a token checkout saves, so a token given to checkout alone still fails at byte-machine. Eleven checks on ci.yml's own strings pass, each watched red under a mutant. `make test`: forty-three suites, 1,407 expected passes. The job's later steps have never run on GitHub; the first run with the secret is their first. DECIDED on the owner's word (2026-10-01), by form: checkout keeps the job's own token, and the change goes up as one PR. Weighed: the secret on checkout too, which would also have to read chez-http-server.

MERGED to main on 2026-10-01, on the owner's "do closing ritual": **#88, CI reads the private submodules through a secret.** 3dcde03 was squashed as 3d006b0 (tree f7454e9, the tested tip's), whose parent is 37afef1. The owner added `SUBMODULES_READ_TOKEN` at 09:58Z. The PR's re-run (36844511280, attempt 2) then passed all 17 steps, the job's first green run on GitHub:
- the five submodules cloned at their pins in 5 s;
- Chez 10.4.1 built from source in 195 s and was cached, under the PR's ref, so main's first run builds it once more;
- `make test` on ubuntu-24.04 (git 2.55.0, libuv 1.48.0) ran forty-three suites, 1,407 expected passes.

The branch was deleted by hand, local and remote, and the shared checkout's `main` was fast-forwarded behind the guard.

THE CHEZ-HTTPARSE v0.4.4 PIN (2026-10-01), on the owner's word: "chez-http-server can now move its vendor/chez-httparse pin to the v0.4.4". Branch `chore/chez-httparse-v0.4.4`, cut from main at 8993ff0; Darwin arm64, Chez 10.4.1.

UPSTREAM: chez-httparse tagged v0.4.4 (3342428, annotated tag 9b198d4). Checked against the sibling checkout's history:
- **#56 answers our #55** (closed 2026-10-01). `docs/api.org` gains "Where a callback is in the stream":
  - an event callback reads the bytes taken before it, llhttp's `off=`;
  - a span callback reads its fragment's end, so the fragment starts at the offset less `(- to from)`, including a fragment cut off at a feed's end and an empty one.
  - That is what the core reads, and `unit.stream-offset` holds both over the 274 fixtures at chunk sizes 1, 2, 3, 7 and whole.
- **#57:** `parser-finish!` on a close-delimited body with no bytes runs no empty `on-body-data`, as llhttp. The generated parser gains one state, so it is not byte-identical to v0.4.3. The core never finishes a parser. The tests' response reader reads only the finish's status and whether its message completed, and an empty body's text is "" either way.
- Conformance is 274 of 274 and the generated-runtime ABI is 9. Its byte-machine is still v0.6.1 at 5c1cb7e, so uriparse, the other carrier, stays. The vendored llhttp corpus is unchanged from v0.4.3. Its CI clones its private byte-machine with a read token (#58).

Decision 0008's ask is closed by its landing: the pin moves on its own commit, and the adapter's comment, which cited the ask, now cites the documented section.

Measured at v0.4.4:
- `make test` (2026-10-01, Darwin arm64): forty-three suites, 1,407 expected passes, exit 0, as main. Every pin is ok: chez-httparse 3342428, its byte-machine 5c1cb7e, and uriparse released with the same.
- The corpus lanes under `CORPUS=full`: trace 7, outcome 6 and libhtp 19 expected passes, ratchet 9.
- On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy made with `COPYFILE_DISABLE=1`, less the submodule and pin checks: forty-three suites, 1,407 expected passes. The shell, contract, clients and integration suites gave 129, 68, 14 and 5 in each of three runs.

Records: the global constraints' pin line; decision 0002's amendment (the offset documented); the adapter's comment; test-integration's and test-corpus-inventory's version comments.

The pin moves alone: the gitlink, the Makefile's pin and the comments, besides these records.

DECIDED on the owner's word (2026-10-01), by form: one PR, the pin alone. Weighed: a review first; nothing committed.

MERGED to main on 2026-10-01, on the owner's "ci is green do closing ritual": **#89, the chez-httparse v0.4.4 pin.** 6ea6558 was squashed as e909e5b (tree 027bc4a, the tested tip's), whose parent is 8993ff0.
- **CI.** Its run, 36857836010, passed: the `linux` job built and tested the PR on GitHub, the first pull request so checked since #88 gave CI its read token.
- **Branches.** `--delete-branch` merged it and deleted its remote branch, but left this checkout on the branch, as for #73 and #87. The switch to main, the fast-forward and the local deletion were by hand.

`make test` green on main at v0.4.4: forty-three suites, 1,407 expected passes, every pin ok.

NEXT, by the owner's word (2026-09-30):
- **The PR for the split found**, main's own limits cut off by the parser's error, now with the run-then-error reason. Its design goes by form on measurements.
- **Then the M6 exit** (plan §14).

THE CUT-OFF-SPAN PR (fix/cut-off-spans, cut from main at f89ad73), on the owner's word: "Lets do the next step: the PR for the remaining split, where a parse error cuts off a span past its limit, including the run-then-error reason."

Measured on main first (2026-10-01, Darwin arm64, Chez 10.4.1, the fake shell, the default limits; every delivery size under 400 bytes, and above it sizes 1 to 80, every 97th and whole). Eleven of eighteen inputs split:
- a 9,000-byte target, then a control byte: 414 at 111 of 174 sizes, 400 at 63; one of 8,193 bytes: 414 at 2 of 165;
- a 9,000-byte field name, then a control byte: 431 at 111 of 174 as the first field, at 113 as the second, and at 111 as a trailer's, 400 at the rest; one of 8,193 bytes: 431 at 4 of 165;
- a 1,000-byte name cut off past 16,000 bytes of fields: 431 (`headers-too-large`) at 107 of 256, 400 at 149;
- a run past its limit and then the parser's error, 400 either way, its reason split: `GET`, three spaces and a control byte, the run's at 5 of 29 sizes; with `/abc` before the control byte, 10 of 33; two spaces and a 9,000-byte target, 172 of 174; eighteen zeros and a `g` as a chunk size, 4 of 85.
- Not split: a value or a chunk's extensions past their limits and then a control byte (431, 413), each handed over before the error; seventeen zeros and a `g`, within the read's slack; spaces after a target; whitespace then CR and a control byte; empty lines.

A fuzz (scratch `cut/fuzz.sps`): random request lines, fields, chunk sizes and trailers under random tight limits, one byte replaced or inserted, each run at every delivery size, each read at index 3 of a bytevector of its own. Of 40,000 inputs (two seeds, a head's fields and a body's trailers), 980 split: 326 by status (414 or 431 against 400: 174, 144 and 8 for a section), 654 by reason only (489 the request line's spaces, 165 a chunk size's digits).

What an error cuts off. Seven requests, each byte replaced by and preceded by each of 22 byte values, fed whole: of 11,790 errors, a field name's span was open at 2,868, the method's at 1,665 (it has no limit), the target's at 1,156, none at 6,101. A value, an extension and the protocol are handed over before their errors. The parser says which span is open, `parser-active-span`, and an error leaves it named; it does not say where that span began (byte-machine's runtime keeps the mark private, and "a final partial fragment is forbidden outright" at an error). And an error's offset is not always the refused byte's: over 11,273 errors it is that byte's when the error's position kind is `byte` (9,132), and one past it when `boundary` (2,141), where the parser took the byte and then refused it (byte-machine's `.reference/transition-and-cursor-semantics.md` §4).

Prototyped in a scratch tree: the shell passes the parser's open span and the refused byte's offset; at the parser's error the core judges the bytes the error cut off as a read's end would, so the first limit passed in byte order names the response; a field name starts where its line starts, which the event before it gives, and a target one byte after the method's space unless that byte is another space, read from the delivery the core holds. None of the eighteen and none of the 40,000 split. On 20,000 more (a third seed), each answer is main's at one-byte reads, where nothing is cut off. The corpus lanes under `CORPUS=full` print what main's print (trace 7, outcome 6, the libhtp lane 19, the ratchet 9, libhtp 11). Allocation is unchanged: curl's GET 1,840 B. A first cut took an error's offset as the refused byte's: it split none, but answered 37 of the 20,000 otherwise than main does a byte at a time, a tab the parser takes and then refuses counted as a target's byte or a space.

DECIDED on the owner's word (2026-10-01), by two forms:
- **A parser-result has five fields, `(parser-result status offset next code span)`**: one code, an error's or a pause's, since a result has at most one, and the span the parser has open; its offset, at an error, is the refused byte's. Built once, in the adapter, for both shells. Weighed: a sixth field, 16 B more a read (curl's GET 1,856 B).
- **Ask and carry.** The owner asked first whether the change would make byte-machine a better product. Answered: yes, if a parse error records the span it abandoned and where its undelivered bytes begin, rather than the mark being exposed, which the runtime keeps private on purpose; free at runtime, no callback changed, so chez-httparse's llhttp conformance holds; any embedder that bounds a span or names a bad token needs it; byte-machine already documents the position kinds. So **byte-machine #145** was filed (2026-10-01), and the core places a cut-off span now, a workaround named in its source (decision 0008), whose line starts and space check, about twelve lines, go when it lands. Weighed: building only once #145 lands; the core alone, with no ask.

What was built:
- `(http-server private adapter)`: `parser-result-event`, the one place a feed's result becomes the core's event, for both shells: `(parser-result status offset next code span)`. The offset is the parser's count, and at an error of the parser's own the refused byte's position: the count less one where the error's position kind is `boundary`. The code is the error's or the pause's, and the span is `parser-active-span`. The libuv shell and the fake shell call it; each dropped its own builder.
- `(http-server connection)`: at the parser's own error, with no refusal of the core's held, `cut-off-past-limit` judges what was cut off:
  - a target's bytes it was not handed: from the read's start where a read's end handed the first ones; otherwise one byte past the method's space, unless that byte is another space, read from the delivery (`space-at?`), and then the spaces' 400 comes first;
  - a field name's: from the later of its line's start (`conn-line`) and the read's start, judged by `first-past` against the name's limit and the section's. `conn-line` is set at on-url-complete for a versionless line, at on-version-complete two bytes on, at each value's end, and at each chunk's size line;
  - otherwise the run still open, judged as at a read's end, every kind (`run-past-limit` lost its `error?`).
  `target-past` states the target's limit once, on-url-data's check too. The line starts and the space check are decision 0008's workaround for byte-machine #145.
- Docs: responses.org, one paragraph: the rule a request's bytes break first decides its answer, however they arrived.
- Records: decisions 0002, 0005 and 0008; design §4.2's table and note, and §4.4's error row; plan §14's note; this ledger; m6-mutations.md.

The checks:
- `tests/test-connection-cut-off.sps`, new, 11: a target, at its limit and a byte past it, then a control byte; two spaces then such a target, or three then the byte; the tabs the parser takes before refusing them; a field name at its limit and a byte past, in each place a name begins (the first field, after a field, after a versionless request line, a trailer section's first, after a trailer); the section passed by a name within its own limit; eighteen digits and seventeen; each at every delivery size. Then the result as the adapter builds it from a real parser, a pause's code among them, and decision 0008's tripwire: byte-machine's error and active-span accessors are v0.6.1's until #145 lands.
- `tests/test-connection-table.sps`, 319 (305): G12 to the new rule, with an instance within the limit; K1 to K4, twelve instances, and their count; T7's pause code in its new place.
- `tests/test-connection-entry.sps`, 35: its short-result check renamed for the new fields.
- `tests/test-serve.sps`, 11 (10): through the libuv shell, a target over the limit and then a control byte, sent in one write: 414.

FOUND WHILE BUILDING:
- **The suite's first trailer inputs never reached their trailers.** The limits it set refused the chunked head's own 17-byte `Transfer-Encoding` name first, at every size: the same trap as the fuzz's first trailer mode. Its name limit is now 17, so the head passes, and the names cut off are 17 and 18 bytes.
- **No check held what the libuv shell hands the core.** The fake shell's suites pass whatever the real shell builds. test-serve's new check is red against main's sources and under X-S1, a shell that builds its own result with no span. The contract suite reddens under X-S1 too: its two shells' traces differ at the first read that ends inside a span.

Measured on the finished tree (2026-10-01):
- `make test` on Darwin arm64: forty-four suites, 1,433 expected passes, exit 0, every pin ok.
- On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Linux 6.12.76-linuxkit aarch64, Chez 10.4.1): forty-four suites, 1,433 passes, exit 0. The shell, contract, clients, serve and cut-off suites gave 129, 68, 14, 11 and 11 in each of three runs.
- The corpus lanes under `CORPUS=full` print what main's print: trace 7, outcome 6, the libhtp lane 19, the ratchet 9, libhtp 11.
- None of the eighteen inputs splits. Of the fuzz's 40,000, none splits; of 20,000 more, on which main splits 495, every answer is main's at one-byte reads.
- Allocation is unchanged: curl's GET 1,840 B, the JSON POST 2,624 and 2,432, ab -k's GET 2,112, a browser's GET 3,312, a parser 1,056.
- Time, 20,000 keep-alive requests on the fake shell, eight runs each, interleaved with main's: curl's GET 4.95 to 5.10 µs against 4.80 to 4.95, a chunked POST 6.65 to 7.20 against 6.55 to 7.10, a browser's GET 9.30 to 9.70 against 9.15 to 10.20.
- Red before green, and the mutants: m6-mutations.md, "The cut-off-span PR". Twenty-eight, none surviving; the padding PR's sixty-two run again, all killed, and three withdrawn.

Size: 529 inserted lines of code and tests (`src/` 155, much of it comments), 73 deleted; over plan §1 rule 1's ~400.

DECIDED on the owner's word (2026-10-01), by form, after the walkthrough: **two stacked PRs**, each proved green on its own before its commit.
- Bottom, `refactor/parser-result-span` (dd21879): the five-field result, built once in the adapter, its span not yet read and its offset still the parser's count. It changes no rule. 107 inserted lines of code and tests, 31 deleted; `make test` 44 suites, 1,409 expected passes.
- Top, `fix/cut-off-spans`: the rule, with its checks, docs and records: the refused byte's offset, the core's judgment of what the error cut off, and the runs judged at the error. 452 inserted (`src/` 134), 72 deleted, the bottom's suite header and builder rewritten among them; 44 suites, 1,433. The finished tree was set aside (16 files, sums and a tarball), the bottom cut in place from main by scripted edits, and the top restored from the set-aside with every sum matching.
Weighed: three stacked PRs (the result; targets and runs; names and the records), each under the ~400 guide but one mechanism split across two; one PR.

NEXT: the two PRs, merged bottom up on the owner's "do closing ritual". Then the M6 exit (plan §14). When byte-machine #145 lands and its release reaches chez-httparse and uriparse, their pins move together, the tripwire goes red, and the core's line starts and space check go.

MERGED to main on 2026-10-01, on the owner's word by form ("Merge #90/#91, then PR"): **the cut-off-span PR, as two stacked PRs**, bottom up. Each squash tree is the tested tip's, and each merge was pinned to its head's full SHA.
- **#90, the five-field result,** dd21879, squashed as baec0e6 (tree 6e4cefa), whose parent is f89ad73. CI's `linux` job passed on dd21879 (36866733334). It merged first and kept its branch.
- **#91, the rule,** retargeted to main and rebased from dd21879: 7a6fd94 became bf11f16 (tree e75ce71, the tested one's), pushed with the lease from `ls-remote`. CI passed on both heads (36866785944, 36925445076). It merged as cab39b1, whose parent is baec0e6. `--delete-branch` switched this checkout to main and fast-forwarded it; the bottom branch was deleted by hand.

`make test` green on main: forty-four suites, 1,433 expected passes, every pin ok.

NEXT, by the owner's word (2026-10-01, the same form): **the pin PR**, one PR from main. byte-machine v0.7.0 (c338a57) shipped #145 the same day: a parse error names the span it abandoned (`parser-error-span`) and where its withheld bytes begin (`parser-error-span-offset`). chez-httparse v0.4.5 (0b7058e) and uriparse v0.6.2 (5ecd88f) carry it, their `src/` unchanged. Both pins move, and the core reads the two values in place of its line starts and space check; the result's `span` becomes the error's `(name . where its withheld bytes begin)`, or #f (DECIDED, the same form). Then the M6 exit (plan §14).

THE PIN PR (refactor/abandoned-span, cut from main at 4086735), on the owner's word: "uriparse and chez-httparse are both updated to byte-machine 0.7.0". Its shape was decided by form (below).

Checked against the siblings' own history first (2026-10-01):
- byte-machine v0.7.0 (c338a57, annotated tag 8b493d4) carries #145, via PR #146 and its decision 0056, released in PR #150; #145 is closed. A parse error gains two members, `parser-error-span` and `parser-error-span-offset`, both #f when no span was open. `abandon-span!` fills them where both executors hand an error back, and a delivery now advances the span's mark (§13:822). The generated ABI is still 9, and the emitted text is unchanged.
- chez-httparse v0.4.5 (0b7058e, tag 814f2df; PRs #60 and #61) and uriparse v0.6.2 (5ecd88f, tag 3cfec81; PR #31) each vendor c338a57. Neither library's `src/` changed since v0.4.4 and v0.6.1, nor chez-httparse's corpus since v0.4.0. All three tags are on GitHub.

Measured before the form (2026-10-01, Darwin arm64, Chez 10.4.1). A copy of v0.7.0's `src/` went on the library path, leaving the checkout alone (scratch `bm7/`):
- #91's tree at the new pins: 44 suites, 1,432 of 1,433 checks pass. The one red is the #145 tripwire. Allocation is unchanged: curl's GET 1,840 B; a JSON POST 2,624 read whole and 2,432 streamed; ab's GET 2,112; a browser's 3,312; the parser 1,056.
- A probe in the core compared the error's offset with the core's own placement, at every error of the 40,000 fuzzed requests at every delivery size. They agreed at all 615,192 targets and names cut off: 103,787 targets that began in the read that failed, 7,551 carried in from an earlier read, and 503,854 names. The error's span always equalled `parser-active-span`, and its offset the result's. No other span ever withheld a byte, and no withheld range began past the refused byte.
- A prototype, with the span field carrying the error's pair (`src/` +15 −31): none of the 40,000 split. On 20,000 more, it answered byte for byte as #91's tree. The eighteen hand-made inputs and the five corpus lanes print what #91's print: trace 7, outcome 6, libhtp lane 19, ratchet 9, libhtp 11.
- A sixth field instead costs 16 B a read: curl's GET 1,856 B, a browser's 3,328. The allocation suite builds its results by hand, so its builders were widened to price it.
- Time, as medians of twelve rounds whose order rotates:

  | Tree | curl's GET | a browser's GET | a chunked POST |
  |---|---|---|---|
  | #91 at v0.6.1 | 5.05 µs | 9.575 | 6.975 |
  | #91 at v0.7.0 | 5.15 | 9.625 | 6.975 |
  | the prototype at v0.7.0 | 5.175 | 9.65 | 7.05 |

DECIDED on the owner's word (2026-10-01), by one form:
- **The span field carries the error's pair.** `span` is `(name . where its withheld bytes begin)` at an error with a span open, and #f on every other result, where the core never read it. Weighed: a sixth field, 16 B more a read.
- **Merge #90 and #91 first, then this as one PR from main.** The closing ritual ran on that answer (above). Weighed: stacking it on #91; folding it into #91, so the workaround never reached main.

What was built:
- The pins: chez-httparse v0.4.5 and uriparse v0.6.2, gitlinks and `make check-pins`'s three commits, so byte-machine v0.7.0 arrives through both. Each tag was fetched from the sibling's own checkout, and both nested byte-machine checkouts follow.
- `(http-server private adapter)`: `parser-result-event : ParserResult -> Event`, built from the result alone. At an error with a span open, `span` is `(cons (parser-error-span e) (parser-error-span-offset e))`, and otherwise #f.
- `(http-server connection)`: `cut-off-past-limit` counts a target's or a name's withheld bytes from the error's offset to the refused byte, after the ones a read's end handed on. For a target that began in the read that failed, `close-judged!` judges the spaces before it first, as its first fragment's would have been. `conn-line` goes, with its five setters, the `on-version-complete` clause, and `space-at?`.
- Both shells call `(parser-result-event r)`.

Checks:
- `tests/test-connection-cut-off.sps`, 11:
  - The shape check holds the new results: need-input without a span; three errors with `(url-span . 4)` or `(url-span . 6)`; and one with none open, in the whitespace before a value.
  - New: a target the core refuses at its head's end, on a request line with no version and no fields, is answered 400 for the target at every delivery size, not for the run the line leaves open (below).
  - The tripwire is gone.
- The table's K1–K4 hand the core the error's pair: from the target's start, from the read's start for a carried one, from past the spaces, or from a name's line start.

Red before green, at the new pins:
- On the old code, the cut-off suite failed its two shape checks.
- The table failed six of K1–K4's twelve instances, in K1, K2 and K4. K3's answer, for the spaces, comes out the same either way.

Mutants (`.superpowers/sdd/m6-mutations.md`, "The pin PR"): eighty-nine on the finished tree, none surviving:
- seventeen new, Y-A1 to Y-S2, each against all forty-four suites;
- ten of the cut-off-span PR's;
- the padding PR's sixty-two.

Withdrawn, their code gone: X-B1, the tripwire's; X-L1 to X-L7, the line starts'; X-T1 and X-T5, the target's placement and its space check. Seven more were cut again as new ones. Every new and changed check is mapped by name to a mutant that reddens it.

FOUND WHILE BUILDING:
- **The guard for the core's own refusal had lost its checks.** On the first run, X-C3, which lets the cut-off judgment run under a refusal the core already holds, survived. Under #91 its checks were two refusals of spaces after the method, met as the target's first bytes arrived; #91's placement counted that read from its start as target. v0.7.0 records nothing withheld at a data callback that fails, so those checks pass with the guard gone. The guard still matters where a run is left open. A request line with no version and no fields keeps the run after its target open to its head's end, and on X-C3's mutant `GET /%zz` with no version and no fields was answered for the spaces (400 `request-line-spaces`), where the tree answers `invalid-target`. The new check holds it, and X-C3 reddens it.
- **X-C4's first run did not load:** its cut named `span`. The runner's tally now counts a suite that reports neither passes nor failures as a load failure, not a kill.
- **The allocation suite builds its results by hand,** so a field added in `parser-result-event` prices the same there. Its builders were widened to price the sixth field.
- **Decision 0008 has no row for chez-httparse #55,** filed on 2026-09-30 in the padding PR's review and landed in v0.4.4, though the ledger cites 0008 for it. It is not fixed here, so 0008's new line says every ask its table lists has landed, without a count.

`make test`: forty-four suites, 1,433 expected passes, every pin ok.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and apache2-utils' ab installed: forty-four suites, 1,433 expected passes. The shell, contract, clients, serve, cut-off and table suites each passed in all three repeat runs.

Size: `src/` +58 −84 and `tests/` +64 −74, comments included; the Makefile's three pins; the two gitlinks; the records, `.plans/` +36 −2 and `.superpowers/` +144 −1, this entry among them. One PR, by the form.

NEXT: this PR, merged on the owner's "do closing ritual" once CI is green on its head. Then the M6 exit (plan §14).

MERGED to main on 2026-10-01, on the owner's "do closing ritual": **#92, the pin PR.** fe543ee was squashed as 29ae566 (tree 2594120, the tested tip's), whose parent is 4086735.
- **CI.** Its run, 36928864872, passed on fe543ee.
- **Branches.** `--delete-branch` switched this checkout to main, fast-forwarded it, and deleted the branch, local and remote.

`make test` green on main at chez-httparse v0.4.5 and uriparse v0.6.2, with byte-machine v0.7.0 through both: forty-four suites, 1,433 expected passes, every pin ok.

NEXT: the M6 exit (plan §14). Also under way, in a session of its own started on the owner's word: chez-httparse #55's missing row in decision 0008 (FOUND above).

MERGED to main on 2026-10-01, on the owner's "do closing ritual": **#93, decision 0008's records for chez-httparse #55** (the FOUND above). 2a59fe5 was squashed as 44d30ee (tree 7c5e676, the tested tip's), whose parent is 2f685ae.
- **What.** 0008 gains #55 in the Decision paragraph's list, a row after chez-httparse #50 (LANDED 2026-10-01 in v0.4.4), and a Consequences bullet for the landing, placed by date before byte-machine #145's filing. The bullet's count, all twenty-two filed asks landed, is the table's 23 rows less #145, which was filed after #55 landed.
- **Rebased.** #92 merged while #93 was open and wrote byte-machine #145 into the same Decision sentence. So #93 was rebased onto 2f685ae, and the sentence keeps both, #55 before #145. The resolution was built two ways, which agreed byte for byte.
- **CI.** Its run, 36934579840, passed on 2a59fe5.
- **Branches.** Merged from its own worktree without `--delete-branch`, while the shared checkout held main. The branch was deleted by hand, local and remote, and the shared checkout's main was fast-forwarded behind the guard.

`make test` green on main: forty-four suites, 1,433 expected passes, every pin ok.

NEXT: the M6 exit (plan §14).

M6 EXIT (plan §14), on the owner's word: "lets close out M6". Branch feat/m6-exit, cut from main at 6b43a5a; 2026-10-02, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. Mutation log: m6-mutations.md, "The M6 exit".

Gathered before the first test, from the brief's M6 and plan §14:
- the brief's exit: 16 MiB each way against a slow peer with bounded memory; libhtp's Expect and early-response files pass;
- plan §14: the memory read as the M4 exit read a connection, the server's heap, the client in a process of its own; `docs/handlers.org` gains bodies.

Met before this branch, each with its check:
- libhtp's Expect files, `05-expect.t` and `99-expect-100.t`, pass since M6.4, delivered with CRLF: the ratchet's fourteen libhtp streams;
- `docs/handlers.org` covers bodies: "Reading the body" since M6.1, "Streaming a response" since M6.3, the 100 since M6.4;
- the brief's M6 scope: credit-based delivery (`body-credit`, M6.2), streaming responses with `notify-producer` (M6.3), and `100 Continue` written when the handler pulls the body (M6.4). Its "four read-stop conditions and the single read-start predicate" came from the research's parse-ahead prototype (`research/async-sans-io-state-machine.md` §5). Decision 0004 made pipelining serial, so design §4.4's rows stop reading at a message's end, at a credit wait (M6.2) and at a response given instead of a reader, and start it again when a response is written or a credit covers what was handed.

Missing:
- 16 MiB each way, read or checked. The bounds were checked at 1 MiB, streamed to a client that reads nothing, and at 64 KiB, an upload on credit, each with the client on the server's own loop;
- `35-early-response.t` passed with a handler that reads the body, as the M2 exit expected, and is the suites' only HTTP/1.0 body read. Its recorded origin answered 400 before the body, which a handler can since M6.1, and nothing ran it so;
- the README's status still listed request bodies as still to come.

MEASURED, before the form: `research/spike/m6-exit-sixteen.sps` and `m6-exit-peer.py`, two runs on each platform. A server is started as `serve` starts one. A Python peer, in a process of its own, holds one keep-alive connection to it, sends it 16 MiB as a POST's body, which `read-body` checks and keeps none of, then reads 16 MiB streamed back in 16 KiB pieces, 16,384 B at a time with 2 ms between. The server's heap is read every 50 ms after two full collections, and the peer reads its resident memory from outside.

| Each way, two runs | Darwin arm64 | Linux aarch64, in Docker |
|---|---|---|
| the upload: time; heap at most | 2.644 and 2.635 s; +61,392 and +34,328 B | 3.110 and 3.106 s; +95,104 and +74,808 B |
| the upload: resident memory | +16 and +32 KiB | +68 and +80 KiB |
| the download: time; heap at most | 2.605 and 2.616 s; +24,152 and +688 B | 3.181 and 3.122 s; +688 and +688 B |
| the download: written and not completed, at most | 262,272 B, in 16 write requests at most | 262,272 B, in 14 and 16 |
| the download: resident memory at most, then after | +1,808 then +384 KiB; +2,464 then +384 | +3,400 then −1,960 KiB; +2,376 then +128 |
| held whole: the body read by `read-whole-body`, its cap raised to 32 MiB | heap +16,847,304 and +16,863,648 B; resident +33,200 KiB | heap +16,854,384 and +16,830,496 B; resident +26,924 and +23,712 KiB |
| held whole: the answer as one bytevector | a write block of 16,777,298 B; resident +16,432 and +9,952 KiB | 16,777,298 B; resident +32,948 and +33,188 KiB |

Every byte arrived in order each way, and every piece handed the reader was 16,384 B or less. The producer was called 1,025 times, a piece each and its end. 262,272 B is the high water and one piece's write, 16,392 B: its size line, `4000` CRLF, the piece and CRLF. Linux is Debian 12 in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6), Chez 10.4.1 `tarm64le`, libuv 1.44.2, Python 3.11.2; Darwin's Python is 3.14.5.

A prototype of the check, curl at 16 MiB/s in the clients suite: 19 checks pass, and the suite took 2.85 to 2.87 s, where main's takes 0.84 to 0.88 (Darwin). Four of the mutants below each reddened their check. On Linux it took 2.63 to 2.81 s.

DECIDED on the owner's word (2026-10-02), by one form:
- **`35-early-response.t` runs both ways.** Its expectation stays, its handler reading the body. A second run answers 400 at the head, as its recorded origin did. Weighed: the early answer only, which drops the suites' one HTTP/1.0 body read; leaving it as the M2 exit wrote it.
- **The 16 MiB transfers are checks in `make test`**, curl at 16 MiB/s in the clients suite, about 2 s more. Weighed: the spike's readings alone.

BUILT:
- `tests/test-clients.sps`, 19 checks (main's 14). Against the suite's server, curl, a process of its own, sends 16 MiB chunked from its standard input, which the suite writes a 16 KiB piece at a time, to `/sixteen`, whose reader checks every byte and keeps none. It then reads 16 MiB from `/sixteen`'s producer, 1,024 pieces of 16 KiB, which the suite checks as curl hands them over and keeps none of. Each runs at 16 MiB/s (`--limit-rate`). Five checks:
  - the upload arrives in order, no read handing the reader more than the read buffer;
  - the server's heap, read every 50 ms after two full collections, five readings or more, grew by less than 1 MiB as it came in;
  - the download arrives in order;
  - the bytes written and not yet completed backed up past the low water, and never passed the high water by more than a piece's write;
  - the server's heap grew by less than 1 MiB as it went out, read the same way.
  The suite's `spawn` and `run` take a pipe for the child's standard input, a procedure that takes its output, a watch and a cap. Its other checks call them as before.
- `tests/libhtp-lane.sls` and `tests/test-libhtp-lane.sps`, 20 checks (19). `35-early-response.t` is run again, its handler answering 400 at once. After the head's packet alone, the connection has asked the handler, written the 400 and lingers, close-after `not-keep-alive`. After the whole stream and its eof, it is closed, and no reader was handed the body. The lane's own run goes through `run-stream`.
- The README's status: since M6, a handler reads a body as it arrives and can stream its response. `docs/handlers.org`: `read-body` never holds a body whole, a 16 MiB upload adding under 100 KB to the server's memory.
- `.plans/research/spike/m6-exit-sixteen.sps` and `m6-exit-peer.py`, new, with four runs in `out/`.
- Records: plan §14's M6 exit note; design §7.5's and §8.2's notes; the research README; m6-mutations.md.

Measured on the finished tree, the clients suite printing what its checks read:
- Darwin, three runs: the upload's heap +80,520 to +82,800 B and the download's +56,248 to +62,592, in 21 readings each, the bytes outstanding 262,272 at most, the largest piece 16,384. The suite took 2.80 to 2.82 s, main's 0.75;
- Linux, eight runs: the upload's heap +31,968 to +53,448 B in 21 readings, the download's +38,648 to +52,424 in 14 to 21, the bytes outstanding 229,488 to 262,272 as read after each turn. The suite took 2.37 to 2.49 s, main's 0.69 to 0.80;
- curl unlimited: two or three readings each way on both, where curl at the limit took 14 to 21. So the readings check is five, not the ten the prototype had: the download took 14 on Linux.

Watched to fail (m6-mutations.md, "The M6 exit"): nine mutants of the code, M6X-A to M6X-I, each against all forty-four suites, and three calibrations of the checks. None survives, and none failed to load. By check:
- the upload's arrival by M6X-F, the read buffer at chez-libuv's default;
- the upload's heap by M6X-B and M6X-C, the body kept by the core or by the shell, and its readings half by C-fast, curl unlimited;
- the download's arrival by M6X-I, a piece's size line a byte short;
- the bytes outstanding by M6X-A, high water ignored, and M6X-E, a write reported completed as it is sent;
- the download's heap by M6X-D, the shell keeping its writes, and C-fast;
- the lane's early run by M6X-G, the handler not asked at the head, and C-read, its handler reading.
M6X-B and M6X-C redden the clients suite alone: before the exit, no check read the heap while a body came in. M6X-H, a write sent before those held, reddens the shell suite alone, since a 16 KiB piece is never held.

`make test`: forty-four suites, 1,439 expected passes (1,433 + 6), every pin ok, 27.8 s.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Debian 12, Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree made with `COPYFILE_DISABLE=1`, curl 7.88.1 and ab 2.3 installed: forty-four suites, 1,439 expected passes, 30.1 s. The clients suite passed its 19 and the libhtp lane its 20 in each of three runs more.

Size: `tests/` +259 −55, comments included; the spike's two files, 380 lines, and their four runs; the README and `docs/handlers.org` +6 −2; the records, `.plans/` +47 −1 and `.superpowers/` +59 before this entry.

DECIDED on the owner's word (2026-10-02), by a second form, after the walkthrough: **one PR now.** Weighed: leaving it uncommitted for the owner to read first.

NEXT: this PR, merged on the owner's "do closing ritual" once CI is green on its head. M6 is then complete. Then M7 (plan §14), when the owner asks.

MERGED to main on 2026-10-02, on the owner's "do closing ritual": **#94, the M6 exit.** 0fccd2a was squashed as d9949f6 (tree 32758a9, the tested tip's), whose parent is 6b43a5a.
- **CI.** Its run, 36997657028, passed on 0fccd2a: 1,439 expected passes in its log.
- **Branches.** `--delete-branch` deleted the remote branch but left this checkout on it, so the switch to main, the fast-forward and the local deletion were done by hand.

`make test` green on main: forty-four suites, 1,439 expected passes, every pin ok.

DONE and merged (d9949f6, PR #94): **M6 COMPLETE.**
- The brief's M6 exit is met. 16 MiB move each way against a slow peer, curl at 16 MiB/s in a process of its own, and the server's heap grows 32 to 83 KB. The bytes written and not completed stay within the high water and one piece's write. libhtp's Expect files pass, and its early-response file passes both ways: read, and answered at the head. `docs/handlers.org` covers bodies.
- M6's slices, each merged: M6.1, how a handler reads a body (decision 0013; #69, #70); M6.2, the read side's credit (#71, #72); M6.3, a streamed response (#74 to #78); write batching (#79); M6.4, Expect, trailers and the exit's files (#80 to #82); the padding PR and its review (#83 to #87); the cut-off-span PR (#90, #91); the pin PR (#92); and this exit.
- Upstream, every ask decision 0008 lists has landed; nothing is open.

NEXT: M7 (plan §14), the scheduler and awaiting handlers, on a fresh branch cut from main after this commit, when the owner asks.


