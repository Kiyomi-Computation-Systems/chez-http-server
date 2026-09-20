# Proposal: Chez engines for cooperative time-slicing (key = `engines`)

Independent proposal for the Scheme <-> libuv asynchrony model of chez-http-server.
Angle: handlers run inside Chez engines (`make-engine` / `engine-block` / `engine-return`)
driven by a scheduler that interleaves engine slices with `uv-run`. Written 2026-09-19 on
the machine described in the task (Chez 10.4.1 tarm64osx, libuv 1.52.1, chez-libuv v0.5.0,
chez-httparse v0.2.0). Every number below was measured here today; the commands and their
verbatim output are in §12.

---

## 0. One-paragraph summary

Every libuv callback becomes a **pure event recorder**: it mutates a connection record
(push an inbox chunk, set an EOF/error/timeout flag, decrement outstanding-write bytes,
store a DNS result) and pushes the owning connection's task onto a run queue. **No handler,
no parser and no HTTP logic ever runs inside a libuv callback.** All of that runs inside one
engine per connection, which the scheduler resumes *between* `uv-run` calls, at the top
level of the loop thread. A handler waits for I/O by re-checking a predicate on its
connection record and calling `engine-block` when the predicate is false; the wakeup is a
queue push from a callback, never a continuation invocation, so the design **does not rely
on invoking a continuation captured inside a foreign-callable** — it never captures one
there. Engines add what coroutines cannot: **preemption** of a CPU-bound handler by tick
budget (measured: a tight loop is preempted at its tick limit; a C call is not), which is
what keeps 10k connections fair against one hog. The costs are real and measured: engines
**cannot nest** in Chez 10.4.1 (`Exception in engine: cannot nest engines`), `dynamic-wind`
before/after thunks run at *every* slice boundary, and each `uv-run 'nowait` poll costs
~13 µs, which forces the scheduler to batch many slices per poll.

---

## 1. Sources read (with what each contributed)

| Source | Used for |
|---|---|
| `/Users/yuzu/github/chez-http-server/.plans/chez-http-server-architecture.md` §5, §7, §10–§14 | connection record shape, backpressure contract, pipelining policy, layered tests |
| `/Users/yuzu/github/chez-libuv/docs/api.md` (Flow control section, lines 72–223; DNS lines 363–415; Signals 315–361; Timers 417–425) | read-buffer contract, write-queue gauge contract, `uv-cancel!`, oneshot SIGTERM pattern |
| `/Users/yuzu/github/chez-libuv/docs/quickstart.md` | canonical callback shapes and "the three rules" |
| `/Users/yuzu/github/chez-libuv/spike/FINDINGS.md` Q2 (lines 383–523) | unguarded raise kills the process (exit 255); escape works but leaves invisible obligations |
| `/Users/yuzu/github/chez-libuv/.plans/decisions/0007-*.md`, `0008-*.md`, `0009-*.md`, `0018-*.md` | explicit close, trampolines + store-and-reraise rationale, copy-at-boundary (fresh bytevectors), unbuffered writes |
| `/Users/yuzu/github/chez-libuv/src/libuv/loop.sls:50-66` | `uv-run` refuses re-entry (`'loop-running`), delivers pending callback error after the C call returns |
| `/Users/yuzu/github/chez-libuv/src/libuv/private/handles.sls:291-304` | `loop-record-error!` stores the first raise and calls `uv_loop_stop`; `dispatch-guarded` |
| `/Users/yuzu/github/chez-libuv/src/libuv/stream.sls:73-135` | `default-read-buffer-size 65536`; `uv-read-start!` optional buffer-size on first start; `uv-read-stop!` requires open stream |
| `/Users/yuzu/github/chez-libuv/src/libuv/timer.sls:18-48`, `dns.sls:78-98` | `make-uv-timer`, `uv-timer-start!`, `uv-getaddrinfo!` signatures |
| `/Users/yuzu/github/chez-libuv/tests/test-echo.sps` | canonical server shape (per-connection closures, shutdown-then-close on EOF, guarded accept) |
| `/Users/yuzu/github/chez-httparse/docs/api.org` | 25 callbacks, `parser-feed!` result, pause/resume, `parser-field-ref` inside callbacks |
| `/Users/yuzu/github/chez-httparse/docs/conformance.org:1-60` | corpus replay method: every fixture at every chunk size 1..len, trace compared byte for byte |
| `/Users/yuzu/github/chez-httparse/docs/performance.org:15-50` | 6,112 B allocated per whole-buffer parse; 384–404 B per feed |
| `/Users/yuzu/github/chez-httparse/test/common/conformance-driver-tests.sps:218-245` | `fixture-mismatch`: the chunk-size loop shape to reuse |
| `/Users/yuzu/github/chez-httparse/test/support/harness/httparse/test/{corpus-load,corpus-decode,trace-format,drive}.sls` | reusable harness libraries for a connection-layer replay |
| `/Users/yuzu/github/byte-machine/src/byte-machine/runtime.sls:1100-1110, 1296-1312, 1604-1620` | `'paused` result carries `consumed = pos - start`; `parser-resume!` lifecycle |
| `/Users/yuzu/github/llhttp/test/request/pipelining.md` | fixture format with `reset` between pipelined messages |
| CSUG 10.0 `control.html` §6.4 Engines, `foreign.html` §4.4, `system.html` (interrupts) | quoted in §11 |
| `/Users/yuzu/github/chez-http-server/AGENTS.md` | FCIS, TDD/mutation, signature comments, R6RS `.sls` |

---

## 2. The model

### 2.1 Three layers, one thread

```
   uv-run ('once | 'nowait)          <- imperative shell: libuv callbacks = event recorders
        |  (callbacks push events into connection records and the run queue)
        v
   scheduler: pop task, run one engine slice, repeat; poll libuv between batches
        |
        v
   connection engine (one per connection): parser pull loop + handler + response writer
        |  waits with (wait-until conn pred) = engine-block until a recorder wakes it
        v
   functional core: request/response records, header codec, framing, limit checks,
                    timeout arithmetic, pipelining decisions -- pure, no libuv, no engines
```

Invariant E1 — **serialisation by construction**: callbacks run only inside `uv-run`
(chez-libuv contract), `uv-run` is called only by the scheduler, and the scheduler never
calls `uv-run` while an engine is running (it cannot: engines cannot nest, and `uv-run`
refuses re-entry, `loop.sls:55-56`). Therefore a callback and an engine slice never
interleave. A `wait-until` that checks its predicate and then blocks cannot lose a wakeup.

Invariant E2 — **no continuation crosses a foreign frame**: engines capture continuations
only at `engine-block` / tick expiry, both of which happen in engine code, which never runs
inside a callback. The open question "may a continuation captured inside a foreign-callable
be invoked after that callable returned" is **not relied on** (see §11 A1).

