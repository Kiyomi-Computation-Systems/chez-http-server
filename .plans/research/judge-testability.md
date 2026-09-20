# Judge report — lens: TESTABILITY and fit with the house rules

Date: 2026-09-19. Judge lens: testability and fit with AGENTS.md (functional core /
imperative shell, TDD with mutation witnesses — "a test is finished when you have
watched it fail", "prefer a check to a comment", R6RS `.sls` with no shared include
bodies, portable across darwin/linux/windows). Weighted most heavily, in this order:

1. Can the connection semantics be exercised WITHOUT sockets by replaying the llhttp
   corpus at every chunk size?
2. Can every decision get a mutation that a named test notices?
3. How much of the code is pure?
4. How does the design slice into TDD milestones?

Everything below marked RE-RUN was executed by me on this machine today; the command
and verbatim output are in §2. Everything marked "proposal §N" cites a section of the
proposal file by heading (line numbers from `rg -n '^#{2,3} '`); everything marked
"spike EN" cites `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/spike-control-flow.md` by experiment and line.

House-rule sources read: `/Users/yuzu/github/chez-http-server/AGENTS.md` (whole file —
FCIS, "A test that passes whether the code is right or wrong is worse than no test",
"Prefer a check to a comment", R6RS `.sls`, "no shared include bodies", "R6RS forbids
assigning an exported variable — reach mutable state through procedures");
`/Users/yuzu/github/chez-http-server/.plans/chez-http-server-architecture.md:654-720`
(§14 Testing Strategy by Layer: for `chez-http1` "The result must not depend on TCP/read
fragmentation"; for `chez-http-server` the end-to-end socket list: keep-alive, pipelining,
chunked bodies, streaming, backpressure, slow clients, timeouts, disconnect during
read/write, graceful shutdown).

---

## 1. The live spike facts this judgement rests on

File: `.../research/spike-control-flow.md` (2297 lines). Lines cited.

| Spike | Lines | Fact used here |
|---|---|---|
| E1a | 274–366 (Observed 359) | `call/1cc` captured in timer A's callback, A **returns normally**, B invokes it: `attempt to invoke shot one-shot continuation` then `attempt to return to stale foreign context`; the trap is a bare `&assertion` escaping `uv-run` unwrapped. |
| E2a | 477–568 (Observed 562) | Same with full `call/cc`: A's body resumes inside B, then trapping on the normal return through A's trampoline. |
| E2c | 662–734 | After the trap the loop is still runnable and teardown is `ok`. |
| E3 / E3b | 736–1002 | Two-level loop (coroutines started from top level; callbacks only enqueue; scheduler alternates ready queue with `uv-run 'once`) works over TCP through nested Scheme frames; 30–36 ns per suspend/resume, `call/1cc` and `call/cc` indistinguishable; ~13 µs per cycle including a 0 ms timer and one `uv-run 'once`. |
| E4c | 1156–1638 (Observed 1636) | Engine expiry INSIDE a libuv callback does not stale the frame but leaves `uv_run`'s C frames suspended for 200 slices. |
| E4d | 1640–1746 | The expiry's non-local exit clears chez-libuv's `loop-running` flag via `dynamic-wind`, so a nested `uv-run` is **accepted** and re-enters libuv's `uv_run` (forbidden by libuv docs); "no crash in 2/2 runs ... an absence of a symptom, not evidence of safety". |
| E5b2 | 1926–2046 | `uv-write!` from a second OS thread: hang, lost data, `invalid memory reference`, registry corruption at teardown — 4/4 runs fail. |
| E5c | 2048–2135 | Loop thread blocked in plain `uv-run` freezes every other thread's collection: 27 ms of worker allocation took 10.27 s with a 300 ms poll, 92 ms with a 1 ms poll. |
| E6 | 2137–2281 | `uv-run` from inside `on-data` raises `&uv-invalid-argument who: uv-run reason: loop-running`, synchronously, catchable in the callback. |
| Conclusions | 2283–2291 | Items 1–7. Item 2 states: "Any design that stores a callback-captured continuation must never invoke it -- there is no way to make it valid." **I treat item 2 as over-generalised** (see §2.2 and §4.4 below): every experiment behind it (E1a/E1b/E2a/E2b) *returns normally* through the stale callback; the promise proposal's discipline never does, and its M2 reproduced today. |

## 2. What I re-ran today (commands and verbatim output)

Toolchain: `chez` 10.4.1 threaded tarm64osx, libuv 1.52.1, chez-libuv v0.5.0 shim built, `gtimeout` present (spike-control-flow.md:9-18).

### 2.1 Sans-I/O prototype, socket-free shell — RE-RUN

Command:
```
S=/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike
gtimeout 300 chez --libdirs $S:/Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src --program $S/sansio-shell.sps 2>&1 | rg -v '^(HTTP/|Content-|Connection:|echo |$)' | tail -40
```
Output (verbatim, wire-byte echo lines filtered by the `rg -v`):
```
whole-buffer trace: ((feed-parser) (call-handler 1 "/aaa") (call-handler 2 "/bbb") (call-handler 3 "/ccc") (write 49) (write 49) (write 49) (close eof))
closed: eof
ok   pipelined: identical output at every chunk size 1..135 (sync)
lifo response order (handler side): (3 2 1)
ok   pipelined: handlers responded newest-first, wire order still 1,2,3
cap=2 trace: ((feed-parser) (call-handler 1 "/aaa") (call-handler 2 "/bbb") (read-stop) (write 49) (write 49) (resume-parser) (feed-parser) (call-handler 3 "/ccc") (read-start) (write 49) (close eof))
ok   cap=2: output identical
ok   cap=2: parser paused and read stopped, then resumed, remainder fed, read restarted
ok   cap=2: identical output at every chunk size (lifo)
close then data, whole buffer: trace=((feed-parser) (call-handler 1 "/") (read-stop) (write 64) (close done)) closed=done
output:

ok   Connection: close -- exactly one handler call, one response, then close
ok   Connection: close at chunk=1 -- second request never fed to the parser
raw parser on close-then-data: status=error consumed=47 next=47 error=(closed-connection "Data after `Connection: close`" 47)
ok   HTTP/1.0 no keep-alive: response then close
handler raise: HTTP/1.1 500 OK

handler failedok   handler raise: 500 written, connection stays open until the fake client's EOF
parser error: trace=((feed-parser) (feed-parser) (feed-parser) (feed-parser) (feed-parser) (feed-parser) (feed-parser) (read-stop) (write-status 400) (close parser-error)) closed=parser-error
ok   parser error: 400 and close
ok   eof while handler pending: response still written, then close
allocation (core+adapter+parser+fake shell, sync handler, 1 request/delivery): 2000 requests, 28108512 bytes total, 14054 bytes/request
ok   2000 keep-alive GETs answered
allocation (pure core only, 14 parser events + response + write-completed per request): 6832 bytes/request
failures: 0
```
Matches the proposal's §12.1 (async-sans-io-state-machine.md:351-400) byte for byte on every `ok` row.

Purity inspection of the core (RE-RUN):
```
sed -n 1,60p $S/sansio/core.sls          # -> (library (sansio core) ... (import (rnrs))   ; only import
rg -n 'set-|set!|vector-set!|hashtable' $S/sansio/core.sls     # -> (no output)
rg -n 'uv-|libuv' $S/sansio/core.sls     # -> 6:;;; No libuv, no parser object, no sockets, no clock. ...
```
The core imports only `(rnrs)` and contains no mutation at all; the adapter
(`$S/sansio/adapter.sls:1-70`) holds the mutable cell, the run-to-completion queue with a
depth counter, and `reply->outcome` (`continue`→`callback-continue`, `pause`→`callback-pause`,
`skip-body`, `(fail code)`→`make-callback-failure`).

### 2.2 Promise proposal, continuation captured in callback A and resumed from B — RE-RUN

Command:
```
S=.../scratchpad/spike-promise; export CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs
gtimeout 60 chez --program $S/await-timer.sps guarded    # head -12 and tail -3
gtimeout 60 chez --program $S/await-timer.sps unguarded  # tail -8
gtimeout 60 chez --program $S/stale-detail.sps           # tail -6
```
Output (verbatim):
```
== guarded
(scenario guarded outcome ran-dry rounds 1000 ms 1279)
  A-enter
  (A-step suspended)
  A-return-to-C
  B-enter
  (resumed-with 0)
  (caught-after-resume "after-resume")
  (B-step finished)
  B-return-to-C
  A-enter
  (A-step suspended)
  A-return-to-C
== guarded tail
  B-return-to-C
(live-handles 0)
teardown ok
== unguarded
(scenario unguarded outcome (uv-run-raised other attempt to return to stale foreign context) rounds 0 ms 2)
  A-enter
  (A-step suspended)
  A-return-to-C
  B-enter
  (resumed-with 0)
(live-handles 2)
(teardown-raised #<compound condition>)
== stale-detail
uv-run raised: (uv-callback-error? #f error? #f who #f message attempt to return to stale foreign context irritants ())
(deferred ())
(second-uv-run (raised callback-error? #t cause boom))
teardown ok
```
Reading: with the discipline "every suspension and completion escapes to the
*dynamically current* callback root and never returns normally into the capturing
callback's frames" (async-promise-combinators.md §4.1–4.2, lines 236–317), 1000
capture-in-A / resume-in-B rounds ran dry and tore down cleanly. Without the
library catch-all (M3), one raise after resumption reaches the capturing callback's stale
`dispatch-guarded` guard and the trap escapes `uv-run` as a bare condition. So the live
spike's E1a/E2a refute the *naive* form (resume then return normally); they do **not**
refute the promise proposal's disciplined form, which I reproduced. The disciplined form
is nonetheless one escaped raise away from the trap, and the trap is not wrapped in
`&uv-callback-error` (stale-detail output above), so the binding cannot contain it.

### 2.3 CPS socket-free core — RE-RUN

Command:
```
gtimeout 120 chez --libdirs /Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src --program $S/cps-core.sps
```
Output (verbatim):
```
1a status=paused consumed=28 (first message is 29 bytes) offset=28
1a resume -> feed-ready
1b status=paused consumed=28 offset=56
1b events of 2nd message (oldest first): (begin method url protocol version field value (headers-complete flags 0 cl 0) complete)
1b urls: (/a /b)
2 whole-buffer: pauses=2 body="hello world"
2 every chunk size 1..60: body identical=#t, coalesced-event-sequence identical=#t, distinct pause counts=(2 3 4 5 7 12)
3 status=error consumed=47 done=1 close?=#t
3 error code=closed-connection reason="Data after `Connection: close`" offset=47
3b with pause-on-complete: status=paused consumed=46 (first msg = 47 bytes) close?=#t
4 bytes allocated per request (parser + builder copies of method/url/3 headers): 2672
4b bytes allocated per request, parser alone (silent bindings, no pause): 1600
```
Structure check: `rg -n 'import' $S/cps-core.sps` → `9:(import (rnrs)` plus httparse/byte-machine
(no libuv); but the "core" here is a mutable builder (`rb-note!`, `rb-events-set!`,
`cps-core.sps:31-41`) driven by 25 closures, **not** the pure `conn-step` promised in the
proposal's §13 (async-cps-callbacks.md:519-578). The pump/driver (§5.3, lines 284-323) was
only exercised with sockets (`cps-server.sps`, Appendix A.3, lines 767-805).

### 2.4 Two-level coroutine spikes — RE-RUN

```
== guard-across-await
coroutine-1 run -> finished
guard-inside-coroutine caught after resume: (caught after-resume)
dynamic-wind in=2 out=2
coroutine-3 run -> (scheduler-guard-caught uncaught-in-coroutine)
== pipeline-pause (head)
(status paused consumed 51 offset 51 error #f)
first message ends at byte 51 of 117
resume -> feed-ready
(status paused consumed 47 offset 98 error #f)
second message ends at byte 98
resume -> feed-ready
(status error consumed 1 offset 99 error (closed-connection Data after `Connection: close` 99))
  (on-message-begin)
== two-level
405 a-after-400
elapsed-ms=405
uv-run-calls=6
uv-run-blocked-ms=405
verdict: BLOCKED-IN-UV-RUN-NO-BUSY-LOOP
```
(Commands: `gtimeout 60 chez --program $S/guard-across-await.sps`; `gtimeout 60 chez --libdirs
<httparse dirs> --program $S/pipeline-pause.sps | head -8`; `CHEZSCHEMELIBDIRS=<libuv dirs>
gtimeout 60 chez --program $S/two-level.sps | tail -5`.) All match async-two-level-coroutines.md
Appendix A (lines 583–710). Note: none of these replays the *connection layer*; the
connection coroutine (§8.3, lines 419-437) exists only as a sketch.

### 2.5 Engines spikes — RE-RUN

```
== sched-spike
scheduler: (idle 70)
  (done (two-awaits timer-fired timer-fired))
  (done hog-finished)
  (done (resolver (dns-ok 2 "::1")))
  (done (sleeper timer-fired hog-progress-when-woken 299999))
loop open after teardown? #f
== bench2 (selected)
nested: (raised cannot nest engines ())
raise inside engine reaches caller: (caught boom)
guard inside engine: caught-inside
dynamic-wind log after block: (in out)
after resume+complete: body -> (in out in out)
parameter while engine blocked: outside
parameter after resume: inside
```
(Commands: `CHEZSCHEMELIBDIRS=<libuv dirs> gtimeout 60 chez --program .../engines/sched-spike.sps | tail -8`;
`gtimeout 120 chez --script .../engines/bench2.ss | rg 'nested|dynamic-wind|after resume|raise inside|guard inside|parameter'`.)
Matches async-engines.md §12.2/§12.5 (lines 770–850). No parser and no TCP under the
scheduler (the proposal admits this: §14 item "The feasibility spike exercised timers and
DNS but not TCP reads/writes").

### 2.6 chez-httparse harness exports the proposals lean on — VERIFIED

```
cd /Users/yuzu/github/chez-httparse && ls test/support/harness/httparse/test/
adapter.sls conformance.sls corpus-decode.sls corpus-load.sls drive.sls fingerprint.sls generate.sls harness.sls oracle.sls prng.sls ratchet.sls trace-format.sls
```
`corpus-load.sls:29-37` exports `corpus-parse-file fixture? ... fixture-input-text fixture-expected fixture-meta-ref ... fixture-init-words fixture-lenient-flags`;
`conformance.sls:21-24` exports `corpus-scan-sizes corpus-chunk-bounds trace-compare mismatch? ...`;
`drive.sls:19-20` exports `drive-trace drive-init drive-refusal? drive-refusal-detail drive-chunk-ladder drive-feed! drive-requested-pause?`;
`adapter.sls:21-31` exports `adapter-event-for ... make-trace-recorder trace-recorder-bindings trace-recorder-events ...`.
So the corpus-at-every-chunk-size lane that five of the six proposals describe is buildable
from existing, R6RS `(rnrs)`-only harness libraries (`corpus-load.sls:38` `(import (rnrs))`).

---

## 3. Scoring rubric applied

Each criterion 1–5 (5 best). Under this lens `testability_fcis` carries the most weight,
then `correctness_under_chez_libuv_constraints` (a design whose tests cannot be
deterministic, or whose safety rests on a discipline no test can pin, loses here too),
then the rest.

## 4. Per-proposal judgement

### 4.1 `sans-io-state-machine` — rank 1

- **Corpus without sockets (weight 1):** DEMONSTRATED, not just planned. The same
  `conn-step` core produced identical wire bytes and an identical `call-handler`/`close`
  sequence at every chunk size 1..135 of the llhttp `pipelining.md` buffer, under a cap of
  2 (pause + read-stop + resume + feed remainder + read-start), for `Connection: close`
  followed by data at chunk=1, HTTP/1.0, handler raise → 500, parser error → 400+close,
  EOF with a request in flight — 13/13 rows, re-run by me (§2.1). The full-corpus plan
  (§12.4, lines 460–468) reuses `trace-recorder-bindings` and `corpus-chunk-bounds`
  (verified exported, §2.6) and asserts (a) the parser trace is unperturbed by the
  connection layer and (b) the connection outcome is chunk-size-invariant.
- **Mutation per decision (weight 2):** every `(state, event) → (state', actions)` cell is
  data; the proposal lists inversions that turn named rows red (§12.4 item 3: `keep-alive?`
  for 1.0 → `connection.md` "No restart when keep-alive is off (1.0)"; drop `(read-stop)`
  from the cap arm; serialise `Connection: close` at arrival time — "as it did"). The one
  bug the author hit (close header decided at arrival not at write time, §11 item 1, lines
  331-347) was found by the *loopback* test, which is the honest limit: the executor's
  contract is not covered without sockets (§11 item 2). Mitigation is a real check: the
  same action stream through the fake shell and the libuv shell must yield the same bytes
  (`libuv-shell.sps` vs `sansio-shell.sps` "compare the same three responses today").
- **Purity (weight 3):** the strongest of the six by inspection: `core.sls` imports only
  `(rnrs)`, contains zero mutation (§2.1). Parser callbacks are events; `reply-parser` is
  the only synchronous reply; every other effect is queued and executed after the
  outermost dispatch returns (§1.2, lines 64-73), which is *forced* by byte-machine's
  `reentrancy` and `poisoned` arms (`runtime.sls:998, :1057`) and by chez-libuv's `uv-run`
  re-entry refusal (spike E6). The cost: naive purity is 6.8 KB/request (§10) and the
  proposed fix ("linear mutable accumulator") makes the core pure by contract (§11 item 8).
- **TDD milestones (weight 4):** natural: pure tables → adapter → fake shell + corpus →
  libuv shell + contract test → limits/deadlines with a fake `(tick now)` → server-step
  shutdown table ("SIGTERM with 3 connections, one mid-body, deadline 2 s" is a table test,
  §8). Both shells already exist as prototypes.
- **House rules:** no continuation, thread or engine anywhere; every executor arm guarded;
  unknown-event arms are `assertion-violation`s (a check); R6RS `.sls` libraries with
  `#!r6rs`; nothing OS-specific.
- **Weaknesses on this lens:** wide event alphabet (17 kinds × ~8 phases, §11 item 9) means
  many rows; streaming costs two `conn-step` round trips per chunk (§11 item 3); the
  credit-based pause inside `on-body-data` is "not corpus-covered for this exact site"
  (§11 item 5) and must be pinned by a connection-layer replay before it is relied on;
  handler ergonomics are callback-style.
- **Chez assumptions:** A1–A11 (§13, lines 469-483); none load-bearing on the live spike;
  A2 explicitly not relied upon and consistent with E1a/E2a.
- **Fatal flaw:** none.
- Scores: simplicity 3, correctness 5, testability 5, backpressure 4, performance 3, extensibility 4.

### 4.2 `two-level-coroutines` — rank 2

- **Corpus without sockets:** PLANNED (§16 lane 2, lines 525-545): `poll!` is the single
  injection point (§4, line 125-131: "`poll!` is the *only* injection point the tests
  replace"); each `corpus-chunk-bounds` slice becomes one `on-data` delivery = one
  scheduler turn; recording handler + `adapter-event-for` + `make-trace-recorder` +
  `trace-compare`. Feasible (exports verified §2.6) and deterministic (single thread, scripted
  poll). Not demonstrated: the connection coroutine (§8.3) is a sketch; the spikes cover the
  scheduler (M1), continuation cost (M2/M3), parser pause boundaries (M4) and guard
  semantics across a park (M5) — all re-run by me (§2.4) — and the live spike's E3 is
  exactly this shape over TCP (spike lines 736-935).
- **Mutation per decision:** the best "check, not a comment" story of the six: a `phase`
  cell asserted by `park!`/`await!` (R1/R5, lines 67-71, 108-128, 182, 345), a one-shot
  `fulfil!` (R4), an `rg` gate in `make test` that `uv-close!` appears nowhere but
  `connection-close!` (line 517), and a named mutation list including "call a handler from
  inside `on-data` (the R1 phase assertion)" and "let `connection-main` return normally
  instead of `(sched-k 'finished)` (M6 reproduces as a crash)" (line 542). A forgotten
  resume is a parked coroutine the scheduler can see, not a silent hang.
- **Purity:** medium. The listed pure core (§16: builder steps, serialiser, `conn-step`,
  `read-decision`, `write-admission`, wheel, limits) is real, but the *sequencing* of the
  connection lives in `connection-main` (§8.3) as control flow on a coroutine stack, so the
  chunk-invariance lane runs through scheduler + coroutine + parser rather than through a
  table. That is more machinery under test than the sans-I/O core and it is why this ranks
  second, not first.
- **TDD milestones:** scheduler with stubbed `poll!` (no libuv at all, "M1's script is the
  template") → transport record of six verbs → connection coroutine → corpus lane → socket
  lane. Clean.
- **Correctness under the binding:** never captures a continuation inside a callable
  (R1/R2), which the live spike E3 confirms works and E1a/E2a confirm was the right thing to
  avoid; a raise from application code can never reach `dispatch-guarded` (§13: "the single
  biggest robustness argument"). `dynamic-wind` winders re-run per park (M5 `in=2 out=2`) —
  documented as a rule, which is a comment not a check; a counting-winder test would fix that.
- **Weaknesses on this lens:** R1/R2/R5 are policed at runtime (§19 item 1); 3.4–5.6 KiB
  resident per parked coroutine (M3) and unmeasured major-GC cost at 10k; no `uv_async`, so
  no cross-thread wake (§19 item 4).
- **Fatal flaw:** none.
- Scores: simplicity 3, correctness 5, testability 4, backpressure 5, performance 4, extensibility 5.

### 4.3 `cps-callbacks` — rank 3

- **Corpus without sockets:** PARTLY DEMONSTRATED (§2.3): parser + builder replayed at every
  chunk size 1..60 with identical body and coalesced event sequence; pipelining boundary via
  `consumed=28`; close-then-data with and without pause. The *pump* (§5.3) — where the cap,
  read-stop/read-start and parse-ahead decisions live — was only run with sockets
  (Appendix A.3). §13 (lines 519-578) promises a pure `conn-step : ConnState Event ->
  (values ConnState (Listof Command))` with a socket-free corpus lane; that is, in its final
  form, the sans-I/O core with a CPS shell — but it is asserted, not prototyped.
- **Mutation per decision:** good and grounded in real failures (§13 "Mutation discipline":
  invert `(< queue-length cap)`, drop `resumed?` re-feed → zero-width-step test "fails
  against the first spike version and passes against the second: watched to fail"). The
  weakness is structural: continuation arity and exactly-once are "unchecked by the
  language" (§16 item 1, lines 651-660); `once` catches a double call at runtime, but "nothing
  catches a forgotten call except `response-timeout`" (line 657-658) — a class of handler
  bug that only a wall-clock timeout notices, which is the opposite of a named red row.
  The arity slip in Appendix A.3 run 1 stopped the whole loop.
- **Purity:** proposed (§13) rather than shown; the spike's builder is mutable. Handler code
  is closures with explicit request context (no dynamic extent across a step, §16 item 3).
- **TDD milestones:** combinators (pure, ~60 lines, unit-testable) → core → driver → server;
  the smallest shell of the six ("the binding is already CPS").
- **Correctness:** captures nothing; relies only on what chez-libuv itself relies on (§15).
  Hazard: "every boundary needs `cps-guard`" (§16 item 5) — one missed guard stops service
  for all connections; the proposed `strict` mode makes that a deterministic test failure,
  which is good.
- **Fatal flaw:** none.
- Scores: simplicity 4, correctness 5, testability 4, backpressure 4, performance 5, extensibility 3.

### 4.4 `promise-combinators` — rank 4

- **Corpus without sockets:** PLANNED (§13.1, lines 743-773) with a genuinely good device:
  the core emits `(settle tag v)`/`(reject tag c)` with opaque tags, so the replay lane
  constructs no promise at all. Not demonstrated (spikes are parser-pause and continuation
  experiments only).
- **Mutation per decision:** §13.4 rows are concrete and one of them is the M3 failure
  ("remove the coroutine catch-all → M3 reproduces"). But two properties cut against the
  house rule "a test that passes whether the code is right or wrong is worse than no test":
  (i) a rejection nobody observes is silent by default and the `unhandled-rejection-hook`
  fires only at drain end and "can report spuriously when a reaction is attached in a later
  step" (§16 item 4, lines 914-917) — a flaky oracle; (ii) the Tier 1 safety rule is
  runtime-only and the failure is a bare `&assertion` escaping `uv-run` that `&uv-callback-error`
  does not wrap (§2.2 stale-detail).
- **Purity:** Tier 0 core is pure (proposed); the promise library is pure given an explicit
  `(run-microtasks!)`; the microtask FIFO "is honestly a scheduler in miniature" (§3.2).
- **Correctness under the binding:** Tier 0 is as safe as CPS. Tier 1 (`await`) rests on A1.
  The live spike's Conclusion 2 declares any invocation of a callback-captured continuation
  invalid; the experiments behind it (E1a/E1b/E2a/E2b) all *return normally* through the
  stale callback, which the promise design forbids by construction (§4.1-4.2). I re-ran the
  promise's M2/M3 today (§2.2): 1000 rounds clean under the discipline, immediate trap
  without it. **So A1 is not refuted, but Tier 1 is one escaped raise from a trap the
  binding cannot contain**, the suspended-segment memory is unmeasured (A6), and the
  live-spike author's reading of CSUG §4.4 and the promise author's reading disagree —
  exactly the kind of implementation-property dependence the house rules ask a check to
  pin. A single permanent test (M3 as a red row) can pin it; it must be in the first slice.
- **TDD milestones:** promise lib → core with tags → driver → optional Tier 1. Reasonable.
- **Fatal flaw:** none for Tier 0; Tier 1 is not refuted by the live spike (the spike tested
  a different discipline, §2.2) but is fragile and unmeasured at scale. Stated as such.
- Scores: simplicity 3, correctness 4, testability 3, backpressure 4, performance 4, extensibility 4.

### 4.5 `engines` — rank 5

- **Corpus without sockets:** PLANNED (§9.3, lines 599-630) via a fake transport record with
  scripted events and the same scheduler; feasible. Not demonstrated with a parser or TCP
  (§14 item last: "not yet measured end to end").
- **Mutation per decision:** §9.5 list is fine, but several engine-specific tests are
  tick-dependent by construction: "dynamic-wind churn ... assert the count equals
  slices+wakes" (lines 639-641) and preemption tests. Ticks are "decremented approximately
  once for each call to a nonleaf procedure" (A4) and "Your mileage may vary" (A10), so any
  code-path change moves slice boundaries — outcome tests stay valid, but boundary tests are
  brittle, which makes the mutation lane noisier than the others.
- **Purity:** as two-level (builder, serialiser, limits, wheel), with the parser pulled
  inside the engine.
- **Correctness under the binding:** this is where the live spike bites. E4c/E4d (spike
  1156-1746) show that an engine expiry landing inside a foreign callable leaves `uv_run`'s
  C frames suspended and clears chez-libuv's `loop-running` flag, so the binding's re-entry
  guard is defeated. The design's invariant E1 says no callback ever runs inside a slice —
  true for the scheduler's own `uv-run` — but a handler calling any verb whose callback
  fires synchronously (the `walk` trampoline inside `uv-loop-live-handles`, which the
  proposal itself notes "fires synchronously inside `uv_walk`") would put a callable under a
  slice with no check possible in the binding. Add "cannot nest engines" (A2, re-run §2.5),
  `parameterize` unwound at every block (A5), `set-timer` off limits (A3), and a 13 µs poll
  to amortise (§12.6). None of these is refuted; together they are the weakest fit with
  "prefer a check to a comment" because the dangerous cases are not checkable.
- **TDD milestones:** scheduler → engine body → transport seam → corpus lane. OK.
- **Fatal flaw:** none strictly. Preemption is the only thing engines buy (§13), and nothing
  in the house rules or the architecture plan asks for it.
- Scores: simplicity 2, correctness 3, testability 3, backpressure 4, performance 3, extensibility 3.

### 4.6 `threads-mailbox` — rank 6

- **Corpus without sockets:** PLANNED for the loop-thread half (§13.2, lines 1053-1084:
  `connection-step` with the parser inside, `drive-chunk-ladder` default lane, `'full`
  nightly). The handler half — pool, inbox, channels, wakeup — is admitted to be
  "inherently timing-dependent" (§11 item 6, lines 829-833: "a mutation lane that can still
  go red *by name*" is stated as a goal, not a property). Tests "fork real threads but wait
  with `condition-wait` + timeout and assert sentinel symbols" (§13.3).
- **Mutation per decision:** the memory-model rule "no `set!` on a shared record outside
  `with-mutex`" is enforced by a proposed reviewer lint (§11 item 7) — a comment-grade
  guarantee for a race that would be silent. Unkillable handlers (no thread cancel, §6)
  cannot be tested to a bound at all.
- **Purity:** the connection core is pure; everything that makes this angle distinctive is
  mutex-and-condition imperative code.
- **Correctness under the binding:** the design measured its own hazards honestly and the
  live spike confirms them: E5c (a plain `uv-run` freezes other threads' collections;
  10.27 s at a 300 ms poll) and E5b2 (cross-thread `uv-write!` corrupts, 4/4). Tier 1
  (1 ms heartbeat) works today at ~1 % idle CPU with a 1 ms GC stall ceiling; Tier 2 needs
  an unshipped chez-libuv change (`uv_async` + `__collect_safe` re-binding of `uv_run` and
  all thirteen trampolines) measured on darwin/arm64 only (§12.2) and explicitly "must be
  re-run under the house CI" (Linux).
- **TDD milestones:** actually well sliced (§14: `HTTP_WORKERS=0` inline-handler fallback is
  the single-threaded server), which is why this is not scored lower on milestones — but the
  angle's own payload arrives last and cannot be tested deterministically.
- **Fatal flaw:** none in the sense of a refuted assumption (it never relies on the
  continuation question; it measured the GC interlock itself). For this lens it is
  disqualifying that the load-bearing half is nondeterministic and gated on an upstream
  binding change.
- Scores: simplicity 2, correctness 3, testability 2, backpressure 3, performance 3, extensibility 3.

---

## 5. Ranking (testability lens)

1. `sans-io-state-machine`
2. `two-level-coroutines`
3. `cps-callbacks`
4. `promise-combinators`
5. `engines`
6. `threads-mailbox`

Why 1 over 2: only the sans-I/O core has *demonstrated* chunk-size-invariant connection
semantics with no sockets and no scheduler (§2.1), and its core is pure by inspection (§2.1
`rg` output empty). Why 2 over 3: the two-level design turns "forgot to call k" and
"handler ran under a C frame" into checks a test can flip (phase assertion, `rg` gate,
resume! else-arm), where CPS leaves exactly-once to a wall-clock timeout (§4.3). Why 3
over 4: CPS has no runtime-only hazard class the binding cannot wrap; the promise design's
Tier 1 trap escapes `uv-run` bare (§2.2) and its rejection oracle can be spurious. Why 4
over 5: the promise design's hazards are pinnable by one permanent red row (M3); the engines
design's hazards (expiry under a callable, E4c/E4d) are not checkable from Scheme. Why 5
over 6: engines are single-threaded and deterministic given a code path; the threaded half
of `threads-mailbox` is not.

---

## 6. Does a hybrid beat every single proposal? Yes.

**Recommendation: the sans-I/O core as the only home of connection semantics, shipped
first behind a direct-callback shell, then re-hosted under a two-level scheduler shell that
gives handlers direct-style `await` — both shells passing one contract test.**

Concretely:

- **Core (from `sans-io-state-machine`):** `conn-step : State × Event → State × [Action]`
  with the 25 parser callbacks as events, `reply-parser` as the one synchronous action,
  run-to-completion for everything else (§1.2). This is what makes criterion 1 true: the
  llhttp corpus at every chunk size replays through the core with no sockets and no
  scheduler (§2.1, §2.6). Take the CPS proposal's allocation discipline for it (shared
  binding list, 2.7 KB/request measured, async-cps-callbacks.md A.4/A.5) to bring the
  naive 6.8 KB/request down.
- **Shell v1 (from `cps-callbacks` / the sans-I/O `libuv-shell.sps`):** libuv callbacks
  build events and call `dispatch!`; the ~120-line executor maps actions to verbs; every
  arm guarded; `connection-close!` the only `uv-close!` site (an `rg` gate, from the two-level
  proposal §15). This is the already-prototyped path (sans-I/O §12.2: four pipelined
  requests, handlers answering 4,3,2,1, wire order 1,2,3,4) and it is the fallback if the
  scheduler slice slips.
- **Shell v1.1 (from `two-level-coroutines`):** callbacks only enqueue events on a
  per-connection inbox and wake; one coroutine per connection runs the *same* `dispatch!`
  loop over its inbox; the `call-handler` action runs the handler on that coroutine, so
  handlers get `await`/`request-read!`/`response-write!` in direct style through resume
  cells, with a `guard` that works across a park (M5, re-run §2.4). No continuation is ever
  captured under a C frame (live spike E3 is this shape), so the Tier 1 question is never
  asked. The scheduler is tested with a scripted `poll!` and no libuv (E3/M1 template).
- **Contract test:** the same scripted event stream through the fake shell, the direct
  shell and the coroutine shell must yield identical wire bytes and identical action traces
  (the sans-I/O proposal's §11 item 2 mitigation, promoted to a gate).
- **Excluded:** Tier 1 promise-style continuations captured inside callables (unrefuted but
  fragile, §2.2); engines (preemption not required; E4c/E4d hazards unpinnable); OS-thread
  handlers (nondeterministic tests; gated on an upstream chez-libuv change). Keep the
  threads proposal's `uv_async` + `__collect_safe` measurement (§12.2/12.4) as the ADR that
  reopens the question if CPU-bound handlers ever become a requirement.

Why the hybrid beats each single proposal *on this lens*:

| vs | the hybrid gains | at the cost of |
|---|---|---|
| sans-I/O alone | direct-style handlers and generic `await` (extensibility 4→5) with zero loss of core testability; a second shell doubles as an executor-contract oracle | ~200 lines of scheduler (itself testable without libuv) and ~3.5 KiB per parked connection |
| two-level alone | connection semantics become a table replayable without the scheduler (testability 4→5; purity up) | the coroutine no longer "owns" the parser; it just pumps events, which is simpler |
| CPS alone | exactly-once/arity discipline replaced by ordinary returns in handlers; the pure core is built rather than promised | a scheduler layer |
| promise | no dependence on A1; no silent-rejection oracle | the `then` combinators (can still be offered on top as sugar over resume cells) |
| engines / threads | determinism and checkable invariants | preemption / CPU parallelism, neither required |

**TDD slicing for the hybrid (each slice ends with a watched-to-fail row):**

- M0 — pure records and pins: `limits`, request/response records, response serialiser;
  a test that pins `F-CONNECTION-CLOSE = 2` etc. against `parser-field-ref 'flags`
  (the constants are not exported by chez-httparse, `grammar.sls:301-306`).
- M1 — `conn-step` tables: pipelining cap, in-order flush with LIFO handlers, `close-after`
  after `Connection: close`/HTTP/1.0, keep-alive from flags read inside
  `on-headers-complete`, deadlines with a fake `now`, `read-start` conjuncts one at a time.
- M2 — adapter + fake shell; the llhttp corpus at every chunk size via `corpus-parse-file`,
  `corpus-scan-sizes 'full`, `corpus-chunk-bounds`, `trace-recorder-bindings`,
  `trace-compare`; ratchet manifest for fixtures the connection layer intentionally changes
  (data-after-close, upgrade, limits). Pin the `on-body-data` pause/resume point here.
- M3 — direct libuv shell + loopback lane + the three-shell contract test (two shells at
  this point).
- M4 — scheduler with injectable `poll!`, phase assertion, resume cells, one-shot `fulfil!`;
  no libuv in its tests.
- M5 — coroutine shell over the same core; handler `await`; guard-across-park test; contract
  test extended to three shells.
- M6 — timing wheel, limits, 408/413/414/431 mapping, `server-step` shutdown table.
- M7 — the architecture §14 socket list (keep-alive, pipelining, chunked, streaming,
  backpressure, slow clients, timeouts, disconnect during read/write, SIGTERM drain), with
  iteration caps, never wall-clock.

---

## 7. Structured scores (as returned)

| key | simplicity | correctness | testability | backpressure | performance | extensibility | fatal flaw |
|---|---|---|---|---|---|---|---|
| sans-io-state-machine | 3 | 5 | 5 | 4 | 3 | 4 | none |
| two-level-coroutines | 3 | 5 | 4 | 5 | 4 | 5 | none |
| cps-callbacks | 4 | 5 | 4 | 4 | 5 | 3 | none |
| promise-combinators | 3 | 4 | 3 | 4 | 4 | 4 | none for Tier 0; Tier 1 not refuted (re-run §2.2) but fragile and unmeasured at scale |
| engines | 2 | 3 | 3 | 4 | 3 | 3 | none strictly; E4c/E4d hazards unpinnable |
| threads-mailbox | 2 | 3 | 2 | 3 | 3 | 3 | none refuted; disqualifying nondeterminism for this lens and gated on an unshipped binding change |

## 8. Files and URLs relied on

- Proposals (all read in full): `.../research/async-sans-io-state-machine.md` (501 lines),
  `async-two-level-coroutines.md` (746), `async-cps-callbacks.md` (834),
  `async-promise-combinators.md` (1162), `async-engines.md` (936), `async-threads-mailbox.md` (1131).
- Live spike: `.../research/spike-control-flow.md` (2297 lines), sections and lines in §1.
- Scripts re-run: `.../scratchpad/spike/sansio-shell.sps`, `spike/sansio/{core,adapter}.sls`,
  `spike/cps-core.sps`, `spike/guard-across-await.sps`, `spike/pipeline-pause.sps`,
  `spike/two-level.sps`, `.../scratchpad/spike-promise/{await-timer,stale-detail}.sps`,
  `.../scratchpad/engines/{sched-spike.sps,bench2.ss}`.
- House rules: `/Users/yuzu/github/chez-http-server/AGENTS.md`;
  `/Users/yuzu/github/chez-http-server/.plans/chez-http-server-architecture.md:654-720`.
- chez-httparse harness: `/Users/yuzu/github/chez-httparse/test/support/harness/httparse/test/{corpus-load,conformance,drive,adapter}.sls` (export lists quoted in §2.6).
- chez-libuv facts as quoted by the spike: `src/libuv/private/native.sls:242` (`uv_run` bound
  plain), `src/libuv/loop.sls:55-63` (re-entry refusal under `dynamic-wind`),
  `src/libuv/private/handles.sls:302-304` (`dispatch-guarded`), `:218` (unsynchronised registry).
- CSUG 10.0 foreign.html §4.4 (fetched by the spike, saved as `.../research/csug-foreign.html`,
  verbatim at spike lines 152-271): <https://cisco.github.io/ChezScheme/csug10.0/foreign.html>;
  control.html §6.3/§6.4: <https://cisco.github.io/ChezScheme/csug10.0/control.html>.
- libuv: <https://docs.libuv.org/en/v1.x/loop.html> ("uv_run() is not reentrant. It must not
  be called from a callback."), <https://docs.libuv.org/en/v1.x/design.html> (not thread-safe).
