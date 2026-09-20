# Proposal: Promise/future combinators over callbacks (key: `promise-combinators`)

Angle: a small promise library (then / catch / all / race, cancellation,
timeouts) built purely on libuv callbacks, with **optional** `await` sugar
implemented with one-shot continuations captured *inside* libuv callbacks and
resumed from later callbacks. No scheduler, no threads, no engines. Everything
runs inside `uv-run` on the loop thread, exactly where chez-libuv requires it.

Date measured: 2026-09-19. Machine: Chez 10.4.1 tarm64osx, libuv 1.52.1,
chez-libuv v0.5.0, chez-httparse v0.2.0. Every command and verbatim output is
in Appendix A; every source citation is `path:line` or a URL.

---

## 0. One-paragraph verdict

Promises fit this stack better than I expected, for one structural reason:
chez-libuv already delivers *every* completion as a callback whose payload is
either an error or a value (`on-complete (err)`, `on-complete (err results)`,
`on-connection (err)`), and every buffer is already a fresh Scheme object at
the boundary (ADR-0009), so a promise is a one-line wrapper with no lifetime
question. The design has two tiers. **Tier 0** (promises + a microtask FIFO
drained inside the libuv callback that caused it) needs *no* Chez assumption
beyond what chez-libuv already relies on, and the whole connection driver is
written in it. **Tier 1** (`await`) needs one assumption about continuations
captured inside a `foreign-callable`; I measured it today on this machine
(1000 capture-in-callback-A / resume-in-callback-B rounds with a collection per
round, loop ran dry, teardown clean, ~120–150 ns per suspend/resume cycle) and
found the one rule that makes it safe: *control may never return normally
into the frames of the callback that captured the continuation*. Violating
that rule is trapped by Chez as an ordinary condition (`attempt to return to
stale foreign context`) rather than a crash, and — measured — chez-libuv's
store-and-reraise still delivered the stored error afterwards and the loop
survived. Where this angle is worse than plain callbacks: it adds a promise
per write on the hot path (~28 bytes, ~20 ns per `then` link measured), it
adds a miniature scheduler (the microtask FIFO) that the "no scheduler" claim
has to own up to, and rejected promises can go unobserved unless the library
reports them.

---

## 1. Sources read (with what each contributed)

| Source | Used for |
|---|---|
| `/Users/yuzu/github/chez-http-server/.plans/chez-http-server-architecture.md` | Layering, §7 backpressure, §10 pipelining policy, §11 limits, §12 error model, §13 target API, §14 testing |
| `/Users/yuzu/github/chez-libuv/docs/api.md` | Every verb signature; Flow control section (read-buffer table, write bounding, gauge contract); DNS (`uv-cancel!` semantics); Signals oneshot pattern; Timers |
| `/Users/yuzu/github/chez-libuv/docs/quickstart.md` | The three rules (async close; EOF not an error; callback raise policy) |
| `/Users/yuzu/github/chez-libuv/spike/FINDINGS.md` Q2 | Raise across C frames: propagation works, escape leaves invisible obligation, unguarded raise kills the process (exit 255) |
| `/Users/yuzu/github/chez-libuv/.plans/decisions/0007-*.md` | No guardians; explicit close |
| `/Users/yuzu/github/chez-libuv/.plans/decisions/0008-*.md` | Thirteen locked trampolines; store-and-reraise rationale |
| `/Users/yuzu/github/chez-libuv/.plans/decisions/0009-*.md` | Copy at boundary; `uv__read` is a loop; retained span is UAF after close |
| `/Users/yuzu/github/chez-libuv/.plans/decisions/0018-*.md` | No bounded write queue; consumer tracks bytes+requests |
| `/Users/yuzu/github/chez-libuv/tests/test-echo.sps` | Canonical server shape; per-connection closures; read-stop guard; iteration-capped drains |
| `/Users/yuzu/github/chez-libuv/src/libuv/loop.sls:39-70` | `uv-run` refuses re-entry (`'loop-running`), `dynamic-wind` around `uv-loop-run`, `deliver-pending-callback-error!` |
| `/Users/yuzu/github/chez-libuv/src/libuv/private/handles.sls:302-304,390-434` | `dispatch-guarded`, `read-dispatch`, `close-dispatch` |
| `/Users/yuzu/github/chez-libuv/src/libuv/stream.sls:60-135` | `uv-shutdown!`, `uv-read-start!`, `ensure-read-buffer!` (64 KiB default at :73), `uv-read-stop!`, gauge |
| `/Users/yuzu/github/chez-libuv/src/libuv/timer.sls:33-58` | Timer verbs |
| `/Users/yuzu/github/chez-libuv/src/libuv/dns.sls:78-109` | `uv-getaddrinfo!` returns the request record (for `uv-cancel!`) |
| `/Users/yuzu/github/chez-httparse/docs/api.org` | 25 callbacks; result fields; pause/resume; `parser-field-ref`; modes |
| `/Users/yuzu/github/chez-httparse/docs/conformance.org` | Every-chunk-size replay method, 274/274 |
| `/Users/yuzu/github/chez-httparse/src/httparse/grammar.sls:301-305` | `F-CONNECTION-KEEP-ALIVE 1`, `F-CONNECTION-CLOSE 2`, `F-CONNECTION-UPGRADE 4`, `F-CHUNKED 8`, `F-UPGRADE 16` |
| `/Users/yuzu/github/chez-httparse/test/common/conformance-tests.sps:29-45` | `corpus-scan-sizes` (full = 1..len), `corpus-chunk-bounds` |
| `/Users/yuzu/github/byte-machine/src/byte-machine/runtime.sls:905-960` | A paused feed leaves the span committed; the fragment is never delivered twice; `runtime.sls:994` "reentrancy, poisoned parser" |
| `/Users/yuzu/github/llhttp/test/request/pipelining.md` | The fixture shape (```http / ```log with `off=` traces) used for replay |
| https://cisco.github.io/ChezScheme/csug10.0/control.html | `call/1cc`, engines (quoted in §5) |
| https://cisco.github.io/ChezScheme/csug10.0/foreign.html | Stale foreign contexts (quoted in §5) |
| https://cisco.github.io/ChezScheme/csug10.0/threads.html | Thread-safety statements (quoted in §16) |
| https://raw.githubusercontent.com/cisco/ChezScheme/main/s/exceptions.ss | `guard` is built on `call/cc` and `$current-handler-stack` via `parameterize` (quoted in §5.4) |

---

## 2. What I measured today (details and verbatim output in Appendix A)

**M1 — parser pause inside `on-body-data` is a clean backpressure point.**
Feeding `POST /a … Content-Length: 10 … 0123456789GET /b …` with
`on-body-data` answering `callback-pause`: feed 1 (head + 5 body bytes)
→ `(status paused consumed 54 offset 54)`; `parser-resume!` → `feed-ready`;
feed 2 from offset 54 → `(status paused consumed 5 offset 59)`; resume; feed 3
with pausing off → `need-input consumed 28 offset 87`. Body spans delivered
exactly once (`"01234"`, `"56789"`), then `message-complete`, `reset`, and the
second request parsed normally. `consumed` at a pause **includes** the
delivered span, so "re-feed from `consumed`" is the whole resume protocol.
Flags at headers-complete were `32` = `F-CONTENT-LENGTH`.

**M2 — one-shot continuation captured in libuv callback A, invoked from
callback B, 1000 rounds, `(collect)` each round.** With the discipline
"every suspension and every completion escapes to the *dynamically current*
callback root", the loop ran dry, `live-handles 0`, `teardown ok`. A `guard`
established *after* resumption caught a raise correctly. My first version,
which let the completion path return normally into A's `run-step` frame,
failed with `attempt to invoke shot one-shot continuation` — that failure is
the design rule, not a detail (§5.2).

