# chez-http-server — ledger archive: M4, the libuv shell and the first real server

M4's entries, moved verbatim from `progress.md` on 2026-10-05 (its lines 1759–2294 at 64761cb). The mutation log is `m4-mutations.md`; the spine is `progress.md`.

---

M4 — THE LIBUV SHELL AND THE FIRST REAL SERVER (plan §8). Branch feat/m4-libuv-shell, cut from main at 76d5a13; 2026-09-26, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. Mutation log: m4-mutations.md, new.

Gathered before the first test, from plan §8 and this ledger:
- plan §8's four slices:
  - M4.1, the adapter's check;
  - M4.2, the shell: close ownership, the depth counter, the two hazards, and two checks carried in: M3.3's retention check, and the staged close's shell half;
  - M4.3, the listener and `server-step`, with `max-connections` and `backlog` (plan §3);
  - M4.4, the contract test and the socket lane, with the upload past a refusal (decision 0011);
- the exit:
  - curl and ab get correct responses, and the counters return to zero;
  - the contract test passes;
  - the connection table is reconciled against `uv-loop-live-handles` at one place in the run loop;
  - the per-connection budget is re-measured;
  - and the amendment slicing M5–M8 is written (plan §10);
- left to M4 by earlier slices:
  - what handlers see (M2.2);
  - absolute-form's host (RFC 9112 §3.2.2), an empty Host on origin-form, and whether to serve `ftp:///x` (M2.3);
  - a facade that builds limits must refuse a pipeline cap other than 1 (M2.4);
  - how the shell reports a cancelled write (M3.3);
  - a tracing hook (M2.2, from 0002's third amendment).

Found: no slice holds the facade, `(http-server)` (decision 0001's layout), and the exit needs it, since curl and ab need a server to run. It is M4.5, re-planned here (brief risk 6), after M4.4. What handlers see and the host rules land with it. Two of its questions are the owner's, measured first (below).

MEASURED, for what handlers see: `research/spike/m4-handler-view.sps`, new (`out/m4-handler-view.run{1,2}.txt`, identical, exit 0). It measures the bytes a view adds per request, on top of parser, adapter and core. Three views:
- (A), the spans read through accessors that copy what is asked: the path and one header's value;
- (B), every request copied to strings before the handler runs;
- (C), the spans alone.

| request | (A) | (B) | (C) |
|---|---|---|---|
| curl's GET, 3 fields | 80 | 416 | 0 |
| a JSON POST, 5 fields | 96 | 720 | 0 |
| a browser's GET, 11 fields | 192 | 1,872 | 0 |

The JSON POST costs 2,384 B through the core (the M3 exit), so (B) would put it at 3,104 B, over the 3,072 B ratchet it is gated at.

DECIDED on the owner's word (2026-09-26), by form, the recommended answers; recorded as decision 0012:
- **A handler reads the request through accessors that copy what it asks for**: the path, the query, a header's value and the host, as strings, and the method as llhttp's symbol. The host follows RFC 9112 §3.2.2: an absolute-form target's authority, whatever Host says.
- **The server listens where `CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT` say**, defaulting to 127.0.0.1 and 8080.

The alternatives weighed:
- for the view: every request copied to strings first, or the spans alone;
- for the address: the same variables defaulting to 0.0.0.0, or the platforms' `PORT` beside `CHEZ_HTTP_HOST`.

Read as the owner's choice, and flagged: an empty Host on origin-form is served, and reads empty, since v1 has no configured default (RFC 9112 §3.3 allows either). A target of another scheme, such as `ftp:`, is the handler's routing.

M4.1 — A CONNECTION'S PARSER SHARES ONE BINDING LIST. The adapter came in M2.2, so M4.1 is its check.
- `tests/test-connection-allocation.sps`: "a connection's parser costs what one on a binding list made once does". Byte-machine's `make-parser` is measured on a list of twenty-five bindings made once, before either is measured, beside `make-conn-parser`: 1,056 B each. Design §7.5 had 1,072 B, at the pins of 2026-09-19.
- Watched to fail (m4-mutations.md): M4.1-A, the plan's mutation, builds the list per connection. It turns only that check red: 2,640 B against 1,056 B, so a list per connection costs 1,584 B more. §7.5's 1,216 B was a plain list, and the adapter's bindings are closures.
- The tracing hook is the shell's, not the adapter's. Parser callbacks reach the core directly, and the actions they queue are traced where the shell runs them, which is what M4.4's contract test compares. No consumer needs the parser events themselves.

M4.2 FIRST STEP — THE SHELL SERVES A CONNECTION.
- `src/http-server/private/shell.sls`, `(http-server private shell)`, new:
  - a shell holds what a loop's connections share: the handler, the limits, the clock, the Date line, the log, an optional trace, and the connection table;
  - `shell-adopt!` serves an accepted TCP handle: the core in idle, a parser of its own, Nagle's algorithm off, and reading started with the limits' buffer;
  - the message loop is the fake shell's: one queue, drained after the outermost dispatch, with the depth counter around `parser-feed!` and the drain, and an action run anywhere else recorded as a violation.
- The actions, as the shell performs them:
  - `write` is one `uv-write*!`, its Date slot filled. Its completion keeps the write's byte count and nothing else;
  - `shutdown` is `uv-shutdown!`, reporting `shutdown-completed`;
  - `read-stop` and `read-start` change reading only when it is not already what they ask. The first start fixes the buffer at the limits' size;
  - `close` is `connection-close!`, the one `uv-close!` call. The handle's close takes the connection out of the table and reports `closed`;
  - a handler's raise is logged and delivered as `handler-failed`;
  - deadlines are recorded and not acted on: the wheel is M5's.
- The Date is made once a second (decision 0010). The shell's clock, milliseconds since the epoch, is read when a second of the loop's own time has passed. That time is libuv's cached `uv-now`, which costs nothing to read, where the wall clock costs 48 B a reading (measured 2026-09-26). Between readings the second is the last reading plus the loop's time since.
- `tests/test-shell.sps`, new, in chez-libuv's `test-echo.sps` shape (design §8.5):
  - clients on the same loop, and a listener of the suite's own on 127.0.0.1:0, made inside the suite so a failure there is the harness's status 2;
  - every wait capped by an iteration count;
  - responses read back by chez-httparse's response parser, and the Date from RFC 9110 §5.6.7's example instant.
- What it checks:
  - a GET is answered, dated by the shell's clock, and the connection stays open;
  - three requests in one write are answered in order, reading the clock fewer times than they are answered, with no action run from anywhere but the outermost drain (design §6.4's second hazard, against the real shell);
  - the staged close's shell half: the client reads the response, then the stream's end; the connection lingers, reading, while the client holds its end open; it closes and leaves the table when the client closes; its verbs run write, shutdown, read-start, close;
  - a handler that raises is answered 500, and what it raised is logged;
  - M3.3's retention check against the real write executor. The client does not read a four-MiB response, and the connection's send buffer is asked to be small, so the write stays outstanding: chez-libuv's write-queue gauge says so before the collection. Then nothing holds the response's body;
  - at the end, every connection accepted and closed, no handle on the loop, and, where chez-libuv's dev counters are on, no TCP handle, read buffer or write request.
- `tests/test-exports.sps`, new: no library outside `private/` exports a `uv-` name, read by Chez's own `library-exports` (design §7.6, decision 0003). The facade joins its list once `src/http-server.sls` exists.
- `make check-close-ownership`, new, a prerequisite of `make test`:
  - it names every uncommented use of the name `uv-close!` in `src/` (a call, an alias, an argument to `apply`) with the definition it sits in;
  - it requires exactly one use, in `connection-close!`;
  - it needs ripgrep, which CI now installs, and without it fails by name.
- The library path gains chez-libuv's `tests/`, test-only, for `(uv-testing)`: its iteration-capped waits and loopback plumbing, used rather than copied.
- `make check-imports` now also refuses a test library, `(uv-testing)` or `(httparse test ...)`, anywhere under `src/`. Its note has said since M1.1 that it kept the harness out of shipped libraries, and until now it did not.
- Red before green: the shell suite stopped at load before the shell existed (exit 255, library not found).
- Watched to fail (m4-mutations.md):
  - M4.2-H, the queue drained inside the parser callback: the violation check, and the pipelined answers with it;
  - M4.2-R, the completion keeping the segments: the retention check alone;
  - M4.2-S, no half-close: the stream's-end checks;
  - M4.2-L, no reading while lingering: the close and everything after it;
  - M4.2-T, the table not updated at the close: its check;
  - M4.2-D, the Date one second off: its check;
  - M4.2-K, the clock read for every response: its check;
  - M4.2-G, a handler's raise not logged: its check;
  - M4.2-E, a `uv-` export: the export check, every other suite green;
  - B1–B5, the plan's Mutation B and four more: a second `uv-close!` caller, a second call, the call moved into a helper, an alias, and `apply`. Each turns the gate red, naming each use. With B1 the suites stay green, so the gate is the test.
- Survives, a scope statement (M4.2-N): Nagle's algorithm left on. chez-libuv has no getter for `TCP_NODELAY`, and what it changes is time on a link with a round trip. On loopback no stall shows either way (`research/spike/m4-nodelay.sps` on Darwin, `m4-nodelay.pl` in Docker's Linux; both twice).
- Found and fixed: the Makefile's header still named the old pins (chez-httparse v0.4.1, uriparse v0.6.0, byte-machine v0.6.0), which #44 moved without it. It now points at the `*_PIN` lines.
- A review before the first commit found fourteen things, all fixed on the owner's word. Its record is with the second step, since its fixes fall in both.
- Every suite green in a scratch worktree with only this step, cut from main at 76d5a13: twenty-nine suites, 736 expected passes (connection-allocation 19, shell 27, exports 2), each exit 0. `make check-imports` and `make check-close-ownership` are clean there, and the step's mutants ran there (m4-mutations.md).

NEXT: the second step, what fails, stacked on this one.

M4.2 SECOND STEP — WHAT FAILS: THE TRANSPORT, A BUG, A POISONED PARSER (design §6.3, §6.4's first hazard; decision 0003 item 4).
- Transport failures:
  - a failed read, write or shutdown is a `read-error` (design §6.3), whether chez-libuv raises it at the call or reports it at the completion;
  - a failed write is also settled as `write-completed`, after the close, as the core settles a write a close cut short;
  - so a write the close itself cancels is reported the same way. That is how the shell reports a cancelled write (M3.3's question).
- A bug closes its connection. Whatever raises out of a connection's outermost dispatch drops the actions still queued, and one of them may have been the close, or the read that would have seen the client go. So the connection is closed before the raise goes on to chez-libuv and the run loop. An adoption whose read cannot start is closed the same way.
- `shell-run!`: one `uv-run` under a guard.
  - A `&byte-machine-contract` is a bug that has poisoned a parser: logged, the table reconciled, and raised again.
  - Any other callback's error is logged, the table reconciled, and the loop runs on.
  - The run loop logs quietly: a log that raises there cannot take the failure's place.
  - `reconcile!` drops a connection whose handle the loop no longer has. The other direction, a live handle the table does not know, needs the server's listener, M4.3.
- `tests/test-shell.sps` checks:
  - a write that fails at its completion closes the connection as a read error, then is settled, with no half-close. The client goes while four MiB are being written to it;
  - so does a write libuv refuses at the call. The suite shuts the connection's write side behind the shell's back, and libuv 1.52.1 then refuses the write with EPIPE (measured first);
  - a real contract condition, provoked: a parser whose on-message-begin feeds it again gives `reentrancy`, and a timer's callback raises it. The run loop raises it again, having logged it first, and still does when the log raises. After an ordinary condition it runs on, having logged it;
  - a connection whose callback raises is closed, its client reading the stream's end, and so is one whose adoption fails;
  - a connection whose handle was closed behind the shell's back stays in the table until the run loop reconciles it.
- Found, and recorded in plan §8 and design §6.4: the plan's Mutation A expected a guard narrowed to `error?` to let a contract condition escape uncaught. It cannot. chez-libuv raises a callback's error again composed with `&uv-callback-error`, an `&error`, so both arms match, and what keeps it fatal is the contract arm's place first.
- Watched to fail (m4-mutations.md):
  - M4.2-A, the plan's, one `error?` arm, and M4.2-A2, the arms swapped: the loop runs on, logging a callback error;
  - M4.2-X, M4.2-J, M4.2-C, M4.2-Q and M4.2-W1 to W3: each puts back the code as it was before the review's fix, and turns that fix's check red.
- Survives, a scope statement (M4.2-F1): a shutdown's failed completion reported as success. `shutdown(2)` fails only if the client resets in the one poll between the write's completion and the shutdown, which a test on one loop cannot order. A lingering connection reads, so a reset still closes it through the read's error.

Found in review (2026-09-26, `/code-review xhigh`), and fixed on the owner's word ("fix all findings"). Each premise was checked first:
- **A shutdown's failed completion was dropped**, though the shell's note called it a read error. It is one now. The review said the connection would linger forever; a lingering connection reads, so a reset closes it anyway. What was wrong was the note.
- **A connection whose callback raised was abandoned**, its queued close or read dropped, and never closed. Now it is closed before the raise goes on.
- **A failed adoption left the handle open** and in the table. Now it is closed.
- **Nagle's algorithm was on.** The review said pipelined responses would wait for delayed acknowledgements. Measured on loopback, on Darwin and on Linux, nothing waits, with or without it. The shell turns it off anyway: the mechanism needs a round trip, which loopback does not have, and by default Go's net package turns it off for every TCP connection, and nginx for keep-alive ones. A scope statement, as above.
- **The failure paths had no test**: a write failing at either end, a handler's raise. Now they have.
- **The gate matched only calls**, so an alias or `apply` got past it. Now it matches the name.
- **The gate hung without ripgrep**, awk reading standard input. Now it fails by name, exit 2.
- **"The listener is listening" could not fail**: it ran before any connection. Now it runs at the end.
- **The suites' setup ran outside `run-suite`**, so a failed bind exited 255, not the harness's 2. Both suites moved theirs in.
- **`reconcile!` was quadratic** in the connections. Now it looks each one up in a table of the live handles, and has a check of its own.
- **Each response read the wall clock**, 48 B a reading. Now the loop's time, which costs nothing, decides when a second has passed.
- **A log that raised in the run loop took the failure's place.** Now the run loop logs quietly.
- **The trace hook hands over the actions themselves**, so a trace that keeps them keeps a response's body. `make-shell`'s note now says so.
- **The Makefile's note said the test-only check covers `src/http-server/`.** It covers all of `src/`.

`make test` green: twenty-nine suites, 757 expected passes (connection-allocation 19, shell 48, exports 2), exit 0. `make check-imports` and `make check-close-ownership` are clean.

NEXT: two stacked PRs, on the owner's word ("commit and open the PRs"). M4.1 and M4.2 are 1,017 inserted lines of code and tests (1,058 with the Makefile and CI), two and a half times plan §1 rule 1's ~400, so each step goes up on its own: feat/m4-libuv-shell (M4.1 and the first step, 716 lines), then feat/m4.2-failures, cut from it (the second, 332 inserted and 31 deleted). The shell and the exchanges it is checked by do not divide further. Then M4.3, the listener and `server-step`.

MERGED to main on 2026-09-26, bottom up, on the owner's "do closing ritual":
- **#46, M4.1 and the first step,** as 29c5c32, without deleting its branch. The squash tree (850c147) is identical to the tested tip's, 6e77155.
- **#47, the second step.** Retargeted to main, then rebased from 6e77155 onto 29c5c32 as 705e532, its tree unchanged (b9d3acb, the tested e5f3a18's). It was force-pushed with the lease read from `ls-remote`, and merged as 48d5ab9, whose tree is b9d3acb too.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36269743318, 36269759615 and 36269874088.
- **Branches.** Both are deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: twenty-nine suites, 757 expected passes, exit 0.

M4.1 and M4.2 DONE and merged:
- a connection's parser shares the adapter's one binding list, and a check holds it;
- the direct libuv shell serves connections: the message loop with its depth counter, the executors, `connection-close!` as the one `uv-close!` call (gated in `make test`), the staged close's shell half, and a Date made once a second;
- what fails is handled: a transport's failure is a read error, a bug closes its connection, and the run loop stops on a poisoned parser and runs on after any other callback's error;
- decision 0012 settled M4.5's two questions, by form.

NEXT: M4.3, the listener and `server-step` (plan §8):
- `server-step`, pure, with design §4.6's events and actions: `accept`, `refuse` over `max-connections`, `close-listener`, `force-close-all`, `log`;
- `max-connections` (10,000) and `backlog` (511) arrive as limits, each with its four things (plan §3);
- the shell's listener, and the reconciliation's other direction: a live handle the table does not know.

Then M4.4, the contract test and the socket lane, with the upload past a refusal; M4.5, the facade (decision 0012); and the M4 exit. It starts on a fresh branch cut from main after this commit, when the owner asks.

M4.3 — THE LISTENER AND `server-step` (plan §8; design §4.6). Branch feat/m4.3-listener, cut from main at 100ae8b; 2026-09-26, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

CHECKED first, in libuv 1.52.1's source (chez-libuv vendors it):
- libuv takes a connection off the socket before it calls the listener's callback, and stops watching the listener until the callback accepts it (`src/unix/stream.c:507-531`). So a connection the server will not serve is accepted and closed at once. That is how nginx refuses one its `worker_connections` cannot hold, and what decision 0005's "refuse in on-connection" comes to; one left unaccepted would stop the listener.
- On Unix libuv drops a failed accept itself, and when descriptors run out it sheds load by accepting and closing whatever waits (`uv__emfile_trick`). Only on Windows does an accept's error reach the callback, and there the listener has stopped (`src/win/tcp.c:1221-1231`). A `uv_accept` that fails on Unix closes the descriptor and leaves the listener listening (`src/unix/stream.c:535-594`).

Found in review (2026-09-26, `/code-review max`), before the first commit: fifteen findings, eleven confirmed by running them, four plausible. On the owner's word, "Let's work on all of them".

DECIDED on the owner's word (2026-09-26), by form, the recommended answer to each of four questions:
- **The count of open connections is the table's size.** The shell passes it with each arrival, `(connection-arrived n)`, so the step keeps no count to drift, and nothing reports a close to it for counting. `connection-closed` stays in the vocabulary for M8's drain. Weighed: the step's own count, guarded at each report site.
- **A refusal episode is logged twice at most:** the first refusal at once, then how many were refused, when a connection is next accepted or the server shuts down. Counted in the pure step. Weighed: every refusal, as nginx does.
- **A listener that fails shuts the server down:** `listener-failed` is logged, the listener closed, and the server drains, so the process ends once its connections finish and a supervisor restarts it. It is a new event in the step's vocabulary. libuv 1.52.1 reports such a failure only on Windows (`src/win/tcp.c:1221-1231`). Weighed: log only; listen again, which would need M5's timer.
- **One procedure closes every handle,** and what a close does follows the handle, not the caller: a connection's cleanup runs whoever closes it. The rule is again one `uv-close!` caller, checked by reading the source with Chez's own reader. Weighed: an owner per kind of handle.
Decision 0005 has an amendment recording the two about refusals and the listener, and the backlog's bound.

M4.3 FIRST STEP — THE TWO LIMITS, `limits-with`, AND `server-step`.
- `max-connections` (10,000) and `backlog` (511), decision 0005's, arrived with plan §3's four things each: the field, a test of its default, `CHEZ_HTTP_MAX_CONNECTIONS` and `CHEZ_HTTP_BACKLOG` in `limits-environment-variables`, and the drift guard extended. Each is at least 1. The backlog is at most 2147483647, since `uv_listen` takes it as a C `int`; a larger value wrapped negative, or raised an error that named no variable (review, C6).
- `limits-with` replaces fields by name, in an order it reads from the record type itself. The four hand-written fifteen-argument copies in the tests are gone; two of them could swap the cap and the backlog with no suite noticing (review, C18).
- `src/http-server/server.sls`, `(http-server server)`, new and pure (`(rnrs)` and the limits):
  - the vocabulary: five events (design §4.6's four and `listener-failed`), five actions, two phases;
  - the state is the phase and the refusals of the episode under way, linear as a connection's is. A state whose limits have no connection cap of at least 1 is refused, so `max-connections` = `#f` cannot reach an arrival (review, C3's trigger);
  - an arrival carries the count of connections open, and is answered first: `accept` below the cap, ending a refusal episode with `(log refused max-connections n)`; `refuse` at it, the episode's first logged `(log refusing max-connections)`; `refuse` while draining, unlogged;
  - a shutdown, or a failed listener (logged), closes the listener and drains, logging an episode under way; a second asks for nothing;
  - a tick and a close ask for nothing yet.
- `tests/test-server.sps`, new, 28 checks: the vocabulary, tied to the step (every event is taken in either phase; no row asks for an action outside the list, read from what the step answers), and a row per transition, held as data.
- Red before green: the limits suite stopped at load at `limits-with`, then failed the backlog's bound alone until it existed; the server suite stopped at load against the step before the rework.
- Watched to fail (m4-mutations.md): M4.3-A, the plan's, the step's refusal rows and nothing else in any suite; L1 to L7 and W1 to W3, the limits; B to Y, the step, one or more for every check.
- Every suite green in a scratch worktree with only this step, cut from main at 100ae8b: thirty suites, 794 expected passes (limits 37, server 28, shell 48), each exit 0. `make check-imports` and main's close-ownership gate are clean there, and the step's mutants ran there with the results they give on the finished tree.

M4.3 SECOND STEP — THE SHELL'S LISTENER, AND ONE CLOSER.
- `(http-server private shell)`:
  - `handle-close!` is the one `uv-close!` call, for a connection's handle, the listener, and a refused one. Its callback follows the handle: a connection's close takes it out of the table, now keyed by handle, and reports `closed`, whoever asked for it. `refuse!`, which closed any handle it was given, and let a connection's handle pass the gate, is gone (review, C2);
  - `shell-adopt!` offers a handle with the table's size and takes the step's first action as its answer, anything but `accept` or `refuse` an assertion violation (C4). If anything raises before the handle is served it is closed, so none is left open with no one to close it (C3);
  - `shell-listen!` refuses to listen while a listener is open, or once its server has stopped listening, so a listen after a shutdown cannot open a listener nothing closes (C1). A listen that fails is closed and may be retried (C1b);
  - the listener's error is `listener-failed`, which shuts the server down (C5); a `uv-accept!` that fails is logged as `accept-failed`, and the listener listens on;
  - `server-run!` refuses an action it cannot perform, where it dropped it (C12); the server's actions run without a closure per call (C17); `closing-on-raise` takes the handle to close, and serves the listener and a connection alike (C19);
  - the trace also sees the server's events and the actions of its the shell performs;
  - `reconcile!` drops a connection whose handle is gone, which frees its place; nothing is reported to the server any more, so nothing can raise inside the run loop's handling (C9, C10, C11, C15).
- `tests/test-close-ownership.sps`, new, replaces the awk scan: it reads src/ with Chez's own reader and requires one use of `uv-close!`, in `handle-close!`. Its fixtures pin what the scan missed: a call after a `;` in a string or a `#\;`, two uses one character apart, a rename in an import (C7, C8). `make check-close-ownership` runs it alone; `make test` runs it with every suite, and CI no longer needs ripgrep.
- `tests/test-shell.sps`, fourteen checks more than M4.2's 48:
  - a bug before a connection is served: the trace raises on the arrival, and the client reads the stream's end, no connection served, the error logged;
  - the reconciliation's drop, and the run loop runs on;
  - a shell capped at one connection: it serves a client; listens on one listener at a time; two clients over the cap each read the stream's end with nothing before it, the first refusal logged and the second not; once the first client closes the next is served and the count of refusals logged; a shutdown closes the listener the clients used, which the old check did not read (sweep, N1), and the server never listens again;
  - a backlog of -1 from the limits cannot listen, and the listener is closed; a listener on a port in use cannot listen, is closed, and the shell listens again.
- Records: `docs/configuration.org` says what a refusal, running out of descriptors and the backlog's bound look like; design §3.3, §4.6 and §7.6, plan §8's M4.3 note and §9's M7 line, and global-constraints say one procedure closes every handle.
- Red before green: the shell suite with the new checks stopped at load against the first step's shell; the ownership suite failed on a copy of the tree whose shell had three owners.
- Watched to fail (m4-mutations.md): S1 to S16 but two; G1 to G5, a second caller, a second call, an alias, a call after a `;` in a string, two uses side by side; the walker's own WA to WH; the plan's M4.3-A against every suite.
- Scope statements:
  - M4.3-S10 and S11: the shell's assertions on a wrong answer or an unknown action fire only on a bug in the step, whose rows pin every answer; no check can provoke them.
  - The listener's failure and a failed `uv-accept!` are routed and logged, and not provoked: libuv 1.52.1 reports neither on Unix in a way a test can cause, and Windows is not in CI. The step's rows hold the listener's failure.
  - "comments are not uses" pins Chez's reader.
- The review's other findings, fixed: the stale single-owner statements (C14); the untied vocabulary (C13); the S7 record, which said the second listener was never closed where the first was, and the G2 record, which overstated the awk fix (sweep, N1); several checks never watched to fail (sweep, N2), now each reddened by a named mutant. Left as it is: the guard idiom repeated across nine suites (not reported; `(testing)` has no helper for it). Not this slice's: two M8 notes on WebSockets and Caddy appeared in the plan's working copy from outside this session; they are not in M4.3's commits.

`make test` green: thirty-one suites, 820 expected passes (limits 37, server 28, shell 62, close-ownership 12, exports 2), exit 0.

NEXT: two stacked PRs, on the owner's word ("Commit an open the PRs - u don't need to split into 4"). M4.3's code and tests are 896 inserted lines: feat/m4.3-server-step, the first step (444 inserted and 57 deleted), then feat/m4.3-listener, cut from it (452 and 89). Each is a little over plan §1 rule 1's ~400, and the owner kept two rather than four. Then M4.4, the contract test and the socket lane, with the upload past a refusal.

MERGED to main on 2026-09-26, on the owner's "Do closing ritual":
- **#48, the first step,** as b79bd85, without deleting its branch. The squash tree (cbf60d8) is identical to the tested tip's, 72a5c2b.
- **#49, the second step.** Retargeted to main, then rebased from 72a5c2b onto b79bd85 as 1f1655b, its tree unchanged (c586e72, the tested 71585ca's). It was force-pushed with the lease read from `ls-remote`, and merged as 140f5e1, whose tree is c586e72 too.
- **#50, the M8 notes.** Two notes another session wrote in the shared checkout, on the questions M8's door must answer before a WebSocket library can take a stream through it, and on serving behind Caddy. They were committed on their own, on the owner's "Commit the M8 notes to their own PR". The commit was built from main without touching the checkout, and the checkout's uncommitted copy was dropped once it was proven to be exactly those lines. The notes were rebased from 100ae8b onto 140f5e1 as 0e38c22 with the same patch (patch id bf7c40c), and `make test` is green on that tree. They merged as e290d1a, whose tree is 0e38c22's, 6d4e2ec. One sentence in its question 2 still gives the close-ownership rule of M4.3's working copy before the review, "each kind of handle one `uv-close!` owner"; since #49 it is `handle-close!`, one procedure for every handle.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36279194851 and 36279207840 (#48 and #49 as opened), 36280979170 (#49 rebased), 36280825011 and 36281050335 (#50, as opened and rebased).
- **Branches.** All three are deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-one suites, 820 expected passes, exit 0.

MERGED to main on 2026-09-26, on the owner's "go ahead and merge this and do the closing ritual": **#51, question 2's close owner,** as 5486ddb. The sentence #50 left stale now says `handle-close!` is the one `uv-close!` in `src/`, for every kind of handle (`make check-close-ownership`). It was written in its own worktree off main, on the owner's word, since the shared checkout was the M4 session's. The squash tree (1389928) is identical to the tested tip's, ac85e2d. CI was the billing block, the `linux` job with 0 steps (36282494049). The branch is deleted local and remote, and refs pruned. `make test` green on its tree: thirty-one suites, 820 expected passes, exit 0. NEXT is unchanged.

M4.3 DONE and merged:
- `max-connections` (10,000) and `backlog` (511) are limits, the backlog at most a C `int`'s largest; `limits-with` replaces limits by name;
- `server-step`, pure, decides the listener: accept below the cap, refuse at it; a refusal episode logged twice at most; a shutdown or a failed listener closes the listener and drains;
- the shell listens, offering each connection with the table's size, and one procedure, `handle-close!`, closes every handle, held by a check that reads the source with Chez's reader;
- four questions settled by form, and the review's fifteen findings fixed.

NEXT: M4.4, the contract test and the socket lane (plan §8): the same scripted event stream through the fake shell and the direct libuv shell must give identical wire bytes and identical action traces; the socket lane's upload past a refusal (decision 0011's measurement) becomes a test. On a fresh branch cut from main after this commit, when the owner asks. Then M4.5, the facade (decision 0012), and the M4 exit.

M4.4 — THE CONTRACT TEST, AND THE SOCKET LANE (plan §8; design §8.4, §8.5). Branch feat/m4.4-contract, cut from main at 523b8fa and fast-forwarded to 5f537b6, which another session merged meanwhile (#51's plan fix and its reflect; neither touches `src/` or `tests/`); 2026-09-26, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

MEASURED first, by a spike (scratch, not kept): six client scripts played to the libuv shell over loopback, and the libuv shell's own events then given to the fake shell, gave identical events, actions and wire bytes. libuv delivered each completion before the next read. A write's completion runs in the loop's pending phase, and in the same call libuv shuts the socket for the half-close the core asks for there and runs its callback, before the poll that reads (libuv 1.52.1, `src/unix/stream.c:733-735, 1232-1238, 625-660`).

M4.4 FIRST STEP — THE SOCKET LANE'S UPLOAD PAST A REFUSAL.
- The socket lane is `tests/test-shell.sps`, which M4.2 wrote in design §8.5's shape; its header now says so.
- It gains decision 0011's measurement as a test. A client sends four MiB after a head the core refuses, with no Host, a 400. Its send buffer is small, so the upload is sent only if the server reads it, and it reads only once its send is over, as Python's http.client and Node's fetch do. It sends all of it, then reads the 400 and the stream's end: the connection lingers, reading and dropping the upload. A client that does not connect sends nothing, and both checks say how its connect ended.
- Measured under a close at once (M4.4-U), three runs of three: the send fails with EPIPE, and the stream ends in ECONNRESET, with the 400 already in the client's buffer. Python's http.client gives up at the EPIPE, which is why decision 0011 saw no status.
- `tests/shell-testing.sls`, `(shell-testing)`, new: the suite's clients and its run of the shell's loop, moved out of it to be shared with the contract test. With the clients' move alone, the suite's output was unchanged, 62 passes. A review before the first commit found eight things, all fixed on the owner's word; its record is with the second step, since its fixes fall in both. Two are here: the run closes its ticker when the shell's run loop raises, which a check provokes, and a client records a connect refused at the call as it records one refused later.
- The upload check passed at once, against M4.2's staged close, so its red is its mutants' (m4-mutations.md): M4.4-U, a close at once, and M4.4-U3, no reading while lingering. U3 found a flaw in the check first: a send the suite's own close cut short started a read on a closing handle, and the raise surfaced in the next block's wait. The client now reads only while its handle is open. The ticker's check was red first, and M4.4-K turns it red.
- Every suite green in a scratch worktree with only this step, cut from main at 5f537b6: thirty-one suites, 823 expected passes (shell 65), each exit 0; the import audit clean. U, U3 and K ran there too, turning the same checks of the shell suite red as on the finished tree.

M4.4 SECOND STEP — THE CONTRACT TEST.
- `tests/test-contract.sps`, new (design §8.4):
  - a script is a client's: what it sends, where it waits for the server to have read it, and its end, the half-close. The client plays it to the libuv shell's own listener, on the shell's loop, run by the shell's own run loop. That loop logs a callback's error and runs on; a byte-machine contract condition it raises again ends the suite, as it would end a server;
  - the libuv shell's own events are then given to a fake connection whose clock reads the same instant: each delivery and the client's end as the libuv shell received them, and each completion where it received its own, the fake delivering the one it has waiting. How the kernel divides the stream into reads is its policy (design §8.5), so a script cannot fix it;
  - nine scripts: a GET kept alive; three requests in one write; a request split across two deliveries; a request with a body; a response that closes the connection, then the linger; input that arrives while the connection lingers; a handler that raises; a handler that raises a condition with no message; and a request refused for want of a Host;
  - for each: the libuv shell read what the client sent, then its end alone, and closed; the client read the bytes the fake shell wrote; and the two traces, every event dispatched and action run, in order, are identical. The traces compare content: a condition by each of its simple conditions and any record by its type and fields, since `equal?` compares a record with fields by identity. Where the shells part, a `CONTRACT MISMATCH` line on stderr names the first byte, or the first event or action;
  - a client that does not connect plays nothing, and its read check names how the connect ended;
  - at the end, no connection and no handle is left.
- `tests/fake-shell.sls`: an optional trace, which sees each event as it is dispatched and each action before it is performed, as the libuv shell's trace does; and `fake-shell-deliver-later!`, which delivers the oldest event a later turn brings, one at a time. `tests/test-fake-shell.sps` and `tests/test-message-loop.sps` have a check each.
- `(shell-testing)` gains `client-shut!`, the half-close a script ends with.
- Red before green: the fake shell's two checks ran before it had either: test-fake-shell's body raised at the five-argument `make-fake-shell` (a harness error, after 15 passes), and test-message-loop stopped at load. The no-message script's trace check was red before the rendering compared records by content. The rest of the contract suite was written against shells that already agree, so its red is its mutants'.
- Watched to fail (m4-mutations.md), on the finished tree:
  - M4.4-A, the plan's: the Date line's space after the colon sent as a tab. Every script's wire check goes red, naming the byte, 32 in the fake's bytes and 9 in the libuv shell's: byte 22 after a 200's status line, 31 after a 400's, 41 after a 500's. The socket lane stays green, since llhttp strips a tab there as it strips a space, and so does every other suite;
  - M4.4-T and T2, the libuv shell reporting a completion twice and tracing an action after performing it: the trace checks alone;
  - M4.4-R and X, the read path dropping each delivery's last byte and a read error reported after the client's end: in this suite the read checks alone, since the fake is given the same stream;
  - M4.4-E, the listener left open: the end's check. M4.4-N, the rendering before the review: the no-message script's trace check. M4.4-P and P2, a client that cannot connect: every read check, named, the suite running on;
  - M4.4-F1 to F4, the fake shell's trace and one-at-a-time delivery: their own checks, and every contract trace check for F1 and F2.
- Survives, a scope statement: F3 and F4 leave the contract green. In these scripts the fake never has two completions waiting, by libuv's order above. The replay delivers each where the libuv shell received its own regardless, and the message loop's check holds the order.
- Records: design §8.4 and §8.5, plan §8's M4.4 note.

Found in review (2026-09-27, `/code-review high`), before the first commit: eight findings, all fixed on the owner's word ("Do the fixes"). Each premise was checked first:
- **The run of the shell's loop left its ticker when the loop raised**, as it does a byte-machine contract condition (design §6.4), so a later "no handle is left" check would have blamed the code under test. It closes the ticker on the way out now, as chez-libuv's `run-until/ticking` does, and a check provokes the raise.
- **The contract's wait said a bug that raises in a callback shows as the traces parting.** A contract condition still ends the suite; the note now says so.
- **A read error the libuv shell made itself would have been handed to the fake as input**, so both traces would agree over it. Measured first: a mutant reporting a read error after the client's end (M4.4-X) left every suite green. No script resets its connection, so the read check now requires the client's end alone, and X turns it red.
- **A condition with fields and no message never compared equal between the shells**: `equal?` compares such a record by identity (measured; a field-less record, such as `(make-error)`, is one shared instance and compares equal). A script whose handler raises one was red first. The rendering now compares a condition by its simple conditions, and any other record by its type and fields.
- **A client that could not connect stopped the suite with a harness error**, in the contract suite and in the upload check alike. Measured first with M4.4-P and a probe of the upload. A second way was found on the way: macOS refuses a connect to the client's own address at the call, with EINVAL (M4.4-P2), where a closed port refuses it at the completion. A client now records a connect refused at the call as it records one refused later, and both suites report it by name and run on.
- **The contract's wait predicates rebuilt the whole event list on every iteration.** The trace now keeps the delivered bytes in chez-libuv's byte collector, and a flag for the close, as they arrive.
- **The contract suite hand-rolled joining bytevectors**, which the byte collector already does. It uses the collector.

`make test` green: thirty-two suites, 853 expected passes (contract 28, shell 65, fake-shell 19, message-loop 20), exit 0.

NEXT: two stacked PRs, on the owner's word. M4.4's code and tests are 567 inserted lines, over plan §1 rule 1's ~400: feat/m4.4-socket-lane, the first step (176 inserted, 60 deleted), then feat/m4.4-contract, cut from it (391 inserted, 33 deleted). Then M4.5, the facade (decision 0012), and the M4 exit.

MERGED to main on 2026-09-27, on the owner's "Do closing ritual":
- **#52, the first step,** as 32aa654, without deleting its branch. The squash tree (a478baa) is identical to the tested tip's, 251ab40.
- **#53, the second step.** Retargeted to main, then rebased from 251ab40 onto 32aa654 as 962eaa8, its tree unchanged (8efdc9e, the tested 1c63567's). It was force-pushed with the lease read from `ls-remote`, and merged as a854e06, whose tree is 8efdc9e too.
- **CI.** Every run was the billing block, the `linux` job with 0 steps: 36319062837 (#52), 36319064692 (#53 as opened) and 36320460207 (#53 rebased).
- **Branches.** Both are deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-two suites, 853 expected passes, exit 0.

M4.4 DONE and merged:
- the socket lane, `tests/test-shell.sps`, holds decision 0011's measurement as a test: a client that uploads four MiB past a refusal sends all of it, then reads the status and the stream's end;
- the cross-shell contract, `tests/test-contract.sps`: nine client scripts played to the libuv shell, its own events given to the fake shell, and the two shells' wire bytes and traces identical. The plan's mutation names the differing byte, and the socket lane stays green under it;
- the fake shell traces what it does and hands over a later turn's events one at a time, and the shell suites share `(shell-testing)`;
- the pre-commit review's eight findings fixed.

NEXT: M4.5, the facade, and what a handler sees (plan §8; decision 0012):
- `(http-server)`, decision 0001's facade;
- a handler reads the request through accessors that copy what it asks for, with the host by RFC 9112 §3.2.2;
- the server listens where `CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT` say, by default 127.0.0.1 and 8080;
- a facade that builds limits refuses a pipeline cap other than 1;
- finished by the plan's mutation, an absolute-form request's host read from its Host field.

Then the M4 exit (plan §8): curl and ab get correct responses and the counters return to zero; the contract test passes; the connection table is reconciled against `uv-loop-live-handles` at one place in the run loop; the per-connection budget is re-measured; and the amendment slicing M5–M8 is written (plan §10). It starts on a fresh branch cut from main after this commit, when the owner asks.

M4.5 — THE FACADE, AND WHAT A HANDLER SEES (plan §8; decision 0012). Branch feat/m4.5-handler-view, cut from main at a5d8474; 2026-09-27, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.

Gathered before the first test, from plan §8, decision 0012 and this ledger:
- decision 0012: a handler reads the path, the query, a header's value by name and the host, as strings made when asked, and the method as llhttp's symbol; the host follows RFC 9112 §3.2.2; the server listens where `CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT` say, by default 127.0.0.1 and 8080;
- a facade that builds limits refuses a pipeline cap other than 1 (M2.4);
- design §6.4's `&http-server-error` and its two subtypes, "defined in the shell and exported from the facade", which design §9.1 gives to M4;
- the plan's mutation: an absolute-form request's host read from its Host field.

Settled here, where decision 0012 is silent, each with a check:
- a string is a character per byte, Latin-1, as the decision's measurement made its strings, so every byte reads back as the byte it was;
- the query is what follows the target's first "?", in every form, since a "?" can be in neither an authority nor a path (RFC 3986 §3.2, §3.3);
- asterisk-form's path is "*", authority-form's is "", and an absolute-form target's is its URI's, "/" when empty (RFC 9110 §4.2.3's normal form). Hyper's `http` crate reads all three the same way;
- a header's value is its first field's, by name in any case, as `headers-ref` reads it in the decision's measurement, and without the whitespace around it (RFC 9112 §5). So is the host from a Host field, which #54 left to M4.5. The view trims where it reads, as the Host judge (with #54) and the transfer-coding reader do. Trimming once, where the core records a value, is #54's alternative, recorded in its entry: one place for every reader, at the cost of a new span for each value with whitespace to drop. It changes M2's core. Decided below: trimmed where read;
- authority-form's host is the Host field's, by the decision's letter ("otherwise it is the Host field's value"). RFC 9112 §3.3 would read the target, the tunnel's destination. v1 answers a CONNECT and closes, so no handler needs it now. Kept, decided below (M4.5-J is its mutant).

Found:
- llhttp leaves out the whitespace before a field value and keeps what comes after it: through the core, "X-Pad:   v  x  " keeps "v  x  ". So the view trims it.
- The Host judge (M2.3's) judges that span as it is kept, so "Host: h " and "Host: h" with a tab after it are answered 400, where RFC 9112 §5 makes the value "h". This is outside M4.5, and was fixed on its own by another session: PR #54 (fix/host-trailing-whitespace), open as this is written. Its review left to M4.5 what a handler reads of such a value: settled below.
- An absolute-form target always has an authority, which may be empty ("ftp:///x"). llhttp takes one only with "//": "GET urn:example:x" never reaches the core.
- `(rnrs)` leaves out `string-set!`. The view fills its strings with it, so `(rnrs mutable-strings)` joins the pure libraries' imports, amended in global-constraints and design §3.1. Measured on an 11-byte path (scratch): 64 B that way, 96 B through a UTF-16 bytevector, 240 B through a list, 2,048 B through a Latin-1 transcoder.

MEASURED, the shipped view (scratch, not kept; two identical runs, exit 0), on decision 0012's three requests and one absolute-form GET. Bytes per request, beside the decision's (A), 80, 96 and 192:

| request | path and User-Agent | host |
|---|---|---|
| curl's GET | 112 | 64 |
| a JSON POST | 128 | 64 |
| a browser's GET | 224 | 64 |
| curl's GET, absolute-form | 3,952 | 3,904 |

A lookup by name makes the name a bytevector, 32 B, which is the difference from (A). An absolute-form target's path or host costs a uriparse parse each time it is asked for. That is accepted, as CONNECT's fresh parse is (design §7.5): absolute-form is a proxy's, rare at an origin server, and a handler that does not ask pays nothing.

M4.5 FIRST STEP — WHAT A HANDLER SEES.
- `src/http-server/view.sls`, `(http-server view)`, new, pure:
  - `request-path`, `request-query`, `request-header` and `request-host`, each a fresh string, or #f for a query or a header that is not there;
  - where each part is follows the target's form, read by `target-form`, the judge's own rule;
  - an absolute-form target's host is its authority, whatever the Host field says; otherwise the host is the Host field's value, "" when it is empty or missing.
- `(http-server target)` exports `target-form`, the rule the judge reads, which the view now reads too, and `first-question`. The allocation gate is unchanged (19 passes).
- `tests/test-view.sps`, new, thirteen checks. Each request is fed whole to a fake connection running the real core and parser, and read inside the handler's call. The rows: origin-form's path and query, with a second "?" and a percent-encoding; no "?" and an empty query; absolute-form's path, query and host; the empty path; asterisk-form and authority-form; origin-form's host; an empty Host and none; a header by name; a value's trailing whitespace; a byte above 127. One more is built by hand: a Host value with whitespace after it, which the core refuses until #54, reads without it.
- Red before green: the twelve rows through the core failed against a stub view. The hand-built host row, added after #54, passed at once against the view as written; its red is M4.5-O2's.
- Watched to fail (m4-mutations.md):
  - M4.5-A, the plan's, reddens the host row alone. Every other suite stays green;
  - B to P each redden the view's own rows, and O2, the host's value untrimmed, the hand-built row alone;
  - Q, `target-form` without its CONNECT arm, reddens the judge's CONNECT rows, two CONNECT traces and the view's authority-form row;
  - each of the thirteen checks is reddened by at least one mutant.

DECIDED on the owner's word (2026-09-27, "Go with the recommendations"), each as recommended and built:
- a value's trailing whitespace is dropped where it is read: by the Host judge (with #54), the transfer-coding reader and the view. Trimming once where the core records a value, #54's alternative, can come later as a small PR of its own;
- authority-form's host is the Host field's, by decision 0012's letter;
- an absolute-form target's parts cost a uriparse parse each time they are asked for (3,904 B, measured above), accepted as CONNECT's fresh parse is;
- the details the view settles where decision 0012 is silent (above) stand, and decision 0012 gains a dated note saying so.

Every suite green on this step alone, in a scratch worktree cut at its commit: thirty-three suites, 866 expected passes (view 13), each exit 0; the import audit clean.

NEXT: the second step, the facade, stacked on this one: `(http-server)`, what reaches the embedder; the address from `CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT`; the startup's `&http-server-config-error`, which refuses a pipeline cap other than 1 as the environment path does; and the docs a handler reads.

M4.5 SECOND STEP — THE FACADE. Branch feat/m4.5-facade, cut from the first.
- `src/http-server.sls`, `(http-server)`, new, the facade. It exports:
  - `serve`;
  - the six accessors a handler reads with: `request?`, `request-method`, and the view's four;
  - `make-response` and `response?`;
  - `&http-server-error` and `&http-server-config-error`, with their predicates.
  
  It imports this project's libraries alone, as design §3.1 has it. The spans stay the request's: no span accessor is exported.
- `src/http-server/private/serve.sls`, `(http-server private serve)`, new: the process's edge.
  - `start-server` reads the limits and the address through a lookup. It makes the shell, listens, and logs `listening` with the host and the port it got.
  - `serve` is `start-server` on a loop of its own, with the process's environment (`getenv`) unless a lookup is given, and the log below. It then runs the loop until the server stops: in v1, only a listener that fails stops it.
  - A setting the pure parsers refuse is raised again as an `&http-server-config-error` composed with their assertion violation, whose irritants name the variable. That covers a pipeline cap other than 1, since the facade builds limits only from the environment (M2.4's note). A `CHEZ_HTTP_HOST` that is not an IP literal is refused by chez-libuv's bind as `bad-address`; it is raised as a config error naming the variable, and the shell has closed the listener.
  - `log-line` writes each thing that happens as one line on standard output, flushed at once (Twelve-Factor XI): what happened, then each detail. A condition reads as Chez's `display-condition` shows it, its line breaks made spaces, and a record as its kind, `#<connection>`, so a line never spells out a connection's state.
- `(http-server limits)`: `address-from-environment` reads `CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT`, by default 127.0.0.1 and 8080 (decision 0012). The port is 0 to 65535, and 0 asks the kernel for one. The host is judged by the bind, the OS's own parser.
- `tests/test-serve.sps`, new, nine checks:
  - the facade's exports;
  - a server started through an environment on port 0: it logs where it listens, with the kernel's port; a request read through the facade's names reaches the handler, and its answer reaches the client; its limits are the environment's (a 414); and once shut down it leaves nothing on the loop;
  - `serve` refuses three malformed settings as config errors naming each;
  - a host that is not an IP literal is refused, and nothing is left open;
  - the log's two shapes.
  
  Clients run on the server's loop, every wait capped by an iteration count. `tests/test-limits.sps` gains three address rows (40).
- `make run PROGRAM=...` runs a program on the library path. `make check-imports` now reads the facade's file as well as `src/http-server/`.
- Docs:
  - `docs/handlers.org`, new: what a handler reads, keeping strings rather than the request (decision 0012's rule for spans), and answering;
  - `docs/configuration.org` gains where the server listens;
  - the README's status, stale since M0, now says M4, and there is a quick start.
  
  The docs had described the four timeouts, a 408 among them, as enforced; the shell only records deadlines until M5's wheel, and now they say so.
- Red before green:
  - the address rows failed against a stub parser;
  - the serve suite's eight behavior rows failed against a stub start that listened with default-limits and logged nothing;
  - the exports row passed at once, since the facade's list was already the one written, so its red is M4.5-Z's.
- Watched to fail (m4-mutations.md), each against every suite: M4.5-R to AE, and AF, the facade importing `(chezscheme)`, which `make check-imports` alone reddens. Every check of the step is reddened by at least one.
- Found while watching: M4.5-AC hung the serve suite. Its `serve` accepted a pipeline cap of 2, listened on 8080 and ran for good, and the run was killed. So every start that should fail also names a host no bind accepts, and so does the suite's own environment: a start past its settings, or a `serve` that read the process's environment rather than its lookup (AE), is refused at the bind. Both were run again and turned red without hanging. A failing start must not be able to run.
- Not tested in a suite: `serve`'s own run of its loop, which blocks by design. Smoke-run by hand (2026-09-27): the README's program, started with `make run` on port 18765, logged `listening 127.0.0.1 18765`. curl got a 200 with its body for a GET and for HTTP/1.0 (with `Connection: close`), the length and no body for `-I`, and two GETs on one connection. The M4 exit runs curl and ab against it.
- Records: design §6.4 (the two types, and why §6.4's third waits) and plan §8's M4.5 note.

DECIDED on the owner's word (the same words, as recommended): design §6.4's `&http-server-handler-error` is not defined in v1. A handler's raise is answered 500 and logged as `handler-failed`, and never reaches the embedder, so the wrapper has nothing to carry.

`make test` green: thirty-four suites, 878 expected passes (serve 9, limits 40, view 13), exit 0.

NEXT: two stacked PRs, on the owner's word: the first step, then the facade stacked on it. Then the M4 exit (plan §8): curl and ab get correct responses, and the counters return to zero; the contract test passes; the connection table is reconciled against `uv-loop-live-handles` at one place in the run loop; the per-connection budget is re-measured; and the amendment slicing M5–M8 is written (plan §10).

MERGED to main on 2026-09-27, on the owner's "Go ahead and do the commits push the PR's up and do a closing ritual":
- **#55, the first step,** as 36b0ff5, without deleting its branch until #56 was retargeted. The squash tree (ec40093) is identical to the tested tip's, 09f7be3.
- **#56, the second step.** Retargeted to main, then rebased from 09f7be3 onto 36b0ff5 as df0d6e5, its tree unchanged (3260d75, the tested 24a78db's). It was force-pushed with the lease read from `ls-remote`, and merged as 1bdb83f, whose tree is 3260d75 too.
- **CI.** Every run was the billing block, the `linux` job with 0 steps and the billing annotation: 36325832664 (#55), 36325848593 (#56 as opened) and 36325938319 (#56 rebased). The last was still queued when #56 merged, on a tree identical to 36325848593's, and completed the same way after.
- **Branches.** Both are deleted local and remote, and refs pruned. PR #54, the Host fix, is still open, another session's work. It meets these merges at the ends of this file and of m4-mutations.md, and in plan §8's M4.5 section.

`make test` green on main: thirty-four suites, 878 expected passes, exit 0.

M4.5 DONE and merged:
- `(http-server)`, the facade: `serve` runs a handler where `CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT` say, by default 127.0.0.1:8080, and a malformed setting raises `&http-server-config-error` naming it before anything listens;
- `(http-server view)`: a handler reads the path, the query, a header's value and the host as fresh strings, the host by RFC 9112 §3.2.2. The plan's mutation reddens the host row alone;
- the owner's decisions of 2026-09-27 are recorded in the steps above, and in decision 0012's amendment.

NEXT: the M4 exit (plan §8): curl and ab get correct responses, and the counters return to zero; the contract test passes; the connection table is reconciled against `uv-loop-live-handles` at one place in the run loop; the per-connection budget is re-measured; and the amendment slicing M5–M8 is written (plan §10). It starts on a fresh branch cut from main after this commit, when the owner asks.

A HOST VALUE WITH OWS AFTER IT (RFC 9112 §5). Branch fix/host-trailing-whitespace, cut from main at a5d8474 in its own worktree, and rebased onto 6bf3c34 once M4.5 merged (#55, #56); 2026-09-27, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1.
- **Found:** `Host: h ` and `Host: h\t` were answered 400 (`invalid-host`) at every delivery size, where `Host: h` reached the handler (measured with the fake shell). llhttp leaves out the OWS before a field value but keeps the OWS after it (`X: h \t ` arrives as `h \t `), and `value-fault` judged that span as it was with uriparse's `validate-authority`, which refuses a space or a tab. RFC 9112 §5 excludes that OWS from the value, so the value is `h`, and valid; §3.2's 400 is for an invalid value.
- **Fixed:** `value-fault` (`src/http-server/host.sls`) judges the value without the OWS around it, trimmed with `trim-ows` from `(http-server headers)`, as the transfer-coding reader does. The duplicate-Host and missing-Host rules are unchanged, and a value invalid without its OWS is still refused (`Host: a b `, `Host: u@h `).
- **Tests:** a row in `tests/test-host.sps` (`h `, `h\t`, `example.com:8080 \t ` and ` h` are accepted) and one in `tests/test-connection-head.sps` (`Host: h ` and `Host: h\t` are served, at every delivery size, whatever a handler reads of the value). On main's code each failed alone in its suite.
- **Watched to fail** (m4-mutations.md): HW-A, the trim removed, turns the two new rows red and nothing else in any suite. HW-B, the OWS before a value kept, turns the unit row red alone.
- **Found in review** (2026-09-27, `/code-review high`), before the first commit: three findings. On the owner's word ("Fix 2 and 3, leave 1 for M4.5"):
  - the head row pinned the handler reading `h `, so a correct trim elsewhere would have turned it red. It now leaves the headers out (`headless`); a probe that trims every value where the core records it (HW-P) leaves it green;
  - `value-fault` bound uriparse's index and never read it. Its comment now says only the code is read: R6RS has no binding that ignores a value, since `_` is an ordinary variable that shadows `(rnrs)`'s `_`, and `(http-server target)` binds the same pair the same way.
- **Left for M4.5, which settled it (#55):** its view trims a value where it reads it, so a handler reads `h` for `Host: h `. Trimming once where the core records a value is this fix's alternative, recorded in M4.5's entry above. HW-P is that trim: every suite green, the allocation lane included, though it makes a new span for every value; spans are immutable, so one is needed only when a value has OWS to drop. The paragraph this fix first carried into plan §8's M4.5 section is dropped on the owner's word, since M4.5's note there covers it.
- `docs/host-header.org` says nothing about whitespace, so it is unchanged.

`make test` green on the rebased tree: thirty-four suites, 880 expected passes (host 12, connection-head 52), exit 0. NEXT is unchanged.

MERGED to main on 2026-09-27, on the owner's "Do the closing ritual?": **#54, the Host fix,** as 52ddb1f.
- **Rebased first.** M4.5 merged meanwhile (#55, #56), so #54 was rebased from 25ca646 (on a5d8474) onto 6bf3c34 as f8623bf. The owner chose by form to drop its plan §8 paragraph, which M4.5's note there covers. Each ledger file was rebuilt as main's text followed by #54's own appended text, both proven pure appends to a5d8474's. The code and tests were byte-identical to 25ca646's; `make test` and the three mutants ran again on the rebased tree. It was force-pushed with the lease read from `ls-remote`.
- **Merged** with `--match-head-commit` and without `--delete-branch`, from this session's worktree, since the shared checkout held main. The squash tree (4d2aae4) is identical to the tested tip's, f8623bf, and its parent is 6bf3c34.
- **Local main** was caught up in the shared checkout, clean and with its session idle, by a fast-forward through `git -C`.
- **CI.** Both runs were the billing block, the `linux` job with 0 steps: 36324869520 (as opened) and 36326632003 (rebased).
- **Branches.** Deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-four suites, 880 expected passes, exit 0. NEXT is unchanged: the M4 exit.

M4 EXIT (plan §8, §10, §12). Branch feat/m4-exit, cut from main at 64e9a3b; 2026-09-27, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. Mutation log: m4-mutations.md, "The M4 exit".

Gathered before the first test, from the brief's M4 gate, plan §8, §10 and §12, and design §7.5:
- the brief's gate: curl and ab get correct responses, the counters return to zero, and the contract test passes;
- plan §8: the table is reconciled against `uv-loop-live-handles` at one place in the run loop, and the per-connection budget is re-measured against design §7.5's 16,384 + 264 + 1,072 and recorded, which discharges §12's risk 2;
- plan §10: the amendment slicing M5–M8 is part of M4's close-out.

Met before this branch, each with its check:
- the contract test: `tests/test-contract.sps` (M4.4), in `make test`;
- the reconciliation: `shell-run!` reconciles after a callback's error (M4.2; decision 0003 item 4), watched to fail by M4.2-C and M4.3-S2;
- "the counters" are chez-libuv's dev-build counts, which the socket lane has read at its end since M4.2.

MEASURED before the decisions (scratch):
- curl and ab as child processes on the server's own loop, through `uv-spawn!` and a pipe: curl four times and ab twice over 500 requests took 368 ms and 712 loop iterations. Every answer was correct. After them the table was empty and chez-libuv counted the listener alone; after the shutdown, nothing.
- A server holding 100, then 500, idle keep-alive connections from a Python client in its own process: its heap grew by about 1.5 KB a connection, and no more after 50 or 200 GETs each. Outside the heap are the read buffer, 16,384 B, and `uv_tcp_t`, 264 B.

DECIDED on the owner's word (2026-09-27), by form, the recommended answers:
- **The client suite runs in `make test`,** and CI installs curl and ApacheBench (`apache2-utils`). macOS ships both. A client that cannot be started fails the suite with status 2, by name. Weighed: a target of its own, `make test-clients`, outside `make test`.
- **The per-connection budget is recorded, not gated.** Weighed: holding a connection's heap to 2 KiB in `make test`, with python3 holding the connections.

BUILT:
- `tests/test-clients.sps`, new: a server started as `serve` starts one, and curl and ab each run as a child process on its loop, every wait capped by an iteration count. It checks:
  - curl: two GETs, two HEADs and two POSTs with a body, each second one on the first's connection (curl's `num_connects`), and two HTTP/1.0 GETs, each on a connection of its own. For the HEADs, the fields a GET's answer has and no content, their Date lines set aside;
  - ab: 200 requests 8 at a time, and with `-k` all 200 kept alive, none failed, none answered other than 2xx, and 4-byte documents;
  - the counters: with every client gone, the table is empty, the listener is the one handle left, and the server logged only `listening`. After the shutdown nothing is left on the loop, and chez-libuv counts no TCP handle, read buffer, write request, pipe or process.
- `(shell-testing)`: `run-until-drained`, a wait until nothing but a timer is live (below).
- `tests/test-view.sps`: #54 merged, so the host row sends `Host: h \t` through the core, where it built its request by hand.
- CI installs `curl` and `apache2-utils`.
- `.plans/research/spike/m4-exit-budget.sps` and `m4-exit-hold.py`, new, with two runs in `out/`: the per-connection budget against the real shell.
- Records:
  - design §7.5's note: about 18.2 KB a connection against the table's 17,720 B, and a parser keeps 592 B, where the table counted the 1,072 B that making one allocates;
  - plan §8's M4 exit note, and §12's risk-2 row;
  - the research README;
  - `docs/configuration.org`: an open connection holds about 18 KB, so 10,000 hold about 180 MB;
  - README's status: M4 is done.

MEASURED, the budget (`out/m4-exit-budget.run{1,2}.txt`): the heap per held connection, over sixteen readings after 1, 10, 50 and 200 GETs each, is 1,490 to 1,707 B, median about 1,540 B, with no trend in the GETs. The parts, made fresh, are:
- the core's state with its head and target judge: 192 B;
- the adapter's context: 32 B;
- a parser: 592 B;
- chez-libuv's TCP handle: 200 to 240 B.
The rest, about 500 B, is not broken down. So an idle connection holds about 18.2 KB, 16,384 B of it the buffer.

Found and fixed:
- **`tests/test-serve.sps` waited out its caps** (M4.5's). Its two waits for an empty loop could never be satisfied, since the 1 ms ticker that keeps the loop awake is live while it waits. Each ran to its 4,096 iterations: 10.5 s of the suite's 11.1 s. Both now wait until nothing but a timer is live (`run-until-drained`), then check the loop is empty. The suite takes 0.60 s, and the client suite, which first copied the pattern, 0.73 s.
- **A missing client failed as a check, not as the harness.** SRFI-64 turns a raise inside a check into a failure, so with ab off PATH the suite exited 1. Now both clients run once with their version flags before any check, and with ab off PATH the suite exits 2, naming it. The mutants M4X-A to M4X-I ran again on the final suite and turned the same checks red.
- **ab does not hold a body to its Content-Length.** With every Content-Length one byte short (M4X-I), ab reports every request complete, none failed. curl's four checks go red. So curl's checks are the ones that see framing, and ab's see concurrency, keep-alive and completion. A and B redden ab's.

Watched to fail (m4-mutations.md): M4X-A to M4X-I each redden the client checks they break, and every check of the suite is reddened by at least one. O2b and HW-Ab, run again, redden the view's host row, now also when the Host judge refuses the value.

`make test` green: thirty-five suites, 891 expected passes (clients 11), exit 0, 16.0 s.

THE AMENDMENT (plan §14, this branch): M5–M8 sliced against what M2–M4 measured. First a sweep (a subagent's extraction) of the ledger, the decisions, the design, the docs and the code, for what each milestone was left. Each item was checked against the tree before it was written.
- **M5, three slices:** the wheel and its two limits; the tick rows the core lacks (`body` answers 408, `responding` closes); one timer per loop, in both shells.
- **M6, four:**
  - how a handler reads a body, decided first (public API, measured and settled by form, as 0012 was), with the buffering helper and brief risk 3's pinned tests;
  - the read side's credit;
  - a streamed response, with the write watermarks and M3.2's carried close-delimited arm;
  - Expect and trailers, with libhtp's two Expect files.
- **M7, three:** the scheduler and the phase cell (R1, R2, R3, R5); what a handler awaits, decided first (R4); the coroutine shell in the contract test.
- **M8, four:** the drain; the hand-off door, decided first; the black-box and robustness lanes; load, and the release.
- **Found:** decision 0007 item 3 put Kestrel's `HttpParsingData` tables, and httpd's `http_strict.t` and lighttpd's `request.t` cases, in M2. No slice held them, and M2 closed without them. §14 puts them in M8.3's robustness lane.
- **Already done, though the sweep reported it open:** every entry into `responding` has armed the write deadline since M3.2 (`respond`), so the ledger's M2.1 item on the three error entries is settled.
- **Left open, and not sliced:** 0004 item 3's alternative; trimming a value once, in the core (0012's amendment); the lenient fixtures; CI's billing.

NEXT: the PR, on the owner's word: feat/m4-exit, the checks, the budget and the amendment. At the merge, M4 is complete.

MERGED to main on 2026-09-27, on the owner's "do the closing ritual": **#57, the M4 exit,** as 21d041f.
- The squash tree (ecdcaf2) is identical to the tested tip's, cf6388b, and its parent is 64e9a3b.
- **CI.** The run (36330741760) was the billing block, the `linux` job with 0 steps.
- **Branches.** Deleted local and remote, and refs pruned. No PR is open.

`make test` green on main: thirty-five suites, 891 expected passes, exit 0.

M4 COMPLETE and merged (21d041f, PR #57): the libuv shell and the first real server. It took twelve PRs, #46 to #57, merged on 2026-09-26 and 2026-09-27. Among them, #50 and #51 are notes for M8, and #54 is the Host fix. The exit criteria are met on main:
- curl and ab get correct responses, and the counters return to zero (`tests/test-clients.sps`);
- the contract test passes (`tests/test-contract.sps`);
- the table is reconciled against `uv-loop-live-handles` in one place, `shell-run!`;
- the per-connection budget is re-measured and recorded, at about 18.2 KB per idle connection;
- plan §14 slices M5–M8. m4-mutations.md is complete, and `make check-imports` is clean.

The suite count went from M3's twenty-seven to thirty-five, adding clients, close-ownership, contract, exports, serve, server, shell and view.

NEXT: M5, timeouts and limits (plan §14):
- M5.1, the wheel and its two limits, `write-timeout-ms` and `tick-ms`;
- M5.2, the tick rows the core lacks;
- M5.3, one timer per loop, in both shells.

It starts on a fresh branch cut from main after this commit, when the owner asks.

