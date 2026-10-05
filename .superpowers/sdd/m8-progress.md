# chez-http-server — ledger archive: M8, shutdown, hand-off, black-box and release

M8's entries, moved verbatim from `progress.md` on 2026-10-05 (its lines 4206–4989 at 64761cb). The mutation log is `m8-mutations.md`; the spine is `progress.md`.

---

M8.1: THE DRAIN (plan §14), on the owner's word: "start M8.1". Cut from main at 0ad7511 as feat/m8.1-drain, 2026-10-03, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. Mutation log: m8-mutations.md, "M8.1".

Gathered before the first test, from the brief's M8 and plan §14:
- the brief: SIGTERM drain with deadline;
- plan §3: `drain-timeout-ms`, 10,000 after SIGTERM, force-close all, arrives in M8 with its four things (the field, a value test against 0005's default, its variable in `limits-environment-variables`, the drift guard over it);
- plan §14: `server-step` gets the rest of the drain (the connections told to finish; `force-close-all` on the tick at the deadline; the drain's end on `connection-closed`); the core gets `shutdown-requested` rows for its in-flight states, today only `idle` has one; the shell watches SIGTERM through a signal handle, and `serve` returns when the drain ends; on a socket, a request in flight at SIGTERM is answered, then closed, an idle keep-alive connection closes at once, and a client that holds its connection is closed at the deadline; the mutation, `force-close-all` never asked for, reddens the held connection's row;
- design §4.4's row: any state, `shutdown-requested`: finish in flight, `Connection: close` on the last response, then close; decision 0011's amendment: a close with no response is at once.

MEASURED, before the form (scratch probes on main at 0ad7511):
- **A shutdown tells no connection anything.** `shell-shutdown!` closes the listener and nothing else: an idle keep-alive client, a request in flight on a handler that waited 150 ms, and a client holding half a head were all still open a second later, and the request in flight was answered keep-alive, with no `Connection: close`, its connection idle again. The shell never dispatches `shutdown-requested` to a connection, and never tells the server `connection-closed`: so a drain never ends while a client keeps using its connection.
- **SIGTERM kills `serve` at once.** `tests/serve-child.sps`, sent SIGTERM once it logged `listening`, ended by the signal.
- **SIGINT does not stop an idle `serve`.** Sent SIGINT, the child ran on through 20,000 iterations of a 1 ms ticker; a request then was reset (ECONNRESET, nothing read), and the child exited 255. Chez takes SIGINT as a keyboard interrupt, which it services only when Scheme runs, and an idle loop runs none.
- **Once SIGINT has been watched, Chez's keyboard interrupt is gone.** A watch of SIGINT started, stopped and closed: the next SIGINT ended the process, exit 130; with no watch first, Chez's keyboard interrupt handler ran.
- **The shell's timer stops while its only connection is in `handling`.** The core arms no deadline there (design §4.3), so the wheel empties: with a handler waiting 300 ms, tick-ms 10, the server was told the time once in 200 ms. A drain whose connections are all in `handling` would never reach its deadline.

DECIDED on the owner's word (2026-10-03), by one form, on those measurements:
- **"SIGTERM and SIGINT (Recommended)":** both signals start the drain; once `serve` returns, a later SIGINT ends the process (exit 130) rather than breaking into Chez. Weighed: "SIGTERM only (the plan)", Ctrl-C left as measured.
- **"Start, cut-off, end (Recommended)":** the drain logs `draining` with the connections it waits for as it starts, `drain-timeout` if the deadline closes connections, and `stopped` when it ends. Weighed: "No new lines".

Settled by the plan and the records, with no form:
- an idle connection closes at once, with no response, as at its idle deadline (plan §14; 0011's amendment). So the core's `draining` state, which only `idle` entered, half-closing, is left with no row into it, and is retired;
- a connection with a request in flight is answered with `Connection: close` if its head is not yet written, its pipelined rest dropped (0004 item 4), and lingers after, as every close after a response does (0011);
- the step keeps no count (decided 2026-09-26), so `shutdown-requested` and `listener-failed` carry the loop's time and the connections open, as an arrival carries its count; a listener's failure drains the same way;
- the shell keeps its timer running while the server drains, whatever the wheel holds, so the deadline is told the time;
- `serve` returns when the drain ends, whatever waits are still armed: the loop's teardown closes them.

M8.1 BUILT in one working tree, then measured (2026-10-03), before the walkthrough: `make test` green, forty-seven suites, 1,685 expected passes (1,645 + 40), every pin ok; sixty-three mutants on a frozen copy of the tree, each against every suite, each loading, each reddening a check; every one of the seventy-one checks the slice added or changed reddened by one, sixty-seven by name and four whose expected value alone changed (m8-mutations.md, M8.1). Plan §14's mutation, `force-close-all` never asked for, reddens the held connection's row, as the plan expects, and the server's deadline rows and both signal checks beside it.

DECIDED on the owner's word (2026-10-03), by form, after the plan-vs-landed walkthrough: **"Review, then 3 stacked PRs (Recommended)"**: a /code-review high of the uncommitted branch first, its findings fixed on the owner's word; then one PR a step: the limit and the core's rows (+121 −55), the drain in the shell (+616 −179), the signals and `serve` (+203 −18, and the records). Weighed: "3 stacked PRs now", and "Review, then 1 PR".

M8.1's REVIEW (2026-10-03, on the owner's form): a /code-review high of the uncommitted branch found nine:
1. a forced close at the drain's deadline closes each handle with no step of the core, so a write still outstanding is cancelled into a core in `responding`, which logs it as a transport failure: measured, a client that never reads an 8 MiB answer, a 200 ms drain, logged `draining 1`, `drain-timeout`, `read-error ECANCELED`, `stopped`;
2. the serve suite's signal checks need the child's 600 ms sleep to outlast the time from its `handling` line to the signal, a wall-clock margin: on a slow runner the request is answered before the signal, keep-alive, and both checks fail with the server right;
3. libuv never delivers SIGTERM on Windows (its `docs/src/signal.rst`: SIGINT, SIGBREAK, SIGHUP and SIGWINCH alone), and a console's close arrives as SIGHUP, which the server does not watch; the docs name SIGTERM with no platform note;
4. once `serve` returns, the loop's teardown runs the loop until every request completes, and a lookup already running cannot be cancelled: the records' "the loop's teardown closes them" overstates it, and a slow lookup holds the process past the drain;
5. the listener's failure, which now carries the time and the count and starts a timed drain, is reported by libuv only on Windows, so no suite reaches the shell's line for it; the server's rows cover the step;
6. `docs/handlers.org`'s "once `serve` has returned, Ctrl-C ends the process at once" rests on a scratch probe, no check;
7. the serve suite's `drained-by-a-child` repeats `served-by-a-child`'s spawn, collector, kill and teardown;
8. the shell suite's `firings-of` repeats the deadline block's `firings`;
9. `event-fields` finds an event's time and count by index arithmetic keyed on its kind, where per-kind shapes would read plainly.

DECIDED on the owner's word (2026-10-03), by form: **"Fix 1, 2, 6–9; note 3–5 (Recommended)"**: the core takes a cancelled request as its own close, with no log (1); the serve suite's in-flight request made in flight by construction (2); a check that once `serve` has returned a SIGINT ends the process (6); the three cleanups (7–9). Noted: Windows' SIGTERM in the docs (3), a running lookup at `serve`'s return in the records (4), and the listener's failure as a scope statement (5). Weighed: "Fix 1 and 2; note the rest", and "Fix all, SIGHUP drains on Windows", a new decision on signals.

FIXED as decided, before the first commit, each in the step it belongs to: the first's row in the first step, and its socket check, the eighth and the ninth in the second; the second, sixth and seventh in the third, whose records note the third, fourth and fifth. Red first: T12, the core's new row, failed both its instances, and the shell's slow reader found `read-error ECANCELED` in the log; the serve suite's check of a SIGINT once `serve` has returned failed against the child before it sent one, the child exiting 0. Then each step's tree was made afresh, main's with the step's files, its `make test` run and its own mutants run on it, and all sixty-five on the finished tree.

M8.1 FIRST STEP: the limit, and the core's shutdown rows (feat/m8.1-rows).
- `src/http-server/limits.sls`: `drain-timeout-ms`, the twentieth field, 10,000, read from `CHEZ_HTTP_DRAIN_TIMEOUT` in whole seconds, 0 accepted; in `limits-environment-variables`, and under the drift guard.
- `src/http-server/connection.sls`: told to finish, `idle` closes at once, with no response, for `shutdown`; `head`, `body`, `awaiting-credit`, `handling` and `responding` close after their response, for `shutdown` unless for a reason of their own; the rest ask for nothing. `draining`, which only `idle` entered, half-closing, is retired, its two rows with it: ten states. And a read error whose errno is ECANCELED closes for `cancelled`, logging nothing (the review's first).
- `tests/test-limits.sps`: the drain's value test, its variable, its override in seconds, 0 accepted and below 0 refused, the drift guard and `limits-with` over it.
- `tests/test-connection-table.sps`: T8 instantiated on every state that answers it, ten instances; T10, the response of a request told to finish says `Connection: close`; T11, its last write's completion lingers, the pipelined rest dropped; T12, a cancelled request closes with no log; D3 and T2's `draining` instance retired; the states, ten.
- Records: design §4.3's and §4.4's notes, and §9.4's count of the limits.

Measured on the step's tree (2026-10-03, Darwin arm64): `make test` green, forty-seven suites, 1,657 expected passes (1,645 + 12), every pin ok. Red first: before the core's rows the table failed eleven checks, the ten states, T8's seven new instances, T10, T11 and the held pairs, then T12's two once the review wrote it; the limits suite did not load, with no accessor.

Watched to fail (m8-mutations.md, M8.1, the first step): eighteen mutants on the step's tree, each loading and reddening a check; every one of the fourteen checks the step added or changed reddened by one.

Size: src +50 −24; tests +90 −32.

NEXT: the second step, the drain in the shell, stacked on this one.

M8.1 SECOND STEP: the drain in the shell (feat/m8.1-drain).
- `src/http-server/server.sls`: the drain. `shutdown-requested` and `listener-failed` carry the loop's time and the connections open; a sixth action, `finish-all`, tells those open to finish; the drain's deadline is the time plus the limits' drain timeout, and the first tick at or after it asks for `force-close-all`, once; a third phase, `stopped`, comes at the last close, or at once with none open; logged `draining` with the count, `drain-timeout` and `stopped`. Each event's shape is checked by `shaped` (the review's ninth).
- `src/http-server/private/shell.sls`: a shutdown, or a listener's failure, told with the loop's time brought up to date and the table's size; `finish-all` dispatched to each connection and `force-close-all` closing each, each under its own guard, the first raise kept (`kept-raise`, tick!'s rule, now shared); each close told to the server with the connections left, and each connection the reconciliation drops; the timer running while the server drains, whatever the wheel holds, and started as the drain begins.
- `tests/test-server.sps`: twenty-nine rows on a fake clock, three drain sequences, and the vocabulary and shape checks, forty-two in all.
- `tests/test-shell.sps`: the drain on shells of their own, 200 ms long: an idle connection closed at once; a request in flight answered, saying it closes, and closed once its client closes, before the deadline; half a head closed at the deadline, on time, read from the trace; one held in its handler, nothing armed, the timer stopped first, closed at the deadline, on time; a slow reader closed at the deadline, no read error logged (the review's first); the drain's end, stopped, logged, no timer; a reconciled connection ends a drain; a shutdown dated by the loop's time brought up to date; a raise as each connection is told to finish. The deadline block counts its firings with `firings-of` (the review's eighth).
- Records: design §4.6's note.

Measured on the step's tree (2026-10-03, Darwin arm64): `make test` green, forty-seven suites, 1,684 expected passes (1,657 + 27), every pin ok.

Watched to fail (m8-mutations.md, M8.1, the second step): forty-one mutants on the step's tree, plan §14's among them, each loading and reddening a check but M8H-15, the listener's failure, which libuv reports only on Windows: a scope statement (the review's fifth). Every one of the fifty-five checks the step added or changed reddened by one.

Size: src +211 −87; tests +426 −97.

NEXT: the third step, the signals and `serve`, stacked on this one.

M8.1 THIRD STEP: the signals and `serve` (feat/m8.1-signals).
- `src/http-server/private/shell.sls`: `shell-watch-signals!`, a signal handle each for SIGTERM and SIGINT, which ask the server to shut down; a shell watches once, while it listens, and closes them once it serves no more.
- `src/http-server/private/serve.sls`: `serve` watches the signals, and returns when the server has stopped.
- `tests/serve-child.sps` and `tests/test-serve.sps`: `serve` itself, in a process of its own, sent SIGTERM, then SIGINT: an idle client closed at once; a request in flight, its body sent once the drain has begun, answered saying it closes (the review's second); one held a minute closed at the 2 s deadline; the drain logged; `serve` returning, the process exiting 0. Once `serve` has returned, a SIGINT ends the process (the review's sixth). One helper starts and ends the child (the review's seventh).
- `tests/test-shell.sps`: the watch: two handles, watched once, closed once the shell serves no more; a shell stopped first is refused one.
- Records: plan §14's note; design §4.6's last bullet; decision 0005's amendment; `docs/configuration.org`, `docs/connections.org`, `docs/handlers.org` and the README's status; the review's third and fourth noted there and in `serve.sls`.

Measured on the finished tree (2026-10-03, Darwin arm64): `make test` green, forty-seven suites, 1,689 expected passes (1,684 + 5), every pin ok.

Watched to fail (m8-mutations.md, M8.1, the third step): sixty-five mutants on the finished tree, the step's six and the first two steps' fifty-nine, each loading and reddening a check but M8H-15. Every one of the seventy-four checks the slice added or changed, seventy by name and four whose expected value alone changed, is reddened by one.

Size: src +51 −12; tests +196 −29.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Linux 6.12.76-linuxkit aarch64, Chez 10.4.1, libuv 1.44.2), from a copy of the finished tree made with `COPYFILE_DISABLE=1`, curl, ab and python3 installed: `make test`, less its submodule and pin checks, forty-seven suites, 1,689 expected passes; and the server, shell and serve suites green three more times each, 43, 169 and 15.

M8.1 BUILT, the three steps proved each on its own tree (2026-10-03):
- the first, main at 0ad7511 with its files: `make test` green, forty-seven suites and 1,657 expected passes; its eighteen mutants there, 14 of 14 checks;
- the second, on the first: 1,684; its forty-one mutants there, 55 of 55 checks, M8H-15 surviving as a scope statement;
- the third, the finished tree: 1,689, on Darwin and on Linux; sixty-five mutants, 74 of 74 checks, M8H-15 surviving.

Size, against main: src +310 −121; tests +711 −157; and the records.

NEXT: the three stacked PRs, as decided, merged bottom up on the owner's "do closing ritual" once CI is green on each head. Then M8.2, the hand-off door, decided first (plan §14), when the owner asks.

MERGED to main on 2026-10-03, on the owner's "do closing ritual": **M8.1, as three stacked PRs.**
- **#106, the drain's limit and the core's shutdown rows,** as 71878db. Its squash tree (3a64712) is the tested tip's, 21ff9aa's, and its parent is 0ad7511. It merged first and kept its branch, since #107 was based on it.
- **#107, the server drains its connections,** as f2d256c. It was retargeted to main and rebased from #106's tip, 21ff9aa. The rebased tip, 9b96876, has the tested tree (e7a66c8, f9d1d66's), and so does the squash, whose parent is 71878db. It kept its branch, since #108 was based on it.
- **#108, SIGTERM and SIGINT drain `serve`,** as 7bcfcb4. It was retargeted to main and rebased from #107's first tip, f9d1d66. The rebased tip, 6826c6d, has the tested tree (717f255, b3b9405's), and so does the squash, whose parent is f2d256c.
- **CI.** Each merged on `linux` SUCCESS at its head: #106 on 21ff9aa (run 37133157275); #107 on 9b96876 (run 37133338112); #108 on 6826c6d (run 37133494793). Each log holds its step's count: forty-seven suites, 1,657, 1,684 and 1,689 expected passes.
- **Branches.** All three deleted, local and remote, and refs pruned. No PR is open.

`make test` green on main: forty-seven suites, 1,689 expected passes, every pin ok.

DONE and merged (71878db, PR #106; f2d256c, PR #107; 7bcfcb4, PR #108): **M8.1, the drain.**
- SIGTERM or SIGINT drains `serve` (SIGINT decided by form): the listener closes, idle connections close at once, requests in flight are answered with `Connection: close`, and what is open at `drain-timeout-ms` (10 s, `CHEZ_HTTP_DRAIN_TIMEOUT`) is closed; the drain is logged, `draining`, `drain-timeout`, `stopped`, and `serve` returns at its end.
- Found and fixed on the way: the shell's timer stopped while no connection had a deadline, and the shell told the server of no close, so a drain could neither reach its deadline nor end; and a forced close logged its own cancellation as a read error (the review's first).
- Decided by form: SIGTERM and SIGINT; the drain's three log lines; review, then three stacked PRs; the review's 1, 2 and 6–9 fixed, 3–5 noted. A /code-review high found nine.

NEXT: M8.2 (plan §14), the hand-off door, decided first, when the owner asks.

M8.2: THE HAND-OFF DOOR, on the owner's "start M8.2". Built on feat/m8.2-door, cut from main at 70b7adf; 2026-10-03, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

MEASURED FIRST, on main (`research/spike/m8-today-101.sps` and `m8-door-pending.sps`, through the fake shell with the real parser, adapter and core, two identical runs each):
- today a handler cannot take an upgrade: a WebSocket handshake answered with a 101, with or without `Connection: upgrade`, is answered 500, logged `invalid-response invalid-status`; answered 200, it is served and the connection closed, close-after `upgrade`;
- the core already holds what the door must hand over: when the handler is asked, its pending input is the rest of the last read from `parser-result-next`, reading having stopped at the message's end. Six inputs at every delivery size, 525 runs: the pending input began at the request's end every time, and it, with what was left unread, was exactly the bytes after the request (a WebSocket handshake alone, 72 sizes, and with a masked frame sent early, 80; an upgrade with a body and a frame, 93; a CONNECT with 6 bytes, 65; `Upgrade: h2c` with the HTTP/2 preface, 144; an HTTP/1.0 handshake with a frame, 71).
Read beside them: the servers surveyed (h2o and hyper write the 101 and hand over the raw socket; Node and Go have the handler write it; Go's `Shutdown` "does not attempt to close nor wait for hijacked connections such as WebSockets", read in net/http's `server.go` that day; Kestrel counts upgraded connections under a limit of their own, read in its API reference that day); and RFC 9110 §7.8 and §15.2 and RFC 6455 §4.1, read that day.

DECIDED on the owner's word (2026-10-03), by form, as decision 0016: **"The server (Recommended)"** writes the 101, for a handler that answers `(switch-protocols headers take-over)`; **"Tell it, then wait (Recommended)"** for the drain; **"Upgrades only (Recommended)"**: an HTTP/1.1 upgrade with no body. To the second question the owner answered "We need to discuss the tradeoffs. the reference servers use a raw handle and loop, what doe the server keeping it gain?", answered with what keeping the stream gains (the drain just chosen, `max-connections` bounding the read buffers, every close seen, a taker's bug closing only its stream, fake-transport tests, one timer, no chez-libuv pin for takers) and what the raw handle gains (all of libuv, less code and API, the peers' shape); then, on a second form, **"Transport; server keeps it (Recommended)"**. Weighed: the handler writing the 101; the raw handle and the loop; a drain that closes a taken stream at once, or waits for it untold; CONNECT tunnels too.

M8.2 BUILT in one working tree, then measured (2026-10-03, Darwin arm64), before the walkthrough: `make test` green, forty-eight suites, 1,788 expected passes (main, re-measured: forty-seven suites, 1,689), every pin ok; and on Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree made with `COPYFILE_DISABLE=1`: forty-eight suites, 1,788, and the switch, shell and serve suites green three more times each, 21, 187 and 16. Eighty-six mutants on frozen copies of the tree, each loading and reddening a check; every one of the eighty-four checks the slice added or changed reddened by one. Plan §14's mutation, the retained bytes starting a byte late, reddens the table's hand-off row, W2, and the contract at every delivery size, as the plan expects.

Three steps, each proved green on a tree of its own, main's with the step's files: the switch, the transport and the 101 (forty-seven suites, 1,726; code +248 −8, tests +189 −4); the core's door and the fake transport (forty-eight suites, 1,769; code +117 −26, tests +610 −28); the shell's transport and the facade (1,788; code +197 −10, tests +458 −12).

FOUND while building:
- a taker's call that returned no values made chez-libuv's close callback raise, and the run loop with it: the shell drops what a taker's call returns (decision 0016's list);
- RFC 9110 §7.8 has a server that receives Upgrade and an Expect of 100-continue send the 100 before the 101: the door's request has no body, so M6.4 sent it none, and the switch now writes it first (W7);
- the parser's own hand-off row, T7, was unreachable: the core never resumes the parser onto an upgrade. Retired, a refusal now.

The first mutation run left survivors, each settled: a deadline's call cleared after it passes, and a guard that reported a read's end once, were redundant (the wheel and libuv already do each once) and were taken out; letting the parser go at the hand-off had no check that could see it and was taken out; and four checks were added: a taker's close waiting for a 4 MiB write still under way, a deadline armed once the timer had stopped, a deadline disarmed leaving none armed, and a drain call registered again not run.

NEXT: the plan-vs-landed walkthrough, then the review and the PRs, by form.

DECIDED on the owner's word (2026-10-03), by form, after the plan-vs-landed walkthrough: **"Review, then 3 stacked PRs (Recommended)"**: a /code-review high of the uncommitted branch first, its findings fixed on the owner's word; then one PR a step: the switch, the transport and the 101 (code and tests +437 −12); the core's door and the fake transport (+727 −54); the shell's transport and the facade (+655 −22), each with its records. Weighed: the same review, then four PRs, the core's rows (+297 −40) apart from the fake transport (+430 −14); and three PRs with no review.

M8.2's REVIEW (2026-10-03, on the owner's form): a /code-review high of the uncommitted branch found ten:
1. a taken stream has no bound on its writes outstanding and no write deadline: measured, a client that sent 4 MiB to an echoing taker and read nothing left 28 and 107 writes outstanding in two runs (0.4 and 1.7 MiB), growing with what the client sends;
2. a write the shell counts before `uv-write*!` stays counted when the call raises anything but a transport failure (`&uv-wrong-thread`, from another thread), so `transport-close!` never closes the stream;
3. three test renderers (`outcome-lane.sls`, `libhtp-lane.sls`, `test-message-loop.sps`) still read a hand-off as `(hand-off request)`;
4. a 101 that lists protocol layers, the one in use among them (RFC 2817's `Upgrade: TLS/1.0, HTTP/1.1`), is refused: HTTP/1.1 was not offered;
5. the door reads the parser's upgrade flag from the close-after reason, a field other rows set;
6. a taker's callbacks deferred to the next turn are lost when `serve` returns first;
7. the fake transport arms a deadline on a stream that has closed, where the shell's does not;
8. a close call registered after the stream has closed is never called, where the docs say it is called once the stream has closed;
9. the serializer repeats `(http-server headers)`' scan of a field's list;
10. a taker's writes are one write request each, never batched as the core's are under 4 KiB.

DECIDED on the owner's word (2026-10-03), by form: **"Fix 2, 3, 7, 8, 9; note the rest (Recommended)"**, and for the first, **"The taker bounds them; document how (Recommended)"**: the done callbacks already let a taker count what is outstanding, and the docs show how, with a deadline for a client that stops reading. Weighed: the same without the ninth; all of 2–10; and for the first, an eighth verb giving what is outstanding, or the server closing a stream whose write waits past `write-timeout-ms`.

FIXED as decided, before the first commit, each in the step it belongs to: the ninth, `field-elements` shared, in the first; the third, the renderers, and the seventh and eighth on the fake transport, in the second; the second, a write counted once libuv has taken it, the eighth on the shell, and the first's docs, in the third. Red first: the headers suite did not load, with no `field-elements`; the message loop's and the outcome lane's hand-off raised in their renderers; the fake armed a deadline on a stream that had closed, and called no close call registered late; on the shell, a write refused off the loop's thread left the taker's close waiting, its stream open and a handle on the loop at the suite's end, and a close call registered late was never called.

M8.2 FIRST STEP: the switch, the transport and the 101 (feat/m8.2-switch).
- `src/http-server/switch.sls` (new): `switch-protocols`, what a handler answers to take an upgrade: the 101's fields and the take-over.
- `src/http-server/transport.sls` (new): the transport, a record of seven verbs, each checking what it is handed before its procedure is called; `make-transport`, with which a taker's tests make a fake.
- `src/http-server/serializer.sls`: `serialize-switch`, the 101: its status line, the switch's fields but Connection, `Connection: upgrade`, no Date and no framing; `switch-fault`, a response's field faults, a Connection that says anything but `upgrade`, and an Upgrade missing or naming a protocol the request's did not (RFC 9110 §7.8).
- `src/http-server/headers.sls`: `field-elements`, a field's list elements, which the serializer reads a switch's Upgrade with (the review's ninth).
- `tests/test-records.sps`: the switch read back, and the transport: each verb's shape, and its refusals, none reaching its procedure.
- `tests/test-serializer.sps`: a WebSocket's 101 on the wire, two segments, read back by chez-httparse's response parser; a handler's Connection not copied and its Date kept; a response not written as a 101; the switch's faults, nineteen rows.
- `tests/test-headers.sps`: `field-elements`, over a field's lines, trimmed, within a span's bounds.
- Records: decision 0016; the two spikes, their runs and the research README.

Measured on the step's tree (2026-10-03, Darwin arm64): `make test` green, forty-seven suites, 1,728 expected passes (1,689 + 39), every pin ok.

Watched to fail (m8-mutations.md, M8.2, the first step): thirty-three mutants on the step's tree, each loading and reddening a check; every one of the thirty-nine checks the step added reddened by one.

Size: src +263 −10; tests +210 −6.

NEXT: the second step, the core's door and the fake transport, stacked on this one.

M8.2 SECOND STEP: the core's door and the fake transport (feat/m8.2-door).
- `src/http-server/connection.sls`: the door. A switch answered for an HTTP/1.1 upgrade kept alive, with no body and no CONNECT, has its 101 written, the 100 first when the request expects it (RFC 9110 §7.8; W7), and once the 101 is written the core hands the stream over, `(hand-off take-over retained)`: the take-over, and the pending input the message's pause kept. Any other switch, or one with a fault, is answered 500, logged `invalid-response`. Handed off, the core asks for nothing more and ends `closed` at the stream's close; a 101 a read error cuts short closes, its take-over let go. The parser's own hand-off, never reached, is refused, and T7 retired.
- `tests/fake-shell.sls`: the fake transport: a write kept as the client reads it and its callback told on a later turn, or ECANCELED once the close has been asked for; reads routed to the taker, its end once; the close after the writes, then `closed` to the core and the close call, run at once when registered late; the deadline on the connection's wheel entry, none armed once closing; `fake-shell-drain!` and `fake-shell-armed`.
- `tests/test-connection-table.sps`: W1 to W7; the parser's hand-off refused; what the door lets go of; the counts.
- `tests/test-connection-switch.sps` (new): the hook's contract at every delivery size; the fake transport's verbs; the door closed, to a request that does not upgrade, HTTP/1.0, a CONNECT, one with a body, and a switch to a protocol not offered.
- `tests/test-message-loop.sps`, `tests/test-outcome-lane.sps`, `tests/outcome-lane.sls` and `tests/libhtp-lane.sls`: a hand-off rendered by the bytes it hands over (the review's third).
- Records: design §4.3's and §4.4's notes; decision 0006's amendment.

Measured on the step's tree (2026-10-03, Darwin arm64): `make test` green, forty-eight suites, 1,775 expected passes (1,728 + 47), every pin ok.

Watched to fail (m8-mutations.md, M8.2, the second step): forty-one mutants on the step's tree, plan §14's among them, each loading and reddening a check; every one of the thirty-seven checks the step added or changed by name, and each of the table's twenty instances, reddened by one.

Size: src +117 −26; tests +685 −34.

NEXT: the third step, the shell's transport and the facade, stacked on this one.

M8.2 THIRD STEP: the shell's transport and the facade (feat/m8.2-transport).
- `src/http-server/private/shell.sls`: the door's other side. When the core asks for the hand-off, the shell calls the switch's take-over with a transport over the connection and a copy of the bytes handed over. The connection stays in the table, so it counts against `max-connections`, and it closes through `handle-close!`.
  - A write is a `uv-write*!` of its own, counted once libuv has taken it (the review's second), and its callback is told when it completes. A write asked for once the close has been is cancelled, and its callback is told ECANCELED after the turn.
  - Reading restarts libuv's reads with the taker's callbacks, stopping a read already started.
  - The close waits for the writes still outstanding.
  - The deadline is the connection's one entry in the wheel.
  - The drain runs a taker's drain call once, at once if it is registered while the server drains, then waits for the close, which the drain's deadline forces.
  - The close tells the core, `closed`, then runs the close call, at once if it is registered later (the review's eighth).
  - Each call into the taker is guarded and what it returns is dropped; one that raises is logged `taker-failed` and its stream closed.
- `src/http-server.sls`: the facade exports `switch-protocols` and the transport's verbs, and `make-transport` for a taker's tests.
- `tests/test-shell.sps`, the door over real sockets:
  - through the door, with a frame sent with the handshake; later frames, and the client's end;
  - a taker that raises;
  - the close after the writes, among them a 4 MiB write still under way;
  - a write refused at the call, and one refused off the loop's thread;
  - reading stopped and started again, and restarted while it reads;
  - `max-connections` while a stream is taken;
  - the deadline, armed with the timer stopped, and disarmed;
  - the drain, with a taker that says goodbye, one that ignores it, a drain call registered twice, and one registered while the server drains;
  - a stream the server has closed.
- `tests/test-serve.sps`: the facade's exports, and a handler that takes an upgrade with the facade's names alone.
- Records:
  - design §4.6's and §8.4's notes;
  - decisions 0001's and 0005's notes;
  - plan §14's M8.2 note;
  - `docs/handlers.org`'s "Taking an upgrade", with how a taker bounds its writes (the review's first);
  - `docs/connections.org` and the README's status.

Measured on the finished tree (2026-10-03, Darwin arm64): `make test` green, forty-eight suites, 1,795 expected passes (1,775 + 20), every pin ok.

Watched to fail (m8-mutations.md, M8.2, the third step): ninety-seven mutants on the finished tree, the step's twenty-three and the first two steps' seventy-four, each loading and reddening a check. Every one of the ninety-seven checks the slice added or changed, by name, is reddened by one, and each of the table's twenty instances, as on the second step's tree.

Size: src +205 −10; tests +492 −13.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the finished tree made with `COPYFILE_DISABLE=1`, with curl, ab and python3 installed:
- `make test`, less its submodule and pin checks: forty-eight suites, 1,795 expected passes;
- the switch, shell and serve suites green three more times each: 23, 188 and 16.

M8.2 BUILT, the three steps proved each on its own tree (2026-10-03):
- the first, main at 70b7adf with its files: `make test` green, forty-seven suites and 1,728 expected passes; its thirty-three mutants there, 39 of 39 checks;
- the second, on the first: forty-eight suites, 1,775; its forty-one mutants there, 37 of 37 checks by name, and the table's twenty instances;
- the third, the finished tree: 1,795, on Darwin and on Linux; ninety-seven mutants, 97 of 97 checks.

Size, against main: src +585 −46; tests +1,387 −53; and the records.

NEXT: the three stacked PRs, as decided. They merge bottom up on the owner's "do closing ritual", once CI is green on each head. Then M8.3 (plan §14), the black-box and robustness lanes, when the owner asks.

NOTED on the owner's word (2026-10-03), once the three PRs were open. The owner asked "Did we make note of the other issues?": the review's four noted findings were in decision 0016 and this ledger only, two of them with no reason given. Then, on "Let's do that":
- `docs/handlers.org`'s "Taking an upgrade" now says that each `transport-write!` is a write of its own, so small pieces are best joined (the tenth). It also says that a `done` the server calls on its next turn, for a write asked for after the close or refused as it was asked for, never comes if the server stops first, so a taker frees what it holds in its close call (the sixth).
- Plan §14's "Open, and not sliced" lists all four.
- Decision 0016's noted paragraph says where they went, and what was measured.

Measured first, with a scratch probe, two identical runs, Darwin arm64. A taker whose close call writes; the server drained; the loop run as `serve` runs it:
- the late write's `done` was still uncalled when the loop returned, and was told ECANCELED a turn later;
- a write that completed had its `done` called inside libuv's callback, as the close call is.

Docs and records only, a second commit on #111: `make test` green, forty-eight suites, 1,795 expected passes.

MERGED to main on 2026-10-03, on the owner's "Do closing ritual": **M8.2, as three stacked PRs.**
- **#109, the switch, the transport and the 101,** as a5cac4c. Its squash tree (347434e) is the tested tip's, fb1099f's, and its parent is 70b7adf. It merged first and kept its branch, since #110 was based on it.
- **#110, the core's door,** as 8d1d0af. It was retargeted to main and rebased from #109's tip, fb1099f. The rebased tip, c8e75c9, has the tested tree (bebd13e, 47bcd02's), and so does the squash, whose parent is a5cac4c. It kept its branch, since #111 was based on it.
- **#111, the shell's transport and the facade,** as 20d8481. It was retargeted to main and rebased from #110's first tip, 47bcd02. The rebased tip, 82b86ca, has the tested tree (067f149, eb6648f's), and so does the squash, whose parent is 8d1d0af. Its two commits, the step and the review's noted findings, were squashed with one message.
- **CI.** Each merged on `linux` SUCCESS at its head: #109 on fb1099f (run 37145792279); #110 on c8e75c9 (run 37160194575); #111 on 82b86ca (run 37160285596). Each log holds its step's count: forty-seven suites and 1,728 expected passes, then forty-eight and 1,775, then 1,795.
- **Branches.** All three deleted, local and remote, and refs pruned. No PR is open.

`make test` green on main: forty-eight suites, 1,795 expected passes, every pin ok.

DONE and merged (a5cac4c, PR #109; 8d1d0af, PR #110; 20d8481, PR #111): **M8.2, the hand-off door.**
- A handler takes an upgrade by answering `(switch-protocols headers take-over)`. The server writes the 101, the 100 first when the request expects it. It then hands the stream over as a transport it keeps: in the table under `max-connections`, closed through `handle-close!`, its deadline the connection's entry in the wheel, its taker told of the drain, which waits for its close.
- Found and fixed on the way: a taker's call that returned no values crashed chez-libuv's callback; RFC 9110 §7.8's 100 before the 101; the parser's own hand-off row, never reached, retired.
- Decided by form: the server writes the 101; the transport, the server keeping the stream; tell it, then wait; upgrades only; review, then three stacked PRs; the review's 2, 3 and 7–9 fixed, the first documented (the taker bounds its writes), 4–6 and 10 noted, two of them in the docs and all four in plan §14's open list. A /code-review high found ten.

NEXT: M8.3 (plan §14), the black-box and robustness lanes, when the owner asks.

---

## M8.3 — the black-box and robustness lanes (started 2026-10-04)

Started on the owner's "Start m8.3", from main at 3ab1934. Plan §14 and design
§8.8: black-box clients against a port, and a robustness lane of libhtp's
invalid streams, smuggler's payloads and the AWS desync-guardian tables, each
vendored by decision 0007's rules, with brief risk 4 answered by the test
client.

**Measured first (scratch, the session scratchpad m83/).** Six surveyed corpora
were fetched at pinned commits and every case run through one fake connection,
whole and at size 1:
- AWS http-desync-guardian: 162 cases (the survey's "668" counted header rows),
  63 of them Severe; all 63 refused; 11 of 56 Ambiguous served, each valid by
  the RFCs (e.g. `Transfer_Encoding` with an underscore, an ordinary field).
- smuggler: 1,768 gadgets × 2 probes; all refused but 6 gadgets that are no
  Transfer-Encoding header (e.g. `Content-Encoding: chunked`). An RFC rule
  written apart from the parser predicted all 3,536.
- Kestrel's literal tables: 214 rows; 197 match Kestrel's verdict.
- httpd's `http_strict.t`: 80 request rows; 68 match its strict column.
- lighttpd's `request.t`: 151 blocks, 30 parser-level; 15 match.
- libhtp's 24 invalid streams: 15 refused, 9 served (valid requests).
Every outcome was chunk-size invariant. The measurement is in m83/measure/.

**Decided by form (2026-10-03), both recommended.**
- "Refuse with 505": a request with no version, or `HTTP/0.9`, is refused 505,
  `version-not-supported`, since the server speaks HTTP/1.1 and 1.0 only (RFC
  9110 §15.6.6; Go answers so). Prototyped against the gated lanes before the
  form: 6 of 4,167 cases change. HTTP/1.2 and 3.0 stay the parser's 400, as
  Node and hyper answer them.
- "curl and vtest2": the black-box lane (step 3) uses curl and vtest2 (the
  archived GitHub tag `last`, built with pcre2 and zlib), pinned by a decision
  record; hurl was dropped, since it reads responses through libcurl as curl
  does.

**Then, by a third form, smuggler was dropped from the slice** ("Drop it from
M8.3"): a safety classifier stopped the step that wrote its probe reader, so
`test/vendor/smuggler` was removed from the branch. guardian covers the same
Transfer-Encoding classes, and the measurement above stands as the record.

**Noted, not changed** (to plan §14's open list; the first also to
`docs/request-targets.org`): the parser refuses BWS in a chunk extension
(`a; comment`), which RFC 9110 §5.6.3 allows; `%00` and other percent-encoded
octets reach a handler undecoded (the server hands the target over as sent); a
lowercase method is 400, not 501; HTTP/1.2 and 3.0 are 400, not 505.

### The first step: the robustness lane, and HTTP/0.9 (feat/m8.3-smuggling)

Built in the working tree. New:
- `(http-server decisions)`: `version-not-supported . 505`, a tenth originated
  reason.
- `(http-server connection)`: `conn-headers-complete-step` refuses
  `version-not-supported` first, before the Host, when `http-major` is 0.
- `tests/provenance.sls`: a vendored corpus's bytes are the bytes we fetched
  (sha256 per file, both-way manifest, status 3 on drift), shared by any
  corpus `tests/vendor-corpus.sh` vendors.
- `tests/guardian-corpus.sls`: the YAML cases, read by a loader that refuses a
  shape it does not know, and each case's request built as guardian's harness
  builds it (both decoders, the raw request). Its requests are identical to a
  PyYAML rendering of all 162 (checked in scratch).
- `(robustness-lane)` and `tests/test-robustness-lane.sps`: three properties —
  the serve manifest both ways (which cases reach the handler is ours, from
  RFC 9112), the security property (no Severe case is in the manifest, so none
  is served), and chunk invariance.
- `test/vendor/http-desync-guardian/`: the corpus, with LICENSE, NOTICE and a
  PROVENANCE, vendored by `tests/vendor-corpus.sh` (a `corpus-refresh` arm,
  `GUARDIAN_ROOT=`).
- libhtp's 24 invalid streams and 4 HTTP/0.9 streams promoted in the ratchet,
  their expectations in `(libhtp-lane)`, found by name (plan §14 names them).

Found and recorded:
- The HTTP/0.9 rule changed two existing checks that encoded the old served
  behaviour, now the new 505: `test-connection-padding`'s "a request line with
  no version … 505", and `test-connection-cut-off`'s head's-end refusal, now
  the version before the target. The positive 0.9 checks live in
  `test-connection-head`, `-originated`, `-decisions` and the trace lane.

Measured on the tree (2026-10-04, Darwin arm64): `make test` green,
forty-nine suites, 1,843 expected passes (1,795 + the robustness lane's 13 and
the 0.9 and libhtp checks), every pin ok.

Watched to fail (m8-mutations.md, M8.3, the first step): seven mutants, each
loading and reddening its target checks, plus two witnessed by hand (a flipped
vendored byte → exit 3; a lenient loader). Every new or changed check is
reddened by one.

DECIDED on the owner's word (2026-10-04), by form, after a walkthrough: "Review
+ PR step 1 now": a review of this step, its fixes, and its own PR, then steps 2
and 3 the same way. Weighed: building all three before one review (M8.1's and
M8.2's way), and the two pure-Scheme lanes first with step 3 held.

REVIEWED (2026-10-04): a `/code-review high` found ten.
1. An HTTP/2.0 request line was served as 1.x: the parser reads one, and the
   rule refused only major 0, though its comment said every other version is
   the parser's. Probed: `GET / HTTP/2.0` answered 200; 1.9, 0.0 and 0.1 are
   the parser's 400. DECIDED on the owner's word, by form: "Refuse every
   non-1.x, 505" (weighed: "Keep serving HTTP/2.0", as httpd does). Prototyped
   first against the gated lanes, all green; 1 of 4,167 surveyed cases changes,
   httpd's `GET / HTTP/2.0` row, which httpd serves and Go answers 505. The rule
   is now `(not (fx=? http-major 1))`.
2. The user docs gave 505 for the preface only: `docs/responses.org` and
   `docs/connections.org` now name HTTP/0.9 and HTTP/2.0, and that 1.2 is 400.
3. The provenance walk failed on any unlisted file, so a Finder `.DS_Store` or
   an AppleDouble `._` file would end the suite with exit 3: the walk now
   leaves out every dotfile, the tree's own `.gitattributes` among them.
4. The YAML loader, which promises to refuse a shape it does not know, read on
   past two spaces after a key's colon (`GET  /x`, or `H:  "v"` with its
   quotes) and kept a plain scalar's ` # comment` as text: each is refused now.
   Probed first: all three were read so.
5. The records: decision 0006 is amended (a version not 1.x is 505), and plan
   §14's M8.3 section and design §8.8 have notes.
6. `tests/vendor-corpus.sh` named the robustness suite as every corpus's
   verifier: each arm names its own. Re-vendored, PROVENANCE byte-identical.
7. The PROVENANCE count was a `test-assert` on a boolean: a `test-eqv` now.
8. A comment credited 162 to the survey, which said 668: corrected.
9. The size scan ran every size always, re-implementing the corpus lanes': it
   takes `corpus-scan-sizes` and the CORPUS selection now, 324 runs by default
   (two a case), 24,279 under CORPUS=full, with a check of the schedule.
10. Two PROVENANCE checkers hold one contract (`tests/provenance.sls` and
   `tests/test-libhtp.sps`'s own): noted in plan §14's open list, on the
   owner's word ("Fix 2–9, note 10"), since merging them edits M1.3's suite.

Each fix's check was watched red first. Twelve mutants on the fixed tree (the
seven re-cut, five new), every one loading; one, M8R-P1, first reddened only
through the manifest's exit 3, so the dotfile check moved ahead of it
(m8-mutations.md, M8.3, the review).

Measured on the fixed tree (2026-10-04, Darwin arm64): `make test` green,
forty-nine suites, 1,848 expected passes (1,843 + the HTTP/2.0 check and four
of the robustness lane's), every pin ok.

NEXT: step 1's PR, as decided; then the strictness lane (Kestrel, httpd,
lighttpd), then the black-box lane (curl, vtest2), each its own PR, with a
decision record for vtest2.

### The second step: the strictness lane (feat/m8.3-strictness, on #112)

Stacked on #112, since it vendors through `tests/vendor-corpus.sh` and checks
provenance through `tests/provenance.sls`.

DECIDED on the owner's word (2026-10-04), by form, after measuring each rule on
the three corpora (refused-or-served class, the current core):
- "Complete them into heads": Kestrel and httpd send a bare request line and
  answer as they read it, where this server answers once a head ends, so a
  request that ends in CRLF and holds no empty line gets one CRLF more and its
  line is judged; the vendored bytes untouched. Measured: Kestrel 207/214 and
  httpd 68/77 agree that way, against 202/214 and 67/77 as sent, where 12 and 2
  cases end unanswered. Weighed: "Deliver as each source sends".
- "Its two HTTP sections": lighttpd's "Basic Request-Handling" and
  "keep-alive", 41 of request.t's 151 blocks, picked by the file's own
  headings; the rest test lighttpd's modules. Weighed: all 151 with the module
  sections deferred, and dropping lighttpd.

Found while building:
- Kestrel's `RequestLineInvalidData` appends every non-token method as an
  HTTP/1.0 line (`.Concat(MethodWithNonTokenCharData.Select(...))`): the
  scratch measurement scraped that interpolated string as a row (91, not 90)
  and missed the 24 lines it builds. Two more tables append (`MethodWith...`,
  `TargetWithNullCharData`). The reader reads each table's rows and its tail;
  the lane ports the three appends, with a check that each tail still reads as
  ported.
- httpd's harness reads an undef strict expectation as the lenient one (`$expect
  = $t->[1] if (! defined $expect)`): row 41's is 90, not undef. The reader
  does the same, checked on row 41.
- The suite's refusal check found httpd's reader taking any word in an
  expectation slot as a build condition: only the third value may be one now.

New:
- `tests/kestrel-corpus.sls`, `tests/httpd-corpus.sls`,
  `tests/lighttpd-corpus.sls`: each reads its vendored file as data, never
  compiled or run, refusing any shape it does not know. httpd's 88 rows and
  lighttpd's 41 blocks were checked in scratch against Perl's own reading of
  the files (the tables evaluated, the test run with a stub harness):
  identical. Kestrel's eleven tables read at the survey's counts.
- `(strictness-lane)` and `tests/test-strictness-lane.sps`: 355 cases (Kestrel
  237, httpd 77, lighttpd 41), each held to its source's refused-or-served
  verdict or to a listed departure, gated both ways (22 departures, ten
  reasons), and chunk-invariant at the corpus lanes' sizes.
- `test/vendor/kestrel/`, `test/vendor/httpd-tests/`, `test/vendor/lighttpd/`,
  vendored by `tests/vendor-corpus.sh` (`KESTREL_ROOT=`, `HTTPD_TESTS_ROOT=`,
  `LIGHTTPD_ROOT=`).

Measured on the tree (2026-10-04, Darwin arm64): `make test` green, fifty
suites, 1,863 expected passes (1,848 + the strictness lane's 15). The lane runs
709 deliveries by default and 14,420 under CORPUS=full, in about 0.6 s.

Watched to fail (m8-mutations.md, M8.3, the second step): fifteen mutants,
every one loading and reddening the strictness suite alone; one, M8S-L1, first
missed the end-to-end check, which moved to a three-line block.


REVIEWED (2026-10-04): a `/code-review high` of the second step found ten.
DECIDED on the owner's word, by form: "Fix all ten" (weighed: fixing 1-4, 6
and 7 and noting 8-10; fixing 1-4 only).
1. A listed departure was held only to differ from its source's verdict, so it
   could move to a third outcome unnoticed (httpd row 50, unanswered, could have
   become served). Each departure now carries this server's own verdict, which
   the lane holds it to; a check lists row 50 with a verdict it does not give and
   reads a mismatch.
2. `tests/vendor-corpus.sh` removed the vendored corpus before listing the
   checkout's files: a checkout missing one (a sparse one, a wrong root) left the
   corpus deleted. Witnessed by hand in a scratch copy (exit 1, the directory
   emptied); it now lists and checks every file first (exit 2, named, the corpus
   as it was), and a good checkout still vendors byte-identically.
3. Completion touched header sections ended by CRLF too, and the form's figures
   were measured on a scraped reading of Kestrel's tables (one table's appended
   rows missed). Only a bare request line, one line ended by CRLF, is completed
   now, as the decision says: 136 of Kestrel's cases, 2 of httpd's. Agreement, the
   lane's own: Kestrel 230 of 237, httpd 70 of 79, lighttpd 35 of 41.
4. httpd's two rows gated on its version (`$test_underscore`, a fix level), whose
   expectation holds for any server, were left out with the one gated on a module:
   only `have_module` rows are left out now, and both rows agree (79 cases).
5. lighttpd's statuses outside the refusal list count as served: a 500 or 502 is
   the server's answer to a request it accepted, as this server's handler accepts
   it. The comment says so now; nothing else changed.
6. Kestrel's reader would have taken the next table's rows for one whose array
   opens on its constructor's line: it refuses that now, checked on a snippet.
7. A Kestrel row past ASCII ended the suite with a harness error: the reader
   refuses it by name now, checked on a snippet.
8. Each reader re-read its file at every call: each reads it once a process.
9. Six copies of the same string helpers: one library, `(corpus-text)`, which the
   five readers and `(provenance)` import.
10. The two lanes repeated the delivery schedule and its loop: one library,
   `(corpus-scan)` (the selection, the sizes, the invariance check), which both
   lanes and both suites use.

Each behaviour fix's check was watched red first (1, 3, 4, 6, 7); 2 by hand.

Found by the mutants' re-run: the strictness suite verified provenance inside a
check's expression, so a provenance failure ended it with exit 1, not 3; it is
verified outside the check now, as the robustness suite does.

Measured on the fixed tree (2026-10-04, Darwin arm64): `make test` green, fifty
suites, 1,865 expected passes (the strictness lane's 17: the departure-verdict
and the Kestrel snippets' checks added). The lane: 357 cases, 713 deliveries by
default, 14,467 under CORPUS=full.

Watched to fail (m8-mutations.md, M8.3, the second step's review): thirty-three
mutants on the fixed tree, every one loading and reddening a suite; one,
M8R-P1, gave the strictness suite exit 1, which found the defect above.

NEXT: step 2's PR, stacked on #112, as decided; then the black-box lane (curl,
vtest2), with a decision record for vtest2.

### The third step: the black-box lane (feat/m8.3-blackbox, on #113)

Stacked on #113, as the steps go. Built on the owner's form ("curl and vtest2"),
measured first (scratch, the session scratchpad m83/co and m83/vtc):
- vtest2 is the archived GitHub mirror, vtest/VTest2, tag `last`, 803dcd0
  (2026-02-17); development moved to code.vinyl-cache.org. It builds with a C
  compiler, pcre2 and zlib, python3 and awk generating two headers, under
  `-Werror`: Darwin arm64 in 5.9 s; Ubuntu 24.04 amd64 (gcc 13.3.0, the CI
  image's release, under emulation) in 25 s, no warning.
- vtest exits 2 alike for a failed expectation and a script it cannot read;
  its log's `----` lines name the failure; `vtest -h` exits 1.
- curl's own ways (8.7.1 here): `--http2` sends the h2c upgrade, served over
  HTTP/1.1, then closed; `--http2-prior-knowledge` fails at once on the 505
  (exit 16 here; the check reads only that it fails, since the code is
  curl's); `-g -L` follows the bracket redirect once.

New:
- Decision 0017: vtest2 a submodule at `last`, built out of its tree into
  `build/vtest` by `make vtest` (stamp `build/vtest.pin`), `make test` building
  it first; CI caches it keyed on the gitlink, the OS release and the arch.
- `tests/vtc/`: twelve scripts, written from RFC 9112 and the decisions before
  they first ran. Eleven passed at once; the twelfth, `timeouts.vtc`, waited
  out vtest's 30 s, since the lane's server set its timeouts as milliseconds
  where `CHEZ_HTTP_*_TIMEOUT` reads seconds (docs/configuration.org): the
  harness's fault, not the server's.
- `tests/test-clients.sps`: the lane, a server of its own on a loop of its own
  (deadlines 1 s, bodies capped at 1 KiB), each script held to a manifest both
  ways, the table emptied, the server's log and its loop read after a drain;
  and five curl checks (`--http2`, `--http2-prior-knowledge`, `-g -L`,
  `OPTIONS *`, `--path-as-is`).
- README.org: the test tools among the prerequisites.

Brief risk 4 was answered in M6.3 and is recorded now:
`tests/test-shell.sps` reads a streamed body close-delimited to HTTP/1.0 over
a real socket with `(response-reader)`, which finishes the read the close ends
with `parser-finish!`; M8B-P1, no finish, reddens it. vtest reads one with its
own code (`stream.vtc` c2).

Found while building:
- vtest stops a script at its first failure, so each client got a mutant of
  its own (`framing.vtc` c2, the parser's duplicate Content-Length, with M8B-F2).
- M8B-D1 found `head.vtc` blind to a HEAD answered with content: the GET after
  it checked its body, not its status, and vtest read the stray body as the
  status line. Every `rxresp` is now followed by a status check (37).

Measured on the tree (2026-10-04, Darwin arm64): `make test` green, fifty
suites, 1,875 expected passes (1,865 + the clients suite's ten: the lane's five
and curl's five), every pin ok, vtest2's among them, in 41 s; the clients suite
in 6.3 s, timed before its log check was added (28 checks then).

Watched to fail (m8-mutations.md, M8.3, the third step): thirty-four mutants,
every one loading and reddening its check; three behaviours by hand (the
stamp, the pin check, a missing vtest).

REVIEWED (2026-10-04): a `/code-review high` of the third step found ten.
DECIDED on the owner's word, by form, after a walkthrough of the step against the
plan: "Fix all ten" (weighed: fixing 1–7 and noting 8–10; fixing 1–5 and noting
the rest), and "Three stacked PRs" (weighed: two; one).
1. The Makefile named its binary VTEST, the name the suite reads for another
   build: `make vtest VTEST=path` copied ours over the user's file there
   (witnessed in scratch), and `VTEST=path make test` was overridden unseen. The
   binary is VTEST_BIN now; both ways reach the suite, and nothing is written.
2. The `--http2-prior-knowledge` check held only that curl failed, so a curl
   without HTTP/2, or a server closing unanswered, passed it; curl's trace never
   shows what its HTTP/2 layer read (measured), so no check of curl's can see
   the 505. Dropped: `version.vtc` c3 reads it. Four curl checks remain.
3. `make vtest` built from `git archive` through a pipe: a tree without its
   `.git` (the Linux run in Docker) could not build it, and bsdtar took git's
   failure for an empty archive (the pipe exited 0). `tests/build-vtest.sh`
   builds it now: from the git store, else the files as they stand, saying so.
4. `make -n` ran the build's `rm -rf`, its line holding `$(MAKE)` (45 objects
   deleted, exit 2). The script runs it now, so a dry run only prints it.
5. vtest had no test timeout, so a hung script waited for the suite's cap and
   twelve would outlast its 120 s. It gives each 5 s now (`-t 5`), and a killed
   script's verdict reads "TIMED OUT"; M8B-O3 ends with vtest's own verdict.
6. The two rules the verdicts rest on, each rxresp checked for its status and
   each client run, were held by nothing: a reader of the scripts' text holds
   them, checked on a snippet.
7. An editor's lock file (`.#name.vtc`) would have been taken for a script:
   dotfiles are left out, checked.
8. `make test` waited on a build only POSIX systems make: it tries the build and
   runs on, so where vtest does not build only the clients suite fails, by name
   (witnessed with `CC=false`).
9. The records: M8B-H2's row miscounted, 0017's and the suite's timings were
   underived, and head.vtc's comment named the wrong mechanism. Re-measured
   (the twelve take 3.22 s) and corrected.
10. `vtc-file?` re-implemented `(corpus-text)`'s `suffix?`, and `vtc-handler`
   copied the clients' handler: it hands it all but a POST now.

Each new check was watched red first, the rules' reader and the dotfile rule
on a stub; the verdict reader, added after the re-run showed no mutant reaches
its TIMED OUT, by M8B-S11 and S12; 1, 3, 4 and 8 by hand.

Measured on the fixed tree (2026-10-04, Darwin arm64): `make test` green, fifty
suites, 1,878 expected passes (1,865 + the clients suite's thirteen: the lane's
nine and curl's four), every pin ok, in 40.65 s; the clients suite 31 checks in
5.97 s, before the verdict reader's check made 32.

Watched to fail (m8-mutations.md, M8.3, the third step's review): forty-one
mutants on the fixed tree, every one loading and reddening its check.

Found by the layers' proof in a scratch worktree: `tests/build-vtest.sh` wrote
its archive with `git -C DIR archive -o build/vtest2.tar`, a path git took inside
the submodule, so a tree with no binary yet could not build vtest ("could not
open 'build/vtest2.tar' for writing"). This checkout never reached that line,
its stamp matching, and the copy without `.git` was built with absolute paths.
The archive is written through the shell now, and `make vtest` from no binary
builds it; the second layer's clients suite had named the missing vtest, as
the eighth fix has it.

NEXT: the three PRs, stacked on #113, as decided: the pin and build, the vtest
lane, then curl's checks and the step's records, each proved green alone in a
scratch worktree first.

MERGED to main on 2026-10-04, on the owner's "do closing ritual": **M8.3, as five stacked PRs.**
- **#112, the robustness lane and the version rule,** as 88cdc07. Its squash tree is the tested tip's, 8185355's, and its parent is 3ab1934. It merged first and kept its branch, since #113 was based on it.
- **#113, the strictness lane,** as 375e2e4. It was retargeted to main and rebased from #112's tip, 8185355. The rebased tip, 1d15943, has the tested tree (e4cbabc's), and so does the squash, whose parent is 88cdc07. It kept its branch, since #114 was based on it.
- **#114, vtest2 pinned and built,** as 064db95. It was retargeted to main and rebased from #113's first tip, e4cbabc. The rebased tip, 0afcdb4, has the tested tree (0673d32's), and so does the squash, whose parent is 375e2e4. It kept its branch, since #115 was based on it.
- **#115, the vtest lane,** as 1f74086. It was retargeted to main and rebased from #114's first tip, 0673d32. The rebased tip, 78f2720, has the tested tree (cd53f18's), and so does the squash, whose parent is 064db95. It kept its branch, since #116 was based on it.
- **#116, curl's own ways and the step's records,** as 9df037f. It was retargeted to main and rebased from #115's first tip, cd53f18. The rebased tip, c0b3871, has the tested tree (0c13def's), and so does the squash, whose parent is 1f74086.
- **CI.** Each merged on `linux` SUCCESS at its head: #112 on 8185355 (run 37169875089); #113 on 1d15943 (run 37202921918); #114 on 0afcdb4 (run 37203043893); #115 on 78f2720 (run 37203170626); #116 on c0b3871 (run 37203289322). Each log holds its step's count: forty-nine suites and 1,848 expected passes, then fifty and 1,865, 1,865, 1,874 and 1,878. vtest2 built on CI in 5 to 7 s.
- **Branches.** All five deleted, local and remote, and refs pruned. No PR is open.

`make test` green on main: fifty suites, 1,878 expected passes, every pin ok, vtest2's among them.

DONE and merged (88cdc07, PR #112; 375e2e4, PR #113; 064db95, PR #114; 1f74086, PR #115; 9df037f, PR #116): **M8.3, the black-box and robustness lanes.**
- The robustness lane holds AWS http-desync-guardian's 162 cases to a serve manifest written from RFC 9112, gated both ways, with no Severe case served; libhtp's 24 invalid and 4 HTTP/0.9 streams joined the ratchet. A version that is not 1.x is answered 505 (decision 0006's amendment of 2026-10-04).
- The strictness lane holds Kestrel's, httpd's and lighttpd's strict request tests, 357 cases, to their sources' refused-or-served verdicts or to 22 departures pinned to this server's own.
- The black-box lane runs vtest2's twelve scripts against a server of its own (decision 0017: vtest2 a submodule at the archived mirror's `last`, built by `make vtest`) beside curl and ab, and brief risk 4 is recorded as answered since M6.3.
- Decided by form: HTTP/0.9, then every non-1.x version, refused 505; curl and vtest2; smuggler dropped; each step reviewed and its own PR(s); the reviews' findings fixed (step 1's tenth noted), Kestrel's bare lines completed into heads, lighttpd's two HTTP sections, and step 3 as three stacked PRs. Three /code-review high passes found ten each.

NEXT: M8.4 (plan §14), load and the release, when the owner asks.

## M8.4 — load, and the release (started 2026-10-04)

Started on the owner's "Start m8.4", from main at 28e0d77, on feat/m8.4-load. Plan §14:
- oha's load smoke gives the first throughput numbers, where decision 0002's amendment
  says a goal can first be set and 0004 item 3's alternative can be weighed;
- the memory at `max-connections` is re-measured;
- `CHANGELOG.md` gains v0.1.0, then the tag.

All measured 2026-10-04 on an Apple M1, 8 cores and 16 GB: Darwin 25.6.0 arm64 (macOS
26.6.2), and Linux 6.12.76-linuxkit aarch64 in Docker's `chez-libuv-valgrind:10.4.1`
image (698eba6; Debian 12, libuv 1.44.2) on the same machine. oha 1.16.0, its release
binary. A macOS Bluetooth daemon, BTLEServer, used about one core whenever it was
checked, from before the first Darwin run to after the last.

**Measured first, for the form (scratch, the session scratchpad m84/).**
- oha against `tests/serve-child.sps` beside Node's http, kept alive, three rounds
  alternating: Darwin 11.2–11.3 thousand a second at one connection and 31.1–34.3 at 10
  to 500, against Node 20.10's 11.2–11.3 and 32.3–37.2; Linux 14.2–14.7 and 62.3–88.0,
  against Node 18.20's 14.1–14.4 and 41.7–61.2. Every request answered 200.
- 10,000 idle connections held 195–202 MB on Darwin, 199–205 MB on Linux.
- A shell never stopping reading made no difference beyond the runs' spread.
- The smoke in the clients suite: 1.2 to 1.3 s more a run; the plan's mutation reddened
  both runs, oha counting 19,980 answered and 20 timeouts.
- oha's binaries 10.3 to 13.4 MB, each with the sha256 GitHub records for it; built
  from source with `cargo install --locked`, 133 s (440 s of CPU), 225 crates, 304 MB
  downloaded, Rust 1.88 or later.

**DECIDED on the owner's word (2026-10-04), by one form, the recommended option each
time:**
- "Pinned binary, checked": oha is v1.16.0's release binary, fetched by `make oha` and
  kept only at its pinned sha256, decision 0018. Weighed: built from source as vtest2
  is, and oha on `PATH` as curl and ab are.
- "No goal; record a baseline": v0.1.0 sets no throughput goal, and CHANGELOG.md
  records the numbers with their platforms. The 3 KiB gate stays a ratchet, as decision
  0002's amendment of 2026-10-04 records. Weighed: within 15% of Node's http, checked by
  hand per release; a floor in CI.
- "Annotated tag only": v0.1.0 is an annotated tag, as chez-libuv, chez-httparse and
  byte-machine tag, pushed at the closing ritual. Weighed: a GitHub release too, as
  uriparse makes.

**Built** (no source under `src/` changes):
- `tests/fetch-oha.sh` and `make oha`. The script pins the version and the four
  binaries' sums, for macOS and Linux on amd64 and arm64. `make test` fetches oha
  unless `OHA` names one, and runs on where it cannot: the clients suite then names
  it, status 2. CI fetches it in a step of its own.
- `tests/test-clients.sps`, the load smoke: a reader of oha's JSON report, checked on a
  snippet; 20,000 GETs on 50 kept-alive connections, then 2,000 on a connection each,
  each held to every request answered 200 and none failed; each run's rate, printed and
  not checked.
- Records: decision 0018; 0002's amendment and 0004's note; design §7.5's and §8.8's
  notes; plan §14's note; `docs/configuration.org`'s memory figure; README.org's status
  and prerequisites; CHANGELOG.md's v0.1.0.
- The spikes, with their runs under `out/`.

**The review.** A /code-review high found ten. By a second form the owner chose "Fix
all ten" and "One PR now". Fixed:
1. The records blamed the no-keep-alive failures on client ports without measuring:
   measured, below.
2. CHANGELOG gave the gate's 1,840 B as what a request allocates: the whole server's is
   measured, below, and both are given.
3. Two stalled oha runs, each waiting out the 60,000-turn cap, would outlast the
   suite's 120 s: the cap is 25,000, four and a half times the most measured.
4. An empty `OHA` or `VTEST` named no client in the Makefile and "" in the suite: the
   suite takes it as unset too, checked.
5. Every fetch wrote the one file `oha.part`, so fetches at once interfered: each
   writes a file of its own. Witnessed before the fix, four at once, three trials: one
   fetched and three failed each time.
6. With no sum tool the fetch reported a mismatch: `tests/sha256.sh` names the missing
   tool, before anything is fetched.
7. The sha256 helper was in three places: `tests/sha256.sh` is the one, for the fetch,
   `tests/vendor-corpus.sh` and the Makefile's corpus-refresh. It reproduces all 123
   vendored sums, and the vendoring stops before touching a corpus when no tool is
   there.
8. The spikes repeated their CPU reader and summary: `m8-load-common.sh` holds them.
9. The Makefile's header implied a `*_PIN` line for oha: it names the script.
10. The smoke checked no bytes: each run's bodies must come to 4 bytes a request.

**Measured on the fixed tree, the committed spikes, for the records** (the outputs under
`out/`):
- **Throughput** (`m8-load.sh`, two runs of three rounds). In thousands a second, at 1,
  10, 50, 100 and 500 connections:
  - Darwin: 9.9–10.5, 31.3–32.8, 32.8–34.0, 32.6–34.0 and 23.7–31.5, against Node
    20.10's 10.3–10.7, 34.0–35.5, 35.4–36.1, 34.4–36.1 and 31.1–32.0. Round by round,
    level at one connection and 2% to 10% under at 10 or more, one round at 500 aside,
    25% under.
  - Linux: 14.0–14.4, 61.5–64.4, 82.8–86.8, 78.3–88.0 and 62.4–72.8, against Node
    18.20's 14.1–14.4, 53.6–55.6, 50.9–60.4, 50.6–55.9 and 43.8–46.8. Level at one, 12%
    to 66% over at 10 or more.
  - Server CPU a request at 10 connections or more: Darwin 28.4 to 31.6 µs, Linux 11.4
    to 16.2. At 50 connections the median latency was 1.1 to 1.7 ms on Darwin and 0.55
    to 0.58 on Linux, the 99th percentile 2.2 to 2.6 and 0.71 to 0.81.
  - Every request was answered 200, none failed.
- **Allocation through the whole server** (`m8-request-alloc.sps`, two rounds): 10,431
  to 10,434 B a GET at one connection, and 8,895 to 8,902 B at 50, on both platforms.
- **Without keep-alive** (`m8-no-keepalive.sh`, Darwin, two rounds, each run waiting
  for the last's TIME_WAITs to clear): every one of 20,000 was answered at 10, 100 and
  500 connections, with no listen-queue overflow. Each run left 5,587 to 5,873 of oha's
  ports in TIME_WAIT, and up to 16,355 of the server's. The first matrix ran its runs
  back to back: three of them pass macOS's 16,384 ports, held 30 s, which is what its
  failures at 100 and 500 were.
- **The read-stop A/B** (`m8-read-stop.sh`, four rounds): never stopping saved 0.6 to
  1.0 µs a request at 10 connections on Linux, 4% to 6%, and 0.2 to 0.8 µs at 10 and 50
  on Darwin, up to 3%; at one connection, and at 50 on Linux, the two overlap (0004's
  note has the table). The Linux run's `HEAD` is the container's own commit of the
  tree's src and tests.
- **Memory at `max-connections`** (`m8-max-connections.sps`, before the review, the
  server's code unchanged since): the heap grew 1,949 to 1,950 B a connection on Darwin
  and 1,945 to 1,947 on Linux, the resident set 20,020 to 20,206 B and 19,860 to 19,875,
  199 to 202 MB in all.
- **Set aside:** a first Darwin load run, which read lower for both servers, and the
  load, read-stop and allocation runs made while a witness of the fixes ran beside them,
  each run again alone.

`make test` on the fixed tree, Darwin arm64: fifty suites, 1,882 expected passes
(1,878 + the clients suite's four), every pin ok, in 42.97 s. On Linux in Docker, less
its submodule and pin checks: fifty suites, 1,882, and the clients suite 36 twice more.

Watched to fail (m8-mutations.md, M8.4): seven mutants on the fixed tree, each loading
and reddening its checks. Plan §14's mutation, a write in a thousand dropped, reddens
both runs, oha counting 19,980 answered and 20 timeouts of the 20,000. An empty body in
a thousand reddens them by the bodies' bytes alone. The fetch script's paths, the shared
sum and `make test`'s were witnessed by hand.

NEXT: the PR, on the owner's "One PR now".

MERGED to main on 2026-10-04, on the owner's "do closing ritual": **M8.4, as one PR.**
- **#117, the load smoke, the first throughput numbers and v0.1.0's CHANGELOG,** as fa9e745. Its squash tree is the tested tip's, 9737119's, and its parent is 28e0d77.
- **CI.** It merged on `linux` SUCCESS at its head (run 37210696001), whose log holds fifty suites and 1,882 expected passes, as local. There, on GitHub's ubuntu-24.04 runner, `make oha` fetched and checked the amd64 binary, and the smoke's in-process server took 34,011 requests a second kept alive and 6,441 a connection each. Main's own run on fa9e745 (37215807182) was green too, fifty suites and 1,882.
- **Branch.** Deleted, local and remote, and refs pruned. No PR is open.
- **The tag.** On the owner's word, by form ("Tag once main's run is green"): `v0.1.0`, an annotated tag (4e17b91) on fa9e745, pushed once main's run was green.

`make test` green on main: fifty suites, 1,882 expected passes, every pin ok.

DONE and merged (fa9e745, PR #117), and tagged `v0.1.0`: **M8.4, load and the release.**
- oha's load smoke is in the clients suite: 20,000 GETs kept alive and 2,000 on a connection each, every one answered 200 with its body, none failed. oha is its release binary, fetched by `make oha` and kept at its pinned sha256 (decision 0018).
- The first throughput numbers, measured beside Node's http on an Apple M1, are v0.1.0's baseline, with no throughput goal (decision 0002's amendment). 0004 item 3's alternative was weighed and left unbuilt (0004's note). 10,000 idle connections hold about 200 MB, and a request allocates about 10.4 KB through the whole server.
- CHANGELOG.md has v0.1.0, with the numbers and the platforms they were measured on.
- Decided by form: the pinned binary, no goal, an annotated tag only; the review's ten fixed and one PR; the tag once main's run was green.

**M8 COMPLETE**, and with it the brief's milestones, M0 to M8: v0.1.0 is tagged with the measured numbers in CHANGELOG.md.

NEXT: plan §14's open list, or a new milestone, when the owner asks.