**M3 — the negative case.** A resumed coroutine that raises with **no** inner
guard: the raise reached callback A's stale `dispatch-guarded` guard (its
handler stack travels with the continuation); that guard's escape tried to
return through A's trampoline, and Chez raised `attempt to return to stale
foreign context` — an ordinary condition (`uv-callback-error? #f`,
`error? #f`) that escaped `uv-run` directly. Afterwards: `uv-loop-deferred-errors`
= `()`, the **next** `uv-run` raised `&uv-callback-error` with cause `boom`
(store-and-reraise had stored it before the trap), and `uv-loop-teardown!`
succeeded. So: the loop survives, the error is not lost, but the process would
die if the outer `uv-run` were unguarded. Hence the library — never the
user — installs the coroutine's catch-all (§5.3).

**M4 — cost.** Inside one timer callback, 200 000 suspend/resume cycles:
8 ms (~40 ns/cycle) bare; wrapped in R6RS `guard` 140–150 ns/cycle; wrapped
in `with-exception-handler` + `call/1cc` escape 120 ns/cycle. 200 000 promise
`then` links resolved synchronously: 4 ms, 28 bytes/link. (`bytes-allocated`
deltas per continuation cycle were 13–28 bytes; I do not trust that number to
include stack-segment allocation — see §15.)

---

## 3. Tier 0: the promise core (`(http-server promise)`)

### 3.1 Data

```scheme
;; A promise is a settled-once cell plus a reaction list. No thread safety:
;; chez-libuv's registry is an unsynchronised eqv-hashtable and every
;; callback runs on the loop thread (docs/api.md, ADR-0008), so neither is
;; the promise library.
(define-record-type (promise %make-promise promise?)
  (fields (mutable state)      ; 'pending | 'fulfilled | 'rejected
          (mutable value)      ; the value, or the condition
          (mutable reactions)  ; list of (vector on-ok on-err target), newest first
          (mutable on-cancel)  ; #f or thunk; called once by promise-cancel!
          (mutable observed?)  ; #t once any reaction/await is attached
          ))
```

### 3.2 Settlement and the microtask FIFO

Settling **never** runs a reaction synchronously. It appends the reactions to
a per-loop FIFO (`step-queue`), and `with-step` — the wrapper every libuv
callback body runs under — drains that FIFO *before returning to C*:

```scheme
;; with-step : uv-loop (-> any) -> any
;; Runs body, then drains the microtask FIFO to empty. Reactions enqueued
;; while draining run in the same drain (FIFO), so the queue is empty at the
;; moment control returns to libuv. Nothing ever runs outside a libuv
;; callback, and nothing needs uv_async (which is not bound).
(define (with-step loop body)
  (let ((result (body)))
    (drain-steps! loop)
    result))
```

Why a FIFO rather than synchronous resolution (three reasons, all checkable):

1. **Parser re-entrancy.** A body chunk resolves a `body-read!` promise from
   *inside* `on-body-data`, i.e. inside `parser-feed!`. If the reaction ran
   synchronously, handler code would run inside the parser's own frame and
   could call `parser-resume!`/`parser-feed!` re-entrantly — byte-machine
   poisons the parser for that (`runtime.sls:994`). Deferring to the FIFO
   guarantees no handler code runs while a feed is active.
2. **Bounded stack.** A `then` chain over already-settled promises would
   recurse; the FIFO makes it iterative.
3. **No Zalgo.** A `then` on an already-settled promise and on a pending one
   both run "later, in this step" — the same guarantee JS gives, so handlers
   can be reasoned about in one mode.

This FIFO is honestly a scheduler in miniature. It is not a *task* scheduler:
it has no timeslicing, no idle work, no thread, and it cannot run when no
libuv callback is on the stack. That is the whole of the "no scheduler"
claim.

### 3.3 API (Typed-Racket-style signatures, as AGENTS.md asks)

```scheme
;; make-promise : ((Any -> Void) (Condition -> Void) -> (U #f (-> Void))) -> Promise
;;   executor receives resolve/reject; may return a cancel thunk.
;; resolved : Any -> Promise          rejected : Condition -> Promise
;; then : Promise (Any -> Any) [(Condition -> Any)] -> Promise
;;   a reaction that returns a promise is flattened (adoption); one that
;;   raises rejects the derived promise. The reaction runs under the
;;   library's own catch-all (with-exception-handler + one-shot escape), so a
;;   raise never reaches dispatch-guarded.
;; catch : Promise (Condition -> Any) -> Promise
;; finally : Promise (-> Any) -> Promise
;; promise-all : (Listof Promise) -> Promise            ; list, in order
;; promise-race : (Listof Promise) -> Promise           ; losers are cancelled
;; promise-any : (Listof Promise) -> Promise            ; first fulfilment
;; promise-cancel! : Promise -> Boolean
;;   if pending: reject with &promise-cancelled, run on-cancel once. #f if settled.
;; promise-timeout : Promise Nat -> Promise
;;   races p against a timer-wheel deadline (§10); on timeout, cancels p and
;;   rejects with &promise-timeout.
;; promise-state : Promise -> Symbol      promise-value : Promise -> Any
;; unhandled-rejection-hook : Parameter (Condition Promise -> Void)
;;   called at the END of a drain for any promise that was rejected during
;;   this step and has observed? = #f. Default: log to stderr. A test sets it
;;   to raise, which is how "a rejection nobody looked at" becomes a failing
;;   test instead of silence.
```

