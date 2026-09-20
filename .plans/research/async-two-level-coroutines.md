# Proposal: two-level loop with coroutines on one-shot continuations

- key: `two-level-coroutines`
- date: 2026-09-19
- machine: Chez Scheme 10.4.1 (`chez --version` → `10.4.1`), tarm64osx, libuv 1.52.1 (Homebrew), chez-libuv v0.5.0, chez-httparse v0.2.0, byte-machine v0.6.0
- spike scripts and verbatim outputs: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/` (Appendix A reproduces every command and output)

## 0. Thesis in one paragraph

A Scheme scheduler owns the top of the program. Each turn it (1) resumes every runnable coroutine to its next suspension point, then (2) calls `(uv-run loop 'once)` — which blocks in the OS poll until libuv has something to deliver — then repeats. libuv callbacks never run user code: each one appends an event to a per-connection inbox (or fulfils a one-shot "resume cell") and returns. Coroutines are built on `call/1cc`, and **every continuation is captured and invoked in frames the scheduler entered, never inside a `foreign-callable`** — so the open question "may a continuation captured inside a callable be invoked after the callable returned?" is sidestepped by construction rather than answered. One coroutine per connection owns the parser, the ordered response stream, and runs handlers in arrival order on its own stack; handlers are written in direct style (`request-read!`, `response-write!`, `await`), and a `guard` inside a handler catches raises that occur after an await (measured, §13). Idle behaviour is exact: "no coroutine runnable" ⇔ "every coroutine is waiting for a libuv callback" ⇔ blocking in `uv-run 'once` is correct; measured 6 `uv-run` calls over a 402 ms run with 100% of wall time spent blocked (§5).

Where this is worse than the obvious alternative (run the parser and handlers directly inside `on-data`): ~3.4–5.6 KiB of resident heap per parked coroutine (measured at 10k, §17), one extra continuation switch plus one queue operation per delivery (~24 ns + a cons, §17), a discipline that must be *checked* (callbacks never await; parser callbacks never await), and no way to wake the loop from another OS thread because `uv_async` is not bound (§19).

## 1. Sources read (with the facts each one contributed)

| Source | Facts relied on |
|---|---|
| `/Users/yuzu/github/chez-http-server/.plans/chez-http-server-architecture.md` | §5 connection is the central abstraction (lines 335–400); §7 backpressure crosses parser boundary via `uv_read_stop` (434–467); §10 pipelining policy: preserve order, cap outstanding (534–558); §11 limits list (561–588); §12 error classes (592–618); §13 target handler API `(lambda (request respond) ...)` (622–651); §14 test strategy per layer (654–716); "libuv owns I/O and scheduling" (758) — this proposal deliberately moves *scheduling* one level up and leaves *I/O* with libuv. |
| `/Users/yuzu/github/chez-libuv/docs/api.md` | `uv-run` modes and `#t` if work remains (line 18); `uv-stop!` legal inside a callback (19); `uv-read-start!` on-data `(bv start end)`, on-eof `()`, on-error `(condition)` all required (68); `uv-read-stop!` idempotent, keeps buffer and callbacks (69); read buffer 64 KiB committed at first `uv-read-start!`, freed by close (86, 117–121); the measured memory table 4096/16384/65536 → ~40/160/625 MiB at 10k (146–151); "4096 or 16384 are reasonable" for many small-message connections (174–177); read-stop must be guarded with `uv-handle-open?` (183–192); bounding write memory = outstanding payload bytes + outstanding request count, increment only after `uv-write!` returns, zero-length write costs a full block (194–206); write-queue gauge is a congestion signal, non-zero after a failed write on Unix, opposite meaning on Windows (208–223); "A second `uv-close!` silently discards its callback" (266–274); `uv-signal-start-oneshot!` and the SIGTERM drain pattern, disposition reverts to SIG_DFL (323–361); `uv-getaddrinfo!` `(loop node service [hints] on-complete)`, on-complete gets `(err results)`, completions delivered on the loop thread (370, 391–395); `uv-cancel!` semantics (372); timers `(timer on-timeout timeout-ms repeat-ms)` (422); `&uv-callback-error` composed with the cause (452). |
| `/Users/yuzu/github/chez-libuv/docs/quickstart.md` | The three rules: close is asynchronous (87–91); EOF is not an error (92–96); "A callback that raises does not cross into C. The first raise of a run is stored, the loop is stopped, and it is re-raised from `uv-run`" (97–101). |
| `/Users/yuzu/github/chez-libuv/src/libuv/loop.sls:50-64` | `uv-run` raises `'loop-running` on re-entry; runs `uv-loop-run` under `dynamic-wind` setting `loop-running`; then `deliver-pending-callback-error!` re-raises the stored error as `&uv-callback-error`. |
| `/Users/yuzu/github/chez-libuv/src/libuv/private/handles.sls:302-304` | `(define (dispatch-guarded loop thunk) (guard (e (#t (loop-record-error! loop e))) (thunk)))` — every callback body is guarded; a raise is recorded, never propagated into C. Lines 390–417: `read-dispatch` delivers `(copy-out (stream-read-buf handle) nread) 0 nread` — a fresh bytevector per delivery. Lines 421–433: `close-dispatch` deregisters, frees the read buffer and the handle, then calls `on-close`. Line 218: `(define registry (make-eqv-hashtable))` — unsynchronised. |
| `/Users/yuzu/github/chez-libuv/src/libuv/stream.sls:30-123` | `uv-write!` copies the payload into one foreign block and submits immediately (`uv-write-native`), raising synchronously on failure with no completion; `uv-read-start!` stores callbacks only after libuv accepts the start; `ensure-read-buffer!` fixes the size on the first start (`'buffer-size-fixed` on a differing later size); `default-read-buffer-size 65536` (line 73); `uv-read-stop!` goes through `require-open-stream` (119–123). |
| `/Users/yuzu/github/chez-libuv/src/libuv/dns.sls:78-107` | `uv-getaddrinfo!` case-lambda `(loop node service [hints] on-complete)`. |
| `/Users/yuzu/github/chez-libuv/src/libuv/handle.sls:98-104` | `uv-close! : uv-handle [procedure]`, "Idempotent and asynchronous. The first callback wins". |
| `/Users/yuzu/github/chez-libuv/src/libuv/timer.sls:30-45` | `uv-timer-start!` stores the callback before arming. |
| `/Users/yuzu/github/chez-libuv/spike/FINDINGS.md` | Q1: 10,000 re-entries from a blocking `uv_run` with `(collect)` on every fire, PASS; `uv_handle_size(UV_TIMER)` = 152, `uv_handle_size(UV_TCP)` = 264, `uv_req_size(UV_WRITE)` = 192 (probe output). Q2: `bare` scenario "An unhandled raise inside a `foreign-callable` **kills the process**" exit 255; `escape` scenario: a condition raised in a callback reaches a `guard` around `uv_run`, loop survives; the abandoned iteration's `UV_EOF` is *redelivered*; `uv_loop_close` with handles open = `-16 (EBUSY)`; "Deliberately untested: `__collect_safe` × callback re-entry". |
| ADR-0007 | No guardians; `uv-close!` is the only close path; `uv-loop-teardown!` closes what the registry knows. |
| ADR-0008 | Thirteen locked static trampolines, one per callback *type*; store-and-reraise retained "for determinism and for not leaving the caller an obligation they cannot see"; "guarding every trampoline body is mandatory". |
| ADR-0009 | Copy at the boundary; on-data span shape `(bv start end)` reserved for a future zero-copy variant; `uv__read` is a loop that overwrites the buffer right after `on-data` returns; read-stop does NOT make a retained span safe; write block freed *before* `on-complete`. |
| ADR-0018 | No bounded write queue in the binding; `uv-shutdown!` submits immediately so a Scheme-side queue would reorder FIN before data; consumer tracks bytes + count. |
| `/Users/yuzu/github/chez-libuv/tests/test-echo.sps:203-262` | The canonical server shape: per-connection closures over a peer record; on-eof → `uv-shutdown!` then `uv-close!` from the shutdown callback; on-error → `uv-close!`; `uv-accept!` failure caught with `guard` inside `on-connection` "a raise here would cross the callback boundary". Lines 300–330: read-stop from inside one delivery, read-start from inside a *different* client's delivery, guarded with `uv-handle-open?`. |
| `/Users/yuzu/github/chez-httparse/docs/api.org` | `make-parser : CompiledMachine (Listof (List Symbol Procedure)) Any [FieldInitials] -> Parser`; all 25 callbacks required; `parser-feed!` statuses `'need-input 'error 'paused 'finished 'stopped`; span callbacks index the caller's bytevector, "copy what you need before returning"; outcomes `callback-continue`, `callback-pause`, `make-callback-failure`; `on-headers-complete` may answer `'skip-body` and may pause; `on-reset` fires between pipelined messages; `type` must be given (`'request`); `lenient-flags` set once; `parser-field-ref` fields, `content-length` counts down so read it in `on-headers-complete`; `parser-resume!` changes lifecycle only; `parser-finish!` for EOF. |
| `/Users/yuzu/github/byte-machine/src/byte-machine/runtime.sls:978-1003, 1604-1686` | `parser-feed!` refuses a `busy` parser with `'reentrancy` and a `poisoned` parser ("a caller who fed a parser an escaped callback left behind"); `parser-reset!` is the only operation that revives a poisoned parser. → A parser callback must never escape (never await). |
| `/Users/yuzu/github/chez-httparse/test/support/harness/httparse/test/{conformance,drive,adapter,corpus-load}.sls` | Exports reusable for corpus replay through the connection layer: `corpus-parse-file`, `fixture-*`, `corpus-scan-sizes` (`'full` = every size 1..len, `'extremes` = 1 and len), `corpus-chunk-bounds`, `trace-compare`, `adapter-event-for`, `make-trace-recorder`, `trace-recorder-bindings`, `drive-chunk-ladder`. |
| `/Users/yuzu/github/chez-httparse/docs/conformance.org:40-44` | "Every in-scope fixture is replayed *at every chunk size from 1 to its length* and the parser's rendered trace is compared byte for byte." |
| libuv vendored docs `/Users/yuzu/github/chez-libuv/vendor/libuv/docs/src/loop.rst:122-133` | "UV_RUN_ONCE: Poll for i/o once. Note that this function blocks if there are no pending callbacks. Returns zero when done (no active handles or requests left), or non-zero if more callbacks are expected"; "UV_RUN_NOWAIT: Poll for i/o once but don't block if there are no pending callbacks." `async.rst:43-62`: `uv_async_send` "Wake up the event loop ... It's safe to call this function from any thread" — **not bound** by chez-libuv. `timer.rst:46-57`: "If the timer is already active, it is simply updated." |
| CSUG 10.0 `control.html` §6.3 (fetched; verbatim in Appendix B) | "One-shot continuations are continuations that may be invoked at most once"; "A one-shot continuation should not be returned to multiple times, either by invoking the continuation or returning normally from procedure more than once"; "A one-shot continuation is 'promoted' into a normal (multishot) continuation, however, if it is still active when a normal continuation is obtained by call/cc"; `dynamic-wind` "identical to the Revised6 Report dynamic-wind". §6.4 engines: `engine-block` "A new engine is made from the continuation of the call to engine-block and passed to the expire procedure." |
| CSUG 10.0 `foreign.html` §4.4 (verbatim in Appendix B) | "Chez Scheme handles this interaction in a general manner by trapping attempts to return to stale foreign contexts rather than by restricting the use of continuations directly. A foreign context is a foreign frame and return point corresponding to a particular call from a foreign language, e.g., C, into Scheme. A foreign context becomes stale after a normal return to the context"; "until some return to a foreign context is actually performed, all return points remain valid"; "the C stack pointer is not automatically restored to its base value when a continuation is used on the Scheme side to perform a nonlocal exit". §4.3: lock the callable's code object if "registered as a callback"; `__collect_safe` on a callable "activates a calling thread". |
| CSUG 10.0 `threads.html` (fetched) | `fork-thread`, mutexes, `condition-wait`/`condition-signal` exist; the page says nothing about continuations crossing threads. Not used by this proposal. |

## 2. Measurements made for this proposal (all on this machine, today)

| # | Question | Script | Result |
|---|---|---|---|
| M1 | Does a scheduler that drains ready coroutines then calls `(uv-run loop 'once)` block when idle and wake when a timer callback enqueues, without busy-looping? | `spike/two-level.sps` | Two coroutines sleeping 300+100 ms and 150 ms: events at 0/0/151/301/402 ms; `elapsed-ms=402 uv-run-calls=6 uv-run-blocked-ms=402`; verdict `BLOCKED-IN-UV-RUN-NO-BUSY-LOOP`. Continuations were captured only in scheduler-entered frames; the timer callback did `(uv-close! t)` then `(make-runnable! (lambda () (k 'woke)))` and returned. |
| M2 | Cost of a coroutine yield (capture k with `call/1cc`, jump to scheduler, scheduler resumes) | `spike/1cc-cost.sps` | `call/1cc` ping-pong: 24 ns/yield, 6–7 bytes/yield; `call/cc`: 28–29 ns/yield, 7 bytes; yield from 200 frames deep: 359 ns/yield, 0 bytes/yield amortised (1,000,000 iterations each). |
| M3 | Resident heap per parked coroutine at 10,000 parked | `spike/coro-memory.sps` | depth 4: 3449 B; depth 16: 3815 B; depth 64: 5635 B per parked coroutine (after `(collect (collect-maximum-generation))`). |
| M4 | Does returning `callback-pause` from `on-message-complete` give an exact pipelining boundary, and does data after a `Connection: close` message error? | `spike/pipeline-pause.sps` | Feed of 117 bytes containing POST(cl 3)+GET(close)+GET: first feed `(status paused consumed 51 offset 51)`; `parser-resume!` → `feed-ready`; second feed `(status paused consumed 47 offset 98)`; third feed `(status error consumed 1 offset 99 error (closed-connection "Data after `Connection: close`" 99))`. `on-headers-complete` saw `flags 32` (F_CONTENT_LENGTH) then `flags 2` (F_CONNECTION_CLOSE); `on-reset` fired before the second `on-message-begin`. |
| M5 | Does a `guard` inside a coroutine catch a raise after suspend/resume? How many times do `dynamic-wind` winders run per suspend/resume? Where does an *uncaught* coroutine raise land? | `spike/guard-across-await.sps` | `(caught after-resume)`; `dynamic-wind in=2 out=2` (one pair for the suspend/resume, one for normal entry/exit); uncaught raise → `(scheduler-guard-caught uncaught-in-coroutine)` — a plain Scheme `guard` in the scheduler, no foreign frame involved. |
| M6 | Two bugs found while writing M2/M3 that are design rules | `1cc-cost.sps`, `coro-memory.sps` first runs | A coroutine that *returned normally* from its body fell back into the scheduler's already-used one-shot: `Exception in +: go is not a number`. Rule R3 below: a coroutine ends by jumping to the scheduler's *current* k, never by returning. |

## 3. The model

### 3.1 Two levels

```
level 1  scheduler turn:   resume runnable coroutines until the ready queue is empty
level 2  libuv turn:       (uv-run loop 'once)   ; blocks until at least one callback lands
                           callbacks: enqueue events / fulfil resume cells / mark runnable; return
                           (uv-run returns)
level 1  scheduler turn:   ...
```

### 3.2 Invariants (each one is a check, not a comment)

- **R1 — callbacks do not run user code and do not capture or invoke continuations.** Every libuv callback registered by the server is one of a fixed set of library-owned closures (`on-connection`, `on-data`, `on-eof`, `on-error`, `on-write-done`, `on-shutdown`, `on-close`, `on-timer-tick`, `on-signal`, `on-dns`), each of which does O(1) work: push an event, adjust a counter, mark a coroutine runnable. Check: the scheduler sets a `phase` cell to `'in-uv-run` around `uv-run`; `await!`, `spawn-resume!` and the coroutine trampoline assert `(eq? phase 'scheduling)`, raising `&server-invariant` otherwise. Since the assertion is raised from inside a callback it would be stored by `dispatch-guarded` and re-raised from `uv-run` as `&uv-callback-error` — which the scheduler treats as a fatal bug (§13).
- **R2 — continuations are captured only on coroutine stacks entered from the scheduler.** The scheduler resumes a coroutine with `(call/1cc (lambda (k) (set! sched-k k) (resume-coroutine c v)))`; the coroutine suspends with `(call/1cc (lambda (k) (set-coroutine-k! c k) (sched-k 'suspended)))`. Between capture and invocation the only frames are Scheme frames. CSUG §4.4's "stale foreign context" cannot arise because no foreign context exists between the scheduler and any captured continuation.
- **R3 — a coroutine never returns normally; it ends with `(sched-k 'finished)`.** Measured consequence of violating it: M6. The coroutine trampoline is `(lambda () (guard (e (#t (set-coroutine-fault! c e))) (body)) (sched-k 'finished))`.
- **R4 — every continuation is invoked at most once.** Resume cells (§5.2) are one-shot: the second call is a recorded fault, not a second resume.
- **R5 — parser callbacks never await.** They return `callback-pause` and the coroutine awaits *after* `parser-feed!` has returned. Check: the same `phase` cell is `'in-parser` during `parser-feed!`; `await!` asserts it is not. (byte-machine independently poisons a parser whose callback escaped, `runtime.sls:1001`.)
- **R6 — exactly one procedure calls `uv-close!` on a connection handle** (§15).
- **R7 — single OS thread.** No `fork-thread`; `uv-run` is bound plain (spike FINDINGS "deliberately untested: `__collect_safe` × callback re-entry"); the handle registry is an unsynchronised `eqv-hashtable` (`handles.sls:218`).

## 4. The scheduler

Library `(http-server private scheduler)` — the imperative shell's smallest piece. The ready queue is a mutable FIFO (two-list queue, O(1) amortised). A coroutine is a record:

```scheme
(define-record-type coroutine
  (fields name
          (mutable k)          ; #f while running or finished; a one-shot continuation while parked
          (mutable state)      ; 'ready | 'running | 'parked | 'finished | 'faulted
          (mutable fault)      ; the condition an uncaught raise produced, or #f
          (mutable wake-value) ; value delivered by the resumer, read on resume
          conn))               ; owning connection or #f for server-level coroutines
```

```scheme
;; scheduler-run! : scheduler -> unspecified
;; Runs until the loop has no work AND no coroutine is runnable.
(define (scheduler-run! s)
  (let turn ()
    (drain-ready! s)                                    ; level 1
    (let ((more (poll! s (if (queue-empty? (scheduler-ready s)) 'once 'nowait))))  ; level 2
      (when (or more (not (queue-empty? (scheduler-ready s))))
        (turn)))))

;; drain-ready! resumes each coroutine that was ready at the START of the turn
;; (fairness: a coroutine that re-enqueues itself with yield! runs next turn,
;; after uv-run has had a chance to poll).
(define (drain-ready! s)
  (let ((n (queue-length (scheduler-ready s))))
    (do ((i 0 (+ i 1))) ((= i n))
      (resume! s (queue-pop! (scheduler-ready s))))))

(define (resume! s c)
  (scheduler-phase-set! s 'scheduling)
  (coroutine-state-set! c 'running)
  (let ((r (call/1cc
             (lambda (k)
               (scheduler-sched-k-set! s k)
               (let ((k0 (coroutine-k c)))
                 (coroutine-k-set! c #f)
                 (if k0
                     (k0 (coroutine-wake-value c))    ; parked -> continue after its await
                     ((coroutine-entry c))))))))      ; first run: trampoline, ends in (sched-k 'finished)
    (case r
      ((suspended) (coroutine-state-set! c 'parked))
      ((finished)  (coroutine-state-set! c 'finished))
      (else        (assertion-violation 'resume! "coroutine jumped to the scheduler with" r)))))

;; poll! : scheduler symbol -> boolean   ('once blocks; 'nowait does not)
(define (poll! s mode)
  (scheduler-phase-set! s 'in-uv-run)
  (let ((more (guard (e ((uv-callback-error? e) (fatal-callback-error! s e)))
                (uv-run (scheduler-loop s) mode))))
    (scheduler-phase-set! s 'scheduling)
    more))
```

`poll!` is the *only* injection point the tests replace (§16): a fake `poll!` pops scripted events instead of calling `uv-run`.

`'once` vs `'nowait`: when the ready queue is empty after the drain, every coroutine is waiting on libuv, so blocking is correct (`loop.rst:126-129`). When a coroutine called `(yield!)` to be fair (re-enqueued itself), the queue is non-empty and `'nowait` polls I/O without blocking so the yielder is not starved by an idle socket. This is the whole idle policy; there is no timer-driven wakeup and no spinning.

## 5. Wakeup protocol

### 5.1 Connection inbox

Each connection has an inbox (FIFO of events) and a `waiting-for` tag. The libuv closures created once at accept:

```scheme
(define (install-transport-callbacks! s conn tcp)
  (uv-read-start! tcp
    (lambda (bv start end)                   ; on-data: chez-libuv hands a FRESH bytevector (ADR-0009)
      (inbox-push! conn (make-ev-data bv start end))
      (conn-inbox-bytes-set! conn (+ (conn-inbox-bytes conn) (- end start)))
      (when (>= (conn-inbox-bytes conn) (limits-inbox-high (conn-limits conn)))
        (when (uv-handle-open? tcp) (uv-read-stop! tcp))      ; docs/api.md:183-192
        (conn-reading-set! conn #f))
      (wake-if-waiting! s conn 'input))
    (lambda () (inbox-push! conn ev-eof) (wake-if-waiting! s conn 'input))
    (lambda (err) (inbox-push! conn (make-ev-error err)) (wake-if-waiting! s conn 'any))
    (limits-read-buffer-size (server-limits s))))             ; 16384 recommended, §17

(define (wake-if-waiting! s conn what)
  (let ((c (conn-coroutine conn)))
    (when (and (eq? (coroutine-state c) 'parked)
               (or (eq? what 'any) (eq? (conn-waiting-for conn) what)))
      (conn-waiting-for-set! conn #f)
      (coroutine-wake-value-set! c 'event)
      (coroutine-state-set! c 'ready)
      (queue-push! (scheduler-ready s) c))))
```

The coroutine side:

```scheme
;; await-event! : conn symbol -> event
;; Blocks the calling coroutine until its inbox has an event of the awaited class.
(define (await-event! conn what)
  (let spin ()
    (let ((ev (inbox-pop! conn what)))
      (or ev
          (begin
            (conn-waiting-for-set! conn what)
            (park! (conn-coroutine conn))          ; R2/R5 checks live here
            (spin))))))

(define (park! c)
  (let ((s (coroutine-scheduler c)))
    (assert-phase! s 'scheduling 'park!)
    (call/1cc (lambda (k)
                (coroutine-k-set! c k)
                ((scheduler-sched-k s) 'suspended)))))
```

### 5.2 Resume cells (for external async results)

For things that are not connection I/O (DNS, sleeps, a write drain), the coroutine hands a **resume cell** to whoever will complete the operation; the libuv callback fulfils the cell and returns.

```scheme
(define-record-type resume-cell
  (fields (mutable coroutine) (mutable value) (mutable fulfilled?) (mutable deadline)))

;; await : ((any -> unspecified) -> unspecified) -> any
;; Calls `register!` with a one-argument `resume` procedure; parks until it is called.
(define (await register!)
  (let* ((c (current-coroutine))
         (cell (make-resume-cell c #f #f #f)))
    (register! (lambda (v) (fulfil! cell v)))   ; may be called from ANY libuv callback
    (park! c)
    (resume-cell-value cell)))

(define (fulfil! cell v)
  (cond ((resume-cell-fulfilled? cell)           ; R4: a second fulfilment is a fault, never a second resume
         (record-late-fulfilment! cell v))
        (else
         (resume-cell-fulfilled?-set! cell #t)
         (resume-cell-value-set! cell v)
         (let ((c (resume-cell-coroutine cell)))
           (coroutine-wake-value-set! c 'cell)
           (coroutine-state-set! c 'ready)
           (queue-push! (scheduler-ready (coroutine-scheduler c)) c)))))
```

M1 is exactly this protocol with a timer as the registrar.

## 6. Per-connection vs per-request coroutines

**Primary (v1): one coroutine per connection; handlers run inline, in arrival order.** The connection coroutine owns: the tcp handle, the parser, the inbox, the outstanding-write counters, the response sequence. It runs `(handler req res)` on its own stack. Consequences: response ordering for pipelined requests is trivially preserved (there is only ever one response in flight per connection), "outstanding requests" is at most one running plus unparsed bytes in the inbox, and the parser is never fed while a handler runs — which is what M4 shows the parser wants (`callback-pause` at `on-message-complete`, exact `consumed`).

**Extension (v2): per-request coroutines behind an ordering gate**, for handlers that block on slow upstreams while later pipelined requests could be served. The connection coroutine spawns a request coroutine per parsed request (up to `max-pipeline-depth`, default 8); each request's `response-start!` awaits `(= (request-seq req) (conn-next-to-write conn))`; `response-end!` increments `next-to-write` and wakes the next. The connection coroutine stops *resuming the parser* when `in-flight = max-pipeline-depth`. Everything in §7–§15 is written so v2 is additive: request coroutines use the same `await`, the same counters, the same close ownership.

Server-level coroutines: one **acceptor/drain coroutine** (handles `'draining` state), and nothing else. Timers, signals and DNS never need a coroutine of their own — they fulfil cells.

## 7. Handler API

`(http-server)` exports `make-http-server`, `http-server-run!`, request accessors, and the direct-style verbs below. Handlers are `(lambda (req res) ...)` and run inside a coroutine; every verb that might block *parks* the coroutine — it never blocks the OS thread.

```scheme
;; request-method   : request -> symbol            ('GET 'POST ... from llhttp's method int)
;; request-target   : request -> bytevector        (raw; uriparse's uri-parse for components)
;; request-version  : request -> (cons major minor)
;; request-headers  : request -> (listof (cons bytevector bytevector))   ; in wire order, names lowercased
;; request-header   : request bytevector -> (or bytevector #f)
;; request-read!    : request -> (or bytevector eof-object)   ; next body chunk; PARKS; drives the parser
;; request-body     : request [limit] -> bytevector           ; convenience: read! until eof, bounded
;; respond!         : response status headers body -> unspecified   ; whole response, Content-Length set
;; response-start!  : response status headers -> unspecified  ; chunked unless Content-Length given
;; response-write!  : response bytevector [start end] -> unspecified ; PARKS while over write high-water
;; response-end!    : response -> unspecified                 ; final chunk / nothing; PARKS until on-complete? no: until queued
;; await            : ((any -> unspecified) -> unspecified) -> any   ; §5.2
;; sleep!           : ms -> unspecified
;; with-deadline    : ms thunk -> any                         ; raises &timeout at the next await after expiry
;; yield!           : -> unspecified                          ; fairness point
```

### 7.1 Trivial respond

```scheme
(define (hello req res)
  (respond! res 200 '((content-type . "text/plain")) (string->utf8 "hello\n")))
```

`respond!` serialises `HTTP/1.1 200 OK\r\n...Content-Length: 6\r\n\r\n` + body into **one** `uv-write!` (one foreign block, one syscall) when the body is under `limits-coalesce-bytes` (16 KiB), otherwise head then body as two writes. It does not park unless the connection is over its write high-water (§10).

### 7.2 Streaming a large response body with backpressure

```scheme
(define (stream-file req res path)
  (response-start! res 200 '((content-type . "application/octet-stream")))
  (let ((port (open-file-input-port path)) (buf (make-bytevector 65536)))
    (let loop ()
      (let ((n (get-bytevector-n! port buf 0 65536)))
        (unless (eof-object? n)
          (response-write! res buf 0 n)      ; parks while outstanding bytes >= high-water
          (loop))))
    (close-port port)
    (response-end! res)))
```

`response-write!`:

```scheme
(define (response-write! res bv start end)
  (unless (= start end)                              ; a zero-length write costs a full block (api.md:194-197)
    (let* ((conn (response-conn res)) (lim (conn-limits conn)))
      (let wait ()
        (when (or (>= (conn-out-bytes conn) (limits-write-high lim))
                  (>= (conn-out-count conn) (limits-write-count-high lim)))
          (conn-waiting-for-set! conn 'drain)
          (park! (conn-coroutine conn))
          (check-transport-fault! conn)               ; a write error/EOF while parked raises &transport
          (wait)))
      (transport-write! conn (frame-chunk res bv start end)))))

;; transport-write! : conn bytevector -> unspecified
;; Counters move only after uv-write! returned (api.md:199-206): a synchronous
;; raise means nothing was queued and no completion will come.
(define (transport-write! conn bv)
  (uv-write! (conn-tcp conn) bv (conn-on-write-done conn))   ; ONE closure per connection, reused
  (conn-out-bytes-set! conn (+ (conn-out-bytes conn) (bytevector-length bv)))
  (conn-out-count-set! conn (+ 1 (conn-out-count conn))))

;; created once at accept:
(define (make-on-write-done s conn n-cell)
  (lambda (err)
    ;; libuv freed the block BEFORE this ran (ADR-0009 amendment); n is carried per request via a
    ;; per-connection FIFO of sizes so the callback allocates nothing.
    (let ((n (fifo-pop! (conn-out-sizes conn))))
      (conn-out-bytes-set! conn (- (conn-out-bytes conn) n))
      (conn-out-count-set! conn (- (conn-out-count conn) 1))
      (when err (inbox-push! conn (make-ev-write-error err)))
      (when (or err (< (conn-out-bytes conn) (limits-write-low (conn-limits conn))))
        (wake-if-waiting! s conn (if err 'any 'drain))))))
```

`uv-stream-write-queue-size` is read by `response-write!` only to choose the *size* of the next chunk (halve the target chunk when the gauge is above `write-high`, since on Unix it measures bytes not yet handed to the kernel) and for metrics; it is never the correctness gate (api.md:208-223; it stays non-zero after a failed write on Unix).

### 7.3 Consuming a large request body incrementally

```scheme
(define (upload req res)
  (let ((h (make-sha256)))
    (let loop ((total 0))
      (let ((chunk (request-read! req)))          ; parks; each call resumes the parser once
        (if (eof-object? chunk)
            (respond! res 200 '() (string->utf8 (format "~a bytes ~a\n" total (hex (h)))))
            (begin (sha256-update! h chunk) (loop (+ total (bytevector-length chunk)))))))))
```

`request-read!` is where read-side backpressure crosses the parser boundary (architecture §7):

```scheme
;; request-read! : request -> (or bytevector eof-object)
(define (request-read! req)
  (let ((conn (request-conn req)))
    (cond ((request-body-done? req) (eof-object))
          (else
           (let pump ()
             (let ((chunk (conn-take-body-chunk! conn)))     ; set by on-body-data, which paused
               (cond (chunk chunk)
                     ((request-body-done? req) (eof-object))
                     (else (feed-one-step! conn) (pump)))))))))

;; feed-one-step! : conn -> unspecified
;; Resume the parser and feed until it pauses (body chunk or message complete), errors, or needs input.
(define (feed-one-step! conn)
  (let ((p (conn-parser conn)))
    (when (eq? (parser-lifecycle p) 'paused-feed) (parser-resume! p))
    (let ((ev (await-event! conn 'input)))           ; parks if the inbox is empty; maybe restarts reading
      (case (ev-kind ev)
        ((data)
         (let ((r (with-phase 'in-parser (lambda () (parser-feed! p (ev-bv ev) (ev-start ev) (ev-end ev))))))
           (inbox-consume! conn ev (parser-result-consumed r))   ; unconsumed tail stays at the inbox head
           (maybe-read-start! conn)
           (case (parser-result-status r)
             ((paused need-input) #f)
             ((error) (raise-parse-error conn (parser-result-error r))))))
        ((eof) (parser-finish! p) (conn-eof-seen-set! conn #t))   ; a truncated body -> 'error from finish
        ((error write-error) (raise-transport conn ev))))))
```

Because `on-body-data` returns `callback-pause` after storing the span, exactly one chunk is handed out per `request-read!`, and `parser-result-consumed` marks how far the delivery was eaten, so the remainder of the same delivery is kept at the inbox head. A handler that never calls `request-read!` (or `respond!`s early) leaves the inbox to fill until `inbox-high`, at which point `on-data` stops the read: the body backs up in the kernel (api.md:101-116 — the receive buffer is charged only when you stop reading, which is why body/idle timeouts bound how long we stay stopped, §11). On `respond!` for a request whose body was not consumed, the connection coroutine drains the body up to `max-drain-bytes` (default 1 MiB) and otherwise marks the connection `close`.

### 7.4 Awaiting an external async result (DNS)

```scheme
(define (proxy-ish req res)
  (let* ((host (utf8->string (request-header req (string->utf8 "x-upstream"))))
         (r (with-deadline 2000
              (lambda ()
                (await (lambda (resume)
                         (uv-getaddrinfo! (current-loop) host "80" '((socktype . stream))
                                          (lambda (err results) (resume (cons err results))))))))))
    (if (car r)
        (respond! res 502 '() (string->utf8 (symbol->string (uv-errno-error-errno (car r)))))
        (respond! res 200 '() (string->utf8 (uv-addrinfo-address (car (cdr r))))))))
```

The `on-complete` given to `uv-getaddrinfo!` is a library-owned closure shape: it calls `resume` (fulfils a cell) and returns. If `with-deadline` expires first, the wheel (§11) fulfils the cell with `&timeout`, the coroutine raises at the `await`, and the late DNS result (which "still fires", api.md:372) hits `fulfil!`'s already-fulfilled branch and is dropped (R4). `with-deadline` also calls `uv-cancel!` when the registrar returned a `uv-dns-request?` so the threadpool slot is released early when possible.

## 8. Connection driver

### 8.1 libuv callbacks → model

| libuv callback (chez-libuv verb) | Runs where | What it does (O(1), no user code) |
|---|---|---|
| `on-connection` (`uv-listen!`) | inside `uv-run` | If `live-conns ≥ max-connections` or server is `'draining`: `(uv-accept!)` then `(uv-close! peer)` at once (the peer never gets a conn record, so R6 is not violated — nothing else will ever close it). Else: `uv-accept!` (guarded, as test-echo.sps:229-236), `make-conn`, register in the server's conn table, install the four transport closures, create the connection coroutine, push it on the ready queue. `uv-accept!` raising inside the callback would become `&uv-callback-error` and stop the loop, so it is guarded here and the error is counted. |
| `on-data` | `uv-run` | inbox push, byte accounting, maybe `uv-read-stop!` (guarded), wake (§5.1). No copy: the bytevector is already fresh (`handles.sls:405`). |
| `on-eof` | `uv-run` | push `eof`, wake. |
| `on-error` (read) | `uv-run` | push `(error . cond)`, wake `'any`. Never closes (that is "the caller's decision", quickstart.md:93-96) — the coroutine closes. |
| write `on-complete` | `uv-run` | counters down, push `write-error` if err, wake `'drain`/`'any` (§7.2). |
| `uv-shutdown!` callback | `uv-run` | push `shutdown-done`, wake `'shutdown`. |
| `on-close` (`uv-close!`) | `uv-run` | `(conn-table-remove! s conn)`, `live-conns--`, state `'closed`, push `closed`, wake `'closed`; if `draining` and `live-conns = 0` fulfil the drain cell. This is the only deregistration site. |
| timer tick (`make-uv-timer`, one per server) | `uv-run` | `(wheel-advance! wheel (uv-now loop))` → for each expired entry push `(timeout . kind)` on its conn's inbox and wake `'any`, or fulfil the entry's resume cell with `&timeout` (§11). |
| `on-signal` (`uv-signal-start-oneshot!` sigterm) | `uv-run` | `(server-state-set! s 'draining)`, fulfil the acceptor coroutine's cell, `(uv-close! watcher)`. |
| `on-complete` (`uv-getaddrinfo!`) | `uv-run` | fulfil a resume cell. |

### 8.2 The 25 parser callbacks → model

All 25 run **inside the connection coroutine**, during `parser-feed!` called from `feed-one-step!` — a Scheme frame under the scheduler, never under `uv-run`. The user context (`make-parser`'s third argument) is the `conn` record. Bindings are built once per connection by `(make-parser-bindings conn)`; the functional core provides pure step functions over the request-builder value, and the closure only stores results.

| Callback | Outcome | Action (`rb` = the connection's current request-builder, a pure value updated functionally) |
|---|---|---|
| `on-message-begin` | continue | `rb := (rb-begin now)`; arm the *header* deadline on the wheel; `conn-requests++`. |
| `on-method-data` (span) | continue | `rb := (rb-append-method rb bv from to)` — copies (api.org: "copy what you need before returning"). |
| `on-method-complete` | continue | `rb := (rb-method-complete rb (parser-field-ref p 'method))` — llhttp's int → symbol via a fixed table. |
| `on-url-data` (span) | continue / failure `'target-too-long` | append to target; refuse when `> max-target-bytes` (→ 414). |
| `on-url-complete` | continue | freeze target bytevector. |
| `on-protocol-data`/`-complete` | continue | ignored (llhttp already validated `HTTP`). |
| `on-version-data`/`-complete` | continue | ignored here; version read at headers-complete from `http-major/minor`. |
| `on-status-data`/`-complete` | continue | bound because all 25 are required; never fire in `'request` mode. A firing is recorded as an invariant fault. |
| `on-header-field-data` (span) | continue / failure `'header-too-large` | append to current name; enforce `max-header-field-bytes`, `max-header-bytes` (→ 431). |
| `on-header-field-complete` | continue | lowercase-in-place (ASCII), freeze name. |
| `on-header-value-data` (span) | continue / failure | append to current value; same limits. |
| `on-header-value-complete` | continue / failure `'too-many-headers` | push `(name . value)`; enforce `max-header-count`. |
| `on-headers-complete` | continue / `'skip-body` / failure | **Read flags here, before the inter-message reset** (M4: `flags 32` then `2`): keep-alive/close/chunked/content-length/upgrade bits, declared `content-length`, `http-major/minor`. Decide framing policy: reject `F_UPGRADE`/`CONNECT` with `'upgrade-unsupported` (→ 501) unless a future extension claims it; reject a body over `max-body-bytes` when `content-length` is declared (→ 413); note `Expect: 100-continue` (the coroutine writes `HTTP/1.1 100 Continue\r\n\r\n` before the first `request-read!`). Build the immutable `request` record and store it on the conn. **Returns `callback-pause`**, so the coroutine can start the handler before the body arrives. |
| `on-body-data` (span) | **pause** | Store `(bv from to)` as the pending chunk — no copy, the delivery bytevector is ours and fresh; return `callback-pause` so exactly one chunk is delivered per `request-read!`. Count towards `max-body-bytes` for chunked bodies (→ 413 on excess, failure). |
| `on-chunk-header` | continue | record chunk size for metrics; nothing else. |
| `on-chunk-extension-name-data`/`-complete`, `on-chunk-extension-value-data`/`-complete` | continue / failure `'chunk-ext-too-large` | extensions are ignored but bounded by `max-chunk-extension-bytes`. |
| `on-chunk-complete` | continue | — |
| `on-message-complete` | **pause** | `request-body-done := #t`; disarm body deadline; arm *idle* deadline; return `callback-pause` — the pipelining boundary (M4). |
| `on-reset` | continue | fires only when the parser is next resumed and fed (M4 shows it before the second `on-message-begin`); clears nothing that `on-message-begin` does not already reset — kept as a check that the two agree. |

Policy failures use `(make-callback-failure code detail)`; `parser-feed!` then returns `'error` with `parser-error-domain` distinguishing our callback failures from llhttp grammar errors, and the parser is sticky in `'error` (api.org "the parser will not make further progress"), which is exactly the "close after error" behaviour HTTP wants.

### 8.3 The connection coroutine

```scheme
(define (connection-main s conn)
  (guard (e (#t (connection-abort! s conn e)))            ; catches EVERYTHING below; §13
    (let loop ()
      (feed-until-headers! conn)                           ; may park on input; parse errors raise
      (let* ((req (conn-current-request conn))
             (res (make-response conn req)))
        (run-handler! s conn req res)                      ; guard inside; 500 if nothing was written yet
        (finish-request! conn req res))                    ; drain unread body (bounded), flush 'end'
      (cond ((or (conn-must-close? conn) (server-draining? s))
             (graceful-close! s conn))                     ; shutdown → await shutdown-done → close! → await closed
            (else (loop)))))
  ((scheduler-sched-k s) 'finished))                       ; R3
```

`conn-must-close?` is true when: the request had `F_CONNECTION_CLOSE` or was HTTP/1.0 without keep-alive; the handler set `Connection: close`; the response was written without a known length on HTTP/1.0; a body was left unread beyond `max-drain-bytes`; any error occurred. A close-marked message is **never followed by a feed** (M4 third feed: `closed-connection` error at offset 99).

## 9. Pipelining

- Correctness of boundaries: `callback-pause` at `on-message-complete` returns `consumed` = the exact end of the message (M4: 51, then 47 more). The unconsumed tail of a delivery stays at the head of the inbox as a sub-span `(bv start' end)` — no re-copy.
- Ordering: v1 executes handlers sequentially in the connection coroutine, so responses are emitted in request order by construction. v2's per-request coroutines order via `conn-next-to-write` (§6).
- Cap on outstanding requests: v1 — at most one executing; unparsed pipelined bytes are bounded by `inbox-high` (read-stop). v2 — `max-pipeline-depth` spawned-but-unanswered request coroutines; when reached the connection coroutine parks on `'pipeline-slot` instead of resuming the parser, and `response-end!` wakes it.
- Head-of-line: a slow handler holds the pipeline; that is HTTP/1.1 (RFC 9112 §9.3.2 requires in-order responses) and not a defect of the model.
- After a close-marked message, remaining inbox bytes are discarded and reading stops (`uv-read-stop!` guarded) before `uv-shutdown!`.

## 10. Backpressure in both directions

**Read side** (bytes, not deliveries): `inbox-high` (default `2 × read-buffer-size`) → `uv-read-stop!` from `on-data` (guarded by `uv-handle-open?`, api.md:183-192, test-echo.sps:300-330 pattern); `inbox-low` (default `read-buffer-size / 2`) → `uv-read-start!` from the coroutine's `inbox-consume!` (an omitted size restarts against the fixed buffer, `stream.sls:105-115`). Restart is issued from a coroutine, never from a callback, so it never races a delivery in flight.

**Write side**: `out-bytes`/`out-count` per connection, incremented after `uv-write!` returns (api.md:199-206), decremented in `on-write-done`; `write-high` 256 KiB / `write-count-high` 64 park `response-write!`; `write-low` 64 KiB wakes. This is ADR-0018's "queueing and admission remain server policy" implemented in the server: **nothing is queued Scheme-side** — a parked coroutine *is* the queue (its unsent chunk lives on its own stack), so there is no second free site and no FIN-before-data hazard: `uv-shutdown!` is only ever called by the connection coroutine after its last `uv-write!` returned, and libuv orders them.

**Gauge**: `uv-stream-write-queue-size` adapts chunk size and feeds metrics only (§7.2).

**Interaction**: a handler streaming a response while a client uploads (full duplex) has read-stop and write-park operating independently; both are per-connection and both are released by callbacks that wake the one coroutine.

## 11. Timeouts and timer economy

One `uv-timer` per server (`tick-ms`, default 250) drives a **hashed timing wheel** in the functional core: `(wheel-schedule w key deadline-ms) → w'`, `(wheel-cancel w key) → w'`, `(wheel-advance w now) → (values w' expired-keys)`. Connections and resume cells are keys. Rearming on activity is lazy: the conn stores its own deadline; an expired bucket entry whose conn deadline moved is re-bucketed instead of fired. So at 10k connections there is **one** `uv_timer_t` (152 B) instead of 10k (1.5 MB foreign + 10k registry entries + 10k closes to own), and the wheel is O(1) per event.

| Timeout | Armed | Disarmed | Expiry action |
|---|---|---|---|
| header (`headers-timeout-ms`, 10 s) | `on-message-begin` | `on-headers-complete` | 408 + close (response only if nothing written) |
| body (`body-timeout-ms`, 30 s between chunks) | `on-headers-complete` | each `on-body-data` (rearm), `on-message-complete` | 408 + close |
| idle keep-alive (`idle-timeout-ms`, 60 s) | `on-message-complete` / accept | `on-message-begin` | close, no response |
| write (`write-timeout-ms`, 30 s per write completion) | `uv-write!` when `out-count` goes 0→1 | `on-write-done` when `out-count` → 0 (rearm otherwise) | abort |
| handler / await (`with-deadline`) | at `await` | at fulfilment | fulfil cell with `&timeout`; `uv-cancel!` if DNS |
| drain deadline (`drain-timeout-ms`, 10 s) | SIGTERM | all closed | force-close all |

Expiry is delivered as an inbox event or a cell fulfilment; the coroutine observes it at its next park. A CPU-bound handler cannot be interrupted (no preemption; engines were considered and rejected — §19 R3); the deadline fires at its next await.

Granularity: `tick-ms` = 250 gives ±250 ms, acceptable for second-scale timeouts. The tick timer is *unreferenced* work: while the server has no connections the tick still fires (keeps `uv-run 'once` from blocking forever, which is harmless) — alternatively stop the tick timer when the wheel is empty and start it on first schedule; the proposal does the latter so an idle server sleeps in the poll indefinitely.

## 12. Limits (`(http-server limits)`, a pure record with defaults, validated at construction)

`max-connections` 10000 · `backlog` 511 · `read-buffer-size` 16384 · `inbox-high` 32768 · `inbox-low` 8192 · `write-high` 262144 · `write-low` 65536 · `write-count-high` 64 · `coalesce-bytes` 16384 · `max-target-bytes` 8192 · `max-header-field-bytes` 8192 · `max-header-bytes` 65536 · `max-header-count` 100 · `max-body-bytes` #f (unbounded; `request-body` takes its own limit) · `max-drain-bytes` 1048576 · `max-chunk-extension-bytes` 1024 · `max-pipeline-depth` 8 (v2) · `headers-timeout-ms` 10000 · `body-timeout-ms` 30000 · `idle-timeout-ms` 60000 · `write-timeout-ms` 30000 · `drain-timeout-ms` 10000 · `tick-ms` 250.

12-factor: every limit is overridable from the environment (`HTTP_SERVER_MAX_CONNECTIONS` …) by the shell, parsed once at startup; the core sees only the record.

## 13. Error propagation

| Class | Where it surfaces | Policy |
|---|---|---|
| **Parser error** (llhttp grammar) | `parser-feed!` returns `'error` inside `feed-one-step!` (coroutine frame) | `raise-parse-error` → caught by `connection-main`'s guard → if nothing written: 400 (505 for `invalid-version`, 414/431 for our own codes) with `Connection: close`; then `graceful-close!`. The parser is never fed again (sticky). |
| **Policy error** (limits, timeouts) | callback failure → same path; timeout → inbox event observed at a park | 413/414/431/408/501 as tabled; idle timeout → silent close. |
| **Handler exception** | `run-handler!`'s guard, on the coroutine stack (M5: a guard inside a coroutine catches after resume; an uncaught raise lands in the scheduler's guard, never near a foreign frame) | Nothing written yet → 500 + close; headers already sent → abort (close without shutdown, so the client sees a truncated body rather than a fake-complete one); logged with the request line. `&timeout` from `with-deadline` is an ordinary condition the handler may `guard`. |
| **Transport error** (`on-error`, write `err`, EOF mid-message, ECONNRESET on shutdown) | inbox event → raised as `&transport` at the coroutine's next park or write | abort: `connection-close!`; no response attempted. |
| **`&uv-callback-error`** | raised by `uv-run` in `poll!` | Can only come from *our own* callbacks (all user code runs outside them, R1) → it is a server bug. `fatal-callback-error!` logs the composed cause and `uv-loop-deferred-errors`, sets state `'crashing`, force-closes everything, tears down, and re-raises so the process exits non-zero. Never swallowed, never retried: chez-libuv already stopped the loop (quickstart.md:97-101), and continuing would hide a broken invariant. |
| **Unguarded raise inside a callable** | impossible by construction | Every trampoline body is guarded by chez-libuv (`handles.sls:302`, ADR-0008); our callbacks add no `guard` of their own except around `uv-accept!` where a raise means a *dropped connection*, not a bug. |
| **Raise from the scheduler itself** | top-level `http-server-run!` | wrapped in `call-with-uv-loop`-style teardown so `uv-loop-teardown!` runs on every exit path (loop.sls:150-160). |

Store-and-reraise compatibility: because handler code never executes in a callback, the "loop stopped by a raise" failure mode that ADR-0008 documents cannot be triggered by application code at all — this is the single biggest robustness argument for the two-level design.

## 14. Graceful shutdown

```scheme
(define (acceptor-main s)                      ; the one server-level coroutine
  (await (lambda (resume) (server-drain-cell-set! s resume)))   ; fulfilled by on-signal (sigterm oneshot)
  (uv-close! (server-listener s))              ; stop accepting; on-connection can no longer fire
  (for-each (lambda (conn)
              (if (conn-idle? conn)            ; parked between messages
                  (connection-close! s conn 'drain)
                  (conn-must-close-set! conn #t)))   ; finish the current response with Connection: close
            (conn-table-snapshot s))
  (let ((r (with-deadline (limits-drain-timeout-ms (server-limits s))
             (lambda () (await (lambda (resume) (server-all-closed-cell-set! s resume)))))))
    (when (timeout? r) (for-each (lambda (c) (connection-close! s c 'drain-deadline)) (conn-table-snapshot s))))
  ((scheduler-sched-k s) 'finished))
```

Idle connections are woken with a `drain` inbox event so their coroutine runs `graceful-close!` (shutdown → close). Busy ones see `server-draining?` after their current request. When the last `on-close` fires, `live-conns` hits 0, the all-closed cell is fulfilled; the tick timer is stopped and closed; `uv-run` returns `#f` (no active handles) and `scheduler-run!` exits; `http-server-run!` then calls `uv-loop-teardown!` (which is a no-op sweep by then, and would also cancel any in-flight DNS, api.md:402-408). A second SIGTERM after the oneshot fired hits SIG_DFL and kills the process — the documented "first drains, second kills" behaviour (api.md:337-348).

## 15. Close-ownership protocol

Because "a close issued against a handle that is already `'closing` stores nothing and the supplied `on-close` never runs" (api.md:266-274), the on-close callback that deregisters a connection would be lost if anyone else closed first. Rules:

1. `connection-close! : server conn symbol -> unspecified` is the **only** caller of `uv-close!` on a connection's tcp handle. It transitions `conn-state` `'open → 'closing` and records the reason; a second call is a no-op that increments `close-requests` (a counter tests read).
2. Every path — eof, read error, write error, parse error, policy error, handler abort, timeout, drain, drain-deadline — calls `connection-close!`. `uv-close!` never appears elsewhere in the server sources (a `rg` gate in `make test`: `rg -n 'uv-close!' src | rg -v 'connection-close!|listener|watcher|tick-timer'` must be empty — a check, not a comment).
3. `graceful-close!` = `uv-shutdown!` (if no transport fault) → park until `shutdown-done` → `connection-close!` → park until `closed`. The abort path skips the shutdown.
4. Server-owned handles (listener, signal watcher, tick timer) are closed exactly once by the acceptor coroutine, in that order.
5. `uv-loop-teardown!` at exit may still sweep a handle in a crash path; `on-close` tolerates a conn already removed.
6. Peers refused in `on-connection` (over `max-connections`/draining) are closed there without a conn record — the one sanctioned `uv-close!` outside `connection-close!`, and it has no callback to lose.

Test: close a connection through two paths in the same turn (eof event + idle timeout); assert `on-close` ran once, the registry deregistered, `close-requests = 2`.

## 16. Testability under FCIS / TDD / mutation

**Functional core** (`(http-server core ...)`, pure, no libuv import): request-builder steps for all 25 callbacks; header limits; response serialiser (`(serialize-head status headers) → bytevector`, `(frame-chunk ...)`); the connection state machine `(conn-step state event) → (values state' actions)` with symbolic actions (`'read-stop 'read-start (write bv) 'shutdown 'close (run-handler req) ...`); flow-control decisions (`(read-decision inbox-bytes reading? lim)`, `(write-admission out-bytes out-count lim)`); the timing wheel; the limits record; llhttp method-int → symbol table.

**Imperative shell**: scheduler (`poll!` injectable), transport (a record of six verbs: `read-start!`, `read-stop!`, `write!`, `shutdown!`, `close!`, `write-queue-size`), the callback closures.

**Three test lanes:**

1. *Pure lane* (no libuv, no sockets, seconds): SRFI-64 suites over the core; every limit has a boundary test watched to fail first.
2. *Fake-transport lane* (no sockets, scheduler real, `poll!` scripted): the fake transport records verbs and the test script delivers `on-data`/`on-eof`/`on-error`/`on-write-done` events as the scheduler's `poll!` result. This is where the **llhttp corpus is replayed through the connection layer at every chunk size**:
   - load `test/request/*.md` fixtures with chez-httparse's `corpus-parse-file`; `fixture-input-text`, `fixture-init-words`, `fixture-lenient-flags`, `fixture-expected` (its harness libs are R6RS and import only `(rnrs)`/`(byte-machine runtime)`).
   - for `size in (corpus-scan-sizes len no-scan? 'full)` (release) or `'extremes` (pr), each `(corpus-chunk-bounds len size)` slice becomes **one `on-data` delivery = one scheduler turn**, so parser resumption *and* inbox/backpressure logic are exercised at every boundary.
   - the handler is a *recording handler* that, together with instrumented connection-layer hooks, emits events in llhttp's own vocabulary via `adapter-event-for` into a `make-trace-recorder`, and `trace-compare` judges byte-for-byte against `fixture-expected`.
   - fixtures whose semantics the connection layer intentionally changes (stop feeding after `Connection: close`, refuse `CONNECT`/upgrade, limits) are listed in a ratchet manifest exactly as chez-httparse's conformance ratchet does; a fixture changing status in either direction is a reviewed diff. Response fixtures (`test/response/*.md`) are out of scope for a server.
   - the same lane runs pipelining (M4's input at every chunk size), backpressure (assert `read-stop`/`read-start` verb sequence vs inbox thresholds), timeouts (the fake `poll!` advances the wheel's clock), shutdown, and close-ownership.
3. *Socket lane* (chez-libuv ADR-0010 shape: `127.0.0.1:0`, clients on the same loop, iteration-capped drains as in test-echo.sps): the `'extremes` corpus preset over real sockets (a client coroutine writes the fixture in `size`-byte `uv-write!`s), keep-alive, pipelining, slow reader (client stops reading → server parks in `response-write!`), slow writer (body timeout), disconnect during read/write, SIGTERM drain (`uv-kill!` self with `uv-os-getpid`). Assertions are on bytes and verb sequences, never on timing (test-echo.sps's rule).

**Mutation discipline** (each named mutation must turn a named test red before the test is accepted): invert the read-stop comparison; remove `parser-resume!` before feeding; return `callback-continue` from `on-message-complete` (pipelining boundary lost → corpus pipelined fixtures diverge); remove the one-shot check in `fulfil!` (late DNS after timeout would resume twice → the R4 test); remove the `uv-handle-open?` guard before `uv-read-stop!`; count write bytes before `uv-write!` returns; swap `'once`/`'nowait` (the idle test asserts `uv-run` call count under a scripted clock); let `connection-main` return normally instead of `(sched-k 'finished)` (M6 reproduces as a crash); call a handler from inside `on-data` (the R1 phase assertion).

**Scheduler unit tests** need no libuv at all: `poll!` is a stub returning scripted "callbacks landed" batches; M1's script is the template.

## 17. Performance

Measured continuation costs (M2, M3): 24 ns and ~7 bytes per yield/resume pair at shallow depth; 359 ns from 200 frames deep (the segment copy grows with the live stack, which is why handlers should await at modest depth); parked coroutine ≈ 3.4 KiB (depth 4) to 5.6 KiB (depth 64).

Per keep-alive request on the hot path (trivial handler, request in one delivery): 1 delivery bytevector (chez-libuv's `copy-out`, unavoidable under ADR-0009), ~2 small conses per inbox event, 1 request record, `2n` bytevectors for `n` headers (copied at span time — could be deferred to a single copy of the head region later since the delivery is ours; left as an optimisation), 1 response head bytevector coalesced with a small body into one `uv-write!` (one 192-byte-req + payload foreign block, freed before `on-complete`), 0 per-write Scheme closures (one `on-write-done` per connection), 0 timer handles (wheel), 2–3 continuation switches (~70 ns, ~20 bytes). Estimated < 2 KiB Scheme allocation per trivial request excluding the delivery itself; to be measured with `bytes-allocated` in the benchmark lane, not asserted.

Per idle keep-alive connection: chez-libuv read buffer (64 KiB default; **this proposal passes 16384**, the size api.md:174-177 calls reasonable for many small-message connections → ~160 MiB at 10k instead of ~625 MiB), `uv_tcp_t` 264 B + registry entry, conn record (~30 fields, ~300 B), parser vector (18 slots + field vectors, ~400 B), 4 transport closures (~200 B), parked coroutine ~3.5 KiB, inbox empty. ≈ 16 KiB foreign + ~5 KiB heap ≈ 21 KiB → ~210 MiB at 10k. The coroutine is ~15% of that; the read buffer dominates at any setting above 4 KiB.

GC: 10k parked coroutines ≈ 35 MB of stack segments that a major collection scans; young collections touch only recently parked ones. Not measured under load — listed as a risk.

Latency: an event goes callback → inbox → `uv-run` returns at the end of the iteration → scheduler resumes the coroutine: no extra syscalls, one queue op, one continuation switch. Under load, one `uv-run 'once` iteration delivers many callbacks and the scheduler then runs all woken coroutines in one drain — natural batching.

## 18. Chez assumptions (stated, not verified here)

- **A1 (structural, spike-independent):** a continuation captured in a Scheme frame entered from the scheduler, with `uv-run`'s foreign-procedure call having *returned normally* in between, may be invoked later. CSUG §4.4: "until some return to a foreign context is actually performed, all return points remain valid" — and a foreign context is a C→Scheme call, of which none exists between the scheduler and any captured k. M1 exercised this path 6 times without incident.
- **A2 (the open question, deliberately not depended on):** whether a continuation captured *inside* a `foreign-callable` may be invoked after that callable returned. CSUG §4.4 says Chez traps "attempts to return to stale foreign contexts", i.e. the expected outcome is a trapped error, not memory corruption — but this proposal never captures a continuation inside a callable (R1/R2, checked by the `phase` assertion), so its correctness does not change whichever way the live spike lands. If the spike shows it is safe, the queue hop in §5 could be removed for a simpler design; if it shows it is unsafe, this design is unaffected.
- **A3:** one-shot promotion is transparent: if any library used inside a handler calls `call/cc` while a coroutine is active (R6RS `guard`'s reraise path, SRFI generators, the httparse harness's `refuses?`), the active `call/1cc` continuations are promoted to multishot (CSUG §6.3) — correct, and the measured cost difference is 24 vs 29 ns, so nothing depends on staying one-shot.
- **A4:** `dynamic-wind` winders run on every suspend/resume (M5: in=2 out=2 for one park) — so `parameterize` across an `await` is correct but re-executed; the handler API documents "avoid `dynamic-wind`/`parameterize` around awaits in hot handlers".
- **A5:** no non-local exit ever crosses a C frame in this design, so the C-stack-growth caveat of CSUG §4.4 ("the C stack pointer is not automatically restored") does not apply; if `&uv-callback-error` is ever raised it is after `uv-run` returned normally.
- **A6:** single thread; `uv-run` bound plain; `__collect_safe` unused (spike FINDINGS "deliberately untested").
- **A7:** `call/1cc` capture is O(1) in the size of the *current* stack segment and resume copies the segment back (paper [3] cited by CSUG §6.3 "Representing control in the presence of one-shot continuations"); consistent with M2's 24 ns shallow / 359 ns at 200 frames.

## 19. Risks — including where this angle is simply worse

1. **Discipline that must be policed.** The whole safety argument rests on R1/R2/R5. They are checked by the `phase` assertion, but a violation surfaces as a fatal `&uv-callback-error` at runtime, not at compile time. The callback-in-`on-data` alternative has no such rule to break.
2. **Memory: 3.4–5.6 KiB per parked coroutine vs ~200 B of closures in the callback model** (M3). At 10k connections that is ~35–56 MB more. It is smaller than the read buffer at any size ≥ 8 KiB, but it is real and it is scanned by major GCs (unmeasured under load).
3. **One extra hop per delivery** (~24 ns switch + a cons + queue ops) and one more `uv-run` iteration boundary before user code sees an event. Negligible against a syscall; still strictly more than the callback model.
4. **No cross-thread wakeup.** `uv_async` is not bound, so nothing can wake a scheduler blocked in `uv-run 'once` from another OS thread; off-loop CPU work is impossible in v1. Mitigation: ask chez-libuv for `uv_async` (one more locked trampoline under ADR-0008's rule); until then, R7.
5. **No preemption.** A CPU-bound handler starves every connection; `with-deadline` cannot interrupt it. Engines could preempt (CSUG §6.4) but their timer-interrupt-driven `engine-block` would capture continuations at arbitrary points including inside `parser-feed!` (poisoning the parser) — rejected for v1; the callback model has exactly the same starvation property, so this is not *worse*, just not better.
6. **Debugging.** A parked coroutine's stack is a heap object; inspector/backtrace tooling shows only its own segment. Callback-model backtraces are no better, but coroutine ones are unfamiliar.
7. **Sequential handler execution per connection (v1).** A pipelining client with one slow request waits for it; v2 fixes that at the cost of the ordering gate and `max-pipeline-depth`.
8. **Reliance on `callback-pause` at three points** (headers-complete, body-data, message-complete). The corpus records pauses for 24 fixtures (api.org, conformance.org) and M4 confirmed the two we need; still, the pause path is less exercised upstream than the straight path.
9. **The 16 KiB read-buffer recommendation** was measured by chez-libuv on Linux/aarch64 discarding deliveries (api.md:164-171 "a consumer that retains deliveries ... was not measured"); this server retains deliveries in the inbox, so the object-count cost is open.
10. **If A2 turns out to be "safe"**, the obvious alternative (resume coroutines directly from callbacks) needs less machinery than this proposal and has lower latency; this proposal's advantage then reduces to determinism (no user code ever under a C frame, so `&uv-callback-error` cannot be caused by applications) and to not depending on an implementation property CSUG documents only obliquely.

---

## Appendix A — spike scripts, commands, verbatim outputs

All in `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike/`.

### A.1 `two-level.sps` (M1)

Command:
```
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs gtimeout 30 chez --program two-level.sps
```
Output:
```
0 a-start
0 b-start
151 b-after-150
301 a-after-300
402 a-after-400
elapsed-ms=402
uv-run-calls=6
uv-run-blocked-ms=402
verdict: BLOCKED-IN-UV-RUN-NO-BUSY-LOOP
```

### A.2 `1cc-cost.sps` (M2, M6)

Command: `chez --program 1cc-cost.sps`. First run (bug, R3 violated in the deep variant):
```
call/1cc ping-pong: result=1000000 total-ns=21286000 ns/yield=21 bytes/yield=7
call/cc  ping-pong: result=1000000 total-ns=26380000 ns/yield=26 bytes/yield=7
call/1cc ping-pong (2nd): result=1000000 total-ns=20148000 ns/yield=20 bytes/yield=6
call/cc  ping-pong (2nd): result=1000000 total-ns=26045000 ns/yield=26 bytes/yield=7
Exception in +: go is not a number
```
After making the deep coroutine end with `((car box) 'done)`:
```
call/1cc ping-pong: result=1000000 total-ns=24549000 ns/yield=24 bytes/yield=7
call/cc  ping-pong: result=1000000 total-ns=29363000 ns/yield=29 bytes/yield=7
call/1cc ping-pong (2nd): result=1000000 total-ns=24674000 ns/yield=24 bytes/yield=6
call/cc  ping-pong (2nd): result=1000000 total-ns=28747000 ns/yield=28 bytes/yield=7
call/1cc yield from 200 frames deep: result=1000000 total-ns=359702000 ns/yield=359 bytes/yield=0
```

### A.3 `coro-memory.sps` (M3, M6)

Command: `chez --program coro-memory.sps`. First run:
```
depth=4 parked=10000 bytes/parked-coroutine=3401
Exception in +: go is not a number
```
After the coroutine trampoline ends in `(sched-k 'finished)` and resumes pass `0`:
```
depth=4 parked=10000 bytes/parked-coroutine=3449
depth=16 parked=10000 bytes/parked-coroutine=3815
depth=64 parked=10000 bytes/parked-coroutine=5635
```

### A.4 `pipeline-pause.sps` (M4)

Command:
```
chez --libdirs /Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src --program pipeline-pause.sps
```
Input: `"POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabcGET /b HTTP/1.1\r\nHost: y\r\nConnection: close\r\n\r\nGET /c HTTP/1.1\r\n\r\n"` (117 bytes), strict request mode, `on-message-complete` returns `callback-pause`.
Output:
```
(status paused consumed 51 offset 51 error #f)
first message ends at byte 51 of 117
resume -> feed-ready
(status paused consumed 47 offset 98 error #f)
second message ends at byte 98
resume -> feed-ready
(status error consumed 1 offset 99 error (closed-connection Data after `Connection: close` 99))
  (on-message-begin)
  (method "POST")
  (on-method-complete)
  (url "/a")
  (on-url-complete)
  (protocol "HTTP")
  (on-protocol-complete)
  (version "1.1")
  (on-version-complete)
  (hf "Host")
  (on-header-field-complete)
  (hv "x")
  (on-header-value-complete)
  (hf "Content-Length")
  (on-header-field-complete)
  (hv "3")
  (on-header-value-complete)
  (on-headers-complete flags 32 cl 3 major 1 minor 1)
  (body "abc")
  (on-message-complete)
  (on-reset)
  (on-message-begin)
  (method "GET")
  (on-method-complete)
  (url "/b")
  (on-url-complete)
  (protocol "HTTP")
  (on-protocol-complete)
  (version "1.1")
  (on-version-complete)
  (hf "Host")
  (on-header-field-complete)
  (hv "y")
  (on-header-value-complete)
  (hf "Connection")
  (on-header-field-complete)
  (hv "close")
  (on-header-value-complete)
  (on-headers-complete flags 2 cl 0 major 1 minor 1)
  (on-message-complete)
```

### A.5 `guard-across-await.sps` (M5)

Command: `chez --program guard-across-await.sps`. Output:
```
coroutine-1 run -> finished
guard-inside-coroutine caught after resume: (caught after-resume)
dynamic-wind in=2 out=2
coroutine-3 run -> (scheduler-guard-caught uncaught-in-coroutine)
```

### A.6 Toolchain checks

`chez --version` → `10.4.1`; `which gtimeout timeout` → `/opt/homebrew/bin/gtimeout`, `/opt/homebrew/bin/timeout`.

## Appendix B — CSUG verbatim quotes (fetched 2026-09-19 with `curl -sSL https://cisco.github.io/ChezScheme/csug10.0/{control,foreign}.html`, tags stripped)

control.html §6.3:
> Chez Scheme supports one-shot continuations as well as the standard multi-shot continuations obtainable via call/cc. One-shot continuations are continuations that may be invoked at most once, whether explicitly or implicitly. They are obtained with call/1cc.

> The continuation obtained by call/1cc is a "one-shot continuation." A one-shot continuation should not be returned to multiple times, either by invoking the continuation or returning normally from procedure more than once. A one-shot continuation is "promoted" into a normal (multishot) continuation, however, if it is still active when a normal continuation is obtained by call/cc. After a one-shot continuation is promoted into a multishot continuation, it behaves exactly as if it had been obtained via call/cc. This allows call/cc and call/1cc to be used together transparently in many applications.

> One-shot continuations may be more efficient for some applications than multishot continuations. See the paper "Representing control in the presence of one-shot continuations" [3] for more information about one-shot continuations, including how they are implemented in Chez Scheme.

> (dynamic-wind in body out) ... The first form is identical to the Revised6 Report dynamic-wind. When the optional critical? argument is present and non-false, the in thunk is invoked in a critical section ...

control.html §6.4:
> An engine is created by passing a thunk (no argument procedure) to make-engine. The body of the thunk is the computation to be performed by the engine. An engine itself is a procedure of three arguments:

> With engine-return and engine-block, it is possible to terminate an engine explicitly. engine-return causes the engine to complete, as if the computation had finished. ... Similarly, engine-block causes the engine to expire, as if the timer had run out. A new engine is made from the continuation of the call to engine-block and passed to the expire procedure.

foreign.html §4.3:
> The code object may be converted into a foreign-callable address via foreign-callable-entry-point ... This is an implicit pointer into an immobile Scheme object, so it will not be relocated by the storage management system, but it may be reclaimed if the code object becomes unreachable on the Scheme side; lock the code object (using lock-object) or otherwise retain it if the entry point is, for example, registered as a callback and retained in the "C" side indefinitely.

> The __collect_safe convention for a callable activates a calling thread if the thread is not already activated, and the thread's activation state is reverted when the callable returns.

> Mixed use of foreign-callable and foreign-procedure may result in nesting of foreign and Scheme calls, and this results in some interesting considerations when continuations are involved, directly or indirectly (as via the default exception handler). See Section 4.4 for a discussion of the interaction between foreign calls and continuations.

foreign.html §4.4:
> foreign-callable and foreign-procedure allow arbitrary nesting of foreign and Scheme calls. Because other languages do not support the fully general first-class continuations of Scheme, the interaction between continuations and nested calls among Scheme and foreign procedures is problematic. Chez Scheme handles this interaction in a general manner by trapping attempts to return to stale foreign contexts rather than by restricting the use of continuations directly. A foreign context is a foreign frame and return point corresponding to a particular call from a foreign language, e.g., C, into Scheme. A foreign context becomes stale after a normal return to the context or after a return to some other foreign context beneath it on the control stack.

> As a result of this treatment, Scheme continuations may be used to throw control either upwards or downwards logically through any mix of Scheme and foreign frames. Furthermore, until some return to a foreign context is actually performed, all return points remain valid. In particular, this means that programs that use continuations exclusively for nonlocal exits never attempt to return to a stale foreign context. ... Programs that use continuations more generally also function properly as long as they never actually return to a stale foreign context, even if control logically moves past stale foreign contexts via invocation of continuations.

> One implication of this mechanism is that the C stack pointer is not automatically restored to its base value when a continuation is used on the Scheme side to perform a nonlocal exit. If the program continues to run after the nonlocal exit, any further build-up of the C stack will add to the existing build up, which might result in a C stack overflow.

libuv `vendor/libuv/docs/src/loop.rst:122-133`:
> UV_RUN_ONCE: Poll for i/o once. Note that this function blocks if there are no pending callbacks. Returns zero when done (no active handles or requests left), or non-zero if more callbacks are expected (meaning you should run the event loop again sometime in the future).
> UV_RUN_NOWAIT: Poll for i/o once but don't block if there are no pending callbacks.

libuv `async.rst:43-51` (not bound by chez-libuv):
> uv_async_send ... Wake up the event loop and call the async handle's callback. ... It's safe to call this function from any thread.