Invariant E3 — **one close initiator**: only `connection-close!` (called by the connection's
own engine or by the server's forced-shutdown sweep through the same procedure) ever calls
`uv-close!` on a connection handle. Everyone else calls `request-close!`, which sets a reason
and wakes the engine. Hence the "second `uv-close!` silently discards its callback" trap
(api.md:266-274) cannot fire.

### 2.2 Why the parser runs inside the engine (pull parsing)

The parser is pulled, not pushed. `on-data` only appends the **fresh** bytevector span it was
handed (ADR-0009: a fresh bytevector per delivery, so retaining it is safe) to the
connection's inbox. The engine feeds the parser when the driver or the handler asks for the
next event (`read-request-head!`, `body-read!`). Consequences:

- Parsing 64 KiB of hostile headers is preemptible like everything else.
- Pipelined bytes wait in the inbox; nothing is pre-parsed, so the "cap on outstanding
  requests" is a cap on **buffered bytes** (inbox high-water -> `uv-read-stop!`) in v1, and a
  cap on **parsed-but-unanswered requests** in the v2 concurrent variant (§5).
- The connection layer is a function from an inbox of bytevectors to an outbox of writes,
  which is what makes the socket-free corpus replay (§9) a straight replay.
- Body chunks are zero-copy sub-spans `(bv from to)` of inbox chunks the server already
  owns. Header names/values are copied in v1 (they may straddle chunks); the zero-copy
  variant is safe later precisely because of ADR-0009.

---

## 3. Handler API (code sketch)

```scheme
#!r6rs
(library (http-server handler)
  (export respond! response-start! response-write! response-end!
          body-read! body-read-all! await request-method request-target
          request-headers request-header-ref)
  (import (rnrs) (only (chezscheme) engine-block make-parameter parameterize))

  ;; current-connection : Parameter Connection -- bound by the scheduler for each slice.
  ;; It is a parameter (not a global) so it is re-established on every resume; see A6.
  (define current-connection (make-parameter #f))

  ;; wait-until : Connection (Connection -> Boolean) -> unspecified
  ;; Blocks the calling engine until (pred conn) is true. Never captures a continuation
  ;; inside a callback: the wake is a run-queue push done by a libuv callback (§4).
  (define (wait-until conn pred)
    (let spin ()
      (unless (pred conn)
        (connection-park! conn)        ; scheduler will not re-queue at expiry
        (engine-block)                 ; slice ends; resumed by a wake
        (check-abort! conn)            ; timeout / transport error / shutdown -> raise
        (spin))))

  ;; await : ((Any ... -> unspecified) -> unspecified) -> Any ...
  ;; Runs `start!` with a completion procedure k. k may be called from any libuv
  ;; callback; it stores the values and wakes the connection. Returns the values.
  (define (await start!)
    (let* ((conn (current-connection))
           (cell (make-completion conn)))
      (start! (lambda vals (completion-set! cell vals) (connection-wake! conn)))
      (wait-until conn (lambda (c) (completion-done? cell)))
      (apply values (completion-values cell)))))
```

### (1) Trivial respond

```scheme
(define (hello req)
  (respond! req 200 '((content-type . "text/plain")) (string->utf8 "hello\n")))
;; respond! serialises status+headers+Content-Length and the body into ONE uv-write!
;; (one foreign block, ADR-0009), then returns; it does not wait for completion.
```

### (2) Streaming a large response body with backpressure

```scheme
(define (big-file req)
  (response-start! req 200 '((content-type . "application/octet-stream")) 'chunked)
  (let ((buf (make-bytevector 65536)))
    (let loop ()
      (let ((n (get-bytevector-n! port buf 0 65536)))   ; any producer; here a port
        (unless (eof-object? n)
          ;; response-write! copies into a foreign block (uv-write!), bumps
          ;; outstanding-bytes/count, and then BLOCKS while
          ;;   outstanding-bytes >= write-high-water  OR
          ;;   (uv-stream-write-queue-size tcp) >= gauge-threshold
          ;; until write completions bring it under write-low-water (§6.2).
          (response-write! req buf 0 n)
          (loop)))))
  (response-end! req))   ; writes the terminating chunk; waits for outstanding = 0
                         ; only if the connection will close (so FIN follows data)
```

### (3) Consuming a large request body incrementally

```scheme
(define (upload req)
  (let loop ((total 0))
    (let ((chunk (body-read! req)))          ; -> (values bv from to) or eof-object
      (if (eof-object? chunk)
          (respond! req 200 '() (string->utf8 (number->string total)))
          (let-values (((bv from to) chunk))
            (sink! bv from to)               ; may itself `await` (e.g. a slow store)
            (loop (+ total (- to from))))))))
;; body-read! pulls: returns a queued span if any; else feeds the next inbox chunk
;; to the parser (on-body-data queues spans; on-message-complete marks EOF); else
;; wait-until inbox non-empty. A handler that stops calling body-read! stops the
;; parser; the inbox fills to high-water; on-data calls uv-read-stop!. That is the
;; whole read-side backpressure path -- no separate body buffer exists.
```

### (4) Awaiting an external async result (DNS)

```scheme
(define (lookup req)
  (let ((host (utf8->string (request-header-ref req "x-host"))))
    (let-values (((err results)
                  (await (lambda (k)
                           (uv-getaddrinfo! (connection-loop (current-connection))
                                            host #f '((socktype . stream)) k)))))
      (if err
          (respond! req 502 '() (string->utf8 (symbol->string (uv-errno-error-errno err))))
          (respond! req 200 '() (string->utf8 (uv-addrinfo-address (car results))))))))
;; Completion runs on the loop thread (api.md:389-393) inside uv-run, stores the
;; two values and wakes the connection. If the connection is closed while the
;; request is in flight, connection-close! calls (uv-cancel! req) best-effort
;; (api.md:372); the callback still fires (EAI_CANCELED) into a completion cell
;; whose connection is gone -- the cell is dropped, nothing is invoked.
```

The spike in §12.5 ran exactly these four shapes (a CPU hog, a timer sleeper, a
`uv-getaddrinfo!` await, and two sequential awaits) under one scheduler and got
`(done (resolver (dns-ok 2 "::1")))`, `(done (two-awaits timer-fired timer-fired))`,
with the hog preempted every 5000 ticks and the loop torn down to closed.

---

## 4. Connection driver

### 4.1 Records (imperative shell; mutable by callbacks and by the engine, never both at once — E1)

```scheme
(define-record-type connection
  (fields server loop tcp parser
          (mutable engine)            ; the current engine (replaced at every expiry)
          (mutable run-state)         ; 'runnable | 'parked | 'queued | 'finished
          (mutable inbox)             ; queue of (bv start end), fresh bytevectors
          (mutable inbox-bytes)
          (mutable reading?)          ; our mirror of read-start/stop
          (mutable eof?) (mutable transport-error)   ; #f | condition
          (mutable close-requested)   ; #f | reason symbol
          (mutable state)             ; 'open | 'closing | 'closed
          (mutable out-bytes) (mutable out-count)   ; outstanding uv-write! payload/requests
          (mutable deadline) (mutable deadline-kind) (mutable deadline-gen)  ; §7
          (mutable requests-served)
          builder))                   ; the in-progress request builder = parser ctx
```

### 4.2 libuv callbacks -> events (every one is tiny, allocation-light, and never raises)

| libuv callback | What it does (and only this) |
|---|---|
| `uv-listen!` on-connection `(err)` | `err` -> log, return. Else `guard`ed `uv-accept!` (as test-echo.sps:253); make connection; `uv-read-start! tcp on-data on-eof on-error read-buffer-size` (size from config, default **16384** — see §10); arm header deadline; spawn the engine; enqueue. |
| on-data `(bv start end)` | push span to inbox; `inbox-bytes += (- end start)`; if `inbox-bytes >= inbox-high-water` and `(uv-handle-open? tcp)` then `uv-read-stop!`, `reading? := #f`; `connection-wake!`. |
| on-eof `()` | `eof? := #t`; wake. |
| on-error `(cond)` | `transport-error := cond`; wake. (Does not close: EOF/error never close by themselves — quickstart "the three rules".) |
| `uv-write!` on-complete `(err)` | `out-bytes -= n; out-count -= 1`; if `err` then `transport-error := err`; wake. |
| `uv-shutdown!` on-shutdown `(err)` | record; wake (the engine is waiting for it before close). |
| `uv-close!` on-close `()` | `state := 'closed`; remove from server table; if draining and table empty -> `uv-stop!`-free path: the scheduler notices the empty table. **Only deregistration point.** |
| wheel timer on-timeout | advance the wheel; for each expiring entry whose `deadline-gen` still matches: `close-requested := 'timeout`, note `deadline-kind`; wake. (§7) |
| `uv-getaddrinfo!` / `uv-getnameinfo!` on-complete | store values in the completion cell; wake owner (if owner is finished, drop). |
| `uv-signal-start-oneshot!` sigterm | `server-draining := #t`; `uv-close!` listener; arm drain deadline in the wheel; `uv-close!` the watcher (api.md:340-348). (§8) |

Every one of these is additionally wrapped in our own `guard` that turns a raise into
`(request-close! conn 'internal-error cond)`; the binding's `dispatch-guarded`
(`handles.sls:302-304`) is the second net, and store-and-reraise is the third (§8.4).

### 4.3 The engine body

```scheme
;; connection-main : Connection -> unspecified   (runs inside the engine)
(define (connection-main conn)
  (guard (e ((abort-condition? e) (finish-connection! conn (abort-reason e))))
    (let loop ()
      (let ((req (read-request-head! conn)))         ; #f on clean EOF before any byte
        (cond ((not req) (finish-connection! conn 'eof))
              (else
               (arm-deadline! conn 'body/handler)
               (run-handler! conn req)               ; §8.3 for its guard
               (discard-unread-body! conn req)       ; pull to message-complete, bounded
               (cond ((or (request-close? req)       ; Connection: close, HTTP/1.0 default
                          (server-draining? conn)
                          (>= (connection-requests-served conn) max-requests-per-connection))
                      (finish-connection! conn 'keep-alive-off))
                     (else (arm-deadline! conn 'idle) (loop)))))))))
```

`read-request-head!`:

```scheme
(define (read-request-head! conn)
  (arm-deadline! conn 'header)             ; header timeout runs from first byte; see §7
  (let pull ()
    (cond ((builder-head-complete? (connection-builder conn)) (builder->request conn))
          ((inbox-empty? conn)
           (cond ((connection-eof? conn)
                  (if (builder-empty? conn) #f (raise-abort 'eof-mid-message)))
                 (else (maybe-read-start! conn)
                       (wait-until conn (lambda (c) (or (not (inbox-empty? c)) (connection-eof? c))))
                       (pull))))
          (else (feed-one-chunk! conn) (pull)))))
```

`feed-one-chunk!` is the single place `parser-feed!` is called:

```scheme
(define (feed-one-chunk! conn)
  (let* ((chunk (inbox-peek conn))                     ; (bv start end)
         (r (parser-feed! (connection-parser conn) (chunk-bv chunk) (chunk-start chunk) (chunk-end chunk)))
         (consumed (parser-result-consumed r)))
    (inbox-advance! conn consumed)                     ; re-slice; drop chunk when fully consumed
    (case (parser-result-status r)
      ((need-input) (void))
      ((paused) (parser-resume! (connection-parser conn)))   ; we pause only at message-complete (§5)
      ((error) (raise-abort 'parse-error (parser-result-error r)))
      (else (raise-abort 'parser-terminal)))))
```

### 4.4 The 25 parser callbacks

The user context is the connection's `builder`. Span callbacks copy in v1; every callback
returns `callback-continue` unless a limit trips, in which case it returns
`(make-callback-failure 'limit-<name> detail)` and the feed returns `'error` with that code.

| Callback | Action in the builder |
|---|---|
| `on-message-begin` | reset builder; `first-byte-seen := #t` (header deadline anchor) |
| `on-method-data` / `-complete` | append span / finalize `method` bytevector; also read `(parser-field-ref p 'method)` (llhttp method int) at complete |
| `on-url-data` / `-complete` | append (limit `max-target-bytes` -> `'limit-target`) / finalize; the `(uri collect)` parse of the target happens in `builder->request`, **not** in the callback (keeps callbacks allocation-light and the URI parse mockable) |
| `on-protocol-data` / `-complete` | ignored span / no-op (llhttp already validated) |
| `on-version-data` / `-complete` | ignored / read `'http-major` `'http-minor` |
| `on-status-data` / `-complete` | contract violation if fired (`type` is request) -> failure `'unexpected-status` |
| `on-header-field-data` / `-complete` | append (limit `max-header-name-bytes`, `max-headers` count on complete) / finalize name (lower-cased ASCII copy) |
| `on-header-value-data` / `-complete` | append (limit `max-header-value-bytes`, running total `max-header-bytes`) / push `(name . value)` |
| `on-headers-complete` | **read flags here** (`F-CONNECTION-CLOSE`, `F-CONNECTION-KEEP-ALIVE`, `F-CHUNKED`, `F-CONTENT-LENGTH`, `F-UPGRADE`, `'content-length` declared) — the inter-message reset zeroes them (task facts; api.org "Reading parser state"). Decide keep-alive (RFC 7230 §6.3) and store it in the builder. If declared length > `max-body-bytes` and the route is not streaming: record `'policy-413` and return `callback-pause` so the driver can answer before reading the body. `Expect: 100-continue` -> record; the driver writes `100 Continue` before the first `body-read!`. Return value is never `'skip-body` on the server side. |
| `on-body-data` | push `(bv from to)` onto the builder's body queue — **no copy** (the bv is the inbox chunk we own); count `body-bytes` (limit `max-body-bytes` when buffering, `'limit-body`) |
| `on-chunk-header` / `on-chunk-complete` | no-op (chunk size limits are llhttp's own); count chunks for a `max-chunks` limit if configured |
| `on-chunk-extension-name-data` / `-complete`, `-value-data` / `-complete` | drop (limit total extension bytes -> `'limit-chunk-ext`) |
| `on-message-complete` | `message-complete := #t`; return `callback-pause` (**the one routine pause**): the feed returns `'paused` with `consumed` = exact end of this message, so the inbox re-slices to the first byte of the next pipelined request without our layer guessing boundaries |
| `on-reset` | the builder is already fresh; assert it (a check, not a comment: `on-reset` seen with a non-empty builder is a driver bug -> failure `'driver-invariant`) |

After a message whose keep-alive decision is *close*, `feed-one-chunk!` is never called
again on that connection (the task's measurement: llhttp reports `data-after-close` at the
first byte of the next message); the driver `uv-read-stop!`s, discards the inbox, and goes
to `finish-connection!`.

### 4.5 Scheduler

```scheme
(define slice-ticks 20000)     ; tuned by measurement (a tick ~ one nonleaf call; §12.2)
(define batch-max 256)         ; slices per poll; amortises the ~13 µs uv-run 'nowait (§12.6)

(define (serve! server)
  (let loop ()
    (let ((ran (run-batch! server batch-max)))
      (guard (e ((uv-callback-error? e) (log-callback-error! server e)))   ; §8.4
        (uv-run (server-loop server) (if (run-queue-empty? server) 'once 'nowait)))
      (unless (and (server-draining? server) (server-table-empty? server))
        (loop)))))

(define (run-batch! server n)
  (let loop ((i 0))
    (if (or (= i n) (run-queue-empty? server)) i
        (let ((conn (run-queue-pop! server)))
          (run-slice! conn)
          (loop (+ i 1))))))

(define (run-slice! conn)
  (connection-run-state-set! conn 'runnable)
  (parameterize ((current-connection conn))
    ((connection-engine conn)
     slice-ticks
     (lambda (ticks . vals) (connection-run-state-set! conn 'finished))
     (lambda (e2)
       (connection-engine-set! conn e2)
       (case (connection-run-state conn)
         ((parked) (void))                        ; blocked in wait-until; a wake re-queues
         (else (run-queue-push! conn)))))))       ; preempted mid-work: back of the queue

(define (connection-wake! conn)                   ; called ONLY from libuv callbacks
  (when (eq? (connection-run-state conn) 'parked)
    (connection-run-state-set! conn 'queued)
    (run-queue-push! conn)))
```

`'once` when nothing is runnable blocks in the kernel until an event arrives (no busy
spin); `'nowait` when tasks are runnable keeps latency bounded by one batch. The spike
(§12.5) used exactly this shape and idled after 70 iterations.

Fairness under 10k connections: parked connections cost nothing in the scheduler — they are
not in the queue. Runnable ones are round-robin; a hog is preempted after `slice-ticks` and
goes to the back. Worst-case added latency for a request behind k runnable tasks is
k × (one slice), and a slice is bounded by ticks, not by handler goodwill. The batch bound
guarantees libuv is polled at least every `batch-max` slices, so accepts, reads and write
completions keep flowing under CPU saturation. A single `slice-ticks` value cannot be
mapped to time ("Your mileage may vary", CSUG §6.4), so it is a config knob with a benchmark
behind it, not a constant.

---

## 5. Pipelining, response ordering, outstanding cap

**v1 (this proposal's default): sequential per connection.** One engine per connection
handles requests strictly in order; response N is fully issued to `uv-write!` before the
parser is fed for request N+1. Ordering is therefore free. The bytes of pipelined requests
wait in the inbox; the cap is `inbox-high-water` (bytes) enforced by `uv-read-stop!`, plus
`max-requests-per-connection`. The `'paused` at `on-message-complete` gives the exact byte
boundary (`runtime.sls:1108`: consumed = `pos - start`), so a 64 KiB delivery holding three
requests is re-sliced, never re-parsed.

**v2 (extension, same scheduler): bounded concurrency with ordered responses.** The
connection engine becomes a *reader* that parses up to `max-pipeline-depth` (default 8)
heads and spawns one **sibling** engine per request (siblings, because engines cannot nest —
§11 A2); each request engine writes into its own response slot; a *writer* step in the
connection engine flushes slots in request order and only the head-of-line request may
stream. Backpressure: the reader parks when depth is reached. This is where engines beat
coroutines: eight concurrent handlers on one connection remain preemptible.

---

## 6. Backpressure in both directions

### 6.1 Read side (`uv-read-stop!` / `uv-read-start!`)

- `on-data` stops reading when `inbox-bytes >= inbox-high-water` (default 4 × read buffer,
  i.e. 64 KiB with a 16 KiB buffer), guarded by `(uv-handle-open? tcp)` (api.md:183-192).
- The engine restarts reading (`maybe-read-start!`) when it needs bytes and
  `inbox-bytes < inbox-low-water` and `(not reading?)`. `uv-read-start!` is called with no
  size argument so it is legal against the fixed buffer (stream.sls:114-117). Calling it
  from the engine — outside any callback — is exactly the "restart from the suite's own top
  level" shape test-echo.sps:263 exercises.
- A handler that does not read its body exerts backpressure automatically (§3(3)).
- `discard-unread-body!` after a handler is bounded by `max-discard-bytes`; beyond that the
  connection closes rather than sink an unbounded upload.

### 6.2 Write side (ADR-0018: policy is ours)

Two counters, incremented **only after `uv-write!` returns** (api.md:194-206), decremented
in on-complete: `out-bytes`, `out-count`. `response-write!` blocks with `wait-until` while
`out-bytes >= write-high-water` (default 256 KiB) **or** `out-count >= write-max-requests`
(default 64) **or** `(uv-stream-write-queue-size tcp) >= gauge-threshold` (platform-calibrated,
supplemental, api.md:208-223). A synchronous `uv-write!` failure raises out of
`response-write!` into the handler as a transport condition; nothing was queued. A zero-length
write is never issued (it costs a full request block, api.md:195-197).

Memory bound per connection = inbox-high-water + write-high-water + read buffer + Scheme
state; all four are configuration.

---

## 7. Timeouts and limits

### 7.1 One timer handle per server, not per connection (timing wheel)

`uv_timer_t` is 152 B on this machine (§12.7), so 10k timers is only 1.5 MB — the reason to
economise is not memory but **10k more handles in the unsynchronised registry, 10k more
closes to own, and 10k more `on-close` orderings** (ADR-0007/E3). The server owns one
`uv-timer` repeating every `wheel-tick-ms` (default 1000) and a wheel of `W` buckets
(default 64) of connection references with lazy deletion:

```scheme
;; arm-deadline! : Connection Symbol -> unspecified   (pure arithmetic in the core)
(define (arm-deadline! conn kind)
  (let* ((ms (deadline-ms (connection-server conn) kind))      ; header/body/idle/handler/drain
         (at (+ (uv-now loop) ms))
         (gen (+ 1 (connection-deadline-gen conn))))
    (connection-deadline-set! conn at)  (connection-deadline-kind-set! conn kind)
    (connection-deadline-gen-set! conn gen)
    (wheel-insert! (server-wheel server) at (cons conn gen))))   ; bucket = (at / tick) mod W
;; on-timeout: pop the current bucket; for each (conn . gen): if gen matches and
;; (>= (uv-now) deadline) -> request-close! 'timeout; else re-insert (a re-armed or
;; long deadline). Cost per tick is O(entries in one bucket); a stale entry costs one eq?.
```

Resolution is the tick (1 s); precise enough for header/idle/body policies. A connection
that dies leaves a stale `(conn . gen)` that is dropped when its bucket comes round.
`uv-now` is libuv's cached clock (api.md:21), allocation-free.

### 7.2 Kinds

| Deadline | Armed | Cleared/re-armed | On expiry |
|---|---|---|---|
| header (default 10 s) | accept; and each `read-request-head!` when the first byte of a new request arrives | headers-complete | 408 if no response started, then close |
| body (30 s inactivity) | each `body-read!` wait | each body chunk | 408 / close |
| idle keep-alive (60 s) | after response N ends | first byte of request N+1 | close silently |
| handler (config, default off) | handler start | response end | 503 if nothing written, else close |
| drain (§8, default 30 s) | SIGTERM | — | force-close all |

The expiry only sets `close-requested := 'timeout` and wakes; the engine raises the abort
from `check-abort!` at its next `wait-until` or slice boundary check (`run-handler!` also
checks between response writes), so a timeout observed mid-parse is honoured at the next
safe point, never by tearing a frame.

### 7.3 Limits (server policy, enforced in callbacks or driver; all configurable)

`max-target-bytes` 8 KiB, `max-header-name-bytes` 1 KiB, `max-header-value-bytes` 8 KiB,
`max-header-bytes` 64 KiB, `max-headers` 100, `max-body-bytes` (buffering only) 1 MiB,
`max-discard-bytes` 1 MiB, `max-requests-per-connection` 1000, `max-pipeline-depth` (v2) 8,
`inbox-high-water` 64 KiB, `write-high-water` 256 KiB, `write-max-requests` 64,
`max-connections` 10000 (accept then immediately `finish-connection! 'overloaded` with 503
if over — accepting and closing is cheaper than leaving the backlog to the kernel's whims),
`read-buffer-size` 16 KiB (api.md:172-178: many small-message connections is exactly where a
smaller buffer is "close to free and the saving is linear"), `slice-ticks`, `batch-max`.

Mapping to responses: `'limit-target` -> 414; `'limit-header-*`/`'limit-headers` -> 431;
`'limit-body` -> 413; parser `'error` -> 400 (with `Connection: close`), except
`invalid-version`-class -> 505; all followed by close. A response is only attempted if no
response bytes have been written for the current request; otherwise the connection is closed
without one (a half-written response cannot be repaired).

---

## 8. Error propagation and shutdown

### 8.1 Four error classes, four channels

| Class | Where it surfaces | What happens |
|---|---|---|
| parser error | `parser-feed!` returns `'error` inside `feed-one-chunk!` (engine) | `raise-abort 'parse-error` -> `finish-connection!` writes 400/505 if possible, `Connection: close`, shutdown, close |
| policy error (limits, timeouts, 413 pre-body) | callback failure code, or `close-requested` flag | as above with 4xx mapping (§7.3) |
| handler exception | `raise` inside `run-handler!` (engine) | caught by `run-handler!`'s `guard`: response not started -> 500 and keep-alive preserved; started -> abort the connection. The engine survives because the guard is *inside* it; a raise that escaped the engine would consume it (§12.2 row 8) |
| transport error | `on-error`/write on-complete `err` set `transport-error` | next `check-abort!` raises `'transport`; `finish-connection!` skips shutdown/writes and closes directly |

`raise-abort` raises an `&http-abort` condition carrying the reason; `connection-main`'s
outer `guard` is the only handler for it, so every path ends in `finish-connection!`.

### 8.2 `finish-connection!` (the only writer of the close protocol)

```scheme
(define (finish-connection! conn reason)
  (when (eq? (connection-state conn) 'open)
    (when (uv-handle-open? tcp) (uv-read-stop! tcp))                 ; guarded stop
    (cancel-inflight-awaits! conn)                                   ; uv-cancel! DNS etc.
    (write-error-response-if-possible! conn reason)
    (unless (connection-transport-error conn)
      (wait-until conn (lambda (c) (zero? (connection-out-count c)))) ; data before FIN (ADR-0018 ordering)
      (uv-shutdown! tcp (lambda (err) (connection-shutdown-done-set! conn #t) (connection-wake! conn)))
      (wait-until conn connection-shutdown-done?))
    (connection-close! conn reason)))

(define (connection-close! conn reason)          ; E3: the ONLY uv-close! on a connection tcp
  (when (eq? (connection-state conn) 'open)
    (connection-state-set! conn 'closing)
    (uv-close! (connection-tcp conn) (lambda () (on-connection-closed! conn reason)))))
```

The forced-shutdown sweep calls `connection-close!` directly (state-checked, so idempotent
with respect to an engine that is concurrently finishing — they cannot actually run
concurrently, E1). An engine whose connection was force-closed sees `state = 'closing` at
its next `check-abort!` and returns; its `wait-until` predicates all include
`(not (eq? state 'open))` via `check-abort!`.

### 8.3 The three nets against "an unguarded raise kills the process"

1. Handler code runs only in engines, guarded inside the engine (`run-handler!`) and at the
   engine boundary (`run-slice!` wraps the engine invocation in a `guard` that logs and
   `connection-close!`s — a raise escaping an engine is a bug in the driver, not the handler).
2. Our libuv callbacks are recorders and are each wrapped in `guard` -> `request-close!`.
3. If something still escapes, chez-libuv's `dispatch-guarded` stores it, stops the loop
   (`handles.sls:291-300`) and `uv-run` re-raises `&uv-callback-error` after the C frame has
   returned (`loop.sls:64`). `serve!` catches that, logs it with `uv-loop-deferred-errors`,
   and continues (policy knob: `on-callback-error` = `'continue` | `'exit`). Nothing in this
   design ever lets a raise reach the default handler (spike Q2 `bare`: exit 255).

### 8.4 Graceful shutdown (SIGTERM oneshot)

```scheme
(uv-signal-start-oneshot! watcher 'sigterm
  (lambda (sig)
    (server-draining-set! server #t)
    (uv-close! (server-listener server))              ; stop accepting; listener has no reads
    (arm-server-deadline! server 'drain)              ; via the same wheel
    (for-each (lambda (conn)
                (when (connection-idle? conn)         ; parked in read-request-head! with empty inbox
                  (request-close! conn 'shutdown)))   ; wakes it; it finishes cleanly
              (server-connections server))
    (uv-close! watcher)))                             ; disposition reverts to SIG_DFL: 2nd SIGTERM kills
```

Busy connections finish their current response (the driver adds `Connection: close` when
`server-draining?`), then close. At the drain deadline the sweep calls `connection-close!`
on every remaining connection. `serve!` exits when the table is empty, then
`uv-loop-teardown!` (which also cancels in-flight DNS, api.md:402-408).

---

## 9. Testability (FCIS, TDD, mutation)

### 9.1 What is pure

`(http-server core)`: request builder transitions (the 25 callback bodies are pure functions
of builder + span -> builder'), keep-alive decision from flags/version/headers, response
serialisation to bytevectors, limit arithmetic, wheel arithmetic, error-code -> status
mapping, pipelining re-slice arithmetic. All unit-tested with no libuv and no engines.

### 9.2 The transport seam

The engine body talks to the shell through a `transport` record of procedures:
`(read-start!) (read-stop!) (write! bv s e on-complete) (shutdown! k) (close! k) (now)
(cancel! req)`. The production transport wraps chez-libuv; the **fake transport** is a
Scheme record with queues and a scripted event list. The scheduler is the same code in both
cases; only "poll" differs: real `uv-run` vs `(deliver-next-scripted-event!)`. Hence the
whole driver — engine, wait-until, backpressure, timeouts (fake `now`), close protocol — is
exercised without sockets, deterministically, in-process.

### 9.3 llhttp corpus through the CONNECTION layer, every chunk size, without sockets

Reuse `(httparse test corpus-load)`, `(httparse test corpus-decode)` and
`(httparse test trace-format)` (test/support/harness) to load each request fixture and its
recorded trace. For each fixture and each chunk size `s` in 1..len (the loop shape of
`fixture-mismatch`, conformance-driver-tests.sps:220-245):

1. Build a fake-transport connection with a dummy handler that records
   `(method target version headers body-chunks keep-alive?)` and answers 204.
2. Script `on-data` deliveries of `s` bytes each (fresh bytevectors, as ADR-0009 promises),
   then EOF; run the scheduler to idle.
3. Assert (a) the connection-layer observation equals the one from the whole-buffer run
   (**chunk-size invariance**, the property conformance.org:40-44 states for the parser, now
   at the layer above); (b) the request sequence agrees with the fixture's recorded llhttp
   trace projected onto message boundaries, spans and `headers complete` flags — the
   projection is computed from the fixture's own `log` block, never from our code (AGENTS.md:
   "Numbers in a test come from the oracle, never from the code under test"); (c) for error
   fixtures, the status/close decision and that nothing is fed after the error; (d) for
   pipelining fixtures (`test/request/pipelining.md`), one response per message in order,
   and the byte at which the inbox was re-sliced equals the fixture's `reset` offset.
4. Response-side replay: fixtures from `test/response/*.md` drive the *serialiser* the other
   way — serialise our response record, feed the bytes to a response-mode parser, and
   compare its trace to the fixture's when the fixture is a serialisable message.

**With sockets:** the same fixture list through a loopback pair (ADR-0010 style: bind port
0, in-process chez-libuv client on the same loop, as test-echo.sps) with the client writing
each chunk in its own `uv-write!`. The kernel may coalesce, so the socket lane asserts
equality with the fake-transport result for the same fixture, not a specific chunking, and
adds what only sockets can show: read-stop actually stops delivery (the test-echo.sps:446
pattern), write completions decrement counters, EOF and ECONNRESET paths, shutdown-before-
close ordering, and a real SIGTERM (`uv-kill!` self with `uv-os-getpid`).

### 9.4 Engine-specific tests

- Preemption: a handler that loops forever; assert other connections progress and the hog
  is eventually cut by the handler deadline (503).
- Wake-before-block impossibility: a mutant that moves `uv-run` inside `run-batch!` must be
  caught by a test where a completion lands between predicate check and block.
- No-nesting: a handler that calls `make-engine`+invoke gets a 500, not a dead server
  (asserts the `cannot nest engines` raise is contained).
- `dynamic-wind` churn: a handler with a counting `dynamic-wind` around an await; assert the
  count equals slices+wakes so the cost is *documented by a test* (it is engine semantics,
  §12.2 row 9).

### 9.5 Mutation list (each must be watched to fail)

drop the `uv-handle-open?` guard before `uv-read-stop!`; increment `out-bytes` before
`uv-write!` returns; read flags at `on-message-complete` instead of `on-headers-complete`;
feed after a close-marked message; forget `parser-resume!` after the message-complete pause;
re-queue a parked engine at expiry; call `uv-close!` from `on-error`; skip the
`out-count = 0` wait before `uv-shutdown!`; wheel without generation check; `'nowait` when
the queue is empty (busy spin — caught by a CPU-time assertion).

---

## 10. Performance

### 10.1 Measured engine costs (§12.1–12.3, 12.6)

| Quantity | Measured |
|---|---|
| `make-engine` | 128 B, ~0.1 µs (10k in 1 ms) |
| engine that blocked once (shallow), retained | ~652 B |
| engine blocked 30 frames deep, retained after `(collect)` | ~804 B; 10k such = 8.0 MB |
| block + resume round trip | ~25 B, ~0.5 µs (100k in 49 ms) |
| create + run to completion (trivial thunk) | ~6 B amortised, ~0.5 µs |
| resume 10k blocked engines | 5–7 ms total |
| one tick | ≈ one nonleaf call (1000 ticks = 999 loop iterations) |
| `uv-run 'nowait` on an idle loop | **~13 µs**, 33 B |
| engine slice + `uv-run 'nowait` | ~15 µs |

The poll dominates: the scheduler must not poll per slice. With `batch-max` 256 the poll is
amortised to ~0.05 µs/slice under load, and under light load `'once` blocks in the kernel.

### 10.2 Per request (small GET, keep-alive, v1)

parser: ~6.1 KB per whole-buffer parse (performance.org:20-23) + ~390 B per additional feed;
inbox chunk: `nread` bytes (allocated by chez-libuv regardless of model, ADR-0009);
builder/request record + copied header names/values: ≈ header bytes + ~300 B; response
head bytevector ~200 B; `uv-write!` foreign block 192 B + payload (freed before on-complete);
engine: one block/resume (25 B) when waiting for the next request, zero if the request was
already in the inbox; scheduler queue op ~16 B. **Total ≈ 7–8 KB Scheme allocation per
request**, of which the engine model contributes < 1%. GC pressure is set by the parser and
the copies, not by engines.

### 10.3 Per connection resident (10k keep-alive idle)

| Item | Bytes | ×10k |
|---|---|---|
| chez-libuv read buffer, default 64 KiB (`stream.sls:73`) | 65,536 | **625 MiB** |
| same, at the proposed 16 KiB (`uv-read-start!` size arg) | 16,384 | 160 MiB |
| `uv_tcp_t` (§12.7) | 264 | 2.6 MB |
| parked engine (continuation) | ~800 | 8 MB |
| parser + builder + connection record (estimate; parser alloc not measured) | ~2–4 KB | 20–40 MB |
| OS socket buffers, idle (api.md:109) | ~11–15 KiB kernel | ~120 MB kernel |
| timers | 0 per connection (one wheel timer per server) | 152 B |

The engine is ~1% of the per-connection footprint; the read buffer size is the decision that
matters, and chez-libuv lets the server pick it on the first `uv-read-start!`.

### 10.4 Throughput ceiling and latency

Per-request CPU is parser + copies + serialisation + one `uv-write!` FFI call + the amortised
poll; engines add ~1 µs. Latency under CPU saturation is bounded by `batch-max × slice`
before libuv is polled again, and by the run-queue length × slice for a given request —
both tunable, both bounded regardless of handler behaviour, which is the property the
callback and coroutine designs lack.

---

## 11. Chez assumptions (stated, with the evidence I have)

- **A1 (NOT relied upon, stated as required):** whether a continuation captured inside a
  `foreign-callable` may be invoked after that callable has returned is **assumed unknown**.
  CSUG §4.4 says "Scheme continuations may be used to throw control either upwards or
  downwards logically through any mix of Scheme and foreign frames" and "A foreign context
  becomes stale after a normal return to the context or after a return to some other
  foreign context beneath it on the control stack" — which is why this design captures
  continuations only in engine code that runs outside every callback (E2). The live spike
  the judges will read decides whether other designs may do more; this one needs nothing
  from it.
- **A2 (measured):** engines cannot nest in Chez 10.4.1 — `Exception in engine: cannot nest
  engines` (§12.2 row "nested"). Consequence: the scheduler is the only engine invoker;
  handlers may not use engines; libraries that use engines internally (e.g. a timeout
  wrapper) cannot be called from handlers.
- **A3 (CSUG §6.4, quoted):** "Do not use the timer interrupt (see set-timer) and engines at
  the same time, since engines are implemented in terms of the timer." Handlers and the
  server never call `set-timer` / `timer-interrupt-handler`. libuv timers are C and unaffected.
- **A4 (CSUG system.html, quoted; measured §12.3):** "Timer, keyboard, and collect-request
  interrupts are supported via a counter that is decremented approximately once for each
  call to a nonleaf procedure." A foreign call is therefore not preemptible: `usleep(20000)`
  ×2 inside a 10-tick engine completed with 7 ticks left; a loop of `usleep(0)` calls was
  preempted. Long C calls in handlers defeat fairness.
- **A5 (measured §12.2 row 9):** `dynamic-wind` after-thunks run when an engine blocks and
  before-thunks run when it resumes (`(in out)` after block, `(in out in out)` after
  completion). `parameterize` inside an engine is unwound at block and restored at resume
  (row 11). Handlers pay wind/unwind at every slice boundary.
- **A6 (measured §12.2 rows 8, 8b, 8c):** a raise inside an engine propagates to the engine's
  invoker and the engine is consumed; new engines work afterwards; a `guard` inside the
  engine keeps it alive.
- **A7 (measured §12.3):** `engine-block` from a nested Scheme call inside the engine works;
  `call/1cc` captured before a block and invoked after resume worked once here, but is not
  documented to — handlers are told not to rely on it.
- **A8 (assumed, single-thread design):** engines/timer interrupts are per-thread state and
  the loop runs on exactly one thread (chez-libuv's registry is unsynchronised anyway). No
  Scheme ever runs on libuv worker threads (api.md:389-393).
- **A9 (measured §12.2 rows 15, "10000 short engines"):** `(collect)` inside an engine and
  allocation-heavy engines do not disturb engine accounting.

---

## 12. Measurements (commands and verbatim output)

All scripts are in
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/engines/`.

### 12.1 `bench.ss` — creation, blocking, round trips

Command: `cd .../scratchpad/engines && chez --version; chez --script bench.ss`

```
10.4.1
create 10000 engines: 1280000 bytes (128/engine), 1 ms
block 10000 engines once: 6521472 bytes (652/engine), 9 ms
after collect, blocked engines still referenced: bytes-allocated 25234128
resume 10000 engines to completion: 5 ms, first=9999 last=0
round-trips 100000: 49 ms, 2531552 bytes (25/round-trip)
Exception in engine: cannot nest engines
```
(The run stopped at the nesting probe; the remaining rows were re-run in 12.2.)

### 12.2 `bench2.ss` — nesting, preemption, raise, dynamic-wind, resident size

Command: `chez --script bench2.ss`

```
nested: (raised cannot nest engines ())
sequential engines: (a b)
preempt tight loop with 1000 ticks: preempted
1000 ticks = 999 loop iterations
100000 ticks of consing: 0 ms cpu
engine-return: (complete 99 (a b))
raise inside engine reaches caller: (caught boom)
engine after escaped raise: ok
guard inside engine: caught-inside
dynamic-wind log after block: (in out)
after resume+complete: body -> (in out in out)
timer-interrupt-handler is: #<procedure>
1 tick on (+ 1 2): (complete ticks-left 1 3)
parameter while engine blocked: outside
parameter after resume: inside
10000 engines blocked 30 frames deep, retained after collect: 8049152 bytes (804/engine)
resume 10000 deep: 7 ms
100000 create+complete engines: 49 ms, 6 bytes/engine
collect inside engine: ok
Exception in foreign-procedure: no entry for "usleep"
```

### 12.3 `bench3.ss` — ticks across C calls, nested block, call/1cc, block outside engine

Command: `chez --script bench3.ss`

```
engine calling C usleep(20000) with 10 ticks: (complete 7 returned)
loop of usleep(0) with 100 ticks: preempted
engine-block from nested call: (got woke)
call/1cc across a block: via-1cc
engine-block outside engine: (raised no engine active)
10000 short engines each allocating 8KB: total=10000  (GC did not break engine accounting)
```

### 12.4 CSUG quotations

Fetched with `curl -sL https://cisco.github.io/ChezScheme/csug10.0/{control,foreign,system}.html`
(saved beside this file as `csug-control.html`, `csug-foreign.html`, `csug-system.html`).

control.html §6.4: "An engine itself is a procedure of three arguments: ticks … complete …
expire: a procedure of one argument that specifies what to do if the fuel runs out before
the computation finishes. Its argument is a new engine capable of continuing the computation
from the point of interruption." "When an engine is applied to its arguments, it sets up a
timer to fire in ticks time units." "Do not use the timer interrupt (see set-timer) and
engines at the same time, since engines are implemented in terms of the timer." "(The fuel
amounts given here are for illustration only. Your mileage may vary.)"

foreign.html §4.4: quoted in A1 above; also "One implication of this mechanism is that the C
stack pointer is not automatically restored to its base value when a continuation is used on
the Scheme side to perform a nonlocal exit."

system.html (Interrupts): quoted in A4 above; also "When the counter reaches zero, the system
looks to see if the timer is set and has expired … the current procedure call is pended …
while the appropriate interrupt handler is invoked."

### 12.5 `sched-spike.sps` — the scheduler against real chez-libuv

Command:
`CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs chez --program sched-spike.sps`

```
scheduler: (idle 70)
  (done hog-finished)
  (done (resolver (dns-ok 2 "::1")))
  (done (two-awaits timer-fired timer-fired))
  (done (sleeper timer-fired hog-progress-when-woken 299999))
loop open after teardown? #f
```
Four tasks: a 300k-iteration CPU hog (sliced at 5000 ticks), a 5 ms timer sleeper, a
`uv-getaddrinfo!` await for `localhost`, two sequential 1 ms timer awaits. Callbacks only
stored values and pushed the task; every `engine-block` happened in Scheme frames outside
`uv-run`; `uv-run` was `'once` when the queue was empty and `'nowait` otherwise. Teardown
closed the loop. (Two earlier attempts failed at load time for reasons unrelated to the
design: an `(rnrs)`/`(chezscheme)` import clash and R6RS setter naming; both fixed.)

### 12.6 `nowait.sps` — poll cost

```
100000 x (uv-run loop 'nowait) on an idle loop: 1331 ms, 33 bytes/call
100000 x (engine slice + nowait): 1511 ms
```

### 12.7 `sz.c` — libuv struct sizes

Command: `cc $(pkg-config --cflags --libs libuv) sz.c -o sz && ./sz`

```
uv_timer_t=152 uv_tcp_t=264 uv_write_t=192 uv_getaddrinfo_t=160 uv_shutdown_t=80
```

### 12.8 Other citations used verbatim

- chez-libuv `loop.sls:55-56`: `(when (loop-running? loop) (raise (make-uv-invalid-argument 'uv-run 'loop-running)))`
- `handles.sls:291-300`: `loop-record-error!` — "Never raise through a C callback frame. Store the first object and stop the loop; retain later objects for inspection."
- `stream.sls:73`: `(define default-read-buffer-size 65536)`
- `runtime.sls:1108`: `(make-parser-result 'paused pos (- pos start) (parser-offset parser) #f …)`
- api.md:266-274: "A second `uv-close!` silently discards its callback … a server that deregisters a connection from `on-close` must own every close initiation for that handle".
- spike/FINDINGS.md:429-431: "An unhandled raise inside a `foreign-callable` kills the process. Nothing after `uv_run` runs: no teardown, no `uv_loop_close`, no `foreign-free`." (exit 255)
- performance.org:20-23: `POST` with a 10-byte body 6,112 B per whole-buffer parse; 10,000-byte body 6,160 B.
- conformance.org:40-44: "Every in-scope fixture is replayed at every chunk size from 1 to its length and the parser's rendered trace is compared byte for byte."

---

## 13. What engines buy over plain coroutines (and what they cost)

Buy:
1. **Preemption.** A coroutine yields only where the author wrote a yield; an engine is cut
   at `slice-ticks` regardless. With 10k connections one non-yielding handler (a regex on
   attacker-shaped input, a big JSON encode) stalls every other connection under coroutines;
   under engines it costs everyone one slice per round.
2. **Per-request CPU budgets** for free: the handler deadline can be expressed in ticks
   (`engine-return`-free: the scheduler just stops re-queueing and closes) — a DoS knob no
   coroutine gives.
3. **Same direct-style API.** `await` / `body-read!` / `response-write!` read identically
   under a coroutine scheduler; the engine is an implementation detail behind `wait-until`.
4. **Bounded, measured cost:** ~25 B and ~0.5 µs per block/resume, ~800 B parked.

Cost:
1. No nesting (A2). 2. `dynamic-wind`/`parameterize` churn at every slice (A5). 3. C calls are
not preemptible (A4). 4. `set-timer` is off limits (A3). 5. The tick->time relation is
unspecified, so slice sizing is empirical.

---

## 14. Risks (honest, including where this angle is worse)

1. **Worse than the obvious callback/CPS design for trivial handlers.** A pure
   callback-driven connection state machine (parse in `on-data`, write in place) has no
   scheduler, no poll amortisation problem, no continuation per connection, and roughly the
   same allocation. For "respond with a small body" workloads, engines add a scheduler and a
   ~13 µs poll to amortise and buy nothing until a handler blocks or hogs.
2. **Worse than one-shot coroutines (`call/1cc`) if handlers are trusted.** A cooperative
   yield-at-await design has the same direct-style API, no nesting restriction, no
   `dynamic-wind` churn, and no timer-interrupt coupling. Engines only win when preemption
   is a requirement. If the judges decide handlers are trusted and short, pick coroutines.
3. **The nesting restriction is a footgun for users.** Any handler (or library it calls)
   that uses engines breaks with a runtime error; the server contains it (500) but cannot
   fix it. Chez's own `(chezscheme)` has other engine users? None known, but unverified.
4. **Poll latency vs throughput tension.** `batch-max` too small -> 13 µs/slice overhead;
   too large -> accept/read latency under CPU saturation. Needs a benchmark, not a guess.
5. **`dynamic-wind` cost is invisible to handler authors** and grows with slice frequency;
   `parameterize`-heavy code (loggers, request-context parameters) pays twice per slice.
6. **Unpreemptible foreign calls** (A4): a handler calling a slow C routine or a blocking
   libc call stalls the loop exactly as in every other single-threaded design; engines do
   not help there and the tick accounting can mislead ("7 ticks left" after 40 ms).
7. **Slice inside `parser-feed!`.** Preemption can land mid-feed (parser lifecycle `'busy`);
   correct because nothing else touches that parser (E1), but a future "inspect the parser
   from a timer" feature would violate it. Prefer a check: the timer path never touches
   parsers (test in §9.4).
8. **Continuation size is handler-stack dependent** (652 -> 804 B at 30 frames); a deeply
   recursive handler parked mid-recursion costs more. Bounded, but unbounded in principle.
9. **The A1 unknown is avoided, not answered.** If the live spike shows continuations from
   inside callbacks are fine, designs that resume handlers directly inside `on-data` skip a
   queue hop and a slice; this design keeps the hop for determinism (E1) and pays ~1 µs.
10. **Windows** (deferred by the house rules): `uv-stream-write-queue-size` semantics invert
    (api.md:212-217); the gauge threshold must be per-platform or off. Unrelated to engines.
11. **Timer wheel resolution** of 1 s means a 10 s header timeout fires at 10–11 s; fine for
    policy, wrong if anyone wants sub-second deadlines (make the tick configurable).
12. **The read-buffer default** is chez-libuv's, and 10k × 64 KiB = 625 MiB is the single
    biggest number in this document; the proposal sets 16 KiB but that is a tradeoff the
    binding explicitly left to consumers (api.md:172-181).