The combinators are all closures over `then`; `promise-all` keeps a countdown,
`promise-race` subscribes to all and cancels the rest on first settlement.
Cancellation is cooperative and best-effort, exactly like `uv-cancel!`
("`#t` only if the work was still queued — the callback still fires, with
`'EAI_CANCELED`", docs/api.md DNS table).

### 3.4 Lifting chez-libuv verbs

Every verb whose completion is `(err)` or `(err value)` lifts identically:

```scheme
;; uv-write/p : uv-stream Bytevector Nat Nat -> Promise   ; resolves #t on completion
(define (uv-write/p stream bv start end)
  (make-promise
   (lambda (resolve reject)
     ;; A synchronous failure raises here, before anything was queued
     ;; (docs/api.md, "Bounding write memory"); make-promise turns a raise in
     ;; the executor into a rejection, so the caller sees one channel.
     (uv-write! stream bv start end (lambda (err) (if err (reject err) (resolve #t))))
     #f)))                                            ; a queued write cannot be cancelled

;; dns-lookup : uv-loop String -> Promise (Listof uv-addrinfo)
(define (dns-lookup loop host)
  (make-promise
   (lambda (resolve reject)
     (let ((req (uv-getaddrinfo! loop host #f '((socktype . stream))
                                 (lambda (err results) (if err (reject err) (resolve results))))))
       (lambda () (uv-cancel! req))))))               ; the cancel hook

;; connection-closed : Connection -> Promise   (resolved from the ONE on-close, §13)
```

---

## 4. Tier 1: `await` (optional, assumption-gated)

### 4.1 Mechanism

```scheme
;; The root is the escape continuation of the libuv callback currently on the
;; stack. It is set by run-step and is DYNAMIC: a resumed coroutine always
;; escapes to the root of the callback that resumed it, never to the root of
;; the callback that captured it.
(define current-root #f)

;; run-step : (-> any) -> Symbol
(define (run-step thunk)
  (call/1cc (lambda (root) (set! current-root root) (thunk) 'returned-normally)))

;; spawn : (-> Any) -> Promise
;; Starts a coroutine. Its completion path NEVER returns into run-step's
;; frame: it settles the promise and jumps to whatever root is current.
(define (spawn thunk)
  (let ((p (%make-promise 'pending #f '() #f #f)))
    (run-step
     (lambda ()
       (call/1cc
        (lambda (escape)
          (with-exception-handler
           (lambda (e) (reject! p e) (escape 'failed))   ; never returns into the raiser
           (lambda () (resolve! p (parameterize ((in-coroutine #t)) (thunk)))))))
       (current-root 'finished)))
    p))

;; await : Promise -> Any   (raises the rejection condition)
(define (await p)
  (unless (in-coroutine) (raise (make-await-outside-coroutine)))
  (case (promise-state p)
    ((fulfilled) (promise-value p))
    ((rejected)  (raise (promise-value p)))
    (else
     (let ((r (call/1cc
               (lambda (k)
                 (subscribe! p (lambda (v) (resume! k (cons 'ok v)))
                               (lambda (e) (resume! k (cons 'err e))))
                 (current-root 'suspended)))))       ; return to C now
       (if (eq? (car r) 'ok) (cdr r) (raise (cdr r)))))))

;; resume! is a reaction, so it runs from a drain inside SOME later callback:
(define (resume! k tagged) (run-step (lambda () (k tagged))))
```

Measured (M2): this shape ran 1000 A→B rounds with a `collect` per round and
tore down cleanly. The `spawn` promise is what the connection driver
consumes, so the driver does not know whether a handler used `await` or
`then`.

### 4.2 The one rule, and what breaks if it is broken

CSUG foreign.html: "A foreign context is a foreign frame and return point
corresponding to a particular call from a foreign language, e.g., C, into
Scheme." "A foreign context becomes stale after a normal return to the context
or after a return to some other foreign context beneath it on the control
stack." "Scheme continuations may be used to throw control either upwards or
downwards logically through any mix of Scheme and foreign frames." "Programs
that use continuations more generally also function properly as long as they
never actually return to a stale foreign context, even if control logically
moves past stale foreign contexts via invocation of continuations." "Scheme
handles this interaction in a general manner by trapping attempts to return
to stale foreign contexts."

A continuation captured inside `on-data` contains, beneath the handler's own
frames: the driver's `run-step` frame, `dispatch-guarded`'s `guard` frame
(`handles.sls:302-304`), the trampoline, and the foreign context of that
`on-data` call. After `on-data` returns to C, that context is stale. Resuming
the continuation from `write-done` is a "throw"; **finishing the handler by
returning normally** through those frames would be a return to the stale
context. Two things in my design prevent that:

- `spawn`'s completion is `(current-root 'finished)` — a throw to the
  *current* callback's root — not a return (M2's first failure was exactly
  a return to the lexical root: `attempt to invoke shot one-shot continuation`).
- Every reaction and every coroutine body runs under a catch-all installed
  by the library, so no raise can reach the stale `dispatch-guarded` guard
  (M3 shows that guard *is* live after resumption because
  `$current-handler-stack` is a parameter restored by the continuation, and
  its escape is a return to the stale context).

### 4.3 Why `with-exception-handler` + `call/1cc`, not `guard`

Chez's `guard` expands to `$guard`, which captures with `call/cc` twice
(exceptions.ss: "`(call/cc (lambda (kouter) ... (with-exception-handler
(lambda (arg) (call/cc (lambda (kinner)`"), and handlers live in
"`(parameterize ([$current-handler-stack (cons handler ($current-handler-stack))]) (thunk))`".
CSUG control.html: "A one-shot continuation is 'promoted' into a normal
(multishot) continuation, however, if it is still active when a normal
continuation is obtained by call/cc." So a `guard` inside a coroutine
promotes the active one-shot root. Measured cost (M4): 140–150 ns vs 120 ns
per cycle — negligible, but the library's own wrapper uses the cheaper form
and, more importantly, the one whose semantics do not depend on promotion.
Handlers are free to use `guard`; it works (M2).

### 4.4 `dynamic-wind` hazard

`uv-run` wraps `uv-loop-run` in `dynamic-wind` (`loop.sls:60-63`). A
continuation captured in one `uv-run` call and resumed in a *different*
`uv-run` call (a test driver running `'once` repeatedly) will run the
current call's after-thunk and the old call's before-thunk on resume, and
the reverse on the escape. With `set-loop-running!` these are idempotent
`set!`s so the net state is right, but the rule for the driver is: **no
`dynamic-wind` or `parameterize` around a step whose thunks are not
idempotent.** The production server runs one `uv-run loop 'default`; the
test harness runs `'once` and asserts loop-running? is #f between calls.

### 4.5 Fallback if the live spike says no

If invoking a continuation captured inside a foreign-callable after it
returned is *not* supported, Tier 1 is deleted and nothing else changes: the
driver and all four handler sketches have `then` forms. There is no
thread-based fallback: a handler thread could not wake the loop, because
`uv_async` is not bound, and could not touch handles, because the registry is
single-thread.

---

## 5. Handler API

```scheme
;; A handler is (Request -> (U Response Promise)). A plain Response is lifted
;; with `resolved`. The driver only ever sees a Promise of a Response.
;; respond : Nat Headers (U Bytevector #f) -> Response        ; complete body
;; respond/stream : Nat Headers (Sink -> Promise) -> Response  ; streaming body
;; sink-write! : Sink Bytevector -> Promise   ; resolves when this connection's
;;      outstanding bytes are at or under high-water (immediately if so);
;;      rejects with &transport-error if the peer went away.
;; sink-end! : Sink -> Promise               ; final chunk / last-chunk; resolves on drain
;; request-body : Request -> BodySource
;; body-read! : BodySource -> Promise (U Bytevector Eof)   ; one chunk, backpressured
;; body-bytevector : BodySource Nat -> Promise Bytevector ; buffered up to limit, else &body-too-large
```

### (1) Trivial respond

```scheme
(define (hello req)
  (respond 200 '((content-type . "text/plain")) (string->utf8 "hello\n")))
```

### (2) Streaming a large body with backpressure

```scheme
;; then-form: one write in flight per iteration is the simplest correct
;; policy; the promise resolves early when outstanding <= high-water, so the
;; kernel is kept busy without the producer running ahead.
(define (big req)
  (respond/stream 200 '((content-type . "application/octet-stream"))
    (lambda (sink)
      (let loop ((i 0))
        (if (= i n-chunks)
            (sink-end! sink)
            (then (sink-write! sink (chunk-ref i))
                  (lambda (_) (loop (+ i 1)))))))))

;; await-form (Tier 1): the same loop, written straight.
(define (big/await req)
  (respond/stream 200 '((content-type . "application/octet-stream"))
    (lambda (sink)
      (spawn (lambda ()
               (do ((i 0 (+ i 1))) ((= i n-chunks))
                 (await (sink-write! sink (chunk-ref i))))
               (await (sink-end! sink)))))))
```

### (3) Consuming a large request body incrementally

```scheme
(define (upload req)
  (let ((body (request-body req)))
    (let loop ((total 0))
      (then (body-read! body)
            (lambda (chunk)
              (if (eof-object? chunk)
                  (respond 200 '() (string->utf8 (number->string total)))
                  (then (store-chunk! chunk)               ; itself a promise
                        (lambda (_) (loop (+ total (bytevector-length chunk)))))))))))
```

Each `body-read!` is the demand signal: the parser is *paused* between
chunks and the socket is read-stopped when a delivery arrives with no demand
(§9.1), so a slow `store-chunk!` throttles the peer.

### (4) Awaiting an external async result (DNS)

```scheme
(define (whois req)
  (then (promise-timeout (dns-lookup (request-loop req) (query-param req "host")) 2000)
        (lambda (addrs) (respond 200 '() (render-addrs addrs)))
        (lambda (e)
          (cond ((promise-timeout? e) (respond 504 '() (string->utf8 "resolver timeout")))
                ((uv-errno-error? e)  (respond 502 '() (string->utf8 (symbol->string (uv-errno-error-errno e)))))
                (else (raise e))))))                     ; anything else -> 500 by the driver
```

`promise-timeout` cancels the DNS promise on expiry; the cancel hook calls
`uv-cancel!`, whose completion still fires with `'EAI_CANCELED` and is
absorbed because the promise is already settled.

---

## 6. Connection driver

### 6.1 Functional core / imperative shell split

```
(http-server connection)   -- CORE: no libuv import. Owns the parser, the
                              request FIFO, limits, deadlines-as-numbers.
                              (conn-event! core event) -> (Listof Action)
(http-server driver)       -- SHELL: maps libuv callbacks -> events and
                              actions -> libuv verbs / promise settlements.
(http-server promise)      -- Tier 0/1 above; no libuv import except the
                              timer-wheel deadline registration (§10).
```

Events (into the core):

```
(data bv start end) (eof) (read-error cond) (write-done tag err)
(tick now-ms) (response-head rid status headers body-mode)
(response-chunk rid bv) (response-end rid) (handler-failed rid cond)
(body-demand rid) (drain-requested) (closed)
```

Actions (out of the core):

```
(write bv start end tag) (read-stop) (read-start) (shutdown) (close reason)
(start-handler request) (settle tag value) (reject tag cond)
(deadline kind at-ms) (deadline-clear) (log level datum)
```

`tag`s are opaque integers; the shell keeps `tag -> promise`. This is what
lets the corpus replay (§14) run the core with **no promises and no
sockets**: a test interprets `(settle tag v)` by recording it.

### 6.2 libuv callback → model

| libuv callback | Shell does |
|---|---|
| `uv-listen!` on-connection `(err)` | `err` → log. Else `uv-accept!` (guarded: EAGAIN is recorded, not raised — test-echo.sps:311-316), check `max-connections` (over → `uv-close!` immediately via `connection-close!`), `uv-tcp-nodelay! #t`, build core, register in the server table, `uv-read-start!` with the three closures below, `(deadline header)` |
| on-data `(bv start end)` | `(with-step loop (lambda () (apply-actions! (conn-event! core (data bv start end)))))` — the core loops `parser-feed!` honoring `consumed`, pause, and the close marker (§6.4) |
| on-eof `()` | event `(eof)`. Core: if no request in flight → `(shutdown)` then close; else mark `half-closed`, responses may still be written, close after the last |
| on-error `(cond)` | event `(read-error cond)` → core rejects every pending tag with `&transport-error` (composed with the `&uv-errno-error`) and emits `(close read-error)` |
| `uv-write!` on-complete `(err)` | event `(write-done tag err)` → core decrements outstanding bytes/requests (both, per docs/api.md "Bounding write memory"), emits `(settle tag #t)` for the write and for any drain waiters now under low-water, or `(reject tag err)` + `(close write-error)` |
| `uv-shutdown!` on-shutdown `(err)` | `connection-close!` |
| `uv-close!` on-close `()` | deregister from the server table; settle `connection-closed`; if the server is draining and the table is empty, settle `server-drained` |
| wheel timer on-timeout | event `(tick (uv-now loop))` on every connection whose deadline is due (§10) |
| `uv-signal-start-oneshot!` sigterm | `server-stop!` (§12) |
| `uv-getaddrinfo!` on-complete | settle/reject the DNS promise (§3.4) |

Every one of these bodies runs under `with-step`, and `with-step` itself
has **no** guard: a condition that escapes it is a driver bug and is meant
to reach `dispatch-guarded` → store → `uv-run` raises `&uv-callback-error`
(§11.5). Handler conditions never get that far because `spawn`/`then`
convert them to rejections.

### 6.3 The 25 parser callbacks → model

All bound (a hole is refused at `make-parser`, api.org "Making a parser").
The `ctx` argument is the core record. Span bytes are copied before return
(api.org: "The bytes are not copied and are not retained: copy what you need
before returning"), except body spans which are copied into the delivery.

| Callback | Core action |
|---|---|
| `on-message-begin` | If `parsed-not-finished >= max-pipeline` → return `callback-pause` (§8). Else open a head accumulator; `(deadline header)` if idle |
| `on-method-data` / `-complete` | accumulate; at complete read `(parser-field-ref p 'method)` |
| `on-url-data` / `-complete` | accumulate; enforce `max-target-bytes` → `(make-callback-failure 'target-too-large …)` (→ 414); at complete keep the bytevector; `uri-parse` (uriparse, `'uri-reference` mode) runs lazily in `request-path`/`query-param` |
| `on-protocol-data` / `-complete`, `on-version-data` / `-complete` | continue; version is read from `'http-major`/`'http-minor` at headers-complete |
| `on-status-data` / `-complete` | `(make-callback-failure 'status-in-request …)` — a request parser can never legally fire these; a check, not a comment |
| `on-header-field-data` / `-complete` | accumulate name; enforce `max-header-name-bytes` |
| `on-header-value-data` / `-complete` | accumulate value; at complete push `(name . value)`; enforce `max-header-count`, `max-header-bytes-total` (→ 431) |
| `on-headers-complete` | **Read here, inside the callback** (task brief; api.org "content-length … Read it inside on-headers-complete"): `flags`, `content-length`, `http-major/minor`, `upgrade`. Decide `keep-alive?` = HTTP/1.1 and not `F-CONNECTION-CLOSE`, or HTTP/1.0 and `F-CONNECTION-KEEP-ALIVE`; `close-after?` = `F-CONNECTION-CLOSE`. Build the `request` record with a fresh `body-source`; push onto the FIFO; `(deadline body)` if a body is expected else `(deadline-clear)`; emit `(start-handler req)` if fewer than `max-handlers-started` are running (§8). Return nothing (no `'skip-body`; upgrades are refused with 501 in v1 — `F-UPGRADE` set → mark `close-after?`) |
| `on-body-data` | If the request's body-source has a pending demand tag → copy span, `(settle tag chunk)`, `(deadline body)`; return `callback-continue`. Else if the body-source is in `discard` mode → count against `max-discard-body-bytes`, continue. Else → **`callback-pause`** (M1: `consumed` includes this span; nothing is redelivered) |
| `on-chunk-header`, `on-chunk-complete`, `on-chunk-extension-*` | continue; extension bytes dropped; extension length counted against `max-chunk-extension-bytes` |
| `on-message-complete` | settle the body-source's pending demand (if any) with `eof`, else mark it `eof-ready`; `(deadline-clear)` then `(deadline idle)` if keep-alive; if `close-after?` → set `stop-feeding` so the core does **not** feed the remaining bytes (measured by the orchestrator: llhttp reports data-after-close as an error, so the connection layer stops first) |
| `on-reset` | assert accumulators empty (a check); continue |

### 6.4 The feed loop (core)

```scheme
;; feed! : Core Bytevector Nat Nat -> (Listof Action)   (pure w.r.t. I/O)
(define (feed! core bv start end)
  (let loop ((at start))
    (cond
      ((core-stop-feeding? core) (emit core `(read-stop)))          ; Connection: close seen
      ((core-paused? core) (set-core-leftover! core (vector bv at end)) (emit core `(read-stop)))
      ((>= at end) (emit-nothing))
      (else
       (let ((r (parser-feed! (core-parser core) bv at end)))
         (case (parser-result-status r)
           ((need-input) (loop (+ at (parser-result-consumed r))))
           ((paused)     (set-core-paused! core #t)
                         (loop (+ at (parser-result-consumed r))))   ; stores leftover next round
           ((error)      (policy-error! core (parser-result-error r)))  ; -> 400 + close
           (else         (policy-error! core 'terminal-state))))))))
```

When a demand arrives (`(body-demand rid)`) or a response completes (pipeline
slot freed): `parser-resume!`, re-run `feed!` over the leftover, and only
when the leftover is exhausted emit `(read-start)`. The shell guards
`(read-stop)` with `uv-handle-open?` (docs/api.md, "The read-stop/read-start
pairing invariant").

---

## 7. Pipelining

- The core keeps a FIFO of requests. The parser may run ahead up to
  `max-pipeline` (default 8) *parsed* heads; the ninth `on-message-begin`
  pauses (§6.3), which read-stops the socket.
- **Response ordering is a promise.** Every response object carries a
  `ready` promise, resolved when (a) it is the FIFO head and (b) the previous
  response's final write completed. `respond`, `sink-write!` and `sink-end!`
  are all `(then (response-ready r) (lambda (_) …))`, so a handler that
  finishes first for a later request simply waits at its first write.
- `max-handlers-started` (default 1) caps how many handlers run
  concurrently per connection. At 1 the behaviour is the conservative one the
  architecture plan suggests ("optionally avoid concurrent execution
  initially"), and a handler's DNS wait does not block *parsing* of the next
  request — only its dispatch. Raising it lets handlers overlap; their output
  still serialises through `ready`. Memory for a not-yet-head response is
  bounded because `sink-write!` on a non-ready response does not buffer: the
  promise simply does not resolve until it is head, and the producer is
  waiting on it.
- Bodies are sequential on the wire, so a later request's body cannot be
  consumed before the earlier one's; a handler that never reads its body has
  its body-source switched to `discard` when its response ends (bounded by
  `max-discard-body-bytes`, default 1 MiB; over → `close-after?`).
- A parse or policy error after N accepted requests: the core marks the
  connection `closing-after-drain`, lets the queued responses finish in
  order, then writes the 400/431/413 and closes.

---

## 8. Backpressure, both directions

### 8.1 Read side (peer → handler)

Demand-driven at two levels: the parser pause (M1) and `uv-read-stop!`.
Sequence for a large upload: `on-data` (≤64 KiB) → `parser-feed!` →
`on-body-data` with a demand pending → `(settle tag chunk)` → continue →
next span, no demand → `callback-pause` → leftover stored → `(read-stop)`.
Handler's `then` runs in the drain, calls `body-read!` → `(body-demand rid)`
→ `parser-resume!`, re-feed leftover → span delivered → pause again or, if
the leftover is exhausted, `(read-start)`. Resident per connection while
paused: the one 64 KiB read buffer (foreign) + at most one leftover
bytevector (the last delivery, ≤64 KiB). No accumulation in Scheme, which is
architecture §7's requirement.

Because the parser is paused *between* deliveries and the socket is stopped
*between* reads, a stalled consumer costs the kernel's receive-buffer charge
(docs/api.md: "becomes the dominant cost exactly when the application has
stopped reading") — which is exactly the pressure that should reach the peer.

### 8.2 Write side (handler → peer)

Per connection: `outstanding-bytes`, `outstanding-writes`, incremented only
after `uv-write!` returned (a synchronous raise queued nothing), decremented
in `write-done` — docs/api.md's prescription and ADR-0018's division of
labour. `sink-write!` returns a promise that resolves immediately when
`outstanding-bytes <= write-high-water` (default 64 KiB), otherwise it is
parked as a drain waiter resolved when the count drops to
`write-low-water` (16 KiB). `uv-stream-write-queue-size` is read at the same
decision point as a supplemental signal: above `queue-high-water` the write
is parked regardless of our own count (Unix semantics; on Windows the gauge
counts kernel-accepted overlapped sends, so the threshold is a config knob
with a platform default, not a constant — ADR-0018 / api.md "gauge's
contract, stated portably"). A `finished` promise on the response resolves
when outstanding is 0 and `sink-end!` was called; the pipeline uses that to
release the next `ready`.

While a connection's writes are parked, the read side is *not* stopped on
that account (pipelining cap already bounds it); a slow reader that keeps
sending requests hits `max-pipeline` and gets read-stopped there.

---

## 9. Timeouts and limits

### 9.1 One timer handle per server, not per connection

A `uv-timer` is a handle: 152 bytes (spike/FINDINGS.md probe:
`uv_handle_size(UV_TIMER) 152`), a registry entry, a close protocol
(ADR-0007), and one more close-ownership hazard. At 10k connections that is
10k handles to close on drain. Instead the server owns **one** repeating
timer (`wheel-tick-ms`, default 1000) and three intrusive FIFO lists keyed by
deadline kind (header, body, idle), each ordered by expiry because every
member has the same timeout value: touching a connection moves it to the
tail, and the tick pops from the head while `expires-at <= (uv-now loop)`.
O(1) touch, O(expired) tick. `promise-timeout` deadlines (arbitrary
durations) go in a fourth structure, a binary heap keyed by expiry; at
10k connections a heap operation is ~14 comparisons.

Granularity is coarse (±1 s) by design; HTTP timeouts are tens of seconds.
Tests use a `tick` event with an explicit `now`, so they never sleep.

### 9.2 Kinds

| Kind | Starts | Cleared | Expiry |
|---|---|---|---|
| header (default 30 s) | accept; and again at `on-message-begin` after idle | `on-headers-complete` | 408 + close if nothing was written for this request; else close |
| body (60 s, idle between bytes) | `on-headers-complete` with a body; re-armed on each body span | `on-message-complete` | 408 + close, reject pending `body-read!` |
| idle keep-alive (15 s) | `on-message-complete` with an empty FIFO | next `on-message-begin` | close silently |
| write/drain (30 s) | when any drain waiter is parked | outstanding under low-water | reject the waiter with `&promise-timeout`, close |
| handler (optional, off) | `(start-handler)` | response `finished` | reject handler promise → 503 if head unsent, else close |
| shutdown drain (30 s) | `server-stop!` | table empty | force-close all remaining |

### 9.3 Limits (server policy, not grammar — architecture §11)

`max-connections 10000`, `max-target-bytes 8192`, `max-header-name-bytes 1024`,
`max-header-bytes-total 65536`, `max-header-count 100`, `max-pipeline 8`,
`max-handlers-started 1`, `max-buffered-body-bytes 1 MiB` (only for
`body-bytevector`), `max-discard-body-bytes 1 MiB`, `max-chunk-extension-bytes 1024`,
`write-high-water 65536`, `write-low-water 16384`, `queue-high-water (platform)`,
`read-buffer-bytes 65536` (passed to the first `uv-read-start!`; see §15 for why
a many-connections profile sets 16384). Every limit is a field on the
`server-config` record, 12-factor-style overridable from the environment by
the program, not the library.

---

## 10. Error propagation

| Class | Where it surfaces | What happens |
|---|---|---|
| **Parser error** (`parser-result-status 'error`) | core `feed!` | `policy-error!`: record `(parser-error-code e)`/offset; if the FIFO is empty write `400` and `(close parse-error)`; else `closing-after-drain` (§7). Never fed again. |
| **Policy error** (limit hit via `make-callback-failure`, or timeout) | core | mapped: `414` target, `431` headers, `413` body-too-large, `408` timeouts, `501` upgrade; then close |
| **Handler exception** (raise in a `then` reaction or in a `spawn` body) | promise library catch-all | rejection of the handler promise → driver: head not yet sent → `500` with empty body, log the condition; head sent → `(close handler-error)` (a truncated body is the only honest signal). It **never** reaches `dispatch-guarded`. |
| **Unobserved rejection** | end of drain | `unhandled-rejection-hook` (default: log; tests: raise) |
| **Transport error** (`on-error` condition, write `err`, shutdown `err`) | shell → core event | every pending tag rejected with `&transport-error` wrapping the `&uv-errno-error` (`condition` composition keeps `uv-errno-error?` true, same trick chez-libuv uses for `&uv-callback-error`); `(close transport)` |
| **Driver bug** (invariant violated in core or shell) | escapes `with-step` | `dispatch-guarded` stores it, `uv-stop!`, the rest of the iteration's queued callbacks run, `uv-run` raises `&uv-callback-error`; later raises in the same run are in `uv-loop-deferred-errors`. The server's `run!` loop: log, close the offending connection if identifiable, re-enter `uv-run` (the loop survives — FINDINGS Q2 `store` scenario; and M3 shows this holds even after a stale-context trap), with a crash-loop breaker (N re-entries per minute → exit non-zero). In tests, `run!` re-raises instead. |
| **Stale-context return** (a resumed coroutine escaped through frames of the callback that captured it) | `uv-run` raises `attempt to return to stale foreign context` (plain condition, M3) | Treated as a driver bug. The library's catch-all makes it unreachable from handler code; a test asserts that a raising resumed coroutine yields a rejected promise and **no** raise from `uv-run` (watched to fail by removing the catch-all: M3 is that failing run). |

The unguarded-raise-kills-the-process fact (FINDINGS Q2 `bare`, exit 255) is
why `run!` wraps `uv-run` in `guard` and why the `with-step` bodies are the
*only* place a condition is allowed to reach the trampolines.

---

## 11. Graceful shutdown

```scheme
;; server-stop! : Server -> Promise   ; resolves when every connection has closed
(define (server-stop! srv)
  (connection-close! (server-listener srv) 'shutdown)      ; stop accepting
  (set-server-draining! srv #t)
  (for-each (lambda (c) (conn-drain! c)) (server-connections srv))
  (promise-timeout (promise-all (map connection-closed (server-connections srv)))
                   (server-drain-deadline-ms srv)))

;; conn-drain! : idle -> close now; active -> responses get "Connection: close",
;; on-message-begin pauses (no new requests), close after the last response.
;; The signal watcher (already auto-disarmed) and the wheel timer are closed
;; when the drain promise settles; the loop then runs dry and uv-run returns.
(uv-signal-start-oneshot! watcher 'sigterm
  (lambda (sig)
    (then (server-stop! srv)
          (lambda (_) (finish-shutdown! srv))
          (lambda (e) (force-close-all! srv) (finish-shutdown! srv)))))
```

A second SIGTERM after the oneshot fired has default disposition and kills the
process (docs/api.md Signals: "the disposition reverts to `SIG_DFL` once the
oneshot fires") — the documented "first drains, second kills" behaviour.
After `uv-run` returns, `uv-loop-teardown!` is the belt-and-braces sweep.

---

## 12. Close-ownership protocol

docs/api.md and ADR-0018's `close-dispatch` excerpt establish that a second
`uv-close!` on a `'closing` handle silently discards its callback. Therefore:

```scheme
;; connection-close! : Connection Symbol -> Void
;; THE ONLY caller of uv-close! for a connection's tcp handle. Idempotent:
;; the first reason wins and is recorded; the on-close is passed exactly
;; once. A test closes twice and asserts one on-close and the first reason.
(define (connection-close! c reason)
  (when (eq? (connection-state c) 'open)
    (set-connection-state! c 'closing)
    (set-connection-close-reason! c reason)
    (reject-all-pending! c (make-connection-closing reason))
    (when (uv-handle-open? (connection-tcp c))
      (uv-close! (connection-tcp c)
                 (lambda ()
                   (set-connection-state! c 'closed)
                   (server-deregister! (connection-server c) c)
                   (resolve! (connection-closed-promise c) reason))))))
```

Paths that end in close all go through it: EOF, read error, write error,
shutdown complete, parse/policy error, timeouts, handler abort, drain
deadline, `max-connections`. `uv-shutdown!` precedes the close only when
there is unflushed output (test-echo.sps:265-270 pattern). `uv-loop-teardown!`
is never relied on for a connection the server knows about: the server calls
it only after its table is empty, so the discarded-callback hazard cannot
arise from the sweep either.

---

## 13. Testability under FCIS / TDD / mutation

### 13.1 Corpus replay through the *connection* layer, every chunk size, no sockets

The core takes `(data bv start end)` events and returns actions. Reusing the
scan schedule chez-httparse already defines (`corpus-scan-sizes`: full = 1..len,
`corpus-chunk-bounds`; `test/common/conformance-tests.sps:29-45`) and its
corpus loader, the lane is:

```
for each fixture in llhttp test/request/*.md (type=request):
  for each chunk size s in 1..len:
    core <- fresh core with a scripted handler that answers
            (response-head rid 200 '((content-length . "0")) 'none) synchronously
    feed the ```http block as (data …) events of size s
    record: request records built (method, target, version, headers, body bytes,
            close-after?, keep-alive?), the action stream, and for error
            fixtures the mapped status + parser-error-code + offset
  assert:
    (a) the request records are identical across all s (chunk-invariance);
    (b) the action stream with (read-stop)/(read-start) pairs elided is identical across s;
    (c) the record content equals the fixture's ```log trace projected to
        spans/events (method, url, header_field/value, body, headers-complete
        flags & content_length, message-complete count) — the same projection
        chez-httparse's comparator makes, so no second oracle is invented;
    (d) for pipelining fixtures (test/request/pipelining.md) the responses are
        emitted in request order and exactly one per message-complete;
    (e) for `pausing.md` fixtures the pause/resume protocol is exercised.
```

No promise is constructed in this lane: `(settle tag v)` is recorded. That is
the point of the tag indirection.

### 13.2 With sockets

A second lane runs a subset (pipelining, connection, content-length,
chunked) over loopback, test-echo.sps style: bind `127.0.0.1:0`, a client on
the same loop writes the fixture in the chosen chunk sizes (1, 7, len),
collects the response bytes, and the suite drains with an iteration cap, not
a timeout (`run-until/ticking`, test-echo.sps:45-49). Backpressure rows:
client 0 stops reading mid-stream and the row asserts the server's
`outstanding-bytes` plateaus at high-water and its `sink-write!` promise is
still pending; restart, assert resolution.

### 13.3 Promise library and await, without libuv

Pure: `(run-microtasks!)` is called explicitly; every combinator has a
watched-to-fail test (e.g. `promise-race` losers cancelled: remove the
cancel and the on-cancel counter row fails). `await` tests provide a root via
`run-step` in plain Scheme — nothing in `await` depends on libuv, only on
`current-root`.

### 13.4 Mutation rows (each watched to fail)

- delete `(read-stop)` emission on pause → chunk-invariance row (b) still
  passes (by design, elided) but the socket backpressure row fails: the
  stopped client keeps receiving. Good: the row that fails names the
  property.
- delete the `ready` gating → the "handler B answers before handler A" socket
  row sees B's bytes first.
- make `connection-close!` non-idempotent → the double-close row counts two
  on-close callbacks (or a discarded one).
- remove the coroutine catch-all → M3 reproduces: `uv-run` raises the
  stale-context condition instead of the handler promise rejecting.
- stop reading flags inside `on-headers-complete` (read at message-complete
  instead) → `connection.md` close/keep-alive rows fail because reset zeroed
  them.
- feed past a close-marked message → llhttp-style data-after-close error row
  fails (the orchestrator's measurement today).

---

## 14. Performance

**Per request (then-form, trivial respond, keep-alive):** request record
(1), header pairs (2 allocations per header: copied name+value bytevectors,
plus a pair), target bytevector (1), body-source (1), response record (1),
promises: handler result (1), `ready` (1), one write promise for the
serialised head+body (1), reactions ~3 closures + 3 vector cells, FIFO
conses ~3, the serialised response bytevector (1), the foreign write block
(192 B request + payload, freed before on-complete — ADR-0009 amendment).
Roughly 20 small Scheme objects + 1 header/body bytevector per request;
measured cost of a `then` link is 28 bytes / ~20 ns, so the promise share
is ~100 bytes and well under a microsecond. Await-form adds one `call/1cc`
per suspension (~120–150 ns per suspend+resume, M4).

**Per connection resident:** 65536 B foreign read buffer (stream.sls:73;
docs table: ~625 MiB at 10k) + `uv_tcp_t` 264 B (FINDINGS probe) + registry
entry + core record (~15 fields) + parser record (byte-machine: callback
vector + fields; small) + request FIFO. Scheme side ≈ 1–2 KiB; the read
buffer dominates by 30×. For the many-connections profile the server passes
`read-buffer-bytes 16384` (docs table: ~160 MiB at 10k, "close to free" for
small-message traffic); bulk-transfer deployments keep 65536. Timers: one
handle per server (§9.1). Suspended `await` coroutines additionally pin
their stack segment; I did not measure segment size (assumption A6) —
the then-form pins only closures.

**Per write:** one foreign block (ADR-0009), one promise, one reaction; the
gauge read is allocation-free (docs/api.md).

**Hot-path cautions:** `with-step`'s drain is a loop over a queue — a
pathological handler that resolves 10⁶ promises in one step runs them all
before the loop regains control, same as a callback that loops 10⁶ times.
No preemption exists in any of the six angles without threads.

---

## 15. Chez assumptions (stated, not assumed)

- **A1.** A one-shot continuation captured inside a `foreign-callable` body
  may be invoked after that callable has returned to C, provided the resumed
  computation never returns normally to that (now stale) foreign context and
  instead leaves by invoking another continuation (CSUG foreign.html, quoted
  in §4.2). *My measurement today (M2) is consistent with this on tarm64osx;
  the separate spike is authoritative; if it fails, Tier 1 is dropped (§4.5).*
- **A2.** Returning to a stale foreign context is *trapped* as a raise of an
  ordinary condition, not undefined behaviour (CSUG: "trapping attempts to
  return to stale foreign contexts"; M3 observed the message `attempt to
  return to stale foreign context` and a surviving loop).
- **A3.** The exception-handler stack (`$current-handler-stack`, a
  parameter) and `dynamic-wind` winders are part of the captured
  continuation and are reinstated on resume (M3: the stale
  `dispatch-guarded` guard caught a post-resume raise). Consequence: the
  library's catch-all must be the innermost handler around every resumed
  body.
- **A4.** `call/1cc` semantics per CSUG: "A one-shot continuation should not
  be returned to multiple times, either by invoking the continuation or
  returning normally from procedure more than once." and promotion to
  multishot if `call/cc` is called while it is active. `guard` calls
  `call/cc` (exceptions.ss), so a `guard` inside a coroutine promotes the
  root; measured cost is negligible (M4). Handler code that itself uses
  `call/cc` to re-enter a resumed body twice is unsupported and will raise
  `attempt to invoke shot one-shot continuation`.
- **A5.** Single loop thread. CSUG threads.html: "Most primitive Scheme
  procedures are thread-safe … Other destructive operators are thread safe
  only if they are used to operate on different objects from those being
  read or modified by other threads." The promise library, the microtask
  FIFO, the wheel and the registry are all single-thread by construction; DNS
  completions arrive on the loop thread (docs/api.md DNS: "no Scheme ever
  runs off the loop thread").
- **A6.** The memory retained by a suspended coroutine is its stack segment
  from the capturing callback's entry to the await point; I have not
  measured its size or Chez's segment allocation policy. `bytes-allocated`
  deltas in M4 (13–28 B/cycle) are suspiciously small and may not include
  segment allocation.
- **A7.** Engines are not used: CSUG control.html "Do not use the timer
  interrupt (see set-timer) and engines at the same time, since engines are
  implemented in terms of the timer." — and an engine block from inside a
  foreign-callable would be a return-to-stale-context by another name.
- **A8.** `uv-run`'s `dynamic-wind` after/before thunks are idempotent
  (`loop.sls:60-63`), so cross-`uv-run` resumption in tests is harmless
  (§4.4). The driver adds no non-idempotent winders of its own.

---

## 16. Risks — including where this angle is simply worse

1. **It is a scheduler after all.** The microtask FIFO is the thing that
   makes promises safe against parser re-entrancy; a judge who wanted "raw
   callbacks, nothing between me and libuv" is right that this is a layer.
   Mitigation: it is ~30 lines and its ordering is unit-tested.
2. **Tier 1 rests on A1.** If the live spike says no, the ergonomic win
   shrinks to `then` chains, which in Scheme without arrow-function sugar
   read worse than in JS. The four sketches all have `then` forms so the
   design does not collapse, but the pitch does.
3. **Stale-context hazards are one `raise` away.** Any path that lets a
   condition escape a resumed coroutine to the capturing callback's guard
   produces M3. The catch-all is mandatory and library-owned; user code that
   installs its own `with-exception-handler` that *returns* (for
   `raise-continuable`) is fine, but user code that captures a full
   continuation inside a handler and re-enters it later is a trap. This is a
   class of bug plain callbacks cannot have.
4. **Swallowed errors.** A promise rejected with no reaction is silence by
   default in most promise libraries. The `unhandled-rejection-hook` is the
   mitigation and it only fires at drain end; a rejection whose reaction is
   attached in a *later* step is reported spuriously (JS has the same
   wart). Plain callbacks make the error path explicit at every site.
5. **Per-write promise on the hot path.** ~28 B + ~20 ns per link, plus a
   reaction closure — a raw-callback design allocates the completion closure
   anyway, so the delta is one promise record per write. Measurable, not
   decisive.
6. **Cancellation is cosmetic for writes.** A queued `uv_write` cannot be
   cancelled (ADR-0018: the binding submits immediately); `promise-cancel!`
   on a write promise only detaches reactions. Only DNS has a real cancel.
7. **Debuggability.** A resumed coroutine's continuation chain contains
   frames of a callback that finished long ago; inspector output is
   confusing. `then` chains have the opposite problem (no chain at all).
8. **Memory of suspended coroutines at 10k connections** is unmeasured
   (A6); if a segment is several KiB, 10k suspended `await`s is tens of MiB
   — still small next to 625 MiB of read buffers, but not zero.
9. **`dynamic-wind`/`parameterize` interaction** (§4.4) is a footgun for
   contributors: a `parameterize` around a step whose value matters after a
   resume will be silently wrong.
10. **Windows**: the write-queue gauge inverts meaning; the design keeps the
    gauge supplemental, but `queue-high-water` needs per-platform
    calibration and Windows is deferred anyway (ADR-0004).
11. **Where a plain-callback design is better outright:** a server whose
    handlers are all synchronous (`respond` immediately) gains nothing from
    promises and pays items 1, 4 and 5. Where an engine/thread design is
    better: CPU-bound handlers — no angle without preemption helps there,
    and threads cannot touch the loop without `uv_async`, which is unbound.

---

## Appendix A — commands run and verbatim output

All scripts are in
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike-promise/`.

### A.1 M1 — parser pause in `on-body-data` (`parser-pause.sps`)

```
cd /Users/yuzu/github/chez-httparse && chez --libdirs /Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src --program .../spike-promise/parser-pause.sps
```
```
feed 1 (head + 5 body bytes, body pauses): (status paused consumed 54 offset 54 pause #f)
resume -> feed-ready
feed 2 (rest, body pauses again after 5 more): (status paused consumed 5 offset 59 pause #f)
resume -> feed-ready
feed 3 (rest, no pause): (status need-input consumed 28 offset 87 pause #f)
events:
  (message-begin)
  (method "POST")
  (method-complete)
  (url "/a")
  (url-complete)
  (protocol "HTTP")
  (protocol-complete)
  (version "1.1")
  (version-complete)
  (field "Host")
  (field-complete)
  (value "x")
  (value-complete)
  (field "Content-Length")
  (field-complete)
  (value "10")
  (value-complete)
  (headers-complete (flags 32 content-length 10))
  (body "01234")
  (body "56789")
  (message-complete)
  (reset)
  (message-begin)
  (method "GET")
  (method-complete)
  (url "/b")
  (url-complete)
  (protocol "HTTP")
  (protocol-complete)
  (version "1.1")
  (version-complete)
  (field "Host")
  (field-complete)
  (value "x")
  (value-complete)
  (headers-complete (flags 0 content-length 0))
  (message-complete)
exit=0
```

### A.2 M2/M3 — capture in callback A, resume in callback B (`await-timer.sps`)

```
cd /Users/yuzu/github/chez-libuv && CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs chez --program .../spike-promise/await-timer.sps guarded
```
```
(scenario guarded outcome ran-dry rounds 1000 ms 1129)
  A-enter
  (A-step suspended)
  A-return-to-C
  B-enter
  (resumed-with 0)
  (caught-after-resume "after-resume")
  (B-step finished)
  B-return-to-C
  A-enter
  ... (repeats; trace capped at 40 lines) ...
  (B-step finished)
  B-return-to-C
(live-handles 0)
teardown ok
```
(The 1129 ms is 1000 rounds of a 1 ms timer, not continuation cost.)

```
... await-timer.sps unguarded
```
```
(scenario unguarded outcome (uv-run-raised other attempt to return to stale foreign context) rounds 0 ms 1)
  A-enter
  (A-step suspended)
  A-return-to-C
  B-enter
  (resumed-with 0)
(live-handles 2)
(teardown-raised #<compound condition>)
```

First (wrong) version of the same script, whose completion path returned
into A's `run-step` frame and invoked A's root:
```
(outcome (uv-run-raised #<compound condition>) rounds 1)
  A-enter
  (A-step-result suspended)
  A-return-to-C
  B-enter
  (resumed-with hello)
  (caught-after-resume "after-resume")
Exception: attempt to invoke shot one-shot continuation
```

### A.3 M3 detail — what the trap leaves behind (`stale-detail.sps`)

```
uv-run raised: (uv-callback-error? #f error? #f who #f message attempt to return to stale foreign context irritants ())
(deferred ())
(second-uv-run (raised callback-error? #t cause boom))
teardown ok
```

### A.4 M4 — cost (`cost.sps`, `cost-guard.sps`)

```
(await-cycles 200000 ms 8 bytes-per-cycle 23)
(then-links 200000 ms 4 bytes-per-link 28)
```
```
(guard-wrapper 200000 ms 30 ns-per-cycle 150 bytes-per-cycle 13)
(weh-wrapper 200000 ms 24 ns-per-cycle 120 bytes-per-cycle 24)
(guard-wrapper 200000 ms 28 ns-per-cycle 140 bytes-per-cycle 28)
(weh-wrapper 200000 ms 24 ns-per-cycle 120 bytes-per-cycle 23)
```

### A.5 Source lookups (verbatim excerpts relied on)

`/Users/yuzu/github/chez-libuv/src/libuv/loop.sls:55-66`
```scheme
       (when (loop-running? loop)
         (raise (make-uv-invalid-argument 'uv-run 'loop-running)))
       ...
         (let ((rc (dynamic-wind
                    (lambda () (set-loop-running! loop #t))
                    (lambda () (uv-loop-run ptr mode-int))
                    (lambda () (set-loop-running! loop #f)))))
           (deliver-pending-callback-error! loop)
```

`/Users/yuzu/github/chez-libuv/src/libuv/private/handles.sls:302-304`
```scheme
  (define (dispatch-guarded loop thunk)
    (guard (e (#t (loop-record-error! loop e)))
      (thunk)))
```

`/Users/yuzu/github/chez-libuv/src/libuv/private/handles.sls:399-405`
```scheme
  (define (deliver-read-data! handle nread)
    (let ((on-data (stream-on-data handle)))
      (when on-data
        (dispatch-guarded
         (handle-loop handle)
         (lambda ()
           (on-data (copy-out (stream-read-buf handle) nread) 0 nread))))))
```

`/Users/yuzu/github/chez-libuv/src/libuv/stream.sls:73`
```scheme
  (define default-read-buffer-size 65536)
```

`/Users/yuzu/github/chez-libuv/src/libuv/dns.sls:99-109` — `uv-getaddrinfo!`
registers the request block and returns `req`, the record `uv-cancel!` accepts.

`/Users/yuzu/github/chez-httparse/src/httparse/grammar.sls:301-305`
```scheme
  (define F-CONNECTION-KEEP-ALIVE 1)
  (define F-CONNECTION-CLOSE 2)
  (define F-CONNECTION-UPGRADE 4)
  (define F-CHUNKED 8)
  (define F-UPGRADE 16)
```

`/Users/yuzu/github/chez-httparse/test/common/conformance-tests.sps:31-33`
```scheme
    (harness-case "a full scan runs every chunk size from 1 to the length"
      (lambda ()
        (check-equal "full 5" (corpus-scan-sizes 5 #f 'full) '(1 2 3 4 5))))
```

`/Users/yuzu/github/byte-machine/src/byte-machine/runtime.sls:913-915`
```
  ;;   paused    -- a feed that exits `paused` leaves the span active with the
  ;;                fragment the span end has just delivered; nothing advances the
  ;;                mark (see the fragment step above), so an arm here would not
```

`/Users/yuzu/github/llhttp/test/request/pipelining.md:1-20` — fixture format
(```http block; ```log block with `off=N` lines), `wc -l` over
`test/request/*.md test/response/*.md test/url.md` = 8951.

CSUG quotes (fetched 2026-09-19):
- control.html: "A one-shot continuation should not be returned to multiple
  times, either by invoking the continuation or returning normally from
  procedure more than once." / "A one-shot continuation is 'promoted' into a
  normal (multishot) continuation, however, if it is still active when a
  normal continuation is obtained by call/cc." / "Do not use the timer
  interrupt (see set-timer) and engines at the same time, since engines are
  implemented in terms of the timer."
- foreign.html: the five sentences quoted in §4.2, plus "The __collect_safe
  convention for a callable activates a calling thread if the thread is not
  already activated, and the thread's activation state is reverted when the
  callable returns." and "lock the code object (using lock-object) or
  otherwise retain it if the entry point is registered as a callback and
  retained indefinitely."
- threads.html: "Most primitive Scheme procedures are thread-safe, meaning
  that they can be called concurrently from multiple threads." / "Other
  destructive operators are thread safe only if they are used to operate on
  different objects from those being read or modified by other threads."
- exceptions.ss (cisco/ChezScheme main): `guard` → `$guard` uses
  `(call/cc (lambda (kouter) ... (with-exception-handler (lambda (arg) (call/cc (lambda (kinner)`
  and `(parameterize ([$current-handler-stack (cons handler ($current-handler-stack))]) (thunk))`.
